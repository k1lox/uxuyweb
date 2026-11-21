//! All upstreams in these isolation tests are loopback fixtures. No real platform
//! requests, credentials or transaction submissions are used.
use crate::four_gate::FourGate;
use crate::{Integrations, image::Image};
use botai_core::Chain;
use botai_rpc::{Call, Rpc};
use reqwest::Client;
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    task::{JoinHandle, JoinSet},
};

const WALLET: &str = "0x0000000000000000000000000000000000000001";
const TOKEN: &str = "0x0000000000000000000000000000000000000002";

#[derive(Clone, Debug)]
struct Request {
    path: String,
    body: Vec<u8>,
}

#[derive(Clone)]
struct Reply {
    status: u16,
    body: String,
    challenge: bool,
    delay: Duration,
}

impl Reply {
    fn json(status: u16, body: Value) -> Self {
        Self {
            status,
            body: body.to_string(),
            challenge: false,
            delay: Duration::ZERO,
        }
    }

    fn challenge() -> Self {
        Self {
            status: 403,
            body: "<html>challenge fixture</html>".into(),
            challenge: true,
            delay: Duration::ZERO,
        }
    }

    fn delayed(mut self, milliseconds: u64) -> Self {
        self.delay = Duration::from_millis(milliseconds);
        self
    }
}

struct Server {
    url: String,
    requests: Arc<Mutex<Vec<Request>>>,
    task: JoinHandle<()>,
}

impl Server {
    async fn new(handler: impl Fn(&Request) -> Reply + Send + Sync + 'static) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let captured = requests.clone();
        let handler = Arc::new(handler);
        let task = tokio::spawn(async move {
            let mut connections = JoinSet::new();
            loop {
                tokio::select! {
                    accepted = listener.accept() => {
                        let Ok((stream, _)) = accepted else { break };
                        let captured = captured.clone();
                        let handler = handler.clone();
                        connections.spawn(async move {
                            let Some((mut stream, request)) = read_request(stream).await else { return };
                            let reply = handler(&request);
                            captured.lock().unwrap().push(request);
                            tokio::time::sleep(reply.delay).await;
                            let challenge = if reply.challenge { "cf-mitigated: challenge\r\n" } else { "" };
                            let response = format!(
                                "HTTP/1.1 {} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n{}\r\n{}",
                                reply.status, reply.body.len(), challenge, reply.body,
                            );
                            let _ = stream.write_all(response.as_bytes()).await;
                        });
                    }
                    _ = connections.join_next(), if !connections.is_empty() => {}
                }
            }
        });
        Self {
            url,
            requests,
            task,
        }
    }

    async fn scripted(replies: Vec<Reply>) -> Self {
        assert!(!replies.is_empty());
        let last = replies.last().unwrap().clone();
        let queue = Mutex::new(VecDeque::from(replies));
        Self::new(move |_| {
            queue
                .lock()
                .unwrap()
                .pop_front()
                .unwrap_or_else(|| last.clone())
        })
        .await
    }

    fn count(&self) -> usize {
        self.requests.lock().unwrap().len()
    }

    async fn wait_for_count(&self, count: usize) {
        tokio::time::timeout(Duration::from_secs(2), async {
            while self.count() < count {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await
        .expect("fixture did not receive the expected request");
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn read_request(mut stream: TcpStream) -> Option<(TcpStream, Request)> {
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 4096];
    let (head_end, body_len) = loop {
        let read = stream.read(&mut buffer).await.ok()?;
        if read == 0 {
            return None;
        }
        bytes.extend_from_slice(&buffer[..read]);
        if bytes.len() > 100_000 {
            return None;
        }
        if let Some(end) = bytes.windows(4).position(|window| window == b"\r\n\r\n") {
            let head = std::str::from_utf8(&bytes[..end]).ok()?;
            let len = head
                .lines()
                .find_map(|line| {
                    let (key, value) = line.split_once(':')?;
                    key.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            break (end + 4, len);
        }
    };
    while bytes.len() < head_end + body_len {
        let read = stream.read(&mut buffer).await.ok()?;
        if read == 0 {
            return None;
        }
        bytes.extend_from_slice(&buffer[..read]);
        if bytes.len() > 100_000 {
            return None;
        }
    }
    let head = std::str::from_utf8(&bytes[..head_end]).ok()?;
    let path = head.lines().next()?.split_whitespace().nth(1)?.to_owned();
    let body = bytes[head_end..head_end + body_len].to_vec();
    Some((stream, Request { path, body }))
}

fn image() -> Image {
    Image {
        bytes: b"fixture-image".to_vec(),
        mime: "image/png".into(),
        filename: "fixture.png".into(),
    }
}

fn config_ok() -> Value {
    json!({"code":0,"data":[{"symbol":"BNB","status":"PUBLISH"}]})
}

fn integration(server: &Server) -> Integrations {
    integration_with(server, &server.url, 200, 80, 160, 120)
}

fn integration_with(
    server: &Server,
    rpc_url: &str,
    timeout_ms: u64,
    short_ms: u64,
    long_ms: u64,
    cache_ms: u64,
) -> Integrations {
    let http = Client::builder().no_proxy().build().unwrap();
    let rpc = Rpc::with_urls(
        http.clone(),
        [(Chain::Bsc, rpc_url.into())].into_iter().collect(),
    );
    let mut integrations = Integrations::new(http, rpc);
    integrations.four_gate = FourGate::for_test(
        format!("{}/meme-api/v1", server.url),
        Duration::from_millis(timeout_ms),
        Duration::from_millis(short_ms),
        Duration::from_millis(long_ms),
        Duration::from_millis(cache_ms),
    );
    integrations
}

async fn concurrent_config(
    integrations: &Integrations,
    count: usize,
) -> Vec<botai_core::Result<Value>> {
    futures::future::join_all((0..count).map(|_| integrations.four(json!({"action":"config"}))))
        .await
}

#[tokio::test]
async fn simultaneous_challenge_calls_make_one_request_and_share_upload_cooldown() {
    let server = Server::scripted(vec![Reply::challenge().delayed(20)]).await;
    let integrations = integration(&server);
    let results = concurrent_config(&integrations, 6).await;
    assert_eq!(server.count(), 1);
    for result in results {
        let error = result.unwrap_err();
        assert_eq!(error.code, "FOUR_API_CHALLENGED");
        assert!(!error.retryable);
        assert!(
            error
                .data
                .as_ref()
                .and_then(|d| d["retryAfterSeconds"].as_u64())
                .is_some_and(|n| n > 0)
        );
    }
    assert_eq!(integrations.four_status()["state"], "cooldown");
    assert_eq!(integrations.four_status()["available"], false);
    assert!(integrations.four_preflight().is_err());
    let error = integrations
        .four_image(image(), "fixture-access")
        .await
        .unwrap_err();
    assert_eq!(error.code, "FOUR_API_CHALLENGED");
    assert!(!error.retryable);
    assert_eq!(
        server.count(),
        1,
        "upload and status must not bypass the shared gate"
    );
}

#[tokio::test]
async fn cooldown_expires_into_one_probe_and_successful_config_is_coalesced_and_cached() {
    let server = Server::scripted(vec![
        Reply::challenge(),
        Reply::json(200, config_ok()).delayed(20),
    ])
    .await;
    let integrations = integration(&server);
    assert!(integrations.four(json!({"action":"config"})).await.is_err());
    tokio::time::sleep(Duration::from_millis(190)).await;
    for result in concurrent_config(&integrations, 6).await {
        assert_eq!(result.unwrap(), config_ok());
    }
    assert_eq!(
        server.count(),
        2,
        "only one recovery probe can reach the official service"
    );
    assert_eq!(integrations.four_status()["available"], true);
    assert!(integrations.four_preflight().is_ok());
    assert_eq!(
        integrations.four(json!({"action":"config"})).await.unwrap(),
        config_ok()
    );
    assert_eq!(server.count(), 2);
    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(
        integrations.four(json!({"action":"config"})).await.unwrap(),
        config_ok()
    );
    assert_eq!(server.count(), 3, "expired config must be fetched again");
}

#[tokio::test]
async fn network_timeout_starts_short_cooldown_without_retrying() {
    let server = Server::scripted(vec![
        Reply::json(200, config_ok()).delayed(250),
        Reply::json(200, config_ok()),
    ])
    .await;
    let integrations = integration_with(&server, &server.url, 40, 70, 150, 120);
    let error = integrations
        .four(json!({"action":"config"}))
        .await
        .unwrap_err();
    assert_eq!(error.code, "FOUR_API_TIMEOUT");
    assert!(!error.retryable);
    assert_eq!(server.count(), 1);
    assert!(integrations.four(json!({"action":"config"})).await.is_err());
    assert_eq!(server.count(), 1);
    tokio::time::sleep(Duration::from_millis(95)).await;
    assert_eq!(
        integrations.four(json!({"action":"config"})).await.unwrap(),
        config_ok()
    );
    assert_eq!(server.count(), 2);
    tokio::time::sleep(Duration::from_millis(130)).await;
    assert_eq!(
        integrations.four_status()["available"],
        true,
        "an abandoned old response must not corrupt recovered state"
    );
}

#[tokio::test]
async fn server_errors_rate_limits_and_invalid_json_use_short_cooldown() {
    let fixtures = [
        Reply::json(503, json!({"error":"upstream fixture unavailable"})),
        Reply::json(429, json!({"error":"rate fixture"})),
        Reply {
            status: 200,
            body: "not JSON".into(),
            challenge: false,
            delay: Duration::ZERO,
        },
    ];
    for failure in fixtures {
        let server = Server::scripted(vec![failure, Reply::json(200, config_ok())]).await;
        let integrations = integration_with(&server, &server.url, 100, 45, 150, 120);
        let error = integrations
            .four(json!({"action":"config"}))
            .await
            .unwrap_err();
        assert!(!error.retryable);
        assert_eq!(integrations.four_status()["state"], "cooldown");
        assert!(integrations.four_preflight().is_err());
        assert_eq!(server.count(), 1);
        tokio::time::sleep(Duration::from_millis(70)).await;
        assert_eq!(
            integrations.four(json!({"action":"config"})).await.unwrap(),
            config_ok()
        );
        assert_eq!(server.count(), 2);
    }
}

#[tokio::test]
async fn ordinary_forbidden_enters_long_cooldown_but_auth_and_business_errors_do_not() {
    let server = Server::scripted(vec![Reply {
        status: 403,
        body: "Forbidden".into(),
        challenge: false,
        delay: Duration::ZERO,
    }])
    .await;
    let integrations = integration(&server);
    let error = integrations
        .four(json!({"action":"config"}))
        .await
        .unwrap_err();
    assert_eq!(error.code, "FOUR_API_FORBIDDEN");
    assert!(!error.retryable);
    tokio::time::sleep(Duration::from_millis(95)).await;
    assert!(
        integrations.four_preflight().is_err(),
        "ordinary 403 must not use the shorter outage cooldown"
    );
    assert_eq!(server.count(), 1);

    for status in [200, 401, 403] {
        let business = json!({"code":40101,"msg":"fixture login expired"});
        let server = Server::scripted(vec![
            Reply::json(status, business.clone()),
            Reply::json(200, config_ok()),
        ])
        .await;
        let integrations = integration(&server);
        let result = integrations
            .four(json!({"action":"login","payload":{"address":WALLET}}))
            .await;
        if status == 200 {
            assert_eq!(result.unwrap(), business);
        } else if let Err(error) = result {
            assert!(!error.retryable);
        }
        assert!(
            integrations.four_preflight().is_ok(),
            "business/auth errors are local to the request"
        );
        assert_ne!(integrations.four_status()["state"], "cooldown");
        assert_eq!(
            integrations.four(json!({"action":"config"})).await.unwrap(),
            config_ok()
        );
        assert_eq!(server.count(), 2);
    }
}

#[tokio::test]
async fn unsuccessful_or_malformed_config_is_never_stored_as_success() {
    let business = json!({"code":1001,"msg":"fixture config denied"});
    let server = Server::scripted(vec![
        Reply::json(200, business.clone()),
        Reply::json(200, business.clone()),
    ])
    .await;
    let integrations = integration(&server);
    for _ in 0..2 {
        assert_eq!(
            integrations.four(json!({"action":"config"})).await.unwrap(),
            business
        );
    }
    assert_eq!(server.count(), 2);
    assert!(integrations.four_preflight().is_ok());

    let malformed = json!({"code":0,"data":{"not":"an array"}});
    let server = Server::scripted(vec![
        Reply::json(200, malformed),
        Reply::json(200, config_ok()),
    ])
    .await;
    let integrations = integration_with(&server, &server.url, 100, 45, 150, 120);
    let first = integrations.four(json!({"action":"config"})).await;
    if let Err(error) = first {
        assert!(!error.retryable);
    }
    tokio::time::sleep(Duration::from_millis(70)).await;
    assert_eq!(
        integrations.four(json!({"action":"config"})).await.unwrap(),
        config_ok()
    );
    assert_eq!(server.count(), 2);
}

#[tokio::test]
async fn string_zero_config_success_is_cached() {
    let value = json!({"code":"0","data":[]});
    let server = Server::scripted(vec![Reply::json(200, value.clone())]).await;
    let integrations = integration(&server);
    for result in concurrent_config(&integrations, 4).await {
        assert_eq!(result.unwrap(), value);
    }
    assert_eq!(server.count(), 1);
}

#[tokio::test]
async fn private_actions_and_uploads_are_never_cached_or_replayed() {
    let server = Server::scripted(vec![Reply::json(
        200,
        json!({"code":0,"data":"fixture-result"}),
    )])
    .await;
    let integrations = integration(&server);
    for _ in 0..2 {
        integrations
            .four(json!({"action":"nonce","address":WALLET}))
            .await
            .unwrap();
        integrations
            .four(json!({"action":"login","payload":{"address":WALLET}}))
            .await
            .unwrap();
        integrations.four(json!({"action":"create","accessToken":"fixture-access","payload":{"name":"fixture"}})).await.unwrap();
        integrations
            .four_image(image(), "fixture-access")
            .await
            .unwrap();
        integrations
            .four(json!({"action":"tokenDetail","address":TOKEN}))
            .await
            .unwrap();
    }
    let requests = server.requests.lock().unwrap();
    assert_eq!(requests.len(), 10);
    for path in [
        "/private/user/nonce/generate",
        "/private/user/login/dex",
        "/private/token/create",
        "/private/token/upload",
        "/private/token/get/v2",
    ] {
        assert_eq!(
            requests
                .iter()
                .filter(|r| r.path.starts_with(&format!("/meme-api/v1{path}")))
                .count(),
            2,
            "{path}"
        );
    }
    drop(requests);

    let server = Server::scripted(vec![Reply::json(503, json!({"error":"fixture"}))]).await;
    let integrations = integration(&server);
    let error = integrations
        .four(
            json!({"action":"create","accessToken":"fixture-access","payload":{"name":"fixture"}}),
        )
        .await
        .unwrap_err();
    assert!(!error.retryable);
    assert_eq!(
        server.count(),
        1,
        "create must never replay an unknown result"
    );
}

#[tokio::test]
async fn upload_failure_blocks_json_actions_through_the_same_gate() {
    let server = Server::scripted(vec![Reply::challenge()]).await;
    let integrations = integration(&server);
    let error = integrations
        .four_image(image(), "fixture-access")
        .await
        .unwrap_err();
    assert_eq!(error.code, "FOUR_API_CHALLENGED");
    assert!(
        integrations
            .four(json!({"action":"nonce","address":WALLET}))
            .await
            .is_err()
    );
    assert!(integrations.four_preflight().is_err());
    assert_eq!(server.count(), 1);
}

#[tokio::test]
async fn canceled_request_releases_the_lane_and_cannot_overwrite_a_later_failure() {
    let server = Server::scripted(vec![
        Reply::json(200, config_ok()).delayed(250),
        Reply::challenge(),
    ])
    .await;
    let integrations = integration_with(&server, &server.url, 500, 80, 500, 120);
    let clone = integrations.clone();
    let first = tokio::spawn(async move { clone.four(json!({"action":"config"})).await });
    server.wait_for_count(1).await;
    first.abort();
    let _ = first.await;
    let error = tokio::time::timeout(
        Duration::from_millis(150),
        integrations.four(json!({"action":"config"})),
    )
    .await
    .expect("cancellation left the Four lane locked")
    .unwrap_err();
    assert_eq!(error.code, "FOUR_API_CHALLENGED");
    assert_eq!(server.count(), 2);
    tokio::time::sleep(Duration::from_millis(270)).await;
    assert!(integrations.four_preflight().is_err());
    assert_eq!(integrations.four_status()["state"], "cooldown");
}

#[tokio::test]
async fn cooldown_does_not_affect_rpc_prediction_or_other_official_http() {
    let four = Server::scripted(vec![Reply::challenge()]).await;
    let rpc = Server::new(|request| {
        let request: Value = serde_json::from_slice(&request.body).unwrap();
        let respond = |row: &Value| {
            let result = match row["method"].as_str().unwrap_or("") {
                "debug_traceCall" => json!({"type":"CALL","calls":[{"type":"CREATE2","to":TOKEN}]}),
                _ => json!("0x64"),
            };
            json!({"jsonrpc":"2.0","id":row["id"],"result":result})
        };
        Reply::json(
            200,
            match request.as_array() {
                Some(rows) => json!(rows.iter().map(respond).collect::<Vec<_>>()),
                None => respond(&request),
            },
        )
    })
    .await;
    let other = Server::scripted(vec![Reply::json(
        200,
        json!({"ok":true,"fixture":"other-platform"}),
    )])
    .await;
    let integrations = integration_with(&four, &rpc.url, 200, 80, 1000, 120);
    assert!(integrations.four(json!({"action":"config"})).await.is_err());
    assert_eq!(
        integrations
            .rpc
            .read(Chain::Bsc, Call::new("eth_blockNumber", vec![]))
            .await
            .unwrap(),
        json!("0x64")
    );
    let predicted = integrations.four(json!({"action":"predictTokenAddress","from":WALLET,"createCalldata":"0x519ebb10","value":"0"})).await.unwrap();
    assert_eq!(predicted["tokenAddress"], TOKEN);
    let response = integrations.http.get(&other.url).send().await.unwrap();
    assert_eq!(
        crate::bounded_json(response, "Flap", 1000).await.unwrap()["fixture"],
        "other-platform"
    );
    assert_eq!(four.count(), 1);
    assert!(rpc.count() > 0);
    assert_eq!(other.count(), 1);
    assert!(integrations.four_preflight().is_err());
}

#[tokio::test]
async fn a_new_fault_invalidates_cached_config_and_requires_a_real_recovery_probe() {
    let recovered = json!({"code":0,"data":[{"symbol":"RECOVERED","status":"PUBLISH"}]});
    let server = Server::scripted(vec![
        Reply::json(200, config_ok()),
        Reply::challenge(),
        Reply::json(200, recovered.clone()),
    ])
    .await;
    let integrations = integration_with(&server, &server.url, 100, 40, 80, 1000);
    assert_eq!(
        integrations.four(json!({"action":"config"})).await.unwrap(),
        config_ok()
    );
    assert!(
        integrations
            .four(json!({"action":"tokenDetail","address":TOKEN}))
            .await
            .is_err()
    );
    let error = integrations
        .four(json!({"action":"config"}))
        .await
        .unwrap_err();
    assert_eq!(error.code, "FOUR_API_CHALLENGED");
    assert_eq!(
        server.count(),
        2,
        "cached config cannot hide the new failure"
    );
    tokio::time::sleep(Duration::from_millis(105)).await;
    assert_eq!(integrations.four_status()["state"], "probe_required");
    assert_eq!(
        integrations.four(json!({"action":"config"})).await.unwrap(),
        recovered
    );
    assert_eq!(
        server.count(),
        3,
        "recovery cannot reuse a pre-failure cached response"
    );
}

#[tokio::test]
async fn excess_concurrent_private_requests_are_rejected_without_queue_growth() {
    let server = Server::scripted(vec![
        Reply::json(200, json!({"code":0,"data":"fixture"})).delayed(15),
    ])
    .await;
    let integrations = integration_with(&server, &server.url, 500, 80, 160, 120);
    let results = futures::future::join_all(
        (0..20).map(|_| integrations.four(json!({"action":"nonce","address":WALLET}))),
    )
    .await;
    let successful = results.iter().filter(|result| result.is_ok()).count();
    assert_eq!(
        successful, 9,
        "one active request and eight waiters should be admitted"
    );
    assert_eq!(server.count(), 9);
    for error in results.into_iter().filter_map(Result::err) {
        assert_eq!(error.code, "FOUR_API_BUSY");
        assert!(!error.retryable);
    }
    assert!(
        integrations.four_preflight().is_ok(),
        "local overload does not poison upstream availability"
    );
}

#[tokio::test]
async fn upload_body_slots_are_bounded_released_on_drop_and_blocked_during_cooldown() {
    let server = Server::scripted(vec![Reply::challenge()]).await;
    let integrations = integration(&server);
    let first = integrations.four_upload_slot().unwrap();
    let second = integrations.four_upload_slot().unwrap();
    let error = integrations.four_upload_slot().unwrap_err();
    assert_eq!(error.code, "FOUR_API_BUSY");
    assert!(!error.retryable);
    drop(first);
    let replacement = integrations.four_upload_slot().unwrap();
    drop(second);
    drop(replacement);
    assert!(integrations.four(json!({"action":"config"})).await.is_err());
    let error = integrations.four_upload_slot().unwrap_err();
    assert_eq!(error.code, "FOUR_API_CHALLENGED");
    assert_eq!(
        server.count(),
        1,
        "body preflight must not trigger another official request"
    );
}

#[tokio::test]
async fn business_codes_without_message_do_not_cool_down_or_cache() {
    let value = json!({"code":1001});
    let server = Server::scripted(vec![Reply::json(200, value.clone())]).await;
    let integrations = integration(&server);
    for _ in 0..2 {
        assert_eq!(
            integrations.four(json!({"action":"config"})).await.unwrap(),
            value
        );
        assert!(integrations.four_preflight().is_ok());
    }
    assert_eq!(server.count(), 2);
}

#[tokio::test]
async fn invalid_header_values_are_rejected_before_upstream_or_availability_changes() {
    let server = Server::scripted(vec![Reply::json(200, config_ok())]).await;
    let integrations = integration(&server);
    assert_eq!(integrations.four_status()["state"], "unknown");
    for token in ["fixture\0access", "fixture\naccess", "fixture\raccess"] {
        let create = integrations
            .four(json!({"action":"create","accessToken":token,"payload":{"name":"fixture"}}))
            .await
            .unwrap_err();
        assert_eq!(create.code, "INVALID_INPUT");
        assert!(!create.retryable);
        let upload = integrations.four_image(image(), token).await.unwrap_err();
        assert_eq!(upload.code, "INVALID_INPUT");
        assert!(!upload.retryable);
        assert_eq!(server.count(), 0);
        assert_eq!(integrations.four_status()["state"], "unknown");
        assert!(integrations.four_preflight().is_ok());
    }
    // A RequestBuilder can carry a construction error before any HTTP request is
    // sent. That local caller error must not be mistaken for an upstream outage.
    let request = integrations
        .four_gate
        .post("/private/token/create")
        .header("x-fixture", "bad\0header")
        .json(&json!({"name":"fixture"}));
    let error = integrations
        .four_gate
        .request(request, false, 1000)
        .await
        .unwrap_err();
    assert_eq!(error.code, "INVALID_INPUT");
    assert!(!error.retryable);
    assert_eq!(server.count(), 0);
    assert_eq!(integrations.four_status()["state"], "unknown");
    assert_eq!(integrations.four_status()["available"], false);
    assert!(integrations.four_preflight().is_ok());
    assert_eq!(
        integrations.four(json!({"action":"config"})).await.unwrap(),
        config_ok()
    );
    assert_eq!(server.count(), 1);
    assert_eq!(integrations.four_status()["available"], true);
}

#[tokio::test]
async fn json_body_slots_are_independent_cancel_safe_and_available_during_cooldown() {
    let server = Server::scripted(vec![Reply::challenge()]).await;
    let integrations = integration_with(&server, &server.url, 200, 80, 1000, 120);
    let upload_first = integrations.four_upload_slot().unwrap();
    let upload_second = integrations.four_upload_slot().unwrap();
    let json_first = integrations.four_json_slot().unwrap();
    let json_second = integrations.four_json_slot().unwrap();
    let error = integrations.four_json_slot().unwrap_err();
    assert_eq!(error.code, "FOUR_API_BUSY");
    assert!(!error.retryable);
    assert_eq!(integrations.four_status()["state"], "unknown");
    drop(json_first);
    let replacement = integrations.four_json_slot().unwrap();
    // Upload and JSON body capacities are independent from each other.
    assert_eq!(
        integrations.four_upload_slot().unwrap_err().code,
        "FOUR_API_BUSY"
    );
    drop(json_second);
    drop(replacement);
    drop(upload_first);
    drop(upload_second);

    assert!(integrations.four(json!({"action":"config"})).await.is_err());
    assert_eq!(integrations.four_status()["state"], "cooldown");
    let clone = integrations.clone();
    let (started, entered) = tokio::sync::oneshot::channel();
    let holding = tokio::spawn(async move {
        let _permit = clone.four_json_slot().unwrap();
        started.send(()).unwrap();
        std::future::pending::<()>().await;
    });
    entered.await.unwrap();
    let another = integrations.four_json_slot().unwrap();
    assert_eq!(
        integrations.four_json_slot().unwrap_err().code,
        "FOUR_API_BUSY"
    );
    holding.abort();
    assert!(holding.await.unwrap_err().is_cancelled());
    let released = integrations.four_json_slot().unwrap();
    assert_eq!(integrations.four_status()["state"], "cooldown");
    assert_eq!(integrations.four_status()["available"], false);
    assert_eq!(
        integrations.four_upload_slot().unwrap_err().code,
        "FOUR_API_CHALLENGED"
    );
    assert_eq!(
        server.count(),
        1,
        "body admission is local and cannot probe upstream"
    );
    drop(another);
    drop(released);
}
