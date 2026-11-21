// Isolated test store only. Never compiled into the default release.
use crate::device::{Device, hash, token_valid};
use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use botai_core::{AppError, Result};
use p256::elliptic_curve::sec1::ToEncodedPoint;
use rand::RngCore;
use rusqlite::{Connection, OptionalExtension, params};
use std::{
    path::Path,
    sync::{Arc, Mutex},
};
use web_push::SubscriptionInfo;

#[derive(Clone)]
pub struct Store {
    db: Arc<Mutex<Connection>>,
}
fn failure() -> AppError {
    AppError::unavailable("推送状态保存或读取失败")
}
impl Store {
    pub fn open(path: impl AsRef<Path>, config_hash: &str) -> Result<Self> {
        let db = Connection::open(&path).map_err(|_| failure())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
                .map_err(|_| failure())?;
        }
        db.execute_batch("PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,value TEXT NOT NULL); CREATE TABLE IF NOT EXISTS devices(token_hash TEXT PRIMARY KEY,endpoint TEXT UNIQUE NOT NULL,data TEXT NOT NULL);").map_err(|_|failure())?;
        let previous: Option<String> = db
            .query_row("SELECT value FROM settings WHERE key='config'", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|_| failure())?;
        if previous.as_deref() != Some(config_hash) {
            db.execute_batch(
                "BEGIN IMMEDIATE; DELETE FROM devices; DELETE FROM settings WHERE key='offset';",
            )
            .map_err(|_| failure())?;
            db.execute(
                "INSERT OR REPLACE INTO settings VALUES('config',?1)",
                [config_hash],
            )
            .map_err(|_| failure())?;
            db.execute_batch("COMMIT").map_err(|_| failure())?;
        }
        Ok(Self {
            db: Arc::new(Mutex::new(db)),
        })
    }
    pub fn setting(&self, key: &str) -> Result<Option<String>> {
        self.db
            .lock()
            .map_err(|_| failure())?
            .query_row("SELECT value FROM settings WHERE key=?1", [key], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|_| failure())
    }
    pub fn set(&self, key: &str, value: &str) -> Result<()> {
        self.db
            .lock()
            .map_err(|_| failure())?
            .execute(
                "INSERT OR REPLACE INTO settings VALUES(?1,?2)",
                params![key, value],
            )
            .map_err(|_| failure())?;
        Ok(())
    }
    pub fn keys(&self) -> Result<(String, String)> {
        let db = self.db.lock().map_err(|_| failure())?;
        let private: Option<String> = db
            .query_row("SELECT value FROM settings WHERE key='vapid'", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|_| failure())?;
        let secret = if let Some(private) = private {
            p256::SecretKey::from_slice(&URL_SAFE_NO_PAD.decode(private).map_err(|_| failure())?)
                .map_err(|_| failure())?
        } else {
            let secret = p256::SecretKey::random(&mut rand::rngs::OsRng);
            db.execute(
                "INSERT INTO settings VALUES('vapid',?1)",
                [URL_SAFE_NO_PAD.encode(secret.to_bytes())],
            )
            .map_err(|_| failure())?;
            secret
        };
        Ok((
            URL_SAFE_NO_PAD.encode(secret.public_key().to_encoded_point(false).as_bytes()),
            URL_SAFE_NO_PAD.encode(secret.to_bytes()),
        ))
    }
    pub fn devices(&self) -> Result<Vec<Device>> {
        let db = self.db.lock().map_err(|_| failure())?;
        let mut stmt = db
            .prepare("SELECT data FROM devices")
            .map_err(|_| failure())?;
        let rows = stmt
            .query_map([], |r| r.get::<_, String>(0))
            .map_err(|_| failure())?;
        rows.map(|r| serde_json::from_str(&r.map_err(|_| failure())?).map_err(|_| failure()))
            .collect()
    }
    pub fn device(&self, token: &str) -> Result<Option<Device>> {
        if !token_valid(token) {
            return Ok(None);
        }
        self.device_hash(&hash(token))
    }
    pub fn device_hash(&self, token_hash: &str) -> Result<Option<Device>> {
        let data: Option<String> = self
            .db
            .lock()
            .map_err(|_| failure())?
            .query_row(
                "SELECT data FROM devices WHERE token_hash=?1",
                [token_hash],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| failure())?;
        data.map(|s| serde_json::from_str(&s).map_err(|_| failure()))
            .transpose()
    }
    pub fn subscribe(
        &self,
        subscription: SubscriptionInfo,
        previous: Option<&str>,
        now: u64,
    ) -> Result<String> {
        let token = if let Some(token) = previous.filter(|t| token_valid(t)) {
            token.to_string()
        } else {
            let mut b = [0u8; 32];
            rand::rngs::OsRng.fill_bytes(&mut b);
            URL_SAFE_NO_PAD.encode(b)
        };
        let mut db = self.db.lock().map_err(|_| failure())?;
        let tx = db.transaction().map_err(|_| failure())?;
        let token_hash = hash(&token);
        let owner: Option<String> = tx
            .query_row(
                "SELECT token_hash FROM devices WHERE endpoint=?1",
                [&subscription.endpoint],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| failure())?;
        if owner.is_some_and(|h| h != token_hash) {
            return Err(AppError::new(
                "DEVICE_BOUND",
                "设备已绑定，请先关闭此设备提醒",
                409,
                false,
            ));
        }
        let count: i64 = tx
            .query_row(
                "SELECT count(*) FROM devices WHERE token_hash!=?1",
                [&token_hash],
                |r| r.get(0),
            )
            .map_err(|_| failure())?;
        if count >= 128 {
            return Err(AppError::new(
                "DEVICE_LIMIT",
                "推送设备数量已满",
                429,
                false,
            ));
        }
        let device = Device {
            token_hash: token_hash.clone(),
            subscription,
            since: now,
            error: None,
        };
        tx.execute(
            "INSERT OR REPLACE INTO devices VALUES(?1,?2,?3)",
            params![
                token_hash,
                device.subscription.endpoint,
                serde_json::to_string(&device).map_err(|_| failure())?
            ],
        )
        .map_err(|_| failure())?;
        tx.commit().map_err(|_| failure())?;
        Ok(token)
    }
    pub fn remove(&self, hash: &str) -> Result<()> {
        self.db
            .lock()
            .map_err(|_| failure())?
            .execute("DELETE FROM devices WHERE token_hash=?1", [hash])
            .map_err(|_| failure())?;
        Ok(())
    }
    pub fn error(&self, device: &Device, message: Option<&str>) -> Result<()> {
        let mut db = self.db.lock().map_err(|_| failure())?;
        let tx = db.transaction().map_err(|_| failure())?;
        let data: Option<String> = tx
            .query_row(
                "SELECT data FROM devices WHERE token_hash=?1",
                [&device.token_hash],
                |r| r.get(0),
            )
            .optional()
            .map_err(|_| failure())?;
        if let Some(data) = data {
            let mut current: Device = serde_json::from_str(&data).map_err(|_| failure())?;
            if current.since == device.since
                && current.subscription.endpoint == device.subscription.endpoint
            {
                current.error = message.map(String::from);
                tx.execute(
                    "UPDATE devices SET data=?1 WHERE token_hash=?2",
                    params![
                        serde_json::to_string(&current).map_err(|_| failure())?,
                        device.token_hash
                    ],
                )
                .map_err(|_| failure())?;
            }
        }
        tx.commit().map_err(|_| failure())?;
        Ok(())
    }
}
