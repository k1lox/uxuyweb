//! Probe the first buy and sell against the same simulated wallet and block.
//! The response contains measurements only. No calldata is issued for submission.
use super::*;
use axum::{Json, extract::State};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct RapidCheck {
    pub(super) buy: RouteRequest,
    pub(super) sell_value: String,
    pub(super) percent_sell: bool,
    #[serde(default = "one")]
    pub(super) buy_orders: u16,
    #[serde(default = "one")]
    pub(super) sell_orders: u16,
}

fn one() -> u16 {
    1
}

fn sell_amount(balance: U256, value: U256, percent: bool) -> Result<U256> {
    let result = if percent {
        if value > U256::from(10_000) {
            return Err(ApiError::invalid("卖出比例超过 100%"));
        }
        let product = U512::from(balance) * U512::from(value) / U512::from(10_000);
        U256::from_limbs_slice(&product.as_limbs()[..4])
    } else {
        value
    };
    if result.is_zero() || result > balance {
        return Err(ApiError::invalid("首笔卖出超过买入后持仓或低于最小单位"));
    }
    Ok(result)
}

fn scheduled_sales(
    mut balance: U256,
    received: U256,
    value: U256,
    percent: bool,
    orders: u16,
    four: bool,
) -> Result<U256> {
    let mut total = U256::ZERO;
    for _ in 0..orders {
        balance = balance
            .checked_add(received)
            .ok_or_else(simulation_failed)?;
        let mut sell = sell_amount(balance, value, percent)?;
        if four {
            let lot = U256::from(1_000_000_000);
            sell = sell / lot * lot;
        }
        balance = balance.checked_sub(sell).ok_or_else(simulation_failed)?;
        total = total.checked_add(sell).ok_or_else(simulation_failed)?;
    }
    Ok(total)
}

fn balance(row: &Value) -> Result<U256> {
    if !row["error"].is_null() || crate::rpc::hex_u64(&row["status"]).ok() != Some(1) {
        return Err(simulation_failed());
    }
    uint_return(&row["returnData"])
}

async fn candidate(
    planner: &Planner,
    req: &RouteRequest,
    market: Option<&Value>,
    now: u64,
) -> Result<Vec<RoutePlan>> {
    if let Some(market) = market {
        return Ok(vec![
            planner.compose_inner(req, market, now, false, true).await?,
        ]);
    }
    if req.side == Side::Buy {
        return Ok(vec![planner.plan(req, now).await?]);
    }
    let (amount, slip, cap) = planner.validate(req)?;
    let decimals = planner.precisions(req).await?;
    let (order, rows) = planner
        .quote_rows(req, amount, slip, decimals, false)
        .await?;
    let mut plans = Vec::new();
    let mut error = no_route();
    for row in rows {
        match planner.parse_row(
            req, &row, &order, amount, slip, cap, decimals, now, false, true,
        ) {
            Ok(plan) => plans.push(plan),
            Err(e) => error = e,
        }
    }
    if plans.is_empty() {
        Err(error)
    } else {
        Ok(plans)
    }
}

fn calls(plan: &RoutePlan, amount: U256, approve: bool, inner: bool) -> Result<Vec<Value>> {
    if inner {
        Planner::inner_calls(plan)
    } else {
        Ok(Planner::wallet_swap_calls(plan, amount, approve))
    }
}

fn verify(
    plan: &mut RoutePlan,
    amount: U256,
    approve: bool,
    inner: bool,
    rows: &[Value],
) -> Result<u64> {
    let gas = if inner {
        Planner::verify_inner_results(plan, rows)?;
        plan.gas_limit
    } else {
        Planner::verify_swap_results(plan, amount, approve, rows)?
    };
    if gas < 21_000 || gas > 30_000_000 {
        return Err(simulation_failed());
    }
    Ok(gas)
}

pub(crate) async fn check(
    State(app): State<crate::App>,
    Json(check): Json<RapidCheck>,
) -> Result<Json<Value>> {
    probe(&app.planner, check, crate::now(), Some(&app.issued)).await
}

pub(super) async fn probe(
    planner: &Planner,
    check: RapidCheck,
    now: u64,
    issued: Option<&crate::issued::IssuedRoutes>,
) -> Result<Json<Value>> {
    if check.sell_orders == 0
        || u32::from(check.buy_orders) + u32::from(check.sell_orders) > 10_000
        || !(check.buy_orders == check.sell_orders
            || check.buy_orders == check.sell_orders.saturating_add(1))
    {
        return Err(ApiError::invalid("同一钱包的快速买卖笔数无效"));
    }
    let buy = check.buy;
    if buy.side != Side::Buy || buy.forecast_only || buy.settlement_token.is_some() {
        return Err(ApiError::invalid("快速组需要实钱包和首笔买单"));
    }
    let (buy_amount, _, _) = planner.validate(&buy)?;
    let sell_value = parse_amount(&check.sell_value)?;
    let market = if buy.inner_platform.is_some() {
        Some(planner.inner_market(&buy).await?)
    } else {
        None
    };
    let inner = market.is_some();
    let block = match market.as_ref() {
        Some(m) => json!(format!(
            "{:#x}",
            m["block"].as_u64().ok_or_else(simulation_failed)?
        )),
        None => planner.rpc()?.call("eth_blockNumber", json!([])).await?,
    };
    crate::rpc::hex_u64(&block)?;
    let token_balance = json!({"from":Address::ZERO, "to":buy.token,
        "data":Bytes::from(balanceOfCall{owner:buy.wallet}.abi_encode())});
    let mut first = candidate(planner, &buy, market.as_ref(), now)
        .await?
        .remove(0);
    let mut first_calls = vec![token_balance.clone()];
    first_calls.extend(calls(&first, buy_amount, false, inner)?);
    first_calls.push(token_balance);
    let split = first_calls.len();
    let result = planner
        .simulate_calls_at(first_calls.clone(), block.clone())
        .await?;
    verify(&mut first, buy_amount, false, inner, &result[1..split - 1])?;
    let start = balance(&result[0])?;
    let after = balance(&result[split - 1])?;
    let received = after
        .checked_sub(start)
        .filter(|v| !v.is_zero())
        .ok_or_else(simulation_failed)?;
    let mut sell_amount = sell_amount(after, sell_value, check.percent_sell)?;
    if buy.inner_platform.as_deref() == Some("four") {
        let lot = U256::from(1_000_000_000);
        sell_amount = sell_amount / lot * lot;
        if sell_amount.is_zero() {
            return Err(ApiError::invalid("Four.meme 首卖不足最小卖出单位"));
        }
    }
    let sell = RouteRequest {
        side: Side::Sell,
        amount: sell_amount.to_string(),
        ..buy
    };
    let held = if inner {
        U256::ZERO
    } else {
        planner.allowance(&sell).await?
    };
    let approve = !inner && held < sell_amount;
    let reset = approve && !held.is_zero();
    let sales = match market.as_ref() {
        Some(venue) => vec![
            planner
                .compose_inner_after(&sell, venue, now, &first_calls)
                .await?,
        ],
        None => candidate(planner, &sell, None, now).await?,
    };
    let mut error = simulation_failed();
    for mut sale in sales {
        let mut sequence = first_calls.clone();
        if reset {
            sequence.push(
                json!({"from":sell.wallet,"to":sell.token,"data":Bytes::from(
                approveCall{spender:sale.spender,amount:U256::ZERO}.abi_encode())}),
            );
        }
        sequence.extend(calls(&sale, sell_amount, approve, inner)?);
        let results = planner.simulate_calls_at(sequence, block.clone()).await?;
        let buy_gas = verify(&mut first, buy_amount, false, inner, &results[1..split - 1])?;
        if balance(&results[0])? != start || balance(&results[split - 1])? != after {
            return Err(simulation_failed());
        }
        if reset {
            let row = &results[split];
            if !row["error"].is_null()
                || crate::rpc::hex_u64(&row["status"]).ok() != Some(1)
                || (row["returnData"] != "0x"
                    && uint_return(&row["returnData"]).ok() != Some(U256::ONE))
            {
                return Err(simulation_failed());
            }
        }
        match verify(
            &mut sale,
            sell_amount,
            approve,
            inner,
            &results[split + usize::from(reset)..],
        ) {
            Ok(sell_gas) => {
                if let Some(issued) = issued.filter(|_| inner) {
                    // A dedicated allowance proof for the selected schedule. No
                    // action, calldata or transaction authorization is issued.
                    let mut budget = sale.clone();
                    let total = scheduled_sales(
                        start,
                        received,
                        sell_value,
                        check.percent_sell,
                        check.sell_orders,
                        sell.inner_platform.as_deref() == Some("four"),
                    )?;
                    let denom = U512::from(sell_amount) * U512::from(check.sell_orders);
                    for grant in &mut budget.approvals {
                        let n = U512::from(parse_amount(&grant.amount)?) * U512::from(total);
                        let avg = n / denom + U512::from(u8::from(!(n % denom).is_zero()));
                        if avg.as_limbs()[4..].iter().any(|&n| n != 0) {
                            return Err(simulation_failed());
                        }
                        grant.amount = U256::from_limbs_slice(&avg.as_limbs()[..4]).to_string();
                    }
                    issued.record_inner_grants(&first)?;
                    issued.record_inner_grants(&budget)?;
                }
                return Ok(Json(
                    json!({"ok":true, "wallet":sell.wallet, "token":sell.token,
                "before":start.to_string(), "received":received.to_string(), "sellAmount":sell_amount.to_string(),
                "buyGas":buy_gas,"sellGas":sell_gas,"buyApprovals":first.approvals,"sellApprovals":sale.approvals}),
                ));
            }
            Err(e) => error = e,
        }
    }
    Err(error)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rapid_allowance_counts_cumulative_holdings_and_each_four_lot() {
        let u = U256::from;
        assert_eq!(
            scheduled_sales(u(0u64), u(100), u(5000), true, 3, false).unwrap(),
            u(212)
        );
        assert_eq!(
            scheduled_sales(u(0u64), u(3_000_000_000), u(5000), true, 3, true).unwrap(),
            u(6_000_000_000)
        );
        assert!(scheduled_sales(U256::MAX, U256::ONE, u(5000), true, 2, false).is_err());
    }
    #[test]
    fn proportional_first_sell_uses_actual_post_buy_units_without_overflow() {
        assert_eq!(
            sell_amount(U256::MAX, U256::from(10_000), true).unwrap(),
            U256::MAX
        );
        assert_eq!(
            sell_amount(U256::from(11), U256::from(5000), true).unwrap(),
            U256::from(5)
        );
        assert!(sell_amount(U256::ONE, U256::ONE, true).is_err());
        assert!(sell_amount(U256::ONE, U256::from(2), false).is_err());
    }
}
