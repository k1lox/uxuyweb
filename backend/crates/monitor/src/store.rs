pub use crate::device::{Device, hash, subscription, token_valid};
#[cfg(any(test, feature = "sqlite"))]
use crate::sqlite;
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use botai_core::{AppError, Result};
use botai_database::{
    Database, error,
    mysql::{TxOpts, prelude::Queryable},
};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use rand::RngCore;
#[cfg(any(test, feature = "sqlite"))]
use std::path::Path;
use web_push::SubscriptionInfo;
#[derive(Clone)]
pub enum Store {
    Mysql(Database),
    #[cfg(any(test, feature = "sqlite"))]
    Test(sqlite::Store),
}
impl Store {
    #[cfg(any(test, feature = "sqlite"))]
    pub fn open(path: impl AsRef<Path>, config_hash: &str) -> Result<Self> {
        Ok(Self::Test(sqlite::Store::open(path, config_hash)?))
    }
    pub fn mysql(db: Database, config_hash: &str) -> Result<Self> {
        db.run(|c| {
            let mut t = c.start_transaction(TxOpts::default()).map_err(error)?;
            t.exec_drop(
                "INSERT IGNORE INTO botai_settings VALUES('monitor:config','')",
                (),
            )
            .map_err(error)?;
            let previous: Option<String> = t
                .query_first(
                    "SELECT value FROM botai_settings WHERE name='monitor:config' FOR UPDATE",
                )
                .map_err(error)?;
            if previous.as_deref() != Some(config_hash) {
                t.query_drop("DELETE FROM botai_monitor_devices")
                    .map_err(error)?;
                t.query_drop("DELETE FROM botai_settings WHERE name='monitor:offset'")
                    .map_err(error)?;
                t.exec_drop(
                    "UPDATE botai_settings SET value=? WHERE name='monitor:config'",
                    (config_hash,),
                )
                .map_err(error)?;
            }
            t.commit().map_err(error)
        })?;
        Ok(Self::Mysql(db))
    }
    pub fn setting(&self, key: &str) -> Result<Option<String>> {
        match self {
            #[cfg(any(test, feature = "sqlite"))]
            Self::Test(s) => s.setting(key),
            Self::Mysql(db) => db.run(|c| {
                c.exec_first(
                    "SELECT value FROM botai_settings WHERE name=?",
                    (format!("monitor:{key}"),),
                )
                .map_err(error)
            }),
        }
    }
    pub fn set(&self, key: &str, value: &str) -> Result<()> {
        match self {#[cfg(any(test, feature = "sqlite"))]Self::Test(s)=>s.set(key,value),Self::Mysql(db)=>db.run(|c|c.exec_drop("INSERT INTO botai_settings VALUES(?,?) ON DUPLICATE KEY UPDATE value=VALUES(value)",(format!("monitor:{key}"),value)).map_err(error))}
    }
    pub fn keys(&self) -> Result<(String, String)> {
        match self {
            #[cfg(any(test, feature = "sqlite"))]
            Self::Test(s) => s.keys(),
            Self::Mysql(db) => db.run(|c| {
                let candidate = p256::SecretKey::random(&mut rand::rngs::OsRng);
                c.exec_drop(
                    "INSERT IGNORE INTO botai_settings VALUES('monitor:vapid',?)",
                    (URL_SAFE_NO_PAD.encode(candidate.to_bytes()),),
                )
                .map_err(error)?;
                let private: String = c
                    .query_first("SELECT value FROM botai_settings WHERE name='monitor:vapid'")
                    .map_err(error)?
                    .ok_or_else(|| error("missing key"))?;
                let secret =
                    p256::SecretKey::from_slice(&URL_SAFE_NO_PAD.decode(private).map_err(error)?)
                        .map_err(error)?;
                Ok((
                    URL_SAFE_NO_PAD.encode(secret.public_key().to_encoded_point(false).as_bytes()),
                    URL_SAFE_NO_PAD.encode(secret.to_bytes()),
                ))
            }),
        }
    }
    pub fn devices(&self) -> Result<Vec<Device>> {
        match self {
            #[cfg(any(test, feature = "sqlite"))]
            Self::Test(s) => s.devices(),
            Self::Mysql(db) => db.run(|c| {
                c.query::<String, _>("SELECT data FROM botai_monitor_devices")
                    .map_err(error)?
                    .into_iter()
                    .map(|v| serde_json::from_str(&v).map_err(error))
                    .collect()
            }),
        }
    }
    pub fn device(&self, token: &str) -> Result<Option<Device>> {
        if !token_valid(token) {
            return Ok(None);
        }
        self.device_hash(&hash(token))
    }
    pub fn device_hash(&self, hash: &str) -> Result<Option<Device>> {
        match self {
            #[cfg(any(test, feature = "sqlite"))]
            Self::Test(s) => s.device_hash(hash),
            Self::Mysql(db) => db.run(|c| {
                c.exec_first::<String, _, _>(
                    "SELECT data FROM botai_monitor_devices WHERE token_hash=?",
                    (hash,),
                )
                .map_err(error)?
                .map(|v| serde_json::from_str(&v).map_err(error))
                .transpose()
            }),
        }
    }
    pub fn subscribe(
        &self,
        subscription: SubscriptionInfo,
        previous: Option<&str>,
        now: u64,
    ) -> Result<String> {
        match self {
            #[cfg(any(test, feature = "sqlite"))]
            Self::Test(s)=>s.subscribe(subscription,previous,now),
            Self::Mysql(db)=>db.run(|c| {
                let token=previous.filter(|t|token_valid(t)).map(str::to_owned).unwrap_or_else(||{let mut b=[0u8;32];rand::rngs::OsRng.fill_bytes(&mut b);URL_SAFE_NO_PAD.encode(b)});
                let token_hash=hash(&token); let endpoint_hash=hash(&subscription.endpoint);
                let mut t=c.start_transaction(TxOpts::default()).map_err(error)?;
                // Tiny global device list: one lock enforces the capacity across processes.
                let _:Option<String>=t.query_first("SELECT value FROM botai_settings WHERE name='monitor:config' FOR UPDATE").map_err(error)?;
                let owner:Option<String>=t.exec_first("SELECT token_hash FROM botai_monitor_devices WHERE endpoint_hash=?",(&endpoint_hash,)).map_err(error)?;
                if owner.is_some_and(|h|h!=token_hash) {return Err(AppError::new("DEVICE_BOUND","设备已绑定，请先关闭此设备提醒",409,false));}
                let count:u64=t.exec_first("SELECT COUNT(*) FROM botai_monitor_devices WHERE token_hash!=?",(&token_hash,)).map_err(error)?.unwrap_or(0);
                if count>=128 {return Err(AppError::new("DEVICE_LIMIT","推送设备数量已满",429,false));}
                let device=Device{token_hash:token_hash.clone(),subscription,since:now,error:None};
                t.exec_drop("INSERT INTO botai_monitor_devices VALUES(?,?,?) ON DUPLICATE KEY UPDATE endpoint_hash=VALUES(endpoint_hash),data=VALUES(data)",(&token_hash,endpoint_hash,serde_json::to_string(&device).map_err(error)?)).map_err(error)?;
                t.commit().map_err(error)?;Ok(token)
            })
        }
    }
    pub fn remove(&self, hash: &str) -> Result<()> {
        match self {
            #[cfg(any(test, feature = "sqlite"))]
            Self::Test(s) => s.remove(hash),
            Self::Mysql(db) => db.run(|c| {
                c.exec_drop(
                    "DELETE FROM botai_monitor_devices WHERE token_hash=?",
                    (hash,),
                )
                .map_err(error)
            }),
        }
    }
    pub fn error(&self, device: &Device, message: Option<&str>) -> Result<()> {
        match self {
            #[cfg(any(test, feature = "sqlite"))]
            Self::Test(s) => s.error(device, message),
            Self::Mysql(db) => db.run(|c| {
                let mut t = c.start_transaction(TxOpts::default()).map_err(error)?;
                let value: Option<String> = t
                    .exec_first(
                        "SELECT data FROM botai_monitor_devices WHERE token_hash=? FOR UPDATE",
                        (&device.token_hash,),
                    )
                    .map_err(error)?;
                if let Some(value) = value {
                    let mut current: Device = serde_json::from_str(&value).map_err(error)?;
                    if current.since == device.since
                        && current.subscription.endpoint == device.subscription.endpoint
                    {
                        current.error = message.map(str::to_owned);
                        t.exec_drop(
                            "UPDATE botai_monitor_devices SET data=? WHERE token_hash=?",
                            (
                                serde_json::to_string(&current).map_err(error)?,
                                &device.token_hash,
                            ),
                        )
                        .map_err(error)?;
                    }
                }
                t.commit().map_err(error)
            }),
        }
    }
}
