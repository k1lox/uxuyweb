use alloy_primitives::{Address, address};
use serde::Deserialize;

pub const CHAIN_ID: u64 = 56;
pub const WBNB: Address = address!("bb4cdb9cbd36b01bd1cbaebf2de08d9173bc095c");
pub const MULTICALL3: Address = address!("ca11bde05977b3631167028862be2a173976ca11");
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(default = "default_listen")]
    pub listen: String,
    /// Server-only BSC upstream. It is never accepted in an API request.
    #[serde(default = "default_rpc")]
    rpc_url: String,
    #[serde(default)]
    pub uxuy: Option<UxuyConfig>,
    #[serde(default)]
    pub monitor: Option<botai_monitor::Config>,
    #[serde(default = "default_max_impact")]
    pub max_price_impact_percent: f64,
    #[serde(default = "default_slippage")]
    pub default_slippage_bps: u16,
    #[serde(default = "default_deadline")]
    pub deadline_seconds: u64,
    /// Browser origins allowed to call the API (the native module does not need CORS).
    #[serde(default = "default_cors")]
    pub cors_origins: Vec<String>,
    /// Extra contracts refused as swap targets / spenders (in addition to the built-in DEX list).
    #[serde(default)]
    pub denied_contracts: Vec<Address>,
    /// Transaction store: MySQL when configured, otherwise a local SQLite file.
    #[serde(default)]
    pub mysql: Option<MysqlConfig>,
    #[serde(default = "default_store")]
    pub store_path: String,
    /// Built Flutter web bundle served on web_listen for local preview.
    #[serde(default)]
    pub web_root: Option<String>,
    #[serde(default)]
    pub web_listen: Option<String>,
    #[serde(default)]
    pub bundle: Option<BundleConfig>,
    /// Fork testing only: loopback relay that lands bundles on a local node (must be http://127.0.0.1).
    #[serde(default)]
    pub bundle_local_relay: Option<String>,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UxuyConfig {
    pub router: Address,
    pub approval_spender: Address,
    pub native_token: Address,
    pub app_id_file: std::path::PathBuf,
    pub signing_key_file: std::path::PathBuf,
}
#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MysqlConfig {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub user: String,
    pub password: String,
}

#[derive(Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BundleConfig {
    /// bloXroute authorization for BSC private bundles (relay endpoint is fixed in botai-transactions).
    pub authorization: String,
}

fn default_rpc() -> String {
    "http://127.0.0.1:8545".into()
}
fn default_listen() -> String {
    "127.0.0.1:3291".into()
}
fn default_store() -> String {
    "data/transactions.sqlite".into()
}
fn default_cors() -> Vec<String> {
    vec![
        "http://127.0.0.1:3188".into(),
        "http://localhost:3188".into(),
    ]
}
fn default_max_impact() -> f64 {
    7.0
}
fn default_slippage() -> u16 {
    100
}
fn default_deadline() -> u64 {
    180
}
impl Config {
    pub fn rpc_endpoint(&self) -> Result<reqwest::Url, String> {
        let url = reqwest::Url::parse(&self.rpc_url)
            .map_err(|_| "rpc_url 必须是有效的 BSC 节点地址".to_string())?;
        let local = url.scheme() == "http"
            && matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
        if !(local || url.scheme() == "https")
            || url.host().is_none()
            || !url.username().is_empty()
            || url.password().is_some()
            || url.fragment().is_some()
        {
            return Err("rpc_url 必须使用 HTTPS 或本机 HTTP 节点".into());
        }
        if self.bundle_local_relay.is_some() && !local {
            return Err("本地分叉 relay 需要配套的本机 HTTP RPC".into());
        }
        if local
            && self.bundle_local_relay.is_none()
            && self
                .bundle
                .as_ref()
                .is_some_and(|b| !b.authorization.is_empty())
        {
            return Err("本地分叉 RPC 不能与主网捆绑通道混用；请配置本地 relay".into());
        }
        Ok(url)
    }

    // Preserve transport and store settings from earlier installations. Only the explicit
    // UXUY section may enable quoting or provide execution and allowance addresses.
    pub(super) fn parse(text: &str) -> Result<Self, toml::de::Error> {
        let mut fields: toml::Table = toml::from_str(text)?;
        for key in [
            "router",
            "fee_rate",
            "launch_fee_contract",
            "platform_routers",
            "okx",
            "skip_router_check",
        ] {
            fields.remove(key);
        }
        toml::Value::Table(fields).try_into()
    }

    pub fn load(path: &str) -> Result<Self, String> {
        let text = std::fs::read_to_string(path).map_err(|e| format!("read {path}: {e}"))?;
        let mut config = Self::parse(&text)
            .map_err(|_| format!("invalid configuration in {path}; see config.example.toml"))?;
        // Credentials may come from the environment so they never need to be written into a file.
        let env = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty());
        if let Some(v) = env("UXUY_BUNDLE_AUTHORIZATION") {
            config.bundle = Some(BundleConfig { authorization: v });
        }
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<(), String> {
        if let Some(uxuy) = &self.uxuy {
            for addr in [uxuy.router, uxuy.approval_spender] {
                if addr.is_zero() || crate::submit::denied(addr, &self.denied_contracts) {
                    return Err("UXUY 执行合约或授权合约地址无效".into());
                }
            }
            if uxuy.app_id_file.as_os_str().is_empty()
                || uxuy.signing_key_file.as_os_str().is_empty()
            {
                return Err("UXUY 服务端凭据文件路径缺失".into());
            }
        }
        if !(1..=600).contains(&self.deadline_seconds) {
            return Err("deadline_seconds must be 1..=600".into());
        }
        if !(0.0..100.0).contains(&self.max_price_impact_percent) {
            return Err("max_price_impact_percent must be at least 0 and below 100".into());
        }
        if self.default_slippage_bps == 0 || self.default_slippage_bps > 5_000 {
            return Err("default_slippage_bps must be 1..=5000".into());
        }
        Ok(())
    }
}
