use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};

use crate::{error::AppError, state::AppState};

use super::model::{
    Project,
    ProjectFolderInput, ProjectInput, INBOX_ID,
};

// Shared with the folders module, which validates names the same way.
pub(crate) fn name_or_invalid(name: &str) -> Result<&str, AppError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(AppError::Invalid("name is required"));
    }
    Ok(name)
}

pub(crate) fn optional_id_or_invalid(id: Option<&str>) -> Result<Option<&str>, AppError> {
    match id.map(str::trim) {
        Some("") => Err(AppError::Invalid("id cannot be blank")),
        id => Ok(id),
    }
}

#[utoipa::path(
    get,
    path = "/api/projects",
    operation_id = "listProjects",
    responses((status = 200, description = "Projects", body = [Project])),
    tag = "projects"
)]
pub(crate) async fn list_projects(
    State(state): State<AppState>,
) -> std::result::Result<Json<Vec<Project>>, AppError> {
    Ok(Json(state.projects.list().await?))
}

#[utoipa::path(
    get,
    path = "/api/projects/{id}",
    operation_id = "getProject",
    params(("id" = String, Path, description = "Project id")),
    responses(
        (status = 200, description = "Project", body = Project),
        (status = 404, description = "Project not found", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn get_project(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> std::result::Result<Json<Project>, AppError> {
    Ok(Json(state.projects.get(&id).await?))
}

#[utoipa::path(
    post,
    path = "/api/projects",
    operation_id = "createProject",
    request_body = ProjectInput,
    responses(
        (status = 201, description = "Created project", body = Project),
        (status = 400, description = "Invalid project", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn create_project(
    State(state): State<AppState>,
    Json(input): Json<ProjectInput>,
) -> std::result::Result<(StatusCode, Json<Project>), AppError> {
    let name = name_or_invalid(&input.name)?;
    let id = optional_id_or_invalid(input.id.as_deref())?;
    Ok((
        StatusCode::CREATED,
        Json(state.projects.create(id, name).await?),
    ))
}

#[utoipa::path(
    put,
    path = "/api/projects/{id}",
    operation_id = "updateProject",
    params(("id" = String, Path, description = "Project id")),
    request_body = ProjectInput,
    responses(
        (status = 200, description = "Renamed project", body = Project),
        (status = 400, description = "Invalid project", body = String),
        (status = 404, description = "Project not found", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn update_project(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<ProjectInput>,
) -> std::result::Result<Json<Project>, AppError> {
    let name = name_or_invalid(&input.name)?;
    Ok(Json(state.projects.update(&id, name).await?))
}

#[utoipa::path(
    delete,
    path = "/api/projects/{id}",
    operation_id = "deleteProject",
    params(("id" = String, Path, description = "Project id")),
    responses(
        (status = 204, description = "Project deleted, its tasks moved to Inbox"),
        (status = 400, description = "Inbox cannot be deleted", body = String),
        (status = 404, description = "Project not found", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn delete_project(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> std::result::Result<StatusCode, AppError> {
    if id == INBOX_ID {
        return Err(AppError::Invalid("Inbox cannot be deleted"));
    }
    state.projects.delete(&id).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[utoipa::path(
    put,
    path = "/api/projects/{id}/folder",
    operation_id = "moveProject",
    params(("id" = String, Path, description = "Project id")),
    request_body = ProjectFolderInput,
    responses(
        (status = 200, description = "Project filed into the folder, or at the top level when folderId is null", body = Project),
        (status = 400, description = "Inbox cannot be filed", body = String),
        (status = 404, description = "Project or folder not found", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn move_project(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<ProjectFolderInput>,
) -> std::result::Result<Json<Project>, AppError> {
    if id == INBOX_ID {
        return Err(AppError::Invalid("Inbox cannot be filed"));
    }
    Ok(Json(
        state
            .projects
            .set_folder(&id, input.folder_id.as_deref())
            .await?,
    ))
}
