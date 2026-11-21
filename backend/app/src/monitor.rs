use crate::App;
use axum::{
    Json,
    extract::{ConnectInfo, State},
    http::{HeaderMap, StatusCode},
    response::{
        IntoResponse, Response, Sse,
        sse::{Event, KeepAlive},
    },
};
use botai_core::{AppError, Result};
use serde_json::{Value, json};
use std::{
    convert::Infallible,
    net::{IpAddr, SocketAddr},
    time::Duration,
};

fn client_ip(peer: SocketAddr, headers: &HeaderMap) -> String {
    let ip = peer.ip();
    if ip.is_loopback() {
        if let Some(forwarded) = headers
            .get("x-real-ip")
            .and_then(|h| h.to_str().ok())
            .and_then(|value| value.parse::<IpAddr>().ok())
        {
            return forwarded.to_string();
        }
    }
    ip.to_string()
}

fn error(error: AppError) -> Response {
    (
        StatusCode::from_u16(error.status).unwrap_or(StatusCode::BAD_GATEWAY),
        Json(json!({"error":error.message,"retryable":error.retryable})),
    )
        .into_response()
}
pub async fn stream(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Response {
    let Some(monitor) = &app.monitor else {
        return error(AppError::unavailable("监控消息源未配置"));
    };
    let client = client_ip(peer, &headers);
    let subscription: Result<_> = async {
        botai_core::error::reject_secret_fields(&body)?;
        monitor
            .authorize(body["accessKey"].as_str().unwrap_or(""), &client)
            .await?;
        monitor.subscribe().await
    }
    .await;
    let subscription = match subscription {
        Ok(value) => value,
        Err(e) => return error(e),
    };
    let stream = futures::stream::unfold(subscription, |mut subscription| async move {
        let value = if !subscription.initial.is_empty() {
            subscription.initial.remove(0)
        } else {
            match subscription.receiver.recv().await {
                Ok(value) => value,
                Err(_) => return None,
            }
        };
        // A lagged client reconnects; private messages never build up without bound.
        let event = Event::default().json_data(value).ok()?;
        Some((Ok::<_, Infallible>(event), subscription))
    });
    let mut response = Sse::new(stream)
        .keep_alive(
            KeepAlive::new()
                .interval(Duration::from_secs(15))
                .text("heartbeat"),
        )
        .into_response();
    response
        .headers_mut()
        .insert("cache-control", "no-store, no-transform".parse().unwrap());
    response
        .headers_mut()
        .insert("x-accel-buffering", "no".parse().unwrap());
    response
        .headers_mut()
        .insert("content-encoding", "identity".parse().unwrap());
    response
}
pub async fn push(
    State(app): State<App>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Response {
    let Some(monitor) = &app.monitor else {
        return error(AppError::unavailable("监控消息源未配置"));
    };
    let client = client_ip(peer, &headers);
    let result: Result<_> = async {
        botai_core::error::reject_secret_fields(&body)?;
        monitor.push_action(body, &client).await
    }
    .await;
    match result {
        Ok(data) => Json(data).into_response(),
        Err(e) => error(e),
    }
}
pub async fn worker() -> Response {
    (
        [
            ("content-type", "application/javascript; charset=utf-8"),
            ("service-worker-allowed", "/"),
        ],
        include_str!("monitor-worker.js"),
    )
        .into_response()
}

pub async fn manifest() -> Response {
    (
        [
            ("content-type", "application/manifest+json"),
            ("cache-control", "no-cache"),
        ],
        Json(json!({
            "id": "/monitor/", "name": "本站监控", "short_name": "监控", "lang": "zh-CN",
            "start_url": "/monitor/", "scope": "/", "display": "standalone",
            "background_color": "#f7f7f5", "theme_color": "#f7f7f5",
            "icons": ([192, 512].map(|size| json!({
                "src": format!("/icons/Icon-{size}.png"), "sizes": format!("{size}x{size}"),
                "type": "image/png", "purpose": "any"
            })))
        })),
    )
        .into_response()
}
