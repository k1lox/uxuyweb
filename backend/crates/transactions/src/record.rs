use crate::SignedTransaction;
use botai_core::Chain;
use serde::{Deserialize, Serialize};
use serde_json::Value;
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TransactionRecord {
    pub chain: Chain,
    pub transaction_hash: String,
    pub sender: String,
    pub nonce: u64,
    pub status: String,
    pub message: Option<String>,
    pub receipt: Option<Value>,
    #[serde(default)]
    pub max_block_number: Option<u64>,
}
impl TransactionRecord {
    pub fn new(chain: Chain, tx: &SignedTransaction) -> Self {
        Self {
            chain,
            transaction_hash: tx.hash.clone(),
            sender: tx.sender.clone(),
            nonce: tx.nonce,
            status: "ambiguous".into(),
            message: None,
            receipt: None,
            max_block_number: None,
        }
    }
}
