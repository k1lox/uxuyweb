mod approvals;
mod config;
mod error;
mod issued;
mod launch_bundle;
mod launch_approval;
mod monitor;
mod platform_api;
mod route;
mod rpc;
mod submit;
mod uxuy;
mod wallets;

#[cfg(test)]
mod tests;

use alloy_primitives::{Address, Bytes};
use axum::{
    Json, Router,
    extract::{DefaultBodyLimit, Path, State},
    routing::{get, post},
};
use config::Config;
use error::{ApiError, Result};
use route::{Planner, RouteRequest};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Clone)]
pub struct App {
    planner: Planner,
    rpc: rpc::Rpc,
    pub router: Address,
    rpc_provider: &'static str,
    node_status: std::sync::Arc<tokio::sync::Mutex<Option<(std::time::Instant, Value)>>>,
    pub denied: Vec<Address>,
    pub issued: issued::IssuedRoutes,
    route_enabled: bool,
    // Carried over from the BotAI backend.
    pub chain_rpc: botai_rpc::Rpc,
    pub platforms: botai_platforms::Platforms,
    pub integrations: botai_integrations::Integrations,
    pub transactions: botai_transactions::Transactions,
    monitor: Option<botai_monitor::Monitor>,
}

fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let path = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "config.local.toml".into());
    let config = Config::load(&path).unwrap_or_else(|e| panic!("config: {e}"));
    let http = reqwest::Client::builder()
        .user_agent("uxuy-backend/0.1")
        .build()
        .expect("http client");
    let rpc_endpoint = config
        .rpc_endpoint()
        .unwrap_or_else(|e| panic!("config: {e}"));
    let rpc_provider = if rpc_endpoint.scheme() == "http" {
        "local-fork"
    } else {
        "configured"
    };
    let rpc = rpc::Rpc::new(http.clone(), rpc_endpoint.as_str());
    let (gateway, router, spender, native) = match &config.uxuy {
        Some(settings) => {
            verify_gateway_contracts(&rpc, settings)
                .await
                .expect("UXUY BSC contract check");
            let app_id =
                std::fs::read_to_string(&settings.app_id_file).expect("read UXUY app ID file");
            let key =
                std::fs::read(&settings.signing_key_file).expect("read UXUY signing key file");
            let client =
                uxuy::Uxuy::new(app_id.trim(), &key).expect("invalid UXUY server credential");
            (
                client,
                settings.router,
                settings.approval_spender,
                settings.native_token,
            )
        }
        None => (
            uxuy::Uxuy::disabled(),
            Address::ZERO,
            Address::ZERO,
            Address::ZERO,
        ),
    };
    let chain_rpc = botai_rpc::Rpc::with_urls(
        http.clone(),
        [(botai_core::Chain::Bsc, rpc_endpoint.to_string())]
            .into_iter()
            .collect(),
    );
    let platforms = botai_platforms::Platforms::new(chain_rpc.clone());
    let mut monitor_db = None;
    let store = match &config.mysql {
        Some(db) => {
            let db = botai_database::Database::connect(
                &db.host,
                db.port,
                &db.database,
                &db.user,
                &db.password,
            )
            .expect("mysql");
            db.schema().expect("mysql schema");
            monitor_db = Some(db.clone());
            botai_transactions::Store::mysql(db)
        }
        None => {
            if let Some(dir) = std::path::Path::new(&config.store_path).parent() {
                std::fs::create_dir_all(dir).ok();
            }
            botai_transactions::Store::open(&config.store_path).expect("transaction store")
        }
    };
    let transactions = botai_transactions::Transactions::new(
        store,
        chain_rpc.clone(),
        http.clone(),
        config
            .bundle
            .as_ref()
            .map(|b| b.authorization.clone())
            .unwrap_or_default(),
    );
    let transactions = match &config.bundle_local_relay {
        Some(url) => transactions
            .with_local_relay(url)
            .expect("local relay must be loopback http"),
        None => transactions,
    };
    let monitor = config.monitor.as_ref().map(|settings| {
        assert!([&settings.token, &settings.chat_id, &settings.sender_id, &settings.access_key].iter().all(|v| !v.trim().is_empty()), "monitor settings incomplete");
        match monitor_db {
            Some(db) => botai_monitor::Monitor::new_mysql(settings.clone(), http.clone(), db),
            None => botai_monitor::Monitor::new(settings.clone(), http.clone(), format!("{}.monitor", config.store_path)),
        }.expect("monitor store")
    });
    let _tracker = transactions.start_tracking();
    let app = App {
        monitor,
        rpc_provider,
        node_status: Default::default(),
        chain_rpc: chain_rpc.clone(),
        integrations: botai_integrations::Integrations::new(http.clone(), chain_rpc.clone()),
        platforms: platforms.clone(),
        transactions,
        denied: config.denied_contracts.clone(),
        issued: issued::IssuedRoutes::default(),
        route_enabled: config.uxuy.is_some(),
        planner: Planner {
            platforms: Some(platforms),
            uxuy: gateway,
            rpc: Some(rpc.clone()),
            router,
            spender,
            native,
            max_impact_percent: config.max_price_impact_percent,
            default_slippage_bps: config.default_slippage_bps,
            deadline_seconds: config.deadline_seconds,
        },
        rpc,
        router,
    };
    if let (Some(root), Some(addr)) = (&config.web_root, &config.web_listen) {
        let web = Router::new().fallback_service(tower_http::services::ServeDir::new(root));
        let web_listener = tokio::net::TcpListener::bind(addr)
            .await
            .expect("bind web preview");
        tracing::info!("web preview on {addr}");
        tokio::spawn(async move { axum::serve(web_listener, web).await.ok() });
    }
    let listener = tokio::net::TcpListener::bind(&config.listen)
        .await
        .expect("bind");
    tracing::info!("uxuy backend listening on {}", config.listen);
    let origins: Vec<axum::http::HeaderValue> = config
        .cors_origins
        .iter()
        .filter_map(|o| o.parse().ok())
        .collect();
    let cors = tower_http::cors::CorsLayer::new()
        .allow_origin(origins)
        .allow_methods([axum::http::Method::GET, axum::http::Method::POST])
        .allow_headers([axum::http::header::CONTENT_TYPE]);
    axum::serve(listener, routes(app).layer(cors).into_make_service_with_connect_info::<std::net::SocketAddr>())
        .await
        .expect("serve");
}

fn routes(app: App) -> Router {
    Router::new()
        .route(
            "/api/v1/health",
            get(|| async { Json(json!({"ok": true})) }),
        )
        .route("/api/telegram-monitor", post(monitor::stream).layer(DefaultBodyLimit::max(1024)))
        .route("/api/monitor-push", post(monitor::push).layer(DefaultBodyLimit::max(4096)))
        .route("/api/monitor-worker", get(monitor::worker))
        .route("/api/monitor-manifest", get(monitor::manifest))
        .route("/api/v1/config", get(public_config))
        .route("/api/v1/rpc-latency", get(rpc_latency))
        .route("/api/v1/routes", post(plan_route))
        .route("/api/v1/routes/batch", post(plan_batch))
        .route("/api/v1/routes/rapid-check", post(route::rapid_probe::check))
        .route("/api/v1/approvals/check", post(approvals::prepare))
        .route("/api/v1/routes/bundle", post(plan_bundle))
        .route("/api/v1/wallets/state", post(wallet_states))
        .route("/api/v1/gas", get(gas_price))
        .route("/api/v1/tokens/{token}", get(token_meta))
        // Carried over from the BotAI backend (BSC only), with signed transaction validation.
        .route("/api/v1/rpc/{chain}", post(platform_api::read_rpc))
        .route(
            "/api/v1/platforms/{chain}",
            post(platform_api::platform_market),
        )
        .route(
            "/api/v1/transactions/{chain}",
            post(platform_api::submit_transactions),
        )
        .route(
            "/api/v1/transactions/{chain}/{hash}",
            get(platform_api::transaction_status),
        )
        .route("/api/v1/bundles", post(platform_api::bundle))
        .route(
            "/api/flap",
            get(platform_api::flap_get)
                .post(platform_api::flap_upload)
                .layer(DefaultBodyLimit::max(10_100_000)),
        )
        .route(
            "/api/fourmeme",
            post(platform_api::four).layer(DefaultBodyLimit::max(10_100_000)),
        )
        .route("/api/fourmeme/status", get(platform_api::four_status))
        .route(
            "/api/genius/image",
            get(platform_api::genius_get)
                .post(platform_api::genius_upload)
                .layer(DefaultBodyLimit::max(2 * 1024 * 1024)),
        )
        .layer(DefaultBodyLimit::max(4 * 1024 * 1024))
        .with_state(app)
}

async fn verify_gateway_contracts(rpc: &rpc::Rpc, settings: &config::UxuyConfig) -> Result<()> {
    let mut addresses = vec![settings.router];
    if settings.approval_spender != settings.router {
        addresses.push(settings.approval_spender);
    }
    let chain = rpc.call("eth_chainId", json!([])).await?;
    if rpc::hex_u64(&chain)? != config::CHAIN_ID {
        return Err(ApiError::invalid("UXUY 执行网络必须为 BSC 主网"));
    }
    for address in addresses {
        let reply = rpc.call("eth_getCode", json!([address, "latest"])).await?;
        let code = reply.as_str().and_then(|text| text.parse::<Bytes>().ok());
        if !code.is_some_and(|bytes| !bytes.is_empty()) {
            return Err(ApiError::invalid(format!(
                "BSC 地址 {address:#x} 没有合约代码"
            )));
        }
    }
    Ok(())
}

async fn rpc_latency(State(app): State<App>) -> Json<Value> {
    use botai_core::Chain;
    use std::time::{Duration, Instant};

    let mut cache = app.node_status.lock().await;
    if let Some((sampled, value)) = cache.as_ref() {
        if sampled.elapsed() < Duration::from_secs(5) {
            return Json(value.clone());
        }
    }
    let ms = app.chain_rpc.latency(Chain::Bsc).await;
    let limited = app.chain_rpc.rate_limited(Chain::Bsc).await;
    let value = json!({"ok": true, "ms": ms, "limited": limited});
    *cache = Some((Instant::now(), value.clone()));
    Json(value)
}

async fn public_config(State(app): State<App>) -> Json<Value> {
    Json(
        json!({"ok": true, "chainId": config::CHAIN_ID, "rpcProvider": app.rpc_provider,
        "routeSource": "uxuy", "routeEnabled": app.route_enabled, "router": app.router,
        "approvalSpender": app.planner.spender, "fastPreflightVersion": 1,
        "maxPriceImpactPercent": app.planner.max_impact_percent}),
    )
}

async fn plan_route(State(app): State<App>, Json(req): Json<RouteRequest>) -> Result<Json<Value>> {
    let plan = app.planner.plan(&req, now()).await?;
    app.issued.record(&plan)?;
    Ok(Json(json!({"ok": true, "plan": plan})))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct BatchRequest {
    requests: Vec<RouteRequest>,
}

/// Preserve request order and report failures per wallet.
async fn plan_batch(State(app): State<App>, Json(req): Json<BatchRequest>) -> Result<Json<Value>> {
    if req.requests.is_empty() || req.requests.len() > 200 {
        return Err(ApiError::invalid("批量数量需在 1–200 之间"));
    }
    use futures::{StreamExt, stream};
    let planner = &app.planner;
    let issued = &app.issued;
    let out: Vec<_> = stream::iter(req.requests).map(|r| async move {
        match planner.plan(&r, now()).await.and_then(|plan| { issued.record(&plan)?; Ok(plan) }) {
            Ok(plan) => json!({"ok": true, "plan": plan}),
            Err(e) => json!({"ok": false, "wallet": r.wallet, "code": e.code, "message": e.message, "retryable": e.retryable}),
        }
    }).buffered(8).collect().await;
    Ok(Json(json!({"ok": true, "results": out})))
}

async fn plan_bundle(State(app): State<App>, Json(req): Json<BatchRequest>) -> Result<Json<Value>> {
    let (group, plans) = app.planner.plan_bundle(&req.requests, now()).await?;
    for plan in &plans {
        app.issued.record(plan)?;
    }
    let results: Vec<_> = plans
        .into_iter()
        .map(|plan| json!({"ok": true, "plan": plan}))
        .collect();
    Ok(Json(
        json!({"ok": true, "groupPlan": group, "results": results}),
    ))
}

async fn wallet_states(
    State(app): State<App>,
    Json(req): Json<wallets::StateRequest>,
) -> Result<Json<Value>> {
    let states = wallets::states(&app.rpc, app.planner.spender, &req).await?;
    Ok(Json(json!({"ok": true, "wallets": states})))
}

async fn token_meta(State(app): State<App>, Path(token): Path<String>) -> Result<Json<Value>> {
    let token: Address = token
        .parse()
        .map_err(|_| ApiError::invalid("代币地址无效"))?;
    Ok(Json(
        json!({"ok": true, "token": wallets::token_meta(&app.rpc, token).await?}),
    ))
}

async fn gas_price(State(app): State<App>) -> Result<Json<Value>> {
    let (price, block) = tokio::try_join!(
        app.rpc.call("eth_gasPrice", json!([])),
        app.rpc.call("eth_blockNumber", json!([]))
    )?;
    Ok(Json(
        json!({"ok": true, "gasPrice": rpc::hex_u64(&price)?.to_string(), "blockNumber": rpc::hex_u64(&block)?}),
    ))
}
