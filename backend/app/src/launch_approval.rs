//! Verify a launch-specific allowance target before granting a finite approval.
//! Input tokens are bound to the official creation or the official factory preview.
use crate::{
    ApiError, App, Result,
    launch_bundle::{self, INFINITY, PANCAKE, PERMIT2},
    submit::{FOUR_MANAGER, GENIUS_M52},
};
use alloy_primitives::{
    Address, Bytes, U256,
    aliases::{U48, U160},
};
use alloy_sol_types::{SolCall, sol};
use serde::Deserialize;
use serde_json::json;

sol! {
    struct Links{string a;string b;string c;string d;string e;}
    struct Parts{uint16 a;uint16 b;uint16 c;uint16 d;}
    struct Weight{address recipient;uint16 bps;}
    struct Award{uint8 kind;address token;uint256 min;}
    struct Extra{address target;bytes data;uint16 share;address receiver;}
    struct Settings{uint16 buy;uint16 sell;Parts parts;Weight[] weights;Award award;uint48 duration;uint24 fee;address treasury;Extra extra;address[] exemptions;}
    struct Params{string name;string symbol;string description;string image;Links links;bytes32 salt;uint256 config;address pair;address creator;Settings settings;}
    function previewConfigurableLaunch(Params params,address dev) view returns(address token,address curve,bytes32 commitment);
    interface Permit {
        function approve(address token,address spender,uint160 amount,uint48 expiration);
        function allowance(address owner,address token,address spender) view returns(uint160 amount,uint48 expiration,uint48 nonce);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct Context {
    dev: Address,
    to: Address,
    data: Bytes,
    value: String,
}
pub(crate) async fn verify(
    app: &App,
    ctx: &Context,
    token: Address,
    spender: Address,
    permit: bool,
) -> Result<()> {
    let bad = || ApiError::invalid("发币预授权未能匹配官方创建参数、底池币和授权对象");
    if ctx.dev.is_zero()
        || ctx.data.len() > 65536
        || app.denied.contains(&spender)
        || app.denied.contains(&ctx.to)
    {
        return Err(bad());
    }
    if ctx.to == GENIUS_M52 {
        if ctx.value != "0" {
            return Err(bad());
        }
        let args =
            previewConfigurableLaunchCall::abi_decode_validate(&ctx.data).map_err(|_| bad())?;
        if args.abi_encode() != ctx.data.as_ref()
            || args.dev != ctx.dev
            || args.params.creator != ctx.dev
            || args.params.pair != token
        {
            return Err(bad());
        }
        let result = app
            .rpc
            .call(
                "eth_call",
                json!([{"from":ctx.dev,"to":GENIUS_M52,"data":ctx.data},"latest"]),
            )
            .await?;
        let out: Bytes = result
            .as_str()
            .and_then(|s| s.parse().ok())
            .ok_or_else(bad)?;
        let p =
            previewConfigurableLaunchCall::abi_decode_returns_validate(&out).map_err(|_| bad())?;
        if p.token.is_zero()
            || p.curve.is_zero()
            || p.token == p.curve
            || p.commitment.is_zero()
            || (if permit {
                spender != INFINITY
            } else {
                spender != p.curve && spender != PERMIT2
            })
            || app
                .rpc
                .call("eth_getCode", json!([p.token, "latest"]))
                .await?
                .as_str()
                != Some("0x")
        {
            return Err(bad());
        }
        return Ok(());
    }
    if permit
        || spender != PANCAKE
        || launch_bundle::platform(ctx.to, &ctx.data) != Some(launch_bundle::Platform::Four)
        || ctx.to != FOUR_MANAGER
    {
        return Err(bad());
    }
    let payment = U256::from_str_radix(&ctx.value, 10).map_err(|_| bad())?;
    let create =
        json!({"from":ctx.dev,"to":ctx.to,"data":ctx.data,"value":format!("{payment:#x}")});
    let first = app.planner.simulate_calls(vec![create.clone()]).await?;
    let newborn = launch_bundle::created_token(launch_bundle::Platform::Four, &first[0], ctx.dev)?;
    let rows = app
        .planner
        .simulate_calls(vec![create, launch_bundle::four_info(newborn)])
        .await?;
    if launch_bundle::created_token(launch_bundle::Platform::Four, &rows[0], ctx.dev)? != newborn {
        return Err(bad());
    }
    let info = botai_platforms::abi::getTokenInfoCall::abi_decode_returns_validate(
        &launch_bundle::output(&rows[1])?,
    )
    .map_err(|_| bad())?;
    if info.tokenManager != FOUR_MANAGER || info.version.is_zero() || info.quote != token {
        return Err(bad());
    }
    Ok(())
}

pub(crate) fn permit_data(token: Address, amount: U256, expiry: u64) -> Result<Bytes> {
    let now = crate::now();
    if expiry <= now || expiry > now + 1200 || amount.is_zero() || amount >= U256::from(U160::MAX) {
        return Err(ApiError::invalid("Permit2 的精确额度或截止时间无效"));
    }
    Ok(Permit::approveCall {
        token,
        spender: INFINITY,
        amount: amount.to::<U160>(),
        expiration: U48::from(expiry),
    }
    .abi_encode()
    .into())
}
pub(crate) async fn verify_permit(
    app: &App,
    token: Address,
    owner: Address,
    amount: U256,
    expiry: u64,
) -> Result<Bytes> {
    let data = permit_data(token, amount, expiry)?;
    let call = Permit::allowanceCall {
        owner,
        token,
        spender: INFINITY,
    }
    .abi_encode();
    let result = app
        .planner
        .simulate_calls(vec![
            json!({"from":owner,"to":PERMIT2,"data":data}),
            json!({"to":PERMIT2,"data":Bytes::from(call)}),
        ])
        .await?;
    if !launch_bundle::output(&result[0])?.is_empty() {
        return Err(launch_bundle::invalid());
    }
    let granted =
        Permit::allowanceCall::abi_decode_returns_validate(&launch_bundle::output(&result[1])?)
            .map_err(|_| launch_bundle::invalid())?;
    if U256::from(granted.amount) != amount || granted.expiration.to::<u64>() != expiry {
        return Err(launch_bundle::invalid());
    }
    Ok(data)
}
