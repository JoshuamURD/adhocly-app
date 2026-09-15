use axum::{http::StatusCode, routing::get, Json, Router};
use sqlx::SqlitePool;
use tower_http::cors::CorsLayer;
use utoipa::OpenApi;

use crate::{
    error::AppError,
    projects::{
        self, FieldKind, MetadataField, MetadataFieldInput, MetadataFieldUpdate, MetadataValue,
        MetadataValueInput, Project, ProjectInput,
    },
    reminders::{self, Reminder},
    state::AppState,
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
        tasks::delete_task,
        projects::list_projects,
        projects::get_project,
        projects::create_project,
        projects::update_project,
        projects::delete_project,
        projects::list_metadata_fields,
        projects::create_metadata_field,
        projects::update_metadata_field,
        projects::delete_metadata_field,
        projects::set_project_metadata,
        reminders::get_reminder
    ),
    components(schemas(
        Task,
        TaskInput,
        ToggleInput,
        ToggleResult,
        Project,
        ProjectInput,
        MetadataField,
        MetadataFieldInput,
        MetadataFieldUpdate,
        MetadataValue,
        MetadataValueInput,
        FieldKind,
        Reminder
    )),
    tags(
        (name = "tasks", description = "Task persistence API"),
        (name = "projects", description = "Projects and their user-defined metadata"),
        (name = "reminders", description = "Task reminders")
    )
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
        .route(
            "/api/projects",
            get(projects::list_projects).post(projects::create_project),
        )
        .route(
            "/api/projects/{id}",
            get(projects::get_project)
                .put(projects::update_project)
                .delete(projects::delete_project),
        )
        .route(
            "/api/projects/{id}/metadata/{fieldId}",
            axum::routing::put(projects::set_project_metadata),
        )
        .route(
            "/api/metadata-fields",
            get(projects::list_metadata_fields).post(projects::create_metadata_field),
        )
        .route(
            "/api/metadata-fields/{id}",
            axum::routing::put(projects::update_metadata_field)
                .delete(projects::delete_metadata_field),
        )
        .route("/api/reminders/{id}", get(reminders::get_reminder))
        .layer(CorsLayer::permissive())
        .with_state(AppState::new(db))
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
    axum::extract::State(state): axum::extract::State<AppState>,
) -> std::result::Result<StatusCode, AppError> {
    // Not a tagged macro on purpose: this touches no schema, and `SELECT 1` has no nameable
    // output column for `query!` to bind to.
    sqlx::query("SELECT 1").execute(state.pool()).await?;
    Ok(StatusCode::OK)
}
