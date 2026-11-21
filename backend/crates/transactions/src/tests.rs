use super::*;

#[test]
fn moved_or_removed_logs_cannot_confirm_a_transaction() {
    let receipt = |log: Value| json!({
        "transactionHash": "0xaaaa", "blockHash": "0xbbbb", "logs": [log]
    });
    for changed in [json!({"removed": true}), json!({"transactionHash": "0xcccc"}),
        json!({"blockHash":"0xdddd"})] {
        assert!(!receipt_logs_match_inclusion(&receipt(changed)));
    }
    assert!(receipt_logs_match_inclusion(&receipt(
        json!({"removed": false, "transactionHash": "0xAAAA", "blockHash": "0xBBBB"})
    )));
}
use alloy_consensus::{SignableTransaction, TxEnvelope};
use alloy_eips::eip2718::{Decodable2718, Encodable2718};
use alloy_primitives::{Bytes, keccak256};
use axum::{
    Json, Router,
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::post,
};
use std::{
    collections::{HashMap, HashSet},
    sync::atomic::{AtomicUsize, Ordering},
};
use tempfile::TempDir;
use tokio::sync::Mutex;

// Deterministic, zero-funded test signatures. Transport in this module is LOCAL ONLY.
const A0: &str = "0xf86580843b9aca0082520894000000000000000000000000000000000000dead01808201aca0c155b106934809be2199cd6210abb662bc8a83de746edf185fcb014c71cdc95fa07862c4d57bdc148615a626baabc1b00e270ca32c2f8956d2f76fc58edd0fcdf4";
const A1: &str = "0xf86501843b9aca0082520894000000000000000000000000000000000000dead01808201aba0edf302edaac2f7c1d2b1805ee5ab66a3f28c49488bb2794e72a4025350d7ee3fa01b2e4a57601db9e900e8533b84369b370eea7274052e81d3e1c6b19b7997d02e";
const B0: &str = "0xf86580843b9aca0082520894000000000000000000000000000000000000dead01808201aba0d428bb91546b49c9484f8f7c3e3fc6f664cf8220dacf9daada7728d3aafb8151a04c61ca333a7ed7ce880b14eee24c003fc2bd4f8b139e8722822c0d271ef83134";
const RH: &str = "0xf86580843b9aca0082520894000000000000000000000000000000000000dead0180822491a02d5a57b5be427d5f9fef02702c70756dbd73b6337fddc134b92bd5bdb8905621a0341388c5d1cf2f8addb1838bf84308caadba644a6d3e16f45d523dfdbd4a3885";
const ARC: &str = "0xf866808504a817c80082520894000000000000000000000000000000000000dead0180822787a0bf0f4803ab18455617a25366b14084a46c90bef5775ae34350e924a0505e7330a008b297599d26346f5d188adfac7d4bf32c46338dcd172f64d45d054b3e32983b";
const BSC: &str = "0xf86480843b9aca0082520894000000000000000000000000000000000000dead01808194a08daba645c5448fd844c63e87cb6e2b4fd301060c1213d26cff03bc6f6f296772a00aa4390815114b3c8f5970a885b04ee32ae8f400ce99012b20e23360f7e26e0f";
fn hash(raw: &str) -> String {
    format!("{:#x}", keccak256(raw.parse::<Bytes>().unwrap()))
}

fn distinct_signed_transactions(template: &str, count: usize) -> Vec<String> {
    let bytes = template.parse::<Bytes>().unwrap();
    let TxEnvelope::Legacy(signed) = TxEnvelope::decode_2718_exact(&bytes).unwrap() else {
        panic!("legacy test fixture required");
    };
    (0..count)
        .map(|nonce| {
            let mut tx = signed.tx().clone();
            tx.nonce = nonce as u64;
            // Reusing a valid signature over distinct messages recovers distinct
            // synthetic senders. These bytes only reach the local mock relay.
            let envelope = TxEnvelope::Legacy(tx.into_signed(*signed.signature()));
            format!("{:#x}", Bytes::from(envelope.encoded_2718()))
        })
        .collect()
}

#[test]
fn bundle_capacity_accepts_205_and_301_without_changing_regular_batch_limits() {
    let raws = distinct_signed_transactions(BSC, 302);
    for count in [205, 301] {
        assert_eq!(validate_bundle(&raws[..count]).unwrap().len(), count);
    }
    assert!(validate_bundle(&raws).is_err());
    assert!(validate_bundle(&[]).is_err());
    for (chain, template, maximum) in [
        (Chain::Bsc, BSC, 103),
        (Chain::Robinhood, RH, 200),
        (Chain::Xlayer, A0, 200),
        (Chain::Arc, ARC, 100),
    ] {
        assert_eq!(chain.config().max_transactions, maximum);
        let raws = distinct_signed_transactions(template, maximum + 1);
        assert_eq!(
            validate_batch(chain, &raws[..maximum]).unwrap().len(),
            maximum
        );
        assert!(validate_batch(chain, &raws).is_err());
    }
    let mut invalid = raws[..301].to_vec();
    invalid[300] = invalid[0].clone();
    assert!(validate_bundle(&invalid).is_err());
    invalid[300] = RH.into();
    assert!(validate_bundle(&invalid).is_err());
}
#[derive(Clone, Default)]
struct Mock {
    sent: Arc<Mutex<Vec<String>>>,
    submissions: Arc<Mutex<Vec<Value>>>,
    confirmed: Arc<Mutex<HashSet<String>>>,
    mode: Arc<AtomicUsize>,
    relay: Arc<Mutex<Vec<Value>>>,
}
async fn rpc(State(mock): State<Mock>, Json(rows): Json<Vec<Value>>) -> Response {
    let mut results = vec![];
    for row in rows {
        let method = row["method"].as_str().unwrap();
        let params = &row["params"];
        let mut response = json!({"jsonrpc":"2.0","id":row["id"]});
        let result = match method {
            "eth_sendRawTransaction" => {
                let raw = params[0].as_str().unwrap();
                let hash = hash(raw);
                mock.sent.lock().await.push(hash.clone());
                mock.submissions.lock().await.push(row.clone());
                match mock.mode.load(Ordering::SeqCst) {
                    1 if raw == A0 => {
                        response["error"] = json!({"code":-32000,"message":"insufficient funds"});
                        Value::Null
                    }
                    2 => json!("0xwrong-response"),
                    3 => return (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response(),
                    4 => {
                        return (StatusCode::BAD_GATEWAY, "upstream response lost").into_response();
                    }
                    _ => json!(hash),
                }
            }
            "eth_getTransactionReceipt" => {
                let hash = params[0].as_str().unwrap();
                if mock.confirmed.lock().await.contains(hash) {
                    json!({"transactionHash":hash,"status":"0x1","blockNumber":"0x64"})
                } else {
                    Value::Null
                }
            }
            "eth_getTransactionByHash" => Value::Null,
            "eth_blockNumber" => json!("0x68"),
            _ => panic!("unexpected method {method}"),
        };
        if response.get("error").is_none() {
            response["result"] = result;
        }
        results.push(response);
    }
    Json(json!(results)).into_response()
}
async fn relay(State(mock): State<Mock>, Json(body): Json<Value>) -> Response {
    mock.relay.lock().await.push(body.clone());
    match mock.mode.load(Ordering::SeqCst) {
        3 => return (StatusCode::TOO_MANY_REQUESTS, "rate limited").into_response(),
        4 => return (StatusCode::BAD_GATEWAY, "upstream response lost").into_response(),
        5 => return Json(json!({"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"account bundle size limit"}})).into_response(),
        6 => return Json(json!({"jsonrpc":"2.0","id":1,"result":{"bundleHash":"not-a-hash"}})).into_response(),
        _ => {},
    }
    assert_eq!(body["method"], "blxr_submit_bundle");
    let result = json!({"bundleHash":format!("0x{}","1".repeat(64))});
    Json(json!({"jsonrpc":"2.0","id":1,"result":result})).into_response()
}
async fn setup() -> (Transactions, Mock, TempDir, tokio::task::JoinHandle<()>) {
    let mock = Mock::default();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let root = format!("http://{}", listener.local_addr().unwrap());
    let app = Router::new()
        .route("/rpc", post(rpc))
        .route("/relay", post(relay))
        .with_state(mock.clone());
    let server = tokio::spawn(async { axum::serve(listener, app).await.unwrap() });
    let http = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(2))
        .build()
        .unwrap();
    let urls = Chain::ALL
        .into_iter()
        .map(|chain| (chain, format!("{root}/rpc")))
        .collect::<HashMap<_, _>>();
    let directory = TempDir::new().unwrap();
    let store = Store::open(directory.path().join("transactions.sqlite")).unwrap();
    let mut service = Transactions::new(
        store,
        Rpc::with_urls(http.clone(), urls),
        http,
        "TEST_AUTH".into(),
    );
    service.relay_url = format!("{root}/relay").into();
    (service, mock, directory, server)
}
async fn until(mut predicate: impl AsyncFnMut() -> bool) {
    tokio::time::timeout(Duration::from_secs(4), async {
        while !predicate().await {
            tokio::time::sleep(Duration::from_millis(5)).await
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn revoked_permission_stops_a_queued_dependent_send_without_claiming_its_nonce() {
    let (service, mock, _directory, server) = setup().await;
    let checks = Arc::new(AtomicUsize::new(0));
    let count = checks.clone();
    let service = service.authorized(move || {
        if count.fetch_add(1, Ordering::SeqCst) >= 2 {
            Err(AppError::new(
                "MEMBERSHIP_REQUIRED",
                "请先开通会员",
                403,
                false,
            ))
        } else {
            Ok(())
        }
    });
    let sending = service.clone();
    let task = tokio::spawn(async move {
        sending
            .submit(Chain::Xlayer, vec![A0.into(), A1.into()])
            .await
    });
    until(async || mock.sent.lock().await.len() == 1).await;
    mock.confirmed.lock().await.insert(hash(A0));
    let result = task.await.unwrap().unwrap();
    assert_eq!(result[1].status, "not_submitted");
    assert_eq!(mock.sent.lock().await.len(), 1);
    assert!(
        service
            .store
            .get(Chain::Xlayer, &hash(A1))
            .unwrap()
            .is_none()
    );
    server.abort();
}
#[tokio::test]
async fn membership_gate_covers_bundles_and_single_sends_before_network() {
    let (service, mock, _directory, server) = setup().await;
    let service = service.authorized(|| {
        Err(AppError::new(
            "MEMBERSHIP_REQUIRED",
            "请先开通会员",
            403,
            false,
        ))
    });
    assert!(
        service
            .submit(Chain::Xlayer, vec![A0.into()])
            .await
            .unwrap_err()
            .not_submitted
    );
    assert!(
        service
            .submit(Chain::Robinhood, vec![RH.into()])
            .await
            .unwrap_err()
            .not_submitted
    );
    assert!(
        service
            .submit_bundle(vec![BSC.into()], 100)
            .await
            .unwrap_err()
            .not_submitted
    );
    assert!(mock.sent.lock().await.is_empty());
    assert!(mock.relay.lock().await.is_empty());
    assert!(service.store.pending().unwrap().is_empty());
    server.abort();
}

#[tokio::test]
async fn explicit_bundle_rejection_releases_claim_but_uncertain_response_never_does() {
    for mode in [3, 4, 5, 6] {
        let (service, mock, _directory, server) = setup().await;
        mock.mode.store(mode, Ordering::SeqCst);
        let failure = service
            .submit_bundle(vec![BSC.into()], 200)
            .await
            .unwrap_err();
        let rejected = mode == 3 || mode == 5;
        assert_eq!(failure.not_submitted, rejected);
        assert_eq!(
            service
                .store
                .get(Chain::Bsc, &hash(BSC))
                .unwrap()
                .unwrap()
                .status,
            if rejected { "rejected" } else { "ambiguous" }
        );
        mock.mode.store(0, Ordering::SeqCst);
        let retry = service.submit_bundle(vec![BSC.into()], 201).await;
        assert_eq!(retry.is_ok(), rejected);
        assert_eq!(mock.relay.lock().await.len(), if rejected { 2 } else { 1 });
        server.abort();
    }
}

#[tokio::test]
async fn large_bundle_is_sent_once_in_order_and_tracks_every_transaction() {
    for count in [205, 301] {
        let (service, mock, _directory, server) = setup().await;
        let raws = distinct_signed_transactions(BSC, count);
        service.submit_bundle(raws.clone(), 200).await.unwrap();
        let requests = mock.relay.lock().await;
        assert_eq!(requests.len(), 1);
        assert_eq!(requests[0]["method"], "blxr_submit_bundle");
        assert_eq!(requests[0]["params"]["max_block_number"], 200);
        assert_eq!(requests[0]["params"]["reverting_tx_hashes"], json!([]));
        assert_eq!(
            requests[0]["params"]["txs"],
            json!(
                raws.iter()
                    .map(|raw| raw.trim_start_matches("0x"))
                    .collect::<Vec<_>>()
            )
        );
        drop(requests);
        assert!(mock.sent.lock().await.is_empty());
        let pending = service.store.pending().unwrap();
        assert_eq!(pending.len(), count);
        assert!(pending.iter().all(|row| row.chain == Chain::Bsc
            && row.status == "accepted"
            && row.max_block_number == Some(200)));
        let last_hash = hash(raws.last().unwrap());
        mock.confirmed.lock().await.insert(last_hash.clone());
        let confirmed = service
            .refresh(Chain::Bsc, &last_hash)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(confirmed.status, "confirmed");
        assert_eq!(service.store.pending().unwrap().len(), count - 1);
        assert_eq!(mock.relay.lock().await.len(), 1);
        server.abort();
    }
}

#[tokio::test]
async fn oversized_bundle_is_rejected_before_nonce_claims_or_network() {
    let (service, mock, _directory, server) = setup().await;
    let raws = distinct_signed_transactions(BSC, 302);
    let failure = service.submit_bundle(raws, 200).await.unwrap_err();
    assert!(failure.not_submitted);
    assert!(mock.relay.lock().await.is_empty());
    assert!(mock.sent.lock().await.is_empty());
    assert!(service.store.pending().unwrap().is_empty());
    server.abort();
}
#[tokio::test]
async fn robinhood_rate_limit_can_retry_same_bytes_without_leaving_an_unknown_nonce() {
    let (service, mock, _directory, server) = setup().await;
    mock.mode.store(3, Ordering::SeqCst);
    let result = service
        .submit(Chain::Robinhood, vec![RH.into()])
        .await
        .unwrap();
    assert_eq!(result[0].status, "rejected");
    mock.mode.store(0, Ordering::SeqCst);
    let result = service
        .submit(Chain::Robinhood, vec![RH.into()])
        .await
        .unwrap();
    assert_eq!(result[0].status, "accepted");
    assert_eq!(result[0].transaction_hash, hash(RH));
    let rows = mock.submissions.lock().await;
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["params"], json!([RH]));
    assert_eq!(rows[1]["params"], json!([RH]));
    assert!(mock.relay.lock().await.is_empty());
    server.abort();
}

#[tokio::test]
async fn robinhood_uncertain_rpc_responses_track_original_hash_without_resending() {
    for mode in [2, 4] {
        let (service, mock, _directory, server) = setup().await;
        mock.mode.store(mode, Ordering::SeqCst);
        let result = service
            .submit(Chain::Robinhood, vec![RH.into()])
            .await
            .unwrap();
        assert_eq!(result[0].status, "ambiguous");
        assert_eq!(result[0].transaction_hash, hash(RH));
        mock.mode.store(0, Ordering::SeqCst);
        let repeated = service
            .submit(Chain::Robinhood, vec![RH.into()])
            .await
            .unwrap();
        assert_eq!(repeated[0].status, "ambiguous");
        assert_eq!(mock.submissions.lock().await.len(), 1);
        mock.confirmed.lock().await.insert(hash(RH));
        assert_eq!(
            service
                .refresh(Chain::Robinhood, &hash(RH))
                .await
                .unwrap()
                .unwrap()
                .status,
            "confirmed"
        );
        assert_eq!(mock.submissions.lock().await.len(), 1);
        assert!(mock.relay.lock().await.is_empty());
        server.abort();
    }
}

#[tokio::test]
async fn non_bsc_rpc_sends_do_not_require_bundle_relay_authorization() {
    let (mut service, mock, _directory, server) = setup().await;
    service.authorization = "".into();
    for (chain, raw) in [
        (Chain::Robinhood, RH),
        (Chain::Xlayer, A0),
        (Chain::Arc, ARC),
    ] {
        let result = service.submit(chain, vec![raw.into()]).await.unwrap();
        assert_eq!(result[0].status, "accepted");
        assert_eq!(result[0].transaction_hash, hash(raw));
    }
    let error = service
        .submit_bundle(vec![BSC.into()], 100)
        .await
        .unwrap_err();
    assert_eq!(error.code, "AUTH_NOT_CONFIGURED");
    assert!(error.not_submitted);
    let submissions = mock.submissions.lock().await;
    assert_eq!(submissions.len(), 3);
    for (request, raw) in submissions.iter().zip([RH, A0, ARC]) {
        assert_eq!(request["method"], "eth_sendRawTransaction");
        assert_eq!(request["params"], json!([raw]));
    }
    assert!(mock.relay.lock().await.is_empty());
    assert!(service.store.get(Chain::Bsc, &hash(BSC)).unwrap().is_none());
    server.abort();
}

#[tokio::test]
async fn akc_selection_retains_membership_gate_and_shared_sender_lanes() {
    let (service, mock, _directory, server) = setup().await;
    let bytes = ARC.parse::<Bytes>().unwrap();
    let TxEnvelope::Legacy(signed) = TxEnvelope::decode_2718_exact(&bytes).unwrap() else {
        panic!("legacy");
    };
    let mut tx = signed.tx().clone();
    tx.chain_id = Some(9070);
    let envelope = TxEnvelope::Legacy(tx.into_signed(*signed.signature()));
    let raw = format!("{:#x}", Bytes::from(envelope.encoded_2718()));
    assert!(validate_batch(Chain::Bsc, &[raw.clone()]).is_err());
    let scoped = service
        .clone()
        .with_rpc(service.rpc.select_endpoint(Chain::Akc, 0).unwrap());
    assert!(Arc::ptr_eq(&scoped.lanes, &service.lanes));
    let rejected = service
        .authorized(|| {
            Err(AppError::new(
                "MEMBERSHIP_REQUIRED",
                "会员未开通",
                403,
                false,
            ))
        })
        .with_rpc(scoped.rpc.clone())
        .submit(Chain::Akc, vec![raw.clone()])
        .await
        .unwrap_err();
    assert!(rejected.not_submitted);
    assert!(mock.sent.lock().await.is_empty());
    let result = scoped.submit(Chain::Akc, vec![raw.clone()]).await.unwrap();
    assert_eq!(result[0].status, "accepted");
    assert_eq!(result[0].transaction_hash, hash(&raw));
    assert!(mock.relay.lock().await.is_empty());
    server.abort();
}

#[tokio::test]
async fn same_sender_waits_but_other_wallet_proceeds_and_duplicates_are_idempotent() {
    let (service, mock, _directory, server) = setup().await;
    let task = tokio::spawn({
        let service = service.clone();
        async move {
            service
                .submit(Chain::Xlayer, vec![A0.into(), A1.into(), B0.into()])
                .await
                .unwrap()
        }
    });
    until(async || mock.sent.lock().await.len() == 2).await;
    assert!(mock.sent.lock().await.contains(&hash(B0)));
    assert!(!mock.sent.lock().await.contains(&hash(A1)));
    mock.confirmed.lock().await.insert(hash(A0));
    let rows = tokio::time::timeout(Duration::from_secs(4), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(rows.len(), 3);
    assert_eq!(rows[1].status, "accepted");
    service
        .submit(Chain::Xlayer, vec![A0.into(), A1.into(), B0.into()])
        .await
        .unwrap();
    assert_eq!(mock.sent.lock().await.len(), 3);
    server.abort();
}
#[tokio::test]
async fn failed_predecessor_blocks_only_its_own_lane() {
    let (service, mock, _directory, server) = setup().await;
    mock.mode.store(1, Ordering::SeqCst);
    let rows = service
        .submit(Chain::Xlayer, vec![A0.into(), A1.into(), B0.into()])
        .await
        .unwrap();
    assert_eq!(
        rows.iter().map(|r| r.status.as_str()).collect::<Vec<_>>(),
        vec!["rejected", "not_submitted", "accepted"]
    );
    assert_eq!(mock.sent.lock().await.len(), 2);
    server.abort();
}
#[tokio::test]
async fn tracked_lookup_recovers_an_old_removed_receipt_without_resubmitting() {
    let (service, mock, _directory, server) = setup().await;
    service.submit(Chain::Xlayer, vec![A0.into()]).await.unwrap();
    let hash = hash(A0);
    let mut old = service.store.get(Chain::Xlayer, &hash).unwrap().unwrap();
    old.status = "confirmed".into();
    old.receipt = Some(json!({"transactionHash":hash,"status":"0x1","blockNumber":"0x64",
        "logs":[{"removed":true}]}));
    service.store.update(&old).unwrap();
    let pending = service.tracked(Chain::Xlayer, &hash).await.unwrap().unwrap();
    assert_eq!(pending.status, "ambiguous");
    assert!(pending.receipt.is_none());
    mock.confirmed.lock().await.insert(hash.clone());
    service.rpc.invalidate_latest(Chain::Xlayer).await;
    let fixed = service.tracked(Chain::Xlayer, &hash).await.unwrap().unwrap();
    assert_eq!(fixed.status, "confirmed");
    assert!(receipt_logs_match_inclusion(&fixed.receipt.unwrap()));
    assert_eq!(mock.sent.lock().await.len(), 1);
    server.abort();
}

#[tokio::test]
async fn ambiguous_response_can_confirm_then_unlock_dependency_without_rebroadcast() {
    let (service, mock, _directory, server) = setup().await;
    mock.mode.store(2, Ordering::SeqCst);
    let task = tokio::spawn({
        let service = service.clone();
        async move {
            service
                .submit(Chain::Xlayer, vec![A0.into(), A1.into()])
                .await
                .unwrap()
        }
    });
    until(async || mock.sent.lock().await.len() == 1).await;
    mock.confirmed.lock().await.insert(hash(A0));
    let rows = tokio::time::timeout(Duration::from_secs(4), task)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(mock.sent.lock().await.len(), 2);
    assert_eq!(rows[1].status, "ambiguous");
    service
        .submit(Chain::Xlayer, vec![A1.into()])
        .await
        .unwrap();
    assert_eq!(mock.sent.lock().await.len(), 2);
    server.abort();
}
#[tokio::test]
async fn browser_disconnect_does_not_cancel_accepted_work_and_restart_reads_original_hash() {
    let (service, mock, directory, server) = setup().await;
    let task = tokio::spawn({
        let service = service.clone();
        async move {
            service
                .submit(Chain::Xlayer, vec![A0.into(), A1.into()])
                .await
        }
    });
    until(async || mock.sent.lock().await.len() == 1).await;
    task.abort();
    mock.confirmed.lock().await.insert(hash(A0));
    until(async || mock.sent.lock().await.len() == 2).await;
    mock.confirmed.lock().await.insert(hash(A1));
    let restarted = Transactions::new(
        Store::open(directory.path().join("transactions.sqlite")).unwrap(),
        service.rpc.clone(),
        service.http.clone(),
        String::new(),
    );
    restarted.rpc.invalidate_latest(Chain::Xlayer).await;
    assert_eq!(
        restarted
            .refresh(Chain::Xlayer, &hash(A1))
            .await
            .unwrap()
            .unwrap()
            .status,
        "confirmed"
    );
    assert_eq!(mock.sent.lock().await.len(), 2);
    server.abort();
}
#[tokio::test]
async fn legacy_robinhood_reward_is_not_forwarded_and_bsc_only_uses_private_bundle() {
    let (service, mock, _directory, server) = setup().await;
    let reward = "0x0000000000000000000000000000000000001234"
        .parse()
        .unwrap();
    service
        .submit_with_options(
            Chain::Robinhood,
            vec![RH.into()],
            SubmitOptions {
                backrunme_reward_address: Some(reward),
            },
        )
        .await
        .unwrap();
    let submissions = mock.submissions.lock().await;
    assert_eq!(submissions.len(), 1);
    assert_eq!(submissions[0]["method"], "eth_sendRawTransaction");
    assert_eq!(submissions[0]["params"], json!([RH]));
    drop(submissions);
    assert!(mock.relay.lock().await.is_empty());
    assert!(
        service
            .submit(Chain::Bsc, vec![BSC.into()])
            .await
            .unwrap_err()
            .not_submitted
    );
    service.submit_bundle(vec![BSC.into()], 100).await.unwrap();
    assert_eq!(
        mock.relay.lock().await[0]["params"]["txs"],
        json!([BSC.trim_start_matches("0x")])
    );
    assert_eq!(*mock.sent.lock().await, vec![hash(RH)]);
    server.abort();
}
#[tokio::test]
async fn bad_signature_chain_or_reward_is_rejected_before_network() {
    let (service, mock, _directory, server) = setup().await;
    assert!(
        service
            .submit(Chain::Xlayer, vec![RH.into()])
            .await
            .is_err()
    );
    assert!(
        service
            .submit(Chain::Xlayer, vec!["0x1234".into()])
            .await
            .is_err()
    );
    assert!(
        service
            .submit(Chain::Xlayer, vec![A1.into(), A0.into()])
            .await
            .is_err()
    );
    assert!(
        service
            .submit_with_options(
                Chain::Xlayer,
                vec![A0.into()],
                SubmitOptions {
                    backrunme_reward_address: Some(Address::ZERO)
                }
            )
            .await
            .is_err()
    );
    assert!(mock.sent.lock().await.is_empty());
    assert!(mock.relay.lock().await.is_empty());
    server.abort();
}

#[tokio::test]
async fn separate_requests_wait_for_same_wallet_but_not_other_wallets() {
    let (service, mock, _directory, server) = setup().await;
    service
        .submit(Chain::Xlayer, vec![A0.into()])
        .await
        .unwrap();
    let next = tokio::spawn({
        let service = service.clone();
        async move {
            service
                .submit(Chain::Xlayer, vec![A1.into()])
                .await
                .unwrap()
        }
    });
    service
        .submit(Chain::Xlayer, vec![B0.into()])
        .await
        .unwrap();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(*mock.sent.lock().await, vec![hash(A0), hash(B0)]);
    mock.confirmed.lock().await.insert(hash(A0));
    assert_eq!(next.await.unwrap()[0].status, "accepted");
    assert_eq!(mock.sent.lock().await.len(), 3);
    server.abort();
}

#[tokio::test]
async fn restart_tracker_recovers_pending_without_resending_and_expires_private_bundle() {
    let (service, mock, directory, server) = setup().await;
    // Simulate process termination after acceptance persisted, before receipt polling.
    let signed = validate_batch(Chain::Xlayer, &[A0.into()]).unwrap();
    service.store.claim(Chain::Xlayer, &signed[0]).unwrap();
    let bundle = validate_batch(Chain::Bsc, &[BSC.into()]).unwrap();
    service.store.claim_bundle(&bundle, 100).unwrap();
    let restarted = Transactions::new(
        Store::open(directory.path().join("transactions.sqlite")).unwrap(),
        service.rpc.clone(),
        service.http.clone(),
        String::new(),
    );
    mock.confirmed.lock().await.insert(hash(A0));
    let tracker = restarted.start_tracking();
    until(async || restarted.store.pending().unwrap().is_empty()).await;
    assert_eq!(
        restarted
            .store
            .get(Chain::Xlayer, &hash(A0))
            .unwrap()
            .unwrap()
            .status,
        "confirmed"
    );
    assert_eq!(
        restarted
            .store
            .get(Chain::Bsc, &hash(BSC))
            .unwrap()
            .unwrap()
            .status,
        "not_included"
    );
    assert!(mock.sent.lock().await.is_empty());
    assert!(mock.relay.lock().await.is_empty());
    // Expiry releases the reservation; only an explicit new request may submit.
    restarted.store.claim_bundle(&bundle, 200).unwrap();
    tracker.abort();
    server.abort();
}
