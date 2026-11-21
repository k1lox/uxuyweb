//! Validate executable UXUY quotes for the exact BSC wallet and order. Aggregate quotes are forecasts only.
use crate::{
    config::WBNB,
    error::{ApiError, Result},
    rpc::Rpc,
    uxuy::Uxuy,
    wallets::{allowanceCall, balanceOfCall, decimalsCall, getEthBalanceCall},
};
use alloy_primitives::{Address, B256, Bytes, U256, U512, hex};
use alloy_sol_types::{SolCall, SolEvent, sol};
use futures::{StreamExt, TryStreamExt, stream};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashSet;

#[path = "route/rapid_probe.rs"]
pub(crate) mod rapid_probe;

#[path = "inner.rs"]
mod inner;
pub(crate) use inner::{RouteApproval, RouteLeg, RouteStep};

sol! {
    function approve(address spender, uint256 amount) returns(bool);
    // UXUY IProtocol ABI verified on BSC at 0x7B458DBE4E7a693BE2e691DEdDff4607104f1266
    // and on Base at 0x020818b41B5D536570E5224626fbf95dA4D0B453. A deployment is
    // selected separately from this ABI by server configuration and startup code checks.
    struct SwapParams { address provider; address router; address[] path; uint256 minAmountOut; bytes data; }
    struct BridgeParams { address provider; address router; address tokenIn; uint256 chainIDOut; address tokenOut; uint256 minAmountOut; bytes data; }
    struct TradeParams {
        uint256 amountIn; SwapParams[] swaps; BridgeParams bridge; address recipient;
        address feeShareRecipient; uint256 extraFeeAmountIn; SwapParams[] extraFeeSwaps;
        uint256 deadline; uint256 orderId;
    }
    function trade(TradeParams params) payable returns (uint256 amountOut, uint256 bridgeTxnID);
    event Traded(address indexed sender, uint256 orderId, address indexed recipient, address indexed feeShareRecipient,
        address tokenIn, uint256 amountIn, uint256 chainIDOut, address tokenOut, uint256 amountOut, uint256 bridgeTxnID,
        address feeToken, uint256 amountFee, uint256 amountFeeShare, uint256 amountExtraFee);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Side {
    Buy,
    Sell,
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RouteRequest {
    #[serde(default)]
    pub inner_platform: Option<String>,
    pub side: Side,
    pub token: Address,
    #[serde(default)]
    pub settlement_token: Option<Address>,
    pub amount: String,
    pub wallet: Address,
    #[serde(default)]
    pub slippage_bps: Option<u16>,
    #[serde(default)]
    pub max_impact_percent: Option<f64>,
    #[serde(default)]
    pub forecast_only: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RoutePlan {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<RouteStep>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub legs: Vec<RouteLeg>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub approvals: Vec<RouteApproval>,
    pub source: &'static str,
    pub chain_id: u64,
    pub quote_scope: Option<&'static str>,
    pub side: Side,
    pub amount: String,
    pub token: Address,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settlement_token: Option<Address>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settlement_decimals: Option<u8>,
    pub wallet: Address,
    pub to: Address,
    pub spender: Address,
    pub data: Bytes,
    pub value: String,
    pub pools: Vec<Address>,
    pub dexes: Vec<String>,
    pub quote_out: String,
    pub min_out: String,
    pub slippage_ppm: u64,
    pub fee: String,
    pub price_impact_percent: f64,
    pub adverse_price_impact_percent: f64,
    /// Local quote freshness limit, not a claim about the opaque contract ABI.
    pub deadline: u64,
    pub gas_limit: u64,
    pub gas_estimated: bool,
    pub executed: bool,
    pub simulation: &'static str,
}

#[derive(Clone)]
pub struct Planner {
    pub platforms: Option<botai_platforms::Platforms>,
    pub uxuy: Uxuy,
    pub rpc: Option<Rpc>,
    pub router: Address,
    pub spender: Address,
    pub native: Address,
    pub max_impact_percent: f64,
    pub default_slippage_bps: u16,
    pub deadline_seconds: u64,
}

fn invalid_route() -> ApiError {
    ApiError::new(
        "UXUY_ROUTE_INVALID",
        "UXUY 无法获得合格报价",
        422,
        false,
    )
}
fn no_route() -> ApiError {
    ApiError::new(
        "UXUY_NO_ROUTE",
        "UXUY 无法获得合格报价",
        422,
        false,
    )
}
fn simulation_failed() -> ApiError {
    ApiError::new(
        "UXUY_SIMULATION_FAILED",
        "UXUY 路由未通过本次钱包的执行模拟",
        422,
        false,
    )
}

pub fn parse_amount(s: &str) -> Result<U256> {
    decimal_word(s)
        .filter(|v| !v.is_zero())
        .ok_or_else(|| ApiError::invalid("金额必须是非零整数最小单位"))
}
fn decimal_word(s: &str) -> Option<U256> {
    if s.is_empty() || s.len() > 78 || !s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    U256::from_str_radix(s, 10).ok()
}
fn word(v: &Value) -> Result<U256> {
    match v {
        Value::String(s) => decimal_word(s),
        Value::Number(n) => decimal_word(&n.to_string()),
        _ => None,
    }
    .ok_or_else(invalid_route)
}
fn address(v: &Value) -> Result<Address> {
    v.as_str()
        .and_then(|s| s.parse().ok())
        .ok_or_else(invalid_route)
}
fn units(amount: U256, decimals: u8) -> String {
    let digits = amount.to_string();
    let n = usize::from(decimals);
    if n == 0 {
        return digits;
    }
    let mut s = if digits.len() > n {
        format!(
            "{}.{}",
            &digits[..digits.len() - n],
            &digits[digits.len() - n..]
        )
    } else {
        format!("0.{}{}", "0".repeat(n - digits.len()), digits)
    };
    while s.ends_with('0') {
        s.pop();
    }
    if s.ends_with('.') {
        s.pop();
    }
    s
}
fn uint_return(value: &Value) -> Result<U256> {
    let bytes: Bytes = value
        .as_str()
        .ok_or_else(invalid_route)?
        .parse()
        .map_err(|_| invalid_route())?;
    if bytes.len() != 32 {
        return Err(ApiError::unavailable("节点未返回有效的代币属性"));
    }
    Ok(U256::from_be_slice(&bytes))
}

impl Planner {
    fn rpc(&self) -> Result<&Rpc> {
        self.rpc
            .as_ref()
            .ok_or_else(|| ApiError::unavailable("缺少用于验证 UXUY 路由的 BSC 节点"))
    }
    fn validate(&self, req: &RouteRequest) -> Result<(U256, u64, f64)> {
        if req.inner_platform.is_none() && (self.router.is_zero() || self.spender.is_zero()) {
            return Err(ApiError::new(
                "UXUY_NOT_CONFIGURED",
                "请配置受信任的 UXUY 交易及授权合约",
                503,
                false,
            ));
        }
        if req.token.is_zero()
            || req.token == WBNB
            || req.token == self.native
            || req.wallet.is_zero()
        {
            return Err(ApiError::invalid("钱包或交易币种无效"));
        }
        if let Some(asset) = req.settlement_token {
            if req.side != Side::Sell || asset.is_zero() || asset == self.native || asset == req.token {
                return Err(ApiError::invalid("清仓到账币种无效"));
            }
        }
        let bps = req.slippage_bps.unwrap_or(self.default_slippage_bps);
        if bps >= 10_000 {
            return Err(ApiError::invalid("滑点必须小于 100%"));
        }
        let cap = req.max_impact_percent.unwrap_or(self.max_impact_percent);
        if !(0.0..=100.0).contains(&cap) {
            return Err(ApiError::invalid("价格影响上限无效"));
        }
        Ok((parse_amount(&req.amount)?, u64::from(bps) * 100, cap))
    }
    async fn precision(&self, token: Address) -> Result<u8> {
        let data = Bytes::from(decimalsCall {}.abi_encode());
        let result = self
            .rpc()?
            .call("eth_call", json!([{"to":token,"data":data},"latest"]))
            .await?;
        u8::try_from(uint_return(&result)?).map_err(|_| ApiError::unavailable("代币精度无效"))
    }
    async fn precisions(&self, req: &RouteRequest) -> Result<(u8, u8)> {
        let token = self.precision(req.token).await?;
        let settlement = match req.settlement_token {
            Some(asset) => self.precision(asset).await?,
            None => 18,
        };
        Ok((token, settlement))
    }
    async fn allowance(&self, req: &RouteRequest) -> Result<U256> {
        let data = Bytes::from(
            allowanceCall {
                owner: req.wallet,
                spender: self.spender,
            }
            .abi_encode(),
        );
        let result = self
            .rpc()?
            .call("eth_call", json!([{"to":req.token,"data":data},"latest"]))
            .await?;
        uint_return(&result)
    }
    pub async fn plan(&self, req: &RouteRequest, now: u64) -> Result<RoutePlan> {
        self.validate(req)?;
        if req.inner_platform.is_some() {
            let market = self.inner_market(req).await?;
            return self.compose_inner(req, &market, now, false, false).await;
        }
        let decimals = self.precisions(req).await?;
        self.quote_plan(req, now, decimals, false).await
    }
    async fn quote_plan(
        &self,
        req: &RouteRequest,
        now: u64,
        precisions: (u8, u8),
        group: bool,
    ) -> Result<RoutePlan> {
        let (amount, slippage, cap) = self.validate(req)?;
        let forecast = group || req.forecast_only;
        let preapproval =
            !forecast && req.side == Side::Sell && self.allowance(req).await? < amount;
        let with_tx = !forecast && !preapproval;
        let (order, rows) = self.quote_rows(req, amount, slippage, precisions, with_tx).await?;
        let mut error = no_route();
        for row in rows {
            let parsed = self.parse_row(
                req,
                &row,
                &order,
                amount,
                slippage,
                cap,
                precisions,
                now,
                group,
                preapproval,
            );
            match parsed {
                Ok(mut plan) => {
                    if !forecast {
                        match self.simulate_wallet_swap(&plan, amount, preapproval).await {
                            Ok(gas) => {
                                plan.gas_limit = gas;
                                plan.gas_estimated = true;
                                plan.executed = true;
                            }
                            Err(e) => {
                                error = e;
                                continue;
                            }
                        }
                    }
                    return Ok(plan);
                }
                Err(e) => error = e,
            }
        }
        Err(error)
    }
    async fn quote_rows(&self, req: &RouteRequest, amount: U256, slippage: u64,
        precisions: (u8, u8), with_tx: bool) -> Result<(String, Vec<Value>)> {
        let (input, output, decimals) = match req.side {
            Side::Buy => (self.native, req.token, 18),
            Side::Sell => (req.token, req.settlement_token.unwrap_or(self.native), precisions.0),
        };
        let order = Uxuy::order_id()?;
        let params = json!({
            "sender":req.wallet, "receiver":req.wallet,
            "tokenIn":input, "tokenOut":output,
            "amountIn":units(amount,decimals), "decimals":decimals,
            "slippage":slippage, "size":3, "noFee":true,
            "withTx":with_tx, "orderId":order,
        });
        Ok((order, self.uxuy.quote(params).await?))
    }
    fn same_asset(&self, actual: Address, requested: Address) -> bool {
        actual == requested
            || ((requested == self.native || requested == WBNB)
                && (actual == self.native || actual == WBNB))
    }
    #[allow(clippy::too_many_arguments)]
    fn parse_row(
        &self,
        req: &RouteRequest,
        row: &Value,
        order: &str,
        amount: U256,
        max_slip: u64,
        cap: f64,
        precisions: (u8, u8),
        now: u64,
        group: bool,
        preapproval: bool,
    ) -> Result<RoutePlan> {
        if row
            .get("orderId")
            .is_some_and(|id| id.as_str() != Some(order))
            || row.get("error").is_some_and(|v| !v.is_null() && v != "")
        {
            return Err(invalid_route());
        }
        let is_buy = req.side == Side::Buy;
        let (input, output) = if is_buy {
            (self.native, req.token)
        } else {
            (req.token, req.settlement_token.unwrap_or(self.native))
        };
        let path = row["paths"]
            .as_array()
            .filter(|p| (2..=17).contains(&p.len()))
            .ok_or_else(invalid_route)?;
        let mut tokens = Vec::new();
        for hop in path {
            if hop["chainId"].as_u64() != Some(56) {
                return Err(invalid_route());
            }
            let addr = address(&hop["token"])?;
            if tokens.contains(&addr) {
                return Err(invalid_route());
            }
            tokens.push(addr);
        }
        let last = path.len() - 1;
        if !self.same_asset(tokens[0], input)
            || !(if req.settlement_token.is_some() {
                tokens[last] == output
            } else {
                self.same_asset(tokens[last], output)
            })
            || path[0]["decimals"].as_u64()
                != Some(if is_buy {
                    18
                } else {
                    u64::from(precisions.0)
                })
            || path[last]["decimals"].as_u64()
                != Some(if is_buy {
                    u64::from(precisions.0)
                } else {
                    u64::from(precisions.1)
                })
        {
            return Err(invalid_route());
        }
        let pairs = row["pairs"]
            .as_array()
            .filter(|v| v.len() == last)
            .ok_or_else(invalid_route)?;
        let mut pools = Vec::new();
        let mut dexes = Vec::new();
        let mut impact_ppm = 0u64;
        let mut available = amount;
        for (index, pair) in pairs.iter().enumerate() {
            if pair["chainId"].as_u64() != Some(56)
                || !self.same_asset(address(&pair["tokenIn"])?, tokens[index])
                || !self.same_asset(address(&pair["tokenOut"])?, tokens[index + 1])
            {
                return Err(invalid_route());
            }
            let branches = pair["pools"]
                .as_array()
                .filter(|v| !v.is_empty() && v.len() <= 32)
                .ok_or_else(invalid_route)?;
            let mut input_sum = U256::ZERO;
            let mut output_sum = U256::ZERO;
            let mut worst = 0;
            for pool in branches {
                let pool_id = pool["pool"].as_str().ok_or_else(invalid_route)?;
                let protocol = pool["protocol"]
                    .as_str()
                    .filter(|s| !s.is_empty() && s.len() <= 80)
                    .ok_or_else(invalid_route)?;
                let addr = match pool_id.parse::<Address>() {
                    Ok(a) => a,
                    Err(_) if pool_id.parse::<alloy_primitives::B256>().is_ok() => {
                        address(&pool["factory"])?
                    }
                    _ => return Err(invalid_route()),
                };
                if addr.is_zero() {
                    return Err(invalid_route());
                }
                pools.push(addr);
                if !dexes.iter().any(|s| s == protocol) {
                    dexes.push(protocol.to_owned());
                }
                let impact = pool["price_impact"]
                    .as_i64()
                    .map(i64::unsigned_abs)
                    .filter(|v| *v <= 1_000_000)
                    .ok_or_else(|| {
                        ApiError::new(
                            "PRICE_IMPACT_UNKNOWN",
                            "UXUY 未返回可核验的池价格影响",
                            422,
                            false,
                        )
                    })?;
                worst = worst.max(impact);
                input_sum = input_sum
                    .checked_add(word(&pool["in"])?)
                    .ok_or_else(invalid_route)?;
                output_sum = output_sum
                    .checked_add(word(&pool["amount"])?)
                    .ok_or_else(invalid_route)?;
            }
            if input_sum.is_zero()
                || output_sum.is_zero()
                || input_sum > available
                || (index == 0 && input_sum != amount)
            {
                return Err(invalid_route());
            }
            available = output_sum;
            if index == last - 1 && output_sum < word(&row["amount"])? {
                return Err(invalid_route());
            }
            // A conservative upper bound: worst branch per hop, summed across sequential hops.
            impact_ppm += worst;
        }
        let impact = (impact_ppm as f64) / 10_000.;
        if impact > cap {
            return Err(ApiError::new(
                if group {
                    "BUNDLE_IMPACT_EXCEEDED"
                } else {
                    "LIQUIDITY_INSUFFICIENT"
                },
                format!("UXUY 路径价格影响上限 {impact:.2}% 超过本次限制 {cap:.2}%"),
                422,
                false,
            ));
        }
        let quote = word(&row["amount"])?;
        let min_out = word(&row["minAmount"])?;
        let slippage = row["slippage"]
            .as_u64()
            .filter(|v| *v <= max_slip)
            .ok_or_else(invalid_route)?;
        let floor = U512::from(quote) * U512::from(1_000_000 - slippage) / U512::from(1_000_000);
        if min_out.is_zero() || min_out > quote || U512::from(min_out) < floor {
            return Err(invalid_route());
        }
        let forecast = group || req.forecast_only;
        let value = if is_buy { amount } else { U256::ZERO };
        let mut deadline = now.saturating_add(self.deadline_seconds);
        // Live responses can omit the JSON orderId. Even a forecast must then
        // bind the call to this order before exposing its price or risk estimates.
        let validate_call = !forecast || row.get("orderId").is_none() || !row["calldata"].is_null();
        let data = if validate_call {
            let call = &row["calldata"];
            if address(&call["to"])? != self.router || word(&call["value"])? != value {
                return Err(invalid_route());
            }
            if !call["error"].as_str().is_some_and(str::is_empty)
                || call["executed"].as_bool() != Some(!forecast && !preapproval)
            {
                return Err(simulation_failed());
            }
            let encoded = call["data"].as_str().ok_or_else(invalid_route)?;
            let raw = encoded.strip_prefix("0x").unwrap_or(encoded);
            if raw.len() < 8 || raw.len() > 256 * 1024 || raw.len() % 2 != 0 {
                return Err(invalid_route());
            }
            let bytes = hex::decode(raw).map_err(|_| invalid_route())?;
            if bytes[..4] != tradeCall::SELECTOR {
                return Err(ApiError::new(
                    "UXUY_METHOD_UNSUPPORTED",
                    "UXUY 返回了未配置的兑换方法",
                    422,
                    false,
                ));
            }
            let trade = tradeCall::abi_decode_validate(&bytes).map_err(|_| invalid_route())?;
            if trade.abi_encode() != bytes {
                return Err(invalid_route());
            }
            let params = trade.params;
            let swaps = &params.swaps;
            if Some(params.orderId) != decimal_word(order)
                || params.amountIn != amount
                || params.recipient != req.wallet
                || !params.bridge.provider.is_zero()
                || !params.feeShareRecipient.is_zero()
                || !params.extraFeeAmountIn.is_zero()
                || !params.extraFeeSwaps.is_empty()
                || swaps.is_empty()
                || swaps.len() > 32
            {
                return Err(invalid_route());
            }
            let actual_native = Address::ZERO; // IProtocol SafeNativeAsset uses address(0) inside calldata.
            let (raw_input, raw_output) = if is_buy {
                (actual_native, req.token)
            } else {
                (req.token, req.settlement_token.unwrap_or(actual_native))
            };
            let mut asset = raw_input;
            for swap in swaps {
                if swap.provider.is_zero()
                    || swap.path.len() < 2
                    || swap.path.first() != Some(&asset)
                {
                    return Err(invalid_route());
                }
                asset = *swap.path.last().ok_or_else(invalid_route)?;
            }
            if asset != raw_output || swaps.last().ok_or_else(invalid_route)?.minAmountOut < min_out
            {
                return Err(invalid_route());
            }
            if !params.deadline.is_zero() {
                let contract_deadline = u64::try_from(params.deadline).unwrap_or(u64::MAX);
                if contract_deadline <= now {
                    return Err(invalid_route());
                }
                deadline = deadline.min(contract_deadline);
            }
            if forecast { Bytes::new() } else { bytes.into() }
        } else {
            Bytes::new()
        };
        Ok(RoutePlan {
            steps: Vec::new(),
            legs: Vec::new(),
            approvals: Vec::new(),
            source: "uxuy",
            chain_id: 56,
            quote_scope: Some(if group { "bundle" } else { "wallet" }),
            side: req.side,
            wallet: req.wallet,
            token: req.token,
            settlement_token: req.settlement_token,
            settlement_decimals: req.settlement_token.map(|_| precisions.1),
            amount: amount.to_string(),
            to: self.router,
            spender: self.spender,
            value: value.to_string(),
            data,
            pools,
            dexes,
            quote_out: quote.to_string(),
            min_out: min_out.to_string(),
            fee: "0".into(),
            slippage_ppm: slippage,
            price_impact_percent: -impact,
            adverse_price_impact_percent: impact,
            deadline,
            gas_limit: 0,
            gas_estimated: false,
            executed: false,
            simulation: if forecast {
                "forecast"
            } else if preapproval {
                "approve_then_swap"
            } else {
                "uxuy"
            },
        })
    }

    async fn simulate_wallet_swap(
        &self,
        plan: &RoutePlan,
        amount: U256,
        preapproval: bool,
    ) -> Result<u64> {
        let calls = Self::wallet_swap_calls(plan, amount, preapproval);
        let response = self.simulate_calls(calls).await?;
        Self::verify_swap_results(plan, amount, preapproval, &response)
    }

    fn wallet_swap_calls(plan: &RoutePlan, amount: U256, preapproval: bool) -> Vec<Value> {
        let value = if plan.side == Side::Buy {
            amount
        } else {
            U256::ZERO
        };
        let call =
            json!({"from":plan.wallet,"to":plan.to,"data":plan.data,"value":format!("{value:#x}")});
        // Read both real wallet balances around the exact call sequence at a single block.
        // Zero simulated gas price isolates the native swap amount from transaction gas costs.
        let settlement_balance = match plan.settlement_token {
            Some(asset) => json!({"from":Address::ZERO, "to":asset, "data":Bytes::from(balanceOfCall{owner:plan.wallet}.abi_encode())}),
            None => json!({"from":Address::ZERO, "to":crate::config::MULTICALL3, "data":Bytes::from(getEthBalanceCall{addr:plan.wallet}.abi_encode())}),
        };
        let token_balance = json!({
            "from": Address::ZERO, "to": plan.token,
            "data": Bytes::from(balanceOfCall{owner:plan.wallet}.abi_encode()),
        });
        let mut calls = vec![settlement_balance.clone(), token_balance.clone()];
        if preapproval {
            let approval = Bytes::from(
                approveCall {
                    spender: plan.spender,
                    amount,
                }
                .abi_encode(),
            );
            calls.push(json!({"from":plan.wallet,"to":plan.token,"data":approval}));
        }
        calls.extend([call, settlement_balance, token_balance]);
        calls
    }

    pub(crate) async fn simulate_calls(&self, calls: Vec<Value>) -> Result<Vec<Value>> {
        self.simulate_calls_at(calls, json!("latest")).await
    }

    async fn simulate_calls_at(&self, calls: Vec<Value>, block: Value) -> Result<Vec<Value>> {
        let count = calls.len();
        let params = json!([{
            "blockStateCalls":[{"blockOverrides":{"baseFeePerGas":"0x0"},"calls":calls}],
            "validation":false,
        },block]);
        let mut response = self
            .rpc()?
            .call("eth_simulateV1", params)
            .await
            .map_err(|_| {
                ApiError::new(
                    "UXUY_SIMULATION_UNAVAILABLE",
                    "BSC 节点未能模拟交易并回查本次钱包余额",
                    502,
                    true,
                )
            })?;
        let blocks = response
            .as_array_mut()
            .filter(|rows| rows.len() == 1)
            .ok_or_else(simulation_failed)?;
        match blocks[0]["calls"].take() {
            Value::Array(rows) if rows.len() == count => Ok(rows),
            _ => Err(simulation_failed()),
        }
    }

    fn verify_swap_results(
        plan: &RoutePlan,
        amount: U256,
        preapproval: bool,
        results: &[Value],
    ) -> Result<u64> {
        let swap_idx = if preapproval { 3 } else { 2 };
        if results.len() != swap_idx + 3 {
            return Err(simulation_failed());
        }
        if results
            .iter()
            .any(|c| !c["error"].is_null() || crate::rpc::hex_u64(&c["status"]).ok() != Some(1))
        {
            return Err(simulation_failed());
        }
        if preapproval
            && results[2]["returnData"] != "0x"
            && uint_return(&results[2]["returnData"]).ok() != Some(U256::ONE)
        {
            return Err(simulation_failed());
        }
        let balance = |index: usize| {
            uint_return(&results[index]["returnData"]).map_err(|_| simulation_failed())
        };
        let (payment_before, token_before, payment_after, token_after) = (
            balance(0)?,
            balance(1)?,
            balance(swap_idx + 1)?,
            balance(swap_idx + 2)?,
        );
        let (spent, received) = match plan.side {
            Side::Buy => (
                payment_before.checked_sub(payment_after),
                token_after.checked_sub(token_before),
            ),
            Side::Sell => (
                token_before.checked_sub(token_after),
                payment_after.checked_sub(payment_before),
            ),
        };
        let minimum = parse_amount(&plan.min_out)?;
        // Native buys send the full quoted value, but the call can return BNB to the wallet.
        // The protocol emits the requested amountIn. Wallet balances measure the net debit.
        let valid_debit = match plan.side {
            Side::Buy => spent.is_some_and(|net| !net.is_zero() && net <= amount),
            Side::Sell => spent == Some(amount),
        };
        if !valid_debit || received.is_none_or(|out| out < minimum) {
            return Err(simulation_failed());
        }
        let (raw_input, raw_output) = if plan.side == Side::Buy {
            (Address::ZERO, plan.token)
        } else {
            (plan.token, plan.settlement_token.unwrap_or(Address::ZERO))
        };
        Self::verify_traded(&results[swap_idx], plan.to, plan.wallet, raw_input, raw_output, amount, minimum)?;
        let gas =
            crate::rpc::hex_u64(&results[swap_idx]["gasUsed"]).map_err(|_| simulation_failed())?;
        if gas < 21_000 {
            return Err(simulation_failed());
        }
        gas.checked_add(gas / 2).ok_or_else(simulation_failed)
    }

    fn verify_traded(result:&Value,target:Address,wallet:Address,raw_input:Address,raw_output:Address,amount:U256,minimum:U256)->Result<()> {
        // IProtocol.Traded reports the actual platform, fee-share and extra-fee charges.
        // An upstream noFee flag alone does not establish that its execution contract waived them.
        let logs = result["logs"]
            .as_array()
            .ok_or_else(simulation_failed)?;
        let mut events = logs.iter().filter(|l| {
            address(&l["address"]).ok() == Some(target)
                && l["topics"]
                    .get(0)
                    .and_then(Value::as_str)
                    .and_then(|s| s.parse::<B256>().ok())
                    == Some(Traded::SIGNATURE_HASH)
        });
        let event = events.next().ok_or_else(simulation_failed)?;
        if events.next().is_some() {
            return Err(simulation_failed());
        }
        let topics: Vec<B256> =
            serde_json::from_value(event["topics"].clone()).map_err(|_| simulation_failed())?;
        let event_data: Bytes =
            serde_json::from_value(event["data"].clone()).map_err(|_| simulation_failed())?;
        let event = Traded::decode_raw_log_validate(topics, &event_data)
            .map_err(|_| simulation_failed())?;
        if event.sender != wallet
            || event.recipient != wallet
            || event.tokenIn != raw_input
            || event.tokenOut != raw_output
            || event.amountIn != amount
            || event.amountOut < minimum
            || !event.feeShareRecipient.is_zero()
            || !event.amountFee.is_zero()
            || !event.amountFeeShare.is_zero()
            || !event.amountExtraFee.is_zero()
            || !event.bridgeTxnID.is_zero()
        {
            return Err(simulation_failed());
        }
        Ok(())
    }

    /// Reuse each wallet's exact calls in execution order. Earlier swaps may move the same pool
    /// enough for a later wallet to revert or receive less than its quoted minimum.
    async fn verify_bundle_order(&self, plans: &mut [RoutePlan]) -> Result<()> {
        if plans.len() < 2 {
            return Ok(());
        }
        let mut calls = Vec::new();
        let mut ranges = Vec::with_capacity(plans.len());
        for plan in plans.iter() {
            let amount = parse_amount(&plan.amount)?;
            let preapproval = plan.simulation == "approve_then_swap";
            let start = calls.len();
            calls.extend(Self::wallet_swap_calls(plan, amount, preapproval));
            ranges.push((start..calls.len(), amount, preapproval));
        }
        let results = self.simulate_calls(calls).await?;
        for (plan, (range, amount, preapproval)) in plans.iter_mut().zip(ranges) {
            let gas = Self::verify_swap_results(plan, amount, preapproval, &results[range])
                .map_err(|_| {
                    ApiError::new(
                        "UXUY_BUNDLE_SIMULATION_FAILED",
                        format!(
                            "钱包 {:#x} 的兑换未通过整组顺序模拟，请重新报价",
                            plan.wallet
                        ),
                        422,
                        false,
                    )
                })?;
            plan.gas_limit = plan.gas_limit.max(gas);
        }
        Ok(())
    }

    pub async fn plan_bundle(
        &self,
        requests: &[RouteRequest],
        now: u64,
    ) -> Result<(RoutePlan, Vec<RoutePlan>)> {
        let first = requests
            .first()
            .filter(|_| requests.len() <= crate::submit::MAX_BUNDLE)
            .ok_or_else(|| ApiError::invalid("捆绑钱包数量无效"))?;
        let mut wallets = HashSet::new();
        let mut total = U256::ZERO;
        for req in requests {
            if req.inner_platform != first.inner_platform
                || req.token != first.token
                || req.settlement_token != first.settlement_token
                || req.side != first.side
                || req.forecast_only != first.forecast_only
                || req.max_impact_percent != first.max_impact_percent
                || req.slippage_bps != first.slippage_bps
                || !wallets.insert(req.wallet)
            {
                return Err(ApiError::invalid(
                    "捆绑的币种、方向、风险设置必须一致且钱包不得重复",
                ));
            }
            total = total
                .checked_add(self.validate(req)?.0)
                .ok_or_else(|| ApiError::invalid("捆绑总金额过大"))?;
        }
        let mut aggregate = first.clone();
        aggregate.amount = total.to_string();
        aggregate.forecast_only = true;
        if first.inner_platform.is_some() {
            let market = self.inner_market(first).await?;
            let group = self.compose_inner(&aggregate, &market, now, true, false).await?;
            if first.forecast_only {
                return Ok((group, Vec::new()));
            }
            let market_ref = &market;
            let mut plans: Vec<_> = stream::iter(requests.to_vec())
                .map(|req| async move { self.compose_inner(&req, market_ref, now, false, true).await })
                .buffered(8).try_collect().await?;
            self.reprice_inner_bundle(requests, &market, &mut plans, now)
                .await?;
            return Ok((group, plans));
        }
        let decimals = self.precisions(first).await?;
        let group = self.quote_plan(&aggregate, now, decimals, true).await?;
        if first.forecast_only {
            return Ok((group, Vec::new()));
        }
        let mut rows: Vec<RoutePlan> = stream::iter(requests.to_vec())
            .map(|req| async move { self.quote_plan(&req, now, decimals, false).await })
            .buffered(8)
            .try_collect()
            .await?;
        self.verify_bundle_order(&mut rows).await?;
        Ok((group, rows))
    }
}

#[cfg(test)]
#[path = "tests/uxuy_route.rs"]
mod tests;
