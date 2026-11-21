use axum::{
    Json, Router,
    body::Bytes,
    extract::{DefaultBodyLimit, State},
    routing::post,
};
use botai_core::Chain;
use botai_rpc::{Call, Rpc};
use serde_json::{Value, json};
use std::{
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
    time::Duration,
};
use tokio::sync::{Mutex, Semaphore};

const BYTE_BUDGET: usize = 2_700_000;

#[derive(Clone, Default)]
struct Mock {
    requests: Arc<Mutex<Vec<(usize, Vec<Value>)>>>,
    active: Arc<AtomicUsize>,
    maximum: Arc<AtomicUsize>,
    gate: Option<Arc<Semaphore>>,
}

async fn setup(mock: Mock) -> (Rpc, tokio::task::JoinHandle<()>) {
    let app = Router::new()
        .route(
            "/",
            post(|State(mock): State<Mock>, bytes: Bytes| async move {
                let rows = serde_json::from_slice::<Vec<Value>>(&bytes).unwrap();
                assert!(
                    rows.iter()
                        .all(|row| row["method"] != "eth_sendRawTransaction")
                );
                let active = mock.active.fetch_add(1, Ordering::SeqCst) + 1;
                mock.maximum.fetch_max(active, Ordering::SeqCst);
                mock.requests.lock().await.push((bytes.len(), rows.clone()));
                if let Some(gate) = &mock.gate {
                    gate.acquire().await.unwrap().forget();
                }
                mock.active.fetch_sub(1, Ordering::SeqCst);
                // Echo only the small marker: request-size tests must not create
                // artificially large responses or spend time cloning fixtures.
                Json(Value::Array(
                    rows.iter()
                        .map(|row| {
                            json!({"jsonrpc":"2.0", "id":row["id"], "result":row["params"][0]})
                        })
                        .collect(),
                ))
            }),
        )
        .layer(DefaultBodyLimit::max(8_000_000))
        .with_state(mock);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        [(Chain::Bsc, url)].into(),
    );
    (rpc, server)
}

fn heavy(method: &str) -> bool {
    matches!(
        method,
        "eth_simulateV1" | "debug_traceCall" | "debug_traceTransaction" | "trace_callMany"
    )
}

async fn wait_requests(mock: &Mock, count: usize) {
    tokio::time::timeout(Duration::from_secs(4), async {
        while mock.requests.lock().await.len() < count {
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await
    .expect("mock requests should make progress under the shared quota");
}

#[tokio::test]
async fn heavy_packing_keeps_all_six_http_lanes_and_continues_multiple_batches() {
    let gate = Arc::new(Semaphore::new(0));
    let mock = Mock {
        gate: Some(gate.clone()),
        ..Mock::default()
    };
    let (rpc, server) = setup(mock.clone()).await;
    let work = tokio::spawn(async move {
        rpc.read_many(
            Chain::Bsc,
            (0..40)
                .map(|i| {
                    Call::new(
                        [
                            "eth_simulateV1",
                            "debug_traceCall",
                            "debug_traceTransaction",
                            "trace_callMany",
                        ][i % 4],
                        vec![json!(i)],
                    )
                })
                .collect(),
        )
        .await
        .unwrap()
    });
    wait_requests(&mock, 6).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(
        mock.requests.lock().await.len(),
        6,
        "HTTP capacity stays six"
    );
    assert_eq!(mock.maximum.load(Ordering::SeqCst), 6);
    gate.add_permits(128);
    let replies = tokio::time::timeout(Duration::from_secs(5), work)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(replies, (0..40).map(|i| json!(i)).collect::<Vec<_>>());
    let requests = mock.requests.lock().await;
    assert!(requests.len() >= 10);
    assert!(
        requests
            .iter()
            .all(|(bytes, rows)| *bytes <= BYTE_BUDGET && rows.len() <= 4)
    );
    assert_eq!(
        requests.iter().map(|(_, rows)| rows.len()).sum::<usize>(),
        40
    );
    server.abort();
}

#[tokio::test]
async fn light_reads_keep_the_existing_item_limit_not_the_heavy_limit() {
    let mock = Mock::default();
    let (rpc, server) = setup(mock.clone()).await;
    let replies = rpc
        .read_many(
            Chain::Bsc,
            (0..40)
                .map(|i| Call::new("eth_getCode", vec![json!(i)]))
                .collect(),
        )
        .await
        .unwrap();
    assert_eq!(replies, (0..40).map(|i| json!(i)).collect::<Vec<_>>());
    let requests = mock.requests.lock().await;
    assert!(requests.iter().any(|(_, rows)| rows.len() > 4));
    assert!(requests.iter().all(|(_, rows)| rows.len() <= 10));
    server.abort();
}

#[tokio::test]
async fn mixed_pending_boundary_preserves_every_call_and_input_order() {
    let mock = Mock::default();
    let (rpc, server) = setup(mock.clone()).await;
    let calls = (0..48)
        .map(|i| {
            // Four heavy calls may share a batch with light calls; the fifth
            // already-popped heavy call must become the next batch's first item.
            Call::new(
                if i % 6 == 4 {
                    "eth_getCode"
                } else {
                    "eth_simulateV1"
                },
                vec![json!(i)],
            )
        })
        .collect();
    let replies = rpc.read_many(Chain::Bsc, calls).await.unwrap();
    assert_eq!(replies, (0..48).map(|i| json!(i)).collect::<Vec<_>>());
    let requests = mock.requests.lock().await;
    let mut markers = Vec::new();
    for (_, rows) in requests.iter() {
        assert!(
            rows.iter()
                .filter(|row| heavy(row["method"].as_str().unwrap()))
                .count()
                <= 4
        );
        let ids = rows
            .iter()
            .map(|row| row["params"][0].as_u64().unwrap())
            .collect::<Vec<_>>();
        assert!(
            ids.windows(2).all(|pair| pair[1] == pair[0] + 1),
            "pending stays ahead of later queued calls"
        );
        markers.extend(ids);
    }
    markers.sort_unstable();
    assert_eq!(markers, (0..48).collect::<Vec<_>>());
    server.abort();
}

#[tokio::test]
async fn encoded_byte_budget_splits_without_dropping_pending_or_rejecting_a_large_single_call() {
    let mock = Mock::default();
    let (rpc, server) = setup(mock.clone()).await;
    let mut calls = (0..7)
        .map(|i| Call::new("eth_call", vec![json!(i), json!("x".repeat(600_000))]))
        .collect::<Vec<_>>();
    // Existing valid per-call parameters below 3 MB remain supported, alone.
    calls.push(Call::new(
        "eth_call",
        vec![json!(7), json!("y".repeat(2_800_000))],
    ));
    calls.push(Call::new("eth_call", vec![json!(8)]));
    let replies = rpc.read_many(Chain::Bsc, calls).await.unwrap();
    assert_eq!(replies, (0..9).map(|i| json!(i)).collect::<Vec<_>>());
    let requests = mock.requests.lock().await;
    assert!(
        requests.iter().any(|(bytes, rows)| *bytes > BYTE_BUDGET
            && rows.len() == 1
            && rows[0]["params"][0] == 7)
    );
    assert!(
        requests
            .iter()
            .all(|(bytes, rows)| rows.len() == 1 || *bytes <= BYTE_BUDGET)
    );
    assert!(
        requests.iter().any(|(_, rows)| rows.len() >= 2),
        "normal large calls still coalesce"
    );
    assert_eq!(
        requests.iter().map(|(_, rows)| rows.len()).sum::<usize>(),
        9
    );
    server.abort();
}

#[tokio::test]
async fn canceled_pending_work_is_not_sent_and_does_not_block_following_reads() {
    let gate = Arc::new(Semaphore::new(0));
    let mock = Mock {
        gate: Some(gate.clone()),
        ..Mock::default()
    };
    let (rpc, server) = setup(mock.clone()).await;
    let first = {
        let rpc = rpc.clone();
        tokio::spawn(async move {
            rpc.read_many(
                Chain::Bsc,
                (0..24)
                    .map(|i| Call::new("eth_simulateV1", vec![json!(i)]))
                    .collect(),
            )
            .await
            .unwrap()
        })
    };
    wait_requests(&mock, 6).await;
    let canceled = {
        let rpc = rpc.clone();
        tokio::spawn(async move {
            rpc.read_many(
                Chain::Bsc,
                (100..132)
                    .map(|i| Call::new("eth_simulateV1", vec![json!(i)]))
                    .collect(),
            )
            .await
        })
    };
    // The worker is blocked on its six occupied HTTP lanes, including a batch
    // it already assembled and the next boundary item held in pending.
    tokio::time::sleep(Duration::from_millis(30)).await;
    canceled.abort();
    assert!(canceled.await.unwrap_err().is_cancelled());
    let follow = {
        let rpc = rpc.clone();
        tokio::spawn(async move {
            rpc.read(Chain::Bsc, Call::new("eth_simulateV1", vec![json!(999)]))
                .await
                .unwrap()
        })
    };
    gate.add_permits(128);
    tokio::time::timeout(Duration::from_secs(5), first)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(
        tokio::time::timeout(Duration::from_secs(5), follow)
            .await
            .unwrap()
            .unwrap(),
        json!(999)
    );
    let requests = mock.requests.lock().await;
    let mut markers = requests
        .iter()
        .flat_map(|(_, rows)| rows.iter().map(|row| row["params"][0].as_u64().unwrap()))
        .collect::<Vec<_>>();
    markers.sort_unstable();
    assert_eq!(markers, (0..24).chain([999]).collect::<Vec<_>>());
    server.abort();
}
