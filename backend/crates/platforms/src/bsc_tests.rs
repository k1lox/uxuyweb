use super::{abi::*, *};
use alloy_primitives::{B256, U256, address};
use alloy_sol_types::SolError;
use axum::{Json, Router, extract::State, routing::post};
use botai_rpc::multicall::{Result3, aggregate3Call};
use std::{collections::HashMap, sync::Arc};

const TOKEN: Address = address!("0000000000000000000000000000000000000011");
const QUOTE: Address = address!("0000000000000000000000000000000000000022");
const POOL: Address = address!("0000000000000000000000000000000000000033");
const OTHER: Address = address!("0000000000000000000000000000000000000044");
const FLAP: Address = address!("e2ce6ab80874fa9fa2aae65d277dd6b8e65c9de0");
const HELPER: Address = address!("f251f83e40a78868fcfa3fa4599dad6494e46034");
const FOUR: Address = address!("5c952063c7fc8610ffdb798152d69f0b9550762b");
const FACTORY: Address = address!("ca143ce32fe78f1f7019d7d551a6402fc5350c73");
const WBNB: Address = address!("bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c");
const OPENFOUR_CORE: Address = address!("ebe7b6c1089d9f72ad07f34e36d898e44e5e27f3");
const OPENFOUR_VAULT: Address = address!("0000000000000000000000000000000000000055");

#[derive(Clone)]
struct Spec {
    flap: bool,
    version: u8,
    external: bool,
    quote: Address,
    fault: &'static str,
}
fn response(spec: &Spec, target: Address, data: &[u8]) -> Option<Vec<u8>> {
    let selector = &data[..4];
    let fault = spec.fault;
    if selector == tokensCall::SELECTOR {
        assert_eq!(target, OPENFOUR_CORE);
        let openfour = fault.starts_with("unregistered_openfour");
        return Some(tokensCall::abi_encode_returns(&tokensReturn {
            version: u32::from(openfour),
            creator: OTHER,
            presetId: U256::from(1),
            token: if openfour { TOKEN } else { Address::ZERO },
            name: String::new(),
            symbol: String::new(),
            maxSupply: U256::ZERO,
            saleAmount: U256::ZERO,
            raiseAmount: U256::ZERO,
            quoteAsset: WBNB,
            vault: if openfour { OPENFOUR_VAULT } else { Address::ZERO },
            curveModule: Address::ZERO,
            tradeModule: Address::ZERO,
            migrateModule: Address::ZERO,
            tokenModule: Address::ZERO,
            customData: Address::ZERO,
            createBlock: U256::ZERO,
            exists: openfour,
            paused: false,
            antiSniperEnabled: false,
        }));
    }
    if selector == phaseCall::SELECTOR {
        assert_eq!(target, OPENFOUR_VAULT);
        return Some(phaseCall::abi_encode_returns(&if fault == "unregistered_openfour_migrated" { 3 } else { 1 }));
    }
    if fault.starts_with("unregistered") {
        if selector == getTokenV8SafeCall::SELECTOR {
            return None;
        }
        if selector == getTokenInfoCall::SELECTOR {
            return None;
        }
        if selector == _tokenInfosCall::SELECTOR {
            return Some(vec![0; 13 * 32]);
        }
        if selector == getLaunchedTokenCall::SELECTOR {
            return if fault == "unregistered_genius_error" {
                None
            } else {
                Some(vec![0; 15 * 32])
            };
        }
    }
    if selector == getTokenV8SafeCall::SELECTOR {
        assert_eq!(target, FLAP);
        if !spec.flap {
            return None;
        }
        return Some(getTokenV8SafeCall::abi_encode_returns(&FlapState {
            status: if fault == "stage" {
                3
            } else if spec.external {
                4
            } else {
                1
            },
            reserve: U256::from(1),
            circulatingSupply: U256::from(1),
            price: U256::from(1),
            tokenVersion: spec.version,
            r: U256::from(1),
            h: U256::from(1),
            k: U256::from(1),
            dexSupplyThresh: U256::from(1),
            quoteTokenAddress: spec.quote,
            nativeToQuoteSwapEnabled: false,
            extensionID: if fault == "extension" {
                B256::repeat_byte(1)
            } else {
                B256::ZERO
            },
            buyTaxRate: U256::from(if fault == "tax" { 10000 } else { 200 }),
            sellTaxRate: U256::from(300),
            pool: if fault == "portal_pool" { OTHER } else { POOL },
            progress: U256::ZERO,
            lpFeeProfile: 0,
            dexId: u8::from(fault == "dex"),
        }));
    }
    if selector == getTokenInfoCall::SELECTOR {
        assert_eq!(target, HELPER);
        if spec.flap {
            return None;
        }
        return Some(getTokenInfoCall::abi_encode_returns(&getTokenInfoReturn {
            version: U256::from(if fault == "helper_version" { 1 } else { 2 }),
            tokenManager: if fault == "manager" { OTHER } else { FOUR },
            quote: spec.quote,
            lastPrice: U256::ZERO,
            tradingFeeRate: U256::ZERO,
            minTradingFee: U256::ZERO,
            launchTime: U256::ZERO,
            offers: U256::ZERO,
            maxOffers: U256::ZERO,
            funds: U256::ZERO,
            maxFunds: U256::ZERO,
            liquidityAdded: spec.external,
        }));
    }
    if selector == _tokenInfosCall::SELECTOR {
        assert_eq!(target, FOUR);
        if spec.flap {
            return None;
        }
        return Some(_tokenInfosCall::abi_encode_returns(&_tokenInfosReturn {
            base: if fault == "base" { OTHER } else { TOKEN },
            quote: if fault == "quote" { OTHER } else { spec.quote },
            template: U256::from(spec.version) << 10usize,
            totalSupply: U256::from(u8::from(fault != "supply")),
            maxOffers: U256::ZERO,
            maxRaising: U256::ZERO,
            launchTime: U256::ZERO,
            offers: U256::ZERO,
            funds: U256::ZERO,
            lastPrice: U256::ZERO,
            K: U256::ZERO,
            T: U256::ZERO,
            status: U256::ZERO,
        }));
    }
    if selector == getLaunchedTokenCall::SELECTOR {
        return None;
    }
    if selector == symbolCall::SELECTOR {
        return Some(symbolCall::abi_encode_returns(&"SIX".into()));
    }
    if selector == decimalsCall::SELECTOR {
        return Some(decimalsCall::abi_encode_returns(&if fault == "decimals" {
            37
        } else {
            6
        }));
    }
    if [
        feeRateCall::SELECTOR,
        feeRateBuyCall::SELECTOR,
        feeRateSellCall::SELECTOR,
    ]
    .contains(&selector.try_into().unwrap())
    {
        return Some(feeRateCall::abi_encode_returns(&U256::from(
            if fault == "tax" {
                10000
            } else if spec.version == 5 {
                200
            } else {
                2
            },
        )));
    }
    if selector == getPairCall::SELECTOR {
        assert_eq!(target, FACTORY);
        let args = getPairCall::abi_decode(data).unwrap();
        assert_eq!(args.a, TOKEN);
        assert_eq!(
            args.b,
            if spec.quote.is_zero() {
                WBNB
            } else {
                spec.quote
            }
        );
        return Some(getPairCall::abi_encode_returns(
            &if fault == "missing_pool" {
                Address::ZERO
            } else {
                POOL
            },
        ));
    }
    if selector == mainPoolCall::SELECTOR || selector == pairCall::SELECTOR {
        if fault == "lazy_absent" {
            return None;
        }
        return Some(pairCall::abi_encode_returns(&if fault == "declared_pool" {
            OTHER
        } else if fault == "lazy_zero" {
            Address::ZERO
        } else {
            POOL
        }));
    }
    assert_eq!(target, POOL);
    Some(if selector == token0Call::SELECTOR {
        token0Call::abi_encode_returns(&TOKEN)
    } else if selector == token1Call::SELECTOR {
        token1Call::abi_encode_returns(&if fault == "currency" {
            OTHER
        } else if spec.quote.is_zero() {
            WBNB
        } else {
            spec.quote
        })
    } else if selector == factoryCall::SELECTOR {
        factoryCall::abi_encode_returns(&if fault == "factory" { OTHER } else { FACTORY })
    } else if selector == getReservesCall::SELECTOR {
        getReservesCall::abi_encode_returns(&getReservesReturn {
            reserve0: alloy_primitives::aliases::U112::from(if fault == "empty" {
                0
            } else {
                4000
            }),
            reserve1: alloy_primitives::aliases::U112::from(9000),
            timestamp: 0,
        })
    } else {
        panic!("unexpected selector")
    })
}
async fn rpc(State(spec): State<Arc<Spec>>, Json(rows): Json<Vec<Value>>) -> Json<Value> {
    Json(json!(rows.into_iter().map(|row| {
        assert_eq!(row["method"], "eth_call"); assert_eq!(row["params"][1], "0x64");
        let data = row["params"][0]["data"].as_str().unwrap().parse::<Bytes>().unwrap();
        let returns = aggregate3Call::abi_decode(&data).unwrap().calls.into_iter().map(|call| {
            let result = response(&spec, call.target, &call.callData);
            if call.callData[..4] == getTokenV8SafeCall::SELECTOR && spec.fault.starts_with("unregistered") && spec.fault != "unregistered_flap_error" {
                return Result3 { success: false, returnData: TokenNotFound { token: if spec.fault == "unregistered_wrong_token" {OTHER} else {TOKEN} }.abi_encode().into() };
            }
            Result3 { success: result.is_some(), returnData: result.unwrap_or_default().into() }
        }).collect::<Vec<_>>();
        json!({"jsonrpc":"2.0","id":row["id"],"result":Bytes::from(aggregate3Call::abi_encode_returns(&returns))})
    }).collect::<Vec<_>>()))
}
async fn inspect(spec: Spec) -> Result<Value> {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let app = Router::new()
        .route("/", post(rpc))
        .with_state(Arc::new(spec));
    let server = tokio::spawn(async { axum::serve(listener, app).await.unwrap() });
    let platforms = Platforms::new(Rpc::with_urls(
        reqwest::Client::builder().no_proxy().build().unwrap(),
        HashMap::from([(Chain::Bsc, url)]),
    ));
    let result = platforms.inspect(Chain::Bsc, TOKEN, Some(100)).await;
    server.abort();
    result
}
#[tokio::test]
async fn ordinary_tokens_need_negative_registries_and_keep_real_precision() {
    for fault in [
        "unregistered",
        "unregistered_flap_error",
        "unregistered_genius_error",
        "unregistered_wrong_token",
    ] {
        let result = inspect(Spec {
            flap: false,
            version: 0,
            external: true,
            quote: Address::ZERO,
            fault,
        })
        .await;
        if fault == "unregistered" {
            let value = result.unwrap();
            assert_eq!(value["platform"], "external");
            assert_eq!(value["decimals"], 6);
            assert_eq!(value["external"], true);
        } else {
            assert!(result.is_err(), "{fault}");
        }
    }
}
#[tokio::test]
async fn deprecated_flap_tax_versions_stay_closed() {
    for version in [1, 3, 4, 5] {
        for external in [false, true] {
            let spec = Spec { flap: true, version, external, quote: Address::ZERO, fault: "" };
            assert!(inspect(spec).await.is_err(), "flap version {version} must be refused");
        }
    }
}
#[tokio::test]
async fn openfour_tokens_are_refused_until_they_migrate() {
    let spec = |fault| Spec { flap: false, version: 0, external: true, quote: Address::ZERO, fault };
    let err = inspect(spec("unregistered_openfour_internal")).await.unwrap_err();
    assert!(format!("{err:?}").contains("OpenFour"), "{err:?}");
    let value = inspect(spec("unregistered_openfour_migrated")).await.unwrap();
    assert_eq!(value["platform"], "external");
    assert_eq!(value["external"], true);
}
#[tokio::test]
async fn bsc_official_registry_keeps_versions_precision_and_native_pool_mapping() {
    for (flap, versions) in [(true, vec![2, 6, 7]), (false, vec![0, 5, 8, 9])] {
        for version in versions {
            for external in [false, true] {
                for quote in [Address::ZERO, QUOTE] {
                    let value = inspect(Spec {
                        flap,
                        version,
                        external,
                        quote,
                        fault: "",
                    })
                    .await
                    .unwrap();
                    assert_eq!(value["platform"], if flap { "flap" } else { "four" });
                    assert_eq!(value["decimals"], 6);
                    assert_eq!(value["taxType"], version);
                    assert_eq!(value["external"], external);
                    // Ordinary Four tokens have no tax functions; their tax is zero, not read.
                    assert_eq!(value["buyTaxBps"], if !flap && version == 0 { "0" } else { "200" });
                    assert_eq!(value["quote"], quote.to_checksum(None));
                    if external && !(flap && version != 6) {
                        assert_eq!(value["reserveToken"], "4000");
                        assert_eq!(value["reserveQuote"], "9000");
                    }
                }
            }
        }
    }
    for fault in ["lazy_zero", "lazy_absent"] {
        assert!(
            inspect(Spec {
                flap: false,
                version: 8,
                external: true,
                quote: QUOTE,
                fault
            })
            .await
            .is_ok()
        );
    }
}
#[tokio::test]
async fn bsc_spoofed_registry_unsupported_phases_tax_and_wrong_pools_fail_closed() {
    for (flap, faults) in [
        (
            true,
            vec![
                "stage",
                "extension",
                "dex",
                "portal_pool",
                "declared_pool",
                "tax",
                "decimals",
                "factory",
                "currency",
                "missing_pool",
                "empty",
            ],
        ),
        (
            false,
            vec![
                "helper_version",
                "manager",
                "base",
                "quote",
                "supply",
                "declared_pool",
                "tax",
                "decimals",
                "factory",
                "currency",
                "missing_pool",
                "empty",
            ],
        ),
    ] {
        for fault in faults {
            assert!(
                inspect(Spec {
                    flap,
                    version: if flap { 6 } else { 8 },
                    external: true,
                    quote: QUOTE,
                    fault
                })
                .await
                .is_err(),
                "{flap}/{fault}"
            );
        }
    }
    for (flap, version) in [(true, 5), (true, 8), (false, 1), (false, 10)] {
        assert!(
            inspect(Spec {
                flap,
                version,
                external: false,
                quote: QUOTE,
                fault: ""
            })
            .await
            .is_err()
        );
    }
}
