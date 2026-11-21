mod device;
pub mod parser;
pub mod push;
#[cfg(any(test, feature = "sqlite"))]
mod sqlite;
pub mod store;
#[cfg(test)]
mod tests;
use botai_core::{AppError, Result};
use parser::Message;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, VecDeque},
    sync::{
        Arc,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use subtle::ConstantTimeEq;
use tokio::sync::{Mutex, Notify, broadcast};
pub fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}
#[derive(Clone, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub token: String,
    pub chat_id: String,
    pub sender_id: String,
    pub access_key: String,
    /// Public contact URI sent to push providers in the VAPID token.
    pub push_contact: String,
}
#[derive(Clone)]
pub struct Monitor {
    inner: Arc<Inner>,
}
struct Inner {
    config: Config,
    http: reqwest::Client,
    telegram_base: String,
    pub store: store::Store,
    delivery: push::Delivery,
    events: broadcast::Sender<Value>,
    messages: Mutex<VecDeque<Message>>,
    status: Mutex<Value>,
    offset: Mutex<Option<u64>>,
    running: AtomicBool,
    consumers_changed: Notify,
    viewers: AtomicUsize,
    attempts: Mutex<BTreeMap<String, (u32, u64)>>,
    test_times: Mutex<BTreeMap<String, u64>>,
}
pub struct Subscription {
    pub receiver: broadcast::Receiver<Value>,
    pub initial: Vec<Value>,
    monitor: Monitor,
}
impl Drop for Subscription {
    fn drop(&mut self) {
        self.monitor.inner.viewers.fetch_sub(1, Ordering::SeqCst);
        self.monitor.inner.consumers_changed.notify_waiters();
    }
}
impl Monitor {
    pub fn new_mysql(
        config: Config,
        http: reqwest::Client,
        db: botai_database::Database,
    ) -> Result<Self> {
        let hash = store::hash(&format!(
            "{}\n{}\n{}\n{}",
            config.token, config.chat_id, config.sender_id, config.access_key
        ));
        Self::with_store(
            config,
            http,
            store::Store::mysql(db, &hash)?,
            "https://api.telegram.org".into(),
        )
    }
    #[cfg(any(test, feature = "sqlite"))]
    pub fn new(
        config: Config,
        http: reqwest::Client,
        path: impl AsRef<std::path::Path>,
    ) -> Result<Self> {
        Self::with_transport(config, http, path, "https://api.telegram.org".into())
    }
    // The upstream cannot be chosen by HTTP clients. Tests use an isolated local server.
    #[cfg(any(test, feature = "sqlite"))]
    fn with_transport(
        config: Config,
        http: reqwest::Client,
        path: impl AsRef<std::path::Path>,
        telegram_base: String,
    ) -> Result<Self> {
        let config_hash = store::hash(&format!(
            "{}\n{}\n{}\n{}",
            config.token, config.chat_id, config.sender_id, config.access_key
        ));
        let store = store::Store::open(path, &config_hash)?;
        Self::with_store(config, http, store, telegram_base)
    }
    fn with_store(
        config: Config,
        http: reqwest::Client,
        store: store::Store,
        telegram_base: String,
    ) -> Result<Self> {
        let offset = store.setting("offset")?.and_then(|s| s.parse().ok());
        let contact = reqwest::Url::parse(&config.push_contact)
            .map_err(|_| AppError::invalid("监控推送联系地址格式无效"))?;
        let valid = match contact.scheme() {
            "https" => {
                contact.host().is_some()
                    && contact.username().is_empty()
                    && contact.password().is_none()
            }
            "mailto" => contact
                .path()
                .split_once('@')
                .is_some_and(|(user, domain)| !user.is_empty() && !domain.is_empty()),
            _ => false,
        };
        if !valid || contact.query().is_some() || contact.fragment().is_some() {
            return Err(AppError::invalid(
                "监控推送联系地址必须是公开 HTTPS 或 mailto 地址",
            ));
        }
        let delivery = push::Delivery::new(store.clone(), http.clone(), contact.to_string());
        delivery.start();
        let (events, _) = broadcast::channel(64);
        let monitor = Self {
            inner: Arc::new(Inner {
                config,
                http,
                telegram_base,
                store,
                delivery,
                events,
                messages: Mutex::new(VecDeque::new()),
                status: Mutex::new(json!({"phase":"connecting","detail":"正在连接 Telegram"})),
                offset: Mutex::new(offset),
                running: AtomicBool::new(false),
                consumers_changed: Notify::new(),
                viewers: AtomicUsize::new(0),
                attempts: Mutex::new(BTreeMap::new()),
                test_times: Mutex::new(BTreeMap::new()),
            }),
        };
        if !monitor.inner.store.devices()?.is_empty() {
            monitor.ensure_running();
        }
        Ok(monitor)
    }
    pub fn configured(&self) -> bool {
        let c = &self.inner.config;
        c.token.split_once(':').is_some_and(|(id, key)| {
            !id.is_empty()
                && id.bytes().all(|b| b.is_ascii_digit())
                && !key.is_empty()
                && key
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        }) && c.chat_id.starts_with('-')
            && c.chat_id.len() > 1
            && c.chat_id[1..].bytes().all(|b| b.is_ascii_digit())
            && !c.sender_id.is_empty()
            && c.sender_id.bytes().all(|b| b.is_ascii_digit())
            && c.access_key.len() >= 6
    }
    fn require_config(&self) -> Result<()> {
        if !self.configured() {
            Err(AppError::new(
                "MONITOR_NOT_CONFIGURED",
                "后端监控配置未完成",
                503,
                false,
            ))
        } else {
            Ok(())
        }
    }
    pub async fn authorize(&self, key: &str, client: &str) -> Result<()> {
        self.require_config()?;
        let time = now();
        let client = client.chars().take(128).collect::<String>();
        let mut attempts = self.inner.attempts.lock().await;
        attempts.retain(|_, (_, until)| *until > time);
        if attempts.get(&client).is_some_and(|(count, _)| *count >= 5) {
            return Err(AppError::new(
                "MONITOR_RATE_LIMIT",
                "访问码尝试过于频繁，请稍后再试",
                429,
                false,
            ));
        }
        if attempts.len() >= 2048 && !attempts.contains_key(&client) {
            return Err(AppError::new("MONITOR_BUSY", "访问码验证繁忙", 429, true));
        }
        let a = Sha256::digest(key.as_bytes());
        let b = Sha256::digest(self.inner.config.access_key.as_bytes());
        if key.len() <= 512 && bool::from(a.ct_eq(&b)) {
            attempts.remove(&client);
            return Ok(());
        }
        let entry = attempts.entry(client).or_insert((0, time + 60000));
        entry.0 += 1;
        Err(AppError::new(
            "MONITOR_ACCESS_DENIED",
            "监控访问码不正确",
            401,
            false,
        ))
    }
    pub async fn subscribe(&self) -> Result<Subscription> {
        self.require_config()?;
        if self
            .inner
            .viewers
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                (n < 16).then_some(n + 1)
            })
            .is_err()
        {
            return Err(AppError::new(
                "MONITOR_VIEWERS",
                "监控连接数已满，请关闭多余页面",
                429,
                false,
            ));
        }
        let receiver = self.inner.events.subscribe();
        let messages = self.inner.messages.lock().await;
        let initial = vec![
            json!({"type":"snapshot","messages":*messages}),
            json!({"type":"status","status":*self.inner.status.lock().await}),
        ];
        drop(messages);
        self.ensure_running();
        Ok(Subscription {
            receiver,
            initial,
            monitor: self.clone(),
        })
    }
    pub async fn push_action(&self, body: Value, client: &str) -> Result<Value> {
        self.require_config()?;
        let action = body["action"].as_str().unwrap_or("");
        if ["configure", "subscribe"].contains(&action) {
            self.authorize(body["accessKey"].as_str().unwrap_or(""), client)
                .await?;
        }
        match action {
            "configure" => Ok(json!({"publicKey":self.inner.store.keys()?.0})),
            "subscribe" => {
                let subscription = store::subscription(body["subscription"].clone())?;
                let token = self.inner.store.subscribe(
                    subscription,
                    body["deviceToken"].as_str(),
                    now(),
                )?;
                self.ensure_running();
                Ok(json!({"enabled":true,"deviceToken":token}))
            }
            "status" | "delete" | "test" => {
                let device = self
                    .inner
                    .store
                    .device(body["deviceToken"].as_str().unwrap_or(""))?;
                if action == "status" {
                    let status = self.inner.status.lock().await;
                    let error = device.as_ref().and_then(|d| d.error.clone()).or_else(|| {
                        device.as_ref().and_then(|_| {
                            ["error", "retrying"]
                                .contains(&status["phase"].as_str().unwrap_or(""))
                                .then(|| status["detail"].as_str().unwrap_or("").to_string())
                        })
                    });
                    return Ok(json!({"enabled":device.is_some(),"error":error}));
                }
                if action == "delete" {
                    if let Some(device) = device {
                        self.inner.store.remove(&device.token_hash)?;
                        self.inner.consumers_changed.notify_waiters();
                    }
                    return Ok(json!({"enabled":false}));
                }
                let device = device.ok_or_else(|| {
                    AppError::new("DEVICE_MISSING", "此设备尚未开启锁屏提醒", 404, false)
                })?;
                let time = now();
                let mut tests = self.inner.test_times.lock().await;
                tests.retain(|_, last| time.saturating_sub(*last) < 60000);
                if tests
                    .get(&device.token_hash)
                    .is_some_and(|last| time.saturating_sub(*last) < 10000)
                {
                    return Err(AppError::new(
                        "TEST_RATE_LIMIT",
                        "请间隔 10 秒再测试",
                        429,
                        false,
                    ));
                }
                tests.insert(device.token_hash.clone(), time);
                drop(tests);
                self.inner.delivery.test(device).await?;
                Ok(json!({"sent":true}))
            }
            _ => Err(AppError::invalid("未知推送操作")),
        }
    }
    fn consumers(&self) -> bool {
        self.inner.viewers.load(Ordering::SeqCst) > 0
            || self.inner.store.devices().is_ok_and(|d| !d.is_empty())
    }
    fn ensure_running(&self) {
        if !self.configured()
            || self
                .inner
                .running
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
        {
            return;
        }
        let service = self.clone();
        tokio::spawn(async move {
            loop {
                let idle = service.run().await;
                service.inner.running.store(false, Ordering::SeqCst);
                // A subscriber may have arrived between the final consumer check and
                // releasing running. Reacquire ownership without starting two pollers.
                if !idle
                    || !service.consumers()
                    || service
                        .inner
                        .running
                        .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                        .is_err()
                {
                    break;
                }
            }
        });
    }
    async fn status(&self, phase: &str, detail: &str, retry: u64) {
        let mut status = self.inner.status.lock().await;
        let mut next = json!({"phase":phase,"detail":detail});
        if retry > 0 {
            next["retryAt"] = json!(retry)
        }
        if *status != next {
            *status = next.clone();
            let _ = self
                .inner
                .events
                .send(json!({"type":"status","status":next}));
        }
    }
    async fn telegram(&self, method: &str, params: Value) -> Result<Value> {
        // URLs contain the bot token. Neither transport errors nor raw Telegram errors leave this function.
        let mut response = self
            .inner
            .http
            .post(format!(
                "{}/bot{}/{method}",
                self.inner.telegram_base, self.inner.config.token
            ))
            .json(&params)
            .timeout(Duration::from_secs(40))
            .send()
            .await
            .map_err(|_| AppError::unavailable("连接 Telegram 失败，正在重试"))?;
        let status = response.status().as_u16();
        let mut raw = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| AppError::unavailable("Telegram 响应中断"))?
        {
            if raw.len() + chunk.len() > 2_000_000 {
                return Err(AppError::unavailable("Telegram 响应过大"));
            }
            raw.extend_from_slice(&chunk);
        }
        let body: Value =
            serde_json::from_slice(&raw).map_err(|_| AppError::unavailable("Telegram 返回异常"))?;
        if body["ok"] != true || status >= 400 {
            let code = body["error_code"].as_u64().unwrap_or(status as u64);
            let message = match code {
                401 => "Bot Token 无效，请检查后端配置",
                403 => "Telegram 拒绝访问，请检查机器人权限",
                409 => "此 Bot 被其他轮询程序或 Webhook 占用，请先停止另一端",
                429 => "Telegram 限频，等待后重连",
                _ => "Telegram 暂时不可用，正在重试",
            };
            let mut error =
                AppError::new("TELEGRAM_ERROR", message, 503, code == 429 || code >= 500);
            if code == 429 {
                error.data = Some(json!(
                    body["parameters"]["retry_after"]
                        .as_u64()
                        .unwrap_or(5)
                        .min(60)
                ))
            }
            return Err(error);
        }
        Ok(body["result"].clone())
    }
    async fn accept_updates(&self, updates: &Value) -> Result<()> {
        let updates = updates
            .as_array()
            .ok_or_else(|| AppError::unavailable("Telegram 返回异常"))?;
        let mut next = *self.inner.offset.lock().await;
        for update in updates {
            let Some(id) = update["update_id"].as_u64() else {
                continue;
            };
            if next.is_some_and(|offset| id < offset) {
                continue;
            }
            if let Some(message) = parser::normalize(
                update,
                &self.inner.config.chat_id,
                &self.inner.config.sender_id,
                now(),
            ) {
                let mut messages = self.inner.messages.lock().await;
                let newer = messages
                    .iter()
                    .find(|m| m.id == message.id)
                    .is_none_or(|m| m.update_id < message.update_id);
                if newer {
                    messages.retain(|m| m.id != message.id);
                    messages.push_back(message.clone());
                    while messages.len() > 300
                        || serde_json::to_vec(&*messages).map_or(true, |v| v.len() > 256000)
                    {
                        messages.pop_front();
                    }
                    drop(messages);
                    let _ = self
                        .inner
                        .events
                        .send(json!({"type":"message","message":message}));
                    self.inner.delivery.accept(&message).await?;
                }
            }
            next = Some(id.saturating_add(1));
        }
        if let Some(next) = next {
            // Persist once per poll, including unrelated or duplicate updates.
            self.inner.store.set("offset", &next.to_string())?;
            *self.inner.offset.lock().await = Some(next);
        }
        Ok(())
    }
    async fn poll(&self, webhook_checked: &mut bool, first: bool) -> Result<Value> {
        if !*webhook_checked {
            let info = self.telegram("getWebhookInfo", json!({})).await?;
            if info["url"].as_str().is_some_and(|u| !u.is_empty()) {
                return Err(AppError::new(
                    "WEBHOOK_ACTIVE",
                    "此 Bot 已配置 Webhook，请先停用另一端接收程序",
                    503,
                    false,
                ));
            }
            *webhook_checked = true;
        }
        let offset = *self.inner.offset.lock().await;
        let mut params = json!({"timeout":if first {0} else {30},"limit":100,"allowed_updates":["message","edited_message"]});
        if let Some(offset) = offset {
            params["offset"] = json!(offset);
        }
        self.telegram("getUpdates", params).await
    }
    async fn run(&self) -> bool {
        let mut webhook_checked = false;
        let mut first = true;
        let mut failures = 0u32;
        self.status("connecting", "正在连接 Telegram", 0).await;
        loop {
            let changed = self.inner.consumers_changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if !self.consumers() {
                return true;
            }
            let updates = tokio::select! {
                result = self.poll(&mut webhook_checked, first) => result,
                _ = &mut changed => continue,
            };
            // Persist a completed poll outside the cancellable HTTP future.
            let outcome = match updates {
                Ok(updates) => self.accept_updates(&updates).await,
                Err(error) => Err(error),
            };
            match outcome {
                Ok(()) => {
                    failures = 0;
                    first = false;
                    self.status("live", "监控中", 0).await;
                }
                Err(error) => {
                    if !error.retryable {
                        self.status("error", &error.message, 0).await;
                        return false;
                    }
                    let delay = error
                        .data
                        .and_then(|v| v.as_u64())
                        .map(|s| s * 1000)
                        .unwrap_or((1000u64 << failures.min(4)).min(15000));
                    failures = failures.saturating_add(1);
                    self.status("retrying", &error.message, now() + delay).await;
                    tokio::select! {
                        _ = tokio::time::sleep(Duration::from_millis(delay)) => {},
                        _ = &mut changed => {},
                    }
                }
            }
        }
    }
}
