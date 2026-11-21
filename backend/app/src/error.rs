use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde_json::json;

/// API error. Messages are user facing (Chinese) and never contain credentials or raw transactions.
#[derive(Debug, Clone, PartialEq)]
pub struct ApiError {
    pub code: &'static str,
    pub message: String,
    pub status: u16,
    pub retryable: bool,
}

pub type Result<T> = std::result::Result<T, ApiError>;

impl ApiError {
    pub fn new(code: &'static str, message: impl Into<String>, status: u16, retryable: bool) -> Self {
        Self { code, message: message.into(), status, retryable }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new("INVALID_REQUEST", message, 400, false)
    }

    pub fn unavailable(message: impl Into<String>) -> Self {
        Self::new("UPSTREAM_UNAVAILABLE", message, 502, true)
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let status = StatusCode::from_u16(self.status).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR);
        (
            status,
            Json(json!({"ok": false, "code": self.code, "message": self.message, "retryable": self.retryable})),
        )
            .into_response()
    }
}
