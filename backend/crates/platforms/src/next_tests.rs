use super::{abi::*, next::*, *};
use alloy_primitives::{U256, address};
use alloy_sol_types::SolValue;
use axum::{Json, Router, extract::State, routing::post};
use botai_rpc::multicall::{Result3, aggregate3Call};
use std::collections::HashMap;

const TOKEN: Address = address!("8888888888888888888888888888888888888888");
const STOCK: Address = address!("1111111111111111111111111111111111111111");
#[derive(Clone)]
struct Spec {
    stage: u8,
    stock: bool,
    fault: &'static str,
}
async fn rpc(State(spec): State<Spec>, Json(rows): Json<Vec<Value>>) -> Json<Value> {
    Json(json!(rows.into_iter().map(|row| {
        assert_eq!(row["method"], "eth_call");
        assert_eq!(row["params"][1], "0x64");
        let data: Bytes = row["params"][0]["data"].as_str().unwrap().parse().unwrap();
        let results = aggregate3Call::abi_decode(&data).unwrap().calls.into_iter().map(|call| {
            let selector = &call.callData[..4];
            let quote = if spec.stock { STOCK } else { Address::ZERO };
            let bytes = if selector == getLaunchedTokenCall::SELECTOR {
                // Pons registry explicitly says this token is not its launch.
                vec![0u8; 15 * 32]
            } else if selector == tokenCreatorCall::SELECTOR {
                assert_eq!(call.target, LAUNCHPAD);
                tokenCreatorCall::abi_encode_returns(&if spec.stage == 0 || spec.fault == "creator" {Address::ZERO} else {STOCK})
            } else if selector == getTokenStateCall::SELECTOR {
                getTokenStateCall::abi_encode_returns(&U256::from(spec.stage))
            } else if selector == virtualPoolsCall::SELECTOR {
                (U256::from(100), U256::from(100), U256::from(u8::from(spec.stage == 3 && spec.fault != "flag")),
                    U256::from(if spec.fault == "pooltype" { 0 } else {u8::from(spec.stock)}), quote).abi_encode()
            } else if selector == taxConfigCall::SELECTOR {
                assert_eq!(call.target, TOKEN);
                (if spec.fault == "tax" { 1001u16 } else { 100u16 }, 100u16, 0u16, 0u16, STOCK, U256::from(100)).abi_encode()
            } else if selector == NextVenue::poolKeyForCall::SELECTOR {
                assert_eq!(call.target, VENUE);
                NextVenue::poolKeyForCall::abi_encode_returns(&NextPoolKey {
                    currency0: if spec.fault == "currency" { TOKEN } else { quote }, currency1: TOKEN,
                    fee: alloy_primitives::aliases::U24::from(3000), tickSpacing: alloy_primitives::aliases::I24::try_from(60).unwrap(),
                    hooks: if spec.fault == "hook" {STOCK} else {HOOK},
                })
            } else { panic!("unexpected registry call") };
            Result3 { success: true, returnData: bytes.into() }
        }).collect::<Vec<_>>();
        json!({"jsonrpc":"2.0","id":row["id"],"result":Bytes::from(aggregate3Call::abi_encode_returns(&results))})
    }).collect::<Vec<_>>()))
}
async fn inspect(spec: Spec) -> Result<Value> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async {
        axum::serve(
            listener,
            Router::new().route("/", post(rpc)).with_state(spec),
        )
        .await
        .unwrap()
    });
    let platforms = Platforms::new(Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        HashMap::from([(Chain::Robinhood, url)]),
    ));
    let result = platforms.inspect(Chain::Robinhood, TOKEN, Some(100)).await;
    server.abort();
    result
}
#[tokio::test]
async fn next_is_registry_bound_and_tracks_native_stock_migration_and_v4() {
    for stock in [false, true] {
        for stage in 0..=3 {
            let row = inspect(Spec {
                stage,
                stock,
                fault: "",
            })
            .await
            .unwrap();
            if stage == 0 {
                assert_eq!(row["platform"], "external");
                assert_eq!(row["venue"], "okx");
                continue;
            }
            assert_eq!(row["platform"], "next");
            assert_eq!(
                row["pairToken"],
                if stock { STOCK } else { Address::ZERO }.to_checksum(None)
            );
            assert_eq!(
                row["venue"],
                match stage {
                    1 => "curve",
                    2 => "blocked",
                    _ => "v4",
                }
            );
            assert_eq!(row["conditionalDividendBps"], 100);
            if stage == 3 {
                assert_eq!(row["sellHookData"], "0x4c0fa25a");
                assert_eq!(row["poolKey"]["hooks"], HOOK.to_checksum(None));
            }
        }
    }
}
#[tokio::test]
async fn next_refuses_inconsistent_registry_or_unrecognized_hook() {
    for fault in ["creator", "tax", "flag", "pooltype", "currency", "hook"] {
        assert!(
            inspect(Spec {
                stage: 3,
                stock: true,
                fault
            })
            .await
            .is_err(),
            "{fault}"
        );
    }
    assert!(
        inspect(Spec {
            stage: 4,
            stock: false,
            fault: ""
        })
        .await
        .is_err()
    );
}
