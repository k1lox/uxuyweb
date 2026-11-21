use axum::{Json, Router, extract::State, routing::post};
use botai_core::Chain;
use botai_rpc::{Call, Rpc};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
};

#[tokio::test]
async fn direct_receipt_reads_invalidate_pre_confirmation_head_and_balances() {
    let block = Arc::new(AtomicU64::new(1));
    let app = Router::new()
        .route(
            "/",
            post(
                |State(block): State<Arc<AtomicU64>>, Json(calls): Json<Vec<Value>>| async move {
                    Json(calls.iter().map(|call| {
            let height = block.load(Ordering::SeqCst);
            let result = match call["method"].as_str().unwrap() {
                "eth_blockNumber" => json!(format!("0x{height:x}")),
                "eth_getBalance" => json!(format!("0x{:x}", height * 100)),
                "eth_getTransactionReceipt" if height > 1 => json!({
                    "transactionHash": "0x1234", "blockNumber": format!("0x{height:x}"),
                    "status": if height == 2 { "0x1" } else { "0x0" },
                }),
                "eth_getTransactionReceipt" => Value::Null,
                _ => panic!("unexpected RPC"),
            };
            json!({"jsonrpc": "2.0", "id": call["id"], "result": result})
        }).collect::<Vec<_>>())
                },
            ),
        )
        .with_state(block.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let rpc = Rpc::with_urls(
        reqwest::Client::new(),
        HashMap::from([(Chain::Robinhood, url.clone()), (Chain::Xlayer, url)]),
    );
    let head = Call::new("eth_blockNumber", vec![]);
    let balance = Call::new("eth_getBalance", vec![json!("0x01"), json!("latest")]);
    assert_eq!(
        rpc.read(Chain::Xlayer, head.clone()).await.unwrap(),
        json!("0x1")
    );
    assert_eq!(
        rpc.read(Chain::Robinhood, head.clone()).await.unwrap(),
        json!("0x1")
    );
    assert_eq!(
        rpc.read(Chain::Robinhood, balance.clone()).await.unwrap(),
        json!("0x64")
    );
    for height in [2, 3] {
        block.store(height, Ordering::SeqCst);
        // A new group has no previous runtime confirmation, only the shared API.
        assert_eq!(
            rpc.read(Chain::Robinhood, head.clone()).await.unwrap(),
            json!(format!("0x{:x}", height - 1))
        );
        rpc.read(
            Chain::Robinhood,
            Call::new(
                "eth_getTransactionReceipt",
                vec![json!(format!("0x{height:064x}"))],
            ),
        )
        .await
        .unwrap();
        assert_eq!(
            rpc.read(Chain::Robinhood, head.clone()).await.unwrap(),
            json!(format!("0x{height:x}"))
        );
        assert_eq!(
            rpc.read(Chain::Robinhood, balance.clone()).await.unwrap(),
            json!(format!("0x{:x}", height * 100))
        );
    }
    assert_eq!(
        rpc.read(Chain::Xlayer, head).await.unwrap(),
        json!("0x1"),
        "other chains keep their own snapshots"
    );
    server.abort();
}
