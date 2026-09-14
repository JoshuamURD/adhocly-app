mod db;
mod error;
mod routes;
mod tasks;

use anyhow::{Context, Result};
use std::env;
use utoipa::OpenApi;

const DEFAULT_BIND: &str = "127.0.0.1:3000";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    if env::args().any(|arg| arg == "--openapi") {
        println!("{}", routes::ApiDoc::openapi().to_pretty_json()?);
        return Ok(());
    }

    let db = db::connect().await?;
    let bind = env::var("API_BIND").unwrap_or_else(|_| DEFAULT_BIND.into());
    let listener = tokio::net::TcpListener::bind(&bind)
        .await
        .with_context(|| format!("failed to bind API to {bind}"))?;

    println!("Adhocly API listening on http://{bind}");
    axum::serve(listener, routes::app(db))
        .await
        .context("API server stopped")
}
