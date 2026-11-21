use super::*;
use axum::{
    Json, Router,
    extract::{Path, State},
    routing::post,
};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use tempfile::TempDir;

fn config() -> Config {
    Config {
        token: "12345:TEST_ONLY".into(),
        chat_id: "-1001".into(),
        sender_id: "2002".into(),
        access_key: "123456".into(),
        push_contact: "mailto:test@example.com".into(),
    }
}

pub(crate) fn update(id: u64) -> Value {
    let text = "[示例] - BSC\n🟢买 1.25 UUSD 20K [示例币🖖🏻] $0.01 市值 $100K";
    let offset = text[..text.find("示例币").unwrap()].encode_utf16().count();
    json!({"update_id":id,"message":{"message_id":id,"date":now()/1000,
        "chat":{"id":-1001i64},"from":{"id":2002u64,"is_bot":true},"text":text,
        "entities":[{"type":"text_link","offset":1,"length":2,"url":"https://gmgn.ai/bsc/address/fixture_0x00000000000000000000000000000000000000aa"},
        {"type":"text_link","offset":offset,"length":"示例币🖖🏻".encode_utf16().count(),"url":"https://gmgn.ai/bsc/token/fixture_0x00000000000000000000000000000000000000bb"}]}})
}
pub(crate) fn subscription(endpoint: &str) -> Value {
    let secret = p256::SecretKey::random(&mut rand::rngs::OsRng);
    json!({"endpoint":endpoint,"keys":{"p256dh":URL_SAFE_NO_PAD.encode(secret.public_key().to_encoded_point(false).as_bytes()),"auth":URL_SAFE_NO_PAD.encode([1u8;16])}})
}
#[test]
fn only_expected_bsc_bot_trades_and_utf16_labels_survive() {
    let original = update(1);
    let c = config();
    let normalized = parser::normalize(&original, &c.chat_id, &c.sender_id, 123).unwrap();
    assert_eq!(normalized.trade.token_name, "示例币");
    assert_eq!(normalized.trade.wallet_name, "示例");
    assert_eq!(normalized.trade.amount, "1.25");
    assert!(!serde_json::to_string(&normalized).unwrap().contains("市值"));
    for pointer in ["/message/chat/id", "/message/from/id"] {
        let mut changed = original.clone();
        *changed.pointer_mut(pointer).unwrap() = json!(999);
        assert!(parser::normalize(&changed, &c.chat_id, &c.sender_id, 0).is_none());
    }
    let mut changed = original.clone();
    changed["message"]["from"]["is_bot"] = json!(false);
    assert!(parser::normalize(&changed, &c.chat_id, &c.sender_id, 0).is_none());
    changed = original.clone();
    changed["message"]["text"] = json!(
        original["message"]["text"]
            .as_str()
            .unwrap()
            .replace("BSC", "SOL")
    );
    assert!(parser::normalize(&changed, &c.chat_id, &c.sender_id, 0).is_none());
    let mut caption = original["message"].clone();
    caption["caption"] = caption.as_object_mut().unwrap().remove("text").unwrap();
    caption["caption_entities"] = caption.as_object_mut().unwrap().remove("entities").unwrap();
    let edit = parser::normalize(
        &json!({"update_id":2,"edited_message":caption}),
        &c.chat_id,
        &c.sender_id,
        0,
    )
    .unwrap();
    assert!(edit.edited);
    assert_eq!(edit.trade.token_name, normalized.trade.token_name);
}

#[test]
fn subscriptions_reject_foreign_hosts_and_invalid_curve_keys() {
    for url in [
        "https://web.push.apple.com/abc",
        "https://fcm.googleapis.com/fcm/send/abc",
        "https://updates.push.services.mozilla.com/push/v1/abc",
    ] {
        assert!(store::subscription(subscription(url)).is_ok());
    }
    for url in [
        "http://web.push.apple.com/abc",
        "https://web.push.apple.com.evil.test/a",
        "https://evil.test/a",
        "https://user@web.push.apple.com/a",
        "https://web.push.apple.com/",
        "https://web.push.apple.com/a#fragment",
        "https://127.0.0.1/private",
    ] {
        assert!(store::subscription(subscription(url)).is_err(), "{url}");
    }
    let mut invalid = subscription("https://web.push.apple.com/abc");
    let mut key = [0u8; 65];
    key[0] = 4;
    invalid["keys"]["p256dh"] = json!(URL_SAFE_NO_PAD.encode(key));
    assert!(store::subscription(invalid).is_err());
}

#[test]
fn restart_preserves_vapid_device_and_offset_and_config_change_revokes_devices() {
    let directory = TempDir::new().unwrap();
    let path = directory.path().join("monitor.sqlite");
    let db = store::Store::open(&path, "config-a").unwrap();
    let keys = db.keys().unwrap();
    let s = store::subscription(subscription("https://web.push.apple.com/a")).unwrap();
    let token = db.subscribe(s.clone(), None, 100).unwrap();
    assert!(store::token_valid(&token));
    assert!(
        db.subscribe(s.clone(), None, 100).is_err(),
        "endpoint cannot be stolen"
    );
    assert_eq!(db.subscribe(s, Some(&token), 200).unwrap(), token);
    db.set("offset", "123").unwrap();
    drop(db);
    let db = store::Store::open(&path, "config-a").unwrap();
    assert_eq!(db.keys().unwrap(), keys);
    assert_eq!(db.device(&token).unwrap().unwrap().since, 200);
    assert_eq!(db.setting("offset").unwrap().as_deref(), Some("123"));
    assert!(
        !std::fs::read(&path)
            .unwrap()
            .windows(token.len())
            .any(|w| w == token.as_bytes()),
        "only hashed device credentials persist"
    );
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    drop(db);
    let db = store::Store::open(&path, "config-b").unwrap();
    assert!(db.devices().unwrap().is_empty());
    assert!(db.setting("offset").unwrap().is_none());
    assert_eq!(db.keys().unwrap(), keys);
}

#[derive(Clone, Default)]
struct Mock {
    calls: Arc<Mutex<Vec<(String, Value)>>>,
    replies: Arc<Mutex<VecDeque<Value>>>,
    failure: Arc<AtomicUsize>,
}
async fn telegram_mock(
    State(mock): State<Mock>,
    Path(method): Path<String>,
    Json(params): Json<Value>,
) -> Json<Value> {
    mock.calls.lock().await.push((method.clone(), params));
    let code = mock.failure.load(Ordering::SeqCst);
    if code > 0 {
        return Json(
            json!({"ok":false,"error_code":code,"description":"12345:TEST_ONLY","parameters":{"retry_after":1}}),
        );
    }
    if method == "getWebhookInfo" {
        return Json(json!({"ok":true,"result":{"url":""}}));
    }
    if let Some(value) = mock.replies.lock().await.pop_front() {
        return Json(json!({"ok":true,"result":value}));
    }
    std::future::pending().await
}
async fn setup() -> (Monitor, Mock, TempDir, tokio::task::JoinHandle<()>) {
    let mock = Mock::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}", listener.local_addr().unwrap());
    let app = Router::new()
        .route("/bot12345:TEST_ONLY/{method}", post(telegram_mock))
        .with_state(mock.clone());
    let server = tokio::spawn(async { axum::serve(listener, app).await.unwrap() });
    let directory = TempDir::new().unwrap();
    let monitor = Monitor::with_transport(
        config(),
        reqwest::Client::builder()
            .no_proxy()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .unwrap(),
        directory.path().join("monitor.sqlite"),
        base,
    )
    .unwrap();
    (monitor, mock, directory, server)
}
async fn until(mut condition: impl AsyncFnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(3), async {
        while !condition().await {
            tokio::time::sleep(Duration::from_millis(5)).await
        }
    })
    .await
    .unwrap();
}
#[tokio::test]
async fn shared_polling_cancels_on_last_viewer_and_restarts_without_races() {
    let (monitor, mock, _directory, server) = setup().await;
    let first = monitor.subscribe().await.unwrap();
    let second = monitor.subscribe().await.unwrap();
    until(async || mock.calls.lock().await.len() == 2).await;
    assert_eq!(
        mock.calls
            .lock()
            .await
            .iter()
            .filter(|(m, _)| m == "getWebhookInfo")
            .count(),
        1
    );
    drop(first);
    assert!(monitor.inner.running.load(Ordering::SeqCst));
    drop(second);
    let reopened = monitor.subscribe().await.unwrap();
    until(async || {
        mock.calls
            .lock()
            .await
            .iter()
            .filter(|(m, _)| m == "getUpdates")
            .count()
            >= 2
    })
    .await;
    drop(reopened);
    until(async || !monitor.inner.running.load(Ordering::SeqCst)).await;
    assert_eq!(monitor.inner.viewers.load(Ordering::SeqCst), 0);
    server.abort();
}
#[tokio::test]
async fn duplicate_edits_unrelated_updates_and_restart_advance_offset() {
    let (monitor, _mock, _directory, server) = setup().await;
    let first = update(1);
    let mut edited = first["message"].clone();
    edited["entities"][1]["length"] = json!(3);
    let mut unrelated = update(3);
    unrelated["message"]["chat"]["id"] = json!(-1);
    monitor
        .accept_updates(
            &json!([first.clone(),first.clone(),{"update_id":2,"edited_message":edited},unrelated]),
        )
        .await
        .unwrap();
    monitor.accept_updates(&json!([first])).await.unwrap();
    assert_eq!(monitor.inner.messages.lock().await.len(), 1);
    assert!(monitor.inner.messages.lock().await[0].edited);
    assert_eq!(*monitor.inner.offset.lock().await, Some(4));
    assert_eq!(
        monitor.inner.store.setting("offset").unwrap().as_deref(),
        Some("4")
    );
    server.abort();
}
#[tokio::test]
async fn permanent_telegram_failure_stops_without_secret_or_hot_retry() {
    let (monitor, mock, _directory, server) = setup().await;
    for code in [401, 403, 409, 400, 429, 502] {
        mock.failure.store(code, Ordering::SeqCst);
        let error = monitor.telegram("getUpdates", json!({})).await.unwrap_err();
        assert_eq!(error.retryable, code == 429 || code >= 500);
        assert!(!error.message.contains("TEST_ONLY"));
    }
    mock.calls.lock().await.clear();
    mock.failure.store(409, Ordering::SeqCst);
    let subscription = monitor.subscribe().await.unwrap();
    until(async || !monitor.inner.running.load(Ordering::SeqCst)).await;
    assert_eq!(monitor.inner.status.lock().await["phase"], "error");
    assert_eq!(mock.calls.lock().await.len(), 1);
    drop(subscription);
    server.abort();
}
#[tokio::test]
async fn wrong_access_code_is_bounded_per_client_without_network() {
    let (monitor, mock, _directory, server) = setup().await;
    for _ in 0..5 {
        assert_eq!(
            monitor.authorize("wrong", "a").await.unwrap_err().status,
            401
        )
    }
    assert_eq!(
        monitor.authorize("123456", "a").await.unwrap_err().status,
        429
    );
    monitor.authorize("123456", "b").await.unwrap();
    monitor
        .inner
        .attempts
        .lock()
        .await
        .insert("a".into(), (5, 0));
    monitor.authorize("123456", "a").await.unwrap();
    assert!(mock.calls.lock().await.is_empty());
    server.abort();
}
