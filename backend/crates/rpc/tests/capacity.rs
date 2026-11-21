use axum::{Json, Router, extract::State, routing::post};
use botai_core::Chain;
use botai_rpc::{Call, Rpc};
use serde_json::{Value, json};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::{Mutex, Semaphore};

#[derive(Clone, Default)]
struct Mock {
    calls: Arc<Mutex<Vec<(Instant, Vec<Value>)>>>,
    gate: Option<Arc<Semaphore>>,
}
async fn setup(mock: Mock) -> (Rpc, tokio::task::JoinHandle<()>) {
    let app = Router::new()
        .route(
            "/",
            post(
                |State(mock): State<Mock>, Json(body): Json<Value>| async move {
                    let is_batch = body.is_array();
                    let rows = if is_batch {
                        body.as_array().unwrap().clone()
                    } else {
                        vec![body]
                    };
                    mock.calls.lock().await.push((Instant::now(), rows.clone()));
                    if let Some(gate) = mock.gate {
                        gate.acquire().await.unwrap().forget();
                    }
                    let replies = rows
                        .iter()
                        .map(|row| {
                            json!({
                                "jsonrpc":"2.0", "id":row["id"],
                                "result":match row["method"].as_str().unwrap() {
                                    "eth_getTransactionReceipt" => Value::Null,
                                    "eth_blockNumber" => json!("0x1"),
                                    _ => row["params"].clone(),
                                }
                            })
                        })
                        .collect::<Vec<_>>();
                    Json(if is_batch {
                        Value::Array(replies)
                    } else {
                        replies[0].clone()
                    })
                },
            ),
        )
        .with_state(mock);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    // Aliases intentionally refer to one mock node. Only admission is shared;
    // chain-scoped results/caches must remain separate.
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        [
            (Chain::Bsc, url.clone()),
            (Chain::Xlayer, url.clone()),
            (Chain::Robinhood, url),
        ]
        .into(),
    );
    (rpc, server)
}
async fn wait_calls(mock: &Mock, count: usize) {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if mock.calls.lock().await.len() >= count {
                return;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn mixed_users_share_endpoint_quota_including_simulations_sends_receipts_and_health() {
    let mock = Mock::default();
    let (rpc, server) = setup(mock.clone()).await;
    let start = Instant::now();
    assert!(rpc.latency(Chain::Xlayer).await.is_some());
    let mut work = Vec::new();
    for (user, chain) in [Chain::Bsc, Chain::Xlayer, Chain::Robinhood]
        .into_iter()
        .enumerate()
    {
        let rpc = rpc.clone();
        work.push(tokio::spawn(async move {
            let calls = (0..26)
                .map(|i| {
                    let method = [
                        "eth_simulateV1",
                        "eth_estimateGas",
                        "eth_getTransactionReceipt",
                        "eth_getBalance",
                    ][i % 4];
                    Call::new(
                        method,
                        vec![json!(format!("user-{user}-{i}")), json!("latest")],
                    )
                })
                .collect();
            assert_eq!(rpc.read_many(chain, calls).await.unwrap().len(), 26);
        }));
    }
    for i in 0..9 {
        let rpc = rpc.clone();
        work.push(tokio::spawn(async move {
            rpc.broadcast(Chain::Xlayer, &format!("MOCK_ONLY_{i}"))
                .await
                .unwrap();
        }));
    }
    tokio::time::timeout(Duration::from_secs(6), async {
        for task in work {
            task.await.unwrap();
        }
    })
    .await
    .unwrap();
    let history = mock.calls.lock().await;
    assert_eq!(
        history.iter().map(|(_, rows)| rows.len()).sum::<usize>(),
        88
    );
    assert!(history.iter().all(|(_, rows)| rows.len() <= 10));
    assert_eq!(
        history
            .iter()
            .flat_map(|(_, rows)| rows)
            .filter(|row| row["method"] == "eth_sendRawTransaction")
            .count(),
        9
    );
    assert!(start.elapsed() >= Duration::from_secs(2));
    // Network receipt timestamps can differ from exact local admission time.
    // The unit test checks the exact 1 s admission window without this tolerance.
    let times = history
        .iter()
        .flat_map(|(at, rows)| std::iter::repeat_n(*at, rows.len()))
        .collect::<Vec<_>>();
    for window in times.windows(41) {
        assert!(window[40] - window[0] >= Duration::from_millis(950));
    }
    server.abort();
}

#[tokio::test]
async fn health_waits_for_quota_without_reporting_queue_time_as_latency() {
    let mock = Mock::default();
    let (rpc, server) = setup(mock.clone()).await;
    rpc.read_many(
        Chain::Bsc,
        (0..10)
            .map(|i| Call::new("eth_estimateGas", vec![json!(i)]))
            .collect(),
    )
    .await
    .unwrap();
    let start = Instant::now();
    let latency = rpc
        .latency(Chain::Xlayer)
        .await
        .expect("quota waiting is not a node outage");
    assert!(start.elapsed() >= Duration::from_millis(200));
    assert!(
        latency < 500,
        "local FIFO wait must not contaminate node latency"
    );
    assert_eq!(
        mock.calls
            .lock()
            .await
            .iter()
            .map(|(_, rows)| rows.len())
            .sum::<usize>(),
        11
    );
    server.abort();
}

#[tokio::test]
async fn rejected_item_retry_consumes_quota_without_repeating_successes() {
    let history = Arc::new(Mutex::new(Vec::<(Instant, Vec<Value>)>::new()));
    let app = Router::new().route("/", post(|State(history): State<Arc<Mutex<Vec<(Instant, Vec<Value>)>>>>, Json(rows): Json<Vec<Value>>| async move {
        let mut seen = history.lock().await;
        let first = seen.is_empty();
        seen.push((Instant::now(), rows.clone()));
        Json(Value::Array(rows.iter().map(|row| if first && row["params"][0] == 0 {
            json!({"jsonrpc":"2.0","id":row["id"],"error":{"code":-32016,"message":"over rate limit"}})
        } else {
            json!({"jsonrpc":"2.0","id":row["id"],"result":row["params"][0]})
        }).collect()))
    })).with_state(history.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        [(Chain::Bsc, url)].into(),
    );
    let rows = rpc
        .read_many(
            Chain::Bsc,
            (0..10)
                .map(|i| Call::new("eth_estimateGas", vec![json!(i)]))
                .collect(),
        )
        .await
        .unwrap();
    assert_eq!(rows, (0..10).map(|i| json!(i)).collect::<Vec<_>>());
    let history = history.lock().await;
    assert_eq!(
        history
            .iter()
            .map(|(_, rows)| rows.len())
            .collect::<Vec<_>>(),
        vec![10, 1]
    );
    assert_eq!(history[1].1[0]["params"][0], 0);
    assert!(history[1].0 - history[0].0 >= Duration::from_millis(450));
    server.abort();
}

#[tokio::test]
async fn cached_identical_reads_share_work_but_fresh_methods_and_full_call_parameters_do_not_mix() {
    let mock = Mock::default();
    let (rpc, server) = setup(mock.clone()).await;
    let call = Call::new(
        "eth_call",
        vec![
            json!({"from":"a", "to":"token", "value":"0x1", "data":"0x"}),
            json!("latest"),
        ],
    );
    let shared =
        futures::future::join_all((0..20).map(|_| rpc.read(Chain::Xlayer, call.clone()))).await;
    assert!(shared.iter().all(Result::is_ok));
    let variants = vec![
        Call::new(
            "eth_call",
            vec![
                json!({"from":"b", "to":"token", "value":"0x1", "data":"0x"}),
                json!("latest"),
            ],
        ),
        Call::new(
            "eth_call",
            vec![
                json!({"from":"a", "to":"token", "value":"0x2", "data":"0x"}),
                json!("latest"),
            ],
        ),
        Call::new(
            "eth_call",
            vec![
                json!({"from":"a", "to":"token", "value":"0x1", "data":"0x"}),
                json!("pending"),
            ],
        ),
    ];
    rpc.read_many(Chain::Xlayer, variants).await.unwrap();
    rpc.read(Chain::Robinhood, call).await.unwrap();
    for method in [
        "eth_getTransactionCount",
        "eth_estimateGas",
        "eth_simulateV1",
    ] {
        let call = Call::new(method, vec![json!("exact-same"), json!("pending")]);
        let (a, b) = tokio::join!(
            rpc.read(Chain::Xlayer, call.clone()),
            rpc.read(Chain::Xlayer, call.clone())
        );
        a.unwrap();
        b.unwrap();
        rpc.read(Chain::Xlayer, call).await.unwrap();
    }
    let history = mock.calls.lock().await;
    assert_eq!(
        history.iter().map(|(_, rows)| rows.len()).sum::<usize>(),
        14
    );
    for method in [
        "eth_getTransactionCount",
        "eth_estimateGas",
        "eth_simulateV1",
    ] {
        assert_eq!(
            history
                .iter()
                .flat_map(|(_, rows)| rows)
                .filter(|row| row["method"] == method)
                .count(),
            3
        );
    }
    server.abort();
}

#[tokio::test]
async fn cancellation_discards_queued_read_without_cancelling_another_consumer() {
    let gate = Arc::new(Semaphore::new(0));
    let mock = Mock {
        gate: Some(gate.clone()),
        ..Default::default()
    };
    let (rpc, server) = setup(mock.clone()).await;
    let mut occupied = Vec::new();
    for i in 0..6 {
        let rpc = rpc.clone();
        occupied.push(tokio::spawn(async move {
            rpc.read(Chain::Xlayer, Call::new("eth_estimateGas", vec![json!(i)]))
                .await
        }));
        wait_calls(&mock, i + 1).await;
    }
    let cancelled = {
        let rpc = rpc.clone();
        tokio::spawn(async move {
            rpc.read(
                Chain::Xlayer,
                Call::new("eth_estimateGas", vec![json!("cancelled")]),
            )
            .await
        })
    };
    tokio::time::sleep(Duration::from_millis(20)).await;
    cancelled.abort();
    assert!(cancelled.await.unwrap_err().is_cancelled());
    gate.add_permits(6);
    for task in occupied {
        task.await.unwrap().unwrap();
    }
    let call = Call::new("eth_getBalance", vec![json!("shared"), json!("latest")]);
    let survivor = {
        let rpc = rpc.clone();
        let call = call.clone();
        tokio::spawn(async move { rpc.read(Chain::Xlayer, call).await })
    };
    wait_calls(&mock, 7).await;
    let second = {
        let rpc = rpc.clone();
        tokio::spawn(async move { rpc.read(Chain::Xlayer, call).await })
    };
    tokio::time::sleep(Duration::from_millis(10)).await;
    second.abort();
    let _ = second.await;
    gate.add_permits(1);
    assert!(survivor.await.unwrap().is_ok());
    let history = mock.calls.lock().await;
    assert_eq!(history.iter().map(|(_, rows)| rows.len()).sum::<usize>(), 7);
    assert!(
        history
            .iter()
            .flat_map(|(_, rows)| rows)
            .all(|row| row["params"][0] != "cancelled")
    );
    server.abort();
}

#[tokio::test]
async fn cancellation_during_quota_wait_saves_items_and_preserves_survivor_mapping() {
    let mock = Mock::default();
    let (rpc, server) = setup(mock.clone()).await;
    rpc.read_many(
        Chain::Xlayer,
        (0..10)
            .map(|i| Call::new("eth_estimateGas", vec![json!(i)]))
            .collect(),
    )
    .await
    .unwrap();
    let cancelled = {
        let rpc = rpc.clone();
        tokio::spawn(async move {
            rpc.read(
                Chain::Xlayer,
                Call::new("eth_estimateGas", vec![json!("cancelled-quota")]),
            )
            .await
        })
    };
    let survivor = {
        let rpc = rpc.clone();
        tokio::spawn(async move {
            rpc.read(
                Chain::Xlayer,
                Call::new("eth_estimateGas", vec![json!("survivor")]),
            )
            .await
        })
    };
    // Both have a free HTTP lane but no short-window quota.
    tokio::time::sleep(Duration::from_millis(30)).await;
    cancelled.abort();
    assert!(cancelled.await.unwrap_err().is_cancelled());
    assert_eq!(survivor.await.unwrap().unwrap(), json!(["survivor"]));
    tokio::time::sleep(Duration::from_millis(280)).await;
    let history = mock.calls.lock().await;
    assert_eq!(
        history.iter().map(|(_, rows)| rows.len()).sum::<usize>(),
        11
    );
    assert!(
        history
            .iter()
            .flat_map(|(_, rows)| rows)
            .all(|row| row["params"][0] != "cancelled-quota")
    );
    server.abort();
}

#[tokio::test]
async fn quota_waiters_recheck_new_429_cooldown_for_read_send_and_health() {
    let history = Arc::new(Mutex::new(Vec::<(Instant, Vec<Value>)>::new()));
    let rejected_at = Arc::new(Mutex::new(None::<Instant>));
    let app = Router::new().route("/", post({
        let history = history.clone();
        let rejected_at = rejected_at.clone();
        move |Json(body): Json<Value>| {
            let history = history.clone(); let rejected_at = rejected_at.clone();
            async move {
                let array = body.is_array();
                let rows = if array { body.as_array().unwrap().clone() } else { vec![body] };
                let first = { let mut h = history.lock().await; let first = h.is_empty(); h.push((Instant::now(), rows.clone())); first };
                if first {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    *rejected_at.lock().await = Some(Instant::now());
                }
                let replies = rows.iter().map(|row| if first && row["params"][0] == 0 {
                    json!({"jsonrpc":"2.0","id":row["id"],"error":{"code":-32016,"message":"over rate limit"}})
                } else { json!({"jsonrpc":"2.0","id":row["id"],"result":"0x1"}) }).collect::<Vec<_>>();
                Json(if array { Value::Array(replies) } else { replies[0].clone() })
            }
        }
    }));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, app).await.unwrap();
    });
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        [(Chain::Xlayer, url)].into(),
    );
    let initial = {
        let rpc = rpc.clone();
        tokio::spawn(async move {
            rpc.read_many(
                Chain::Xlayer,
                (0..10)
                    .map(|i| Call::new("eth_estimateGas", vec![json!(i)]))
                    .collect(),
            )
            .await
        })
    };
    while history.lock().await.is_empty() {
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
    let (read, send, health) = tokio::join!(
        rpc.read(
            Chain::Xlayer,
            Call::new("eth_estimateGas", vec![json!("queued")])
        ),
        rpc.broadcast(Chain::Xlayer, "MOCK_ONLY"),
        rpc.latency(Chain::Xlayer),
    );
    initial.await.unwrap().unwrap();
    read.unwrap();
    send.unwrap();
    assert!(health.is_some(), "locally queued health is not an outage");
    let rejected_at = rejected_at.lock().await.unwrap();
    let history = history.lock().await;
    assert_eq!(
        history.iter().map(|(_, rows)| rows.len()).sum::<usize>(),
        14
    );
    assert!(
        history
            .iter()
            .skip(1)
            .all(|(at, _)| *at - rejected_at >= Duration::from_millis(480))
    );
    assert_eq!(
        history
            .iter()
            .flat_map(|(_, rows)| rows)
            .filter(|row| row["method"] == "eth_sendRawTransaction")
            .count(),
        1
    );
    server.abort();
}
