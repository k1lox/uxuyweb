//! Private same-block buys must refer to the token created earlier by the official
//! launch contract. The relay only receives a bundle after ordered BSC simulation.
use crate::{
    ApiError, Result,
    submit::{
        self, FLAP_PORTAL, FLAP_VAULT_PORTAL, FOUR_MANAGER, GENIUS_M52, GENIUS_M52_LAUNCH_AND_BUY,
    },
};
use alloy_consensus::{Transaction, TxEnvelope};
use alloy_primitives::{Address, B256, Bytes, U256, address, keccak256};
use alloy_sol_types::{SolCall, SolValue, sol};
use botai_platforms::abi::{
    getLaunchedTokenCall, getTokenInfoCall, getTokenV8SafeCall, poolKeyForCall,
};
use serde_json::{Value, json};

pub(crate) const PANCAKE: Address = address!("10ed43c718714eb63d5aA57B78B54704E256024E");
pub(crate) const INFINITY: Address = address!("d9c500dff816a1da21a48a732d3498bf09dc9aeb");
pub(crate) const PERMIT2: Address = address!("31c2f6fcff4f8759b3bd5bf0e1084a055615c768");
const FOUR_HELPER: Address = address!("f251f83e40a78868fcfa3fa4599dad6494e46034");
const HOOK: Address = address!("2c908012aba847735b6f43654265b02e3d37d74a");
const CL_MANAGER: Address = address!("a0ffb9c1ce1fe56963b0321b32e7a0302114058b");

sol! {
    function buyTokenAMAP(address token,address recipient,uint256 funds,uint256 minAmount);
    struct FlapBuy{address inputToken;address outputToken;uint256 amount;uint256 minOutput;bytes permitData;bytes extensionData;}
    function swapExactInputV3(FlapBuy swap);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256 minOut,address[] path,address to,uint256 deadline);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(uint256 amount,uint256 minOut,address[] path,address to,uint256 deadline);
    function buy(uint256 amount,uint256 minOut,address recipient);
    function createGraduatedPool(address token);
    function execute(bytes commands,bytes[] inputs,uint256 deadline);
    struct PoolKey{address currency0;address currency1;address hooks;address poolManager;uint24 fee;bytes32 parameters;}
    struct Swap{PoolKey poolKey;bool zeroForOne;uint128 amountIn;uint128 amountOutMinimum;bytes hookData;}
    function promote(address factory,address token);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Platform {
    Four,
    Flap,
    Genius,
}

pub(crate) fn platform(to: Address, input: &[u8]) -> Option<Platform> {
    if !submit::platform_guard(to, input).ok()? {
        return None;
    }
    match to {
        FOUR_MANAGER => Some(Platform::Four),
        FLAP_PORTAL | FLAP_VAULT_PORTAL => Some(Platform::Flap),
        GENIUS_M52 | GENIUS_M52_LAUNCH_AND_BUY => Some(Platform::Genius),
        _ => None,
    }
}

pub(crate) fn invalid() -> ApiError {
    ApiError::invalid("同块买单的合约、代币、金额、收款人或执行顺序与本次发币不符")
}

#[derive(Debug)]
enum Step {
    Buy {
        token: Option<Address>,
        quote: Option<Address>,
        curve: Option<Address>,
        recipient: Address,
        min: U256,
        outer: bool,
        pool_key: Option<Bytes>,
    },
    Migrate(Address),
    Alpha(Address),
}

fn decode<C: SolCall>(data: &[u8]) -> Result<C> {
    let call = C::abi_decode_validate(data).map_err(|_| invalid())?;
    if call.abi_encode() != data {
        return Err(invalid());
    }
    Ok(call)
}
fn live_deadline(d: U256, now: u64) -> bool {
    d >= U256::from(now) && d <= U256::from(now + 3600)
}
fn pays(value: U256, quote: Address, amount: U256) -> bool {
    amount > U256::ZERO && value == if quote.is_zero() { amount } else { U256::ZERO }
}

fn step(
    p: Platform,
    to: Address,
    value: U256,
    data: &[u8],
    signer: Address,
    now: u64,
) -> Result<Option<Step>> {
    let sel = data.get(..4).unwrap_or_default();
    let leg = match p {
        Platform::Four if to == FOUR_MANAGER && sel == buyTokenAMAPCall::SELECTOR => {
            let c = decode::<buyTokenAMAPCall>(data)?;
            if c.recipient != signer
                || c.funds.is_zero()
                || (!value.is_zero() && value != c.funds)
                || c.minAmount.is_zero()
            {
                return Err(invalid());
            }
            Step::Buy {
                token: Some(c.token),
                quote: None,
                curve: None,
                recipient: signer,
                min: c.minAmount,
                outer: false,
                pool_key: None,
            }
        }
        Platform::Four if to == PANCAKE => {
            let (path, recipient, min, deadline) = if sel
                == swapExactETHForTokensSupportingFeeOnTransferTokensCall::SELECTOR
            {
                let c = decode::<swapExactETHForTokensSupportingFeeOnTransferTokensCall>(data)?;
                if value.is_zero() || c.path.first() != Some(&crate::config::WBNB) {
                    return Err(invalid());
                }
                (c.path, c.to, c.minOut, c.deadline)
            } else {
                let c = decode::<swapExactTokensForTokensSupportingFeeOnTransferTokensCall>(data)?;
                if !value.is_zero() || c.amount.is_zero() {
                    return Err(invalid());
                }
                (c.path, c.to, c.minOut, c.deadline)
            };
            if path.len() != 2
                || path[0] == path[1]
                || recipient != signer
                || min.is_zero()
                || !live_deadline(deadline, now)
            {
                return Err(invalid());
            }
            Step::Buy {
                token: Some(path[1]),
                quote: Some(if value.is_zero() {
                    path[0]
                } else {
                    Address::ZERO
                }),
                curve: None,
                recipient,
                min,
                outer: true,
                pool_key: None,
            }
        }
        Platform::Flap if to == FLAP_PORTAL && sel == swapExactInputV3Call::SELECTOR => {
            let c = decode::<swapExactInputV3Call>(data)?.swap;
            if !pays(value, c.inputToken, c.amount)
                || c.minOutput.is_zero()
                || !c.permitData.is_empty()
                || !c.extensionData.is_empty()
            {
                return Err(invalid());
            }
            Step::Buy {
                token: Some(c.outputToken),
                quote: Some(c.inputToken),
                curve: None,
                recipient: signer,
                min: c.minOutput,
                outer: false,
                pool_key: None,
            }
        }
        Platform::Genius if sel == buyCall::SELECTOR => {
            let c = decode::<buyCall>(data)?;
            if c.recipient != signer
                || c.amount.is_zero()
                || c.minOut.is_zero()
                || (!value.is_zero() && value != c.amount)
            {
                return Err(invalid());
            }
            Step::Buy {
                token: None,
                quote: None,
                curve: Some(to),
                recipient: signer,
                min: c.minOut,
                outer: false,
                pool_key: None,
            }
        }
        Platform::Genius
            if to == GENIUS_M52 && sel == createGraduatedPoolCall::SELECTOR && value.is_zero() =>
        {
            Step::Migrate(decode::<createGraduatedPoolCall>(data)?.token)
        }
        Platform::Genius if to == INFINITY => {
            let call = decode::<executeCall>(data)?;
            if call.commands.as_ref() != [0x10]
                || call.inputs.len() != 1
                || !live_deadline(call.deadline, now)
            {
                return Err(invalid());
            }
            let args = <(Bytes, Vec<Bytes>)>::abi_decode_params_validate(&call.inputs[0])
                .map_err(|_| invalid())?;
            if args.abi_encode_params() != call.inputs[0].as_ref()
                || args.0.as_ref() != [0x06, 0x0c, 0x0f]
                || args.1.len() != 3
            {
                return Err(invalid());
            }
            let swap = Swap::abi_decode_validate(&args.1[0]).map_err(|_| invalid())?;
            let input =
                <(Address, U256)>::abi_decode_params_validate(&args.1[1]).map_err(|_| invalid())?;
            let output =
                <(Address, U256)>::abi_decode_params_validate(&args.1[2]).map_err(|_| invalid())?;
            let k = &swap.poolKey;
            let pair = if swap.zeroForOne {
                (k.currency0, k.currency1)
            } else {
                (k.currency1, k.currency0)
            };
            if swap.abi_encode() != args.1[0].as_ref()
                || input.abi_encode_params() != args.1[1].as_ref()
                || output.abi_encode_params() != args.1[2].as_ref()
                || pair != (input.0, output.0)
                || input.0 == output.0
                || input.1 != U256::from(swap.amountIn)
                || output.1 != U256::from(swap.amountOutMinimum)
                || output.1.is_zero()
                || !pays(value, input.0, input.1)
                || k.hooks != HOOK
                || k.poolManager != CL_MANAGER
                || !swap.hookData.is_empty()
            {
                return Err(invalid());
            }
            Step::Buy {
                token: Some(output.0),
                quote: Some(input.0),
                curve: None,
                recipient: signer,
                min: output.1,
                outer: true,
                pool_key: Some(k.abi_encode().into()),
            }
        }
        _ => return Ok(None),
    };
    Ok(Some(leg))
}

fn check_block_gas(mut remaining: u64, calls: &[Value], rows: &[Value], offsets: &[usize]) -> Result<()> {
    for (call, &offset) in calls.iter().zip(offsets) {
        let limit = crate::rpc::hex_u64(&call["gas"])?;
        let used = crate::rpc::hex_u64(&rows[offset]["gasUsed"])?;
        if used == 0 || used > limit || limit > remaining {
            return Err(ApiError::invalid("Genius 同块交易超过当前区块 Gas 容量，或模拟耗气无效"));
        }
        remaining -= used;
    }
    Ok(())
}

pub(crate) fn output(row: &Value) -> Result<Bytes> {
    if crate::rpc::hex_u64(&row["status"]).ok() != Some(1) || !row["error"].is_null() {
        return Err(invalid());
    }
    row["returnData"]
        .as_str()
        .and_then(|s| s.parse().ok())
        .ok_or_else(invalid)
}
pub(crate) fn created_token(p: Platform, row: &Value, dev: Address) -> Result<Address> {
    let out = output(row)?;
    if p == Platform::Four {
        let signature =
            keccak256("TokenCreate(address,address,uint256,string,string,uint256,uint256,uint256)");
        let mut created = None;
        for log in row["logs"].as_array().into_iter().flatten() {
            if address_field(&log["address"]) != Some(FOUR_MANAGER)
                || log["topics"][0]
                    .as_str()
                    .and_then(|s| s.parse::<B256>().ok())
                    != Some(signature)
            {
                continue;
            }
            let raw: Bytes = log["data"]
                .as_str()
                .and_then(|s| s.parse().ok())
                .ok_or_else(invalid)?;
            let creator = Address::abi_decode_validate(raw.get(..32).ok_or_else(invalid)?)
                .map_err(|_| invalid())?;
            let token = Address::abi_decode_validate(raw.get(32..64).ok_or_else(invalid)?)
                .map_err(|_| invalid())?;
            if creator != dev || token.is_zero() || created.replace(token).is_some() {
                return Err(invalid());
            }
        }
        return created.ok_or_else(invalid);
    }
    if out.len() != 32 && !(p == Platform::Genius && out.len() == 64) {
        return Err(invalid());
    }
    Address::abi_decode_validate(&out[..32])
        .ok()
        .filter(|t| !t.is_zero())
        .ok_or_else(invalid)
}
fn address_field(v: &Value) -> Option<Address> {
    v.as_str()?.parse().ok()
}
fn read(to: Address, data: Vec<u8>) -> Value {
    json!({"to":to,"data":Bytes::from(data)})
}
pub(crate) fn four_info(token: Address) -> Value {
    read(FOUR_HELPER, getTokenInfoCall { token }.abi_encode())
}
fn view(p: Platform, token: Address) -> Value {
    match p {
        Platform::Four => four_info(token),
        Platform::Flap => read(FLAP_PORTAL, getTokenV8SafeCall { token }.abi_encode()),
        Platform::Genius => read(GENIUS_M52, getLaunchedTokenCall { token }.abi_encode()),
    }
}

fn net_delivery(row: &Value, token: Address, recipient: Address) -> Result<U256> {
    let transfer = keccak256("Transfer(address,address,uint256)");
    let (mut credit, mut debit) = (U256::ZERO, U256::ZERO);
    for log in row["logs"].as_array().into_iter().flatten() {
        if address_field(&log["address"]) != Some(token)
            || log["topics"][0].as_str().and_then(|s| s.parse().ok()) != Some(transfer)
        {
            continue;
        }
        let topics = log["topics"]
            .as_array()
            .filter(|t| t.len() == 3)
            .ok_or_else(invalid)?;
        let owner = |i: usize| -> Result<Address> {
            let b: Bytes = topics[i]
                .as_str()
                .and_then(|s| s.parse().ok())
                .ok_or_else(invalid)?;
            Address::abi_decode_validate(&b).map_err(|_| invalid())
        };
        let raw: Bytes = log["data"]
            .as_str()
            .and_then(|s| s.parse().ok())
            .ok_or_else(invalid)?;
        let amount = U256::abi_decode_validate(&raw).map_err(|_| invalid())?;
        if owner(1)? == recipient {
            debit = debit.checked_add(amount).ok_or_else(invalid)?
        }
        if owner(2)? == recipient {
            credit = credit.checked_add(amount).ok_or_else(invalid)?
        }
    }
    credit.checked_sub(debit).ok_or_else(invalid)
}

/// Both BSC launchpads encode this event without indexed parameters.
fn graduation_event(p: Platform, row: &Value, token: Address, quote: Address) -> bool {
    let (emitter, sig) = match p {
        Platform::Four => (
            FOUR_MANAGER,
            "LiquidityAdded(address,uint256,address,uint256)",
        ),
        Platform::Flap => (
            FLAP_PORTAL,
            "LaunchedToDEX(address,address,uint256,uint256)",
        ),
        Platform::Genius => return false,
    };
    row["logs"].as_array().into_iter().flatten().any(|log| {
        if address_field(&log["address"]) != Some(emitter)
            || log["topics"].as_array().map(Vec::len) != Some(1)
            || log["topics"][0].as_str().and_then(|s| s.parse().ok()) != Some(keccak256(sig))
        {
            return false;
        }
        let Some(data) = log["data"].as_str().and_then(|v| v.parse::<Bytes>().ok()) else {
            return false;
        };
        if data.len() != 128 {
            return false;
        }
        match p {
            Platform::Four => <(Address, U256, Address, U256)>::abi_decode_params_validate(&data)
                .is_ok_and(|(t, _, q, _)| t == token && q == quote),
            Platform::Flap => <(Address, Address, U256, U256)>::abi_decode_params_validate(&data)
                .is_ok_and(|(t, pool, _, _)| t == token && !pool.is_zero()),
            Platform::Genius => false,
        }
    })
}

#[derive(Default)]
pub(crate) struct LaunchBundle {
    creation: Option<(Platform, usize, Address)>,
    multiple: bool,
    calls: Vec<Value>,
    steps: Vec<(usize, Step)>,
}
impl LaunchBundle {
    pub(crate) fn has_creation(&self) -> bool {
        self.creation.is_some()
    }
    pub(crate) fn record(
        &mut self,
        tx: &TxEnvelope,
        signer: Address,
        denied: &[Address],
        now: u64,
    ) -> Result<bool> {
        let to = tx.to().ok_or_else(invalid)?;
        self.record_call(
            to,
            tx.input(),
            tx.value(),
            tx.gas_limit(),
            signer,
            denied,
            now,
        )
    }

    fn record_call(
        &mut self,
        to: Address,
        data: &[u8],
        value: U256,
        gas: u64,
        signer: Address,
        denied: &[Address],
        now: u64,
    ) -> Result<bool> {
        let i = self.calls.len();
        self.calls.push(json!({"from":signer,"to":to,"data":Bytes::copy_from_slice(data),"value":format!("{value:#x}"),"gas":format!("{gas:#x}")}));
        if let Some(p) = platform(to, data) {
            self.multiple |= self.creation.replace((p, i, signer)).is_some();
            return Ok(false);
        }
        let Some((p, _, dev)) = self.creation else {
            return Ok(false);
        };
        if denied.contains(&to) || submit::RETIRED_ROUTERS.contains(&to) {
            return Ok(false);
        }
        if to == submit::GENIUS_ALPHA && p == Platform::Genius {
            let c = decode::<promoteCall>(data)?;
            if signer != dev
                || c.factory != GENIUS_M52
                || value.is_zero()
                || self.steps.iter().any(|(_, s)| matches!(s, Step::Alpha(_)))
            {
                return Err(invalid());
            }
            self.steps.push((i, Step::Alpha(c.token)));
            return Ok(true);
        }
        if let Some(s) = step(p, to, value, data, signer, now)? {
            if matches!(s, Step::Migrate(_)) && dev != signer {
                return Err(invalid());
            }
            self.steps.push((i, s));
            return Ok(true);
        }
        Ok(false)
    }
    pub(crate) async fn verify(
        &self,
        planner: &crate::route::Planner,
        rpc: &crate::rpc::Rpc,
    ) -> Result<()> {
        if self.steps.is_empty() {
            return Ok(());
        }
        if self.multiple {
            return Err(invalid());
        }
        let (p, idx, dev) = self.creation.ok_or_else(invalid)?;
        let first = planner.simulate_calls(self.calls[..=idx].to_vec()).await?;
        let token = created_token(p, &first[idx], dev)?;
        if rpc
            .call("eth_getCode", json!([token, "latest"]))
            .await?
            .as_str()
            != Some("0x")
        {
            return Err(invalid());
        }

        let mut calls = Vec::new();
        let mut offsets = Vec::new();
        let mut read_state = vec![false; self.calls.len()];
        read_state[idx] = true;
        let mut final_outer = None;
        for (i, step) in &self.steps {
            if p == Platform::Genius && matches!(step, Step::Buy { outer: true, .. }) {
                // Genius ticks from the curve into a permanent DEX phase.
                // Verify every signed buy and delivery, and read the final state once.
                final_outer = Some(*i);
            } else {
                read_state[*i] = true;
            }
        }
        if let Some(last) = final_outer {
            read_state[last] = true;
        }
        for (i, c) in self.calls.iter().enumerate() {
            offsets.push(calls.len());
            calls.push(c.clone());
            if read_state[i] {
                calls.push(view(p, token))
            }
            if i == idx
                && self.steps.iter().any(|(_, s)| {
                    matches!(
                        s,
                        Step::Buy {
                            pool_key: Some(_),
                            ..
                        }
                    )
                })
            {
                calls.push(read(GENIUS_M52, poolKeyForCall { token }.abi_encode()))
            }
        }
        let rows = planner.simulate_calls(calls).await?;
        for row in &rows {
            output(row)?;
        }
        if p == Platform::Genius {
            let head = rpc.call("eth_getBlockByNumber", json!(["latest", false])).await?;
            check_block_gas(crate::rpc::hex_u64(&head["gasLimit"])?, &self.calls, &rows, &offsets)?;
        }
        if created_token(p, &rows[offsets[idx]], dev)? != token {
            return Err(invalid());
        }
        let mut state = self.state(p, token, dev, &rows[offsets[idx] + 1])?;
        let flap_native_payment = if p == Platform::Flap {
            let created = output(&rows[offsets[idx] + 1])?;
            getTokenV8SafeCall::abi_decode_returns_validate(&created)
                .map_err(|_| invalid())?.nativeToQuoteSwapEnabled
        } else { false };
        for (i, s) in &self.steps {
            let pos = offsets[*i];
            let after = if read_state[*i] {
                self.state(p, token, dev, &rows[pos + 1])?
            } else {
                state
            };
            if (after.0, after.1) != (state.0, state.1) {
                return Err(invalid());
            }
            match s {
                Step::Alpha(t) => {
                    if *t != token {
                        return Err(invalid());
                    }
                }
                Step::Migrate(t) => {
                    if *t != token || state.2 != 1 || after.2 != 2 {
                        return Err(invalid());
                    }
                }
                Step::Buy {
                    token: target,
                    quote,
                    curve,
                    recipient,
                    min,
                    outer,
                    pool_key,
                } => {
                    let native = self.calls[*i]["value"].as_str() != Some("0x0");
                    let via_portal = flap_native_payment && native && *quote == Some(Address::ZERO);
                    if target.is_some_and(|t| t != token)
                        || (!via_portal && quote.is_some_and(|q| q != state.0))
                        || curve.is_some_and(|c| c != state.1)
                        || net_delivery(&rows[pos], token, *recipient)? < *min
                    {
                        return Err(invalid());
                    }
                    if !via_portal && native != state.0.is_zero() {
                        return Err(invalid());
                    }
                    let graduates = match p {
                        Platform::Four => state.2 != 2 && after.2 == 2,
                        Platform::Flap => state.2 != 4 && after.2 == 4,
                        Platform::Genius => false,
                    };
                    if graduates && !graduation_event(p, &rows[pos], token, state.0) {
                        return Err(invalid());
                    }
                    if p != Platform::Flap && ((*outer && state.2 != 2) || (!outer && state.2 != 0))
                    {
                        return Err(invalid());
                    }
                    if p == Platform::Genius && *outer && after.2 != 2 {
                        return Err(invalid());
                    }
                    if let Some(key) = pool_key {
                        if &output(&rows[offsets[idx] + 2])? != key {
                            return Err(invalid());
                        }
                    }
                }
            }
            state = after;
        }
        Ok(())
    }
    fn state(
        &self,
        p: Platform,
        token: Address,
        dev: Address,
        row: &Value,
    ) -> Result<(Address, Address, u8)> {
        let data = output(row)?;
        match p {
            Platform::Four => {
                let info =
                    getTokenInfoCall::abi_decode_returns_validate(&data).map_err(|_| invalid())?;
                if info.tokenManager != FOUR_MANAGER || info.version.is_zero() {
                    return Err(invalid());
                }
                Ok((
                    info.quote,
                    FOUR_MANAGER,
                    if info.liquidityAdded { 2 } else { 0 },
                ))
            }
            Platform::Flap => {
                let info = getTokenV8SafeCall::abi_decode_returns_validate(&data)
                    .map_err(|_| invalid())?;
                Ok((info.quoteTokenAddress, FLAP_PORTAL, info.status))
            }
            Platform::Genius => {
                let info = getLaunchedTokenCall::abi_decode_returns_validate(&data)
                    .map_err(|_| invalid())?;
                if !info.exists
                    || info.token != token
                    || info.deployer != dev
                    || info.curve.is_zero()
                {
                    return Err(invalid());
                }
                Ok((info.pairToken, info.curve, info.phase))
            }
        }
    }
}

#[cfg(test)]
#[path = "launch_bundle_tests.rs"]
mod tests;
