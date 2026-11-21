use super::{abi::*, *};
use alloy_primitives::{U256, address};
pub const LAUNCHPAD: Address = address!("9510a1444b961d46ae9c76ba00adb55217754696");
const STOCKS: [(Address, &str); 3] = [
    (
        address!("8e2eed8b8b5e13ea7bf38e50d7821d2c57309072"),
        "wSPCXx",
    ),
    (
        address!("a8ddb5cd96b5222afe198316e9a57caa642850d5"),
        "wNVDAx",
    ),
    (
        address!("943bf64d566c32a2bcd41ac92fb63c111cc9de8f"),
        "wAAPLx",
    ),
];
pub fn classify(state: U256, creator: Address) -> Result<Option<u8>> {
    if creator.is_zero() && state.is_zero() {
        return Ok(None);
    }
    if !creator.is_zero() && [U256::from(1), U256::from(3)].contains(&state) {
        return Ok(Some(state.to::<u8>()));
    }
    Err(unsupported("Launchpad 代币当前不可交易，可能正在迁移"))
}
impl Platforms {
    pub(crate) async fn xlayer(&self, token: Address, block: u64) -> Result<Value> {
        let tag = format!("{block:#x}");
        let rows = self
            .rpc
            .multicall(
                Chain::Xlayer,
                vec![
                    view(token, symbolCall {}, true),
                    view(token, decimalsCall {}, true),
                    view(LAUNCHPAD, getTokenStateCall { token }, true),
                    view(LAUNCHPAD, tokenCreatorCall { token }, true),
                    view(token, taxConfigCall {}, false),
                    view(LAUNCHPAD, virtualPoolsCall { token }, false),
                ],
                &tag,
            )
            .await?;
        let (symbol, decimals) = metadata(&rows[0], &rows[1])?;
        let stage = classify(
            decode::<getTokenStateCall>(&rows[2])?,
            decode::<tokenCreatorCall>(&rows[3])?,
        )?;
        let pair = if stage == Some(1) {
            let quote = decode::<virtualPoolsCall>(&rows[5])?.quote;
            if quote.is_zero() {
                json!({"address":Address::ZERO,"symbol":"OKB","decimals":18,"native":true})
            } else {
                let (_, symbol) = STOCKS.iter().find(|(a, _)| *a == quote).ok_or_else(|| {
                    unsupported("暂不支持该内盘底池币；支持 OKB、wSPCXx、wNVDAx、wAAPLx")
                })?;
                let rows = self
                    .rpc
                    .multicall(
                        Chain::Xlayer,
                        vec![view(quote, decimalsCall {}, true)],
                        &tag,
                    )
                    .await?;
                let decimals = decode::<decimalsCall>(&rows[0])?;
                if decimals > 36 {
                    return Err(invalid());
                }
                json!({"address":quote.to_checksum(None),"symbol":symbol,"decimals":decimals,"native":false})
            }
        } else {
            json!({"address":Address::ZERO,"symbol":"OKB","decimals":18,"native":true})
        };
        let mut result = json!({"address":token.to_checksum(None),"symbol":symbol,"decimals":decimals,"platform":if stage.is_some(){"launchpad"}else{"external"},"external":stage!=Some(1),"block":block,"blockTag":tag,"pair":pair,"spender":if stage==Some(1){Some(LAUNCHPAD.to_checksum(None))}else{None}});
        if let Some(stage) = stage {
            result["launchpadStage"] = json!(stage)
        }
        if let Ok(tax) = decode::<taxConfigCall>(&rows[4]) {
            let parts = [tax.a, tax.b, tax.c, tax.d];
            let total: u32 = parts.iter().map(|v| *v as u32).sum();
            if total < 10000 {
                result["tokenTax"] = json!({"componentsBps":parts,"totalBps":total});
            }
        }
        Ok(result)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn never_route_transitional_or_inconsistent_registry_as_external() {
        let owner = address!("0000000000000000000000000000000000000001");
        assert_eq!(classify(U256::ZERO, Address::ZERO).unwrap(), None);
        assert_eq!(classify(U256::from(1), owner).unwrap(), Some(1));
        assert_eq!(classify(U256::from(3), owner).unwrap(), Some(3));
        for state in [0, 2, 4] {
            assert!(classify(U256::from(state), owner).is_err());
        }
        assert!(classify(U256::from(1), Address::ZERO).is_err());
    }
}
