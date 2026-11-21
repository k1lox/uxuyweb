use botai_core::{AppError, Chain, Result};
use futures::{StreamExt, stream};
use moka::future::Cache;
use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, VecDeque},
    sync::Arc,
    time::Duration,
};
use tokio::sync::{Mutex, Semaphore, SemaphorePermit, mpsc, oneshot};
use tokio::time::Instant;

pub mod multicall;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Call {
    pub method: String,
    #[serde(default)]
    pub params: Vec<Value>,
}
impl Call {
    pub fn new(method: &str, params: Vec<Value>) -> Self {
        Self {
            method: method.into(),
            params,
        }
    }
}
#[derive(Clone)]
pub struct Rpc {
    chains: Arc<HashMap<Chain, Arc<ChainRpc>>>,
    alternatives: Arc<HashMap<Chain, Vec<Arc<ChainRpc>>>>,
    client: Client,
}
struct ChainRpc {
    url: String,
    queue: mpsc::Sender<Queued>,
    recent: Cache<String, Value>,
    pinned: Cache<String, Value>,
    rate: Arc<RateControl>,
}
const RPC_ITEMS_PER_SECOND: usize = 40;
const RPC_ITEM_WINDOW: Duration = Duration::from_secs(1);
// Smooth full-window bursts so ordinary network arrival jitter does not turn
// two adjacent 40-item windows into a node-side 80-item burst.
const RPC_BURST_ITEMS: usize = 10;
const RPC_BURST_WINDOW: Duration = Duration::from_millis(250);
// Transport packing is separate from item quota and HTTP parallelism. Large
// calls keep the existing 3 MB per-call compatibility, but are sent alone when
// they exceed this 10%-spare aggregate budget.
const RPC_BATCH_REQUEST_BYTES: usize = 2_700_000;
const RPC_HEAVY_BATCH_ITEMS: usize = 4;
fn heavy_response(call: &Call) -> bool {
    matches!(
        call.method.as_str(),
        "eth_simulateV1" | "debug_traceCall" | "debug_traceTransaction" | "trace_callMany"
    )
}
struct Admission<'a> {
    indices: Vec<usize>,
    started: Instant,
    _recovery: Option<SemaphorePermit<'a>>,
}
struct RateControl {
    state: Mutex<RateState>,
    recovery: Semaphore,
    // Held while waiting for a window slot: Tokio's FIFO mutex prevents a
    // stream of small reads from starving an earlier batch or broadcast.
    items: Mutex<VecDeque<Instant>>,
}
impl Default for RateControl {
    fn default() -> Self {
        Self {
            state: Mutex::default(),
            recovery: Semaphore::new(2),
            items: Mutex::default(),
        }
    }
}
#[derive(Default)]
struct RateState {
    until: Option<Instant>,
    blocked: Option<Instant>,
    next: Option<Instant>,
    strikes: u32,
    successes: u32,
}
impl RateControl {
    async fn batch_size(&self, maximum: usize) -> usize {
        let maximum = maximum.min(RPC_BURST_ITEMS);
        let state = self.state.lock().await;
        if state.until.is_some_and(|end| end > Instant::now()) {
            maximum.div_ceil(1 << state.strikes).max(1)
        } else {
            maximum.max(1)
        }
    }
    async fn success(&self, started: Instant) {
        let mut state = self.state.lock().await;
        // Replies from requests sent before the last cooldown cannot undo it.
        if state.until.is_some_and(|end| end > Instant::now())
            && state.blocked.is_some_and(|end| started >= end)
        {
            state.successes += 1;
            if state.successes >= 3 {
                *state = RateState::default();
            }
        }
    }
    async fn limited(&self) -> bool {
        self.state
            .lock()
            .await
            .until
            .is_some_and(|end| end > Instant::now())
    }
    async fn limit(&self) {
        let mut state = self.state.lock().await;
        let now = Instant::now();
        if state.blocked.is_some_and(|end| end > now) {
            return;
        }
        state.strikes = if state.until.is_some_and(|end| end > now) {
            (state.strikes + 1).min(3)
        } else {
            1
        };
        state.successes = 0;
        state.blocked = Some(now + Duration::from_millis(250 * (1 << state.strikes)));
        state.until = Some(now + Duration::from_secs(5));
    }
    async fn admit(&self, requested: &[usize], active: impl Fn(usize) -> bool) -> Admission<'_> {
        assert!((1..=RPC_BURST_ITEMS).contains(&requested.len()));
        let mut items = self.items.lock().await;
        let mut recovery = None;
        loop {
            // Consumers may disappear while waiting for quota, not only while
            // queued for an HTTP lane. Cancelled rows consume no item budget.
            let mut indices: Vec<_> = requested.iter().copied().filter(|&i| active(i)).collect();
            let now = Instant::now();
            if indices.is_empty() {
                return Admission {
                    indices,
                    started: now,
                    _recovery: recovery,
                };
            }
            while items.front().is_some_and(|at| *at + RPC_ITEM_WINDOW <= now) {
                items.pop_front();
            }
            let mut state = self.state.lock().await;
            let limited = state.until.is_some_and(|end| end > now);
            if limited && recovery.is_none() {
                let until = state.until.unwrap();
                drop(state);
                // Slow old recovery requests must not hold the FIFO beyond
                // the bounded recovery period after healthy admission resumes.
                recovery = tokio::time::timeout_at(until, self.recovery.acquire())
                    .await
                    .ok()
                    .map(|permit| permit.expect("RPC recovery semaphore stays open"));
                continue;
            }
            let mut due = now;
            if limited {
                due = state
                    .blocked
                    .into_iter()
                    .chain(state.next)
                    .fold(due, Instant::max);
            }
            for (capacity, window) in [
                (RPC_ITEMS_PER_SECOND, RPC_ITEM_WINDOW),
                (RPC_BURST_ITEMS, RPC_BURST_WINDOW),
            ] {
                let used = items
                    .iter()
                    .rev()
                    .take_while(|at| **at + window > now)
                    .count();
                if used + indices.len() > capacity {
                    due = due.max(items[items.len() + indices.len() - capacity - 1] + window);
                }
            }
            if due <= now {
                indices.retain(|&i| active(i));
                if limited {
                    state.next = Some(now + Duration::from_millis(50 * (1 << state.strikes)));
                }
                items.extend(std::iter::repeat_n(now, indices.len()));
                return Admission {
                    indices,
                    started: now,
                    _recovery: recovery,
                };
            }
            drop(state);
            // Recheck cooldown, recovery lanes and live consumers after every
            // wait; a concurrent response may have reported a new 429.
            tokio::time::sleep_until(due).await;
        }
    }
    #[cfg(test)]
    async fn reserve_items(&self, count: usize) -> Instant {
        self.admit(&(0..count).collect::<Vec<_>>(), |_| true)
            .await
            .started
    }
}
struct Queued {
    call: Call,
    request_bytes: usize,
    result: oneshot::Sender<Result<Value>>,
}
const READ_METHODS: &[&str] = &[
    "eth_getStorageAt",
    "eth_chainId",
    "eth_blockNumber",
    "eth_gasPrice",
    "eth_maxPriorityFeePerGas",
    "eth_feeHistory",
    "eth_getBalance",
    "eth_getCode",
    "eth_getTransactionCount",
    "eth_call",
    "eth_estimateGas",
    "eth_getTransactionReceipt",
    "eth_getTransactionByHash",
    "eth_getBlockByNumber",
    "eth_getBlockByHash",
    "eth_getLogs",
    "eth_simulateV1",
    "debug_traceCall",
    "debug_traceTransaction",
    "trace_callMany",
];

impl Rpc {
    /// Fixed server-configured endpoints only; queues and caches are shared per endpoint.
    pub fn with_alternatives(mut self, chain: Chain, urls: Vec<String>) -> Self {
        let mut alternatives = (*self.alternatives).clone();
        let mut rows = vec![self.chains[&chain].clone()];
        for url in urls {
            let rpc = Self::with_urls(self.client.clone(), HashMap::from([(chain, url)]));
            rows.push(rpc.chains[&chain].clone());
        }
        alternatives.insert(chain, rows);
        self.alternatives = Arc::new(alternatives);
        self
    }
    pub fn endpoint_count(&self, chain: Chain) -> usize {
        self.alternatives.get(&chain).map(Vec::len).unwrap_or(1)
    }
    /// Request-local selection never changes another user's node or cache.
    pub fn select_endpoint(&self, chain: Chain, index: usize) -> Result<Self> {
        let state = if let Some(rows) = self.alternatives.get(&chain) {
            rows.get(index)
        } else if index == 0 {
            self.chains.get(&chain)
        } else {
            None
        }
        .ok_or_else(|| AppError::invalid("RPC 节点编号无效"))?;
        let mut rpc = self.clone();
        let mut chains = (*self.chains).clone();
        chains.insert(chain, state.clone());
        rpc.chains = Arc::new(chains);
        Ok(rpc)
    }
    pub async fn rate_limited(&self, chain: Chain) -> bool {
        match self.chains.get(&chain) {
            Some(state) => state.rate.limited().await,
            None => false,
        }
    }
    /// Shared health sampling must measure a real request, not a cache hit.
    pub async fn latency(&self, chain: Chain) -> Option<u64> {
        let state = self.chains.get(&chain)?;
        if state.rate.limited().await {
            return None;
        }
        // Quota waiting is not an outage or network latency. Preserve the HTTP
        // timeout and begin measurement only after FIFO admission.
        let _admission = state.rate.admit(&[0], |_| true).await;
        let start = std::time::Instant::now();
        let response = self
            .client
            .post(&state.url)
            .timeout(Duration::from_secs(3))
            .json(&json!({"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}))
            .send()
            .await
            .ok()?;
        if response.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
            state.rate.limit().await;
            return None;
        }
        let result = response
            .error_for_status()
            .ok()?
            .json::<Value>()
            .await
            .ok()?;
        if let Some(error) = result.get("error") {
            if AppError::rpc(
                error["code"].as_i64().unwrap_or(-32000),
                error["message"].as_str().unwrap_or(""),
                None,
            )
            .code
                == "RPC_RATE_LIMIT"
            {
                state.rate.limit().await;
            }
            return None;
        }
        u64::from_str_radix(result["result"].as_str()?.strip_prefix("0x")?, 16).ok()?;
        Some(start.elapsed().as_millis().max(1) as u64)
    }
    // Injection only from trusted server configuration / tests, never an API URL.
    pub fn with_urls(client: Client, urls: HashMap<Chain, String>) -> Self {
        let mut chains = HashMap::new();
        let mut endpoints: HashMap<String, (Arc<RateControl>, Arc<Semaphore>)> = HashMap::new();
        for (chain, url) in urls {
            let configured_url = url.clone();
            let (queue, mut rx) = mpsc::channel::<Queued>(1024);
            let http = client.clone();
            // Healthy nodes retain their original parallelism. Recovery alone
            // uses the smaller shared lane budget and paced requests.
            let endpoint = reqwest::Url::parse(&url)
                .map(|url| url.to_string())
                .unwrap_or_else(|_| url.clone());
            let (rate, capacity) = endpoints
                .entry(endpoint)
                .or_insert_with(|| {
                    (
                        Arc::new(RateControl::default()),
                        Arc::new(Semaphore::new(6)),
                    )
                })
                .clone();
            let worker_rate = rate.clone();
            tokio::spawn(async move {
                let mut pending: Option<Queued> = None;
                loop {
                    let first = match pending.take() {
                        Some(first) => Some(first),
                        None => rx.recv().await,
                    };
                    let Some(first) = first else { break };
                    if first.result.is_closed() {
                        continue;
                    }
                    let mut bytes = 2 + first.request_bytes; // surrounding JSON array
                    let mut heavy = usize::from(heavy_response(&first.call));
                    let mut batch = vec![first];
                    let collect_until = tokio::time::Instant::now() + Duration::from_millis(3);
                    let limit = worker_rate.batch_size(chain.config().rpc_batch_limit).await;
                    while batch.len() < limit {
                        match tokio::time::timeout_at(collect_until, rx.recv()).await {
                            Ok(Some(next)) if !next.result.is_closed() => {
                                let next_heavy = usize::from(heavy_response(&next.call));
                                if bytes + 1 + next.request_bytes > RPC_BATCH_REQUEST_BYTES
                                    || heavy + next_heavy > RPC_HEAVY_BATCH_ITEMS
                                {
                                    // Already popped: preserve it at the head of the next
                                    // batch. Never drop/requeue it behind later consumers.
                                    pending = Some(next);
                                    break;
                                }
                                bytes += 1 + next.request_bytes;
                                heavy += next_heavy;
                                batch.push(next);
                            }
                            Ok(Some(_)) => continue,
                            _ => break,
                        }
                    }
                    let Ok(permit) = capacity.clone().acquire_owned().await else {
                        break;
                    };
                    let http = http.clone();
                    let url = url.clone();
                    let rate = worker_rate.clone();
                    tokio::spawn(async move {
                        let _permit = permit;
                        batch.retain(|queued| !queued.result.is_closed());
                        if batch.is_empty() {
                            return;
                        }
                        let calls: Vec<_> = batch.iter().map(|item| item.call.clone()).collect();
                        let results = read_with_retry(&http, &url, &calls, &rate, |i| {
                            !batch[i].result.is_closed()
                        })
                        .await;
                        for (queued, result) in batch.into_iter().zip(results) {
                            let _ = queued.result.send(result);
                        }
                    });
                }
            });
            chains.insert(
                chain,
                Arc::new(ChainRpc {
                    url: configured_url,
                    queue,
                    rate,
                    recent: Cache::builder()
                        .max_capacity(4096)
                        .time_to_live(Duration::from_millis(600))
                        .build(),
                    pinned: Cache::builder()
                        .max_capacity(8192)
                        .time_to_live(Duration::from_secs(30))
                        .build(),
                }),
            );
        }
        Self {
            chains: Arc::new(chains),
            client,
            alternatives: Arc::default(),
        }
    }
    pub async fn read(&self, chain: Chain, call: Call) -> Result<Value> {
        validate_call(&call)?;
        let state = self
            .chains
            .get(&chain)
            .ok_or_else(|| AppError::invalid("未配置链节点"))?;
        let kind = cache_kind(&call);
        let receipt_read = call.method == "eth_getTransactionReceipt";
        let key = serde_json::to_string(&call).map_err(|_| AppError::invalid("读取参数无效"))?;
        // The cache-key encoding already contains method/params. Reserve enough
        // bytes for jsonrpc plus even a u64 request id, without re-encoding a
        // potentially multi-megabyte payload just to size the queue entry.
        let request_bytes = key.len() + 48;
        let request = async {
            let (result, receiver) = oneshot::channel();
            state
                .queue
                .try_send(Queued {
                    call,
                    request_bytes,
                    result,
                })
                .map_err(|_| AppError::new("RPC_BUSY", "节点读取繁忙", 429, true))?;
            tokio::time::timeout(Duration::from_secs(45), receiver)
                .await
                .map_err(|_| AppError::unavailable("节点读取超时"))?
                .map_err(|_| AppError::unavailable("节点读取中断"))?
        };
        let result = match kind {
            CacheKind::None => request.await,
            CacheKind::Recent => state
                .recent
                .try_get_with(key, request)
                .await
                .map_err(|e| (*e).clone()),
            CacheKind::Pinned => state
                .pinned
                .try_get_with(key, request)
                .await
                .map_err(|e| (*e).clone()),
        }?;
        // Frontend runners may poll receipts through the read API before the
        // transaction tracker sees them. A new execution must not reuse the
        // pre-confirmation head/balances merely because it has a fresh runtime.
        if receipt_read
            && result["blockNumber"].is_string()
            && ["0x0", "0x1"].contains(&result["status"].as_str().unwrap_or(""))
        {
            state.recent.invalidate_all();
        }
        Ok(result)
    }
    pub async fn read_many(&self, chain: Chain, calls: Vec<Call>) -> Result<Vec<Value>> {
        if calls.is_empty() || calls.len() > 256 {
            return Err(AppError::invalid("读取数量须为 1–256"));
        }
        // Validate the whole request before dispatching its first item.
        for call in &calls {
            validate_call(call)?;
        }
        let mut ordered = stream::iter(calls.into_iter().enumerate())
            .map(|(index, call)| async move { (index, self.read(chain, call).await) })
            .buffer_unordered(64)
            .collect::<Vec<_>>()
            .await;
        ordered.sort_by_key(|(index, _)| *index);
        let results: Vec<_> = ordered.into_iter().map(|(_, row)| row).collect();
        if let Some(error) = results
            .iter()
            .filter_map(|r| r.as_ref().err())
            .find(|e| e.code != "RPC_RATE_LIMIT")
            .or_else(|| results.iter().find_map(|r| r.as_ref().err()))
        {
            let mut error = error.clone();
            if error.code == "RPC_RATE_LIMIT" {
                // Request-local progress only, not a longer-lived balance cache.
                // A client can resume rejected items without discarding successes.
                error.data = Some(json!({"rpcResults": results.iter().map(|row| match row {
                    Ok(value) => json!({"ok":true,"result":value}),
                    Err(_) => json!({"ok":false}),
                }).collect::<Vec<_>>()}));
            }
            return Err(error);
        }
        results.into_iter().collect()
    }
    pub async fn invalidate_latest(&self, chain: Chain) {
        if let Some(state) = self.chains.get(&chain) {
            state.recent.invalidate_all();
        }
    }
    /// No retry here. Unknown send results must be reconciled by transaction hash.
    pub async fn broadcast(&self, chain: Chain, raw: &str) -> Result<Value> {
        if chain == Chain::Bsc {
            return Err(AppError::invalid("BSC 只通过私有捆绑节点提交"));
        }
        let calls = [Call::new("eth_sendRawTransaction", vec![json!(raw)])];
        let state = self
            .chains
            .get(&chain)
            .ok_or_else(|| AppError::invalid("该链节点未配置"))?;
        let admission = state.rate.admit(&[0], |_| true).await;
        let result = match rpc_once(&self.client, &state.url, &calls).await {
            Ok(mut rows) => rows.remove(0),
            Err(error) => Err(error),
        };
        if result.as_ref().is_err_and(|e| e.code == "RPC_RATE_LIMIT") {
            state.rate.limit().await;
        }
        if result.is_ok() {
            state.rate.success(admission.started).await;
        }
        result
    }
}

pub fn validate_call(call: &Call) -> Result<()> {
    if !READ_METHODS.contains(&call.method.as_str()) {
        return Err(AppError::invalid("不允许的读取方法"));
    }
    botai_core::error::reject_secret_fields(&json!(call.params))?;
    if call.params.len() > 4
        || serde_json::to_vec(&call.params).map_or(true, |b| b.len() > 3_000_000)
    {
        return Err(AppError::invalid("读取参数过大"));
    }
    let trace_options = match call.method.as_str() {
        "debug_traceCall" => call.params.get(2),
        "debug_traceTransaction" => call.params.get(1),
        _ => None,
    };
    if trace_options
        .and_then(|p| p.get("tracer"))
        .and_then(Value::as_str)
        .is_some_and(|t| !["callTracer", "prestateTracer"].contains(&t))
    {
        return Err(AppError::invalid("不允许自定义节点执行脚本"));
    }
    Ok(())
}
#[derive(Debug, PartialEq)]
enum CacheKind {
    None,
    Recent,
    Pinned,
}
fn cache_kind(call: &Call) -> CacheKind {
    if [
        "eth_getTransactionCount",
        "eth_estimateGas",
        "eth_simulateV1",
        "debug_traceCall",
        "debug_traceTransaction",
        "trace_callMany",
        "eth_gasPrice",
        "eth_maxPriorityFeePerGas",
    ]
    .contains(&call.method.as_str())
        || call.params.iter().any(|p| p == "pending")
    {
        return CacheKind::None;
    }
    // Numeric height is not immutable during a reorg; only block hashes get the longer cache.
    if call.params.iter().any(|p| p.get("blockHash").is_some())
        || call.method == "eth_getBlockByHash"
    {
        CacheKind::Pinned
    } else {
        CacheKind::Recent
    }
}
async fn read_with_retry(
    client: &Client,
    url: &str,
    calls: &[Call],
    rate: &RateControl,
    active: impl Fn(usize) -> bool,
) -> Vec<Result<Value>> {
    let mut results = vec![Err(AppError::unavailable("节点读取未完成")); calls.len()];
    let mut pending: Vec<usize> = (0..calls.len()).collect();
    for attempt in 0..3 {
        let size = rate.batch_size(pending.len()).await;
        let mut retry = Vec::new();
        for indices in pending.chunks(size) {
            let admission = rate.admit(indices, &active).await;
            if admission.indices.is_empty() {
                continue;
            }
            let batch: Vec<_> = admission
                .indices
                .iter()
                .map(|&i| calls[i].clone())
                .collect();
            let rows = match rpc_once(client, url, &batch).await {
                Ok(rows) => rows,
                Err(error) => vec![Err(error); batch.len()],
            };
            if rows.iter().all(Result::is_ok) {
                rate.success(admission.started).await;
            }
            for (&index, row) in admission.indices.iter().zip(rows) {
                if let Err(error) = &row {
                    if error.code == "RPC_RATE_LIMIT" {
                        rate.limit().await;
                    }
                    if error.retryable {
                        retry.push(index);
                    }
                }
                results[index] = row;
            }
        }
        if retry.is_empty() {
            break;
        }
        pending = retry;
        if attempt < 2 && !rate.limited().await {
            tokio::time::sleep(Duration::from_millis(150 * (1 << attempt))).await;
        }
    }
    results
}
pub async fn rpc_once(client: &Client, url: &str, calls: &[Call]) -> Result<Vec<Result<Value>>> {
    let body: Vec<_> = calls
        .iter()
        .enumerate()
        .map(
            |(i, call)| json!({"jsonrpc":"2.0","id":i+1,"method":call.method,"params":call.params}),
        )
        .collect();
    let response = client
        .post(url)
        .json(&body)
        .send()
        .await
        .map_err(|_| AppError::unavailable("节点网络请求失败"))?;
    let status = response.status();
    if !status.is_success() {
        let error = AppError::new(
            if status.as_u16() == 429 {
                "RPC_RATE_LIMIT"
            } else {
                "RPC_HTTP"
            },
            &format!("节点 HTTP {}", status.as_u16()),
            if status.as_u16() == 429 { 429 } else { 502 },
            status.as_u16() == 429 || status.is_server_error(),
        );
        return Err(
            if calls
                .iter()
                .all(|call| call.method == "eth_sendRawTransaction")
                && matches!(status.as_u16(), 401 | 403 | 413 | 429)
            {
                error.before_send()
            } else {
                error
            },
        );
    }
    let mut response = response;
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| AppError::unavailable("节点响应中断"))?
    {
        if bytes.len() + chunk.len() > 16_000_000 {
            return Err(AppError::new("RPC_RESPONSE", "节点响应过大", 502, false));
        }
        bytes.extend_from_slice(&chunk);
    }
    let replies: Value =
        serde_json::from_slice(&bytes).map_err(|_| AppError::unavailable("节点返回格式无效"))?;
    // Providers can reject a whole JSON-RPC batch with a single error object.
    if let Some(error) = replies.as_object().and_then(|row| row.get("error")) {
        let error = AppError::rpc(
            error["code"].as_i64().unwrap_or(-32000),
            error["message"].as_str().unwrap_or("节点请求失败"),
            None,
        );
        return Err(
            if error.code == "RPC_RATE_LIMIT"
                && calls.iter().all(|c| c.method == "eth_sendRawTransaction")
            {
                error.before_send()
            } else {
                error
            },
        );
    }
    let rows = replies
        .as_array()
        .ok_or_else(|| AppError::unavailable("节点批量返回不完整"))?;
    if rows.len() != calls.len() {
        return Err(AppError::unavailable("节点批量返回数量不符"));
    }
    let mut indexed = HashMap::new();
    for row in rows {
        let id = row
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| AppError::unavailable("节点返回缺少请求编号"))?;
        if row.get("jsonrpc") != Some(&json!("2.0"))
            || id == 0
            || id > calls.len() as u64
            || indexed.insert(id, row).is_some()
        {
            return Err(AppError::unavailable("节点返回编号重复或不符"));
        }
    }
    Ok((1..=calls.len() as u64)
        .map(|id| {
            let row = indexed[&id];
            if let Some(error) = row.get("error") {
                let error = AppError::rpc(
                    error["code"].as_i64().unwrap_or(-32000),
                    error["message"].as_str().unwrap_or("节点执行失败"),
                    error.get("data").cloned(),
                );
                return Err(
                    if error.code == "RPC_RATE_LIMIT"
                        && calls[id as usize - 1].method == "eth_sendRawTransaction"
                    {
                        error.before_send()
                    } else {
                        error
                    },
                );
            }
            row.get("result")
                .cloned()
                .ok_or_else(|| AppError::unavailable("节点缺少结果"))
        })
        .collect())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn item_budget_has_an_exact_sliding_window_and_no_light_load_delay() {
        let rate = Arc::new(RateControl::default());
        let start = Instant::now();
        rate.reserve_items(1).await;
        assert!(start.elapsed() < Duration::from_millis(100));
        let mut events = vec![start];
        let tasks = (0..99)
            .map(|_| {
                let rate = rate.clone();
                tokio::spawn(async move { rate.reserve_items(1).await })
            })
            .collect::<Vec<_>>();
        for task in tasks {
            events.push(task.await.unwrap());
        }
        events.sort_unstable();
        for window in events.windows(RPC_ITEMS_PER_SECOND + 1) {
            assert!(window[RPC_ITEMS_PER_SECOND] - window[0] >= RPC_ITEM_WINDOW);
        }
        for window in events.windows(RPC_BURST_ITEMS + 1) {
            assert!(window[RPC_BURST_ITEMS] - window[0] >= RPC_BURST_WINDOW);
        }
    }
    #[tokio::test]
    async fn fifo_budget_does_not_starve_large_reads_or_broadcasts() {
        let rate = Arc::new(RateControl::default());
        rate.reserve_items(10).await;
        // Poll in a known order before the quota window opens.
        let batch = rate.reserve_items(10);
        let broadcast = rate.reserve_items(1);
        tokio::pin!(batch, broadcast);
        assert!(futures::poll!(&mut batch).is_pending());
        assert!(futures::poll!(&mut broadcast).is_pending());
        let later = (0..30).map(|_| rate.reserve_items(1));
        let (batch_at, send_at, later) =
            tokio::join!(batch, broadcast, futures::future::join_all(later));
        assert!(send_at >= batch_at);
        assert!(later.iter().all(|at| *at >= send_at));
        assert!(later.last().unwrap().duration_since(batch_at) >= RPC_ITEM_WINDOW);
    }
    #[tokio::test]
    async fn expired_recovery_does_not_hold_fifo_behind_slow_old_requests() {
        let rate = RateControl::default();
        rate.limit().await;
        rate.state.lock().await.until = Some(Instant::now() + Duration::from_millis(50));
        let _occupied = rate.recovery.acquire_many(2).await.unwrap();
        tokio::time::timeout(Duration::from_millis(300), rate.reserve_items(1))
            .await
            .expect("expired recovery restores healthy admission even with old HTTPs pending");
    }
    #[tokio::test]
    async fn limited_reads_and_sends_share_two_recovery_lanes() {
        use axum::{Json, Router, routing::post};
        use std::sync::atomic::{AtomicUsize, Ordering};

        let started = Arc::new(AtomicUsize::new(0));
        let release = Arc::new(Semaphore::new(0));
        let app = Router::new().route(
            "/",
            post({
                let started = started.clone();
                let release = release.clone();
                move |Json(rows): Json<Vec<Value>>| {
                    let started = started.clone();
                    let release = release.clone();
                    async move {
                        started.fetch_add(1, Ordering::SeqCst);
                        release.acquire().await.unwrap().forget();
                        Json(json!(
                            rows.iter()
                                .map(|row| json!({
                                    "jsonrpc":"2.0", "id":row["id"], "result":"0x1"
                                }))
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
            Client::builder().no_proxy().build().unwrap(),
            [(Chain::Xlayer, url)].into(),
        );
        rpc.chains[&Chain::Xlayer].rate.limit().await;
        let work = tokio::spawn(async move {
            let (reads, sends) = tokio::join!(
                rpc.read_many(
                    Chain::Xlayer,
                    (0..60)
                        .map(|n| Call::new("eth_getCode", vec![json!(n)]))
                        .collect()
                ),
                futures::future::join_all((0..6).map(|_| rpc.broadcast(Chain::Xlayer, "0x00")))
            );
            assert_eq!(reads.unwrap().len(), 60);
            assert!(sends.iter().all(Result::is_ok));
        });
        tokio::time::timeout(Duration::from_secs(3), async {
            while started.load(Ordering::SeqCst) < 2 {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        // No response has completed: reads and sends together may occupy only
        // two recovery lanes, despite their separate normal scheduling paths.
        tokio::time::sleep(Duration::from_millis(150)).await;
        let before_release = started.load(Ordering::SeqCst);
        release.add_permits(128);
        tokio::time::timeout(Duration::from_secs(3), work)
            .await
            .unwrap()
            .unwrap();
        server.abort();
        assert_eq!(before_release, 2);
    }
    #[tokio::test]
    async fn light_limit_caps_wait_and_recovers_after_three_fresh_successes() {
        let rate = RateControl::default();
        assert_eq!(rate.batch_size(10).await, 10);
        rate.limit().await;
        assert_eq!(rate.batch_size(10).await, 5);
        for _ in 0..8 {
            rate.state.lock().await.blocked = Some(Instant::now() - Duration::from_millis(1));
            rate.limit().await;
            let state = rate.state.lock().await;
            assert!(
                state.blocked.unwrap().duration_since(Instant::now()) <= Duration::from_secs(2)
            );
            assert!(state.until.unwrap().duration_since(Instant::now()) <= Duration::from_secs(5));
        }
        rate.state.lock().await.blocked = Some(Instant::now() - Duration::from_millis(1));
        for _ in 0..3 {
            rate.success(Instant::now() - Duration::from_secs(1)).await;
        }
        assert!(
            rate.limited().await,
            "stale responses cannot clear a fresh limit"
        );
        rate.success(Instant::now()).await;
        rate.success(Instant::now()).await;
        assert!(rate.limited().await);
        rate.success(Instant::now()).await;
        assert!(!rate.limited().await);
        assert_eq!(rate.batch_size(10).await, 10);
    }
    #[test]
    fn unsafe_cache_and_submission_are_excluded() {
        assert_eq!(
            cache_kind(&Call::new(
                "eth_getTransactionCount",
                vec![json!("0x01"), json!("latest")]
            )),
            CacheKind::None
        );
        assert_eq!(
            cache_kind(&Call::new("eth_call", vec![json!({}), json!("pending")])),
            CacheKind::None
        );
        assert!(validate_call(&Call::new("eth_sendRawTransaction", vec![])).is_err());
        assert!(
            validate_call(&Call::new(
                "debug_traceCall",
                vec![
                    json!({}),
                    json!("latest"),
                    json!({"tracer":"custom javascript"})
                ]
            ))
            .is_err()
        );
    }
    #[test]
    fn receipt_settlement_and_preparation_traces_remain_readonly_uncached() {
        let transaction = Call::new(
            "debug_traceTransaction",
            vec![json!("0x01"), json!({"tracer":"callTracer"})],
        );
        let batch = Call::new("trace_callMany", vec![json!([]), json!("latest")]);
        for call in [transaction, batch] {
            assert!(validate_call(&call).is_ok());
            assert_eq!(cache_kind(&call), CacheKind::None);
        }
        assert!(
            validate_call(&Call::new(
                "debug_traceTransaction",
                vec![json!("0x01"), json!({"tracer":"custom javascript"})]
            ))
            .is_err()
        );
    }
}
