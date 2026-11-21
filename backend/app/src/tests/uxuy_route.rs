use super::*;
use axum::{Json, Router, extract::State, http::HeaderMap, routing::post};
use base64::{
    Engine,
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
};
use md5::{Digest, Md5};
use ring::signature::{RSA_PKCS1_2048_8192_SHA256, UnparsedPublicKey};
use rsa::{
    RsaPrivateKey,
    pkcs1::{EncodeRsaPrivateKey, EncodeRsaPublicKey},
    pkcs8::{EncodePrivateKey, EncodePublicKey, LineEnding},
    rand_core::OsRng,
};
use std::sync::{Arc, Mutex, OnceLock};

const TOKEN: Address = Address::repeat_byte(0x11);
const ROUTER: Address = Address::repeat_byte(0x22);
const SPENDER: Address = Address::repeat_byte(0x33);
const COLLATERAL: Address = Address::repeat_byte(0x77);
const NATIVE: Address = Address::repeat_byte(0xee);
const A: Address = Address::repeat_byte(0x44);
const B: Address = Address::repeat_byte(0x55);
const POOL: Address = Address::repeat_byte(0x66);
const OUT: u64 = 1_000_000;
const MIN: u64 = 995_000;
fn planner() -> Planner {
    Planner {
        platforms: None,
        uxuy: Uxuy::disabled(),
        rpc: None,
        router: ROUTER,
        spender: SPENDER,
        native: NATIVE,
        max_impact_percent: 5.,
        default_slippage_bps: 50,
        deadline_seconds: 90,
    }
}
fn request(wallet: Address, side: Side, amount: u64) -> RouteRequest {
    RouteRequest {
        inner_platform: None,
        side,
        token: TOKEN,
        settlement_token: None,
        amount: amount.to_string(),
        wallet,
        slippage_bps: Some(50),
        max_impact_percent: None,
        forecast_only: false,
    }
}
fn fake_data(wallet: Address, input: U256, buy: bool, order: &str) -> Vec<u8> {
    let (src, dst) = if buy {
        (Address::ZERO, TOKEN)
    } else {
        (TOKEN, Address::ZERO)
    };
    tradeCall {
        params: TradeParams {
            amountIn: input,
            swaps: vec![SwapParams {
                provider: POOL,
                router: POOL,
                path: vec![src, dst],
                minAmountOut: U256::from(MIN),
                data: Bytes::new(),
            }],
            bridge: BridgeParams {
                provider: Address::ZERO,
                router: Address::ZERO,
                tokenIn: Address::ZERO,
                chainIDOut: U256::ZERO,
                tokenOut: Address::ZERO,
                minAmountOut: U256::ZERO,
                data: Bytes::new(),
            },
            recipient: wallet,
            feeShareRecipient: Address::ZERO,
            extraFeeAmountIn: U256::ZERO,
            extraFeeSwaps: vec![],
            deadline: U256::ZERO,
            orderId: decimal_word(order).unwrap(),
        },
    }
    .abi_encode()
}
fn row(side: Side, order: &str, wallet: Address, input: U256, executed: bool) -> Value {
    let (src, dst, dec_in, dec_out) = if side == Side::Buy {
        (WBNB, TOKEN, 18, 6)
    } else {
        (TOKEN, WBNB, 6, 18)
    };
    json!({"orderId":order,"paths":[{"chainId":56,"token":src,"decimals":dec_in},{"chainId":56,"token":dst,"decimals":dec_out}],
        "pairs":[{"chainId":56,"tokenIn":src,"tokenOut":dst,"pools":[{"pool":POOL,"protocol":"uniswapv3","in":input.to_string(),"amount":OUT,"price_impact":180}]}],
        "amount":OUT,"minAmount":MIN,"slippage":5000,"calldata":{"to":ROUTER,"value":if side==Side::Buy {input.to_string()} else {"0".into()},"data":hex::encode(fake_data(wallet,input,side==Side::Buy,order)),"error":"","executed":executed}})
}

#[test]
fn preserves_all_uint256_digits_and_token_precision() {
    let max = U256::MAX.to_string();
    let json = serde_json::from_str(&max).unwrap();
    assert_eq!(word(&json).unwrap(), U256::MAX);
    assert_eq!(units(U256::from(1_234_500), 6), "1.2345");
    assert_eq!(units(U256::ONE, 18), "0.000000000000000001");
    assert_eq!(units(U256::from(1_000_000), 6), "1");
    assert!(word(&serde_json::from_str("1e20").unwrap()).is_err());
    assert!(parse_amount("1.0").is_err());
}
#[test]
fn zero_user_impact_cap_requires_explicit_zero_from_every_pool() {
    let p = planner();
    let mut req = request(A, Side::Buy, 42);
    req.max_impact_percent = Some(0.);
    let (amount, slippage, cap) = p.validate(&req).unwrap();
    assert_eq!(cap, 0.);
    let mut source = row(Side::Buy, "42", A, amount, true);
    let parse = |value: &Value| p.parse_row(&req, value, "42", amount, slippage, cap, (6, 18), 100, false, false);
    let field = "/pairs/0/pools/0/price_impact";
    *source.pointer_mut(field).unwrap() = json!(0);
    assert!(parse(&source).is_ok());
    *source.pointer_mut(field).unwrap() = json!(1);
    assert_eq!(parse(&source).unwrap_err().code, "LIQUIDITY_INSUFFICIENT");
    *source.pointer_mut(field).unwrap() = Value::Null;
    assert_eq!(parse(&source).unwrap_err().code, "PRICE_IMPACT_UNKNOWN");
}

#[test]
fn validates_order_tokens_value_target_method_and_slippage() {
    let p = planner();
    let req = request(A, Side::Buy, 42);
    let source = row(Side::Buy, "42", A, U256::from(42), true);
    let parse = |v: &Value| {
        p.parse_row(
            &req,
            v,
            "42",
            U256::from(42),
            5000,
            5.,
            (6, 18),
            100,
            false,
            false,
        )
    };
    let accepted = parse(&source).unwrap();
    assert_eq!(
        accepted.data.as_ref(),
        fake_data(A, U256::from(42), true, "42")
    );
    assert_eq!(accepted.min_out, MIN.to_string());
    assert_eq!(accepted.spender, SPENDER);
    for (key, val) in [
        ("/orderId", json!("other")),
        ("/paths/0/chainId", json!(1)),
        ("/paths/1/token", json!(B)),
        ("/paths/1/decimals", json!(18)),
        ("/pairs/0/pools/0/in", json!(43)),
        ("/pairs/0/pools/0/price_impact", Value::Null),
        ("/pairs/0/pools/0/price_impact", json!(70_000)),
        ("/minAmount", json!(MIN - 1)),
        ("/minAmount", json!(0)),
        ("/slippage", json!(5001)),
        ("/calldata/to", json!(POOL)),
        ("/calldata/value", json!(43)),
        ("/calldata/data", json!("a9059cbb00")),
        ("/calldata/executed", json!(false)),
        ("/calldata/error", json!("reverted")),
    ] {
        let mut changed = source.clone();
        *changed.pointer_mut(key).unwrap() = val;
        assert!(parse(&changed).is_err(), "unexpected acceptance of {key}");
    }
}
#[test]
fn binds_missing_order_echo_to_the_calldata_for_execution_and_previews() {
    let p = planner();
    let amount = U256::from(42);
    for forecast in [false, true] {
        let mut req = request(A, Side::Buy, 42);
        req.forecast_only = forecast;
        let parse =
            |v: &Value| p.parse_row(&req, v, "9876", amount, 5000, 5., (6, 18), 100, false, false);
        let mut source = row(Side::Buy, "9876", A, amount, !forecast);
        source.as_object_mut().unwrap().remove("orderId");
        source["id"] = json!("12345"); // Provider route ID is independent of the request.
        let plan = parse(&source).unwrap();
        assert_eq!(plan.data.is_empty(), forecast);

        for (order, wallet, token_amount) in [
            ("987", A, amount),
            ("9876", B, amount),
            ("9876", A, U256::ONE),
        ] {
            let mut changed = source.clone();
            changed["calldata"]["data"] =
                hex::encode(fake_data(wallet, token_amount, true, order)).into();
            assert!(parse(&changed).is_err());
        }
        let mut missing_data = source.clone();
        missing_data.as_object_mut().unwrap().remove("calldata");
        assert!(parse(&missing_data).is_err());
        source["orderId"] = json!("12345");
        assert!(parse(&source).is_err());
    }
}

#[test]
fn rejects_mismatched_onchain_recipient_amount_minimum_bridge_and_fees() {
    let p = planner();
    let req = request(A, Side::Buy, 42);
    let amount = U256::from(42);
    let source = row(Side::Buy, "42", A, amount, true);
    let parse = |v: &Value| p.parse_row(&req, v, "42", amount, 5000, 5., (6, 18), 100, false, false);
    let mutations: &[fn(&mut TradeParams)] = &[
        |t| t.amountIn += U256::ONE,
        |t| t.recipient = B,
        |t| t.swaps[0].minAmountOut -= U256::ONE,
        |t| t.swaps[0].path[1] = B,
        |t| t.bridge.provider = B,
        |t| t.feeShareRecipient = B,
        |t| t.extraFeeAmountIn = U256::ONE,
        |t| t.extraFeeSwaps = t.swaps.clone(),
        |t| t.deadline = U256::from(99),
    ];
    for change in mutations {
        let mut parsed = tradeCall::abi_decode(&fake_data(A, amount, true, "42")).unwrap();
        change(&mut parsed.params);
        let mut row = source.clone();
        row["calldata"]["data"] = hex::encode(parsed.abi_encode()).into();
        assert!(parse(&row).is_err());
    }
    let mut tx = tradeCall::abi_decode(&fake_data(A, amount, true, "42")).unwrap();
    tx.params.deadline = U256::from(110);
    let mut quote = source;
    quote["calldata"]["data"] = hex::encode(tx.abi_encode()).into();
    assert_eq!(parse(&quote).unwrap().deadline, 110);
}
struct TestKey {
    pkcs8_pem: String,
    pkcs1_pem: String,
    verification_key: Vec<u8>,
    expected_jti: String,
}
fn test_key() -> &'static TestKey {
    static KEY: OnceLock<TestKey> = OnceLock::new();
    KEY.get_or_init(|| {
        let rsa = RsaPrivateKey::new(&mut OsRng, 2048).unwrap();
        let public = rsa.to_public_key();
        let spki = public.to_public_key_der().unwrap();
        let sha256 = ring::digest::digest(&ring::digest::SHA256, spki.as_bytes());
        let expected_jti = hex::encode(Md5::digest(STANDARD.encode(sha256).as_bytes()));
        TestKey {
            pkcs8_pem: rsa.to_pkcs8_pem(LineEnding::LF).unwrap().to_string(),
            pkcs1_pem: rsa.to_pkcs1_pem(LineEnding::LF).unwrap().to_string(),
            verification_key: public.to_pkcs1_der().unwrap().as_bytes().to_vec(),
            expected_jti,
        }
    })
}
#[derive(Default)]
struct Mock {
    requests: Mutex<Vec<Value>>,
    fail_simulation: bool,
    rapid_zero_holding: bool,
    fail_later_swap_in_same_block: bool,
    wallet_debit: Option<u64>,
    charges_fee: bool,
    sufficient_allowance: bool,
    output_to_another_wallet: bool,
    empty_quotes: bool,
    invalid_quotes: bool,
}
fn verify_gateway_auth(headers: &HeaderMap) {
    let auth = headers["authorization"]
        .to_str()
        .unwrap()
        .strip_prefix("Bearer ")
        .unwrap();
    let (msg, sig) = auth.rsplit_once('.').unwrap();
    let (header, claims) = msg.split_once('.').unwrap();
    let header: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(header).unwrap()).unwrap();
    let claims: Value = serde_json::from_slice(&URL_SAFE_NO_PAD.decode(claims).unwrap()).unwrap();
    assert_eq!(header["alg"], "RS256");
    assert_eq!(header["jti"], test_key().expected_jti);
    assert_eq!(claims["jti"], test_key().expected_jti);
    assert_eq!(claims["iss"], "app");
    assert!(claims.get("iat").is_none());
    assert_eq!(
        claims["exp"].as_u64().unwrap() - claims["ts"].as_u64().unwrap(),
        300
    );
    UnparsedPublicKey::new(&RSA_PKCS1_2048_8192_SHA256, &test_key().verification_key)
        .verify(msg.as_bytes(), &URL_SAFE_NO_PAD.decode(sig).unwrap())
        .unwrap();
}
async fn gateway(
    State(mock): State<Arc<Mock>>,
    headers: HeaderMap,
    Json(body): Json<Value>,
) -> Json<Value> {
    verify_gateway_auth(&headers);
    assert_eq!(body["method"], "dex_offlineQuote");
    let p = &body["params"][0];
    assert_eq!(p["sender"], p["receiver"]);
    assert_eq!(p["noFee"], true);
    assert_eq!(p["slippage"], 5000);
    let side = if p["tokenIn"] == json!(NATIVE) {
        Side::Buy
    } else {
        Side::Sell
    };
    let decimals = if side == Side::Buy { 18 } else { 6 };
    let text = p["amountIn"].as_str().unwrap();
    let (whole, frac) = text.split_once('.').unwrap_or((text, ""));
    let input = decimal_word(&format!(
        "{whole}{frac}{}",
        "0".repeat(decimals - frac.len())
    ))
    .unwrap();
    let wallet = address(&p["sender"]).unwrap();
    mock.requests.lock().unwrap().push(p.clone());
    let rows = if mock.empty_quotes {
        vec![]
    } else if mock.invalid_quotes {
        vec![json!({"orderId":p["orderId"],"calldata":null})]
    } else {
        let mut quote = row(side, p["orderId"].as_str().unwrap(), wallet, input, p["withTx"] == true);
        if p["tokenOut"] == json!(COLLATERAL) {
            quote["paths"][1]["token"] = json!(COLLATERAL);
            quote["paths"][1]["decimals"] = json!(8);
            quote["pairs"][0]["tokenOut"] = json!(COLLATERAL);
            let data = hex::decode(quote["calldata"]["data"].as_str().unwrap()).unwrap();
            let mut trade = tradeCall::abi_decode_validate(&data).unwrap();
            trade.params.swaps.last_mut().unwrap().path[1] = COLLATERAL;
            quote["calldata"]["data"] = json!(hex::encode(trade.abi_encode()));
        }
        vec![quote]
    };
    Json(json!({"jsonrpc":"2.0","id":1,"result":rows}))
}
fn ret(n: U256) -> String {
    format!("0x{}", hex::encode(n.to_be_bytes::<32>()))
}
async fn bsc(State(mock): State<Arc<Mock>>, Json(req): Json<Value>) -> Json<Value> {
    let result = match req["method"].as_str().unwrap() {
        "eth_blockNumber" => json!("0x123"),
        "eth_call" => {
            let data = req["params"][0]["data"].as_str().unwrap();
            let target = address(&req["params"][0]["to"]).unwrap();
            assert!(target == TOKEN || (target == COLLATERAL && data == "0x313ce567"));
            if data == "0x313ce567" {
                json!(ret(U256::from(if target == TOKEN {6} else {8})))
            } else {
                let raw = hex::decode(data.trim_start_matches("0x")).unwrap();
                assert_eq!(allowanceCall::abi_decode(&raw).unwrap().spender, SPENDER);
                json!(ret(if mock.sufficient_allowance {
                    U256::MAX
                } else {
                    U256::ZERO
                }))
            }
        }
        "eth_simulateV1" => {
            let calls = req["params"][0]["blockStateCalls"][0]["calls"]
                .as_array()
                .unwrap();
            let mut start = 0;
            let mut ordered = Vec::new();
            let mut index = 0;
            let ok = |n: U256| json!({"status":"0x1","returnData":ret(n),"gasUsed":"0x5208"});
            let mut tokens = U256::ZERO;
            while start < calls.len() {
                if mock.rapid_zero_holding && calls[start]["to"]==json!(TOKEN) &&
                    calls[start]["from"]==json!(Address::ZERO) {
                    assert_eq!(req["params"][1],"0x123");
                    ordered.push(ok(tokens));
                    start+=1;
                    continue;
                }
                let remaining = &calls[start..];
                let swap_idx = remaining
                    .iter()
                    .position(|call| call["to"] == json!(ROUTER))
                    .unwrap();
                let calls = &remaining[..swap_idx + 3];
                let swap = &calls[swap_idx];
                let wallet = address(&swap["from"]).unwrap();
                let data: Bytes = swap["data"].as_str().unwrap().parse().unwrap();
                let trade = tradeCall::abi_decode_validate(&data).unwrap().params;
                assert_eq!(trade.recipient, wallet);
                assert_eq!(swap["to"], json!(ROUTER));
                let input = trade.amountIn;
                let buy = trade.swaps[0].path[0].is_zero();
                let preapproval = !buy && !mock.sufficient_allowance;
                assert_eq!(swap_idx, if preapproval { 3 } else { 2 });
                if preapproval {
                    let data: Bytes = calls[2]["data"].as_str().unwrap().parse().unwrap();
                    let approval = approveCall::abi_decode(&data).unwrap();
                    assert_eq!(approval.spender, SPENDER);
                    assert_eq!(approval.amount, input);
                    assert_eq!(calls[2]["from"], json!(wallet));
                    assert_eq!(calls[2]["to"], json!(TOKEN));
                }
                assert_eq!(calls[1]["to"], json!(TOKEN));
                if trade.swaps.last().unwrap().path.last() == Some(&COLLATERAL) {
                    assert_eq!(calls[0]["to"], json!(COLLATERAL));
                    assert_eq!(calls[0]["data"], calls[1]["data"]);
                } else {
                    assert_eq!(calls[0]["to"], json!(crate::config::MULTICALL3));
                }
                assert_eq!(calls[0], calls[swap_idx + 1]);
                assert_eq!(calls[1], calls[swap_idx + 2]);
                let owner_call: Bytes = calls[1]["data"].as_str().unwrap().parse().unwrap();
                assert_eq!(
                    crate::wallets::balanceOfCall::abi_decode(&owner_call)
                        .unwrap()
                        .owner,
                    wallet
                );
                let before = U256::from(10_000_000);
                let out = if mock.output_to_another_wallet {
                    U256::ZERO
                } else {
                    U256::from(OUT)
                };
                let debit = mock.wallet_debit.map(U256::from).unwrap_or(input);
                let token_before = if mock.rapid_zero_holding { tokens } else { before };
                let (nb, tb) = if buy {
                    (before - debit, token_before + out)
                } else {
                    (before + out, token_before - debit)
                };
                tokens = tb;
                let mut results = vec![ok(before), ok(token_before)];
                if preapproval {
                    results.push(ok(U256::ONE));
                }
                let traded = Traded {
                    sender: wallet,
                    orderId: trade.orderId,
                    recipient: wallet,
                    feeShareRecipient: Address::ZERO,
                    tokenIn: trade.swaps[0].path[0],
                    amountIn: input,
                    chainIDOut: U256::ZERO,
                    tokenOut: trade.swaps[0].path[1],
                    amountOut: out,
                    bridgeTxnID: U256::ZERO,
                    feeToken: Address::ZERO,
                    amountFee: if mock.charges_fee {
                        U256::ONE
                    } else {
                        U256::ZERO
                    },
                    amountFeeShare: U256::ZERO,
                    amountExtraFee: U256::ZERO,
                }
                .encode_log_data();
                results.push(json!({"status":if mock.fail_simulation || (index > 0 && mock.fail_later_swap_in_same_block){"0x0"}else{"0x1"},"returnData":"0x","gasUsed":"0x20000",
                "logs":[{"address":ROUTER,"topics":traded.topics(),"data":traded.data}]}));
                results.extend([ok(nb), ok(tb)]);
                ordered.extend(results);
                start += calls.len();
                index += 1;
            }
            json!([{"calls":ordered}])
        }
        method => panic!("unexpected RPC {method}"),
    };
    Json(json!({"jsonrpc":"2.0","id":1,"result":result}))
}
async fn service(mock: Mock) -> (Planner, Arc<Mock>, tokio::task::JoinHandle<()>) {
    let mock = Arc::new(mock);
    let app = Router::new()
        .route("/rpc", post(bsc))
        .route("/bnbchain/test_app", post(gateway))
        .with_state(mock.clone());
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = tcp.local_addr().unwrap();
    let task = tokio::spawn(async move { axum::serve(tcp, app).await.unwrap() });
    let mut p = planner();
    p.rpc = Some(Rpc::new(
        reqwest::Client::new(),
        &format!("http://{addr}/rpc"),
    ));
    p.uxuy = Uxuy::for_loopback("test_app", test_key().pkcs8_pem.as_bytes(), addr);
    (p, mock, task)
}

#[tokio::test]
async fn validates_fresh_wallet_quotes_and_keeps_bundle_preview_unsigned() {
    let (p, mock, task) = service(Mock::default()).await;
    let (group, rows) = p
        .plan_bundle(&[request(A, Side::Buy, 15), request(B, Side::Buy, 17)], 100)
        .await
        .unwrap();
    assert_eq!(group.quote_scope, Some("bundle"));
    assert!(group.data.is_empty());
    assert_eq!(group.gas_limit, 0);
    assert!(!group.executed);
    assert_eq!(group.simulation, "forecast");
    assert!(
        rows.iter().all(|r| r.executed
            && r.gas_estimated
            && r.quote_scope == Some("wallet")
            && r.fee == "0")
    );
    let mut preview = request(A, Side::Sell, 1_200_000);
    preview.forecast_only = true;
    let quote = p.plan(&preview, 100).await.unwrap();
    assert!(!quote.executed && quote.data.is_empty());
    assert_eq!(quote.gas_limit, 0);
    let sell = p
        .plan(&request(A, Side::Sell, 1_234_567), 100)
        .await
        .unwrap();
    assert_eq!(sell.simulation, "approve_then_swap");
    assert!(sell.executed);
    assert_eq!(sell.value, "0");
    let reqs = mock.requests.lock().unwrap();
    for (row, (wallet, input)) in rows.iter().zip([(A, 15u64), (B, 17)]) {
        let order = reqs
            .iter()
            .find(|r| r["sender"] == json!(wallet) && r["withTx"] == true)
            .unwrap()["orderId"]
            .as_str()
            .unwrap();
        assert_eq!(
            row.data.as_ref(),
            fake_data(wallet, U256::from(input), true, order)
        );
    }
    assert_eq!(reqs[0]["withTx"], false);
    assert_eq!(reqs[0]["amountIn"], "0.000000000000000032");
    assert_eq!(reqs[4]["withTx"], false);
    assert_eq!(reqs[4]["amountIn"], "1.234567");
    assert_eq!(
        reqs.iter()
            .map(|r| r["orderId"].as_str().unwrap())
            .collect::<HashSet<_>>()
            .len(),
        5
    );
    task.abort();
}
#[tokio::test]
async fn refuses_unconfirmed_payout_reverts_and_empty_quotes() {
    for (mock, code) in [
        (
            Mock {
                charges_fee: true,
                ..Mock::default()
            },
            "UXUY_SIMULATION_FAILED",
        ),
        (
            Mock {
                fail_simulation: true,
                ..Mock::default()
            },
            "UXUY_SIMULATION_FAILED",
        ),
        (
            Mock {
                output_to_another_wallet: true,
                ..Mock::default()
            },
            "UXUY_SIMULATION_FAILED",
        ),
        (
            Mock {
                empty_quotes: true,
                ..Mock::default()
            },
            "UXUY_NO_ROUTE",
        ),
        (
            Mock {
                invalid_quotes: true,
                ..Mock::default()
            },
            "UXUY_ROUTE_INVALID",
        ),
    ] {
        let (p, _, task) = service(mock).await;
        for side in [Side::Buy, Side::Sell] {
            let error = p.plan(&request(A, side, 42), 100).await.unwrap_err();
            assert_eq!(error.code, code);
            if matches!(code, "UXUY_NO_ROUTE" | "UXUY_ROUTE_INVALID") {
                assert_eq!(error.message, "UXUY 无法获得合格报价");
            }
        }
        task.abort();
    }
}

#[tokio::test]
async fn existing_allowance_uses_upstream_and_wallet_simulation_without_approval() {
    let (p, mock, task) = service(Mock {
        sufficient_allowance: true,
        ..Mock::default()
    })
    .await;
    let plan = p.plan(&request(A, Side::Sell, 42), 100).await.unwrap();
    assert!(plan.executed);
    assert_eq!(plan.simulation, "uxuy");
    assert_eq!(mock.requests.lock().unwrap()[0]["withTx"], true);
    task.abort();
}

#[tokio::test]
async fn route_to_signed_bundle_relay_requires_original_signer_value_and_data() {
    use alloy_primitives::TxKind;
    use botai_transactions::{Store, Transactions};
    use k256::ecdsa::SigningKey;
    use std::sync::atomic::{AtomicU64, Ordering};

    let (mut planner, _, gateway_task) = service(Mock::default()).await;
    planner.deadline_seconds = 8;
    let head = Arc::new(AtomicU64::new(90));
    let seen = Arc::new(Mutex::new(Vec::<Value>::new()));
    let relay=Router::new().route("/",post({
        let seen = seen.clone();
        let head = head.clone();
        move |Json(body): Json<Value>| {
            let seen = seen.clone();
            let head = head.clone();
            async move {
                if let Some(calls) = body.as_array() {
                    let replies: Vec<_> = calls.iter().map(|c| {
                        let result = match c["method"].as_str().unwrap() {
                            "eth_blockNumber" => json!(format!("0x{:x}",head.load(Ordering::SeqCst))),
                            "eth_getTransactionReceipt" => Value::Null,
                            m => panic!("unexpected RPC method {m}"),
                        };
                        json!({"jsonrpc":"2.0","id":c["id"],"result":result})
                    }).collect();
                    return Json(json!(replies));
                }
                assert_eq!(body["method"], "blxr_submit_bundle");
                seen.lock().unwrap().push(body);
                Json(json!({"jsonrpc":"2.0","id":1,"result":{"bundleHash":format!("0x{}","be".repeat(32))}}))
            }
        }
    }));
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_url = format!("http://{}", tcp.local_addr().unwrap());
    let relay_task = tokio::spawn(async move { axum::serve(tcp, relay).await.unwrap() });
    let http = reqwest::Client::builder().no_proxy().build().unwrap();
    let chain_rpc = botai_rpc::Rpc::with_urls(
        http.clone(),
        [(botai_core::Chain::Bsc, relay_url.clone())]
            .into_iter()
            .collect(),
    );
    let rpc_control = chain_rpc.clone();
    let transactions = Transactions::new(
        Store::open(":memory:").unwrap(),
        chain_rpc.clone(),
        http.clone(),
        "test-only".into(),
    )
    .with_local_relay(&relay_url)
    .unwrap();
    let rpc = planner.rpc.clone().unwrap();
    let app = crate::App {
        monitor: None,
        planner,
        rpc,
        router: ROUTER,
        rpc_provider: "local-fork",
        node_status: Default::default(),
        denied: vec![],
        issued: crate::issued::IssuedRoutes::default(),
        route_enabled: true,
        platforms: botai_platforms::Platforms::new(chain_rpc.clone()),
        integrations: botai_integrations::Integrations::new(http.clone(), chain_rpc.clone()),
        chain_rpc,
        transactions,
    };
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let api = format!("http://{}/api/v1", tcp.local_addr().unwrap());
    let app_task = tokio::spawn(async move { axum::serve(tcp, crate::routes(app)).await.unwrap() });
    let key = SigningKey::from_slice(&[7; 32]).unwrap();
    let owner = Address::from_public_key(key.verifying_key());
    let quote: Value = http
        .post(format!("{api}/routes"))
        .json(&json!({
            "side":"buy","token":TOKEN,"wallet":owner,"amount":"59","slippageBps":50
        }))
        .send()
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    let plan = &quote["plan"];
    assert_eq!(plan["wallet"], json!(owner));
    assert_eq!(plan["source"], "uxuy");
    assert_eq!(plan["executed"], true);
    let target = TxKind::Call(address(&plan["to"]).unwrap());
    let value = plan["value"].as_str().unwrap().parse::<u64>().unwrap();
    let data: Bytes = plan["data"].as_str().unwrap().parse().unwrap();
    let signed = |who, v, input| crate::tests::signed_at(who, 9, target, v, input, 56);
    let raw = signed(7, value, data.to_vec());
    let submit = |raw: String, max_block: u64| {
        http.post(format!("{api}/bundles"))
            .json(&json!({"transactions":[raw],"maxBlockNumber":max_block}))
            .send()
    };
    let mut altered = data.to_vec();
    *altered.last_mut().unwrap() ^= 1;
    for rejected in [
        signed(8, value, data.to_vec()),
        signed(7, value, altered),
        signed(7, value + 1, data.to_vec()),
    ] {
        let response = submit(rejected, 100).await.unwrap();
        assert_eq!(response.status().as_u16(), 403);
        assert_eq!(
            response.json::<Value>().await.unwrap()["code"],
            "ACTION_NOT_ALLOWED"
        );
    }
    assert!(seen.lock().unwrap().is_empty());
    let result: Value = submit(raw.clone(), 100)
        .await
        .unwrap()
        .error_for_status()
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(result["ok"], true);
    {
        let requests = seen.lock().unwrap();
        assert_eq!(requests.len(), 1);
        assert_eq!(
            requests[0]["params"]["txs"],
            json!([raw.trim_start_matches("0x")])
        );
    }
    // A lost HTTP response on the browser side cannot bypass the live hash/nonce claim.
    let hash = alloy_primitives::keccak256(hex::decode(raw.trim_start_matches("0x")).unwrap());
    let status = |tracked: bool| {
        http.get(format!(
            "{api}/transactions/bsc/{hash:#x}?tracked={tracked}"
        ))
        .send()
    };
    let current: Value = status(true).await.unwrap().json().await.unwrap();
    assert_eq!(current["result"]["status"], "accepted");
    assert_eq!(current["result"]["maxBlockNumber"], 100);
    let duplicate = submit(raw.clone(), 130).await.unwrap();
    assert_eq!(duplicate.status().as_u16(), 409);
    assert_eq!(seen.lock().unwrap().len(), 1);

    // A proactively refreshed, provably expired window frees the original nonce.
    // Using the same issued swap bytes succeeds while its authorization is valid.
    head.store(110, Ordering::SeqCst);
    rpc_control.invalidate_latest(botai_core::Chain::Bsc).await;
    let expired: Value = status(false).await.unwrap().json().await.unwrap();
    assert_eq!(expired["result"]["status"], "not_included");
    submit(raw.clone(), 150)
        .await
        .unwrap()
        .error_for_status()
        .unwrap();
    {
        let requests = seen.lock().unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[1]["params"]["txs"], requests[0]["params"]["txs"]);
        assert_eq!(requests[1]["params"]["max_block_number"], 150);
    }

    head.store(161, Ordering::SeqCst);
    rpc_control.invalidate_latest(botai_core::Chain::Bsc).await;
    let deadline = plan["deadline"].as_u64().unwrap();
    while crate::now() < deadline {
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    }
    let expired: Value = status(false).await.unwrap().json().await.unwrap();
    assert_eq!(expired["result"]["status"], "not_included");
    let rejected: Value = submit(raw, 201).await.unwrap().json().await.unwrap();
    assert_eq!(rejected["code"], "ACTION_NOT_ALLOWED");
    assert_eq!(rejected["notSubmitted"], true);
    assert_eq!(seen.lock().unwrap().len(), 2);
    app_task.abort();
    relay_task.abort();
    gateway_task.abort();
}

#[tokio::test]
async fn combined_swaps_reject_later_revert_even_when_each_wallet_passes_alone() {
    let (planner, _, task) = service(Mock {
        fail_later_swap_in_same_block: true,
        ..Mock::default()
    })
    .await;
    for side in [Side::Buy, Side::Sell] {
        let first = request(A, side, 42);
        let next = request(B, side, 43);
        assert!(planner.plan(&first, 100).await.unwrap().executed);
        assert!(planner.plan(&next, 100).await.unwrap().executed);
        let error = planner.plan_bundle(&[first, next], 100).await.unwrap_err();
        assert_eq!(error.code, "UXUY_BUNDLE_SIMULATION_FAILED");
        assert!(error.message.contains(&format!("{B:#x}")));
    }
    task.abort();
}

#[tokio::test]
async fn native_buy_can_receive_change_while_sells_must_debit_the_full_token_input() {
    let (p, _, task) = service(Mock {
        wallet_debit: Some(39),
        ..Mock::default()
    })
    .await;
    let buy = request(A, Side::Buy, 42);
    let plan = p.plan(&buy, 100).await.unwrap();
    assert_eq!(plan.value, "42");
    assert_eq!(plan.min_out, MIN.to_string());
    assert!(plan.executed);
    assert!(
        p.plan_bundle(&[buy, request(B, Side::Buy, 42)], 100)
            .await
            .is_ok()
    );
    let partial_sell = p.plan(&request(A, Side::Sell, 42), 100).await.unwrap_err();
    assert_eq!(partial_sell.code, "UXUY_SIMULATION_FAILED");
    task.abort();

    for mock in [
        Mock {
            wallet_debit: Some(0),
            ..Mock::default()
        },
        Mock {
            wallet_debit: Some(43),
            ..Mock::default()
        },
        Mock {
            wallet_debit: Some(39),
            output_to_another_wallet: true,
            ..Mock::default()
        },
        Mock {
            wallet_debit: Some(39),
            charges_fee: true,
            ..Mock::default()
        },
    ] {
        let (p, _, task) = service(mock).await;
        let error = p.plan(&request(A, Side::Buy, 42), 100).await.unwrap_err();
        assert_eq!(error.code, "UXUY_SIMULATION_FAILED");
        task.abort();
    }
}

#[tokio::test]
async fn rejected_gateway_authentication_never_yields_a_signable_quote() {
    let tcp = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = tcp.local_addr().unwrap();
    let mock = Router::new().route(
        "/bnbchain/test_app",
        post(|headers: HeaderMap| async move {
            verify_gateway_auth(&headers);
            (
                axum::http::StatusCode::UNAUTHORIZED,
                "jwt auth id should be empty",
            )
        }),
    );
    let server = tokio::spawn(async move { axum::serve(tcp, mock).await.unwrap() });
    let gateway = Uxuy::for_loopback("test_app", test_key().pkcs1_pem.as_bytes(), addr);
    let error = gateway.quote(json!({})).await.unwrap_err();
    assert_eq!(error.code, "UXUY_AUTH_REJECTED");
    assert!(!error.retryable);
    server.abort();
}

#[tokio::test]
async fn liquidation_validates_selected_collateral_for_each_order_and_measures_its_real_balance() {
    for missing_output in [false, true] {
        let (p, gateway, server) = service(Mock { output_to_another_wallet: missing_output, ..Default::default() }).await;
        let mut sale = request(A, Side::Sell, 450_000);
        sale.settlement_token = Some(COLLATERAL);
        let mut other = sale.clone();
        other.wallet = B;
        let result = p.plan_bundle(&[sale.clone(),other.clone()],100).await;
        if missing_output {
            assert!(result.is_err());
        } else {
            let (group, plans) = result.unwrap();
            assert_eq!(group.settlement_token, Some(COLLATERAL));
            assert_eq!(plans.len(), 2);
            assert!(plans.iter().all(|r| r.settlement_token == Some(COLLATERAL) && r.executed));
            let requests = gateway.requests.lock().unwrap();
            assert!(requests.iter().all(|r| r["tokenOut"] == json!(COLLATERAL) && r["tokenIn"] == json!(TOKEN)));
        }
        other.settlement_token = None;
        assert!(p.plan_bundle(&[sale.clone(),other],100).await.is_err());
        sale.side = Side::Buy;
        assert!(p.validate(&sale).is_err());
        server.abort();
    }
}

#[test]
fn collateral_liquidation_rejects_native_calldata_for_a_correctly_labelled_pool_token_quote() {
    let p = planner();
    let mut req = request(A, Side::Sell, 42);
    req.settlement_token = Some(COLLATERAL);
    let amount = U256::from(42);
    let mut quote = row(Side::Sell, "42", A, amount, true);
    quote["paths"][1]["token"] = json!(COLLATERAL);
    quote["paths"][1]["decimals"] = json!(8);
    quote["pairs"][0]["tokenOut"] = json!(COLLATERAL);
    assert!(p.parse_row(&req,&quote,"42",amount,5000,5.,(6,8),100,false,false).is_err());
}

#[tokio::test]
async fn rapid_zero_holder_must_pass_the_actual_second_swap_in_the_buy_state() {
    for revert in [false,true] {
        let (planner, gateway, handle)=service(Mock{rapid_zero_holding:true,fail_later_swap_in_same_block:revert,..Default::default()}).await;
        let proof=super::rapid_probe::probe(&planner,super::rapid_probe::RapidCheck{
            buy:request(A,Side::Buy,1_000),sell_value:"5000".into(),percent_sell:true,buy_orders:1,sell_orders:1,
        },100,None).await;
        if revert {
            assert!(proof.is_err());
        } else {
            let response=proof.unwrap().0;
            assert_eq!(response["before"],"0");
            assert_eq!(response["received"],OUT.to_string());
            assert_eq!(response["sellAmount"],(OUT/2).to_string());
            assert!(response["buyGas"].as_u64().unwrap()>21_000);
            assert!(response["sellGas"].as_u64().unwrap()>21_000);
            assert!(response.get("data").is_none());
        }
        let reqs=gateway.requests.lock().unwrap();
        assert_eq!(reqs.len(),2);
        assert_eq!(reqs[0]["withTx"],true);
        assert_eq!(reqs[1]["withTx"],false);
        handle.abort();
    }
}

#[tokio::test]
async fn official_bundle_reprices_each_wallet_at_its_position_before_issuing_minima() {
    sol! { function buyTokenAMAP(address token,address to,uint256 funds,uint256 minAmount); }
    async fn simulate(Json(message): Json<Value>) -> Json<Value> {
        let calls = message["params"][0]["blockStateCalls"][0]["calls"]
            .as_array()
            .unwrap();
        assert_eq!(calls.len(), 10);
        let number =
            |n: u64| json!({"status":"0x1","returnData":format!("0x{n:064x}"),"gasUsed":"0x6000"});
        let mut results = Vec::new();
        for (i, chunk) in calls.chunks_exact(5).enumerate() {
            let out = 1000 - i as u64 * 200;
            let encoded: Bytes = serde_json::from_value(chunk[2]["data"].clone()).unwrap();
            let swap = buyTokenAMAPCall::abi_decode_validate(&encoded).unwrap();
            assert_eq!(swap.to, [A, B][i]);
            assert_eq!(swap.funds, U256::from(123));
            let tx = if swap.minAmount <= U256::from(out) {
                number(0)
            } else {
                json!({"status":"0x0","error":"minimum"})
            };
            results.extend([number(1000), number(0), tx, number(877), number(out)]);
        }
        Json(json!({"jsonrpc":"2.0","id":message["id"],"result":[{"calls":results}]}))
    }
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = tokio::spawn(async move {
        axum::serve(listener, Router::new().route("/", post(simulate)))
            .await
            .unwrap();
    });
    let mut planner = planner();
    planner.rpc = Some(Rpc::new(reqwest::Client::new(), &url));
    let mut requests = Vec::new();
    let mut plans = Vec::new();
    for owner in [A, B] {
        let mut req = request(owner, Side::Buy, 123);
        req.inner_platform = Some("four".into());
        req.max_impact_percent = Some(100.);
        let mut plan = crate::tests::plan(Side::Buy);
        plan.source = "official";
        plan.wallet = owner;
        plan.price_impact_percent = 0.;
        plan.adverse_price_impact_percent = 0.;
        plan.quote_out = "1000".into();
        plan.min_out = "990".into();
        let target = crate::submit::FOUR_MANAGER;
        let data = Bytes::from(
            buyTokenAMAPCall {
                token: req.token,
                to: owner,
                funds: U256::from(123),
                minAmount: U256::from(990),
            }
            .abi_encode(),
        );
        plan.legs = vec![RouteLeg {
            kind: "official",
            to: target,
            data,
            value: "123".into(),
            gas_limit: 0,
            token_in: Address::ZERO,
            token_out: req.token,
            amount_in: "123".into(),
            min_out: "990".into(),
            recipient: owner,
        }];
        requests.push(req);
        plans.push(plan);
    }
    planner
        .reprice_inner_bundle(&requests, &json!({"block":10}), &mut plans, crate::now())
        .await
        .unwrap();
    for (plan, minimum) in plans.iter().zip([990u64, 792]) {
        assert_eq!(plan.min_out, minimum.to_string());
        assert_eq!(plan.legs[0].min_out, plan.min_out);
        assert_eq!(plan.data, plan.legs[0].data);
        assert!(plan.executed);
        assert_eq!(
            buyTokenAMAPCall::abi_decode_validate(&plan.data)
                .unwrap()
                .minAmount,
            U256::from(minimum)
        );
    }
    server.abort();
}
