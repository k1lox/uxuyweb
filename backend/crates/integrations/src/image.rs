use crate::{Integrations, address, bounded_json};
use alloy_primitives::{Signature, hex};
use botai_core::{AppError, Result};
use chrono::Utc;
use reqwest::multipart::{Form, Part};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

pub struct Image {
    pub bytes: Vec<u8>,
    pub mime: String,
    pub filename: String,
}
pub fn validate_image(image: &Image, limit: usize, check_magic: bool) -> Result<()> {
    if image.bytes.is_empty() || image.bytes.len() > limit {
        return Err(AppError::invalid("图片大小超出限制"));
    }
    let b = &image.bytes;
    let magic = match image.mime.as_str() {
        "image/png" => b.starts_with(&[137, 80, 78, 71, 13, 10, 26, 10]),
        "image/jpeg" => b.starts_with(&[255, 216, 255]),
        "image/webp" => b.starts_with(b"RIFF") && b.get(8..12) == Some(b"WEBP"),
        "image/gif" => b.starts_with(b"GIF87a") || b.starts_with(b"GIF89a"),
        _ => false,
    };
    if !image.mime.starts_with("image/") || check_magic && !magic {
        return Err(AppError::invalid("图片内容与格式不一致"));
    }
    Ok(())
}
pub(crate) fn part(image: Image) -> Result<Part> {
    Part::bytes(image.bytes)
        .file_name(image.filename)
        .mime_str(&image.mime)
        .map_err(|_| AppError::invalid("图片格式无效"))
}
fn valid_cid(value: &str) -> bool {
    value.starts_with('b')
        && value.len() >= 21
        && value
            .bytes()
            .all(|c| c.is_ascii_lowercase() || (b'2'..=b'7').contains(&c))
}
pub fn genius_message(hash: &str, mime: &str, timestamp: &str) -> String {
    format!(
        "Genius Launchpad image upload\nOrigin: https://genius.fun\nChain ID: 56\nImage SHA-256: {}\nContent-Type: {mime}\nIssued at: {timestamp}\nAuthorize one image upload. This does not authorize a transaction.",
        hash.trim_start_matches("0x").to_lowercase()
    )
}
impl Integrations {
    pub async fn genius_upload(
        &self,
        image: Image,
        sender: &str,
        signature: &str,
        timestamp: &str,
    ) -> Result<(Value, u16)> {
        validate_image(&image, 2 * 1024 * 1024, true)?;
        let time = timestamp
            .parse::<i64>()
            .map_err(|_| AppError::invalid("图片签名时间无效"))?;
        if timestamp.len() != 10 || time.abs_diff(Utc::now().timestamp()) > 300 {
            return Err(AppError::invalid("图片签名已过期"));
        }
        let hash = hex::encode(Sha256::digest(&image.bytes));
        let message = genius_message(&hash, &image.mime, timestamp);
        let sig: Signature = signature
            .parse()
            .map_err(|_| AppError::invalid("图片签名无效"))?;
        if sig
            .recover_address_from_msg(&message)
            .map_err(|_| AppError::invalid("图片签名无效"))?
            != address(sender)?
        {
            return Err(AppError::invalid("图片签名地址不符"));
        }
        let response = self
            .http
            .post("https://genius.fun/api/image/upload")
            .header("origin", "https://genius.fun")
            .header("referer", "https://genius.fun/create")
            .header("content-type", &image.mime)
            .header("x-upload-address", sender)
            .header("x-upload-signature", signature)
            .header("x-upload-timestamp", timestamp)
            .body(image.bytes)
            .send()
            .await
            .map_err(|_| AppError::unavailable("Genius 图片上传失败"))?;
        let status = response.status().as_u16();
        let value = bounded_json(response, "Genius 图片", 20000).await?;
        Ok((genius_fields(value), status))
    }
    pub async fn genius_status(&self, id: Option<&str>, capability: &str) -> Result<Value> {
        let mut url = "https://genius.fun/api/image/upload".to_string();
        if let Some(id) = id {
            if id.is_empty()
                || id.len() > 128
                || !id
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
                || !(16..=256).contains(&capability.len())
                || !capability
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || b"._~-".contains(&c))
            {
                return Err(AppError::invalid("图片查询凭据无效"));
            }
            url.push('/');
            url.push_str(id);
        }
        let mut request = self
            .http
            .get(url)
            .header("origin", "https://genius.fun")
            .header("referer", "https://genius.fun/create");
        if id.is_some() {
            request = request.header("x-upload-capability", capability)
        }
        Ok(genius_fields(
            bounded_json(
                request
                    .send()
                    .await
                    .map_err(|_| AppError::unavailable("Genius 图片查询失败"))?,
                "Genius 图片",
                20000,
            )
            .await?,
        ))
    }
    pub async fn pons_image(&self, image: Image) -> Result<Value> {
        validate_image(&image, 5 * 1024 * 1024, true)?;
        let response = self
            .http
            .post("https://www.ponsfamily.com/api/ipfs/image")
            .header("origin", "https://www.ponsfamily.com")
            .header("referer", "https://www.ponsfamily.com/launchpad/create")
            .multipart(Form::new().part("image", part(image)?))
            .send()
            .await
            .map_err(|_| AppError::unavailable("Pons 图片上传失败"))?;
        let value = bounded_json(response, "Pons 图片", 20000).await?;
        let cid = value["cid"].as_str().unwrap_or("");
        if !valid_cid(cid) || value["uri"] != json!(format!("ipfs://{cid}")) {
            return Err(AppError::unavailable("Pons 图片未返回有效 IPFS 地址"));
        }
        Ok(json!({"cid":cid,"uri":value["uri"]}))
    }
    pub async fn flap_image(
        &self,
        image: Image,
        fields: BTreeMap<String, String>,
    ) -> Result<Value> {
        validate_image(&image, 10_000_000, false)?;
        let creator = fields
            .get("creator")
            .ok_or_else(|| AppError::invalid("缺少创建地址"))?;
        address(creator)?;
        let description = fields.get("description").cloned().unwrap_or_default();
        if description.chars().count() > 5000 {
            return Err(AppError::invalid("简介过长"));
        }
        let mut meta = json!({"creator":creator,"description":description});
        for key in [
            "website", "telegram", "twitter", "github", "youtube", "debox",
        ] {
            let value = fields.get(key).map(|s| s.trim()).unwrap_or("");
            if !value.is_empty() {
                let url = reqwest::Url::parse(value)
                    .map_err(|_| AppError::invalid("社交链接格式无效"))?;
                if value.len() > 500 || !["http", "https"].contains(&url.scheme()) {
                    return Err(AppError::invalid("社交链接格式无效"));
                }
            }
            meta[key] = json!(value);
        }
        let form=Form::new().text("operations",json!({"query":"\nmutation Create($file: Upload!, $meta: MetadataInput!) {\n  create(file: $file, meta: $meta)\n}\n","variables":{"file":null,"meta":meta}}).to_string())
            .text("map",json!({"0":["variables.file"]}).to_string()).part("0",part(image)?);
        let response = self
            .http
            .post("https://flap.sh/api/upload?warmup=true")
            .header("origin", "https://flap.sh")
            .header("referer", "https://flap.sh/launch?chain=bnb&lang=zh")
            .multipart(form)
            .send()
            .await
            .map_err(|_| AppError::unavailable("Flap 图片上传失败"))?;
        let value = bounded_json(response, "Flap 图片", 100000).await?;
        let cid = value["data"]["create"].as_str().unwrap_or("");
        if !valid_cid(cid) {
            return Err(AppError::unavailable("Flap 图片未返回有效 CID"));
        }
        Ok(json!({"cid":cid}))
    }
    pub async fn four_image(&self, image: Image, token: &str) -> Result<Value> {
        self.four_preflight()?;
        validate_image(&image, 10_000_000, false)?;
        if token.is_empty() || token.len() > 8192 {
            return Err(AppError::invalid("Four 图片上传凭据无效"));
        }
        let mut token = reqwest::header::HeaderValue::from_str(token)
            .map_err(|_| AppError::invalid("Four 图片上传凭据无效"))?;
        token.set_sensitive(true);
        let request = self
            .four_gate
            .post("/private/token/upload")
            .header("meme-web-access", token)
            .multipart(Form::new().part("file", part(image)?));
        self.four_gate.request(request, false, 100000).await
    }
}
fn genius_fields(value: Value) -> Value {
    json!(
        ["available", "uploadId", "capability", "status", "uri"]
            .into_iter()
            .filter_map(|key| value.get(key).map(|v| (key.to_string(), v.clone())))
            .collect::<serde_json::Map<_, _>>()
    )
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn upload_purpose_and_file_type_are_bound() {
        assert!(
            genius_message("0xAABB", "image/png", "1789649860")
                .contains("Image SHA-256: aabb\nContent-Type: image/png\nIssued at: 1789649860")
        );
        assert!(
            validate_image(
                &Image {
                    bytes: b"not png".to_vec(),
                    mime: "image/png".into(),
                    filename: "x.png".into()
                },
                100,
                true
            )
            .is_err()
        );
        assert_eq!(
            genius_fields(json!({"status":"pending","internalSecret":"secret"})),
            json!({"status":"pending"})
        );
    }
}
