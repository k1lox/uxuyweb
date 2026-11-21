use alloy_consensus::{Transaction, TxEnvelope, transaction::SignerRecoverable};
use alloy_eips::eip2718::Decodable2718;
use alloy_primitives::{Address, Bytes, keccak256};
use botai_core::{AppError, Chain, Result};
use std::collections::{HashMap, HashSet};

// 200 outer buys, 96 inner buys, one Dev buy and adapter/create/migrate/tip.
// This is a local validation limit; the relay account must support this size.
const MAX_BSC_BUNDLE_TRANSACTIONS: usize = 301;

// Intentionally not Serialize or Debug: raw signed transactions never enter logs/status APIs.
pub struct SignedTransaction {
    pub raw: String,
    pub hash: String,
    pub sender: String,
    pub nonce: u64,
}
pub fn validate_batch(chain: Chain, raws: &[String]) -> Result<Vec<SignedTransaction>> {
    validate_transactions(chain, raws, chain.config().max_transactions, |_, _| Ok(()))
}

pub fn validate_bundle(raws: &[String]) -> Result<Vec<SignedTransaction>> {
    Ok(validate_bundle_with_policy(raws, |_, _| Ok(()))?.0)
}

/// Only signature and chain validation can construct a relay-ready bundle.
pub struct ValidatedBundle(pub(crate) Vec<SignedTransaction>);

pub fn validate_bundle_with_policy(
    raws: &[String],
    policy: impl FnMut(&TxEnvelope, Address) -> Result<()>,
) -> Result<ValidatedBundle> {
    validate_transactions(Chain::Bsc, raws, MAX_BSC_BUNDLE_TRANSACTIONS, policy).map(ValidatedBundle)
}

fn validate_transactions(
    chain: Chain,
    raws: &[String],
    maximum: usize,
    mut policy: impl FnMut(&TxEnvelope, Address) -> Result<()>,
) -> Result<Vec<SignedTransaction>> {
    if raws.is_empty() || raws.len() > maximum {
        return Err(AppError::invalid("交易数量无效"));
    }
    let mut hashes = HashSet::new();
    let mut nonces = HashMap::new();
    raws.iter()
        .map(|raw| {
            if raw.len() > 160_000 || !raw.starts_with("0x") {
                return Err(AppError::invalid("签名交易格式无效"));
            }
            let bytes: Bytes = raw
                .parse()
                .map_err(|_| AppError::invalid("签名交易编码无效"))?;
            let tx = TxEnvelope::decode_2718_exact(&bytes)
                .map_err(|_| AppError::invalid("签名交易解析失败"))?;
            if tx.chain_id() != Some(chain.config().id)
                || tx.gas_limit() < 21_000
                || tx.gas_limit() > 30_000_000
                || tx.max_fee_per_gas() == 0
                || tx.max_fee_per_gas() > 1_000_000_000_000
                || chain == Chain::Arc && tx.max_fee_per_gas() < 20_000_000_000
            {
                return Err(AppError::invalid("签名交易链或网络费不符"));
            }
            let signer = tx.recover_signer().map_err(|_| AppError::invalid("交易签名无效"))?;
            policy(&tx, signer)?;
            let sender = format!("{signer:#x}");
            let hash = format!("{:#x}", keccak256(&bytes));
            if !hashes.insert(hash.clone()) {
                return Err(AppError::invalid("签名交易重复"));
            }
            if let Some(previous) = nonces.insert(sender.clone(), tx.nonce()) {
                if previous.checked_add(1) != Some(tx.nonce()) {
                    return Err(AppError::invalid("同地址交易序号不连续"));
                }
            }
            Ok(SignedTransaction {
                raw: raw.clone(),
                hash,
                sender,
                nonce: tx.nonce(),
            })
        })
        .collect()
}
