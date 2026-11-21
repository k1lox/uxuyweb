use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use botai_core::{AppError, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use web_push::SubscriptionInfo;
#[derive(Clone, Serialize, Deserialize)]
pub struct Device {
    pub token_hash: String,
    pub subscription: SubscriptionInfo,
    pub since: u64,
    pub error: Option<String>,
}
pub fn hash(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}
pub fn token_valid(token: &str) -> bool {
    token.len() == 43 && URL_SAFE_NO_PAD.decode(token).is_ok_and(|b| b.len() == 32)
}
pub fn subscription(value: serde_json::Value) -> Result<SubscriptionInfo> {
    let s: SubscriptionInfo =
        serde_json::from_value(value).map_err(|_| AppError::invalid("设备推送信息无效"))?;
    if s.endpoint.len() > 2048 {
        return Err(AppError::invalid("推送地址过长"));
    }
    let u = reqwest::Url::parse(&s.endpoint).map_err(|_| AppError::invalid("推送地址无效"))?;
    let h = u.host_str().unwrap_or("");
    let allowed = [
        "fcm.googleapis.com",
        "updates.push.services.mozilla.com",
        "web.push.apple.com",
        "wns.windows.com",
    ]
    .contains(&h)
        || h.ends_with(".push.apple.com")
        || h.ends_with(".notify.windows.com");
    if !allowed
        || u.scheme() != "https"
        || !u.username().is_empty()
        || u.password().is_some()
        || u.port().is_some()
        || u.fragment().is_some()
        || u.path() == "/"
    {
        return Err(AppError::invalid("暂不支持此浏览器推送服务"));
    }
    let key = URL_SAFE_NO_PAD
        .decode(&s.keys.p256dh)
        .map_err(|_| AppError::invalid("推送密钥无效"))?;
    let auth = URL_SAFE_NO_PAD
        .decode(&s.keys.auth)
        .map_err(|_| AppError::invalid("推送密钥无效"))?;
    if key.len() != 65
        || key[0] != 4
        || auth.len() != 16
        || p256::PublicKey::from_sec1_bytes(&key).is_err()
    {
        return Err(AppError::invalid("推送密钥无效"));
    }
    Ok(s)
}
