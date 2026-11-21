use crate::{
    ApiError, App, Result,
    config::WBNB,
    route::{approveCall, parse_amount},
    wallets::allowanceCall,
};
use alloy_primitives::{Address, Bytes, U256};
use alloy_sol_types::{SolCall, sol};
use axum::{Json, extract::State};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashSet;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    token: Address,
    wallets: Vec<WalletApproval>,
    launch_spender: Option<Address>,
    inner_platform: Option<String>,
    inner_token: Option<Address>,
    spender: Option<Address>,
    launch_context: Option<crate::launch_approval::Context>,
    permit_expiration: Option<u64>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WalletApproval {
    wallet: Address,
    amount: String,
    reset: bool,
    #[serde(default)]
    orders: Option<u32>,
}

/// Grants bind only a finite ERC20 approve(wallet, configured spender, amount).
/// Swaps still require a separately issued wallet-specific UXUY execution plan.
pub(crate) async fn prepare(
    State(app): State<App>,
    Json(request): Json<Request>,
) -> Result<Json<Value>> {
    let launch_payment = request.launch_spender.is_some();
    let inner_payment = match (
        &request.inner_platform,
        request.inner_token,
        request.spender,
    ) {
        (None, None, None) => false,
        (Some(platform), Some(token), Some(spender))
            if !launch_payment
                && request.launch_context.is_none()
                && request.permit_expiration.is_none() =>
        {
            app.planner
                .verify_inner_spender(token, platform, request.token, spender)
                .await?;
            true
        }
        _ => return Err(ApiError::invalid("内盘授权对象与代币依据不完整")),
    };
    let spender = request
        .spender
        .or(request.launch_spender)
        .unwrap_or(app.planner.spender);
    let token = request.token;
    if !spender.is_zero() && crate::submit::denied(spender, &app.denied) {
        return Err(ApiError::invalid("该授权合约已被禁用"));
    }
    if (!launch_payment && !inner_payment && !app.route_enabled) || spender.is_zero() {
        return Err(ApiError::unavailable("UXUY 授权服务未配置"));
    }
    if token.is_zero()
        || (!launch_payment && !inner_payment && token == WBNB)
        || token == app.planner.native
        || token == spender
        || token == app.router
        || crate::submit::denied(token, &app.denied)
    {
        return Err(ApiError::invalid("授权代币无效"));
    }
    let count: usize = request
        .wallets
        .iter()
        .map(|w| if w.reset { 2 } else { 1 })
        .sum();
    if count == 0 || count > 103 {
        return Err(ApiError::invalid("每组授权最多 103 笔"));
    }
    if let Some(ctx) = &request.launch_context {
        if !launch_payment {
            return Err(ApiError::invalid("发币授权缺少授权对象"));
        }
        crate::launch_approval::verify(
            &app,
            ctx,
            token,
            spender,
            request.permit_expiration.is_some(),
        )
        .await?;
    } else if request.permit_expiration.is_some() {
        return Err(ApiError::invalid("Permit2 授权缺少发币依据"));
    } else if launch_payment {
        check_launch_asset(&app, token, spender).await?;
    }
    if let Some(expiry) = request.permit_expiration {
        let [row] = request.wallets.as_slice() else {
            return Err(ApiError::invalid("每次 Permit2 检查限一个钱包"));
        };
        if row.reset || row.wallet.is_zero() {
            return Err(ApiError::invalid("Permit2 授权参数无效"));
        }
        let amount = parse_amount(&row.amount)?;
        let data =
            crate::launch_approval::verify_permit(&app, token, row.wallet, amount, expiry).await?;
        let deadline = expiry.min(crate::now() + 90);
        app.issued.record_private_approvals(
            &[(
                row.wallet,
                crate::launch_bundle::PERMIT2,
                alloy_primitives::keccak256(data),
            )],
            deadline,
        )?;
        return Ok(Json(
            json!({"ok":true,"chainId":56,"token":token,"spender":spender,"deadline":deadline,"permitExpiration":expiry,"wallets":[{"wallet":row.wallet,"amount":row.amount,"reset":false}]}),
        ));
    }
    let mut seen = HashSet::new();
    let mut calls = Vec::new();
    let mut grants = Vec::new();
    for row in &request.wallets {
        let amount = parse_amount(&row.amount)?;
        if let (Some(platform), Some(market)) = (&request.inner_platform, request.inner_token) {
            if !app.issued.inner_budget(
                row.wallet,
                market,
                platform,
                token,
                spender,
                amount,
                row.orders.unwrap_or(1),
                crate::now(),
            ) {
                return Err(ApiError::new(
                    "INNER_GRANT_BUDGET",
                    "内盘授权超过本钱包已检查的有效订单额度，请重新检查",
                    422,
                    false,
                ));
            }
        } else if row.orders.is_some() {
            return Err(ApiError::invalid("该授权不使用内盘订单数"));
        }
        if amount == U256::MAX || row.wallet.is_zero() || !seen.insert(row.wallet) {
            return Err(ApiError::invalid("授权金额或钱包无效"));
        }
        for value in row
            .reset
            .then_some(U256::ZERO)
            .into_iter()
            .chain(std::iter::once(amount))
        {
            calls.push(json!({"from":row.wallet,"to":token,"data":Bytes::from(approveCall{spender,amount:value}.abi_encode())}));
        }
        calls.push(json!({"from":row.wallet,"to":token,"data":Bytes::from(allowanceCall{owner:row.wallet,spender}.abi_encode())}));
        grants.push((row.wallet, amount));
    }
    let results = app.planner.simulate_calls(calls).await?;
    verify(&request.wallets, &results)?;
    let deadline = crate::now() + app.planner.deadline_seconds;
    let mut actions = grants.clone();
    if launch_payment || inner_payment {
        actions.extend(
            request
                .wallets
                .iter()
                .filter(|row| row.reset)
                .map(|row| (row.wallet, U256::ZERO)),
        );
    }
    if request.launch_context.is_some() || inner_payment {
        let proofs = actions
            .iter()
            .map(|&(wallet, amount)| {
                (
                    wallet,
                    token,
                    alloy_primitives::keccak256(approveCall { spender, amount }.abi_encode()),
                )
            })
            .collect::<Vec<_>>();
        app.issued.record_private_approvals(&proofs, deadline)?;
    } else {
        app.issued
            .record_approvals(token, spender, &actions, deadline)?;
    }
    Ok(Json(
        json!({"ok":true, "chainId":56, "token":token, "spender":spender, "deadline":deadline,
        "wallets":grants.iter().map(|(wallet,amount)| json!({"wallet":wallet,"amount":amount.to_string()})).collect::<Vec<_>>() }),
    ))
}

fn verify(rows: &[WalletApproval], results: &[Value]) -> Result<()> {
    let failed = || {
        ApiError::new(
            "APPROVAL_CHECK_FAILED",
            "代币授权模拟或额度回查失败",
            422,
            false,
        )
    };
    let mut results = results.iter();
    let mut next = || {
        let row = results.next().ok_or_else(failed)?;
        if crate::rpc::hex_u64(&row["status"]).ok() != Some(1) || !row["error"].is_null() {
            return Err(failed());
        }
        row["returnData"].as_str().ok_or_else(failed)
    };
    for row in rows {
        for _ in 0..if row.reset { 2 } else { 1 } {
            let data = next()?;
            if data != "0x"
                && (data.len() != 66
                    || U256::from_str_radix(data.trim_start_matches("0x"), 16).ok()
                        != Some(U256::ONE))
            {
                return Err(failed());
            }
        }
        let data = next()?;
        if data.len() != 66
            || U256::from_str_radix(data.trim_start_matches("0x"), 16).ok()
                != Some(parse_amount(&row.amount)?)
        {
            return Err(failed());
        }
    }
    if results.next().is_some() {
        return Err(failed());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn response(n: u64) -> Value {
        json!({"status":"0x1", "returnData":format!("0x{n:064x}")})
    }
    #[test]
    fn requires_confirmed_token_return_and_exact_allowance_after_each_owner() {
        let row = WalletApproval {
            wallet: Address::repeat_byte(3),
            amount: "17".into(),
            reset: true,
            orders: None,
        };
        let rows = [row];
        assert!(verify(&rows, &[response(1), response(1), response(17)]).is_ok());
        for results in [
            vec![response(1), response(0), response(17)],
            vec![response(1), response(1), response(16)],
            vec![response(1), response(17)],
        ] {
            assert!(verify(&rows, &results).is_err());
        }
    }
}

sol! { function approvedPairTokens(address token) returns (bool); }

async fn check_launch_asset(app: &App, token: Address, spender: Address) -> Result<()> {
    use crate::submit::{
        FLAP_PORTAL, FLAP_VAULT_PORTAL, FOUR_MANAGER, GENIUS_M52, GENIUS_M52_LAUNCH_AND_BUY,
    };
    let unavailable = |_| ApiError::unavailable("无法核对官方发射台底池清单");
    let contains = |rows: &Value, key: &str, published_only: bool| {
        rows.as_array().is_some_and(|rows| {
            rows.iter().any(|row| {
                (!published_only || row["status"] == "PUBLISH")
                    && row[key]
                        .as_str()
                        .and_then(|address| address.parse::<Address>().ok())
                        == Some(token)
            })
        })
    };
    let supported = if spender == GENIUS_M52_LAUNCH_AND_BUY {
        let call = Bytes::from(approvedPairTokensCall { token }.abi_encode());
        let reply = app
            .rpc
            .call(
                "eth_call",
                json!([{"to": GENIUS_M52, "data": call}, "latest"]),
            )
            .await?;
        let bytes = reply.as_str().and_then(|text| text.parse::<Bytes>().ok());
        bytes.is_some_and(|bytes| {
            approvedPairTokensCall::abi_decode_returns(&bytes).is_ok_and(|value| value)
        })
    } else if spender == FOUR_MANAGER {
        let catalog = app
            .integrations
            .four(json!({"action":"config"}))
            .await
            .map_err(unavailable)?;
        contains(&catalog["data"], "symbolAddress", true)
    } else if spender == FLAP_PORTAL || spender == FLAP_VAULT_PORTAL {
        let catalog = app.integrations.flap_catalog().await.map_err(unavailable)?;
        if contains(&catalog["tokens"], "address", false) {
            true
        } else {
            let catalog = app
                .integrations
                .flap_custom_catalog()
                .await
                .map_err(unavailable)?;
            contains(&catalog["tokens"], "address", false)
        }
    } else {
        false
    };
    if !supported || crate::submit::denied(spender, &app.denied) {
        return Err(ApiError::invalid(
            "该代币或授权对象不属于所选发射台的正式预购组合",
        ));
    }
    Ok(())
}
