use anyhow::{Context, Result};
use sqlx::{
    sqlite::{SqliteConnectOptions, SqlitePoolOptions},
    SqlitePool,
};
use std::{env, str::FromStr};

const DEFAULT_DATABASE_URL: &str = "sqlite://adhocly.db?mode=rwc";

pub(crate) async fn connect() -> Result<SqlitePool> {
    let options = SqliteConnectOptions::from_str(
        &env::var("DATABASE_URL").unwrap_or_else(|_| DEFAULT_DATABASE_URL.into()),
    )
    .context("invalid DATABASE_URL")?
    .create_if_missing(true)
    .foreign_keys(true);

    // ponytail: one connection fits a personal app; raise this if concurrent writes stall.
    let db = SqlitePoolOptions::new()
        .max_connections(1)
        .connect_with(options)
        .await
        .context("failed to open SQLite database")?;

    sqlx::migrate!()
        .run(&db)
        .await
        .context("failed to migrate SQLite database")?;

    Ok(db)
}
