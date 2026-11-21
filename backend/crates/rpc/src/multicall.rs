use crate::{Call, Rpc};
use alloy_primitives::{Address, Bytes};
use alloy_sol_types::{SolCall, sol};
use botai_core::{AppError, Chain, Result};
use serde_json::json;

sol! {
    struct Call3 { address target; bool allowFailure; bytes callData; }
    struct Result3 { bool success; bytes returnData; }
    function aggregate3(Call3[] calls) payable returns (Result3[] returnData);
}
pub const MULTICALL: &str = "0xca11bde05977b3631167028862be2a173976ca11";
pub struct Read {
    pub target: Address,
    pub data: Bytes,
    pub required: bool,
}
impl Rpc {
    /// Only explicit view reads belong here. Never wrap stateful swaps or caller-dependent quotes.
    pub async fn multicall(
        &self,
        chain: Chain,
        reads: Vec<Read>,
        block: &str,
    ) -> Result<Vec<Option<Bytes>>> {
        Ok(self
            .multicall_results(chain, reads, block)
            .await?
            .into_iter()
            .map(|row| row.success.then_some(row.returnData))
            .collect())
    }
    /// Preserve revert data for registries whose documented "not found" is
    /// a custom error. Unknown reverts must not be mistaken for non-membership.
    pub async fn multicall_results(
        &self,
        chain: Chain,
        reads: Vec<Read>,
        block: &str,
    ) -> Result<Vec<Result3>> {
        if reads.is_empty() {
            return Ok(vec![]);
        }
        if reads.len() > 1000 {
            return Err(AppError::invalid("Multicall 读取数量过多"));
        }
        let mut result = Vec::with_capacity(reads.len());
        let calls = reads
            .chunks(128)
            .map(|chunk| {
                let data = aggregate3Call {
                    calls: chunk
                        .iter()
                        .map(|read| Call3 {
                            target: read.target,
                            allowFailure: true,
                            callData: read.data.clone(),
                        })
                        .collect(),
                }
                .abi_encode();
                Call::new(
                    "eth_call",
                    vec![
                        json!({"to": MULTICALL, "data": Bytes::from(data)}),
                        json!(block),
                    ],
                )
            })
            .collect();
        let outputs = self.read_many(chain, calls).await?;
        for (chunk, output) in reads.chunks(128).zip(outputs) {
            let data: Bytes = output
                .as_str()
                .ok_or_else(|| AppError::unavailable("Multicall 返回无效"))?
                .parse()
                .map_err(|_| AppError::unavailable("Multicall 编码无效"))?;
            let decoded = aggregate3Call::abi_decode_returns(&data)
                .map_err(|_| AppError::unavailable("Multicall 解码失败"))?;
            if decoded.len() != chunk.len() {
                return Err(AppError::unavailable("Multicall 数量不符"));
            }
            for (read, row) in chunk.iter().zip(decoded) {
                if !row.success && read.required {
                    return Err(AppError::new(
                        "READ_REVERTED",
                        "必要的合约读取失败",
                        422,
                        false,
                    ));
                }
                result.push(row);
            }
        }
        Ok(result)
    }
}
