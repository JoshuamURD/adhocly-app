use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};

use crate::{error::AppError, state::AppState};

use super::{
    model::{INBOX_ID, MetadataField, MetadataFieldInput, MetadataFieldUpdate, MetadataValueInput, Project, ProjectInput},
};

fn name_or_invalid(name: &str) -> Result<&str, AppError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(AppError::Invalid("name is required"));
    }
    Ok(name)
}

#[utoipa::path(
    get,
    path = "/api/projects",
    operation_id = "listProjects",
    responses((status = 200, description = "Projects with their metadata values", body = [Project])),
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
    Ok((StatusCode::CREATED, Json(state.projects.create(name).await?)))
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
    get,
    path = "/api/metadata-fields",
    operation_id = "listMetadataFields",
    responses((status = 200, description = "Metadata fields available to every project", body = [MetadataField])),
    tag = "projects"
)]
pub(crate) async fn list_metadata_fields(
    State(state): State<AppState>,
) -> std::result::Result<Json<Vec<MetadataField>>, AppError> {
    Ok(Json(state.projects.list_fields().await?))
}

#[utoipa::path(
    post,
    path = "/api/metadata-fields",
    operation_id = "createMetadataField",
    request_body = MetadataFieldInput,
    responses(
        (status = 201, description = "Created field", body = MetadataField),
        (status = 400, description = "Invalid field", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn create_metadata_field(
    State(state): State<AppState>,
    Json(input): Json<MetadataFieldInput>,
) -> std::result::Result<(StatusCode, Json<MetadataField>), AppError> {
    name_or_invalid(&input.name)?;
    Ok((
        StatusCode::CREATED,
        Json(state.projects.create_field(&input).await?),
    ))
}

#[utoipa::path(
    put,
    path = "/api/metadata-fields/{id}",
    operation_id = "updateMetadataField",
    params(("id" = String, Path, description = "Field id")),
    request_body = MetadataFieldUpdate,
    responses(
        (status = 200, description = "Updated field; its kind cannot change", body = MetadataField),
        (status = 400, description = "Invalid field", body = String),
        (status = 404, description = "Field not found", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn update_metadata_field(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<MetadataFieldUpdate>,
) -> std::result::Result<Json<MetadataField>, AppError> {
    name_or_invalid(&input.name)?;
    Ok(Json(state.projects.update_field(&id, &input).await?))
}

#[utoipa::path(
    delete,
    path = "/api/metadata-fields/{id}",
    operation_id = "deleteMetadataField",
    params(("id" = String, Path, description = "Field id")),
    responses(
        (status = 204, description = "Field deleted from every project"),
        (status = 404, description = "Field not found", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn delete_metadata_field(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> std::result::Result<StatusCode, AppError> {
    state.projects.delete_field(&id).await?;
    Ok(StatusCode::NO_CONTENT)
}

#[utoipa::path(
    put,
    path = "/api/projects/{id}/metadata/{fieldId}",
    operation_id = "setProjectMetadata",
    params(
        ("id" = String, Path, description = "Project id"),
        ("fieldId" = String, Path, description = "Field id"),
    ),
    request_body = MetadataValueInput,
    responses(
        (status = 204, description = "Value saved, or cleared when null/blank"),
        (status = 400, description = "Value does not fit the field kind", body = String),
        (status = 404, description = "Project or field not found", body = String),
    ),
    tag = "projects"
)]
pub(crate) async fn set_project_metadata(
    Path((id, field_id)): Path<(String, String)>,
    State(state): State<AppState>,
    Json(input): Json<MetadataValueInput>,
) -> std::result::Result<StatusCode, AppError> {
    let value = input
        .value
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());

    state.projects.set_value(&id, &field_id, value).await?;
    Ok(StatusCode::NO_CONTENT)
}
