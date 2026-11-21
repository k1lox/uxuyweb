use crate::{AppError, Result};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Deserialize, Serialize, Eq, PartialEq, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Chain {
    Bsc,
    Robinhood,
    Xlayer,
    Arc,
    Akc,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChainConfig {
    pub chain: Chain,
    pub id: u64,
    pub native_symbol: &'static str,
    pub native_decimals: u8,
    pub quote_decimals: u8,
    pub private_bundle: bool,
    pub rpc_batch_limit: usize,
    pub max_transactions: usize,
}
impl Chain {
    pub const ALL: [Self; 5] = [
        Self::Bsc,
        Self::Robinhood,
        Self::Xlayer,
        Self::Arc,
        Self::Akc,
    ];
    pub fn config(self) -> ChainConfig {
        let (id, native_symbol, quote_decimals, rpc_batch_limit, max_transactions) = match self {
            Self::Bsc => (56, "BNB", 18, 50, 103),
            Self::Robinhood => (4663, "ETH", 18, 20, 200),
            Self::Xlayer => (196, "OKB", 18, 10, 200),
            Self::Arc => (5042, "USDC", 6, 20, 100),
            Self::Akc => (9070, "AKC", 18, 20, 100),
        };
        ChainConfig {
            chain: self,
            id,
            native_symbol,
            native_decimals: 18,
            quote_decimals,
            private_bundle: self == Self::Bsc,
            rpc_batch_limit,
            max_transactions,
        }
    }
    pub fn parse(value: &str) -> Result<Self> {
        match value {
            "bsc" | "56" => Ok(Self::Bsc),
            "robinhood" | "4663" => Ok(Self::Robinhood),
            "xlayer" | "196" => Ok(Self::Xlayer),
            "arc" | "5042" => Ok(Self::Arc),
            "akc" | "9070" => Ok(Self::Akc),
            _ => Err(AppError::invalid("不支持的链")),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arc_native_and_erc20_units_are_not_interchangeable() {
        let arc = Chain::Arc.config();
        assert_eq!(
            (arc.id, arc.native_decimals, arc.quote_decimals),
            (5042, 18, 6)
        );
        assert!(Chain::Bsc.config().private_bundle);
        assert!(
            Chain::ALL
                .iter()
                .filter(|c| **c != Chain::Bsc)
                .all(|c| !c.config().private_bundle)
        );
    }
}
