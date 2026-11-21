pub mod flap;
mod flap_catalog_cache;
pub mod flap_curve;
pub mod four;
mod four_gate;
#[cfg(test)]
mod four_isolation_tests;
pub mod image;
pub mod next;
use botai_core::{AppError, Result};
use botai_rpc::Rpc;
use moka::future::Cache;
use reqwest::{Client, Response};
use serde_json::Value;
use std::time::Duration;

#[derive(Clone)]
pub struct Integrations {
    pub http: Client,
    pub rpc: Rpc,
    pub cache: Cache<String, Value>,
    pub(crate) catalogs: flap_catalog_cache::Catalogs,
    pub(crate) four_gate: four_gate::FourGate,
}
impl Integrations {
    pub fn new(http: Client, rpc: Rpc) -> Self {
        Self {
            http,
            rpc,
            catalogs: Default::default(),
            four_gate: Default::default(),
            cache: Cache::builder()
                .max_capacity(4096)
                .time_to_live(Duration::from_secs(300))
                .build(),
        }
    }

    /// No network request: suitable for rejecting a cooling upload before reading its body.
    pub fn four_preflight(&self) -> Result<()> {
        self.four_gate.preflight()
    }

    /// Hold until the upload finishes; at most two multipart bodies can be buffered.
    pub fn four_upload_slot(&self) -> Result<tokio::sync::OwnedSemaphorePermit> {
        self.four_gate.upload_slot()
    }

    /// Bound JSON body memory without blocking chain-only actions during HTTP cooling.
    pub fn four_json_slot(&self) -> Result<tokio::sync::OwnedSemaphorePermit> {
        self.four_gate.json_slot()
    }

    /// Observed official HTTP availability only; chain RPC has an independent lifecycle.
    pub fn four_status(&self) -> Value {
        self.four_gate.status()
    }
}
pub async fn bounded_text(mut response: Response, label: &str, limit: usize) -> Result<String> {
    if !response.status().is_success() {
        // Cloudflare answers a managed challenge with 403 + `cf-mitigated: challenge`: the official service is
        // blocking this server's network (IP reputation), not rejecting the request. It cannot be passed
        // from a server and must not be worked around; the server needs an egress the platform allows.
        if response.status() == reqwest::StatusCode::FORBIDDEN
            && response
                .headers()
                .get("cf-mitigated")
                .is_some_and(|v| v.as_bytes().eq_ignore_ascii_case(b"challenge"))
        {
            return Err(AppError::new(
                "OFFICIAL_CHALLENGED",
                &format!("{label} 官方接口对本服务器所在网络开启了 Cloudflare 人机验证（403），本服务器无法调用；需要在官方允许的服务器网络上运行，或请官方把服务器 IP 加入白名单"),
                502,
                false,
            ));
        }
        if label.starts_with("Flap") && response.status() == reqwest::StatusCode::FORBIDDEN {
            return Err(AppError::new(
                "OFFICIAL_FORBIDDEN",
                &format!("{label}被官方拒绝（403），请检查服务器访问权限"),
                502,
                false,
            ));
        }
        return Err(AppError::new(
            "OFFICIAL_HTTP",
            &format!("{label} HTTP {}", response.status()),
            502,
            response.status().is_server_error() || response.status().as_u16() == 429,
        ));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|_| AppError::unavailable(&format!("{label} 响应中断")))?
    {
        if bytes.len() + chunk.len() > limit {
            return Err(AppError::new(
                "OFFICIAL_RESPONSE",
                "官方响应过大",
                502,
                false,
            ));
        }
        bytes.extend_from_slice(&chunk);
    }
    String::from_utf8(bytes).map_err(|_| AppError::unavailable("官方响应编码无效"))
}
pub async fn bounded_json(response: Response, label: &str, limit: usize) -> Result<Value> {
    serde_json::from_str(&bounded_text(response, label, limit).await?)
        .map_err(|_| AppError::unavailable(&format!("{label} 响应不是 JSON")))
}
pub fn address(value: &str) -> Result<alloy_primitives::Address> {
    value.parse().map_err(|_| AppError::invalid("地址无效"))
}

#[cfg(test)]
mod http_tests {
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[tokio::test]
    async fn flap_official_forbidden_is_not_a_schema_error_or_retryable() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/fixture", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 4096];
            stream.read(&mut request).await.unwrap();
            stream
                .write_all(
                    b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )
                .await
                .unwrap();
        });
        let response = Client::builder()
            .no_proxy()
            .build()
            .unwrap()
            .get(url)
            .send()
            .await
            .unwrap();
        let error = bounded_json(response, "Flap 自定义列表", 1024)
            .await
            .unwrap_err();
        assert_eq!(error.code, "OFFICIAL_FORBIDDEN");
        assert!(!error.retryable);
        assert!(error.message.contains("403"));
        assert!(!error.message.contains("格式"));
        server.await.unwrap();
    }

    #[tokio::test]
    async fn cloudflare_challenge_is_reported_as_a_network_block() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/public/config", listener.local_addr().unwrap());
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = [0u8; 4096];
            stream.read(&mut request).await.unwrap();
            stream
                .write_all(b"HTTP/1.1 403 Forbidden\r\ncf-mitigated: challenge\r\nContent-Type: text/html\r\nContent-Length: 31\r\nConnection: close\r\n\r\n<title>Just a moment...</title>")
                .await
                .unwrap();
        });
        let response = Client::builder().no_proxy().build().unwrap().get(url).send().await.unwrap();
        let error = bounded_json(response, "Four", 1024).await.unwrap_err();
        assert_eq!(error.code, "OFFICIAL_CHALLENGED");
        assert!(!error.retryable);
        assert!(error.message.contains("Cloudflare"));
        server.await.unwrap();
    }
}
