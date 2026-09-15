use anyhow::{Context, Result};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    SqlitePool,
};
use std::{env, str::FromStr, time::Duration};

const DEFAULT_DATABASE_URL: &str = "sqlite://adhocly.db?mode=rwc";

pub(crate) async fn connect() -> Result<SqlitePool> {
    let options = SqliteConnectOptions::from_str(
        &env::var("DATABASE_URL").unwrap_or_else(|_| DEFAULT_DATABASE_URL.into()),
    )
    .context("invalid DATABASE_URL")?
    .create_if_missing(true)
    .foreign_keys(true)
    // WAL lets snapshot reads run while a sync write holds `BEGIN IMMEDIATE`; the busy timeout
    // turns a second concurrent writer into a short wait instead of a 503.
    .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
    .synchronous(sqlx::sqlite::SqliteSynchronous::Normal)
    .busy_timeout(Duration::from_secs(5));

    // ponytail: four connections fit a personal app; writes still serialise on BEGIN IMMEDIATE.
    // Do not add pool reads inside an open `Write` transaction or the pool can deadlock.
    let db = SqlitePoolOptions::new()
        .max_connections(4)
        .connect_with(options)
        .await
        .context("failed to open SQLite database")?;

    sqlx::migrate!()
        .run(&db)
        .await
        .context("failed to migrate SQLite database")?;

    Ok(db)
}
