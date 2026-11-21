use botai_core::Result;
use moka::future::Cache;
use serde_json::{Value, json};
use std::{
    future::Future,
    time::{Duration, Instant},
};

/// List discovery only. Never used for creation signatures or selected-token checks.
#[derive(Clone)]
pub(crate) struct Catalogs {
    snapshots: Cache<&'static str, (Instant, Value)>,
    refreshes: Cache<&'static str, Result<Value>>,
}
impl Default for Catalogs {
    fn default() -> Self {
        Self {
            snapshots: Cache::builder().max_capacity(2).build(),
            // Coalesce readers and cool down failures, including HTTP 403.
            refreshes: Cache::builder()
                .max_capacity(2)
                .time_to_live(Duration::from_secs(30))
                .build(),
        }
    }
}
impl Catalogs {
    pub(crate) async fn source(&self, key: &'static str) -> Option<String> {
        self.snapshots.get(key).await?.1["source"]
            .as_str()
            .map(str::to_owned)
    }
    pub async fn get(
        &self,
        key: &'static str,
        load: impl Future<Output = Result<Value>> + Send + 'static,
    ) -> Result<Value> {
        if let Some((at, mut value)) = self.snapshots.get(key).await {
            let fresh_for = if value["partial"] == true { 30 } else { 300 };
            if at.elapsed() < Duration::from_secs(fresh_for) {
                return Ok(value);
            }
            let cache = self.clone();
            tokio::spawn(async move {
                let _ = cache.refresh(key, load).await;
            });
            value["stale"] = json!(true);
            if let Some(Err(error)) = self.refreshes.get(key).await {
                value["refreshError"] = json!(error.message);
            }
            return Ok(value);
        }
        self.refresh(key, load).await
    }
    async fn refresh(
        &self,
        key: &'static str,
        load: impl Future<Output = Result<Value>>,
    ) -> Result<Value> {
        self.refreshes
            .get_with(key, async {
                let mut value = load.await?;
                if value["partial"] == true {
                    if let Some((_, previous)) = self.snapshots.get(key).await {
                        let rows = value["tokens"].as_array_mut().expect("validated catalog");
                        for old in previous["tokens"].as_array().into_iter().flatten() {
                            if !rows.iter().any(|row| row["address"] == old["address"]) {
                                rows.push(old.clone());
                            }
                        }
                    }
                }
                self.snapshots
                    .insert(key, (Instant::now(), value.clone()))
                    .await;
                Ok(value)
            })
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use botai_core::AppError;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    #[tokio::test]
    async fn concurrent_readers_share_one_load_and_failures_cool_down() {
        let cache = Catalogs::default();
        let calls = Arc::new(AtomicUsize::new(0));
        let jobs = (0..8).map(|_| {
            let calls = calls.clone();
            cache.get("native", async move {
                calls.fetch_add(1, Ordering::SeqCst);
                tokio::task::yield_now().await;
                Err(AppError::unavailable("fixture 403"))
            })
        });
        assert!(
            futures::future::join_all(jobs)
                .await
                .iter()
                .all(Result::is_err)
        );
        assert_eq!(calls.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn stale_list_is_immediately_available_and_failed_refresh_cannot_erase_it() {
        let cache = Catalogs::default();
        let old = json!({"tokens":[{"address":"A","decimals":6}]});
        cache
            .snapshots
            .insert(
                "native",
                (Instant::now() - Duration::from_secs(301), old.clone()),
            )
            .await;
        let value = cache
            .get("native", async { Err(AppError::unavailable("fixture")) })
            .await
            .unwrap();
        assert_eq!(value["tokens"], old["tokens"]);
        assert_eq!(value["stale"], true);
        let _ = cache
            .refresh("native", async { Err(AppError::unavailable("fixture")) })
            .await;
        assert_eq!(cache.snapshots.get("native").await.unwrap().1, old);
        let again = cache.get("native", async { unreachable!() }).await.unwrap();
        assert_eq!(again["refreshError"], "fixture");
    }
    #[tokio::test]
    async fn partial_refresh_keeps_unavailable_pages_but_updates_returned_tokens() {
        let cache = Catalogs::default();
        cache
            .snapshots
            .insert(
                "custom",
                (
                    Instant::now(),
                    json!({"tokens":[{"address":"A","decimals":6},{"address":"B","decimals":8}]}),
                ),
            )
            .await;
        let value = cache
            .refresh("custom", async {
                Ok(json!({"partial":true,"tokens":[{"address":"A","decimals":18}]}))
            })
            .await
            .unwrap();
        assert_eq!(
            value["tokens"],
            json!([{"address":"A","decimals":18},{"address":"B","decimals":8}])
        );
    }
}
