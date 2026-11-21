use serde::{Deserialize, Serialize};
use serde_json::Value;

pub type Result<T> = std::result::Result<T, AppError>;
#[derive(Clone, Debug, Serialize, Deserialize, thiserror::Error)]
#[error("{message}")]
#[serde(rename_all = "camelCase")]
pub struct AppError {
    pub code: String,
    pub message: String,
    pub status: u16,
    pub retryable: bool,
    #[serde(default)]
    pub not_submitted: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}
impl AppError {
    pub fn new(code: &str, message: &str, status: u16, retryable: bool) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
            status,
            retryable,
            not_submitted: false,
            data: None,
        }
    }
    pub fn invalid(message: &str) -> Self {
        Self::new("INVALID_INPUT", message, 400, false)
    }
    pub fn unavailable(message: &str) -> Self {
        Self::new("UPSTREAM_UNAVAILABLE", message, 503, true)
    }
    pub fn before_send(mut self) -> Self {
        self.not_submitted = true;
        self
    }
    pub fn rpc(code: i64, message: &str, data: Option<Value>) -> Self {
        let lower = message.to_ascii_lowercase();
        if code != 3
            && !lower.contains("revert")
            && ([
                "rate limit",
                "rate-limit",
                "rate_limit",
                "too many requests",
                "quota exceeded",
                "request limit",
            ]
            .iter()
            .any(|needle| lower.contains(needle))
                || code == 429)
        {
            return Self::new("RPC_RATE_LIMIT", "节点限流，请稍后重试", 429, true);
        }
        let mut error = Self::new(
            &code.to_string(),
            &redact(message),
            502,
            matches!(code, -32005 | -32014 | -32603),
        );
        // Revert bytes are required by protocol decoders. Do not echo arbitrary upstream objects.
        error.data = data.filter(|d| {
            d.as_str().is_some_and(|s| {
                s.starts_with("0x")
                    && s.len() <= 32768
                    && s[2..].bytes().all(|c| c.is_ascii_hexdigit())
            })
        });
        error
    }
}
pub fn redact(value: &str) -> String {
    value
        .split_whitespace()
        .map(|word| {
            if word.contains("://")
                || word.len() > 130
                || ["authorization", "secret", "privatekey", "passphrase"]
                    .iter()
                    .any(|key| word.to_lowercase().contains(key))
            {
                "[已隐藏]".to_string()
            } else {
                word.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(240)
        .collect()
}

/// Reject forbidden fields recursively, before any proxy or structured decoding.
pub fn reject_secret_fields(value: &Value) -> Result<()> {
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                let normalized: String = key
                    .chars()
                    .filter(|c| c.is_alphanumeric())
                    .flat_map(char::to_lowercase)
                    .collect();
                if [
                    "privatekey",
                    "privatekeys",
                    "mnemonic",
                    "seed",
                    "secretkey",
                    "password",
                ]
                .contains(&normalized.as_str())
                {
                    return Err(AppError::invalid("接口不接收私钥或助记词"));
                }
                reject_secret_fields(value)?;
            }
        }
        Value::Array(values) => {
            for value in values {
                reject_secret_fields(value)?;
            }
        }
        _ => {}
    }
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rate_limits_are_distinct_from_contract_limits() {
        let limited = AppError::rpc(-32016, "over rate limit", None);
        assert_eq!(limited.code, "RPC_RATE_LIMIT");
        assert_eq!(limited.status, 429);
        assert!(limited.retryable);
        let quicknode = AppError::rpc(
            -32007,
            "50/second request limit reached - reduce calls per second",
            None,
        );
        assert_eq!(quicknode.code, "RPC_RATE_LIMIT");
        assert!(quicknode.retryable);
        let reverted = AppError::rpc(
            3,
            "execution reverted: rate limit",
            Some(serde_json::json!("0x1234")),
        );
        assert_eq!(reverted.code, "3");
        assert!(!reverted.retryable);
        assert_eq!(reverted.data, Some(serde_json::json!("0x1234")));
    }
    #[test]
    fn nested_keys_rejected_but_signed_transactions_allowed() {
        assert!(
            reject_secret_fields(&serde_json::json!({"params":[{"private_key":"0x00"}]})).is_err()
        );
        assert!(reject_secret_fields(&serde_json::json!({"transactions":["0x1234"]})).is_ok());
    }
}
