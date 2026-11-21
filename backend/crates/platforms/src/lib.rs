//! Official registries establish platform provenance; token symbols never do.
pub mod abi;
mod arc;
mod bsc;
#[cfg(test)]
mod bsc_tests;
#[cfg(test)]
mod genius_tests;
pub mod next;
#[cfg(test)]
mod next_tests;
mod pons;
mod xlayer;
use alloy_primitives::{Address, Bytes};
use alloy_sol_types::SolCall;
use botai_core::{AppError, Chain, Result};
use botai_rpc::{Call, Rpc, multicall::Read};
use moka::future::Cache;
use serde_json::{Value, json};
use std::time::Duration;
#[derive(Clone)]
pub struct Platforms {
    rpc: Rpc,
    cache: Cache<String, Value>,
}
impl Platforms {
    pub fn new(rpc: Rpc) -> Self {
        Self {
            rpc,
            cache: Cache::builder()
                .max_capacity(1024)
                .time_to_live(Duration::from_secs(2))
                .build(),
        }
    }
    pub async fn inspect(&self, chain: Chain, token: Address, block: Option<u64>) -> Result<Value> {
        if token.is_zero() {
            return Err(AppError::invalid("目标代币地址无效"));
        }
        let block = match block {
            Some(n) => n,
            None => {
                let value = self
                    .rpc
                    .read(chain, Call::new("eth_blockNumber", vec![]))
                    .await?;
                u64::from_str_radix(value.as_str().unwrap_or("").trim_start_matches("0x"), 16)
                    .map_err(|_| AppError::unavailable("区块读取失败"))?
            }
        };
        self.cache
            .try_get_with(format!("{}:{token:#x}:{block}", chain.config().id), async {
                match chain {
                    Chain::Bsc => self.bsc(token, block).await,
                    Chain::Xlayer => self.xlayer(token, block).await,
                    Chain::Robinhood => {
                        let market = self.pons(token, block).await?;
                        if market.is_null() {
                            let next = self.next(token, block).await?;
                            if next.is_null() {
                                Ok(
                                    json!({"platform":"external","venue":"okx","stage":"external",
                                    "token":token.to_checksum(None),"pairToken":Address::ZERO,
                                    "blockTag":format!("{block:#x}")}),
                                )
                            } else {
                                Ok(next)
                            }
                        } else {
                            Ok(market)
                        }
                    }
                    Chain::Arc => self.arc(token, block).await,
                    Chain::Akc => Err(AppError::invalid("AKC 当前仅支持工具")),
                }
            })
            .await
            .map_err(|e| (*e).clone())
    }
}
fn view<C: SolCall>(target: Address, call: C, required: bool) -> Read {
    Read {
        target,
        data: call.abi_encode().into(),
        required,
    }
}
fn bytes(row: &Option<Bytes>) -> Result<&[u8]> {
    row.as_ref()
        .map(|b| b.as_ref())
        .filter(|b: &&[u8]| !b.is_empty())
        .ok_or_else(invalid)
}
fn decode<C: SolCall>(row: &Option<Bytes>) -> Result<C::Return> {
    C::abi_decode_returns(bytes(row)?).map_err(|_| invalid())
}
fn metadata(symbol: &Option<Bytes>, decimals: &Option<Bytes>) -> Result<(String, u8)> {
    let symbol = decode::<abi::symbolCall>(symbol)?;
    let decimals = decode::<abi::decimalsCall>(decimals)?;
    if symbol.is_empty() || symbol.len() > 256 || decimals > 36 {
        return Err(invalid());
    }
    Ok((symbol, decimals))
}
fn invalid() -> AppError {
    AppError::new(
        "PLATFORM_DATA_INVALID",
        "平台登记或代币数据不一致",
        422,
        false,
    )
}
fn unsupported(message: &str) -> AppError {
    AppError::new("UNSUPPORTED_TRADE_TOKEN", message, 422, false)
}
