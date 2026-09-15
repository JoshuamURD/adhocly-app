use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};

use crate::{error::AppError, state::AppState};

use super::model::{Task, TaskInput, ToggleInput, ToggleResult};

fn validate(input: &TaskInput) -> Result<(), AppError> {
    if input.id.trim().is_empty() {
        return Err(AppError::Invalid("id is required"));
    }
    if input.title.trim().is_empty() {
        return Err(AppError::Invalid("title is required"));
    }
    if input.project_id.trim().is_empty() {
        return Err(AppError::Invalid("projectId is required"));
    }
    if !matches!(input.repeat_weekday, None | Some(0..=6)) {
        return Err(AppError::Invalid("repeatWeekday must be between 0 and 6"));
    }
    Ok(())
}

#[utoipa::path(
    get,
    path = "/api/tasks",
    operation_id = "listTasks",
    responses((status = 200, description = "Tasks ordered newest first", body = [Task])),
    tag = "tasks"
)]
pub(crate) async fn list_tasks(
    State(state): State<AppState>,
) -> std::result::Result<Json<Vec<Task>>, AppError> {
    Ok(Json(state.tasks.list().await?))
}

#[utoipa::path(
    get,
    path = "/api/tasks/{id}",
    operation_id = "getTask",
    params(("id" = String, Path, description = "Task id")),
    responses(
        (status = 200, description = "Task", body = Task),
        (status = 404, description = "Task not found", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn get_task(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> std::result::Result<Json<Task>, AppError> {
    Ok(Json(state.tasks.get(&id).await?))
}

#[utoipa::path(
    post,
    path = "/api/tasks",
    operation_id = "createTask",
    request_body = TaskInput,
    responses(
        (status = 201, description = "Created task", body = Task),
        (status = 400, description = "Invalid task", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn create_task(
    State(state): State<AppState>,
    Json(input): Json<TaskInput>,
) -> std::result::Result<(StatusCode, Json<Task>), AppError> {
    validate(&input)?;
    Ok((StatusCode::CREATED, Json(state.tasks.create(&input).await?)))
}

#[utoipa::path(
    put,
    path = "/api/tasks/{id}",
    operation_id = "updateTask",
    params(("id" = String, Path, description = "Task id")),
    request_body = TaskInput,
    responses(
        (status = 200, description = "Updated task", body = Task),
        (status = 400, description = "Invalid task", body = String),
        (status = 404, description = "Task not found", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn update_task(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<TaskInput>,
) -> std::result::Result<Json<Task>, AppError> {
    validate(&input)?;
    if id != input.id {
        return Err(AppError::Invalid("path and task ids must match"));
    }
    Ok(Json(state.tasks.update(&id, &input).await?))
}

#[utoipa::path(
    post,
    path = "/api/tasks/{id}/toggle",
    operation_id = "toggleTask",
    params(("id" = String, Path, description = "Task id")),
    request_body = ToggleInput,
    responses(
        (status = 200, description = "Toggled task and optional next recurring task", body = ToggleResult),
        (status = 404, description = "Task not found", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn toggle_task(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<ToggleInput>,
) -> std::result::Result<Json<ToggleResult>, AppError> {
    Ok(Json(state.tasks.toggle(&id, input.completed).await?))
}

#[utoipa::path(
    delete,
    path = "/api/tasks/{id}",
    operation_id = "deleteTask",
    params(("id" = String, Path, description = "Task id")),
    responses(
        (status = 204, description = "Deleted task"),
        (status = 404, description = "Task not found", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn delete_task(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> std::result::Result<StatusCode, AppError> {
    state.tasks.delete(&id).await?;
    Ok(StatusCode::NO_CONTENT)
}
