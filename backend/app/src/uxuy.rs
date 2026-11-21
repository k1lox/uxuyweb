//! Server-only authenticated UXUY EVM quote gateway. The signing key and bearer never enter a route plan.
use crate::error::{ApiError, Result};
use alloy_primitives::{U256, hex};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use futures::StreamExt;
use md5::{Digest, Md5};
use ring::{
    rand::{SecureRandom, SystemRandom},
    rsa::KeyPair,
    signature::RSA_PKCS1_SHA256,
};
use serde_json::{Value, json};
use spki::{SubjectPublicKeyInfoRef, der::asn1::BitStringRef};
use std::{
    sync::Arc,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone)]
pub struct Uxuy(Option<Arc<Client>>);

struct Client {
    http: reqwest::Client,
    url: String,
    jti: String,
    key: KeyPair,
}

fn bad_key() -> ApiError {
    ApiError::new("UXUY_CREDENTIALS", "UXUY 认证配置无效", 503, false)
}

impl Uxuy {
    pub fn disabled() -> Self {
        Self(None)
    }

    pub fn new(app_id: &str, pem: &[u8]) -> Result<Self> {
        if app_id.is_empty()
            || app_id.len() > 128
            || !app_id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_'))
        {
            return Err(bad_key());
        }
        let text = std::str::from_utf8(pem).map_err(|_| bad_key())?.trim();
        let (label, pkcs8) = if text.starts_with("-----BEGIN RSA PRIVATE KEY-----") {
            ("RSA PRIVATE KEY", false)
        } else {
            ("PRIVATE KEY", true)
        };
        let b64 = text
            .strip_prefix(&format!("-----BEGIN {label}-----"))
            .and_then(|s| s.strip_suffix(&format!("-----END {label}-----")))
            .ok_or_else(bad_key)?;
        let der = STANDARD
            .decode(b64.split_ascii_whitespace().collect::<String>())
            .map_err(|_| bad_key())?;
        let key = if pkcs8 {
            KeyPair::from_pkcs8(&der)
        } else {
            KeyPair::from_der(&der)
        }
        .map_err(|_| bad_key())?;
        // UXUY registers the lowercase MD5 of the standard Base64 SHA-256 fingerprint
        // of the RSA public key in X.509 SubjectPublicKeyInfo form. ring stores PKCS#1.
        let public_key = SubjectPublicKeyInfoRef {
            algorithm: pkcs1::ALGORITHM_ID,
            subject_public_key: BitStringRef::from_bytes(key.public().as_ref())
                .map_err(|_| bad_key())?,
        };
        let fingerprint = public_key.fingerprint_base64().map_err(|_| bad_key())?;
        let jti = hex::encode(Md5::digest(fingerprint.as_bytes()));
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(12))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|_| bad_key())?;
        Ok(Self(Some(Arc::new(Client {
            http,
            key,
            jti,
            url: format!("https://gwapi.ourdex.com/bnbchain/{app_id}"),
        }))))
    }

    #[cfg(test)]
    pub(super) fn for_loopback(app_id: &str, pem: &[u8], addr: std::net::SocketAddr) -> Self {
        assert!(addr.ip().is_loopback());
        let mut client = Self::new(app_id, pem).unwrap();
        Arc::get_mut(client.0.as_mut().unwrap()).unwrap().url =
            format!("http://{addr}/bnbchain/{app_id}");
        client
    }

    fn auth(client: &Client, now: u64) -> Result<String> {
        let header = json!({"typ":"JWT","alg":"RS256","jti":client.jti});
        let claims = json!({"iss":"app","jti":client.jti,"ts":now,"exp":now + 300});
        let unsigned = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(header.to_string()),
            URL_SAFE_NO_PAD.encode(claims.to_string())
        );
        let mut signature = vec![0_u8; client.key.public().modulus_len()];
        client
            .key
            .sign(
                &RSA_PKCS1_SHA256,
                &SystemRandom::new(),
                unsigned.as_bytes(),
                &mut signature,
            )
            .map_err(|_| bad_key())?;
        Ok(format!(
            "{}.{}",
            unsigned,
            URL_SAFE_NO_PAD.encode(signature)
        ))
    }

    pub async fn quote(&self, params: Value) -> Result<Vec<Value>> {
        let client = self.0.as_ref().ok_or_else(|| {
            ApiError::new("UXUY_NOT_CONFIGURED", "尚未配置 UXUY 报价服务", 503, false)
        })?;
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|_| bad_key())?
            .as_secs();
        let res = client
            .http
            .post(&client.url)
            .bearer_auth(Self::auth(client, now)?)
            .json(&json!({"jsonrpc":"2.0","id":1,"method":"dex_offlineQuote","params":[params]}))
            .send()
            .await
            .map_err(|_| ApiError::unavailable("UXUY 报价请求失败"))?;
        let status = res.status();
        if matches!(status.as_u16(), 401 | 403) {
            return Err(ApiError::new(
                "UXUY_AUTH_REJECTED",
                format!(
                    "UXUY 网关拒绝服务端认证（HTTP {}），本次未取得报价",
                    status.as_u16()
                ),
                502,
                false,
            ));
        }
        if !status.is_success() {
            return Err(ApiError::new(
                "UXUY_HTTP",
                format!("UXUY 报价服务返回 HTTP {}", status.as_u16()),
                502,
                status.is_server_error() || status.as_u16() == 429,
            ));
        }
        let mut buf = Vec::new();
        let mut chunks = res.bytes_stream();
        while let Some(chunk) = chunks.next().await {
            let chunk = chunk.map_err(|_| ApiError::unavailable("UXUY 报价响应中断"))?;
            if buf.len() + chunk.len() > 2 * 1024 * 1024 {
                return Err(ApiError::unavailable("UXUY 报价响应过大"));
            }
            buf.extend_from_slice(&chunk);
        }
        let mut body: Value = serde_json::from_slice(&buf)
            .map_err(|_| ApiError::unavailable("UXUY 报价响应格式无效"))?;
        if body["jsonrpc"] != "2.0" || body["id"].as_u64() != Some(1) || !body["error"].is_null() {
            return Err(ApiError::new(
                "UXUY_QUOTE_FAILED",
                "UXUY 拒绝本次报价",
                422,
                false,
            ));
        }
        match body["result"].take() {
            Value::Array(rows) if rows.len() <= 10 => Ok(rows),
            _ => Err(ApiError::unavailable("UXUY 路由列表格式无效")),
        }
    }

    pub fn order_id() -> Result<String> {
        // UXUY encodes orderId as a decimal uint256 in TradeParams.
        let mut bytes = [0u8; 32];
        SystemRandom::new()
            .fill(&mut bytes)
            .map_err(|_| ApiError::unavailable("无法生成本次报价编号"))?;
        Ok(U256::from_be_bytes(bytes).to_string())
    }
}
