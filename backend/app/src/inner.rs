//! Wallet-owned inner-market calls. Only the launchpad registry supplies the curve and collateral.
use super::*;
use crate::submit::{FLAP_PORTAL, FOUR_MANAGER};
use alloy_primitives::address as addr;

const FOUR_HELPER: Address = addr!("f251f83e40a78868fcfa3fa4599dad6494e46034");

sol! {
    function tryBuy(address token, uint256 tokens, uint256 budget) view returns(address manager,address quote,uint256 estimated,uint256 cost,uint256 fee,uint256 msgValue,uint256 approval,uint256 funds);
    function trySell(address token,uint256 amount) returns(address manager,address quote,uint256 funds,uint256 fee);
    function buyTokenAMAP(address token,address to,uint256 funds,uint256 minAmount) payable;
    function sellToken(uint256 origin,address token,uint256 amount,uint256 minFunds);
    struct FlapInput { address inputToken; address outputToken; uint256 inputAmount; }
    struct FlapSwap { address inputToken; address outputToken; uint256 inputAmount; uint256 minOutputAmount; bytes permitData; bytes extensionData; }
    function quoteExactInput(FlapInput input) returns(uint256);
    function swapExactInputV3(FlapSwap input) payable returns(uint256);
    function buy(uint256 amount,uint256 minOut,address recipient) payable returns(uint256);
    function sell(uint256 amount,uint256 minOut,address recipient) returns(uint256);
    function currentSnipeTaxBps(address recipient) view returns(uint256);
    function deposit() payable;
    function withdraw(uint256 amount);
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteLeg {
    pub kind: &'static str,
    pub to: Address,
    pub data: Bytes,
    pub value: String,
    pub gas_limit: u64,
    pub token_in: Address,
    pub token_out: Address,
    pub amount_in: String,
    pub min_out: String,
    pub recipient: Address,
}
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RouteStep {
    pub kind: &'static str,
    pub to: Address,
    pub token_in: Address,
    pub token_out: Address,
    pub amount_in: String,
    pub min_out: String,
    pub recipient: Address,
}
impl From<&RouteLeg> for RouteStep {
    fn from(leg: &RouteLeg) -> Self {
        Self {
            kind: leg.kind,
            to: leg.to,
            token_in: leg.token_in,
            token_out: leg.token_out,
            amount_in: leg.amount_in.clone(),
            min_out: leg.min_out.clone(),
            recipient: leg.recipient,
        }
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct RouteApproval {
    pub token: Address,
    pub spender: Address,
    pub amount: String,
    #[serde(skip)]
    pub(crate) missing: bool,
    #[serde(skip)]
    pub(crate) reset: bool,
}

fn bad() -> ApiError {
    ApiError::new(
        "INNER_ROUTE_INVALID",
        "官方内盘报价或池状态无法核实，请重新检查",
        422,
        false,
    )
}
fn failed() -> ApiError {
    ApiError::new(
        "INNER_SIMULATION_FAILED",
        "官方内盘交易模拟失败，或钱包实际到账低于最低金额",
        422,
        false,
    )
}
fn number(v: &Value) -> Result<U256> {
    v.as_str()
        .and_then(|s| U256::from_str_radix(s, 10).ok())
        .ok_or_else(bad)
}
fn md(a: U256, b: U256, den: U256) -> Result<U256> {
    if den.is_zero() {
        return Err(bad());
    }
    let value = U512::from(a) * U512::from(b) / U512::from(den);
    if value > U512::from(U256::MAX) {
        return Err(bad());
    }
    Ok(value.to::<U256>())
}
fn min_out(estimate: U256, ppm: u64) -> Result<U256> {
    if estimate.is_zero() {
        return Err(bad());
    }
    Ok(md(estimate, U256::from(1_000_000 - ppm), U256::from(1_000_000))?.max(U256::ONE))
}
pub(super) fn registered(
    market: &Value,
    token: Address,
    platform: &str,
) -> Result<(Address, Address)> {
    if market["external"].as_bool() != Some(false)
        || market["platform"] != platform
        || address(&market["address"])? != token
    {
        return Err(ApiError::new(
            "INNER_MARKET_CHANGED",
            "内盘状态已变化，请重新识别代币",
            422,
            false,
        ));
    }
    let target = match platform {
        "four" => FOUR_MANAGER,
        "flap" => FLAP_PORTAL,
        "genius" if market["genius"]["phase"].as_u64() == Some(0) => {
            address(&market["genius"]["curve"])?
        }
        _ => return Err(bad()),
    };
    let collateral = address(&market["quote"])?;
    if target.is_zero() || target == token || collateral == token {
        return Err(bad());
    }
    Ok((target, collateral))
}
fn leg(
    kind: &'static str,
    to: Address,
    assets: (Address, Address),
    amount: U256,
    min: U256,
    data: Vec<u8>,
    wallet: Address,
) -> RouteLeg {
    RouteLeg {
        kind,
        to,
        data: data.into(),
        value: if assets.0.is_zero() {
            amount
        } else {
            U256::ZERO
        }
        .to_string(),
        gas_limit: 0,
        token_in: assets.0,
        token_out: assets.1,
        amount_in: amount.to_string(),
        min_out: min.to_string(),
        recipient: wallet,
    }
}

impl Planner {
    pub(crate) async fn inner_market(&self, req: &RouteRequest) -> Result<Value> {
        self.registered_market(req.token, req.inner_platform.as_deref().ok_or_else(bad)?)
            .await
    }
    pub(crate) async fn registered_market(&self, token: Address, platform: &str) -> Result<Value> {
        if !matches!(platform, "four" | "flap" | "genius") {
            return Err(bad());
        }
        let market = self
            .platforms
            .as_ref()
            .ok_or_else(bad)?
            .inspect(botai_core::Chain::Bsc, token, None)
            .await
            .map_err(|err| {
                ApiError::new("INNER_REGISTRY", err.message, err.status, err.retryable)
            })?;
        registered(&market, token, platform)?;
        Ok(market)
    }
    pub(crate) async fn verify_inner_spender(
        &self,
        token: Address,
        platform: &str,
        asset: Address,
        spender: Address,
    ) -> Result<()> {
        let market = self.registered_market(token, platform).await?;
        let (official, quote) = registered(&market, token, platform)?;
        if (spender == official && (asset == token || asset == quote))
            || (spender == self.spender && asset == quote && !quote.is_zero())
        {
            Ok(())
        } else {
            Err(bad())
        }
    }
    async fn view<C: SolCall>(
        &self,
        to: Address,
        wallet: Address,
        call: C,
        tag: &str,
    ) -> Result<C::Return> {
        let result = self
            .rpc()?
            .call(
                "eth_call",
                json!([{"from":wallet,"to":to,"data":Bytes::from(call.abi_encode())},tag]),
            )
            .await?;
        let data = result
            .as_str()
            .and_then(|s| s.parse::<Bytes>().ok())
            .ok_or_else(bad)?;
        C::abi_decode_returns_validate(&data).map_err(|_| bad())
    }
    async fn official_out(
        &self,
        req: &RouteRequest,
        market: &Value,
        target: Address,
        quote: Address,
        amount: U256,
    ) -> Result<U256> {
        let tag = format!("{:#x}", market["block"].as_u64().ok_or_else(bad)?);
        let buy = req.side == Side::Buy;
        let token = req.token;
        let wallet = req.wallet;
        match req.inner_platform.as_deref() {
            Some("four") if buy => {
                let row = self
                    .view(
                        FOUR_HELPER,
                        wallet,
                        tryBuyCall {
                            token,
                            tokens: U256::ZERO,
                            budget: amount,
                        },
                        &tag,
                    )
                    .await?;
                if row.manager != target || row.quote != quote {
                    return Err(bad());
                }
                Ok(row.estimated)
            }
            Some("four") => {
                let row = self
                    .view(FOUR_HELPER, wallet, trySellCall { token, amount }, &tag)
                    .await?;
                if row.manager != target || row.quote != quote {
                    return Err(bad());
                }
                Ok(row.funds)
            }
            Some("flap") => {
                let (input, output) = if buy { (quote, token) } else { (token, quote) };
                self.view(
                    target,
                    wallet,
                    quoteExactInputCall {
                        input: FlapInput {
                            inputToken: input,
                            outputToken: output,
                            inputAmount: amount,
                        },
                    },
                    &tag,
                )
                .await
            }
            Some("genius") => {
                let state = &market["genius"];
                let reserve_token = number(&market["reserveToken"])?;
                let reserve_quote = number(&market["reserveQuote"])?;
                let fee = number(&state["curveFeeBps"])?;
                let creator = number(&market[if buy { "buyTaxBps" } else { "sellTaxBps" }])?;
                let bps = U256::from(10000);
                let deduct = |n: U256, r: U256| md(n, r, bps);
                if buy {
                    let snipe = if state.get("openingBps").is_some() || state["version"] == "v2" {
                        let allowed = U256::from(9900)
                            .checked_sub(fee)
                            .and_then(|n| n.checked_sub(creator))
                            .ok_or_else(bad)?;
                        self.view(
                            target,
                            wallet,
                            currentSnipeTaxBpsCall { recipient: wallet },
                            &tag,
                        )
                        .await?
                        .min(allowed)
                    } else {
                        U256::ZERO
                    };
                    let net = amount
                        .checked_sub(deduct(amount, fee)?)
                        .and_then(|n| n.checked_sub(deduct(amount, creator).ok()?))
                        .and_then(|n| n.checked_sub(deduct(amount, snipe).ok()?))
                        .ok_or_else(bad)?;
                    let output = md(
                        net,
                        reserve_token,
                        reserve_quote.checked_add(net).ok_or_else(bad)?,
                    )?;
                    Ok(if let Some(limit) = state.get("sellableTokens") {
                        output.min(number(limit)?)
                    } else {
                        output
                    })
                } else {
                    let gross = md(
                        amount,
                        reserve_quote,
                        reserve_token.checked_add(amount).ok_or_else(bad)?,
                    )?;
                    if gross > number(&state["realQuoteReserve"])? {
                        return Err(bad());
                    }
                    gross
                        .checked_sub(deduct(gross, fee)?)
                        .and_then(|n| n.checked_sub(deduct(gross, creator).ok()?))
                        .ok_or_else(bad)
                }
            }
            _ => Err(bad()),
        }
    }
    fn official_leg(
        req: &RouteRequest,
        target: Address,
        assets: (Address, Address),
        amount: U256,
        min: U256,
    ) -> Result<RouteLeg> {
        let wallet = req.wallet;
        let token = req.token;
        let data = match (req.inner_platform.as_deref(), req.side) {
            (Some("four"), Side::Buy) => buyTokenAMAPCall {
                token,
                to: wallet,
                funds: amount,
                minAmount: min,
            }
            .abi_encode(),
            (Some("four"), Side::Sell) => sellTokenCall {
                origin: U256::ZERO,
                token,
                amount,
                minFunds: min,
            }
            .abi_encode(),
            (Some("flap"), _) => swapExactInputV3Call {
                input: FlapSwap {
                    inputToken: assets.0,
                    outputToken: assets.1,
                    inputAmount: amount,
                    minOutputAmount: min,
                    permitData: Bytes::new(),
                    extensionData: Bytes::new(),
                },
            }
            .abi_encode(),
            (Some("genius"), Side::Buy) => buyCall {
                amount,
                minOut: min,
                recipient: wallet,
            }
            .abi_encode(),
            (Some("genius"), Side::Sell) => sellCall {
                amount,
                minOut: min,
                recipient: wallet,
            }
            .abi_encode(),
            _ => return Err(bad()),
        };
        Ok(leg("official", target, assets, amount, min, data, wallet))
    }
}

impl Planner {
    // Called with the collateral as the UXUY order's target or input. Keep the unexecuted
    // gateway payload private until the whole series has been simulated with this wallet.
    async fn collateral_swap(
        &self,
        original: &RouteRequest,
        assets: (Address, Address),
        amount: U256,
        now: u64,
        forecast: bool,
        slip: u64,
    ) -> Result<RoutePlan> {
        let (input, output) = assets;
        let buy = input.is_zero();
        let req = RouteRequest {
            inner_platform: None,
            side: if buy { Side::Buy } else { Side::Sell },
            token: if buy { output } else { input },
            settlement_token: (!buy && !output.is_zero()).then_some(output),
            amount: amount.to_string(),
            wallet: original.wallet,
            slippage_bps: Some((slip / 100) as u16),
            max_impact_percent: original.max_impact_percent,
            forecast_only: forecast,
        };
        let prec = self.precisions(&req).await?;
        let cap = req.max_impact_percent.unwrap_or(self.max_impact_percent);
        let (order, rows) = self.quote_rows(&req, amount, slip, prec, false).await?;
        let mut last = no_route();
        for row in rows {
            match self.parse_row(
                &req, &row, &order, amount, slip, cap, prec, now, false, !forecast,
            ) {
                Ok(plan) => return Ok(plan),
                Err(err) => last = err,
            }
        }
        Err(last)
    }

    pub(crate) async fn compose_inner(
        &self,
        req: &RouteRequest,
        market: &Value,
        now: u64,
        group: bool,
        preview_only: bool,
    ) -> Result<RoutePlan> {
        self.compose_at_state(req, market, now, group, preview_only, &[])
            .await
    }
    pub(crate) async fn compose_inner_after(
        &self,
        req: &RouteRequest,
        market: &Value,
        now: u64,
        prefix: &[Value],
    ) -> Result<RoutePlan> {
        if req.side != Side::Sell || prefix.is_empty() {
            return Err(bad());
        }
        self.compose_at_state(req, market, now, false, true, prefix)
            .await
    }
    async fn compose_at_state(
        &self,
        req: &RouteRequest,
        market: &Value,
        now: u64,
        group: bool,
        preview_only: bool,
        prefix: &[Value],
    ) -> Result<RoutePlan> {
        let (amount, slip, cap) = self.validate(req)?;
        let platform = req.inner_platform.as_deref().ok_or_else(bad)?;
        let (target, pool_quote) = registered(market, req.token, platform)?;
        let wallet = req.wallet;
        let forecast = group || req.forecast_only;
        let buy = req.side == Side::Buy;
        let settlement = req.settlement_token.unwrap_or(Address::ZERO);
        // Flap explicitly advertises native settlement for selected ERC20 pools.
        let portal_native = platform == "flap"
            && !pool_quote.is_zero()
            && settlement.is_zero()
            && market["nativeToQuoteSwapEnabled"] == true;
        let quote = if portal_native {
            Address::ZERO
        } else {
            pool_quote
        };
        let assets = if buy {
            (Address::ZERO, quote)
        } else {
            (quote, settlement)
        };
        // Allocate the user's slippage budget across the two market executions.
        let convert = assets.0 != assets.1;
        let wrap_only = assets == (Address::ZERO, WBNB) || assets == (WBNB, Address::ZERO);
        let convert_slip = if convert && !wrap_only {
            (slip / 200) * 100
        } else {
            0
        };
        let mut legs = Vec::new();
        let mut deadline = now.saturating_add(self.deadline_seconds);
        let mut impact = 0.0;
        let mut official_input = amount;
        if buy && convert {
            if wrap_only {
                legs.push(leg(
                    "wrap",
                    WBNB,
                    assets,
                    amount,
                    amount,
                    depositCall {}.abi_encode(),
                    wallet,
                ));
            } else {
                let conversion = self
                    .collateral_swap(req, assets, amount, now, forecast, convert_slip)
                    .await?;
                official_input = parse_amount(&conversion.min_out)?;
                legs.push(leg(
                    "conversion",
                    conversion.to,
                    assets,
                    amount,
                    official_input,
                    conversion.data.to_vec(),
                    wallet,
                ));
                deadline = deadline.min(conversion.deadline);
                impact += conversion.adverse_price_impact_percent;
            }
        }
        let out = if prefix.is_empty() {
            self.official_out(req, market, target, quote, official_input)
                .await?
        } else {
            // A new buy can supply the curve's entire real reserve. Reuse its exact state
            // for the prospective first sale, including launch rules, tax and wallet balance.
            self.measure_after(req, market, target, quote, official_input, prefix, &legs)
                .await?
        };
        // Compare execution with the price at the registry snapshot. Fees and capped
        // graduation output make this a conservative bound on the user's adverse price.
        let ideal = if portal_native {
            // The portal's native quote includes the BNB/collateral exchange. Sample the
            // same route at this block; the base-token spot is in a different currency.
            let mut reference = None;
            // Some portal conversions round tiny intermediate ERC20 amounts to zero.
            // Use the smallest executable sample; the full sale remains independently verified.
            for divisor in [1000, 100, 10, 2] {
                let sample = (official_input / U256::from(divisor)).max(U256::ONE);
                if sample >= official_input {
                    continue;
                }
                let quoted = if prefix.is_empty() {
                    self.official_out(req, market, target, quote, sample).await
                } else {
                    self.measure_after(req, market, target, quote, sample, prefix, &legs)
                        .await
                };
                if let Ok(marginal) = quoted
                    && !marginal.is_zero()
                {
                    reference = Some(md(marginal, official_input, sample)?);
                    break;
                }
            }
            reference.ok_or_else(bad)?
        } else if platform == "genius" {
            let q = number(&market["reserveQuote"])?;
            let t = number(&market["reserveToken"])?;
            if buy {
                md(official_input, t, q)?
            } else {
                md(official_input, q, t)?
            }
        } else {
            let spot = number(&market["innerPrice"])?;
            let unit = U256::from(10).pow(U256::from(18));
            if buy {
                md(official_input, unit, spot)?
            } else {
                md(official_input, spot, unit)?
            }
        };
        if ideal.is_zero() {
            return Err(bad());
        }
        let loss = ideal.saturating_sub(out);
        impact += (md(loss, U256::from(100_000_000), ideal)?.to::<u64>() as f64) / 1_000_000.;
        let mut quote_out = out;
        let mut minimum = min_out(out, slip - convert_slip)?;
        let direct_assets = if buy {
            (quote, req.token)
        } else {
            (req.token, quote)
        };
        let direct = Self::official_leg(req, target, direct_assets, official_input, minimum)?;
        let data = direct.data.clone();
        legs.push(direct);
        if !buy && convert {
            let mut source = quote;
            if quote == WBNB {
                legs.push(leg(
                    "unwrap",
                    WBNB,
                    (WBNB, Address::ZERO),
                    minimum,
                    minimum,
                    withdrawCall { amount: minimum }.abi_encode(),
                    wallet,
                ));
                source = Address::ZERO;
                if source == settlement {
                    quote_out = minimum;
                }
            }
            if source != settlement {
                if source.is_zero() && settlement == WBNB {
                    legs.push(leg(
                        "wrap",
                        WBNB,
                        (source, WBNB),
                        minimum,
                        minimum,
                        depositCall {}.abi_encode(),
                        wallet,
                    ));
                    quote_out = minimum;
                } else {
                    let conversion = self
                        .collateral_swap(
                            req,
                            (source, settlement),
                            minimum,
                            now,
                            forecast,
                            convert_slip,
                        )
                        .await?;
                    let next = parse_amount(&conversion.min_out)?;
                    quote_out = parse_amount(&conversion.quote_out)?;
                    legs.push(leg(
                        "conversion",
                        conversion.to,
                        (source, settlement),
                        minimum,
                        next,
                        conversion.data.to_vec(),
                        wallet,
                    ));
                    deadline = deadline.min(conversion.deadline);
                    impact += conversion.adverse_price_impact_percent;
                    minimum = next;
                }
            }
        }
        if impact > cap {
            return Err(ApiError::new(
                if group {
                    "BUNDLE_IMPACT_EXCEEDED"
                } else {
                    "LIQUIDITY_INSUFFICIENT"
                },
                format!("内盘交易预计价格偏差 {impact:.2}% 超过所选上限 {cap:.2}%"),
                422,
                false,
            ));
        }
        let mut approvals = Vec::new();
        for step in &legs {
            if step.token_in.is_zero() || step.kind == "unwrap" {
                continue;
            }
            let spender = if step.kind == "conversion" {
                self.spender
            } else {
                target
            };
            let required = parse_amount(&step.amount_in)?;
            let held = if forecast {
                U256::ZERO
            } else {
                self.view(
                    step.token_in,
                    wallet,
                    allowanceCall {
                        owner: wallet,
                        spender,
                    },
                    "latest",
                )
                .await?
            };
            approvals.push(RouteApproval {
                token: step.token_in,
                spender,
                amount: required.to_string(),
                missing: held < required,
                reset: held < required && !held.is_zero(),
            });
        }
        let preapprove = approvals.iter().any(|a| a.missing);
        let mut plan = RoutePlan {
            steps: if forecast {
                legs.iter().map(RouteStep::from).collect()
            } else {
                vec![]
            },
            source: "official",
            chain_id: 56,
            quote_scope: Some(if group { "bundle" } else { "wallet" }),
            side: req.side,
            amount: req.amount.clone(),
            token: req.token,
            settlement_token: req.settlement_token,
            settlement_decimals: match req.settlement_token {
                Some(t) => Some(self.precision(t).await?),
                None => None,
            },
            wallet,
            to: target,
            spender: target,
            data: if forecast { Bytes::new() } else { data },
            value: if buy { amount } else { U256::ZERO }.to_string(),
            pools: vec![target],
            dexes: vec![platform.to_owned()],
            quote_out: quote_out.to_string(),
            min_out: minimum.to_string(),
            slippage_ppm: slip,
            fee: "0".into(),
            price_impact_percent: -impact,
            adverse_price_impact_percent: impact,
            deadline,
            gas_limit: 0,
            gas_estimated: false,
            executed: false,
            simulation: if forecast {
                "forecast"
            } else if preapprove {
                "approve_then_swap"
            } else {
                "official"
            },
            legs: if forecast { vec![] } else { legs },
            approvals,
        };
        if !forecast && !preview_only {
            self.simulate_inner_group(std::slice::from_mut(&mut plan))
                .await?;
        }
        Ok(plan)
    }
}

#[path = "inner_simulation.rs"]
mod verification;
