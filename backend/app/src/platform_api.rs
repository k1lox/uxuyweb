//! BSC wallet reads, launchpad integrations, transaction status and private bundle submission.
use crate::{App, submit};
use axum::{
    Json,
    body::{Bytes, to_bytes},
    extract::{FromRequest, Multipart, Path, Query, Request, State},
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
};
use botai_core::{AppError, Chain};
use botai_integrations::image::Image;
use botai_rpc::Call;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;

pub struct Error(pub AppError);

impl From<AppError> for Error {
    fn from(value: AppError) -> Self {
        Self(value)
    }
}

impl IntoResponse for Error {
    fn into_response(self) -> Response {
        let e = self.0;
        (
            StatusCode::from_u16(e.status).unwrap_or(StatusCode::BAD_GATEWAY),
            Json(json!({"ok":false,"message":e.message,"code":e.code,"data":e.data,"retryable":e.retryable,"notSubmitted":e.not_submitted})),
        )
            .into_response()
    }
}

pub type Result<T> = std::result::Result<T, Error>;

/// This deployment serves BSC only.
fn bsc(chain: &str) -> std::result::Result<Chain, AppError> {
    let chain = Chain::parse(chain)?;
    if chain != Chain::Bsc {
        return Err(AppError::invalid("当前只支持 BSC"));
    }
    Ok(chain)
}

// ------------------------------------------------------------------ read-only RPC

pub async fn read_rpc(
    State(app): State<App>,
    Path(chain): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>> {
    botai_core::error::reject_secret_fields(&body)?;
    let chain = bsc(&chain)?;
    let rpc = &app.chain_rpc;
    if let Some(rows) = body.as_array() {
        if rows.is_empty() || rows.len() > 256 {
            return Err(AppError::invalid("请求数量无效").into());
        }
        let results =
            futures::future::join_all(rows.iter().map(|row| rpc_reply(rpc, chain, row))).await;
        return Ok(Json(json!(results)));
    }
    if body.get("jsonrpc").is_some() {
        return Ok(Json(rpc_reply(rpc, chain, &body).await));
    }
    if let Some(calls) = body.get("calls") {
        let calls: Vec<Call> =
            serde_json::from_value(calls.clone()).map_err(|_| AppError::invalid("读取格式无效"))?;
        return Ok(Json(
            json!({"ok":true,"result":rpc.read_many(chain, calls).await?}),
        ));
    }
    let call: Call = serde_json::from_value(body).map_err(|_| AppError::invalid("读取格式无效"))?;
    Ok(Json(
        json!({"ok":true,"result":rpc.read(chain, call).await?}),
    ))
}

async fn rpc_reply(rpc: &botai_rpc::Rpc, chain: Chain, row: &Value) -> Value {
    let id = row.get("id").cloned().unwrap_or(Value::Null);
    let call: std::result::Result<Call, _> = serde_json::from_value(
        json!({"method":row["method"],"params":row.get("params").cloned().unwrap_or(json!([]))}),
    );
    let result = match call {
        Ok(call) => rpc.read(chain, call).await,
        Err(_) => Err(AppError::invalid("读取格式无效")),
    };
    match result {
        Ok(value) => json!({"jsonrpc":"2.0","id":id,"result":value}),
        Err(error) => {
            json!({"jsonrpc":"2.0","id":id,"error":{"code":error.code.parse::<i64>().unwrap_or(-32000),"message":error.message,"data":error.data}})
        }
    }
}

// ------------------------------------------------------------------ platforms, quotes, conversion

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MarketRequest {
    token: alloy_primitives::Address,
    block_number: Option<u64>,
}

pub async fn platform_market(
    State(app): State<App>,
    Path(chain): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>> {
    botai_core::error::reject_secret_fields(&body)?;
    let chain = bsc(&chain)?;
    let input: MarketRequest =
        serde_json::from_value(body).map_err(|_| AppError::invalid("市场请求格式无效"))?;
    Ok(Json(
        json!({"ok":true,"result":app.platforms.inspect(chain, input.token, input.block_number).await?}),
    ))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Submission {
    transactions: Vec<String>,
    #[serde(default)]
    options: botai_transactions::SubmitOptions,
}

pub async fn submit_transactions(
    State(app): State<App>,
    Path(chain): Path<String>,
    Json(body): Json<Submission>,
) -> Result<Json<Value>> {
    let chain = bsc(&chain).map_err(AppError::before_send)?;
    let (_, has_creation) = submit::checked_bundle(
        &body.transactions,
        &app.issued,
        app.router,
        app.planner.spender,
        &app.denied,
    )
    .map_err(AppError::before_send)?;
    if has_creation {
        return Err(AppError::invalid("该交易必须使用私有捆绑提交")
            .before_send()
            .into());
    }
    Ok(Json(
        json!({"ok":true,"result":app.transactions.submit_with_options(chain, body.transactions, body.options).await?}),
    ))
}

pub async fn transaction_status(
    State(app): State<App>,
    Path((chain, hash)): Path<(String, String)>,
    Query(query): Query<BTreeMap<String, String>>,
) -> Result<Json<Value>> {
    if hash.len() != 66
        || !hash.starts_with("0x")
        || !hash[2..].bytes().all(|c| c.is_ascii_hexdigit())
    {
        return Err(AppError::invalid("交易哈希无效").into());
    }
    let chain = bsc(&chain)?;
    let hash = hash.to_lowercase();
    let record = if query.get("tracked").is_some_and(|v| v == "true") {
        app.transactions.tracked(chain, &hash).await?
    } else {
        app.transactions.refresh(chain, &hash).await?
    };
    Ok(Json(json!({"ok":true,"result":record})))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Bundle {
    transactions: Vec<String>,
    max_block_number: u64,
}

pub async fn bundle(State(app): State<App>, Json(body): Json<Bundle>) -> Result<Json<Value>> {
    let check = submit::checked_private(&app, &body.transactions);
    let result = app
        .transactions
        .submit_bundle_after_check(body.max_block_number, check)
        .await?;
    Ok(Json(json!({"ok":true,"result":result})))
}

// ------------------------------------------------------------------ official integrations

pub async fn flap_get(
    State(app): State<App>,
    Query(query): Query<BTreeMap<String, String>>,
) -> Result<Json<Value>> {
    let version = || -> std::result::Result<u8, AppError> {
        query
            .get("tokenVersion")
            .map(|s| s.parse::<u8>())
            .transpose()
            .map_err(|_| AppError::invalid("代币版本无效"))
            .map(|v| v.unwrap_or(6))
    };
    let data = match query.get("action").map(String::as_str) {
        None => app.integrations.flap_catalog().await?,
        Some("customCatalog") => app.integrations.flap_custom_catalog().await?,
        Some("curveSignature") => {
            app.integrations
                .flap_signature(
                    query.get("quoteToken").map(String::as_str).unwrap_or(""),
                    query.get("salt").map(String::as_str).unwrap_or(""),
                    version()?,
                )
                .await?
        }
        Some("creationCurve") => {
            let quote = botai_integrations::address(
                query.get("quoteToken").map(String::as_str).unwrap_or(""),
            )?;
            app.integrations
                .flap_creation_curve(quote, version()?, None)
                .await?
        }
        _ => return Err(AppError::invalid("Flap 操作无效").into()),
    };
    Ok(Json(json!({"ok":true,"payload":data})))
}

async fn read_form(
    mut form: Multipart,
    field_name: &str,
    max: usize,
) -> Result<(Image, BTreeMap<String, String>)> {
    let mut image = None;
    let mut fields = BTreeMap::new();
    let mut total = 0;
    while let Some(field) = form
        .next_field()
        .await
        .map_err(|_| AppError::invalid("上传格式无效"))?
    {
        let name = field.name().unwrap_or("").to_string();
        let filename = field.file_name().unwrap_or("token-image").to_string();
        let mime = field.content_type().unwrap_or("").to_lowercase();
        let bytes = field
            .bytes()
            .await
            .map_err(|_| AppError::invalid("上传数据不完整"))?;
        total += bytes.len();
        if total > max + 100_000 {
            return Err(AppError::new("UPLOAD_TOO_LARGE", "图片或资料过大", 413, false).into());
        }
        if name == field_name {
            if image.is_some() {
                return Err(AppError::invalid("只能上传一张图片").into());
            }
            image = Some(Image {
                bytes: bytes.to_vec(),
                mime,
                filename,
            });
        } else {
            if bytes.len() > 10_000 {
                return Err(AppError::invalid("资料字段过长").into());
            }
            let value =
                String::from_utf8(bytes.to_vec()).map_err(|_| AppError::invalid("资料编码无效"))?;
            if fields.insert(name, value).is_some() {
                return Err(AppError::invalid("重复资料字段").into());
            }
        }
    }
    botai_core::error::reject_secret_fields(&json!(fields))?;
    Ok((
        image.ok_or_else(|| AppError::invalid("请选择图片"))?,
        fields,
    ))
}

pub async fn flap_upload(State(app): State<App>, form: Multipart) -> Result<Json<Value>> {
    let (image, fields) = read_form(form, "file", 10_000_000).await?;
    Ok(Json(
        json!({"ok":true,"payload":app.integrations.flap_image(image, fields).await?}),
    ))
}

/// Observes the Four HTTP circuit without contacting the official API or the chain.
pub async fn four_status(State(app): State<App>) -> impl IntoResponse {
    (
        [(axum::http::header::CACHE_CONTROL, "no-store")],
        Json(json!({"ok":true,"officialApi":app.integrations.four_status()})),
    )
}

pub async fn four(State(app): State<App>, request: Request) -> Result<Json<Value>> {
    let multipart = request
        .headers()
        .get("content-type")
        .and_then(|h| h.to_str().ok())
        .is_some_and(|s| s.starts_with("multipart/form-data"));
    let result = if multipart {
        // Limit buffered Four uploads and reject cooldown before reading up to 10 MB.
        let _upload_slot = app.integrations.four_upload_slot()?;
        let form = Multipart::from_request(request, &app)
            .await
            .map_err(|_| AppError::invalid("上传格式无效"))?;
        let (image, fields) = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            read_form(form, "file", 10_000_000),
        )
        .await
        .map_err(|_| {
            AppError::new(
                "FOUR_UPLOAD_TIMEOUT",
                "图片上传超时，请重新上传",
                408,
                false,
            )
        })??;
        app.integrations
            .four_image(
                image,
                fields.get("accessToken").map(String::as_str).unwrap_or(""),
            )
            .await?
    } else {
        // This body limit is independent of HTTP cooldown: on-chain address prediction
        // must still work when Four's website is unavailable.
        let _json_slot = app.integrations.four_json_slot()?;
        let bytes = tokio::time::timeout(
            std::time::Duration::from_secs(30),
            to_bytes(request.into_body(), 2_000_000),
        )
        .await
        .map_err(|_| {
            AppError::new(
                "FOUR_REQUEST_TIMEOUT",
                "Four 请求读取超时，请重新操作",
                408,
                false,
            )
        })?
        .map_err(|_| AppError::new("FOUR_REQUEST_BODY", "Four 请求过大或数据不完整", 413, false))?;
        let body = serde_json::from_slice::<Value>(&bytes)
            .map_err(|_| AppError::invalid("请求格式无效"))?;
        app.integrations.four(body).await?
    };
    Ok(Json(json!({"ok":true,"payload":result})))
}

fn header<'a>(headers: &'a HeaderMap, key: &str) -> &'a str {
    headers.get(key).and_then(|h| h.to_str().ok()).unwrap_or("")
}

pub async fn genius_upload(
    State(app): State<App>,
    headers: HeaderMap,
    bytes: Bytes,
) -> Result<(StatusCode, Json<Value>)> {
    let image = Image {
        bytes: bytes.to_vec(),
        mime: header(&headers, "content-type").to_lowercase(),
        filename: "token-image".into(),
    };
    let (value, status) = app
        .integrations
        .genius_upload(
            image,
            header(&headers, "x-upload-address"),
            header(&headers, "x-upload-signature"),
            header(&headers, "x-upload-timestamp"),
        )
        .await?;
    Ok((
        StatusCode::from_u16(status).unwrap_or(StatusCode::OK),
        Json(value),
    ))
}

pub async fn genius_get(
    State(app): State<App>,
    Query(query): Query<BTreeMap<String, String>>,
    headers: HeaderMap,
) -> Result<Json<Value>> {
    Ok(Json(
        app.integrations
            .genius_status(
                query.get("uploadId").map(String::as_str),
                header(&headers, "x-upload-capability"),
            )
            .await?,
    ))
}
