use axum::{
    extract::{Request, State},
    http::{header::AUTHORIZATION, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use sqlx::SqlitePool;
use tower_http::cors::CorsLayer;
use utoipa::OpenApi;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::{
    contexts,
    error::AppError,
    folders::{self, Folder, FolderInput},
    kanban::{self, Board, FieldOption, TaskField},
    projects::{
        self, FieldKind, MetadataField, MetadataFieldInput, MetadataFieldUpdate, MetadataValue,
        MetadataValueInput, Project, ProjectFolderInput, ProjectInput,
    },
    reminders::{self, Reminder},
    state::AppState,
    sync::{self, SyncOperation, SyncReply, SyncSnapshot},
    tasks::{self, Task, TaskInput, ToggleInput, ToggleResult},
};

#[derive(OpenApi)]
#[openapi(
    // Without this the API client built into the docs (Scalar) resolves relative paths against the
    // docs' own origin and every "Send request" 404s. The generated openapi.json carries it too.
    servers((url = "http://localhost:3000", description = "Local adhocly API")),
    components(schemas(
        Board,
        FieldOption,
        TaskField,
        SyncOperation,
        SyncSnapshot,
        SyncReply,
        Task,
        TaskInput,
        ToggleInput,
        ToggleResult,
        Project,
        ProjectInput,
        ProjectFolderInput,
        Folder,
        FolderInput,
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
        (name = "folders", description = "Folders that group projects"),
        (name = "reminders", description = "Task reminders")
    )
)]
pub(crate) struct ApiDoc;

/// The whole API is declared here: `routes!` reads the `#[utoipa::path]` attribute of each handler,
/// so the mount path lives in exactly one place instead of also being repeated in `app`.
fn api_router() -> OpenApiRouter<AppState> {
    OpenApiRouter::with_openapi(ApiDoc::openapi())
        .routes(routes!(health))
        .routes(routes!(contexts::save_context, contexts::delete_context))
        .routes(routes!(contexts::save_contact, contexts::delete_contact))
        .routes(routes!(contexts::save_links))
        .routes(routes!(sync::get_snapshot, sync::apply))
        .routes(routes!(kanban::list_fields, kanban::create_field))
        .routes(routes!(kanban::update_field))
        .routes(routes!(kanban::list_boards, kanban::create_board))
        .routes(routes!(kanban::update_board, kanban::delete_board))
        .routes(routes!(tasks::list_tasks, tasks::create_task))
        .routes(routes!(
            tasks::get_task,
            tasks::update_task,
            tasks::delete_task
        ))
        .routes(routes!(tasks::toggle_task))
        .routes(routes!(projects::list_projects, projects::create_project))
        .routes(routes!(
            projects::get_project,
            projects::update_project,
            projects::delete_project
        ))
        .routes(routes!(projects::set_project_metadata))
        .routes(routes!(projects::move_project))
        .routes(routes!(folders::list_folders, folders::create_folder))
        .routes(routes!(folders::update_folder, folders::delete_folder))
        .routes(routes!(
            projects::list_metadata_fields,
            projects::create_metadata_field
        ))
        .routes(routes!(
            projects::update_metadata_field,
            projects::delete_metadata_field
        ))
        .routes(routes!(reminders::get_reminder))
}

pub(crate) fn openapi() -> utoipa::openapi::OpenApi {
    api_router().split_for_parts().1
}

pub(crate) fn app(db: SqlitePool) -> Router {
    // Set API_TOKEN to require `Authorization: Bearer <token>` on every /api route. Without it the
    // middleware passes requests through, so local development and the docs page stay open.
    let token = std::env::var("API_TOKEN")
        .ok()
        .filter(|token| !token.is_empty());
    let (router, api) = api_router().split_for_parts();
    router
        // Registered before the layers so the docs page can fetch it cross-origin.
        .route(
            "/openapi.json",
            get(move || {
                let api = api.clone();
                async move { Json(api) }
            }),
        )
        // The iOS app reaches a cross-origin PUBLIC_API_URL and a bearer token forces a preflight,
        // so CORS stays permissive: the token, not the origin, is what closes the hole.
        .layer(middleware::from_fn_with_state(token, require_token))
        .layer(CorsLayer::permissive())
        .with_state(AppState::new(db))
}

/// Shared-secret check for `/api/*`. `/health` and `/openapi.json` stay reachable so health probes and
/// the Scalar docs page keep working.
async fn require_token(
    State(token): State<Option<String>>,
    request: Request,
    next: Next,
) -> Response {
    let Some(token) = token else {
        return next.run(request).await;
    };
    if !request.uri().path().starts_with("/api/") {
        return next.run(request).await;
    }
    let provided = request
        .headers()
        .get(AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "));
    if provided.is_some_and(|value| value == token) {
        next.run(request).await
    } else {
        (StatusCode::UNAUTHORIZED, "unauthorized").into_response()
    }
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
