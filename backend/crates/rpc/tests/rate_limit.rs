use axum::{Json, Router, extract::State, routing::post};
use botai_core::Chain;
use botai_rpc::{Call, Rpc};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::sync::Mutex;

#[tokio::test]
async fn exhausted_limit_returns_request_local_successes_for_failed_only_resume() {
    let history = Arc::new(Mutex::new(Vec::<Value>::new()));
    let app = Router::new().route("/", post(|State(history): State<Arc<Mutex<Vec<Value>>>>, Json(rows): Json<Vec<Value>>| async move {
        let mut seen = history.lock().await;
        Json(json!(rows.iter().map(|r| {
            seen.push(r["params"][0].clone());
            if r["params"][0] == 1 && seen.iter().filter(|v| **v == 1).count() <= 3 {
                json!({"jsonrpc":"2.0","id":r["id"],"error":{"code":-32016,"message":"over rate limit"}})
            } else {json!({"jsonrpc":"2.0","id":r["id"],"result":r["params"][0]})}
        }).collect::<Vec<_>>()))
    })).with_state(history.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(axum::serve(listener, app).into_future());
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        [(Chain::Xlayer, url)].into(),
    );
    let error = rpc
        .read_many(
            Chain::Xlayer,
            vec![
                Call::new("eth_getCode", vec![json!(1)]),
                Call::new("eth_getCode", vec![json!(2)]),
            ],
        )
        .await
        .unwrap_err();
    assert_eq!(error.code, "RPC_RATE_LIMIT");
    assert_eq!(
        error.data,
        Some(json!({"rpcResults":[{"ok":false},{"ok":true,"result":2}]}))
    );
    assert_eq!(
        rpc.read_many(
            Chain::Xlayer,
            vec![Call::new("eth_getCode", vec![json!(1)])]
        )
        .await
        .unwrap(),
        vec![json!(1)]
    );
    assert_eq!(history.lock().await.iter().filter(|v| **v == 2).count(), 1);
    server.abort();
}

#[tokio::test]
async fn public_reads_retain_six_healthy_lanes_and_restore_input_order() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let active = Arc::new(AtomicUsize::new(0));
    let maximum = Arc::new(AtomicUsize::new(0));
    let release = Arc::new(tokio::sync::Semaphore::new(0));
    let app = Router::new().route(
        "/",
        post({
            let active = active.clone();
            let maximum = maximum.clone();
            let release = release.clone();
            move |Json(rows): Json<Vec<Value>>| {
                let active = active.clone();
                let maximum = maximum.clone();
                let release = release.clone();
                async move {
                    let current = active.fetch_add(1, Ordering::SeqCst) + 1;
                    maximum.fetch_max(current, Ordering::SeqCst);
                    release.acquire().await.unwrap().forget();
                    tokio::time::sleep(std::time::Duration::from_millis(60)).await;
                    active.fetch_sub(1, Ordering::SeqCst);
                    Json(json!(
                        rows.iter()
                            .rev()
                            .map(|r| json!({"jsonrpc":"2.0","id":r["id"],"result":r["params"][0]}))
                            .collect::<Vec<_>>()
                    ))
                }
            }
        }),
    );
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(axum::serve(listener, app).into_future());
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        [(Chain::Xlayer, url)].into(),
    );
    // Six small healthy HTTP batches fit within the shared 40-item window.
    // Six ten-item batches would now correctly be paced instead.
    let mut small = Vec::new();
    for n in 1000..1006 {
        let rpc = rpc.clone();
        small.push(tokio::spawn(async move {
            rpc.read(Chain::Xlayer, Call::new("eth_getCode", vec![json!(n)]))
                .await
        }));
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while active.load(Ordering::SeqCst) < n - 999 {
                tokio::time::sleep(std::time::Duration::from_millis(2)).await;
            }
        })
        .await
        .unwrap();
    }
    release.add_permits(256);
    for task in small {
        task.await.unwrap().unwrap();
    }
    let result = rpc
        .read_many(
            Chain::Xlayer,
            (0..114)
                .map(|n| Call::new("eth_getCode", vec![json!(n)]))
                .collect(),
        )
        .await
        .unwrap();
    assert_eq!(result, (0..114).map(|n| json!(n)).collect::<Vec<_>>());
    assert_eq!(maximum.load(Ordering::SeqCst), 6);
    server.abort();
}

#[tokio::test]
async fn partial_rate_limit_retries_only_failed_item_and_exposes_degraded_health() {
    let history = Arc::new(Mutex::new(Vec::<Vec<Value>>::new()));
    let app = Router::new().route("/",post(|State(history):State<Arc<Mutex<Vec<Vec<Value>>>>>,Json(rows):Json<Vec<Value>>|async move {
        let mut log=history.lock().await;
        let first=log.is_empty(); log.push(rows.clone());
        Json(Value::Array(rows.iter().map(|r|if first && r["params"][0]==1 {
            json!({"jsonrpc":"2.0","id":r["id"],"error":{"code":-32016,"message":"over rate limit"}})
        }else{json!({"jsonrpc":"2.0","id":r["id"],"result":r["params"][0]})}).collect()))
    })).with_state(history.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(axum::serve(listener, app).into_future());
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        [(Chain::Xlayer, url)].into(),
    );
    let result = rpc
        .read_many(
            Chain::Xlayer,
            vec![
                Call::new("eth_getCode", vec![json!(1)]),
                Call::new("eth_getCode", vec![json!(2)]),
            ],
        )
        .await
        .unwrap();
    assert_eq!(result, vec![json!(1), json!(2)]);
    assert!(rpc.rate_limited(Chain::Xlayer).await);
    assert!(rpc.latency(Chain::Xlayer).await.is_none());
    let log = history.lock().await;
    assert_eq!(log.len(), 2);
    assert_eq!(log[0].len(), 2);
    assert_eq!(log[1].len(), 1);
    assert_eq!(log[1][0]["params"][0], 1);
    server.abort();
}

#[tokio::test]
async fn single_object_batch_limit_is_retried_as_smaller_batches_not_generic_outage() {
    let history = Arc::new(Mutex::new(Vec::<usize>::new()));
    let app=Router::new().route("/",post(|State(history):State<Arc<Mutex<Vec<usize>>>>,Json(rows):Json<Vec<Value>>|async move {
        let mut log=history.lock().await; let first=log.is_empty(); log.push(rows.len());
        Json(if first {json!({"jsonrpc":"2.0","id":null,"error":{"code":-32016,"message":"over rate limit"}})} else {
            json!(rows.iter().map(|r|json!({"jsonrpc":"2.0","id":r["id"],"result":r["params"][0]})).collect::<Vec<_>>())
        })
    })).with_state(history.clone());
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(axum::serve(listener, app).into_future());
    let rpc = Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        [(Chain::Xlayer, url)].into(),
    );
    let result = rpc
        .read_many(
            Chain::Xlayer,
            (0..3)
                .map(|n| Call::new("eth_getCode", vec![json!(n)]))
                .collect(),
        )
        .await
        .unwrap();
    assert_eq!(result, vec![json!(0), json!(1), json!(2)]);
    assert_eq!(*history.lock().await, vec![3, 2, 1]);
    server.abort();
}
