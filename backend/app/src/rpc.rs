//! Minimal JSON-RPC client: single calls and batched calls (one HTTP request for many wallets).
use crate::error::{ApiError, Result};
use serde_json::{Value, json};
use std::{sync::Arc, time::Duration};

#[derive(Clone)]
pub struct Rpc {
    http: reqwest::Client,
    url: Arc<str>,
}

pub const MAX_BATCH: usize = 100;

impl Rpc {
    pub fn new(http: reqwest::Client, url: &str) -> Self {
        Self { http, url: url.into() }
    }

    pub async fn call(&self, method: &str, params: Value) -> Result<Value> {
        unwrap(self.response(method, params).await?)
    }

    /// Preserve the JSON-RPC error code and data when the caller needs to distinguish an EVM revert.
    pub(super) async fn response(&self, method: &str, params: Value) -> Result<Value> {
        let body = json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params});
        self.post(&body).await
    }

    /// Batched request; results are returned in request order. Each item is Ok(result) or Err(rpc error).
    pub async fn batch(&self, calls: &[(&str, Value)]) -> Result<Vec<Result<Value>>> {
        let mut out = Vec::with_capacity(calls.len());
        for chunk in calls.chunks(MAX_BATCH) {
            let body: Vec<Value> = chunk
                .iter()
                .enumerate()
                .map(|(i, (m, p))| json!({"jsonrpc": "2.0", "id": i, "method": m, "params": p}))
                .collect();
            let value = self.post(&Value::Array(body)).await?;
            let mut rows = value.as_array().cloned().ok_or_else(|| ApiError::unavailable("节点批量响应格式无效"))?;
            if rows.len() != chunk.len() {
                return Err(ApiError::unavailable("节点批量响应数量不符"));
            }
            rows.sort_by_key(|r| r["id"].as_u64().unwrap_or(u64::MAX));
            for (id, row) in rows.into_iter().enumerate() {
                if row["id"].as_u64() != Some(id as u64) {
                    return Err(ApiError::unavailable("节点批量响应编号不符"));
                }
                out.push(unwrap(row));
            }
        }
        Ok(out)
    }

    async fn post(&self, body: &Value) -> Result<Value> {
        // Ordered launch simulation may execute a full BSC block of contract calls.
        let timeout = if body["method"] == "eth_simulateV1" { 75 } else { 15 };
        let response = self
            .http
            .post(self.url.as_ref())
            .json(body)
            .timeout(Duration::from_secs(timeout))
            .send()
            .await
            .map_err(|_| ApiError::unavailable("节点请求失败"))?;
        if !response.status().is_success() {
            return Err(ApiError::new(
                "RPC_HTTP",
                format!("节点 HTTP {}", response.status().as_u16()),
                502,
                true,
            ));
        }
        response.json().await.map_err(|_| ApiError::unavailable("节点响应格式无效"))
    }
}

fn unwrap(value: Value) -> Result<Value> {
    if let Some(error) = value.get("error") {
        let message = error["message"].as_str().unwrap_or("节点拒绝请求").chars().take(200).collect::<String>();
        return Err(ApiError::new("RPC_ERROR", message, 422, false));
    }
    value.get("result").cloned().ok_or_else(|| ApiError::unavailable("节点未返回结果"))
}

pub fn hex_u64(v: &Value) -> Result<u64> {
    let s = v.as_str().ok_or_else(|| ApiError::unavailable("节点返回值无效"))?;
    u64::from_str_radix(s.trim_start_matches("0x"), 16).map_err(|_| ApiError::unavailable("节点返回值无效"))
}
