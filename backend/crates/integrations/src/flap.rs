use crate::{Integrations, address, bounded_json, bounded_text};
use alloy_primitives::{Address, B256, Bytes, U256};
use alloy_sol_types::{SolCall, sol};
use botai_core::{AppError, Chain, Result};
use botai_rpc::{Call, multicall::Read};
use chrono::Utc;
use futures::{StreamExt, stream};
use regex::Regex;
use serde_json::{Value, json};
use std::collections::BTreeMap;

sol! {function decimals() view returns(uint8);function symbol() view returns(string);function name() view returns(string);}
fn invalid() -> AppError {
    AppError::unavailable("Flap 列表格式已变化，请重试")
}
// Discover only scripts published by the official page. Next.js may move the
// config out of main-app; never guess URLs or execute downloaded JavaScript.
fn catalog_scripts(html: &str) -> Result<Vec<reqwest::Url>> {
    let origin = reqwest::Url::parse("https://flap.sh").unwrap();
    let re = Regex::new(r#"<script\b[^>]*\bsrc=["']([^"'<>]+)["']"#).unwrap();
    let mut urls = Vec::new();
    for m in re.captures_iter(html) {
        let raw = m[1].replace("&amp;", "&");
        let Ok(url) = origin.join(&raw) else { continue };
        if url.origin() == origin.origin()
            && url.username().is_empty()
            && url.password().is_none()
            && url.path().starts_with("/_next/static/chunks/")
            && url.path().ends_with(".js")
            && !urls.contains(&url)
        {
            urls.push(url);
        }
    }
    urls.sort_by_key(|url| !url.path().contains("/main-app-"));
    // Do not silently drop later chunks when Next.js splits a future build.
    // Runtime download/time budgets below bound the work instead.
    if urls.is_empty() {
        return Err(invalid());
    }
    Ok(urls)
}
fn catalog_text(value: &str, maximum: usize) -> Result<String> {
    if value.trim().is_empty()
        || value.encode_utf16().count() > maximum
        || value.chars().any(|c| {
            c.is_control() || matches!(c, '\u{202a}'..='\u{202e}' | '\u{2066}'..='\u{2069}')
        })
    {
        return Err(invalid());
    }
    Ok(value.trim().into())
}
fn validate_showcase(value: &Value, category: &str) -> Result<()> {
    if !["unknown", "all"].contains(&category)
        || value["chain_id"] != 56
        || value["view"] != "category"
        || value["category"] != category
        || value["counts"]["total"].as_u64().is_none_or(|n| n > 2000)
        || value["counts"]["rwa_total"]
            .as_u64()
            .is_none_or(|n| n > value["counts"]["total"].as_u64().unwrap_or(0))
        || value["tokens"]
            .as_array()
            .is_none_or(|rows| rows.len() > 20)
    {
        return Err(invalid());
    }
    Ok(())
}
fn validate_showcase_token(token: &Value, category: &str) -> Result<()> {
    let token_category = token["category"].as_str().unwrap_or("");
    if token["chain_id"] != 56
        || token_category.is_empty()
        || token_category.len() > 64
        || !token_category
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'_' || c == b'-')
        || (token_category == "unknown") != (category == "unknown")
        || address(token["address"].as_str().unwrap_or(""))?.is_zero()
    {
        return Err(invalid());
    }
    for (field, maximum) in [("symbol", 64), ("name", 256)] {
        if let Some(value) = token.get(field).filter(|value| !value.is_null()) {
            catalog_text(value.as_str().ok_or_else(invalid)?, maximum)?;
        }
    }
    Ok(())
}
fn catalog_logo(value: &Value) -> String {
    value
        .as_str()
        .filter(|s| s.len() <= 2048)
        .and_then(|s| reqwest::Url::parse(s).ok())
        .filter(|url| url.scheme() == "https")
        .map(|url| url.to_string())
        .unwrap_or_default()
}
impl Integrations {
    pub async fn flap_signature(&self, quote: &str, salt: &str, version: u8) -> Result<Value> {
        let quote = address(quote)?;
        let _: B256 = salt
            .parse()
            .map_err(|_| AppError::invalid("Flap salt 无效"))?;
        if quote.is_zero() || ![6, 7].contains(&version) {
            return Err(AppError::invalid("Flap 创建参数无效"));
        }
        let response = self
            .http
            .get("https://quotes.taxed.fun/v2/curve-signature")
            .query(&[("chain_id", "56"), ("quote_token", &format!("{quote:#x}"))])
            .header("accept", "application/json")
            .header("origin", "https://flap.sh")
            .header("referer", "https://flap.sh/")
            .send()
            .await
            .map_err(|_| AppError::unavailable("Flap 创建许可请求失败"))?;
        let mut value = bounded_json(response, "Flap 创建许可", 16384).await?;
        if value["allowed"] == false {
            return Ok(json!({"allowed":false}));
        }
        let price = U256::from_str_radix(value["price"].as_str().unwrap_or(""), 10)
            .map_err(|_| invalid())?;
        let signer = address(value["signer"].as_str().unwrap_or(""))?;
        let signature: Bytes = value["signature"]
            .as_str()
            .unwrap_or("")
            .parse()
            .map_err(|_| invalid())?;
        if value["allowed"] != true
            || value["chain_id"] != 56
            || address(value["quote_token"].as_str().unwrap_or(""))? != quote
            || price.is_zero()
            || signer.is_zero()
            || signature.len() != 65
            || value["deadline"].as_i64().unwrap_or(0) <= Utc::now().timestamp() + 10
        {
            return Err(AppError::new(
                "CURVE_SIGNATURE",
                "Flap 曲线授权无效或已过期",
                422,
                false,
            ));
        }
        value["protocol"] = json!("v2");
        Ok(value)
    }
    pub async fn flap_catalog(&self) -> Result<Value> {
        let service = self.clone();
        self.catalogs
            .get("native", async move { service.load_flap_catalog().await })
            .await
    }
    async fn load_flap_catalog(&self) -> Result<Value> {
        let html = bounded_text(
            self.http
                .get("https://flap.sh/launch?chain=bnb&lang=en")
                .send()
                .await
                .map_err(|_| AppError::unavailable("Flap 配置连接失败"))?,
            "Flap 配置",
            5_000_000,
        )
        .await?;
        let mut urls = catalog_scripts(&html)?;
        if let Some(previous) = self.catalogs.source("native").await {
            urls.sort_by_key(|url| previous != url.as_str());
        }
        tokio::time::timeout(std::time::Duration::from_secs(20), async {
            let mut remaining = 30_000_000usize;
            // The official config can move past the first 32 chunks. Read only
            // page-published same-origin scripts, with bounded parallelism.
            let mut scripts = stream::iter(urls).map(|url| async move {
                let response = self.http.get(url.clone()).send().await
                    .map_err(|_| AppError::unavailable("Flap 配置连接失败"))?;
                Ok::<_, AppError>((url, bounded_text(response, "Flap 配置", 8_000_000).await?))
            }).buffered(4);
            let mut last_error = None;
            while let Some(script) = scripts.next().await {
                let (url, text) = match script {
                    Ok(value) => value,
                    Err(error) => { last_error = Some(error); continue; }
                };
                if text.len() > remaining { break; }
                remaining = remaining.saturating_sub(text.len());
                if let Ok(tokens) = parse_catalog(&text) {
                    return Ok(json!({"tokens":tokens,"source":url.as_str(),"loadedAt":Utc::now().to_rfc3339()}));
                }
                if remaining == 0 { break; }
            }
            Err(last_error.unwrap_or_else(invalid))
        }).await.map_err(|_| AppError::unavailable("Flap 配置读取超时，请重试"))?
    }
    async fn showcase(&self, category: &str, offset: usize) -> Result<Value> {
        self.cache
            .try_get_with(
                format!("flap-page:{category}:{offset}"),
                self.load_showcase(category, offset),
            )
            .await
            .map_err(|error| (*error).clone())
    }
    async fn load_showcase(&self, category: &str, offset: usize) -> Result<Value> {
        let response = self
            .http
            .get("https://quote-price.taxed.fun/v1/quotes/showcase")
            .query(&[
                ("chain_id", "56"),
                ("limit", "20"),
                ("offset", &offset.to_string()),
                ("view", "category"),
                ("category", category),
                ("sort", "liquidity"),
            ])
            .header("origin", "https://flap.sh")
            .header("referer", "https://flap.sh/")
            .send()
            .await
            .map_err(|_| AppError::unavailable("Flap 自定义列表连接失败"))?;
        let value = bounded_json(response, "Flap 自定义列表", 262144).await?;
        validate_showcase(&value, category)?;
        Ok(value)
    }
    pub async fn flap_custom_catalog(&self) -> Result<Value> {
        let service = self.clone();
        self.catalogs
            .get(
                "custom",
                async move { service.load_flap_custom_catalog().await },
            )
            .await
    }
    async fn load_flap_custom_catalog(&self) -> Result<Value> {
        let first =
            futures::future::join(self.showcase("unknown", 0), self.showcase("all", 0)).await;
        let mut pages = Vec::new();
        let mut jobs = Vec::new();
        let mut partial = false;
        let mut upstream_error = None;
        for (category, page) in [("unknown", first.0), ("all", first.1)] {
            let page = match page {
                Ok(page) => page,
                Err(error) => {
                    upstream_error.get_or_insert(error);
                    partial = true;
                    continue;
                }
            };
            let total = page["counts"]["total"].as_u64().unwrap_or(0);
            let rwa = page["counts"]["rwa_total"].as_u64().unwrap_or(0);
            for offset in (20..if category == "unknown" {
                (total - rwa) as usize
            } else {
                rwa as usize
            })
                .step_by(20)
            {
                jobs.push((category.to_string(), offset));
            }
            pages.push(page);
        }
        // Do not misreport an official 403 / DNS outage as an API schema change.
        if pages.is_empty() {
            return Err(upstream_error.unwrap_or_else(invalid));
        }
        for page in stream::iter(jobs)
            .map(|(category, offset)| {
                let service = self.clone();
                async move { service.showcase(&category, offset).await }
            })
            .buffered(4)
            .collect::<Vec<_>>()
            .await
        {
            match page {
                Ok(page) => pages.push(page),
                Err(_) => partial = true,
            }
        }
        let mut tokens = BTreeMap::new();
        for page in &pages {
            for token in page["tokens"].as_array().unwrap() {
                if validate_showcase_token(token, page["category"].as_str().unwrap()).is_err() {
                    partial = true;
                    continue;
                }
                let key = token["address"].as_str().unwrap().to_lowercase();
                tokens.entry(key).or_insert_with(|| token.clone());
            }
        }
        if tokens.len() > 2000 || tokens.is_empty() {
            return Err(invalid());
        }
        let mut reads = Vec::new();
        let mut descriptors = Vec::new();
        let mut result = Vec::new();
        for (index, (address_text, token)) in tokens.into_iter().enumerate() {
            let target = address(&address_text)?;
            if let Some(entry) = self.cache.get(&format!("flap-meta:{address_text}")).await {
                result.push(entry);
                continue;
            }
            let entry = json!({"chainId":56,"address":address_text,"symbol":token["symbol"].as_str().unwrap_or("").trim(),"name":token["name"].as_str().unwrap_or("").trim(),"logoUrl":catalog_logo(&token["logo_url"]),"assetVariant":match token["category"].as_str(){Some("bstock")=>Some("bStock"),Some("ondo")=>Some("Ondo"),Some("robinhoodstock")=>Some("Robinhood"),_=>None}});
            for field in ["decimals", "symbol", "name"] {
                if field == "decimals" || entry[field] == "" {
                    let data = match field {
                        "decimals" => decimalsCall {}.abi_encode(),
                        "symbol" => symbolCall {}.abi_encode(),
                        _ => nameCall {}.abi_encode(),
                    };
                    reads.push(Read {
                        target,
                        data: data.into(),
                        required: false,
                    });
                    descriptors.push((index, field));
                }
            }
            result.push(entry);
        }
        let block = if reads.is_empty() {
            json!("latest")
        } else {
            self.rpc
                .read(Chain::Bsc, Call::new("eth_blockNumber", vec![]))
                .await?
        };
        let block = block.as_str().ok_or_else(invalid)?;
        // Split large catalogs while pinning every metadata call to one block.
        while !reads.is_empty() {
            let count = reads.len().min(128);
            let chunk = reads.drain(..count).collect();
            let description: Vec<_> = descriptors.drain(..count).collect();
            let values = match self.rpc.multicall(Chain::Bsc, chunk, block).await {
                Ok(values) => values,
                Err(_) => {
                    partial = true;
                    continue;
                }
            };
            for ((index, field), value) in description.into_iter().zip(values) {
                let decoded = value
                    .as_ref()
                    .and_then(|data| catalog_metadata(field, data));
                if let Some(value) = decoded {
                    result[index][field] = value;
                } else {
                    partial = true;
                }
            }
        }
        // Unknown precision never becomes 18. Only that token is omitted;
        // name/symbol are display fields and can fall back to its address.
        result.retain(|row| row["decimals"].as_u64().is_some());
        for row in &mut result {
            for field in ["symbol", "name"] {
                if row[field] == "" {
                    row[field] = row["address"].clone();
                }
            }
            self.cache
                .insert(
                    format!("flap-meta:{}", row["address"].as_str().unwrap()),
                    row.clone(),
                )
                .await;
        }
        if result.is_empty() {
            return Err(invalid());
        }
        Ok(
            json!({"tokens":result,"partial":partial,"source":"https://quote-price.taxed.fun/v1/quotes/showcase","loadedAt":Utc::now().to_rfc3339()}),
        )
    }
}
fn catalog_metadata(field: &str, data: &[u8]) -> Option<Value> {
    match field {
        "decimals" => decimalsCall::abi_decode_returns(data)
            .ok()
            .filter(|value| *value <= 36)
            .map(|value| json!(value)),
        "symbol" => symbolCall::abi_decode_returns(data)
            .ok()
            .and_then(|value| catalog_text(&value, 64).ok())
            .map(|value| json!(value)),
        _ => nameCall::abi_decode_returns(data)
            .ok()
            .and_then(|value| catalog_text(&value, 256).ok())
            .map(|value| json!(value)),
    }
}

/// Parse bounded literals from official JS. Never evaluate remote source.
fn balanced(source: &str, start: usize, open: u8, close: u8) -> Result<(&str, usize)> {
    let bytes = source.as_bytes();
    let mut depth = 0i32;
    let mut quote = 0u8;
    let mut escaped = false;
    for i in start..bytes.len() {
        let c = bytes[i];
        if quote != 0 {
            if escaped {
                escaped = false
            } else if c == b'\\' {
                escaped = true
            } else if c == quote {
                quote = 0
            }
            continue;
        }
        if b"\"'`".contains(&c) {
            quote = c;
            continue;
        }
        if c == open {
            depth += 1
        }
        if c == close {
            depth -= 1;
            if depth == 0 {
                return Ok((&source[start..=i], i + 1));
            }
        }
    }
    Err(invalid())
}
fn objects(source: &str) -> Result<Vec<&str>> {
    if !source.starts_with('[') || !source.ends_with(']') {
        return Err(invalid());
    }
    if balanced(source, 0, b'[', b']')?.1 != source.len() {
        return Err(invalid());
    }
    let mut cursor = 1;
    let mut result = Vec::new();
    loop {
        cursor += source[cursor..].len() - source[cursor..].trim_start().len();
        if source.as_bytes()[cursor] == b']' {
            break;
        }
        if source.as_bytes()[cursor] != b'{' {
            return Err(invalid());
        }
        let (object, end) = balanced(source, cursor, b'{', b'}')?;
        result.push(object);
        cursor = end;
        cursor += source[cursor..].len() - source[cursor..].trim_start().len();
        match source.as_bytes().get(cursor) {
            Some(b',') => cursor += 1,
            Some(b']') => break,
            _ => return Err(invalid()),
        }
    }
    Ok(result)
}
fn literal_string(value: &str) -> Option<String> {
    if value.starts_with('"') {
        return serde_json::from_str(value).ok();
    }
    // Single-quoted JS literals with JSON-compatible escaping. Expressions,
    // template interpolation and unknown escapes are deliberately not evaluated.
    let raw = value.strip_prefix('\'')?.strip_suffix('\'')?;
    let mut json = String::from("\"");
    let mut chars = raw.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next()? {
                '\'' => json.push('\''),
                next => {
                    json.push('\\');
                    json.push(next);
                }
            },
            '"' => json.push_str("\\\""),
            '\'' => return None,
            _ => json.push(c),
        }
    }
    json.push('"');
    serde_json::from_str(&json).ok()
}
/// Read only direct properties, independent of key order/spacing. Nested
/// display metadata must never supply a missing precision or curve parameter.
fn properties(source: &str) -> Result<BTreeMap<String, &str>> {
    let source = source
        .strip_prefix('{')
        .and_then(|s| s.strip_suffix('}'))
        .ok_or_else(invalid)?;
    let (mut depth, mut quote, mut escaped, mut start) = (0i32, 0u8, false, 0usize);
    let mut fields = BTreeMap::new();
    for (i, c) in source.bytes().chain([b',']).enumerate() {
        if quote != 0 {
            if escaped {
                escaped = false;
            } else if c == b'\\' {
                escaped = true;
            } else if c == quote {
                quote = 0;
            }
            continue;
        }
        match c {
            b'"' | b'\'' | b'`' => quote = c,
            b'{' | b'[' | b'(' => depth += 1,
            b'}' | b']' | b')' => {
                depth -= 1;
                if depth < 0 {
                    return Err(invalid());
                }
            }
            b',' if depth == 0 => {
                let part = source[start..i].trim();
                start = i + 1;
                if let Some((key, value)) = part.split_once(':') {
                    let key = key.trim();
                    let key = literal_string(key).unwrap_or_else(|| key.to_string());
                    if fields.insert(key, value.trim()).is_some() {
                        return Err(invalid());
                    }
                }
            }
            _ => {}
        }
    }
    if quote != 0 || depth != 0 {
        return Err(invalid());
    }
    Ok(fields)
}
fn field(fields: &BTreeMap<String, &str>, name: &str) -> Option<String> {
    literal_string(fields.get(name)?)
}
fn number(fields: &BTreeMap<String, &str>, name: &str) -> Option<u64> {
    fields.get(name)?.parse().ok()
}
fn bnb_config(source: &str) -> Result<BTreeMap<String, &str>> {
    let marker = Regex::new(r#"(?:\b(?:id|slug)|["'](?:id|slug)["'])\s*:\s*["']bnb["']"#).unwrap();
    for found in marker.find_iter(source) {
        for (begin, _) in source[..found.start()].rmatch_indices('{').take(64) {
            if found.start() - begin > 500_000 {
                break;
            }
            let Ok((object, end)) = balanced(source, begin, b'{', b'}') else {
                continue;
            };
            if end <= found.end() {
                continue;
            }
            let Ok(fields) = properties(object) else {
                continue;
            };
            if field(&fields, "id").as_deref() == Some("bnb")
                && field(&fields, "slug").as_deref() == Some("bnb")
                && number(&fields, "chainId") == Some(56)
                && fields.contains_key("paymentTokens")
                && fields.contains_key("launchPaymentTokenCatalog")
            {
                return Ok(fields);
            }
        }
    }
    Err(invalid())
}
fn decimal(value: &str, positive: bool) -> bool {
    let valid = !value.is_empty()
        && value.len() <= 128
        && value.matches('.').count() <= 1
        && value.bytes().all(|c| c.is_ascii_digit() || c == b'.');
    valid && (!positive || value.bytes().any(|c| (b'1'..=b'9').contains(&c)))
}
pub fn parse_catalog(source: &str) -> Result<Vec<Value>> {
    let config = bnb_config(source)?;
    let payments = config["paymentTokens"];
    let catalog = config["launchPaymentTokenCatalog"];
    let mut tokens = BTreeMap::new();
    for object in objects(payments)? {
        let object = properties(object)?;
        let Some(symbol) = field(&object, "symbol") else {
            continue;
        };
        let token_address = field(&object, "address").unwrap_or_default();
        let precision = number(&object, "decimals");
        let r = field(&object, "r").unwrap_or_default();
        let h = field(&object, "h").unwrap_or_else(|| {
            if object.contains_key("h") {
                String::new()
            } else {
                "0".into()
            }
        });
        let k = field(&object, "k").unwrap_or_default();
        let valid = token_address.parse::<Address>().is_ok()
            && precision.is_some_and(|value| value <= 36)
            && decimal(&r, true)
            && decimal(&h, false)
            && decimal(&k, true);
        let mut token = json!({"symbol":symbol,"name":field(&object,"name").unwrap_or(symbol.clone()),"address":token_address,"decimals":precision,"logoUrl":field(&object,"logoUrl").unwrap_or_default(),
            "r":if valid{r}else{String::new()},"h":if valid{h}else{String::new()},"k":if valid{k}else{String::new()},"status":if valid{"available"}else{"unavailable"}});
        if !valid {
            token["unavailableReason"] = json!("配置不完整")
        }
        if tokens.insert(symbol.to_uppercase(), token).is_some() {
            return Err(invalid());
        }
    }
    let mut result = Vec::new();
    for object in objects(catalog)? {
        let object = properties(object)?;
        let Some(symbol) = field(&object, "symbol") else {
            continue;
        };
        let category = field(&object, "category").unwrap_or_default();
        if !["crypto", "rwa"].contains(&category.as_str())
            || field(&object, "status").is_some_and(|s| s != "available")
        {
            continue;
        }
        let mut entry=tokens.get(&symbol.to_uppercase()).cloned().unwrap_or(json!({"symbol":symbol,"name":symbol,"address":"","decimals":18,"r":"","h":"","k":"","logoUrl":"","status":"unavailable","unavailableReason":"配置不完整"}));
        entry["category"] = json!(category);
        for key in ["name", "logoUrl"] {
            if let Some(value) = field(&object, key) {
                entry[key] = json!(value)
            }
        }
        result.push(entry);
    }
    if result.is_empty() {
        return Err(invalid());
    }
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovers_official_chunks_after_next_build_moves_the_catalog() {
        let urls = catalog_scripts(
            r#"<script src="/_next/static/chunks/app/launch/page-new.js"></script>
            <script src='/_next/static/chunks/123-new.js?a=1&amp;b=2'></script>
            <script src="https://flap.sh/_next/static/chunks/main-app-old.js"></script>
            <script src="/_next/static/chunks/app/launch/page-new.js"></script>
            <script src="https://other.test/_next/static/chunks/config.js"></script>
            <script src="/api/secret.js"></script>"#,
        )
        .unwrap();
        assert_eq!(urls.len(), 3);
        assert!(urls[0].path().contains("main-app-old"));
        assert_eq!(
            urls[1].path(),
            "/_next/static/chunks/app/launch/page-new.js"
        );
        assert_eq!(urls[2].query(), Some("a=1&b=2"));
        assert!(catalog_scripts("<script src='https://other.test/config.js'></script>").is_err());
        assert!(catalog_scripts("<h1>403 — Service Unavailable</h1>").is_err());
        let html = (0..90)
            .map(|i| format!("<script src='/_next/static/chunks/{i}.js'></script>"))
            .collect::<String>();
        let scripts = catalog_scripts(&html).unwrap();
        assert_eq!(scripts.len(), 90);
        assert!(scripts.iter().any(|url| url.path().ends_with("/32.js")));
        assert!(scripts.iter().any(|url| url.path().ends_with("/89.js")));
    }
    #[test]
    fn failed_metadata_is_local_and_precision_is_never_guessed() {
        let encode = |n: u8| {
            let mut bytes = vec![0u8; 32];
            bytes[31] = n;
            bytes
        };
        let rows = [
            Some(encode(6)),
            None,
            Some(encode(99)),
            Some(encode(18)),
            Some(encode(0)),
        ];
        let usable: Vec<_> = rows
            .iter()
            .filter_map(|row| {
                row.as_ref()
                    .and_then(|raw| catalog_metadata("decimals", raw))
            })
            .collect();
        assert_eq!(usable, vec![json!(6), json!(18), json!(0)]);
        assert!(catalog_metadata("decimals", &[]).is_none());
        assert!(catalog_metadata("symbol", &[]).is_none());
        let page = json!({"chain_id":56,"view":"category","category":"unknown","counts":{"total":2,"rwa_total":0},"categories":[],
            "tokens":[{"chain_id":56,"address":"0x0000000000000000000000000000000000000001","category":"unknown","symbol":"OK"},
            {"chain_id":56,"address":"broken","category":"unknown"}]});
        validate_showcase(&page, "unknown").unwrap();
        assert_eq!(
            page["tokens"]
                .as_array()
                .unwrap()
                .iter()
                .filter(|row| validate_showcase_token(row, "unknown").is_ok())
                .count(),
            1
        );
    }
    #[test]
    fn custom_catalog_rejects_wrong_chain_category_and_spoofed_or_empty_labels() {
        let valid = json!({"chain_id":56,"view":"category","category":"unknown","counts":{"total":1,"rwa_total":0},"categories":[],
            "tokens":[{"chain_id":56,"address":"0x0000000000000000000000000000000000000001","category":"unknown","symbol":"牛来","name":"Token"}]});
        validate_showcase(&valid, "unknown").unwrap();
        for (path, replacement) in [
            ("/chain_id", json!(1)),
            ("/category", json!("new")),
            ("/counts/total", json!(2001)),
            ("/counts/rwa_total", json!(2)),
            ("/tokens/0/address", json!(format!("{:#x}", Address::ZERO))),
            ("/tokens/0/category", json!("ondo")),
            ("/tokens/0/symbol", json!("bad\u{202e}")),
            ("/tokens/0/name", json!("\u{2066}bad")),
            ("/tokens/0/name", json!("  ")),
        ] {
            let mut value = valid.clone();
            *value.pointer_mut(path).unwrap() = replacement;
            assert!(
                if path.starts_with("/tokens/") {
                    validate_showcase_token(&value["tokens"][0], "unknown").is_err()
                } else {
                    validate_showcase(&value, "unknown").is_err()
                },
                "{path}"
            );
        }
        let mut missing = valid.clone();
        missing["tokens"][0]["name"] = Value::Null;
        missing["tokens"][0]
            .as_object_mut()
            .unwrap()
            .remove("symbol");
        validate_showcase(&missing, "unknown").unwrap();
        assert_eq!(catalog_text(" 牛来🚀 ", 64).unwrap(), "牛来🚀");
        assert!(catalog_text(&"🚀".repeat(33), 64).is_err());
        assert!(catalog_text("bad\u{202e}", 64).is_err());
        // Classification is display metadata; a new official issuer/category
        // must not discard an otherwise valid token. Precision is read on-chain.
        let mut future = valid.clone();
        future["category"] = json!("all");
        future["tokens"][0]["category"] = json!("new_issuer");
        future["categories"] = Value::Null;
        future["new_metadata"] = json!({"anything":true});
        validate_showcase(&future, "all").unwrap();
        validate_showcase_token(&future["tokens"][0], "all").unwrap();
        future["tokens"][0]["chain_id"] = json!(1);
        assert!(validate_showcase_token(&future["tokens"][0], "all").is_err());
    }
    #[test]
    fn optional_catalog_logo_is_a_parsed_https_url() {
        assert_eq!(
            catalog_logo(&json!("https://example.com/icon.png")),
            "https://example.com/icon.png"
        );
        for value in [
            json!("javascript:bad()"),
            json!("http://example.com/a"),
            json!("https://"),
            json!(123),
            Value::Null,
        ] {
            assert_eq!(catalog_logo(&value), "");
        }
    }
    #[test]
    fn literal_catalog_keeps_precision_and_disables_bad_entries() {
        let text = r#"const bnb={id:"bnb",slug:"bnb",chainId:56,paymentTokens:[{symbol:"Q",address:"0x0000000000000000000000000000000000000001",decimals:6,r:"2",h:"0",k:"3"},{symbol:"BAD",decimals:99}],launchPaymentTokenCatalog:[{symbol:"Q",category:"rwa"},{symbol:"BAD",category:"crypto"}]}"#;
        let rows = parse_catalog(text).unwrap();
        assert_eq!(rows[0]["decimals"], 6);
        assert_eq!(rows[0]["status"], "available");
        assert_eq!(rows[1]["status"], "unavailable");
    }
    #[test]
    fn literal_catalog_tolerates_order_quotes_whitespace_and_additive_metadata() {
        let text = r#"const configs=[{id:'eth',slug:'eth',chainId:1,paymentTokens:[],launchPaymentTokenCatalog:[]},
        {"slug" : 'bnb', newFlag: !0, launchPaymentTokenCatalog : [{category : 'rwa',symbol : 'Q',future:{a:1}}],
        paymentTokens : [{newData:{symbol:'WRONG',decimals:18}, 'k': '3', r:'2', 'decimals' : 6,
        symbol:'Q',address:'0x0000000000000000000000000000000000000001',name:'A \\' B'}],
        "chainId" : 56, 'id' : 'bnb'}]"#;
        // Use an escaped apostrophe in the actual JS literal.
        let text = text.replace(r"\\'", r"\'");
        let rows = parse_catalog(&text).unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0]["symbol"], "Q");
        assert_eq!(rows[0]["name"], "A ' B");
        assert_eq!(rows[0]["decimals"], 6);
        assert_eq!(rows[0]["h"], "0");
        assert_eq!(rows[0]["status"], "available");
        for text in [
            text.replace("56", "1"),
            text.replace("paymentTokens :", "renamed :"),
        ] {
            assert!(parse_catalog(&text).is_err());
        }
        let missing = text.replace("'decimals' : 6,", "");
        let row = &parse_catalog(&missing).unwrap()[0];
        assert!(row["decimals"].is_null());
        assert_eq!(row["status"], "unavailable");
        assert_eq!(
            parse_catalog(&text.replace("r:'2'", "r:futureCurve()")).unwrap()[0]["status"],
            "unavailable"
        );
        assert!(
            parse_catalog(&text.replace("paymentTokens : [", "paymentTokens : [...other,"))
                .is_err()
        );
    }
    #[test]
    fn catalog_cannot_take_arrays_from_a_different_chain_or_nested_display_fields() {
        let text = r#"[{id:"bnb",slug:"bnb",chainId:56,paymentTokens:[]},
        {id:"eth",slug:"eth",chainId:1,launchPaymentTokenCatalog:[{symbol:"Q",category:"crypto"}]}]"#;
        assert!(parse_catalog(text).is_err());
        assert!(properties(r#"{decimals:6,decimals:18}"#).is_err());
        assert!(objects("[call({symbol:'Q'})]").is_err());
    }
}
