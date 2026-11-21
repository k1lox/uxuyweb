//! Wallet state for many wallets in two round trips: one Multicall3 eth_call for balances and
//! allowances, one JSON-RPC batch for pending nonces.
use crate::{
    config::MULTICALL3,
    error::{ApiError, Result},
    rpc::{Rpc, hex_u64},
};
use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{SolCall, sol};
use serde::{Deserialize, Serialize};
use serde_json::json;

sol! {
    struct Call3 { address target; bool allowFailure; bytes callData; }
    struct Result3 { bool success; bytes returnData; }
    function aggregate3(Call3[] calls) payable returns (Result3[] returnData);
    function getEthBalance(address addr) view returns (uint256 balance);
    function balanceOf(address owner) view returns (uint256);
    function allowance(address owner, address spender) view returns (uint256);
    function symbol() view returns (string);
    function name() view returns (string);
    function decimals() view returns (uint8);
}

pub const MAX_WALLETS: usize = 500;
const WALLETS_PER_MULTICALL: usize = 100;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct StateRequest {
    pub wallets: Vec<Address>,
    #[serde(default)]
    pub token: Option<Address>,
    /// Allowance target; defaults to the configured UXUY token spender.
    #[serde(default)]
    pub spender: Option<Address>,
    /// A plain ERC20 transfer does not consume an allowance.
    #[serde(default)]
    pub skip_allowance: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WalletState {
    pub wallet: Address,
    pub native: String,
    pub nonce: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub token_balance: Option<String>,
    /// Allowance granted to the requested spender.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub router_allowance: Option<String>,
}

pub async fn states(rpc: &Rpc, router: Address, req: &StateRequest) -> Result<Vec<WalletState>> {
    if req.wallets.is_empty() || req.wallets.len() > MAX_WALLETS {
        return Err(ApiError::invalid("钱包数量需在 1–500 之间"));
    }
    use futures::{StreamExt, TryStreamExt, stream};
    let groups: Vec<_> = req.wallets.chunks(WALLETS_PER_MULTICALL).map(<[_]>::to_vec).collect();
    let chunks: Vec<Vec<WalletState>> = stream::iter(groups)
        .map(|chunk| async move {
            let nonce_calls: Vec<_> = chunk.iter().map(|w| ("eth_getTransactionCount", json!([format!("{w:#x}"), "pending"]))).collect();
            let mut calls = Vec::new();
            for w in &chunk {
                calls.push(Call3 { target: MULTICALL3, allowFailure: false, callData: getEthBalanceCall { addr: *w }.abi_encode().into() });
                if let Some(t) = req.token {
                    calls.push(Call3 { target: t, allowFailure: true, callData: balanceOfCall { owner: *w }.abi_encode().into() });
                    if !req.skip_allowance {
                        calls.push(Call3 { target: t, allowFailure: true, callData: allowanceCall { owner: *w, spender: req.spender.unwrap_or(router) }.abi_encode().into() });
                    }
                }
            }
            let data: Bytes = aggregate3Call { calls }.abi_encode().into();
            let (nonces, ret) = tokio::try_join!(rpc.batch(&nonce_calls), rpc.call("eth_call", json!([{"to": format!("{MULTICALL3:#x}"), "data": data}, "latest"])))?;
            let ret: Bytes = ret.as_str().unwrap_or("").parse().map_err(|_| ApiError::unavailable("批量读取返回无效"))?;
            let results = aggregate3Call::abi_decode_returns(&ret).map_err(|_| ApiError::unavailable("批量读取解码失败"))?;
            let per = 1 + usize::from(req.token.is_some()) + usize::from(req.token.is_some() && !req.skip_allowance);
            let mut out = Vec::with_capacity(chunk.len());
            if results.len() != chunk.len() * per {
                return Err(ApiError::unavailable("批量读取数量不符"));
            }
            for (i, w) in chunk.iter().enumerate() {
                let word = |r: &Result3| -> Option<U256> {
                    (r.success && r.returnData.len() >= 32).then(|| U256::from_be_slice(&r.returnData[..32]))
                };
                let native = word(&results[i * per]).ok_or_else(|| ApiError::unavailable("余额读取失败"))?;
                let nonce = match &nonces[i] {
                    Ok(v) => hex_u64(v)?,
                    Err(e) => return Err(e.clone()),
                };
                out.push(WalletState {
                    wallet: *w,
                    native: native.to_string(),
                    nonce,
                    token_balance: req.token.map(|_| word(&results[i * per + 1]).map(|v| v.to_string()).unwrap_or_default()),
                    router_allowance: req.token.filter(|_| !req.skip_allowance).map(|_| word(&results[i * per + 2]).map(|v| v.to_string()).unwrap_or_default()),
                });
            }
            Ok::<_, ApiError>(out)
    }).buffered(4).try_collect().await?;
    Ok(chunks.into_iter().flatten().collect())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenMeta {
    pub token: Address,
    pub name: String,
    pub symbol: String,
    /// None when the token does not expose decimals(); callers must not assume 18.
    pub decimals: Option<u8>,
}

pub async fn token_meta(rpc: &Rpc, token: Address) -> Result<TokenMeta> {
    let calls = vec![
        Call3 { target: token, allowFailure: true, callData: nameCall {}.abi_encode().into() },
        Call3 { target: token, allowFailure: true, callData: symbolCall {}.abi_encode().into() },
        Call3 { target: token, allowFailure: true, callData: decimalsCall {}.abi_encode().into() },
    ];
    let data: Bytes = aggregate3Call { calls }.abi_encode().into();
    let ret = rpc.call("eth_call", json!([{"to": format!("{MULTICALL3:#x}"), "data": data}, "latest"])).await?;
    let ret: Bytes = ret.as_str().unwrap_or("").parse().map_err(|_| ApiError::unavailable("代币信息返回无效"))?;
    let r = aggregate3Call::abi_decode_returns(&ret).map_err(|_| ApiError::unavailable("代币信息解码失败"))?;
    if r.len() != 3 || !r[1].success {
        return Err(ApiError::invalid("不是有效的代币合约"));
    }
    let text = |x: &Result3| -> String {
        if !x.success { return String::new(); }
        nameCall::abi_decode_returns(&x.returnData).map(|s| s.chars().take(64).collect()).unwrap_or_default()
    };
    let decimals = if r[2].success { decimalsCall::abi_decode_returns(&r[2].returnData).ok() } else { None };
    Ok(TokenMeta { token, name: text(&r[0]), symbol: text(&r[1]), decimals })
}
