use botai_core::Chain;
use botai_database::{Database, error, mysql::prelude::Queryable};
use botai_transactions::{SignedTransaction, Store, TransactionRecord};
fn tx(hash: &str, nonce: u64) -> SignedTransaction {
    SignedTransaction {
        raw: "NEVER_PERSIST_RAW".into(),
        hash: hash.into(),
        sender: "local-fixture".into(),
        nonce,
    }
}
#[test]
#[ignore = "requires isolated local MySQL botai_tx_test on port 33316"]
fn mysql_nonce_claims_and_monotonic_receipts() {
    let db = Database::connect("127.0.0.1", 33316, "botai_tx_test", "root", "").unwrap();
    db.schema().unwrap();
    db.run(|c| {
        c.query_drop("DELETE FROM botai_nonce_claims")
            .map_err(error)?;
        c.query_drop("DELETE FROM botai_transactions")
            .map_err(error)
    })
    .unwrap();
    let store = Store::mysql(db.clone());
    let first = tx("first", 1);
    assert!(store.claim(Chain::Xlayer, &first).unwrap().is_none());
    assert!(store.claim(Chain::Xlayer, &first).unwrap().is_some());
    assert!(store.claim(Chain::Xlayer, &tx("different", 1)).is_err());
    let mut row = TransactionRecord::new(Chain::Xlayer, &first);
    row.status = "confirmed".into();
    store.update(&row).unwrap();
    store
        .update(&TransactionRecord::new(Chain::Xlayer, &first))
        .unwrap();
    assert_eq!(
        store.get(Chain::Xlayer, "first").unwrap().unwrap().status,
        "confirmed"
    );
    assert!(
        store
            .claim_bundle(&[tx("bundle-a", 5), tx("bundle-b", 5)], 100)
            .is_err()
    );
    assert!(store.get(Chain::Bsc, "bundle-a").unwrap().is_none());
    let failed = tx("failed", 2);
    store.claim(Chain::Xlayer, &failed).unwrap();
    let mut row = TransactionRecord::new(Chain::Xlayer, &failed);
    row.status = "rejected".into();
    store.update(&row).unwrap();
    store.claim(Chain::Xlayer, &tx("replacement", 2)).unwrap();
    assert_eq!(store.pending().unwrap().len(), 1);
    store
        .claim_bundle(&[tx("bundle-a", 5), tx("bundle-b", 6)], 100)
        .unwrap();
    let mut stale = TransactionRecord::new(Chain::Bsc, &tx("bundle-a", 5));
    stale.max_block_number = Some(99);
    stale.status = "not_included".into();
    store.update(&stale).unwrap();
    assert_eq!(
        store.get(Chain::Bsc, "bundle-a").unwrap().unwrap().status,
        "ambiguous"
    );
    let payloads: Vec<String> = db
        .run(|c| {
            c.query("SELECT payload FROM botai_transactions")
                .map_err(error)
        })
        .unwrap();
    assert!(payloads.iter().all(|s| !s.contains("NEVER_PERSIST_RAW")));
}
