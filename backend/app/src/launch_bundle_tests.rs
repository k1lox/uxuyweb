use super::*;
use crate::{config::WBNB, route::Planner, rpc::Rpc, uxuy::Uxuy};

const OWNER: Address = Address::repeat_byte(10);
const TOKEN: Address = Address::repeat_byte(11);
fn flap(amount: u64, min: u64) -> Vec<u8> {
    swapExactInputV3Call {
        swap: FlapBuy {
            inputToken: Address::ZERO,
            outputToken: TOKEN,
            amount: U256::from(amount),
            minOutput: U256::from(min),
            permitData: Bytes::new(),
            extensionData: Bytes::new(),
        },
    }
    .abi_encode()
}
#[test]
fn genius_block_capacity_uses_each_signed_ceiling_and_prior_actual_usage() {
    let calls = [json!({"gas":"0xc8"}), json!({"gas":"0xc8"})];
    let rows = [json!({"gasUsed":"0x64"}), json!({"gasUsed":"0xf"}), json!({"gasUsed":"0x64"})];
    assert!(check_block_gas(300, &calls, &rows, &[0, 2]).is_ok());
    assert!(check_block_gas(299, &calls, &rows, &[0, 2]).is_err());
}

#[test]
fn isolated_native_order_requires_an_official_creation_and_an_exact_buy() {
    let mut b = LaunchBundle::default();
    let call = flap(5, 2);
    assert!(
        !b.record_call(FLAP_PORTAL, &call, U256::from(5), 1_000_000, OWNER, &[], 10)
            .unwrap()
    );
    let (f, now) = (Platform::Flap, 10);
    assert!(
        step(f, FLAP_PORTAL, U256::from(5), &call, OWNER, now)
            .unwrap()
            .is_some()
    );
    assert!(step(f, FLAP_PORTAL, U256::from(4), &call, OWNER, now).is_err());
    assert!(step(f, FLAP_PORTAL, U256::from(5), &flap(5, 0), OWNER, now).is_err());
    let mut changed = call.clone();
    changed.push(1);
    assert!(step(f, FLAP_PORTAL, U256::from(5), &changed, OWNER, now).is_err());
    assert!(
        step(f, FOUR_MANAGER, U256::from(5), &call, OWNER, now)
            .unwrap()
            .is_none()
    );
}
#[test]
fn direct_four_curve_and_pancake_bind_the_receiver_amount_path_and_expiration() {
    let call = buyTokenAMAPCall {
        token: TOKEN,
        recipient: OWNER,
        funds: U256::from(5),
        minAmount: U256::from(2),
    }
    .abi_encode();
    assert!(
        step(
            Platform::Four,
            FOUR_MANAGER,
            U256::from(5),
            &call,
            TOKEN,
            100
        )
        .is_err()
    );
    let trade = |path, to, deadline| {
        swapExactETHForTokensSupportingFeeOnTransferTokensCall {
            minOut: U256::ONE,
            path,
            to,
            deadline: U256::from(deadline),
        }
        .abi_encode()
    };
    assert!(
        step(
            Platform::Four,
            PANCAKE,
            U256::ONE,
            &trade(vec![WBNB, TOKEN], OWNER, 200u64),
            OWNER,
            100
        )
        .unwrap()
        .is_some()
    );
    for data in [
        trade(vec![WBNB, TOKEN], TOKEN, 200),
        trade(vec![WBNB, TOKEN], OWNER, 99),
        trade(vec![WBNB, OWNER, TOKEN], OWNER, 200),
    ] {
        assert!(step(Platform::Four, PANCAKE, U256::ONE, &data, OWNER, 100).is_err());
    }
}
#[test]
fn permit2_approval_is_private_and_expires_with_the_simulated_grant() {
    let now = crate::now();
    let amount = U256::from(34);
    let expiry = now + 600;
    let data = crate::launch_approval::permit_data(TOKEN, amount, expiry).unwrap();
    let issued = crate::issued::IssuedRoutes::default();
    issued
        .record_private_approvals(&[(OWNER, PERMIT2, keccak256(&data))], now + 90)
        .unwrap();
    assert!(issued.private_approval(OWNER, PERMIT2, &data, now));
    assert!(!issued.private_approval(TOKEN, PERMIT2, &data, now));
    assert!(!issued.private_approval(OWNER, PERMIT2, &data, now + 90));
    assert!(crate::launch_approval::permit_data(TOKEN, U256::MAX, expiry).is_err());
    assert!(crate::launch_approval::permit_data(TOKEN, amount, now + 1234).is_err());
}
#[tokio::test]
#[ignore = "explicit local Anvil fork and public transaction fixture"]
async fn real_official_launch_and_buys_verify_on_the_local_fork() {
    let url = std::env::var("UXUY_LAUNCH_PROOF_FORK").unwrap();
    let parsed = reqwest::Url::parse(&url).unwrap();
    assert_eq!(parsed.scheme(), "http");
    assert_eq!(parsed.host_str(), Some("127.0.0.1"));
    let src = std::fs::read_to_string(std::env::var("UXUY_LAUNCH_PROOF_FIXTURE").unwrap()).unwrap();
    let fixture: Value = serde_json::from_str(&src).unwrap();
    let rpc = Rpc::new(reqwest::Client::new(), &url);
    let info = rpc.call("anvil_nodeInfo", json!([])).await.unwrap();
    assert_eq!(
        info["forkConfig"]["forkBlockNumber"],
        fixture["blockNumber"]
    );
    let planner = Planner {
        platforms: None,
        uxuy: Uxuy::disabled(),
        rpc: Some(rpc.clone()),
        router: Address::ZERO,
        spender: Address::ZERO,
        native: Address::ZERO,
        max_impact_percent: 7.,
        default_slippage_bps: 50,
        deadline_seconds: 120,
    };
    // Seed the fixture's synthetic token balances/allowances only on this checked
    // local historical node. The production submission uses the real pre-state.
    if let Some(overrides) = fixture["stateOverrides"].as_object() {
        for (account, state) in overrides {
            if let Some(slots) = state["stateDiff"].as_object() {
                for (key, value) in slots {
                    rpc.call("anvil_setStorageAt", json!([account, key, value]))
                        .await
                        .unwrap();
                }
            }
        }
    }
    let mut proof = LaunchBundle::default();
    for row in fixture["transactions"].as_array().unwrap() {
        // Fund only the isolated Anvil account used for this historical simulation.
        // Production proof never substitutes balances or chain state.
        let reply: Value = reqwest::Client::new().post(&url)
            .timeout(std::time::Duration::from_secs(120))
            .json(&json!({"jsonrpc":"2.0","id":1,"method":"anvil_setBalance","params":[row["from"],"0x21e19e0c9bab2400000"]}))
            .send().await.unwrap().json().await.unwrap();
        assert!(reply["error"].is_null(), "{reply}");

        let hex = |key: &str| {
            U256::from_str_radix(row[key].as_str().unwrap().trim_start_matches("0x"), 16).unwrap()
        };
        proof
            .record_call(
                address_field(&row["to"]).unwrap(),
                &row["data"].as_str().unwrap().parse::<Bytes>().unwrap(),
                hex("value"),
                hex("gas").to::<u64>(),
                address_field(&row["from"]).unwrap(),
                &[],
                fixture["now"].as_u64().unwrap_or_else(crate::now),
            )
            .unwrap();
    }
    assert!(!proof.steps.is_empty());
    proof.verify(&planner, &rpc).await.unwrap();
    // Changing the proven target can never qualify the same orders for another token.
    if let Some(Step::Buy { token, .. }) = proof
        .steps
        .iter_mut()
        .map(|(_, s)| s)
        .find(|s| matches!(s, Step::Buy { .. }))
    {
        *token = Some(Address::repeat_byte(99));
    }
    assert!(proof.verify(&planner, &rpc).await.is_err());
}
