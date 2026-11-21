use super::{
    abi::{decimalsCall, symbolCall},
    *,
};
use alloy_primitives::{U256, address, keccak256};
use alloy_sol_types::{SolValue, sol};
const PORTAL: Address = address!("b021be536808f551b31789422fd28a6c9c6e97da");
const CASH: Address = address!("3600000000000000000000000000000000000000");
const MANAGER: Address = address!("8366a39cc670b4001a1121b8f6a443a643e40951");
const PERMIT2: Address = address!("000000000022d473030f116ddee9f6b43ac78ba3");
const OKX: Address = address!("2b9899bc46bf0ee094225995f4bd496d42f261af");
sol! {
    function launches(address token) view returns(address creator,uint256 a,uint256 b,address c,address hook,address e,uint256 f,uint256 g,uint256 h,uint256 i,address quote);
    function bonded() view returns(bool);
    function token() view returns(address);
    function portal() view returns(address);
    function quoteAsset() view returns(address);
    function poolManager() view returns(address);
    function poolId() view returns(bytes32);
    function poolFee() view returns(uint24);
    function tickSpacing() view returns(int24);
    function buyTaxBps() view returns(uint256);
    function sellTaxBps() view returns(uint256);
    function currentSnipeTaxBps() view returns(uint256);
}
impl Platforms {
    pub(crate) async fn arc(&self, address: Address, block: u64) -> Result<Value> {
        if address == CASH {
            return Err(unsupported("请输入需要买卖的目标代币地址"));
        }
        let tag = format!("{block:#x}");
        let rows = self
            .rpc
            .multicall(
                Chain::Arc,
                vec![
                    view(address, symbolCall {}, true),
                    view(address, decimalsCall {}, true),
                    view(PORTAL, launchesCall { token: address }, true),
                ],
                &tag,
            )
            .await?;
        let (symbol, decimals) = metadata(&rows[0], &rows[1])?;
        let launch = decode::<launchesCall>(&rows[2])?;
        let mut result = json!({"address":address.to_checksum(None),"symbol":symbol,"decimals":decimals,"external":true,"launchpadStage":0,"blockTag":tag,"block":block,"platform":"external","identity":format!("{}:okx",address.to_checksum(None)),"market":{"token":address.to_checksum(None),"pairToken":Address::ZERO,"spender":OKX.to_checksum(None),"useOkx":true},"pair":{"address":Address::ZERO,"symbol":"USDC","decimals":18,"native":true}});
        if launch.creator.is_zero() && launch.hook.is_zero() {
            return Ok(result);
        }
        if launch.creator.is_zero() || launch.hook.is_zero() {
            return Err(invalid());
        }
        if launch.quote != CASH {
            return Err(unsupported("该代币不是 USDC 底池，不能按 USDC 金额交易"));
        }
        let hook = launch.hook;
        let rows = self
            .rpc
            .multicall(
                Chain::Arc,
                vec![
                    view(hook, bondedCall {}, true),
                    view(hook, tokenCall {}, true),
                    view(hook, portalCall {}, true),
                    view(hook, quoteAssetCall {}, true),
                    view(hook, poolManagerCall {}, true),
                    view(hook, poolIdCall {}, true),
                    view(hook, poolFeeCall {}, true),
                    view(hook, tickSpacingCall {}, true),
                    view(hook, buyTaxBpsCall {}, true),
                    view(hook, sellTaxBpsCall {}, true),
                    view(hook, currentSnipeTaxBpsCall {}, true),
                ],
                &tag,
            )
            .await?;
        if decode::<tokenCall>(&rows[1])? != address
            || decode::<portalCall>(&rows[2])? != PORTAL
            || decode::<quoteAssetCall>(&rows[3])? != CASH
            || decode::<poolManagerCall>(&rows[4])? != MANAGER
        {
            return Err(unsupported("平台代币与兑换池身份不符"));
        }
        let fee = decode::<poolFeeCall>(&rows[6])?;
        let tick = decode::<tickSpacingCall>(&rows[7])?;
        let (a, b) = if CASH < address {
            (CASH, address)
        } else {
            (address, CASH)
        };
        let id = keccak256((a, b, fee, tick, hook).abi_encode());
        if id != decode::<poolIdCall>(&rows[5])? {
            return Err(unsupported("兑换池参数不符"));
        }
        let buy = decode::<buyTaxBpsCall>(&rows[8])?;
        let sell = decode::<sellTaxBpsCall>(&rows[9])?;
        let snipe = decode::<currentSnipeTaxBpsCall>(&rows[10])?;
        if [buy, sell, snipe].iter().any(|v| *v > U256::from(10000)) {
            return Err(unsupported("平台税费返回异常"));
        }
        let external = decode::<bondedCall>(&rows[0])?;
        result["external"] = json!(external);
        result["launchpadStage"] = json!(if external { 3 } else { 1 });
        result["platform"] = json!("arc-portal");
        result["identity"] = json!(format!("{}:{id:#x}", address.to_checksum(None)));
        result["market"]["useOkx"] = json!(external);
        result["market"]["spender"] = json!(if external { OKX } else { PERMIT2 }.to_checksum(None));
        result["market"]["poolKey"] = json!({"currency0":a.to_checksum(None),"currency1":b.to_checksum(None),"fee":fee.to::<u32>(),"tickSpacing":tick.as_i32(),"hooks":hook.to_checksum(None)});
        result["tokenTax"] = json!({"buyBps":buy.to::<u32>(),"sellBps":sell.to::<u32>(),"snipeBps":snipe.to::<u32>(),"totalBps":(buy.max(sell)+snipe).to::<u32>()});
        Ok(result)
    }
}
#[cfg(test)]
#[path = "arc_tests.rs"]
mod tests;
