use super::*;
use alloy_primitives::aliases::{I24, U24};
use axum::{Json, Router, extract::State, routing::post};
use botai_rpc::multicall::{Result3, aggregate3Call};
use std::{
    collections::HashMap,
    sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    },
};
const TARGET: Address = address!("0000000000000000000000000000000000000222");
const HOOK: Address = address!("0000000000000000000000000000000000000333");
fn key() -> alloy_primitives::B256 {
    keccak256(
        (
            TARGET,
            CASH,
            U24::from(3000),
            I24::try_from(60).unwrap(),
            HOOK,
        )
            .abi_encode(),
    )
}
async fn rpc(State(mode): State<Arc<AtomicUsize>>, Json(rows): Json<Vec<Value>>) -> Json<Value> {
    let mode = mode.load(Ordering::SeqCst);
    let results=rows.into_iter().map(|row|{
        assert_eq!(row["method"],"eth_call");assert_eq!(row["params"][1],"0x64");
        let raw=row["params"][0]["data"].as_str().unwrap().parse::<Bytes>().unwrap();
        let calls=aggregate3Call::abi_decode(&raw).unwrap().calls;
        let returns=calls.into_iter().map(|call|{
            let sel=&call.callData[..4];
            let data=if sel==symbolCall::SELECTOR {symbolCall::abi_encode_returns(&"SIX".into())}
            else if sel==decimalsCall::SELECTOR {decimalsCall::abi_encode_returns(&6)}
            else if sel==launchesCall::SELECTOR {
                assert_eq!(call.target,PORTAL);
                launchesCall::abi_encode_returns(&launchesReturn{creator:if mode==2||mode==6{Address::ZERO}else{TARGET},hook:if mode==2{Address::ZERO}else{HOOK},quote:if mode==5{TARGET}else{CASH},a:U256::ZERO,b:U256::ZERO,c:Address::ZERO,e:Address::ZERO,f:U256::ZERO,g:U256::ZERO,h:U256::ZERO,i:U256::ZERO})
            } else {
                assert_eq!(call.target,HOOK);
                if sel==bondedCall::SELECTOR {bondedCall::abi_encode_returns(&(mode==1))}
                else if sel==tokenCall::SELECTOR {tokenCall::abi_encode_returns(&if mode==3{CASH}else{TARGET})}
                else if sel==portalCall::SELECTOR {portalCall::abi_encode_returns(&PORTAL)}
                else if sel==quoteAssetCall::SELECTOR {quoteAssetCall::abi_encode_returns(&CASH)}
                else if sel==poolManagerCall::SELECTOR {poolManagerCall::abi_encode_returns(&MANAGER)}
                else if sel==poolIdCall::SELECTOR {poolIdCall::abi_encode_returns(&if mode==4{Default::default()}else{key()})}
                else if sel==poolFeeCall::SELECTOR {poolFeeCall::abi_encode_returns(&U24::from(3000))}
                else if sel==tickSpacingCall::SELECTOR {tickSpacingCall::abi_encode_returns(&I24::try_from(60).unwrap())}
                else if sel==buyTaxBpsCall::SELECTOR {buyTaxBpsCall::abi_encode_returns(&U256::from(if mode==7{10001}else{200}))}
                else if sel==sellTaxBpsCall::SELECTOR {sellTaxBpsCall::abi_encode_returns(&U256::from(300))}
                else if sel==currentSnipeTaxBpsCall::SELECTOR {currentSnipeTaxBpsCall::abi_encode_returns(&U256::from(100))}
                else {panic!("unexpected selector")}
            };Result3{success:true,returnData:data.into()}
        }).collect::<Vec<_>>();
        json!({"jsonrpc":"2.0","id":row["id"],"result":Bytes::from(aggregate3Call::abi_encode_returns(&returns))})
    }).collect::<Vec<_>>();
    Json(json!(results))
}
#[tokio::test]
async fn official_arc_identity_phase_quote_precision_and_tax_are_bound_at_one_block() {
    let mode = Arc::new(AtomicUsize::new(0));
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let app = Router::new().route("/", post(rpc)).with_state(mode.clone());
    let server = tokio::spawn(async { axum::serve(listener, app).await.unwrap() });
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    for case in 0..8 {
        mode.store(case, Ordering::SeqCst);
        let p = Platforms::new(Rpc::with_urls(
            client.clone(),
            HashMap::from([(Chain::Arc, url.clone())]),
        ));
        let result = p.inspect(Chain::Arc, TARGET, Some(100)).await;
        if case >= 3 {
            assert!(result.is_err(), "case {case}");
            continue;
        }
        let result = result.unwrap();
        assert_eq!(result["decimals"], 6);
        assert_eq!(result["pair"]["decimals"], 18);
        assert_eq!(result["pair"]["native"], true);
        assert_eq!(result["external"], case != 0);
        assert_eq!(
            result["market"]["spender"],
            json!(if case == 0 { PERMIT2 } else { OKX }.to_checksum(None))
        );
        if case != 2 {
            assert_eq!(result["tokenTax"]["totalBps"], 400);
            assert_eq!(result["market"]["poolKey"]["tickSpacing"], 60);
        }
    }
    server.abort();
}
