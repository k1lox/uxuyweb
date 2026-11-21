use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::LazyLock;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Trade {
    pub wallet_name: String,
    pub wallet_address: String,
    pub side: String,
    pub amount: String,
    pub currency: String,
    pub token_name: String,
    pub token_address: String,
}
#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    pub update_id: u64,
    pub message_id: u64,
    pub sent_at: u64,
    pub received_at: u64,
    pub edited: bool,
    pub trade: Trade,
}
static HEADER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"(?i)[-–—]\s*BSC\s*$").unwrap());
static AMOUNT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?:🟢|🔴)\s*(买入|购买|买|卖出|卖)\s*\*{0,2}((?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:[KMBkmb千百万亿])?)\s+([^\s*\[\]<>]{1,25})").unwrap()
});
static MARKDOWN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[([^\]\n]+)\]\((https?://[^\s()]+)\)").unwrap());
static ADDRESS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^/bsc/(address|token)/(?:[A-Za-z0-9_-]+_)?(0x[0-9a-fA-F]{40})/?$").unwrap()
});
static EMOJI: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"[\p{Extended_Pictographic}\p{Emoji_Modifier}\x{FE0E}\x{FE0F}\x{200D}\x{20E3}]")
        .unwrap()
});
fn name(raw: &str) -> String {
    let s = raw
        .trim_matches(|c: char| c.is_whitespace() || "[]*".contains(c))
        .chars()
        .take(80)
        .collect::<String>();
    let clean = EMOJI.replace_all(&s, "").trim().to_string();
    if clean.is_empty() { s } else { clean }
}
fn safe_link(raw: &str) -> Option<String> {
    if raw.len() > 2048 {
        return None;
    }
    let u = reqwest::Url::parse(raw).ok()?;
    (["https", "http"].contains(&u.scheme()) && u.username().is_empty() && u.password().is_none())
        .then(|| u.to_string())
}
fn gmgn(raw: &str, kind: &str) -> Option<String> {
    let u = reqwest::Url::parse(raw).ok()?;
    if u.scheme() != "https"
        || ![Some("gmgn.ai"), Some("www.gmgn.ai")].contains(&u.host_str())
        || !u.username().is_empty()
        || u.password().is_some()
    {
        return None;
    }
    let m = ADDRESS.captures(u.path())?;
    (m.get(1)?.as_str() == kind).then(|| m[2].to_string())
}
pub fn parse_trade(text: &str, mut links: Vec<(String, String)>) -> Option<Trade> {
    if !HEADER.is_match(text.lines().next().unwrap_or("")) {
        return None;
    }
    for m in MARKDOWN.captures_iter(text) {
        links.push((m[1].to_string(), m[2].to_string()))
    }
    let line = text
        .lines()
        .find(|s| s.contains('🟢') || s.contains('🔴'))?;
    let amount = AMOUNT.captures(line)?;
    if amount[2].len() > 40 {
        return None;
    }
    let wallet = links.iter().find(|(label, url)| {
        gmgn(url, "address").is_some()
            && !["钱包盈亏", "钱包详情", "查看钱包"].contains(&label.as_str())
    })?;
    let token = links.iter().find(|(label, url)| {
        gmgn(url, "token").is_some()
            && !["价格图表", "立即买入", "查看图表", "图表", "chart"]
                .contains(&label.to_lowercase().as_str())
    })?;
    let wallet_name = name(&wallet.0);
    let token_name = name(&token.0);
    if wallet_name.is_empty()
        || token_name.is_empty()
        || ["http://", "https://"].iter().any(|s| {
            format!("{wallet_name}{token_name}")
                .to_lowercase()
                .contains(s)
        })
    {
        return None;
    }
    Some(Trade {
        wallet_name,
        wallet_address: gmgn(&wallet.1, "address")?,
        side: if amount[1].starts_with('买') || &amount[1] == "购买" {
            "buy"
        } else {
            "sell"
        }
        .into(),
        amount: amount[2].replace(',', ""),
        currency: amount[3].to_uppercase(),
        token_name,
        token_address: gmgn(&token.1, "token")?,
    })
}
pub fn normalize(update: &Value, chat: &str, sender: &str, now: u64) -> Option<Message> {
    let edited = update.get("edited_message").is_some();
    let m = update
        .get("edited_message")
        .or_else(|| update.get("message"))?;
    if m["chat"]["id"].as_i64()?.to_string() != chat
        || m["from"]["id"].as_u64()?.to_string() != sender
        || m["from"]["is_bot"] != true
    {
        return None;
    }
    let text = m["text"].as_str().or_else(|| m["caption"].as_str())?;
    if text.trim().is_empty() {
        return None;
    }
    let mut links = Vec::new();
    let mut add = |label: String, url: &str| {
        if let Some(url) = safe_link(url) {
            if links.len() < 16 && !links.iter().any(|(_, u)| u == &url) {
                links.push((label.chars().take(100).collect(), url));
            }
        }
    };
    if let Some(entities) = m
        .get("entities")
        .or_else(|| m.get("caption_entities"))
        .and_then(Value::as_array)
    {
        let utf16: Vec<u16> = text.encode_utf16().collect();
        for e in entities {
            if let (Some(offset), Some(len)) = (e["offset"].as_u64(), e["length"].as_u64()) {
                if let Some(end) = offset.checked_add(len).filter(|n| *n <= utf16.len() as u64) {
                    let label = String::from_utf16_lossy(&utf16[offset as usize..end as usize]);
                    if e["type"] == "text_link" {
                        add(label, e["url"].as_str().unwrap_or(""));
                    } else if e["type"] == "url" {
                        add(label.clone(), &label);
                    }
                }
            }
        }
    }
    if let Some(rows) = m["reply_markup"]["inline_keyboard"].as_array() {
        for row in rows {
            if let Some(buttons) = row.as_array() {
                for b in buttons {
                    add(
                        b["text"].as_str().unwrap_or("查看").into(),
                        b["url"].as_str().unwrap_or(""),
                    );
                }
            }
        }
    }
    let text = text.chars().take(8192).collect::<String>();
    let trade = parse_trade(&text, links)?;
    let message_id = m["message_id"].as_u64()?;
    Some(Message {
        id: format!("{chat}:{message_id}"),
        update_id: update["update_id"].as_u64()?,
        message_id,
        sent_at: m["date"].as_u64()?.checked_mul(1000)?,
        received_at: now,
        edited,
        trade,
    })
}
