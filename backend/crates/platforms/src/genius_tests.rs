use super::{abi::*, *};
use alloy_primitives::{B256, U256, address};
use axum::{Json, Router, extract::State, routing::post};
use botai_rpc::multicall::{Result3, aggregate3Call};
use std::collections::HashMap;

const TOKEN: Address = address!("0000000000000000000000000000000000000011");
const CURVE: Address = address!("0000000000000000000000000000000000000022");
const QUOTE: Address = address!("0000000000000000000000000000000000000033");
const FACTORIES: [Address; 3] = [
    address!("78eae9537c0ef90dfe9b7ae964682fe8138afe31"),
    address!("37ee8aee29c5efd3c1a7eda6df3f510779928a37"),
    address!("52609d5dc0f34b4d077dc6f568b17beb0878ab67"),
];
const HOOKS: [Address; 3] = [
    address!("ff17f41c5efd6cce944af0912f300097d62df5c9"),
    address!("8e6f8ebbd62b60085b703c40b460dae802edc51b"),
    address!("2c908012aba847735b6f43654265b02e3d37d74a"),
];
#[derive(Clone)]
struct Spec {
    version: usize,
    phase: u8,
    quote: Address,
    fault: &'static str,
}
fn answer(s: &Spec, target: Address, data: &[u8]) -> Option<Vec<u8>> {
    let selector = &data[..4];
    if selector == getLaunchedTokenCall::SELECTOR {
        assert!(FACTORIES.contains(&target));
        return Some(getLaunchedTokenCall::abi_encode_returns(&LaunchRecord {
            token: if s.fault == "token" { QUOTE } else { TOKEN },
            curve: CURVE,
            deployer: TOKEN,
            creatorFeeRecipient: TOKEN,
            pairToken: s.quote,
            graduationThreshold: U256::from(15),
            poolFee: Default::default(),
            tickSpacing: Default::default(),
            creatorTaxBps: 0,
            buybackEnabled: true,
            phase: s.phase,
            sweptQuote: U256::ZERO,
            sweptTokens: U256::ZERO,
            sweptAt: U256::ZERO,
            exists: target == FACTORIES[s.version],
        }));
    }
    if selector == symbolCall::SELECTOR {
        return Some(symbolCall::abi_encode_returns(&"FIXTURE".into()));
    }
    if selector == decimalsCall::SELECTOR {
        return Some(decimalsCall::abi_encode_returns(&if target == TOKEN {
            18
        } else {
            6
        }));
    }
    if selector == pairTokenEconomicsCall::SELECTOR {
        assert_eq!(target, FACTORIES[s.version]);
        return Some(pairTokenEconomicsCall::abi_encode_returns(
            &pairTokenEconomicsReturn {
                phantomQuote: U256::from(6),
                graduationThreshold: U256::from(15),
                decimals: if s.fault == "decimals" { 18 } else { 6 },
            },
        ));
    }
    if selector == Curve::getReservesCall::SELECTOR {
        return Some(Curve::getReservesCall::abi_encode_returns(
            &Curve::getReservesReturn {
                quoteReserve: U256::from(600),
                tokenReserve: U256::from(1000),
            },
        ));
    }
    if selector == Curve::feeBpsCall::SELECTOR {
        return Some(Curve::feeBpsCall::abi_encode_returns(&U256::from(200)));
    }
    if selector == Curve::creatorRateCall::SELECTOR {
        assert_eq!(s.version, 2);
        let buy = Curve::creatorRateCall::abi_decode(data).unwrap().buy;
        return Some(Curve::creatorRateCall::abi_encode_returns(&if buy {
            120
        } else {
            350
        }));
    }
    if selector == Curve::sellableTokensCall::SELECTOR {
        return Some(Curve::sellableTokensCall::abi_encode_returns(&U256::from(
            if s.fault == "empty" { 0 } else { 200 },
        )));
    }
    if selector == Curve::currentSnipeTaxBpsCall::SELECTOR {
        return Some(Curve::currentSnipeTaxBpsCall::abi_encode_returns(
            &U256::from(8100),
        ));
    }
    if selector == Curve::creatorTaxBpsCall::SELECTOR {
        assert_ne!(s.version, 2);
        return Some(Curve::creatorTaxBpsCall::abi_encode_returns(&U256::ZERO));
    }
    if selector == Curve::realQuoteReserveCall::SELECTOR {
        return Some(Curve::realQuoteReserveCall::abi_encode_returns(
            &U256::from(100),
        ));
    }
    if selector == poolKeyForCall::SELECTOR {
        assert_eq!(target, FACTORIES[s.version]);
        return Some(poolKeyForCall::abi_encode_returns(&InfinityKey {
            currency0: TOKEN,
            currency1: s.quote,
            hooks: HOOKS[if s.fault == "hook" {
                (s.version + 1) % HOOKS.len()
            } else {
                s.version
            }],
            poolManager: address!("a0ffb9c1ce1fe56963b0321b32e7a0302114058b"),
            fee: Default::default(),
            parameters: B256::ZERO,
        }));
    }
    None
}
async fn rpc(State(s): State<Spec>, Json(rows): Json<Vec<Value>>) -> Json<Value> {
    Json(json!(rows.into_iter().map(|row| {
        assert_eq!(row["method"], "eth_call"); assert_eq!(row["params"][1], "0x64");
        let data = row["params"][0]["data"].as_str().unwrap().parse::<Bytes>().unwrap();
        let returns = aggregate3Call::abi_decode(&data).unwrap().calls.into_iter().map(|call| {
            let r = answer(&s, call.target, &call.callData);
            Result3 { success: r.is_some(), returnData: r.unwrap_or_default().into() }
        }).collect::<Vec<_>>();
        json!({"jsonrpc":"2.0","id":row["id"],"result":Bytes::from(aggregate3Call::abi_encode_returns(&returns))})
    }).collect::<Vec<_>>()))
}
async fn inspect(s: Spec) -> Result<Value> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async {
        axum::serve(listener, Router::new().route("/", post(rpc)).with_state(s))
            .await
            .unwrap()
    });
    let p = Platforms::new(Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        HashMap::from([(Chain::Bsc, url)]),
    ));
    let r = p.inspect(Chain::Bsc, TOKEN, Some(100)).await;
    server.abort();
    r
}
#[tokio::test]
async fn genius_versions_native_custom_and_inner_outer_are_identified_by_registry() {
    for version in 0..FACTORIES.len() {
        for phase in [0, 2] {
            for quote in [Address::ZERO, QUOTE] {
                let r = inspect(Spec {
                    version,
                    phase,
                    quote,
                    fault: "",
                })
                .await
                .unwrap();
                assert_eq!(r["platform"], "genius");
                assert_eq!(r["genius"]["version"], ["v1", "v2", "m5.2"][version]);
                if version == 2 {
                    assert_eq!(r["buyTaxBps"], "120");
                    assert_eq!(r["sellTaxBps"], "350");
                    if phase == 0 {
                        assert_eq!(r["genius"]["openingBps"], "8100");
                        assert_eq!(r["genius"]["sellableTokens"], "200");
                    }
                }
                assert_eq!(r["external"], phase == 2);
                assert_eq!(
                    r["genius"]["quoteDecimals"],
                    if quote.is_zero() { 18 } else { 6 }
                );
                if phase == 2 {
                    assert_eq!(
                        r["genius"]["poolKey"]["hooks"],
                        HOOKS[version].to_checksum(None)
                    );
                }
            }
        }
    }
}
#[tokio::test]
async fn genius_wrong_version_hook_token_precision_and_pending_migration_are_rejected() {
    for version in 0..FACTORIES.len() {
        for (phase, fault) in [(0, "token"), (0, "decimals"), (2, "hook"), (1, ""), (3, "")] {
            assert!(
                inspect(Spec {
                    version,
                    phase,
                    quote: QUOTE,
                    fault
                })
                .await
                .is_err()
            );
        }
    }
}

#[tokio::test]
async fn genius_m52_full_curve_waits_for_migration() {
    assert!(
        inspect(Spec {
            version: 2,
            phase: 0,
            quote: QUOTE,
            fault: "empty"
        })
        .await
        .is_err()
    );
}
