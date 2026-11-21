//! Four's official HTTP API has its own bounded admission, cache and failure state.
//! This never wraps chain RPC or any other platform's client.
use botai_core::{AppError, Result};
use reqwest::{Client, RequestBuilder, StatusCode};
use serde_json::{Value, json};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
use tokio::time::{Instant, timeout};

const BASE: &str = "https://four.meme/meme-api/v1";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const SHORT_COOLDOWN: Duration = Duration::from_secs(30);
const LONG_COOLDOWN: Duration = Duration::from_secs(300);
const CONFIG_TTL: Duration = Duration::from_secs(300);

#[derive(Clone)]
pub(crate) struct FourGate {
    inner: Arc<Inner>,
}

struct Inner {
    http: Client,
    base: String,
    timeout: Duration,
    short: Duration,
    long: Duration,
    cache_ttl: Duration,
    // At most one upstream request, plus eight bounded waiters. Keeping the
    // upstream serialized also prevents an older success clearing a new fault.
    admitted: Semaphore,
    upstream: Semaphore,
    upload_bodies: Arc<Semaphore>,
    json_bodies: Arc<Semaphore>,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    known_available: bool,
    failure: Option<Failure>,
    config: Option<(Instant, Value)>,
}

struct Failure {
    until: Instant,
    error: AppError,
}

struct Fault {
    error: AppError,
    cooldown: Option<Duration>,
    service_observed: bool,
}

impl Default for FourGate {
    fn default() -> Self {
        Self::build(
            BASE.into(),
            REQUEST_TIMEOUT,
            SHORT_COOLDOWN,
            LONG_COOLDOWN,
            CONFIG_TTL,
            false,
        )
    }
}

impl FourGate {
    fn build(
        base: String,
        request_timeout: Duration,
        short: Duration,
        long: Duration,
        cache_ttl: Duration,
        no_proxy: bool,
    ) -> Self {
        let builder = Client::builder()
            .user_agent("uxuy-backend/0.1")
            .redirect(reqwest::redirect::Policy::none())
            .retry(reqwest::retry::never())
            .connect_timeout(Duration::from_secs(5).min(request_timeout))
            .timeout(request_timeout)
            .pool_max_idle_per_host(1);
        let http = if no_proxy {
            builder.no_proxy()
        } else {
            builder
        }
        .build()
        .expect("Four HTTP client");
        Self {
            inner: Arc::new(Inner {
                http,
                base,
                timeout: request_timeout,
                short,
                long,
                cache_ttl,
                admitted: Semaphore::new(9),
                upstream: Semaphore::new(1),
                upload_bodies: Arc::new(Semaphore::new(2)),
                json_bodies: Arc::new(Semaphore::new(2)),
                state: Mutex::default(),
            }),
        }
    }

    #[cfg(test)]
    pub(crate) fn for_test(
        base: String,
        request_timeout: Duration,
        short: Duration,
        long: Duration,
        cache_ttl: Duration,
    ) -> Self {
        Self::build(base, request_timeout, short, long, cache_ttl, true)
    }

    pub(crate) fn get(&self, path: &str) -> RequestBuilder {
        self.inner
            .http
            .get(format!("{}{}", self.inner.base, path))
            .header(reqwest::header::ACCEPT, "application/json")
    }

    pub(crate) fn post(&self, path: &str) -> RequestBuilder {
        self.inner
            .http
            .post(format!("{}{}", self.inner.base, path))
            .header(reqwest::header::ACCEPT, "application/json")
    }

    pub(crate) fn preflight(&self) -> Result<()> {
        let state = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(failure) = &state.failure {
            if failure.until > Instant::now() {
                return Err(with_retry_after(failure.error.clone(), failure.until));
            }
        }
        Ok(())
    }

    pub(crate) fn upload_slot(&self) -> Result<OwnedSemaphorePermit> {
        self.preflight()?;
        self.inner
            .upload_bodies
            .clone()
            .try_acquire_owned()
            .map_err(|_| busy())
    }

    pub(crate) fn json_slot(&self) -> Result<OwnedSemaphorePermit> {
        // Admission is independent of HTTP availability: this body may contain
        // predictTokenAddress, which uses chain RPC rather than Four's API.
        self.inner
            .json_bodies
            .clone()
            .try_acquire_owned()
            .map_err(|_| busy())
    }

    pub(crate) fn status(&self) -> Value {
        let state = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(failure) = &state.failure {
            let cooling = failure.until > Instant::now();
            return json!({
                "available":false,
                "state":if cooling { "cooldown" } else if self.inner.upstream.available_permits() == 0 { "probing" } else { "probe_required" },
                "code":failure.error.code,
                "message":failure.error.message,
                "retryable":false,
                "retryAfterSeconds":retry_after(failure.until),
            });
        }
        json!({"available":state.known_available,"state":if state.known_available { "available" } else { "unknown" },"retryable":false,"retryAfterSeconds":0})
    }

    fn cached_config(&self) -> Option<Value> {
        let state = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        state
            .config
            .as_ref()
            .filter(|(until, _)| *until > Instant::now())
            .map(|(_, value)| value.clone())
    }

    pub(crate) async fn request(
        &self,
        request: RequestBuilder,
        config: bool,
        limit: usize,
    ) -> Result<Value> {
        // A cached config is not evidence that login/create is currently usable.
        self.preflight()?;
        if config {
            if let Some(value) = self.cached_config() {
                return Ok(value);
            }
        }
        let _admitted = self.inner.admitted.try_acquire().map_err(|_| busy())?;
        let _upstream = timeout(self.inner.timeout, self.inner.upstream.acquire())
            .await
            .map_err(|_| busy())?
            .map_err(|_| busy())?;
        // Every waiter observes the first request's failure without another call.
        self.preflight()?;
        if config {
            if let Some(value) = self.cached_config() {
                return Ok(value);
            }
        }
        // The timeout encloses sending, every response-body chunk and decoding.
        // Dropping this future drops both permits; cancellation cannot wedge a probe.
        let outcome = timeout(self.inner.timeout, self.fetch(request, config, limit))
            .await
            .unwrap_or_else(|_| {
                Err(self.short_fault("FOUR_API_TIMEOUT", "Four 官方接口响应超时，发币暂不可用"))
            });
        let mut state = self.inner.state.lock().unwrap_or_else(|e| e.into_inner());
        match outcome {
            Ok(value) => {
                state.known_available = true;
                state.failure = None;
                if config && success_code(&value) {
                    state.config = Some((Instant::now() + self.inner.cache_ttl, value.clone()));
                }
                Ok(value)
            }
            Err(fault) => {
                if let Some(duration) = fault.cooldown {
                    let until = Instant::now() + duration;
                    state.known_available = false;
                    state.config = None;
                    state.failure = Some(Failure {
                        until,
                        error: fault.error.clone(),
                    });
                    Err(with_retry_after(fault.error, until))
                } else {
                    // Valid account/parameter refusals prove the HTTP service is
                    // responding. They do not poison other users' sessions.
                    if fault.service_observed {
                        state.known_available = true;
                        state.failure = None;
                    }
                    Err(fault.error)
                }
            }
        }
    }

    async fn fetch(
        &self,
        request: RequestBuilder,
        config: bool,
        limit: usize,
    ) -> std::result::Result<Value, Fault> {
        let mut response = request.send().await.map_err(|error| {
            if error.is_builder() {
                Fault {
                    error: AppError::invalid("Four 请求参数无效"),
                    cooldown: None,
                    service_observed: false,
                }
            } else if error.is_timeout() {
                self.short_fault("FOUR_API_TIMEOUT", "Four 官方接口响应超时，发币暂不可用")
            } else {
                self.short_fault("FOUR_API_UNAVAILABLE", "Four 官方接口暂不可用")
            }
        })?;
        let status = response.status();
        if response
            .headers()
            .get("cf-mitigated")
            .is_some_and(|v| v.as_bytes().eq_ignore_ascii_case(b"challenge"))
        {
            return Err(self.long_fault(
                "FOUR_API_CHALLENGED",
                "Four 官方接口限制本服务器访问，发币暂不可用",
            ));
        }
        if status.is_server_error() || status == StatusCode::TOO_MANY_REQUESTS {
            return Err(self.short_fault("FOUR_API_UNAVAILABLE", "Four 官方接口暂不可用"));
        }
        if status == StatusCode::UNAUTHORIZED {
            return Err(rejected("FOUR_API_AUTH", "Four 登录已失效，请重新登录"));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|error| {
            if error.is_timeout() {
                self.short_fault("FOUR_API_TIMEOUT", "Four 官方接口响应超时，发币暂不可用")
            } else {
                self.short_fault("FOUR_API_UNAVAILABLE", "Four 官方接口响应中断")
            }
        })? {
            if bytes.len().saturating_add(chunk.len()) > limit {
                return Err(self.short_fault("FOUR_API_BAD_RESPONSE", "Four 官方接口返回异常"));
            }
            bytes.extend_from_slice(&chunk);
        }
        let value = serde_json::from_slice::<Value>(&bytes).ok();
        if status == StatusCode::FORBIDDEN {
            // Four may use 403 for an individual account's valid JSON refusal.
            // Only that explicit business envelope is exempt from network cooling.
            if value.as_ref().is_some_and(business_failure) {
                return Err(rejected(
                    "FOUR_API_REJECTED",
                    "Four 请求被拒绝，请检查登录或参数",
                ));
            }
            return Err(self.long_fault(
                "FOUR_API_FORBIDDEN",
                "Four 官方接口拒绝本服务器访问，发币暂不可用",
            ));
        }
        if !status.is_success() {
            return Err(rejected("FOUR_API_REJECTED", "Four 请求被拒绝，请检查参数"));
        }
        let value = value
            .filter(|v| v.is_object() && (success_code(v) || nonzero_code(v)))
            .ok_or_else(|| self.short_fault("FOUR_API_BAD_RESPONSE", "Four 官方接口返回异常"))?;
        if config && success_code(&value) && !value["data"].is_array() {
            return Err(self.short_fault("FOUR_API_BAD_RESPONSE", "Four 官方配置返回异常"));
        }
        Ok(value)
    }

    fn short_fault(&self, code: &str, message: &str) -> Fault {
        Fault {
            error: AppError::new(code, message, 503, false),
            cooldown: Some(self.inner.short),
            service_observed: true,
        }
    }

    fn long_fault(&self, code: &str, message: &str) -> Fault {
        Fault {
            error: AppError::new(code, message, 503, false),
            cooldown: Some(self.inner.long),
            service_observed: true,
        }
    }
}

fn success_code(value: &Value) -> bool {
    value["code"].as_i64() == Some(0) || value["code"].as_str() == Some("0")
}

fn business_failure(value: &Value) -> bool {
    value.is_object()
        && nonzero_code(value)
        && (value["msg"].is_string() || value["message"].is_string())
}

fn nonzero_code(value: &Value) -> bool {
    !success_code(value)
        && (value["code"].is_number()
            || value["code"].as_str().is_some_and(|code| !code.is_empty()))
}

fn rejected(code: &str, message: &str) -> Fault {
    Fault {
        error: AppError::new(code, message, 502, false),
        cooldown: None,
        service_observed: true,
    }
}

fn busy() -> AppError {
    AppError::new(
        "FOUR_API_BUSY",
        "Four 请求正在处理，请稍后手动重试",
        503,
        false,
    )
}

fn retry_after(until: Instant) -> u64 {
    until
        .saturating_duration_since(Instant::now())
        .as_secs_f64()
        .ceil() as u64
}

fn with_retry_after(mut error: AppError, until: Instant) -> AppError {
    error.data = Some(json!({"service":"four","retryAfterSeconds":retry_after(until)}));
    error
}
