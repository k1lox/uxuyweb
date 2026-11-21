mod launch_fee;

use crate::{
    issued::IssuedRoutes,
    route::{RoutePlan, Side},
    submit::{self, IERC20Calls},
};
use alloy_consensus::{SignableTransaction, TxEnvelope, TxLegacy};
use alloy_eips::eip2718::Encodable2718;
use alloy_primitives::{Address, Bytes, Signature, TxKind, U256, address};
use alloy_sol_types::SolCall;
use serde_json::{Value, json};

const ROUTER: Address = Address::repeat_byte(1);
const SPENDER: Address = Address::repeat_byte(2);
const TOKEN: Address = Address::repeat_byte(3);

fn signed(to: TxKind, value: u64, input: Vec<u8>, chain: u64) -> String {
    signed_at(7, 3, to, value, input, chain)
}

pub(crate) fn signed_at(
    signer: u8,
    nonce: u64,
    to: TxKind,
    value: u64,
    input: Vec<u8>,
    chain: u64,
) -> String {
    let key = k256::ecdsa::SigningKey::from_slice(&[signer; 32]).unwrap();
    let tx = TxLegacy {
        chain_id: Some(chain),
        nonce,
        gas_price: 100_000_000,
        gas_limit: 300_000,
        to,
        value: U256::from(value),
        input: Bytes::from(input),
    };
    let hash = tx.signature_hash();
    let (sig, recid) = key.sign_prehash_recoverable(hash.as_slice()).unwrap();
    let sig = Signature::new(
        U256::from_be_slice(&sig.r().to_bytes()),
        U256::from_be_slice(&sig.s().to_bytes()),
        recid.is_y_odd(),
    );
    let env: TxEnvelope = tx.into_signed(sig).into();
    format!("0x{}", alloy_primitives::hex::encode(env.encoded_2718()))
}

#[test]
fn configured_rpc_accepts_https_and_keeps_fork_traffic_local() {
    let config = |extra: &str| -> crate::config::Config { toml::from_str(extra).unwrap() };
    let local = "http://127.0.0.1:8545/";
    let remote = "https://rpc.example.com/bsc";
    assert_eq!(config("").rpc_endpoint().unwrap().as_str(), local);
    assert_eq!(
        config(&format!("rpc_url = '{remote}'"))
            .rpc_endpoint()
            .unwrap()
            .as_str(),
        remote
    );
    let relay = "bundle_local_relay = 'http://127.0.0.1:8546'";
    assert_eq!(config(relay).rpc_endpoint().unwrap().as_str(), local);
    assert!(
        config(&format!("rpc_url = '{remote}'\n{relay}"))
            .rpc_endpoint()
            .is_err()
    );
    for bad in [
        "http://rpc.example.com",
        "file:///etc/hosts",
        "https://user:pass@rpc.example.com",
        "https://rpc.example.com/#fragment",
    ] {
        assert!(config(&format!("rpc_url = '{bad}'")).rpc_endpoint().is_err());
    }
    let mixed = config("[bundle]\nauthorization = 'test-only'");
    assert!(mixed.rpc_endpoint().is_err());
}

pub(crate) fn plan(side: Side) -> RoutePlan {
    let key = k256::ecdsa::SigningKey::from_slice(&[7; 32]).unwrap();
    RoutePlan {
        steps:vec![], legs: vec![], approvals: vec![],
        source: "uxuy",
        chain_id: 56,
        quote_scope: Some("wallet"),
        side,
        amount: "123".into(),
        wallet: Address::from_public_key(key.verifying_key()),
        to: ROUTER,
        spender: SPENDER,
        token: TOKEN,
        settlement_token: None,
        settlement_decimals: None,
        data: Bytes::from(vec![0x51, 3, 0xaa, 0xfa, 7]),
        value: if side == Side::Buy { "123" } else { "0" }.into(),
        pools: vec![],
        dexes: vec![],
        quote_out: "5000".into(),
        min_out: "4950".into(),
        fee: "0".into(),
        slippage_ppm: 10000,
        price_impact_percent: 0.1,
        adverse_price_impact_percent: 0.1,
        deadline: crate::now() + 60,
        gas_limit: 250000,
        gas_estimated: true,
        executed: true,
        simulation: "uxuy",
    }
}

#[test]
fn signed_swaps_require_the_issued_wallet_target_value_data_and_deadline() {
    let issued = IssuedRoutes::default();
    let mut quote = plan(Side::Buy);
    let submit = |who, to, amount, input: Vec<u8>, chain| {
        submit::checked_bundle(
            &[signed_at(who, 0, TxKind::Call(to), amount, input, chain)],
            &issued,
            ROUTER,
            SPENDER,
            &[],
        )
        .is_ok()
    };
    let data = quote.data.to_vec();
    assert!(!submit(7, ROUTER, 123, data.clone(), 56));
    quote.executed = false;
    issued.record(&quote).unwrap();
    assert!(!submit(7, ROUTER, 123, data.clone(), 56));
    quote.executed = true;
    quote.deadline = crate::now();
    issued.record(&quote).unwrap();
    assert!(!submit(7, ROUTER, 123, data.clone(), 56));
    quote.deadline += 60;
    issued.record(&quote).unwrap();
    assert!(submit(7, ROUTER, 123, data.clone(), 56));
    assert!(!submit(8, ROUTER, 123, data.clone(), 56));
    assert!(!submit(7, ROUTER, 122, data.clone(), 56));
    assert!(!submit(7, ROUTER, 123, vec![1, 2, 3, 4], 56));
    assert!(!submit(7, TOKEN, 123, data.clone(), 56));
    assert!(!submit(7, ROUTER, 123, data, 1));
}

#[test]
fn sell_approvals_are_exact_and_bound_to_wallet_token_and_spender() {
    let issued = IssuedRoutes::default();
    let quote = plan(Side::Sell);
    let approve = |who, to, spender, amount| {
        signed_at(
            who,
            0,
            TxKind::Call(to),
            0,
            IERC20Calls::approveCall { spender, amount }.abi_encode(),
            56,
        )
    };
    let check = |raw| submit::checked_bundle(&[raw], &issued, ROUTER, SPENDER, &[]).is_ok();
    let amount = U256::from(123u64);
    assert!(!check(approve(7, TOKEN, SPENDER, amount)));
    issued.record(&quote).unwrap();
    assert!(check(approve(7, TOKEN, SPENDER, amount)));
    assert!(!check(approve(7, TOKEN, SPENDER, U256::MAX)));
    assert!(!check(approve(8, TOKEN, SPENDER, amount)));
    assert!(!check(approve(7, Address::repeat_byte(9), SPENDER, amount)));
    assert!(!check(approve(7, TOKEN, ROUTER, amount)));
    assert!(check(approve(7, TOKEN, SPENDER, U256::ZERO)));
}

#[test]
fn verifies_dart_wallet_transfers_and_rejects_stale_dart_swaps() {
    let f: Value =
        serde_json::from_str(include_str!("../tests/fixtures/dart-signed.json")).unwrap();
    let check = |field: &str| {
        submit::checked_bundle(
            &[f[field].as_str().unwrap().into()],
            &IssuedRoutes::default(),
            ROUTER,
            SPENDER,
            &[],
        )
        .is_ok()
    };
    assert!(check("native"));
    assert!(!check("buy"));
    assert!(!check("approve"));
}

#[test]
fn migrating_legacy_settings_never_enables_old_swap_destinations() {
    let text = r#"listen="127.0.0.1:3295"
router="0x070D82B10579074860D1ca4D9a549D9e53B0537d"
skip_router_check=true
[okx]
api_key="unused"
[platform_routers]
four="unused"
"#;
    let settings = crate::config::Config::parse(text).unwrap();
    assert_eq!(settings.listen, "127.0.0.1:3295");
    assert!(settings.uxuy.is_none());
    settings.validate().unwrap();
    let explicit = format!(
        "{text}\n[uxuy]\nrouter='{:#x}'\napproval_spender='{:#x}'\nnative_token='{:#x}'\napp_id_file='synthetic'\nsigning_key_file='synthetic'\n",
        submit::RETIRED_ROUTERS[4],
        SPENDER,
        Address::ZERO
    );
    assert!(
        crate::config::Config::parse(&explicit)
            .unwrap()
            .validate()
            .is_err()
    );
}

#[test]
fn official_steps_require_the_entire_unexpired_order_in_order_and_one_signer() {
    use crate::route::RouteLeg;
    let issued = IssuedRoutes::default();
    let mut quote = plan(Side::Buy);
    quote.source = "official";
    quote.simulation = "official";
    quote.dexes = vec!["four".into()];
    let make = |kind, to, data: Vec<u8>, value: &str| RouteLeg {
        kind,
        to,
        data: data.into(),
        value: value.into(),
        gas_limit: 300_000,
        token_in: Address::ZERO,
        token_out: TOKEN,
        amount_in: "123".into(),
        min_out: "99".into(),
        recipient: quote.wallet,
    };
    quote.legs = vec![
        make("conversion", ROUTER, vec![0xaa, 0x01, 0x02, 0x03], "123"),
        make(
            "official",
            submit::FOUR_MANAGER,
            vec![0xbb, 0x01, 0x02, 0x03],
            "0",
        ),
    ];
    let sign = |index: usize, who, nonce, value| {
        let leg = &quote.legs[index];
        signed_at(
            who,
            nonce,
            TxKind::Call(leg.to),
            value,
            leg.data.to_vec(),
            56,
        )
    };
    let first = sign(0, 7, 0, 123);
    let second = sign(1, 7, 1, 0);
    let check = |raw: &[String]| submit::checked_bundle(raw, &issued, ROUTER, SPENDER, &[]);
    assert!(check(&[first.clone(), second.clone()]).is_err());
    quote.simulation = "approve_then_swap";
    issued.record(&quote).unwrap();
    assert!(check(&[first.clone(), second.clone()]).is_err());
    quote.simulation = "official";
    issued.record(&quote).unwrap();
    assert!(check(&[first.clone(), second.clone()]).unwrap().1);
    assert!(check(std::slice::from_ref(&first)).is_err());
    assert!(check(std::slice::from_ref(&second)).is_err());
    assert!(check(&[sign(1, 7, 0, 0), sign(0, 7, 1, 123)]).is_err());
    assert!(check(&[first.clone(), sign(1, 8, 1, 0)]).is_err());
    assert!(check(&[first.clone(), sign(1, 7, 2, 0)]).is_err());
    assert!(check(&[sign(0, 7, 0, 1), second.clone()]).is_err());
    let intervening = signed_at(8, 0, TxKind::Call(TOKEN), 1, vec![], 56);
    assert!(check(&[first, intervening, second]).is_err());
}

#[test]
fn inner_grants_bind_market_owner_asset_spender_order_budget_and_expiry() {
    let issued = IssuedRoutes::default();
    let mut quote = plan(Side::Sell);
    quote.source = "official";
    quote.dexes = vec!["genius".into()];
    quote.executed = false;
    let collateral = Address::repeat_byte(17);
    quote.approvals = vec![crate::route::RouteApproval {
        token: collateral,
        spender: SPENDER,
        amount: "13".into(),
        missing: true,
        reset: false,
    }];
    issued.record(&quote).unwrap();
    let check = |wallet, token, asset, spender, amount: u64, orders, now| {
        issued.inner_budget(
            wallet,
            token,
            "genius",
            asset,
            spender,
            U256::from(amount),
            orders,
            now,
        )
    };
    let now = crate::now();
    assert!(check(quote.wallet, TOKEN, collateral, SPENDER, 13, 1, now));
    assert!(!check(quote.wallet, TOKEN, collateral, SPENDER, 14, 1, now));
    assert!(check(quote.wallet, TOKEN, collateral, SPENDER, 26, 2, now));
    assert!(!check(quote.wallet, TOKEN, collateral, SPENDER, 27, 2, now));
    assert!(!check(quote.wallet, TOKEN, collateral, SPENDER, 1, 0, now));
    assert!(!check(
        quote.wallet,
        TOKEN,
        collateral,
        SPENDER,
        1,
        10_001,
        now
    ));
    assert!(!check(TOKEN, TOKEN, collateral, SPENDER, 13, 1, now));
    assert!(!check(
        quote.wallet,
        collateral,
        collateral,
        SPENDER,
        13,
        1,
        now
    ));
    assert!(!check(quote.wallet, TOKEN, TOKEN, SPENDER, 13, 1, now));
    assert!(!check(quote.wallet, TOKEN, collateral, ROUTER, 13, 1, now));
    let expiry = quote.deadline;
    quote.deadline += 60;
    quote.approvals[0].amount = "5".into();
    issued.record(&quote).unwrap();
    assert!(!check(
        quote.wallet,
        TOKEN,
        collateral,
        SPENDER,
        13,
        1,
        expiry
    ));
    assert!(check(
        quote.wallet,
        TOKEN,
        collateral,
        SPENDER,
        5,
        1,
        expiry
    ));
}
