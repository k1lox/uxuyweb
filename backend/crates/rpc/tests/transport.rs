use axum::{Json, Router, extract::State, routing::post};
use botai_core::Chain;
use botai_rpc::{Call, Rpc};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};

#[derive(Clone)]
struct Mock {
    requests: Arc<AtomicUsize>,
    methods: Arc<tokio::sync::Mutex<Vec<String>>>,
}
async fn handler(State(state): State<Mock>, Json(body): Json<Vec<Value>>) -> Json<Value> {
    state.requests.fetch_add(1, Ordering::SeqCst);
    let mut result = Vec::new();
    for row in body {
        state
            .methods
            .lock()
            .await
            .push(row["method"].as_str().unwrap().into());
        result.push(if row["params"].as_array().is_some_and(|p| p.contains(&json!("revert"))) {
            json!({"jsonrpc":"2.0","id":row["id"],"error":{"code":3,"message":"execution reverted","data":"0x1234"}})
        } else { json!({"jsonrpc":"2.0","id":row["id"],"result":row["params"].as_array().and_then(|p|p.first()).cloned().unwrap_or(json!("0x1"))}) });
    }
    result.reverse(); // Node replies may arrive in a different order.
    Json(json!(result))
}
async fn setup() -> (Rpc, Mock, tokio::task::JoinHandle<()>) {
    let state = Mock {
        requests: Arc::new(AtomicUsize::new(0)),
        methods: Arc::new(tokio::sync::Mutex::new(vec![])),
    };
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let router = Router::new()
        .route("/", post(handler))
        .with_state(state.clone());
    let task = tokio::spawn(async { axum::serve(listener, router).await.unwrap() });
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(2))
        .no_proxy()
        .build()
        .unwrap();
    (
        Rpc::with_urls(client, HashMap::from([(Chain::Xlayer, url)])),
        state,
        task,
    )
}
#[tokio::test]
async fn same_reads_coalesce_and_distinct_reads_batch_in_original_order() {
    let (rpc, state, server) = setup().await;
    let calls = (0..40).map(|_| rpc.read(Chain::Xlayer, Call::new("eth_blockNumber", vec![])));
    let results = futures::future::join_all(calls).await;
    assert!(results.iter().all(|r| r.as_ref().unwrap() == "0x1"));
    assert_eq!(state.requests.load(Ordering::SeqCst), 1);
    let result = rpc
        .read_many(
            Chain::Xlayer,
            (0..25)
                .map(|i| Call::new("eth_getBalance", vec![json!(i), json!("latest")]))
                .collect(),
        )
        .await
        .unwrap();
    assert_eq!(result, (0..25).map(|i| json!(i)).collect::<Vec<_>>());
    assert_eq!(state.requests.load(Ordering::SeqCst), 4); // 1 shared + three batches <= 10.
    server.abort();
}
#[tokio::test]
async fn nonce_is_fresh_and_write_requests_never_reach_read_node() {
    let (rpc, state, server) = setup().await;
    for _ in 0..2 {
        rpc.read(
            Chain::Xlayer,
            Call::new(
                "eth_getTransactionCount",
                vec![json!("wallet"), json!("pending")],
            ),
        )
        .await
        .unwrap();
    }
    assert_eq!(state.requests.load(Ordering::SeqCst), 2);
    assert!(
        rpc.read(
            Chain::Xlayer,
            Call::new("eth_sendRawTransaction", vec![json!("0x01")])
        )
        .await
        .is_err()
    );
    assert!(
        !state
            .methods
            .lock()
            .await
            .iter()
            .any(|m| m == "eth_sendRawTransaction")
    );
    server.abort();
}
#[tokio::test]
async fn contract_reverts_preserve_decodable_data_and_are_not_transport_retried() {
    let (rpc, state, server) = setup().await;
    let error = rpc
        .read(Chain::Xlayer, Call::new("eth_call", vec![json!("revert")]))
        .await
        .unwrap_err();
    assert_eq!(error.code, "3");
    assert_eq!(error.data, Some(json!("0x1234")));
    assert_eq!(state.requests.load(Ordering::SeqCst), 1);
    server.abort();
}

#[tokio::test]
async fn send_http_rate_limit_is_definitive_but_server_error_remains_unknown() {
    for status in [401u16, 403, 413, 429, 500, 502, 504] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let router = Router::new().route(
            "/",
            post(move || async move { axum::http::StatusCode::from_u16(status).unwrap() }),
        );
        let server = tokio::spawn(async { axum::serve(listener, router).await.unwrap() });
        let rpc = Rpc::with_urls(
            reqwest::Client::builder().no_proxy().build().unwrap(),
            HashMap::from([(Chain::Xlayer, url)]),
        );
        let error = rpc
            .broadcast(Chain::Xlayer, "0xLOCAL_TEST_ONLY")
            .await
            .unwrap_err();
        assert_eq!(error.not_submitted, status < 500);
        assert_eq!(error.retryable, status == 429 || status >= 500);
        server.abort();
    }
}
