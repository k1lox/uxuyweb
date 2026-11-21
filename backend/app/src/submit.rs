//! Signed BSC submissions are checked before they reach either relay path.
use crate::{
    error::{ApiError, Result},
    issued::IssuedRoutes,
};
use alloy_consensus::{Transaction, TxEnvelope};
use alloy_primitives::{Address, TxKind, U256, address, keccak256};
use alloy_sol_types::{SolCall, sol};

sol! {
    interface IERC20Calls {
        function approve(address spender, uint256 amount) returns (bool);
        function transfer(address to, uint256 amount) returns (bool);
        function promote(address factory, address token) payable;
    }
}

pub const MAX_BUNDLE: usize = 300;

/// Direct DEX calls and approvals bypass the wallet-specific UXUY quote.
pub const DEX_ROUTERS: [Address; 12] = [
    address!("5994814f2c4040b863a0125a45de152a8c2a4dec"), // OKX DexRouter
    address!("2c34a2fb1d0b4f55de51e1d0bdefaddce6b7cdd6"), // OKX TokenApprove
    address!("5cb43bae4f36e2f9f858232b4dce0dbe27bb85e3"), // OKX exactOut router
    address!("10ed43c718714eb63d5aa57b78b54704e256024e"), // PancakeSwap V2 router
    address!("13f4ea83d0bd40e75c8222255bc855a974568dd4"), // PancakeSwap SmartRouter
    address!("1b81d678ffb9c0263b24a97847620c99d213eb14"), // PancakeSwap V3 SwapRouter
    address!("1a0a18ac4becddbd6389559687d1a73d8927e416"), // PancakeSwap Universal Router
    address!("d9c500dff816a1da21a48a732d3498bf09dc9aeb"), // PancakeSwap Infinity Universal Router
    address!("b971ef87ede563556b2ed4b1c0b0019111dd85d2"), // Uniswap V3 SwapRouter02 (BSC)
    address!("4dae2f939acf50408e13d58534ff8c2776d45265"), // Uniswap Universal Router (BSC)
    address!("1906c1d672b88cd1b9ac7593301ca990f94eae07"), // Uniswap Universal Router v4 (BSC)
    address!("111111125421ca6dc452d289314280a0f8842a65"), // 1inch v6
];

pub const RETIRED_ROUTERS: [Address; 8] = [
    address!("5272bb7b78d6cf58a48f183d80a0605c7fcd65f8"),
    address!("e3abae5fc1c266c03dbb0a1c5b98f2e714736c8a"),
    address!("fdaf79b1dac40f704e9d516b91d7695a9cbbf850"),
    address!("488a6d946c1a6b5505b5a61ef715c087054c38d4"),
    address!("070d82b10579074860d1ca4d9a549d9e53b0537d"),
    address!("e31a749a65dc8888dc572cb60bdfd06cda5f6ab8"),
    address!("591ebcda445b0bb90d9835a8f4d2d8fc39398f7a"),
    address!("788c97fc4cf1c0f83cf0249f41000f12524e0b96"),
];

pub fn checked_bundle(
    raws: &[String],
    issued: &IssuedRoutes,
    router: Address,
    spender: Address,
    extra: &[Address],
) -> botai_core::Result<(botai_transactions::ValidatedBundle, bool)> {
    checked_bundle_with_launch(raws, issued, router, spender, extra, None, &mut Vec::new())
}

pub(crate) async fn checked_private(
    app: &crate::App,
    raws: &[String],
) -> botai_core::Result<(botai_transactions::ValidatedBundle, bool)> {
    let mut launch = crate::launch_bundle::LaunchBundle::default();
    let mut markets = Vec::new();
    let result = checked_bundle_with_launch(
        raws,
        &app.issued,
        app.router,
        app.planner.spender,
        &app.denied,
        Some(&mut launch),
        &mut markets,
    )?;
    markets.sort_unstable();
    markets.dedup();
    for (token, platform) in markets {
        app.planner
            .registered_market(token, &platform)
            .await
            .map_err(|e| botai_core::AppError::new(e.code, &e.message, e.status, e.retryable))?;
    }
    launch
        .verify(&app.planner, &app.rpc)
        .await
        .map_err(|e| botai_core::AppError::new(e.code, &e.message, e.status, e.retryable))?;
    Ok(result)
}

fn checked_bundle_with_launch(
    raws: &[String],
    issued: &IssuedRoutes,
    router: Address,
    spender: Address,
    extra: &[Address],
    mut launch: Option<&mut crate::launch_bundle::LaunchBundle>,
    markets: &mut Vec<(Address, String)>,
) -> botai_core::Result<(botai_transactions::ValidatedBundle, bool)> {
    use botai_core::AppError;
    if raws.len() > MAX_BUNDLE {
        return Err(AppError::invalid("捆绑交易数量过多"));
    }
    let mut has_creation = false;
    let mut fresh_genius = None;
    let now = crate::now();
    let mut txs = Vec::with_capacity(raws.len());
    let mut legs = Vec::with_capacity(raws.len());
    let bundle = botai_transactions::validate_bundle_with_policy(raws, |tx, signer| {
        let to = tx
            .to()
            .ok_or_else(|| AppError::invalid("签名交易没有目标合约"))?;
        if denied(to, extra) || to.is_zero() {
            return Err(AppError::invalid("签名交易目标无效"));
        }
        legs.push(crate::issued::LegProof::new(
            signer,
            to,
            tx.value(),
            tx.input(),
            tx.gas_limit(),
        ));
        txs.push((tx.clone(), signer));
        Ok(())
    })?;
    let mut i = 0;
    while i < txs.len() {
        // A conversion or wrapped-asset call is never issued separately by the inner planner.
        // Authorize only contiguous complete wallet orders; ordinary quotes retain their own proof.
        if let Some((count, market)) = (1..=(legs.len() - i).min(3)).rev().find_map(|n| {
            issued
                .official_order(&legs[i..i + n], now)
                .map(|market| (n, market))
        }) {
            if launch.as_ref().is_some_and(|l| l.has_creation()) {
                return Err(AppError::invalid("已发行内盘交易与新币创建请分开提交"));
            }
            if !txs[i..i + count]
                .windows(2)
                .all(|pair| pair[0].0.nonce().checked_add(1) == Some(pair[1].0.nonce()))
            {
                return Err(AppError::invalid("同一笔内盘交易的步骤 nonce 须连续"));
            }
            markets.push(market);
            has_creation = true; // route requires private bundle delivery
            i += count;
            continue;
        }
        let (tx, signer) = (&txs[i].0, txs[i].1);
        i += 1;
        let destination = tx.to();
        if let Some(proof) = launch.as_deref_mut() {
            if proof
                .record(tx, signer, extra, now)
                .map_err(|e| AppError::new(e.code, &e.message, e.status, e.retryable))?
            {
                continue;
            }
        }
        if destination == Some(GENIUS_ALPHA) {
            let payment = IERC20Calls::promoteCall::abi_decode_validate(tx.input())
                .map_err(|_| AppError::invalid("Genius Alpha 付款参数无效"))?;
            if payment.token.is_zero()
                || tx.value().is_zero()
                || fresh_genius.take() != Some((signer, payment.factory))
                || denied(GENIUS_ALPHA, extra)
            {
                return Err(AppError::invalid(
                    "Genius Alpha 须紧跟同一钱包的官方创建交易",
                ));
            }
            continue;
        }
        let creation = check_policy(tx, signer, issued, router, spender, extra, now)
            .map_err(|e| AppError::new(e.code, &e.message, e.status, e.retryable))?;
        fresh_genius = destination
            .filter(|to| {
                creation
                    && (GENIUS_FACTORIES.contains(to)
                        || *to == GENIUS_M52
                        || *to == GENIUS_M52_LAUNCH_AND_BUY)
            })
            .map(|to| {
                (
                    signer,
                    if to == GENIUS_M52_LAUNCH_AND_BUY {
                        GENIUS_M52
                    } else {
                        to
                    },
                )
            });
        has_creation |= creation;
    }
    Ok((bundle, has_creation))
}

fn check_policy(
    tx: &TxEnvelope,
    signer: Address,
    issued: &IssuedRoutes,
    router: Address,
    spender: Address,
    extra: &[Address],
    now: u64,
) -> Result<bool> {
    let reject = || {
        ApiError::new(
            "ACTION_NOT_ALLOWED",
            "签名交易与本钱包的有效报价或已检查操作不符",
            403,
            false,
        )
    };
    let TxKind::Call(to) = tx.kind() else {
        return Err(reject());
    };
    let input = tx.input().as_ref();
    if denied(to, extra) || to.is_zero() {
        return Err(reject());
    }
    if tx.value().is_zero() && issued.private_approval(signer, to, input, now) {
        return Ok(true);
    }
    if to == router {
        return issued
            .swap(signer, to, tx.value(), input, now)
            .then_some(false)
            .ok_or_else(reject);
    }
    if platform_guard(to, input)? {
        return Ok(true);
    }
    if input.is_empty() && !tx.value().is_zero() {
        return Ok(false);
    }
    if input.len() == 68 && tx.value().is_zero() {
        if let Ok(call) = IERC20Calls::approveCall::abi_decode_validate(input) {
            // Factory pre-purchases pull the selected ERC20 directly. These
            // approvals are restricted to official launch spenders and private bundles.
            if launch_payment_spender(call.spender)
                && !denied(call.spender, extra)
                && call.amount != U256::MAX
                && issued.approval(signer, to, call.spender, call.amount, now)
            {
                return Ok(true);
            }
            if !spender.is_zero()
                && call.spender == spender
                && (call.amount.is_zero() || issued.approval(signer, to, spender, call.amount, now))
            {
                return Ok(false);
            }
            return Err(reject());
        }
        if IERC20Calls::transferCall::abi_decode_validate(input).is_ok() {
            return Ok(false);
        }
    }
    if input == selector("prepayGas()") && !tx.value().is_zero() {
        return Ok(false);
    }
    if GENIUS_FACTORIES.contains(&to)
        && input.len() == 36
        && input.starts_with(&selector("createGraduatedPool(address)"))
        && tx.value().is_zero()
    {
        return Ok(false);
    }
    Err(reject())
}

pub(crate) const FOUR_MANAGER: Address = address!("5c952063c7fc8610ffdb798152d69f0b9550762b");
const FOUR_HELPER: Address = address!("f251f83e40a78868fcfa3fa4599dad6494e46034");
pub(crate) const FLAP_PORTAL: Address = address!("e2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0");
pub(crate) const FLAP_VAULT_PORTAL: Address = address!("90497450f2a706f1951b5bdda52b4e5d16f34c06");
// VaultPortal defines distinct tuple layouts for newTokenV6WithVault and newTokenV7WithVault.
const FLAP_VAULT_V6: [u8; 4] = [0x1b, 0x80, 0x62, 0x20];
const FLAP_VAULT_V7: [u8; 4] = [0x3d, 0x2f, 0xc3, 0x88];
const GENIUS_FACTORIES: [Address; 2] = [
    address!("78eae9537c0ef90dfe9b7ae964682fe8138afe31"),
    address!("37ee8aee29c5efd3c1a7eda6df3f510779928a37"),
];

pub(crate) const GENIUS_ALPHA: Address = address!("9d60a14653b266f9d09e2137a5236f0c112ed42b");
pub(crate) const GENIUS_M52: Address = address!("52609d5dc0f34b4d077dc6f568b17beb0878ab67");
pub(crate) const GENIUS_M52_LAUNCH_AND_BUY: Address =
    address!("070e71483e07b219b0509193a885e514fe4aa33e");
// GeniusConfigurableFactory.launchConfigurable(params, commitment), official ABI 5.2.0.
const GENIUS_M52_LAUNCH: [u8; 4] = [0xe7, 0x91, 0x71, 0x95];

pub(crate) fn launch_payment_spender(address: Address) -> bool {
    [
        FOUR_MANAGER,
        FLAP_PORTAL,
        FLAP_VAULT_PORTAL,
        GENIUS_M52_LAUNCH_AND_BUY,
    ]
    .contains(&address)
}

fn selector(signature: &str) -> [u8; 4] {
    let h = keccak256(signature.as_bytes());
    [h[0], h[1], h[2], h[3]]
}

/// Launchpad contracts may only be used for creating tokens (and Genius' explicit pool creation).
/// Independent swaps go through the wallet-specific UXUY execution contract.
pub(crate) fn platform_guard(to: Address, input: &[u8]) -> Result<bool> {
    let refuse = || {
        Err(ApiError::new(
            "ACTION_NOT_ALLOWED",
            "代币买卖需要本钱包已验证的交易报价".to_string(),
            403,
            false,
        ))
    };
    let sel: [u8; 4] = match input.get(..4) {
        Some(s) => [s[0], s[1], s[2], s[3]],
        None if to == FLAP_VAULT_PORTAL && !input.is_empty() => return refuse(),
        None => return Ok(false),
    };
    const PARAMS: &str = "(string,string,string,string,(string,string,string,string,string),address,uint16,bool,bytes32,bytes32)";
    if (GENIUS_FACTORIES.contains(&to) || to == GENIUS_M52)
        && sel == selector("createGraduatedPool(address)")
    {
        return Ok(false);
    }
    let allowed: Vec<[u8; 4]> = if to == FOUR_MANAGER {
        vec![selector("createToken(bytes,bytes)")]
    } else if to == FLAP_VAULT_PORTAL {
        vec![FLAP_VAULT_V6, FLAP_VAULT_V7]
    } else if to == FLAP_PORTAL {
        vec![
            selector(
                "newTokenV6((string,string,string,uint8,bytes32,uint8,address,uint256,address,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8))",
            ),
            selector(
                "newTokenV7((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint16,uint16,uint64,uint64,address,uint8,(uint8,uint16,address,address,uint256)[4]))",
            ),
        ]
    } else if GENIUS_FACTORIES.contains(&to) {
        vec![
            selector(&format!("launchToken({PARAMS},uint256,address,bool)")),
            selector(&format!(
                "launchToken({PARAMS},uint256,address,bool,address[])"
            )),
        ]
    } else if to == GENIUS_M52 {
        vec![GENIUS_M52_LAUNCH]
    } else if to == GENIUS_M52_LAUNCH_AND_BUY {
        vec![[0x64, 0xdd, 0x8f, 0x09]] // official m5.2 launchConfigurableAndBuy
    } else if to == FOUR_HELPER {
        vec![]
    } else {
        // Genius curves are per token: their buy / sell entry points are refused wherever they are called.
        if [
            "buy(uint256,uint256,address)",
            "sell(uint256,uint256,address)",
            "buy(uint256,uint256,address,uint256)",
            "sell(uint256,uint256,address,uint256)",
        ]
        .iter()
        .any(|signature| sel == selector(signature))
        {
            return refuse();
        }
        return Ok(false);
    };
    if allowed.contains(&sel) {
        Ok(true)
    } else {
        refuse()
    }
}

pub fn denied(a: Address, extra: &[Address]) -> bool {
    RETIRED_ROUTERS.contains(&a) || DEX_ROUTERS.contains(&a) || extra.contains(&a)
}

#[cfg(test)]
mod flap_vault_guard_tests {
    use super::*;

    #[test]
    fn permits_the_two_deployed_vault_creation_selectors_only_on_vault_portal() {
        let v6 = selector(
            "newTokenV6WithVault((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint8,uint16,uint16,uint64,uint64,uint16,uint16,uint16,uint16,uint256,address,address,uint8,address,bytes))",
        );
        let v7 = selector(
            "newTokenV7WithVault((string,string,string,uint8,bytes32,uint8,address,uint256,bytes,bytes32,bytes,uint8,uint8,uint64,uint16,uint16,uint64,address,(uint8,uint16,address,address,uint256)[4],address,bytes))",
        );
        assert_eq!([v6, v7], [FLAP_VAULT_V6, FLAP_VAULT_V7]);
        for method in [v6, v7] {
            assert!(platform_guard(FLAP_VAULT_PORTAL, &method).is_ok());
            assert!(platform_guard(FLAP_PORTAL, &method).is_err());
        }
        for other in [
            &[0x8c, 0xb5, 0x77, 0x2c][..], // Portal.newTokenV6
            &[0x87, 0xef, 0x5b, 0x30][..], // Portal.newTokenV7
            &selector("prepayGas()"),
            &[0x1b, 0x80, 0x62],
        ] {
            assert!(platform_guard(FLAP_VAULT_PORTAL, other).is_err());
        }
    }
}
