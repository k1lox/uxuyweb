use botai_core::{AppError, Result};
pub use mysql;
use mysql::{OptsBuilder, Pool, PoolConstraints, PoolOpts, PooledConn, prelude::Queryable};
use std::time::Duration;

#[derive(Clone)]
pub struct Database(Pool);

pub fn error(_: impl std::fmt::Display) -> AppError {
    // Driver errors can contain connection details and SQL. Never return them to browsers.
    AppError::new("DATABASE_UNAVAILABLE", "数据库暂不可用", 503, true)
}
impl Database {
    pub fn connect(
        host: &str,
        port: u16,
        database: &str,
        user: &str,
        password: &str,
    ) -> Result<Self> {
        let options = OptsBuilder::new()
            .ip_or_hostname(Some(host))
            .tcp_port(port)
            .db_name(Some(database))
            .user(Some(user))
            .pass(Some(password))
            .tcp_connect_timeout(Some(Duration::from_secs(5)))
            .read_timeout(Some(Duration::from_secs(8)))
            .write_timeout(Some(Duration::from_secs(8)))
            .pool_opts(PoolOpts::default().with_constraints(PoolConstraints::new(1, 12).unwrap()));
        let db = Self(Pool::new(options).map_err(error)?);
        db.run(|c| {
            c.query_drop("SELECT 1").map_err(error)?;
            Ok(())
        })?;
        Ok(db)
    }
    /// Reuse the pool without blocking Tokio's async worker threads.
    pub fn run<T>(&self, f: impl FnOnce(&mut PooledConn) -> Result<T>) -> Result<T> {
        let run = || {
            let mut c = self.0.get_conn().map_err(error)?;
            f(&mut c)
        };
        if tokio::runtime::Handle::try_current()
            .is_ok_and(|h| h.runtime_flavor() == tokio::runtime::RuntimeFlavor::MultiThread)
        {
            tokio::task::block_in_place(run)
        } else {
            run()
        }
    }
    pub fn schema(&self) -> Result<()> {
        self.run(|c| {
            for sql in include_str!("schema.sql")
                .split(';')
                .map(str::trim)
                .filter(|s| !s.is_empty())
            {
                c.query_drop(sql).map_err(error)?;
            }
            Ok(())
        })
    }
}
