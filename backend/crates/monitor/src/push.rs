use crate::{
    now,
    parser::Message,
    store::{Device, Store},
};
use botai_core::{AppError, Result};
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, HashSet, VecDeque},
    sync::Arc,
    time::Duration,
};
use tokio::sync::{Mutex, Notify};
use web_push::{ContentEncoding, Urgency, VapidSignatureBuilder, WebPushMessageBuilder};

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Payload {
    pub id: String,
    pub title: String,
    pub body: String,
    pub expires_at: u64,
}
#[derive(Clone)]
struct Job {
    device: Device,
    payload: Payload,
}
#[derive(Clone)]
pub struct Delivery {
    inner: Arc<DeliveryState>,
}
struct DeliveryState {
    store: Store,
    push_contact: String,
    http: reqwest::Client,
    queue: Arc<Mutex<BTreeMap<String, Job>>>,
    wake: Arc<Notify>,
    seen: Arc<Mutex<(HashSet<String>, VecDeque<String>)>>,
}
impl Drop for DeliveryState {
    fn drop(&mut self) {
        self.wake.notify_waiters();
    }
}
impl Delivery {
    pub fn new(store: Store, http: reqwest::Client, push_contact: String) -> Self {
        Self {
            inner: Arc::new(DeliveryState {
                store,
                push_contact,
                http,
                queue: Arc::new(Mutex::new(BTreeMap::new())),
                wake: Arc::new(Notify::new()),
                seen: Arc::new(Mutex::new((HashSet::new(), VecDeque::new()))),
            }),
        }
    }
    pub fn start(&self) {
        for _ in 0..4 {
            let weak = Arc::downgrade(&self.inner);
            let wake = self.inner.wake.clone();
            tokio::spawn(async move {
                loop {
                    let notified = wake.notified();
                    tokio::pin!(notified);
                    notified.as_mut().enable();
                    let Some(inner) = weak.upgrade() else { break };
                    let service = Self { inner };
                    let job = service.inner.queue.lock().await.pop_first().map(|(_, j)| j);
                    if let Some(job) = job {
                        let _ = service.deliver(job).await;
                    } else {
                        drop(service);
                        notified.await;
                    }
                }
            });
        }
    }
    pub async fn accept(&self, message: &Message) -> Result<()> {
        if message.edited {
            return Ok(());
        }
        let mut seen = self.inner.seen.lock().await;
        if !seen.0.insert(message.id.clone()) {
            return Ok(());
        }
        seen.1.push_back(message.id.clone());
        if seen.1.len() > 1000 {
            if let Some(id) = seen.1.pop_front() {
                seen.0.remove(&id);
            }
        }
        drop(seen);
        let expires = message.sent_at.saturating_add(30000);
        if expires <= now() || message.sent_at > now() + 5000 {
            return Ok(());
        }
        let t = &message.trade;
        let payload = Payload {
            id: message.id.clone(),
            title: format!(
                "{} {} {}",
                t.wallet_name.chars().take(50).collect::<String>(),
                if t.side == "buy" { "买入" } else { "卖出" },
                t.token_name.chars().take(50).collect::<String>()
            ),
            body: format!("{} {} · BSC", t.amount, t.currency),
            expires_at: expires,
        };
        let mut queue = self.inner.queue.lock().await;
        for device in self
            .inner
            .store
            .devices()?
            .into_iter()
            .filter(|d| d.since <= message.sent_at)
        {
            let key = format!(
                "{}:{}:{}:{}",
                device.token_hash, t.wallet_address, t.token_address, t.side
            );
            if queue.len() >= 512 && !queue.contains_key(&key) {
                if let Some(oldest) = queue
                    .iter()
                    .min_by_key(|(_, j)| j.payload.expires_at)
                    .map(|(k, _)| k.clone())
                {
                    queue.remove(&oldest);
                }
            }
            queue.insert(
                key,
                Job {
                    device,
                    payload: payload.clone(),
                },
            );
        }
        drop(queue);
        self.inner.wake.notify_waiters();
        Ok(())
    }
    async fn send(
        &self,
        device: &Device,
        payload: &Payload,
    ) -> std::result::Result<(), (u16, u64)> {
        let ttl = payload.expires_at.saturating_sub(now()) / 1000;
        if ttl == 0 {
            return Ok(());
        }
        let (_, private) = self.inner.store.keys().map_err(|_| (0, 1500))?;
        let mut vapid = VapidSignatureBuilder::from_base64(&private, &device.subscription)
            .map_err(|_| (400, 0))?;
        vapid.add_claim("sub", self.inner.push_contact.as_str());
        let signature = vapid.build().map_err(|_| (400, 0))?;
        let content = serde_json::to_vec(payload).map_err(|_| (400, 0))?;
        let mut builder = WebPushMessageBuilder::new(&device.subscription);
        builder.set_vapid_signature(signature);
        builder.set_payload(ContentEncoding::Aes128Gcm, &content);
        builder.set_ttl(ttl.min(30) as u32);
        builder.set_urgency(Urgency::High);
        let message = builder.build().map_err(|_| (400, 0))?;
        let request = web_push::request_builder::build_request::<Vec<u8>>(message);
        let mut outgoing = self
            .inner
            .http
            .post(request.uri().to_string())
            .timeout(Duration::from_secs(6));
        for (k, v) in request.headers() {
            outgoing = outgoing.header(k.as_str(), v.as_bytes());
        }
        let response = outgoing
            .body(request.into_body())
            .send()
            .await
            .map_err(|_| (0, 1500))?;
        let status = response.status().as_u16();
        let delay = response
            .headers()
            .get("retry-after")
            .and_then(|v| v.to_str().ok())
            .and_then(|v| v.parse::<u64>().ok())
            .map(|s| s.saturating_mul(1000))
            .unwrap_or(1500);
        if response.status().is_success() {
            Ok(())
        } else {
            Err((status, delay))
        }
    }
    async fn deliver(&self, job: Job) -> Result<()> {
        for attempt in 0..2 {
            if self
                .inner
                .store
                .device_hash(&job.device.token_hash)?
                .is_none_or(|d| {
                    d.since != job.device.since
                        || d.subscription.endpoint != job.device.subscription.endpoint
                })
                || job.payload.expires_at <= now()
            {
                return Ok(());
            }
            match self.send(&job.device, &job.payload).await {
                Ok(()) => {
                    self.inner.store.error(&job.device, None)?;
                    return Ok(());
                }
                Err((404 | 410, _)) => {
                    self.inner.store.remove(&job.device.token_hash)?;
                    return Ok(());
                }
                Err((status, delay)) => {
                    let retry = status == 0 || status == 429 || status >= 500;
                    if attempt == 0
                        && retry
                        && now().saturating_add(delay).saturating_add(1000) < job.payload.expires_at
                    {
                        tokio::time::sleep(Duration::from_millis(delay)).await;
                        continue;
                    }
                    self.inner.store.error(
                        &job.device,
                        Some(if retry {
                            "推送暂时失败，请测试通知或检查服务器网络"
                        } else {
                            "推送服务拒绝，请关闭后重新开启锁屏提醒"
                        }),
                    )?;
                    return Ok(());
                }
            }
        }
        Ok(())
    }
    pub async fn test(&self, device: Device) -> Result<()> {
        let time = now();
        let payload = Payload {
            id: format!("test-{time}"),
            title: "本站监控 · 测试通知".into(),
            body: "通知已送达；提示音受手机静音和专注模式控制。".into(),
            expires_at: time + 30000,
        };
        self.send(&device, &payload)
            .await
            .map_err(|_| AppError::unavailable("测试推送未发出，请检查服务器网络或重新开启提醒"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        parser,
        tests::{subscription, update},
    };
    use axum::{
        Router,
        extract::State,
        http::{HeaderMap, StatusCode},
        routing::post,
    };
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tempfile::TempDir;

    fn message(id: u64) -> Message {
        parser::normalize(&update(id), "-1001", "2002", now()).unwrap()
    }
    #[tokio::test]
    async fn only_new_realtime_messages_are_queued_and_same_trade_coalesces() {
        let directory = TempDir::new().unwrap();
        let store = Store::open(directory.path().join("db"), "test").unwrap();
        let mut msg = message(1);
        msg.sent_at = now();
        let token = store
            .subscribe(
                crate::store::subscription(subscription("https://web.push.apple.com/a")).unwrap(),
                None,
                msg.sent_at - 1,
            )
            .unwrap();
        let delivery = Delivery::new(
            store.clone(),
            reqwest::Client::new(),
            "mailto:test@example.com".into(),
        );
        let mut old = message(2);
        old.sent_at = now() - 31000;
        delivery.accept(&old).await.unwrap();
        let mut edited = message(3);
        edited.edited = true;
        delivery.accept(&edited).await.unwrap();
        assert!(delivery.inner.queue.lock().await.is_empty());
        delivery.accept(&msg).await.unwrap();
        delivery.accept(&msg).await.unwrap();
        assert_eq!(delivery.inner.queue.lock().await.len(), 1);
        let mut newer = message(4);
        newer.sent_at = msg.sent_at + 1;
        delivery.accept(&newer).await.unwrap();
        assert_eq!(
            delivery
                .inner
                .queue
                .lock()
                .await
                .values()
                .next()
                .unwrap()
                .payload
                .id,
            newer.id
        );
        store.remove(&crate::store::hash(&token)).unwrap();
        let job = delivery.inner.queue.lock().await.pop_first().unwrap().1;
        delivery.deliver(job).await.unwrap(); // Removed devices must never reach their remote endpoint.
        let weak = Arc::downgrade(&delivery.inner);
        delivery.start();
        drop(delivery);
        tokio::task::yield_now().await;
        assert!(
            weak.upgrade().is_none(),
            "idle workers must release store and credentials"
        );
    }
    #[derive(Clone)]
    struct Endpoint {
        calls: Arc<AtomicUsize>,
        code: u16,
        first: Arc<AtomicUsize>,
    }
    async fn mock(
        State(state): State<Endpoint>,
        headers: HeaderMap,
        body: axum::body::Bytes,
    ) -> (StatusCode, HeaderMap) {
        state.calls.fetch_add(1, Ordering::SeqCst);
        assert_eq!(headers["content-encoding"], "aes128gcm");
        assert!(
            headers["authorization"]
                .to_str()
                .unwrap()
                .starts_with("vapid ")
        );
        assert!(!String::from_utf8_lossy(&body).contains("本站监控"));
        let first = state.first.swap(0, Ordering::SeqCst);
        let mut response = HeaderMap::new();
        response.insert("retry-after", "0".parse().unwrap());
        (
            StatusCode::from_u16(if first > 0 { first as u16 } else { state.code }).unwrap(),
            response,
        )
    }
    #[tokio::test]
    async fn transient_delivery_retries_same_message_and_gone_subscription_is_removed() {
        for (first, code, expected, removed) in [
            (503, 201, 2, false),
            (410, 410, 1, true),
            (400, 400, 1, false),
        ] {
            let directory = TempDir::new().unwrap();
            let store = Store::open(directory.path().join("db"), "test").unwrap();
            let state = Endpoint {
                calls: Arc::new(AtomicUsize::new(0)),
                code,
                first: Arc::new(AtomicUsize::new(first)),
            };
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            let endpoint = format!("http://{}/push", listener.local_addr().unwrap());
            let app = Router::new()
                .route("/push", post(mock))
                .with_state(state.clone());
            let server = tokio::spawn(async { axum::serve(listener, app).await.unwrap() });
            // Local test-only subscription; public handlers always apply the host allowlist.
            let token = store
                .subscribe(
                    serde_json::from_value(subscription(&endpoint)).unwrap(),
                    None,
                    0,
                )
                .unwrap();
            let device = store.device(&token).unwrap().unwrap();
            let delivery = Delivery::new(
                store.clone(),
                reqwest::Client::builder().no_proxy().build().unwrap(),
                "mailto:test@example.com".into(),
            );
            let job = Job {
                device,
                payload: Payload {
                    id: "test".into(),
                    title: "本站监控".into(),
                    body: "测试".into(),
                    expires_at: now() + 30000,
                },
            };
            delivery.deliver(job.clone()).await.unwrap();
            assert_eq!(state.calls.load(Ordering::SeqCst), expected);
            assert_eq!(store.device(&token).unwrap().is_none(), removed);
            let mut expired = job;
            expired.payload.expires_at = now() - 1;
            delivery.deliver(expired).await.unwrap();
            assert_eq!(state.calls.load(Ordering::SeqCst), expected);
            server.abort();
        }
    }
}
