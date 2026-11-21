use super::*;
use crate::{App, route::Planner, uxuy::Uxuy};
use axum::{Json, Router, routing::post};

const FOUR: Address = address!("5c952063c7fc8610ffdb798152d69f0b9550762b");
fn creation() -> String {
    signed(
        TxKind::Call(FOUR),
        1,
        alloy_primitives::keccak256("createToken(bytes,bytes)")[..4].to_vec(),
        56,
    )
}

#[test]
fn historical_fee_destinations_are_blocked_for_payments_and_approvals() {
    for old in submit::RETIRED_ROUTERS {
        for (to, data) in [
            (old, Vec::new()),
            (
                old,
                alloy_primitives::keccak256("payLaunchFee()")[..4].to_vec(),
            ),
            (
                TOKEN,
                IERC20Calls::approveCall {
                    spender: old,
                    amount: U256::ONE,
                }
                .abi_encode(),
            ),
        ] {
            let raw = signed(TxKind::Call(to), u64::from(to == old), data, 56);
            assert!(
                submit::checked_bundle(&[raw], &IssuedRoutes::default(), ROUTER, SPENDER, &[])
                    .is_err()
            );
        }
    }
}

#[test]
fn official_prebuy_approval_is_private_exact_and_bound_to_the_checked_wallet() {
    let issued = IssuedRoutes::default();
    let dev = plan(Side::Sell).wallet;
    let amount = U256::from(123);
    let check = |who, spender, amount| {
        let raw = signed_at(
            who,
            0,
            TxKind::Call(TOKEN),
            0,
            IERC20Calls::approveCall { spender, amount }.abi_encode(),
            56,
        );
        submit::checked_bundle(&[raw], &issued, ROUTER, SPENDER, &[]).map(|(_, private)| private)
    };
    for spender in [
        submit::FOUR_MANAGER,
        submit::FLAP_PORTAL,
        submit::FLAP_VAULT_PORTAL,
        submit::GENIUS_M52_LAUNCH_AND_BUY,
    ] {
        assert!(check(7, spender, amount).is_err());
        issued
            .record_approvals(TOKEN, spender, &[(dev, amount)], crate::now() + 60)
            .unwrap();
        assert_eq!(check(7, spender, amount).unwrap(), true);
        assert!(check(8, spender, amount).is_err());
        assert!(check(7, spender, amount + U256::ONE).is_err());
        assert!(check(7, spender, U256::ZERO).is_err());
        assert!(check(7, spender, U256::MAX).is_err());
    }
}

#[test]
fn alpha_payment_requires_the_preceding_creation_from_the_same_wallet_and_factory() {
    let issued = IssuedRoutes::default();
    let registry = address!("9d60a14653b266f9d09e2137a5236f0c112ed42b");
    let create = signed_at(
        7,
        0,
        TxKind::Call(submit::GENIUS_M52),
        0,
        vec![0xe7, 0x91, 0x71, 0x95],
        56,
    );
    let pay = |who, nonce, factory, token, value| {
        signed_at(
            who,
            nonce,
            TxKind::Call(registry),
            value,
            IERC20Calls::promoteCall { factory, token }.abi_encode(),
            56,
        )
    };
    let ok = pay(7, 1, submit::GENIUS_M52, TOKEN, 22);
    let check = |raws: &[String]| {
        submit::checked_bundle(raws, &issued, ROUTER, SPENDER, &[])
            .map(|(_, is_private)| is_private)
    };
    assert!(check(std::slice::from_ref(&ok)).is_err());
    assert!(check(&[create.clone(), ok.clone()]).unwrap());
    for bad in [
        pay(8, 1, submit::GENIUS_M52, TOKEN, 22),
        pay(7, 1, submit::FOUR_MANAGER, TOKEN, 22),
        pay(7, 1, submit::GENIUS_M52, Address::ZERO, 22),
        pay(7, 1, submit::GENIUS_M52, TOKEN, 0),
    ] {
        assert!(check(&[create.clone(), bad]).is_err());
    }
    assert!(check(&[create, ok, pay(7, 2, submit::GENIUS_M52, TOKEN, 22)]).is_err());
}

#[tokio::test]
async fn private_creation_is_submitted_alone_and_retired_payments_never_reach_relay() {
    let relay = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_url = format!("http://{}", relay.local_addr().unwrap());
    let (sent, mut requests) = tokio::sync::mpsc::unbounded_channel();
    let mock = Router::new().route(
        "/",
        post(move |Json(body): Json<Value>| {
            sent.send(body).unwrap();
            async { Json(json!({"result":{"bundleHash":format!("0x{}", "a".repeat(64))}})) }
        }),
    );
    let relay_server = tokio::spawn(async move { axum::serve(relay, mock).await.unwrap() });
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let offline = "http://127.0.0.1:1";
    let rpc = botai_rpc::Rpc::with_urls(
        http.clone(),
        [(botai_core::Chain::Bsc, offline.to_owned())]
            .into_iter()
            .collect(),
    );
    let platforms = botai_platforms::Platforms::new(rpc.clone());

    let store = botai_transactions::Store::open(":memory:").unwrap();
    let app = App {
        planner: Planner {
            platforms: None,
            uxuy: Uxuy::disabled(),
            rpc: None,
            router: ROUTER,
            spender: SPENDER,
            native: Address::ZERO,
            max_impact_percent: 7.,
            default_slippage_bps: 100,
            deadline_seconds: 180,
        },
        rpc: crate::rpc::Rpc::new(http.clone(), offline),
        router: ROUTER,
        rpc_provider: "local-fork",
        node_status: Default::default(),
        denied: vec![],
        issued: IssuedRoutes::default(),
        route_enabled: false,
        integrations: botai_integrations::Integrations::new(http.clone(), rpc.clone()),
        platforms,
        chain_rpc: rpc.clone(),
        transactions: botai_transactions::Transactions::new(
            store.clone(),
            rpc,
            http.clone(),
            "mock".into(),
        )
        .with_local_relay(&relay_url)
        .unwrap(),
    };
    let node = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base = format!("http://{}/api/v1", node.local_addr().unwrap());
    let server = tokio::spawn(async move { axum::serve(node, crate::routes(app)).await.unwrap() });
    let config = async || -> Value {
        http.get(format!("{base}/config"))
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap()
    };
    let submit = async |path: &str, txs: &[String]| -> Value {
        let mut body = json!({"transactions":txs});
        if path == "bundles" {
            body["maxBlockNumber"] = json!(100);
        }
        http.post(format!("{base}/{path}"))
            .json(&body)
            .send()
            .await
            .unwrap()
            .json()
            .await
            .unwrap()
    };

    let info = config().await;
    assert_eq!(info["routeSource"], "uxuy");
    assert_eq!(info["routeEnabled"], false);
    assert_eq!(info["approvalSpender"], json!(SPENDER));
    for old in [
        "launchServiceFeeWei",
        "launchFeeContract",
        "feeRate",
        "platformRouters",
    ] {
        assert!(info.get(old).is_none());
    }
    let create = creation();
    let legacy = signed_at(
        7,
        4,
        TxKind::Call(submit::RETIRED_ROUTERS[4]),
        1,
        alloy_primitives::keccak256("payLaunchFee()")[..4].to_vec(),
        56,
    );
    assert_eq!(
        submit("transactions/bsc", std::slice::from_ref(&create)).await["notSubmitted"],
        true
    );
    assert_eq!(
        submit("bundles", &[create.clone(), legacy]).await["notSubmitted"],
        true
    );
    assert!(requests.try_recv().is_err());
    assert_eq!(
        submit("bundles", std::slice::from_ref(&create)).await["ok"],
        true
    );
    let call = requests.try_recv().unwrap();
    assert_eq!(call["params"]["no_merge"], true);
    assert_eq!(call["params"]["txs"], json!([&create[2..]]));
    server.abort();
    relay_server.abort();
}
