use super::{abi::*, *};
use alloy_primitives::{U256, address, keccak256};
use alloy_sol_types::SolValue;
const FACTORY: Address = address!("7ed598bcef8bd9edd8c97a195c6d13f40801ec7e");
const HOOK: Address = address!("e5e702641ea86f4ae6cc3cdaed2b886f976be044");
impl Platforms {
    pub(crate) async fn pons(&self, token: Address, block: u64) -> Result<Value> {
        let tag = format!("{block:#x}");
        let rows = self
            .rpc
            .multicall(
                Chain::Robinhood,
                vec![view(FACTORY, getLaunchedTokenCall { token }, true)],
                &tag,
            )
            .await?;
        let record = decode::<getLaunchedTokenCall>(&rows[0])?;
        if !record.exists {
            return Ok(Value::Null);
        }
        if record.token != token || record.curve.is_zero() {
            return Err(invalid());
        }
        let stage = match record.phase {
            0 => "curve",
            1 => "migration",
            2 => "v4",
            3 => "rescued",
            _ => return Err(unsupported("未知的 Pons 迁移阶段")),
        };
        let mut result = json!({"platform":"pons","token":token.to_checksum(None),"pairToken":record.pairToken.to_checksum(None),"stage":stage,"blockTag":tag});
        if stage == "curve" {
            let curve = record.curve;
            let rows = self
                .rpc
                .multicall(
                    Chain::Robinhood,
                    vec![
                        view(curve, Curve::pairTokenCall {}, true),
                        view(curve, Curve::getReservesCall {}, true),
                        view(curve, Curve::realQuoteReserveCall {}, true),
                        view(curve, Curve::sellableTokensCall {}, true),
                        view(curve, Curve::readyToGraduateCall {}, true),
                        view(curve, Curve::feeBpsCall {}, true),
                        view(curve, Curve::creatorTaxBpsCall {}, true),
                    ],
                    &tag,
                )
                .await?;
            let pair = decode::<Curve::pairTokenCall>(&rows[0])?;
            if pair != record.pairToken {
                return Err(invalid());
            }
            let reserves = decode::<Curve::getReservesCall>(&rows[1])?;
            let real = decode::<Curve::realQuoteReserveCall>(&rows[2])?;
            let sellable = decode::<Curve::sellableTokensCall>(&rows[3])?;
            let ready = decode::<Curve::readyToGraduateCall>(&rows[4])?;
            let fee = decode::<Curve::feeBpsCall>(&rows[5])?;
            let tax = decode::<Curve::creatorTaxBpsCall>(&rows[6])?;
            if fee.checked_add(tax).is_none_or(|n| n >= U256::from(10000)) {
                return Err(unsupported("Pons 费率无法正常交易"));
            }
            if ready || sellable.is_zero() {
                result["venue"] = json!("blocked");
                result["stage"] = json!("curve-ready");
                result["reason"] = json!("内盘已经结束，等待建立 V4 外盘");
                return Ok(result);
            }
            result["venue"] = json!("curve");
            result["curve"] = json!(curve.to_checksum(None));
            result["baseFeeBps"] = json!(fee.to_string());
            result["creatorTaxBps"] = json!(tax.to_string());
            result["curveState"] = json!({"curve":curve.to_checksum(None),"pairToken":pair.to_checksum(None),"quoteReserve":reserves.quoteReserve.to_string(),"tokenReserve":reserves.tokenReserve.to_string(),"realQuoteReserve":real.to_string(),"sellableTokens":sellable.to_string(),"readyToGraduate":ready,"feeBps":fee.to_string(),"creatorTaxBps":tax.to_string(),"currentSnipeTaxBps":null});
        } else if stage == "v4" {
            if record.pairToken == token
                || record.tickSpacing.as_i32() <= 0
                || record.tickSpacing.as_i32() > 32767
            {
                return Err(invalid());
            }
            let rows = self
                .rpc
                .multicall(
                    Chain::Robinhood,
                    vec![view(FACTORY, getLaunchFeePolicyCall { token }, true)],
                    &tag,
                )
                .await?;
            let policy = decode::<getLaunchFeePolicyCall>(&rows[0])?;
            let (a, b) = if token < record.pairToken {
                (token, record.pairToken)
            } else {
                (record.pairToken, token)
            };
            let id = keccak256((a, b, record.poolFee, record.tickSpacing, HOOK).abi_encode());
            result["venue"] = json!("v4");
            result["poolKey"] = json!({"currency0":a.to_checksum(None),"currency1":b.to_checksum(None),"fee":record.poolFee.to::<u32>(),"tickSpacing":record.tickSpacing.as_i32(),"hooks":HOOK.to_checksum(None)});
            result["poolId"] = json!(id);
            result["baseFeeBps"] = json!(policy.hookFeeBps.to_string());
            result["creatorTaxBps"] = json!(record.creatorTaxBps.to_string());
        } else {
            result["venue"] = json!("blocked");
            result["reason"] = json!(if stage == "migration" {
                "代币正在迁移，池子完成前不能交易"
            } else {
                "该代币已进入救援状态，批量交易保持关闭"
            });
        }
        Ok(result)
    }
}
