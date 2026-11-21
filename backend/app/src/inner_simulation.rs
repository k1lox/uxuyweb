//! Ordered state measurement, minimal output rebinding, and wallet balance verification.
use super::*;

impl Planner {
    pub(super) async fn measure_after(
        &self,
        req: &RouteRequest,
        market: &Value,
        target: Address,
        quote: Address,
        amount: U256,
        prefix: &[Value],
        funding: &[RouteLeg],
    ) -> Result<U256> {
        let wallet = req.wallet;
        let mut calls = prefix.to_vec();
        for step in funding {
            let value = decimal_word(&step.value).ok_or_else(bad)?;
            calls.push(
                json!({"from":wallet,"to":step.to,"value":format!("{value:#x}"),"data":step.data}),
            );
        }
        let assets = if req.side == Side::Buy {
            (quote, req.token)
        } else {
            (req.token, quote)
        };
        if !assets.0.is_zero() {
            for value in [U256::ZERO, amount] {
                calls.push(json!({"from":wallet,"to":assets.0,"data":Bytes::from(approveCall{spender:target,amount:value}.abi_encode())}));
            }
        }
        let (balance_to, data) = if assets.1.is_zero() {
            (
                crate::config::MULTICALL3,
                getEthBalanceCall { addr: wallet }.abi_encode(),
            )
        } else {
            (assets.1, balanceOfCall { owner: wallet }.abi_encode())
        };
        let balance = json!({"from":Address::ZERO,"to":balance_to,"data":Bytes::from(data)});
        let direct = Self::official_leg(req, target, assets, amount, U256::ONE)?;
        let value = decimal_word(&direct.value).ok_or_else(bad)?;
        calls.extend([
            balance.clone(),
            json!({"from":wallet,"to":target,"data":direct.data,"value":format!("{value:#x}")}),
            balance,
        ]);
        let tag = format!("{:#x}", market["block"].as_u64().ok_or_else(bad)?);
        let rows = self.simulate_calls_at(calls, json!(tag)).await?;
        if rows
            .iter()
            .any(|r| crate::rpc::hex_u64(&r["status"]).ok() != Some(1))
        {
            return Err(failed());
        }
        let n = rows.len();
        uint_return(&rows[n - 1]["returnData"])?
            .checked_sub(uint_return(&rows[n - 3]["returnData"])?)
            .filter(|v| !v.is_zero())
            .ok_or_else(failed)
    }
    // A preliminary ordered pass measures each wallet at the reserves left by its
    // predecessors. Then verify the final signed minima in a second pass. The
    // preliminary calldata is never returned or placed in the issued-route cache.
    pub(crate) async fn reprice_inner_bundle(
        &self,
        requests: &[RouteRequest],
        market: &Value,
        plans: &mut [RoutePlan],
        now: u64,
    ) -> Result<()> {
        if plans.iter().map(|p| p.legs.len()).sum::<usize>() > crate::submit::MAX_BUNDLE {
            return Err(ApiError::invalid(
                "本组内盘交易步骤超过单个私有捆绑上限，请减少钱包数量",
            ));
        }
        if plans.len() < 2 {
            return self.simulate_inner_group(plans).await;
        }
        let complex = plans.iter().any(|p| {
            let after = p.legs.iter().skip_while(|s| s.kind != "official").skip(1);
            after.into_iter().any(|s| s.kind == "conversion")
        });
        if complex {
            // A subsequent UXUY order's input is the actual guaranteed collateral.
            // Regenerate that immutable order after measuring the preceding wallets.
            let mut prefix = Vec::new();
            for (request, plan) in requests.iter().zip(plans.iter_mut()) {
                if !prefix.is_empty() {
                    *plan = self
                        .compose_at_state(request, market, now, false, true, &prefix)
                        .await?;
                }
                prefix.extend(Self::inner_calls(plan)?);
            }
        } else {
            let mut calls = Vec::new();
            let mut credit_positions = Vec::new();
            for (request, plan) in requests.iter().zip(plans.iter()) {
                let mut probe = plan.clone();
                let i = probe
                    .legs
                    .iter()
                    .position(|s| s.kind == "official")
                    .ok_or_else(bad)?;
                probe.legs.truncate(i + 1); // wrapping proceeds does not affect the next wallet's market
                let l = &probe.legs[i];
                probe.legs[i] = Self::official_leg(
                    request,
                    l.to,
                    (l.token_in, l.token_out),
                    parse_amount(&l.amount_in)?,
                    U256::ONE,
                )?;
                calls.extend(Self::inner_calls(&probe)?);
                credit_positions.push(calls.len() - 1);
            }
            let tag = format!("{:#x}", market["block"].as_u64().ok_or_else(bad)?);
            let result = self.simulate_calls_at(calls, json!(tag)).await?;
            if result
                .iter()
                .any(|r| crate::rpc::hex_u64(&r["status"]).ok() != Some(1))
            {
                return Err(failed());
            }
            for ((request, plan), index) in
                requests.iter().zip(plans.iter_mut()).zip(credit_positions)
            {
                let out = uint_return(&result[index]["returnData"])?
                    .checked_sub(uint_return(&result[index - 3]["returnData"])?)
                    .filter(|n| !n.is_zero())
                    .ok_or_else(failed)?;
                let i = plan
                    .legs
                    .iter()
                    .position(|s| s.kind == "official")
                    .ok_or_else(bad)?;
                let l = &plan.legs[i];
                let slip = if plan.legs[..i].iter().any(|s| s.kind == "conversion") {
                    plan.slippage_ppm - (plan.slippage_ppm / 200) * 100
                } else {
                    plan.slippage_ppm
                };
                let minimum = min_out(out, slip)?;
                let reference = parse_amount(&plan.quote_out)?;
                // Preserve the per-wallet cap after prior wallets have moved the curve.
                if out < reference {
                    let ratio = md(reference - out, U256::from(100_000_000), reference)?.to::<u64>()
                        as f64
                        / 100_000_000.;
                    let impact = plan.adverse_price_impact_percent
                        + (100. - plan.adverse_price_impact_percent) * ratio;
                    if impact
                        > request
                            .max_impact_percent
                            .unwrap_or(self.max_impact_percent)
                    {
                        return Err(ApiError::new(
                            "BUNDLE_IMPACT_EXCEEDED",
                            format!("钱包 {:#x} 的顺序报价超过价格偏差上限", plan.wallet),
                            422,
                            false,
                        ));
                    }
                    plan.adverse_price_impact_percent = impact;
                    plan.price_impact_percent = -impact;
                }
                plan.legs[i] = Self::official_leg(
                    request,
                    l.to,
                    (l.token_in, l.token_out),
                    parse_amount(&l.amount_in)?,
                    minimum,
                )?;
                plan.data = plan.legs[i].data.clone();
                plan.min_out = minimum.to_string();
                plan.quote_out = out.to_string();
                for tail in &mut plan.legs[i + 1..] {
                    let data = match tail.kind {
                        "wrap" => depositCall {}.abi_encode(),
                        "unwrap" => withdrawCall { amount: minimum }.abi_encode(),
                        _ => return Err(bad()),
                    };
                    *tail = leg(
                        tail.kind,
                        WBNB,
                        (tail.token_in, tail.token_out),
                        minimum,
                        minimum,
                        data,
                        plan.wallet,
                    );
                    plan.quote_out = minimum.to_string();
                }
            }
        }
        self.simulate_inner_group(plans).await
    }
    pub(crate) fn inner_calls(plan: &RoutePlan) -> Result<Vec<Value>> {
        let wallet = plan.wallet;
        let mut calls = Vec::new();
        for a in plan.approvals.iter().filter(|a| a.missing) {
            let amount = parse_amount(&a.amount)?;
            for value in a
                .reset
                .then_some(U256::ZERO)
                .into_iter()
                .chain(std::iter::once(amount))
            {
                calls.push(json!({"from":wallet,"to":a.token,"data":Bytes::from(approveCall{spender:a.spender,amount:value}.abi_encode())}));
            }
        }
        let balance = |token: Address| {
            let (to, data) = if token.is_zero() {
                (
                    crate::config::MULTICALL3,
                    getEthBalanceCall { addr: wallet }.abi_encode(),
                )
            } else {
                (token, balanceOfCall { owner: wallet }.abi_encode())
            };
            json!({"from":Address::ZERO,"to":to,"data":Bytes::from(data)})
        };
        for step in &plan.legs {
            let value = decimal_word(&step.value).ok_or_else(bad)?;
            let input = balance(step.token_in);
            let output = balance(step.token_out);
            calls.extend([
                input.clone(),
                output.clone(),
                json!({"from":wallet,"to":step.to,"value":format!("{value:#x}"),"data":step.data}),
                input,
                output,
            ]);
        }
        Ok(calls)
    }
    pub(crate) fn verify_inner_results(plan: &mut RoutePlan, results: &[Value]) -> Result<()> {
        if results.iter().any(|row| {
            !row["error"].is_null() || crate::rpc::hex_u64(&row["status"]).ok() != Some(1)
        }) {
            return Err(failed());
        }
        let count: usize = plan
            .approvals
            .iter()
            .filter(|a| a.missing)
            .map(|a| if a.reset { 2 } else { 1 })
            .sum();
        if results.len() != count + 5 * plan.legs.len() || plan.legs.is_empty() {
            return Err(failed());
        }
        for row in &results[..count] {
            if row["returnData"] != "0x" && uint_return(&row["returnData"]).ok() != Some(U256::ONE)
            {
                return Err(failed());
            }
        }
        let mut gas_total = 0u64;
        for (step, rows) in plan.legs.iter_mut().zip(results[count..].chunks_exact(5)) {
            let debit = uint_return(&rows[0]["returnData"])?
                .checked_sub(uint_return(&rows[3]["returnData"])?);
            let credit = uint_return(&rows[4]["returnData"])?
                .checked_sub(uint_return(&rows[1]["returnData"])?);
            let amount = parse_amount(&step.amount_in)?;
            let minimum = parse_amount(&step.min_out)?;
            let valid_debit = if (step.kind == "official" && plan.side == Side::Buy)
                || (step.kind == "conversion" && step.token_in.is_zero())
            {
                debit.is_some_and(|n| !n.is_zero() && n <= amount)
            } else {
                debit == Some(amount)
            };
            if !valid_debit || credit.is_none_or(|v| v < minimum) {
                return Err(failed());
            }
            if step.kind == "conversion" {
                Self::verify_traded(
                    &rows[2],
                    step.to,
                    plan.wallet,
                    step.token_in,
                    step.token_out,
                    amount,
                    minimum,
                )?;
            }
            let gas = crate::rpc::hex_u64(&rows[2]["gasUsed"])?;
            if gas < 21_000 {
                return Err(failed());
            }
            step.gas_limit = gas.checked_add(gas / 2).ok_or_else(failed)?;
            gas_total = gas_total.checked_add(step.gas_limit).ok_or_else(failed)?;
        }
        plan.gas_limit = gas_total;
        plan.executed = true;
        plan.gas_estimated = true;
        Ok(())
    }
    pub(crate) async fn simulate_inner_group(&self, plans: &mut [RoutePlan]) -> Result<()> {
        let mut calls = Vec::new();
        let mut ranges = Vec::new();
        for plan in plans.iter() {
            let start = calls.len();
            calls.extend(Self::inner_calls(plan)?);
            ranges.push(start..calls.len());
        }
        let rows = self.simulate_calls(calls).await?;
        for (plan, range) in plans.iter_mut().zip(ranges) {
            Self::verify_inner_results(plan, &rows[range])?;
        }
        Ok(())
    }
}
