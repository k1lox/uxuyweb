#[cfg(any(test, feature = "test-support"))]
use crate::sqlite;
use crate::{SignedTransaction, record::TransactionRecord};
use botai_core::{AppError, Chain, Result};
use botai_database::{
    Database, error,
    mysql::{TxOpts, params, prelude::Queryable},
};
#[cfg(any(test, feature = "test-support"))]
use std::path::Path;

#[derive(Clone)]
pub enum Store {
    Mysql(Database),
    #[cfg(any(test, feature = "test-support"))]
    Test(sqlite::Store),
}
fn decode(payload: String) -> Result<TransactionRecord> {
    serde_json::from_str(&payload).map_err(error)
}
impl Store {
    pub fn mysql(db: Database) -> Self {
        Self::Mysql(db)
    }
    /// Isolated test store, unavailable in normal production builds.
    #[cfg(any(test, feature = "test-support"))]
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Ok(Self::Test(sqlite::Store::open(path)?))
    }
    pub fn get(&self, chain: Chain, hash: &str) -> Result<Option<TransactionRecord>> {
        match self {
            #[cfg(any(test, feature = "test-support"))]
            Self::Test(s) => s.get(chain, hash),
            Self::Mysql(db) => db.run(|c| {
                c.exec_first::<String, _, _>(
                    "SELECT payload FROM botai_transactions WHERE chain=? AND hash=?",
                    (chain.config().id, hash),
                )
                .map_err(error)?
                .map(decode)
                .transpose()
            }),
        }
    }
    pub fn pending(&self) -> Result<Vec<TransactionRecord>> {
        match self {
            #[cfg(any(test, feature = "test-support"))]
            Self::Test(s) => s.pending(),
            Self::Mysql(db) => db.run(|c| c.query::<String,_>("SELECT payload FROM botai_transactions WHERE status IN ('accepted','ambiguous')").map_err(error)?.into_iter().map(decode).collect())
        }
    }
    pub fn predecessors(
        &self,
        chain: Chain,
        sender: &str,
        nonce: u64,
    ) -> Result<Vec<TransactionRecord>> {
        match self {
            #[cfg(any(test, feature = "test-support"))]
            Self::Test(s)=>s.predecessors(chain,sender,nonce),
            Self::Mysql(db)=>db.run(|c| {
                let mut rows=c.exec::<String,_,_>("SELECT payload FROM botai_transactions WHERE chain=? AND sender=? AND status IN ('accepted','ambiguous')",(chain.config().id,sender)).map_err(error)?.into_iter().map(decode).collect::<Result<Vec<_>>>()?;
                rows.retain(|r|r.nonce<nonce); rows.sort_by_key(|r|r.nonce); Ok(rows)
            })
        }
    }
    pub fn claim(&self, chain: Chain, tx: &SignedTransaction) -> Result<Option<TransactionRecord>> {
        match self {
            #[cfg(any(test, feature = "test-support"))]
            Self::Test(s)=>s.claim(chain,tx),
            Self::Mysql(db)=>db.run(|c| {
                let mut t=c.start_transaction(TxOpts::default()).map_err(error)?;
                if let Some(s)=t.exec_first::<String,_,_>("SELECT payload FROM botai_transactions WHERE chain=? AND hash=? FOR UPDATE",(chain.config().id,&tx.hash)).map_err(error)? {
                    let row=decode(s)?;
                    if !["rejected","not_included"].contains(&row.status.as_str()) { return Ok(Some(row)); }
                }
                claim_nonce(&mut t,chain,tx)?;
                put(&mut t,&TransactionRecord::new(chain,tx))?;
                t.commit().map_err(error)?; Ok(None)
            })
        }
    }
    pub fn claim_bundle(&self, signed: &[SignedTransaction], max_block: u64) -> Result<()> {
        match self {
            #[cfg(any(test, feature = "test-support"))]
            Self::Test(s) => s.claim_bundle(signed, max_block),
            Self::Mysql(db) => db.run(|c| {
                let mut t = c.start_transaction(TxOpts::default()).map_err(error)?;
                for tx in signed {
                    claim_nonce(&mut t, Chain::Bsc, tx)?;
                    let mut row = TransactionRecord::new(Chain::Bsc, tx);
                    row.max_block_number = Some(max_block);
                    put(&mut t, &row)?;
                }
                t.commit().map_err(error)
            }),
        }
    }
    pub fn update(&self, r: &TransactionRecord) -> Result<()> {
        match self {
            #[cfg(any(test, feature = "test-support"))]
            Self::Test(s)=>s.update(r),
            Self::Mysql(db)=>db.run(|c| {
                let mut t=c.start_transaction(TxOpts::default()).map_err(error)?;
                t.exec_drop("UPDATE botai_transactions SET status=:status,payload=:payload WHERE chain=:chain AND hash=:hash AND max_block <=> :max AND (status NOT IN ('confirmed','reverted','rejected','not_included') OR status=:status)",params!{"status"=>&r.status,"payload"=>serde_json::to_string(r).map_err(error)?,"chain"=>r.chain.config().id,"hash"=>&r.transaction_hash,"max"=>r.max_block_number}).map_err(error)?;
                if t.affected_rows()>0 && ["rejected","not_included"].contains(&r.status.as_str()) {
                    t.exec_drop("DELETE FROM botai_nonce_claims WHERE chain=? AND sender=? AND nonce=? AND hash=?",(r.chain.config().id,&r.sender,r.nonce.to_string(),&r.transaction_hash)).map_err(error)?;
                }
                t.commit().map_err(error)
            })
        }
    }
}
fn claim_nonce(t: &mut impl Queryable, chain: Chain, tx: &SignedTransaction) -> Result<()> {
    t.exec_drop(
        "INSERT INTO botai_nonce_claims VALUES(?,?,?,?)",
        (
            chain.config().id,
            &tx.sender,
            tx.nonce.to_string(),
            &tx.hash,
        ),
    )
    .map_err(|e| match e {
        botai_database::mysql::Error::MySqlError(ref m) if m.code == 1062 => {
            AppError::new("NONCE_RESERVED", "该地址序号已有待确认交易", 409, false)
        }
        _ => error(e),
    })
}
fn put(t: &mut impl Queryable, r: &TransactionRecord) -> Result<()> {
    t.exec_drop("INSERT INTO botai_transactions VALUES(:chain,:hash,:sender,:nonce,:status,:max,:payload) ON DUPLICATE KEY UPDATE status=VALUES(status),max_block=VALUES(max_block),payload=VALUES(payload)",params!{"chain"=>r.chain.config().id,"hash"=>&r.transaction_hash,"sender"=>&r.sender,"nonce"=>r.nonce.to_string(),"status"=>&r.status,"max"=>r.max_block_number,"payload"=>serde_json::to_string(r).map_err(error)?}).map_err(error)
}
