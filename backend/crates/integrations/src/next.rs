//! Fixed official Next endpoints. Never forward arbitrary URLs or private keys.
use crate::{
    Integrations, address, bounded_json,
    image::{Image, part, validate_image},
};
use alloy_primitives::{Address, Signature, U256};
use alloy_sol_types::{SolCall, sol};
use botai_core::{AppError, Chain, Result};
use botai_platforms::{abi, next::LAUNCHPAD};
use botai_rpc::{Call, multicall::Read};
use reqwest::multipart::Form;
use serde::Deserialize;
use serde_json::{Value, json};
const ORIGIN: &str = "https://next.meme";
const LIMIT: usize = 3 * 1024 * 1024;
// Official 4663 production instance, 2026-09-22. Decimals/economics are read on-chain.
const POOLS: [(&str, &str); 15] = [
    ("ETH", "0x0000000000000000000000000000000000000000"),
    ("WETH", "0x0bd7d308f8e1639fab988df18a8011f41eacad73"),
    ("USDG", "0x5fc5360d0400a0fd4f2af552add042d716f1d168"),
    ("UUSD", "0x61a10e8556bed032ea176330e7f17d6a12a10000"),
    ("GME", "0x1b0e319c6a659f002271b69db8a7df2f911c153e"),
    ("SPCX", "0x4a0e65a3eccec6dbe60ae065f2e7bb85fae35eea"),
    ("NVDA", "0xd0601ce157db5bdc3162bbac2a2c8af5320d9eec"),
    ("AMZN", "0x12f190a9f9d7d37a250758b26824b97ce941bf54"),
    ("AAPL", "0xaf3d76f1834a1d425780943c99ea8a608f8a93f9"),
    ("GOOGL", "0x2e0847e8910a9732eb3fb1bb4b70a580adad4fe3"),
    ("TSLA", "0x322f0929c4625ed5bad873c95208d54e1c003b2d"),
    ("MSFT", "0xe93237c50d904957cf27e7b1133b510c669c2e74"),
    ("META", "0xc0d6457c16cc70d6790dd43521c899c87ce02f35"),
    ("QQQ", "0xd5f3879160bc7c32ebb4dc785f8a4f505888de68"),
    ("SPY", "0x117cc2133c37b721f49de2a7a74833232b3b4c0c"),
];
sol! { function poolLaunchConfigs(uint8 poolType) view returns(uint256 launchTarget,uint256 launchFee,uint256 virtualPayment,uint256 launchPaymentReserve); }
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
pub enum Action {
    Verify {
        message: String,
        signature: String,
    },
    Metadata {
        #[serde(rename = "accessToken")]
        access_token: String,
        metadata: Metadata,
    },
}

#[cfg(test)]
mod tests {
    use super::*;
    const MESSAGE: &str = "next.meme wants you to sign in with your Ethereum account:\n0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf\n\nSign in to Next\n\nURI: https://next.meme\nVersion: 1\nChain ID: 4663\nNonce: abcdefgh1234\nIssued At: 2026-09-22T00:00:00.000Z\nExpiration Time: 2026-09-23T00:00:00.000Z";
    // Offline signature from a publicly known disposable test key; never submitted.
    const SIGNATURE: &str = "0x4de894e5966fa1669b1f92c184325103a19c624de0e40eefaf0e752fc50ee5a04a03bf5609a62294e39da2174a605f44d386c0cfe41ae40a9bf189a90ad966f91b";

    #[test]
    fn next_login_binds_official_origin_chain_and_signer() {
        validate_message(MESSAGE, SIGNATURE).unwrap();
        for message in [
            MESSAGE.replace("next.meme", "unrelated.example"),
            MESSAGE.replace("4663", "56"),
            MESSAGE.replace(
                "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
                "0x0000000000000000000000000000000000000001",
            ),
            format!("{MESSAGE}\nextra"),
            String::new(),
        ] {
            assert!(validate_message(&message, SIGNATURE).is_err());
        }
        assert!(validate_message(MESSAGE, "0x00").is_err());
    }

    #[tokio::test]
    async fn next_requests_keep_fixed_origin_and_reject_private_keys() {
        let http = reqwest::Client::new();
        let api = Integrations::new(
            http.clone(),
            botai_rpc::Rpc::with_urls(http, Default::default()),
        );
        for path in [
            "auth/nonce",
            "auth/verify",
            "upload/logo",
            "tokens/pre-meta",
        ] {
            let request = api
                .next_request(reqwest::Method::POST, path)
                .build()
                .unwrap();
            assert_eq!(
                request.url().as_str(),
                format!("https://next.meme/api/{path}?chainId=4663")
            );
            assert_eq!(request.headers()["origin"], ORIGIN);
            assert_eq!(request.headers()["referer"], "https://next.meme/create");
        }
        for field in ["privateKey", "mnemonic", "unexpected"] {
            let body = json!({"action":"verify","message":MESSAGE,"signature":SIGNATURE,field:"do-not-forward"});
            assert!(serde_json::from_value::<Action>(body.clone()).is_err());
            assert!(api.next_action(body).await.is_err());
        }
        assert!(
            api.next_action(json!({"action":"verify","message":MESSAGE,"signature":"0x00"}))
                .await
                .is_err()
        );
    }
}
#[derive(Deserialize, serde::Serialize)]
#[serde(deny_unknown_fields)]
pub struct Metadata {
    pub token_address: Address,
    pub category: String,
    pub description: String,
    pub logo_url: String,
    pub website: String,
    pub twitter: String,
    pub discord: String,
    pub telegram: String,
}
fn validate_message(message: &str, signature: &str) -> Result<()> {
    let lines: Vec<_> = message.lines().collect();
    if message.len() > 2048
        || lines.len() != 11
        || lines[0] != "next.meme wants you to sign in with your Ethereum account:"
        || lines[2] != ""
        || lines[3] != "Sign in to Next"
        || lines[4] != ""
        || lines[5] != "URI: https://next.meme"
        || lines[6] != "Version: 1"
        || lines[7] != "Chain ID: 4663"
        || !lines[8].starts_with("Nonce: ")
        || !lines[9].starts_with("Issued At: ")
        || !lines[10].starts_with("Expiration Time: ")
    {
        return Err(AppError::invalid("Next 登录消息无效"));
    }
    let sig: Signature = signature
        .parse()
        .map_err(|_| AppError::invalid("Next 登录签名无效"))?;
    if sig
        .recover_address_from_msg(message)
        .map_err(|_| AppError::invalid("Next 登录签名无效"))?
        != address(lines[1])?
    {
        return Err(AppError::invalid("Next 登录地址不符"));
    }
    Ok(())
}
impl Integrations {
    fn next_request(&self, method: reqwest::Method, path: &str) -> reqwest::RequestBuilder {
        self.http
            .request(method, format!("{ORIGIN}/api/{path}?chainId=4663"))
            .header("origin", ORIGIN)
            .header("referer", "https://next.meme/create")
    }
    pub async fn next_nonce(&self) -> Result<Value> {
        bounded_json(
            self.next_request(reqwest::Method::GET, "auth/nonce")
                .send()
                .await
                .map_err(|_| AppError::unavailable("Next 登录请求失败"))?,
            "Next 登录",
            20_000,
        )
        .await
    }
    pub async fn next_action(&self, body: Value) -> Result<Value> {
        botai_core::error::reject_secret_fields(&body)?;
        let action: Action =
            serde_json::from_value(body).map_err(|_| AppError::invalid("Next 请求字段无效"))?;
        let request = match action {
            Action::Verify { message, signature } => {
                validate_message(&message, &signature)?;
                self.next_request(reqwest::Method::POST, "auth/verify")
                    .json(&json!({"message":message,"signature":signature}))
            }
            Action::Metadata {
                access_token,
                metadata,
            } => {
                if access_token.is_empty()
                    || access_token.len() > 8192
                    || access_token.contains(['\r', '\n'])
                    || metadata.token_address.is_zero()
                    || metadata.description.chars().count() > 5000
                    || !["MEME", "AI", "RWA", "DEFI", "GAMEFI", "COMMUNITY"]
                        .contains(&metadata.category.as_str())
                    || metadata.logo_url.len() > LIMIT
                    || metadata.logo_url.is_empty()
                {
                    return Err(AppError::invalid("Next 项目资料无效"));
                }
                for url in [
                    &metadata.website,
                    &metadata.twitter,
                    &metadata.discord,
                    &metadata.telegram,
                ] {
                    if !url.is_empty()
                        && (url.len() > 500
                            || reqwest::Url::parse(url)
                                .ok()
                                .is_none_or(|v| !["https", "http"].contains(&v.scheme())))
                    {
                        return Err(AppError::invalid("社交链接格式无效"));
                    }
                }
                self.next_request(reqwest::Method::POST, "tokens/pre-meta")
                    .bearer_auth(access_token)
                    .json(&metadata)
            }
        };
        bounded_json(
            request
                .send()
                .await
                .map_err(|_| AppError::unavailable("Next 请求失败"))?,
            "Next",
            LIMIT,
        )
        .await
    }
    pub async fn next_image(&self, image: Image) -> Result<Value> {
        validate_image(&image, 2 * 1024 * 1024, true)?;
        bounded_json(
            self.next_request(reqwest::Method::POST, "upload/logo")
                .multipart(Form::new().part("logo", part(image)?))
                .send()
                .await
                .map_err(|_| AppError::unavailable("Next 图片上传失败"))?,
            "Next 图片",
            LIMIT,
        )
        .await
    }
    pub async fn next_config(&self) -> Result<Value> {
        self.cache.try_get_with(format!("next-config-4663-{LAUNCHPAD:#x}"), async {
            let block = self.rpc.read(Chain::Robinhood, Call::new("eth_blockNumber", vec![])).await?;
            let tag = block.as_str().ok_or_else(|| AppError::unavailable("区块读取失败"))?;
            let mut reads = Vec::new();
            for (i, (_, payment)) in POOLS.iter().enumerate() {
                reads.push(Read { target: LAUNCHPAD, data: poolLaunchConfigsCall { poolType:i as u8 }.abi_encode().into(), required:true });
                if i != 0 { reads.push(Read { target:address(payment)?, data:abi::decimalsCall{}.abi_encode().into(), required:true }); }
            }
            let values = self.rpc.multicall(Chain::Robinhood, reads, tag).await?;
            let mut rows = values.iter();
            let mut pools = Vec::new();
            for (i, (symbol, payment)) in POOLS.iter().enumerate() {
                let raw = rows.next().and_then(Option::as_ref).ok_or_else(|| AppError::unavailable("Next 底池配置读取失败"))?;
                let config = poolLaunchConfigsCall::abi_decode_returns(raw).map_err(|_| AppError::unavailable("Next 底池配置无效"))?;
                let decimals = if i == 0 { 18 } else {
                    abi::decimalsCall::abi_decode_returns(rows.next().and_then(Option::as_ref).ok_or_else(|| AppError::unavailable("精度读取失败"))?)
                        .map_err(|_| AppError::unavailable("精度读取失败"))?
                };
                if decimals > 36 || config.launchTarget == U256::ZERO { return Err(AppError::unavailable("Next 底池尚未开放")); }
                pools.push(json!({"poolType":i,"address":address(payment)?.to_checksum(None),"symbol":symbol,"decimals":decimals,
                    "native":i==0,"launchTarget":config.launchTarget.to_string(),"launchFee":config.launchFee.to_string()}));
            }
            Ok(json!({"chainId":4663,"launchpad":LAUNCHPAD.to_checksum(None),"pools":pools}))
        }).await.map_err(|e| (*e).clone())
    }
}
