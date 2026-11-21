mod record;
mod signed;
#[cfg(any(test, feature = "test-support"))]
mod sqlite;
mod store;
#[cfg(test)]
mod tests;
pub use record::TransactionRecord;
pub use signed::{SignedTransaction, ValidatedBundle, validate_batch, validate_bundle, validate_bundle_with_policy};
pub use store::Store;

use alloy_primitives::Address;
use botai_core::{AppError, Chain, Result};
use botai_rpc::{Call, Rpc};
use futures::{StreamExt, stream};
use reqwest::Client;
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    sync::{Arc, Mutex, Weak},
    time::Duration,
};
fn receipt_logs_match_inclusion(receipt: &Value) -> bool {
    let Some(logs) = receipt.get("logs") else { return true };
    logs.as_array().is_some_and(|rows| rows.iter().all(|log| {
        log.is_object() && log.get("removed").is_none_or(|value| value == false)
            && ["transactionHash", "blockHash"].iter().all(|field| {
                match (log.get(*field), receipt.get(*field)) {
                    (Some(event), Some(original)) => event.as_str().zip(original.as_str())
                        .is_some_and(|(a, b)| a.eq_ignore_ascii_case(b)),
                    _ => true,
                }
            })
    }))
}

fn explicitly_rejected(error: &AppError) -> bool {
    error.not_submitted
        || matches!(
            error.code.as_str(),
            "-32600" | "-32601" | "-32602" | "RPC_RATE_LIMIT"
        )
        || [
            "insufficient funds",
            "invalid sender",
            "intrinsic gas too low",
            "unsupported transaction type",
            "exceeds block gas",
            "account bundle size limit",
            "rate limit",
            "too many requests",
            "quota exceeded",
        ]
        .iter()
        .any(|s| error.message.to_lowercase().contains(s))
}
type Lanes = Arc<Mutex<HashMap<(Chain, String), Weak<tokio::sync::Mutex<()>>>>>;

#[derive(Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SubmitOptions {
    /// Legacy Robinhood compatibility only. Standard RPC submission does not
    /// support BackRunMe rewards; this field is validated but never forwarded.
    pub backrunme_reward_address: Option<Address>,
}

#[derive(Clone)]
pub struct Transactions {
    pub store: Store,
    rpc: Rpc,
    http: Client,
    authorization: Arc<str>,
    relay_url: Arc<str>,
    lanes: Lanes,
    authorization_check: Option<Arc<dyn Fn() -> Result<()> + Send + Sync>>,
}
impl Transactions {
    pub fn new(store: Store, rpc: Rpc, http: Client, authorization: String) -> Self {
        Self {
            store,
            rpc,
            http,
            authorization: authorization.into(),
            relay_url: "https://api.blxrbdn.com".into(),
            lanes: Arc::default(),
            authorization_check: None,
        }
    }
    pub fn authorized(&self, check: impl Fn() -> Result<()> + Send + Sync + 'static) -> Self {
        let mut service = self.clone();
        service.authorization_check = Some(Arc::new(check));
        service
    }
    fn require_authorization(&self) -> Result<()> {
        if let Some(check) = &self.authorization_check {
            check().map_err(AppError::before_send)?;
        }
        Ok(())
    }
    /// Keep authorization and shared nonce lanes when routing a user request.
    pub fn with_rpc(mut self, rpc: Rpc) -> Self {
        self.rpc = rpc;
        self
    }
    /// Test builds can replace the relay only with a loopback HTTP endpoint.
    #[cfg(feature = "test-support")]
    pub fn with_local_relay(mut self, endpoint: &str) -> Result<Self> {
        let url =
            reqwest::Url::parse(endpoint).map_err(|_| AppError::invalid("Invalid local relay"))?;
        if url.scheme() != "http"
            || !matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"))
        {
            return Err(AppError::invalid("Fork relay must be loopback HTTP"));
        }
        self.relay_url = endpoint.into();
        Ok(self)
    }
    fn lane(&self, chain: Chain, sender: &str) -> Arc<tokio::sync::Mutex<()>> {
        let mut lanes = self.lanes.lock().unwrap_or_else(|error| error.into_inner());
        lanes.retain(|_, lock| lock.strong_count() > 0);
        let entry = lanes.entry((chain, sender.to_owned())).or_default();
        if let Some(lock) = entry.upgrade() {
            return lock;
        }
        let lock = Arc::new(tokio::sync::Mutex::new(()));
        *entry = Arc::downgrade(&lock);
        lock
    }
    /// One read-only worker covers fresh submissions and restart recovery.
    /// Unknown transactions are never rebroadcast or rejected on a timer.
    pub fn start_tracking(&self) -> tokio::task::JoinHandle<()> {
        let service = self.clone();
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(Duration::from_secs(2));
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                interval.tick().await;
                let _ = service.refresh_pending().await;
            }
        })
    }
    pub async fn refresh_pending(&self) -> Result<usize> {
        let rows = self.store.pending()?;
        let count = rows.len();
        stream::iter(rows)
            .for_each_concurrent(8, |row| async move {
                let _ = self.refresh(row.chain, &row.transaction_hash).await;
            })
            .await;
        Ok(count)
    }
    pub async fn submit(&self, chain: Chain, raws: Vec<String>) -> Result<Vec<TransactionRecord>> {
        self.submit_with_options(chain, raws, SubmitOptions::default())
            .await
    }
    pub async fn submit_with_options(
        &self,
        chain: Chain,
        raws: Vec<String>,
        options: SubmitOptions,
    ) -> Result<Vec<TransactionRecord>> {
        self.require_authorization()?;
        if options
            .backrunme_reward_address
            .is_some_and(|address| address.is_zero() || chain != Chain::Robinhood)
        {
            return Err(AppError::invalid("返佣地址或链无效").before_send());
        }
        if chain == Chain::Bsc {
            return Err(AppError::invalid("BSC 必须使用私有捆绑提交").before_send());
        }
        let signed = validate_batch(chain, &raws).map_err(AppError::before_send)?;
        let mut lanes: BTreeMap<String, Vec<(usize, SignedTransaction)>> = BTreeMap::new();
        let count = signed.len();
        for (index, tx) in signed.into_iter().enumerate() {
            lanes
                .entry(tx.sender.clone())
                .or_default()
                .push((index, tx));
        }
        let service = self.clone();
        // Dropping a browser request cannot cancel the accepted backend task.
        tokio::spawn(async move {
            let mut results: Vec<Option<TransactionRecord>> = vec![None; count];
            let rows = stream::iter(lanes.into_values())
                .map(|lane| {
                    let service = service.clone();
                    async move {
                        // A lane spans the entire request, including dependency waits.
                        // Separate requests for the same sender share this lock.
                        let lock = service.lane(chain, &lane[0].1.sender);
                        let _guard = lock.lock().await;
                        let mut blocked = false;
                        let mut results = Vec::new();
                        let length = lane.len();
                        for (position, (index, tx)) in lane.into_iter().enumerate() {
                            let mut record = TransactionRecord::new(chain, &tx);
                            if blocked {
                                record.status = "not_submitted".into();
                                record.message = Some("前置交易未确认，本笔未发送".into());
                            } else {
                                match service.send_one(chain, &tx).await {
                                    Ok(sent) => record = sent,
                                    Err(error) => {
                                        record.status = "not_submitted".into();
                                        record.message = Some(error.message);
                                    }
                                }
                                if ["accepted", "ambiguous"].contains(&record.status.as_str())
                                    && position + 1 < length
                                {
                                    blocked = !service
                                        .wait_dependency(chain, &tx.hash)
                                        .await
                                        .unwrap_or(false);
                                } else {
                                    blocked =
                                        record.status != "accepted" && record.status != "confirmed";
                                }
                            }
                            results.push((index, record));
                        }
                        results
                    }
                })
                .buffer_unordered(8)
                .collect::<Vec<_>>()
                .await;
            for lane in rows {
                for (index, record) in lane {
                    results[index] = Some(record);
                }
            }
            results
                .into_iter()
                .map(|row| row.ok_or_else(|| AppError::unavailable("提交结果不完整")))
                .collect()
        })
        .await
        .map_err(|_| AppError::unavailable("提交任务中断，请查询原哈希"))?
    }
    async fn send_one(&self, chain: Chain, tx: &SignedTransaction) -> Result<TransactionRecord> {
        if let Some(existing) = self.store.get(chain, &tx.hash)? {
            if !["rejected", "not_included"].contains(&existing.status.as_str()) {
                return Ok(existing);
            }
        }
        for previous in self.store.predecessors(chain, &tx.sender, tx.nonce)? {
            if !self
                .wait_dependency(chain, &previous.transaction_hash)
                .await?
            {
                return Err(AppError::new(
                    "DEPENDENCY_UNCONFIRMED",
                    "前置交易未确认，本笔未发送",
                    409,
                    true,
                )
                .before_send());
            }
        }
        // Recheck after a queued lane/dependency wait; never send on a revoked session.
        self.require_authorization()?;
        if let Some(existing) = self.store.claim(chain, tx)? {
            return Ok(existing);
        }
        let mut record = TransactionRecord::new(chain, tx);
        let result = self.rpc.broadcast(chain, &tx.raw).await;
        match result {
            Ok(value) => {
                let hash = value
                    .as_str()
                    .or_else(|| value["txHash"].as_str())
                    .or_else(|| value["tx_hash"].as_str());
                if hash.is_some_and(|s| {
                    s.trim_start_matches("0x")
                        .eq_ignore_ascii_case(tx.hash.trim_start_matches("0x"))
                }) {
                    record.status = "accepted".into();
                } else {
                    record.message = Some("接收结果未确认，正在查询原哈希".into());
                }
            }
            Err(error) => {
                let text = error.message.to_lowercase();
                if text.contains("already known") {
                    record.status = "accepted".into();
                } else if explicitly_rejected(&error) {
                    record.status = "rejected".into();
                }
                record.message = Some(error.message);
            }
        }
        // A persistence failure after sending cannot be reported as not-submitted.
        if self.store.update(&record).is_err() {
            record.status = "ambiguous".into();
            record.message = Some("发送后状态记录失败，请查询原哈希".into());
        }
        Ok(record)
    }
    async fn relay(&self, payload: Value) -> Result<Value> {
        let response = self.http.post(self.relay_url.as_ref()).header("authorization", self.authorization.as_ref())
            .json(&json!({"jsonrpc":"2.0","id":1,"method":payload["method"],"params":payload["params"]})).send().await
            .map_err(|_| AppError::unavailable("发送响应中断，请查询原哈希"))?;
        let status = response.status();
        if !status.is_success() {
            let error = AppError::new(
                "RELAY_HTTP",
                &format!("发送节点 HTTP {}", status.as_u16()),
                502,
                status.as_u16() == 429 || status.is_server_error(),
            );
            return Err(if matches!(status.as_u16(), 401 | 403 | 413 | 429) {
                error.before_send()
            } else {
                error
            });
        }
        let value: Value = response
            .json()
            .await
            .map_err(|_| AppError::unavailable("发送返回格式异常"))?;
        if let Some(error) = value.get("error") {
            let error = AppError::rpc(
                error["code"].as_i64().unwrap_or(-32000),
                error["message"].as_str().unwrap_or("节点拒绝发送"),
                None,
            );
            let fork_rollback = self.relay_url.starts_with("http://") && error.code == "-32003"
                && error.message.starts_with("local atomic bundle rolled back:");
            return Err(if fork_rollback || explicitly_rejected(&error) {
                error.before_send()
            } else {
                error
            });
        }
        value
            .get("result")
            .cloned()
            .ok_or_else(|| AppError::unavailable("发送节点未返回结果"))
    }
    pub async fn submit_bundle(&self, raws: Vec<String>, max_block: u64) -> Result<Value> {
        self.submit_bundle_with_policy(raws, max_block, |_| Ok(())).await
    }

    pub async fn submit_bundle_with_policy(
        &self,
        raws: Vec<String>,
        max_block: u64,
        policy: impl Fn(&alloy_consensus::TxEnvelope) -> Result<()>,
    ) -> Result<Value> {
        self.submit_checked_bundle(raws, max_block, |raws| {
            Ok((validate_bundle_with_policy(raws, |tx, _| policy(tx))?, false))
        }).await
    }

    pub async fn submit_checked_bundle(
        &self,
        raws: Vec<String>,
        max_block: u64,
        check: impl FnOnce(&[String]) -> Result<(ValidatedBundle, bool)>,
    ) -> Result<Value> {
        self.submit_bundle_after_check(max_block, async { check(&raws) }).await
    }

    pub async fn submit_bundle_after_check(
        &self,
        max_block: u64,
        check: impl std::future::Future<Output = Result<(ValidatedBundle, bool)>>,
    ) -> Result<Value> {
        self.require_authorization()?;
        if self.authorization.is_empty() {
            return Err(
                AppError::new("AUTH_NOT_CONFIGURED", "后端发送认证未配置", 503, false)
                    .before_send(),
            );
        }
        if max_block == 0 {
            return Err(AppError::invalid("捆绑截止区块无效").before_send());
        }
        let (bundle, no_merge) = check.await.map_err(AppError::before_send)?;
        let signed = bundle.0;
        // Claim the entire bundle atomically. Never send a partially claimed bundle.
        // A caller can explicitly retry a previously expired bundle. Refresh the
        // original hashes first; active/unknown transactions retain nonce claims.
        for tx in &signed {
            if self.store.get(Chain::Bsc, &tx.hash)?.is_some() {
                self.refresh(Chain::Bsc, &tx.hash).await?;
            }
        }
        self.require_authorization()?;
        self.store.claim_bundle(&signed, max_block)?;
        let service = self.clone();
        tokio::spawn(async move {
            let result = service.relay(json!({"method":"blxr_submit_bundle","params":{"txs":signed.iter().map(|tx|tx.raw.trim_start_matches("0x")).collect::<Vec<_>>(),
                "blockchain_network":"BSC-Mainnet","max_block_number":max_block,"reverting_tx_hashes":[],"mev_builders":{"all":""},"no_merge":no_merge}})).await;
            let result = result.and_then(|value| {
                if value["bundleHash"].as_str().is_some_and(|s| s.starts_with("0x") && s.len()==66 && s[2..].bytes().all(|c| c.is_ascii_hexdigit())) { Ok(value) }
                else { Err(AppError::unavailable("捆绑接收结果不完整，请查询原哈希")) }
            });
            for tx in &signed {
                let mut row = TransactionRecord::new(Chain::Bsc, tx);
                row.max_block_number = Some(max_block);
                match &result {
                    Ok(_) => row.status = "accepted".into(),
                    Err(error) => {
                        if explicitly_rejected(error) { row.status = "rejected".into(); }
                        row.message = Some(error.message.clone());
                    }
                }
                service.store.update(&row)?;
            }
            result
        }).await.map_err(|_| AppError::unavailable("捆绑任务中断，请查询原哈希"))?
    }
    /// A stored result normally requires no RPC. Older records with a removed
    /// or mismatched log need the same canonical check as a manual lookup.
    pub async fn tracked(&self, chain: Chain, hash: &str) -> Result<Option<TransactionRecord>> {
        let result = self.store.get(chain, hash)?;
        if result.as_ref().and_then(|row| row.receipt.as_ref())
            .is_some_and(|receipt| !receipt_logs_match_inclusion(receipt)) {
            return self.refresh(chain, hash).await;
        }
        Ok(result)
    }

    pub async fn refresh(&self, chain: Chain, hash: &str) -> Result<Option<TransactionRecord>> {
        let Some(mut record) = self.store.get(chain, hash)? else {
            return Ok(None);
        };
        if record.receipt.as_ref().is_some_and(|receipt| !receipt_logs_match_inclusion(receipt)) {
            // Recover a terminal record persisted by an older service from the original hash.
            record.status = "ambiguous".into();
            record.receipt = None;
        }
        if [
            "confirmed",
            "reverted",
            "rejected",
            "not_submitted",
            "not_included",
        ]
        .contains(&record.status.as_str())
        {
            return Ok(Some(record));
        }
        let receipt = self
            .rpc
            .read(
                chain,
                Call::new("eth_getTransactionReceipt", vec![json!(hash)]),
            )
            .await?;
        if !receipt.is_null()
            && receipt["transactionHash"]
                .as_str()
                .is_some_and(|s| s.eq_ignore_ascii_case(hash))
            && ["0x0", "0x1"].contains(&receipt["status"].as_str().unwrap_or(""))
            && receipt["blockNumber"].is_string()
            && receipt_logs_match_inclusion(&receipt)
        {
            record.status = if receipt["status"] == "0x1" {
                "confirmed"
            } else {
                "reverted"
            }
            .into();
            record.receipt = Some(receipt);
            record.message = None;
            self.store.update(&record)?;
            self.rpc.invalidate_latest(chain).await;
        } else if receipt.is_null() && record.max_block_number.is_some() {
            let block = self
                .rpc
                .read(chain, Call::new("eth_blockNumber", vec![]))
                .await?;
            let block =
                u64::from_str_radix(block.as_str().unwrap_or("").trim_start_matches("0x"), 16)
                    .unwrap_or(0);
            if block > record.max_block_number.unwrap().saturating_add(3) {
                // Confirm again after cache invalidation so a cached null receipt
                // cannot release a nonce whose transaction was just included.
                self.rpc.invalidate_latest(chain).await;
                let again = self
                    .rpc
                    .read(
                        chain,
                        Call::new("eth_getTransactionReceipt", vec![json!(hash)]),
                    )
                    .await?;
                if again.is_null() {
                    record.status = "not_included".into();
                    record.message = Some("捆绑已过期，原交易未上链".into());
                    self.store.update(&record)?;
                }
            }
        }
        Ok(Some(record))
    }
    async fn wait_dependency(&self, chain: Chain, hash: &str) -> Result<bool> {
        for _ in 0..60 {
            if let Ok(Some(record)) = self.refresh(chain, hash).await {
                if record.status == "confirmed" {
                    return Ok(true);
                }
                if ["reverted", "rejected", "not_included"].contains(&record.status.as_str()) {
                    return Ok(false);
                }
            }
            tokio::time::sleep(Duration::from_millis(500)).await;
        }
        Ok(false)
    }
}
