//! Next's official Robinhood registry, not a symbol or address suffix heuristic.
use super::{abi::*, *};
use alloy_primitives::{U256, address, keccak256};
use alloy_sol_types::{SolValue, sol};

// Official production deployment, finalized 2026-09-22T13:51:45Z.
pub const LAUNCHPAD: Address = address!("78f976d949ede7c132ba27607f052311cd5bd507");
pub const VENUE: Address = address!("051195651fd4460893b66532e1cb413fdb61ac11");
pub const HOOK: Address = address!("142c4c47e235b471da3e7098dc59139c1f31a8cc");
pub const SELL_HOOK_DATA: [u8; 4] = [0x4c, 0x0f, 0xa2, 0x5a];
sol! {
    struct NextPoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
    interface NextVenue { function poolKeyFor(address token) view returns(NextPoolKey); }
}

impl Platforms {
    pub(crate) async fn next(&self, token: Address, block: u64) -> Result<Value> {
        let tag = format!("{block:#x}");
        let rows = self
            .rpc
            .multicall(
                Chain::Robinhood,
                vec![
                    view(LAUNCHPAD, tokenCreatorCall { token }, false),
                    view(LAUNCHPAD, getTokenStateCall { token }, false),
                ],
                &tag,
            )
            .await?;
        // A historical block before Next's deployment is not a Next market.
        if rows
            .iter()
            .all(|row| row.as_ref().is_none_or(|value| value.is_empty()))
        {
            return Ok(Value::Null);
        }
        let creator = decode::<tokenCreatorCall>(&rows[0])?;
        let state = decode::<getTokenStateCall>(&rows[1])?;
        if creator.is_zero() && state.is_zero() {
            return Ok(Value::Null);
        }
        if creator.is_zero() || state.is_zero() || state > U256::from(3) {
            return Err(invalid());
        }
        let rows = self
            .rpc
            .multicall(
                Chain::Robinhood,
                vec![
                    view(LAUNCHPAD, virtualPoolsCall { token }, true),
                    view(token, taxConfigCall {}, true),
                ],
                &tag,
            )
            .await?;
        let pool = decode::<virtualPoolsCall>(&rows[0])?;
        let tax = decode::<taxConfigCall>(&rows[1])?;
        let total: u32 = [tax.a, tax.b, tax.c, tax.d].iter().map(|n| *n as u32).sum();
        if total > 1000
            || pool.quote == token
            || pool.d > U256::from(255)
            || (pool.d.is_zero() != pool.quote.is_zero())
        {
            return Err(invalid());
        }
        let mut result = json!({"platform":"next", "token":token.to_checksum(None),
            "creator":creator.to_checksum(None), "pairToken":pool.quote.to_checksum(None),
            "poolType":pool.d.to::<u8>(), "blockTag":tag, "baseFeeBps":"100", "creatorTaxBps":total.to_string(),
            "conditionalDividendBps":tax.b,
            "tokenTax":{"componentsBps":[tax.a,tax.b,tax.c,tax.d],"totalBps":total}});
        match state.to::<u8>() {
            1 => {
                if !pool.c.is_zero() || pool.a.is_zero() || pool.b.is_zero() {
                    return Err(invalid());
                }
                result["venue"] = json!("curve");
                result["stage"] = json!("curve");
                result["curve"] = json!(LAUNCHPAD.to_checksum(None));
            }
            2 => {
                result["venue"] = json!("blocked");
                result["stage"] = json!("migration");
                result["reason"] = json!("Next 内盘已满，等待官方建立外盘");
            }
            3 => {
                if pool.c != U256::from(1) {
                    return Err(invalid());
                }
                let rows = self
                    .rpc
                    .multicall(
                        Chain::Robinhood,
                        vec![view(VENUE, NextVenue::poolKeyForCall { token }, true)],
                        &tag,
                    )
                    .await?;
                let key = decode::<NextVenue::poolKeyForCall>(&rows[0])?;
                let (a, b) = if token < pool.quote {
                    (token, pool.quote)
                } else {
                    (pool.quote, token)
                };
                if key.currency0 != a
                    || key.currency1 != b
                    || key.hooks != HOOK
                    || key.tickSpacing.as_i32() <= 0
                    || key.fee.to::<u32>() > 1_000_000
                {
                    return Err(invalid());
                }
                result["venue"] = json!("v4");
                result["stage"] = json!("v4");
                result["poolId"] = json!(keccak256(
                    (a, b, key.fee, key.tickSpacing, key.hooks).abi_encode()
                ));
                result["poolKey"] = json!({"currency0":a.to_checksum(None),"currency1":b.to_checksum(None),
                    "fee":key.fee.to::<u32>(),"tickSpacing":key.tickSpacing.as_i32(),"hooks":key.hooks.to_checksum(None)});
                result["sellHookData"] = json!("0x4c0fa25a");
            }
            _ => unreachable!(),
        }
        Ok(result)
    }
}
