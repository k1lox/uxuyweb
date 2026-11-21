use axum::{Json, Router, extract::State, routing::post};
use botai_core::Chain;
use botai_rpc::{Call, Rpc};
use serde_json::{Value, json};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

#[tokio::test]
async fn latency_uses_real_requests_even_when_block_number_is_cached() {
    let count = Arc::new(AtomicUsize::new(0));
    let app = Router::new().route("/", post(|State(count): State<Arc<AtomicUsize>>, Json(value): Json<Value>| async move {
        let n = count.fetch_add(1, Ordering::SeqCst);
        let reply = |row: &Value| json!({"jsonrpc":"2.0","id":row["id"],"result": if n < 3 {"0x123"} else {"bad-response"}});
        Json(if let Some(rows) = value.as_array() { Value::Array(rows.iter().map(reply).collect()) } else {reply(&value)})
    })).with_state(count.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(axum::serve(listener, app).into_future());
    let rpc = Rpc::with_urls(reqwest::Client::new(), [(Chain::Bsc, url)].into());
    rpc.read(Chain::Bsc, Call::new("eth_blockNumber", vec![]))
        .await
        .unwrap();
    assert!(rpc.latency(Chain::Bsc).await.is_some());
    assert!(rpc.latency(Chain::Bsc).await.is_some());
    assert!(rpc.latency(Chain::Bsc).await.is_none());
    assert_eq!(count.load(Ordering::SeqCst), 4);
    assert!(rpc.latency(Chain::Arc).await.is_none());
    server.abort();
}
