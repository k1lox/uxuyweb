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
};

async fn mock(
    State((number, count)): State<(u64, Arc<AtomicUsize>)>,
    Json(body): Json<Value>,
) -> Json<Value> {
    let respond = |row: &Value| {
        count.fetch_add(1, Ordering::SeqCst);
        json!({"jsonrpc":"2.0","id":row["id"],"result":format!("0x{number:x}")})
    };
    Json(if let Some(rows) = body.as_array() {
        Value::Array(rows.iter().map(respond).collect())
    } else {
        respond(&body)
    })
}

#[tokio::test]
async fn endpoints_are_request_local_and_share_only_their_own_cache() {
    let mut servers = Vec::new();
    let mut urls = Vec::new();
    let mut counts = Vec::new();
    for number in 1..=5 {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        urls.push(format!("http://{}", listener.local_addr().unwrap()));
        let count = Arc::new(AtomicUsize::new(0));
        counts.push(count.clone());
        let router = Router::new()
            .route("/", post(mock))
            .with_state((number, count));
        servers.push(tokio::spawn(async move {
            axum::serve(listener, router).await.unwrap();
        }));
    }
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        HashMap::from([(Chain::Akc, urls[0].clone())]),
    )
    .with_alternatives(Chain::Akc, urls[1..].to_vec());
    assert_eq!(rpc.endpoint_count(Chain::Akc), 5);
    assert!(rpc.select_endpoint(Chain::Akc, 5).is_err());
    let users: Vec<_> = (0..20)
        .map(|id| rpc.select_endpoint(Chain::Akc, id % 5).unwrap())
        .collect();
    let values = futures::future::join_all(
        users
            .iter()
            .map(|user| user.read(Chain::Akc, Call::new("eth_blockNumber", vec![]))),
    )
    .await;
    for (index, value) in values.into_iter().enumerate() {
        assert_eq!(value.unwrap(), format!("0x{:x}", index % 5 + 1));
    }
    assert!(
        counts.iter().all(|count| count.load(Ordering::SeqCst) == 1),
        "same-node users share reads"
    );
    assert_eq!(
        rpc.read(Chain::Akc, Call::new("eth_blockNumber", vec![]))
            .await
            .unwrap(),
        "0x1",
        "another user's switch never changes the default"
    );
    // Broadcasting uses the same selected endpoint, never the default.
    let selected = rpc.select_endpoint(Chain::Akc, 4).unwrap();
    selected.broadcast(Chain::Akc, "0x00").await.unwrap();
    assert_eq!(counts[4].load(Ordering::SeqCst), 2);
    assert_eq!(counts[0].load(Ordering::SeqCst), 1);
    for server in servers {
        server.abort();
    }
}
