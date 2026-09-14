use axum::{http::StatusCode, routing::get, Json, Router};
use sqlx::SqlitePool;
use tower_http::cors::CorsLayer;
use utoipa::OpenApi;

use crate::{
    error::AppError,
    tasks::{self, Task, TaskInput, ToggleInput, ToggleResult},
};

#[derive(OpenApi)]
#[openapi(
    paths(
        health,
        tasks::list_tasks,
        tasks::get_task,
        tasks::create_task,
        tasks::update_task,
        tasks::toggle_task,
        tasks::delete_task
    ),
    components(schemas(Task, TaskInput, ToggleInput, ToggleResult)),
    tags((name = "tasks", description = "Task persistence API"))
)]
pub(crate) struct ApiDoc;

pub(crate) fn app(db: SqlitePool) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/openapi.json", get(openapi))
        .route(
            "/api/tasks",
            get(tasks::list_tasks).post(tasks::create_task),
        )
        .route(
            "/api/tasks/{id}",
            get(tasks::get_task)
                .put(tasks::update_task)
                .delete(tasks::delete_task),
        )
        .route(
            "/api/tasks/{id}/toggle",
            axum::routing::post(tasks::toggle_task),
        )
        .layer(CorsLayer::permissive())
        .with_state(db)
}

async fn openapi() -> Json<utoipa::openapi::OpenApi> {
    Json(ApiDoc::openapi())
}

#[utoipa::path(
    get,
    path = "/health",
    operation_id = "health",
    responses(
        (status = 200, description = "Database is reachable"),
        (status = 503, description = "Database is unavailable", body = String),
    ),
    tag = "tasks"
)]
async fn health(
    axum::extract::State(db): axum::extract::State<SqlitePool>,
) -> std::result::Result<StatusCode, AppError> {
    sqlx::query("SELECT 1").execute(&db).await?;
    Ok(StatusCode::OK)
}
