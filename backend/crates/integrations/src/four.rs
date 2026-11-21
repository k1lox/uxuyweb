use crate::{Integrations, address};
use alloy_primitives::{Bytes, U256};
use botai_core::{AppError, Chain, Result};
use botai_rpc::Call;
use serde_json::{Value, json};
impl Integrations {
    pub async fn four(&self, body: Value) -> Result<Value> {
        botai_core::error::reject_secret_fields(&body)?;
        let request = match body["action"].as_str().unwrap_or("") {
            "config" => self.four_gate.get("/public/config"),
            "tokenDetail" => {
                let token = address(body["address"].as_str().unwrap_or(""))?;
                self.four_gate
                    .get("/private/token/get/v2")
                    .query(&[("address", format!("{token:#x}"))])
            }
            "nonce" => {
                let wallet = address(body["address"].as_str().unwrap_or(""))?;
                self.four_gate.post("/private/user/nonce/generate").json(&json!({"accountAddress":format!("{wallet:#x}"),"verifyType":"LOGIN","networkCode":"BSC"}))
            }
            "login" => self
                .four_gate
                .post("/private/user/login/dex")
                .json(&body["payload"]),
            "create" => {
                let token = body["accessToken"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() < 8192)
                    .ok_or_else(|| AppError::invalid("Four 登录凭据无效"))?;
                let mut token = reqwest::header::HeaderValue::from_str(token)
                    .map_err(|_| AppError::invalid("Four 登录凭据无效"))?;
                token.set_sensitive(true);
                self.four_gate
                    .post("/private/token/create")
                    .header("meme-web-access", token)
                    .json(&body["payload"])
            }
            "predictTokenAddress" => return self.predict_four(&body).await,
            _ => return Err(AppError::invalid("未知 Four 操作")),
        };
        self.four_gate
            .request(request, body["action"] == "config", 2_000_000)
            .await
    }
    async fn predict_four(&self, body: &Value) -> Result<Value> {
        let from = address(body["from"].as_str().unwrap_or(""))?;
        let calldata: Bytes = body["createCalldata"]
            .as_str()
            .unwrap_or("")
            .parse()
            .map_err(|_| AppError::invalid("创建参数无效"))?;
        if !calldata.starts_with(&[0x51, 0x9e, 0xbb, 0x10]) || calldata.len() > 500_000 {
            return Err(AppError::invalid("创建方法无效"));
        }
        let value: U256 = body["value"]
            .as_str()
            .unwrap_or("")
            .parse()
            .map_err(|_| AppError::invalid("创建金额无效"))?;
        let trace=self.rpc.read(Chain::Bsc,Call::new("debug_traceCall",vec![json!({"from":from,"to":"0x5c952063c7fc8610FFDB798152D69F0B9550762b","data":calldata,"value":format!("{value:#x}"),"gas":"0x1000000"}),json!("latest"),json!({"tracer":"callTracer"})])).await?;
        if trace.get("error").is_some() {
            return Err(AppError::new(
                "CREATE_REVERTED",
                "Four 创建推导失败",
                422,
                false,
            ));
        }
        let token = find_create(&trace).ok_or_else(|| {
            AppError::new("NO_CREATED_TOKEN", "没有找到成功创建的代币", 422, false)
        })?;
        Ok(json!({"tokenAddress":token}))
    }
}
fn find_create(trace: &Value) -> Option<String> {
    // Failed ancestor subcalls must never contribute an apparent created address.
    if trace.get("error").is_some() {
        return None;
    }
    if trace["type"] == "CREATE2" {
        if let Some(to) = trace["to"].as_str() {
            if address(to).is_ok() {
                return Some(to.into());
            }
        }
    }
    trace["calls"].as_array()?.iter().find_map(find_create)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reverted_subtrees_cannot_supply_predicted_address() {
        let token = "0x0000000000000000000000000000000000000001";
        assert!(
            find_create(
                &json!({"type":"CALL","error":"reverted","calls":[{"type":"CREATE2","to":token}]})
            )
            .is_none()
        );
        assert_eq!(
            find_create(&json!({"type":"CALL","calls":[{"type":"CREATE2","to":token}]})).as_deref(),
            Some(token)
        );
    }
}
