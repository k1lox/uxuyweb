// Isolated test store only. Never compiled into the default release.
use crate::{SignedTransaction, record::TransactionRecord};
use botai_core::{AppError, Chain, Result};
use rusqlite::{Connection, OptionalExtension, params};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};

#[derive(Clone)]
pub struct Store(Arc<Mutex<Connection>>);
fn failure(_: impl std::fmt::Display) -> AppError {
    AppError::new("TRANSACTION_STORE", "交易状态存储不可用", 503, false)
}
impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let db = Connection::open(path).map_err(failure)?;
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
            CREATE TABLE IF NOT EXISTS transactions(chain INTEGER NOT NULL, hash TEXT NOT NULL, sender TEXT NOT NULL, nonce TEXT NOT NULL, payload TEXT NOT NULL,
            PRIMARY KEY(chain,hash));
            CREATE TABLE IF NOT EXISTS nonce_claims(chain INTEGER NOT NULL,sender TEXT NOT NULL,nonce TEXT NOT NULL,hash TEXT NOT NULL,PRIMARY KEY(chain,sender,nonce));
            CREATE INDEX IF NOT EXISTS transactions_status ON transactions(json_extract(payload,'$.status'));").map_err(failure)?;
        Ok(Self(Arc::new(Mutex::new(db))))
    }
    pub fn get(&self, chain: Chain, hash: &str) -> Result<Option<TransactionRecord>> {
        self.0
            .lock()
            .map_err(failure)?
            .query_row(
                "SELECT payload FROM transactions WHERE chain=?1 AND hash=?2",
                params![chain.config().id as i64, hash],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(failure)?
            .map(|s| serde_json::from_str(&s).map_err(failure))
            .transpose()
    }
    pub fn pending(&self) -> Result<Vec<TransactionRecord>> {
        let db = self.0.lock().map_err(failure)?;
        let mut query = db.prepare("SELECT payload FROM transactions WHERE json_extract(payload,'$.status') IN ('accepted','ambiguous') ORDER BY rowid").map_err(failure)?;
        query
            .query_map([], |row| row.get::<_, String>(0))
            .map_err(failure)?
            .map(|row| serde_json::from_str(&row.map_err(failure)?).map_err(failure))
            .collect()
    }
    pub fn predecessors(
        &self,
        chain: Chain,
        sender: &str,
        nonce: u64,
    ) -> Result<Vec<TransactionRecord>> {
        let db = self.0.lock().map_err(failure)?;
        let mut query = db.prepare("SELECT payload FROM transactions WHERE chain=?1 AND sender=?2 AND json_extract(payload,'$.status') IN ('accepted','ambiguous')").map_err(failure)?;
        let rows: Result<Vec<TransactionRecord>> = query
            .query_map(params![chain.config().id as i64, sender], |row| {
                row.get::<_, String>(0)
            })
            .map_err(failure)?
            .map(|row| serde_json::from_str(&row.map_err(failure)?).map_err(failure))
            .collect();
        let mut rows = rows?;
        rows.retain(|row| row.nonce < nonce);
        rows.sort_by_key(|row| row.nonce);
        Ok(rows)
    }
    pub fn claim(&self, chain: Chain, tx: &SignedTransaction) -> Result<Option<TransactionRecord>> {
        let mut db = self.0.lock().map_err(failure)?;
        let db = db.transaction().map_err(failure)?;
        let found = db
            .query_row(
                "SELECT payload FROM transactions WHERE chain=?1 AND hash=?2",
                params![chain.config().id as i64, tx.hash],
                |r| r.get::<_, String>(0),
            )
            .optional()
            .map_err(failure)?;
        if let Some(payload) = found {
            let row: TransactionRecord = serde_json::from_str(&payload).map_err(failure)?;
            if !["rejected", "not_included"].contains(&row.status.as_str()) {
                return Ok(Some(row));
            }
        }
        let row = TransactionRecord::new(chain, tx);
        db.execute(
            "INSERT INTO nonce_claims VALUES(?1,?2,?3,?4)",
            params![
                chain.config().id as i64,
                tx.sender,
                tx.nonce.to_string(),
                tx.hash
            ],
        )
        .map_err(|_| AppError::new("NONCE_RESERVED", "该地址序号已有待确认交易", 409, false))?;
        db.execute(
            "INSERT OR REPLACE INTO transactions VALUES(?1,?2,?3,?4,?5)",
            params![
                chain.config().id as i64,
                tx.hash,
                tx.sender,
                tx.nonce.to_string(),
                serde_json::to_string(&row).map_err(failure)?
            ],
        )
        .map_err(failure)?;
        db.commit().map_err(failure)?;
        Ok(None)
    }
    pub fn claim_bundle(&self, signed: &[SignedTransaction], max_block: u64) -> Result<()> {
        let mut db = self.0.lock().map_err(failure)?;
        let transaction = db.transaction().map_err(failure)?;
        for tx in signed {
            let mut row = TransactionRecord::new(Chain::Bsc, tx);
            row.max_block_number = Some(max_block);
            transaction
                .execute(
                    "INSERT INTO nonce_claims VALUES(56,?1,?2,?3)",
                    params![tx.sender, tx.nonce.to_string(), tx.hash],
                )
                .map_err(|_| {
                    AppError::new(
                        "ALREADY_SUBMITTED",
                        "该交易或序号已提交，请查询原哈希",
                        409,
                        false,
                    )
                })?;
            transaction
                .execute(
                    "INSERT OR REPLACE INTO transactions VALUES(56,?1,?2,?3,?4)",
                    params![
                        tx.hash,
                        tx.sender,
                        tx.nonce.to_string(),
                        serde_json::to_string(&row).map_err(failure)?
                    ],
                )
                .map_err(failure)?;
        }
        transaction.commit().map_err(failure)
    }
    pub fn update(&self, record: &TransactionRecord) -> Result<()> {
        let mut db = self.0.lock().map_err(failure)?;
        let db = db.transaction().map_err(failure)?;
        let updated=db.execute("UPDATE transactions SET payload=?3 WHERE chain=?1 AND hash=?2 AND json_extract(payload,'$.maxBlockNumber') IS ?4 AND (json_extract(payload,'$.status') NOT IN ('confirmed','reverted','rejected','not_included') OR json_extract(payload,'$.status') = json_extract(?3,'$.status'))",
            params![record.chain.config().id as i64, record.transaction_hash,serde_json::to_string(record).map_err(failure)?,record.max_block_number.map(|n|n as i64)]).map_err(failure)?;
        if updated > 0 && ["rejected", "not_included"].contains(&record.status.as_str()) {
            db.execute(
                "DELETE FROM nonce_claims WHERE chain=?1 AND sender=?2 AND nonce=?3 AND hash=?4",
                params![
                    record.chain.config().id as i64,
                    record.sender,
                    record.nonce.to_string(),
                    record.transaction_hash
                ],
            )
            .map_err(failure)?;
        }
        db.commit().map_err(failure)?;
        Ok(())
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn tx(hash: &str, nonce: u64) -> SignedTransaction {
        SignedTransaction {
            raw: "DO_NOT_PERSIST".into(),
            hash: hash.into(),
            sender: "wallet".into(),
            nonce,
        }
    }
    #[test]
    fn claim_is_idempotent_and_nonce_conflict_does_not_overwrite() {
        let store = Store::open(":memory:").unwrap();
        assert!(
            store
                .claim(Chain::Xlayer, &tx("first", 1))
                .unwrap()
                .is_none()
        );
        assert!(
            store
                .claim(Chain::Xlayer, &tx("first", 1))
                .unwrap()
                .is_some()
        );
        assert!(store.claim(Chain::Xlayer, &tx("replacement", 1)).is_err());
        assert!(
            !serde_json::to_string(&store.get(Chain::Xlayer, "first").unwrap())
                .unwrap()
                .contains("DO_NOT_PERSIST")
        );
    }
    #[test]
    fn bundle_claim_is_atomic() {
        let store = Store::open(":memory:").unwrap();
        assert!(
            store
                .claim_bundle(&[tx("same", 1), tx("another", 1)], 100)
                .is_err()
        );
        assert!(store.get(Chain::Bsc, "same").unwrap().is_none());
    }
    #[test]
    fn definitive_failure_releases_nonce_but_unknown_does_not() {
        let store = Store::open(":memory:").unwrap();
        let first = tx("first", 1);
        store.claim(Chain::Xlayer, &first).unwrap();
        assert!(store.claim(Chain::Xlayer, &tx("new", 1)).is_err());
        let mut row = TransactionRecord::new(Chain::Xlayer, &first);
        row.status = "rejected".into();
        store.update(&row).unwrap();
        assert!(store.claim(Chain::Xlayer, &tx("new", 1)).unwrap().is_none());
    }
    #[test]
    fn stale_refresh_cannot_overwrite_confirmed_or_reverted_state() {
        for status in ["confirmed", "reverted"] {
            let store = Store::open(":memory:").unwrap();
            let tx = tx("first", 1);
            store.claim(Chain::Xlayer, &tx).unwrap();
            let pending = TransactionRecord::new(Chain::Xlayer, &tx);
            let mut terminal = pending.clone();
            terminal.status = status.into();
            store.update(&terminal).unwrap();
            store.update(&pending).unwrap();
            assert_eq!(
                store.get(Chain::Xlayer, "first").unwrap().unwrap().status,
                status
            );
        }
    }
}
