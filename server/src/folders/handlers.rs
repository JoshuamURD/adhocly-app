use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};

use crate::{
    error::AppError,
    projects::{name_or_invalid, optional_id_or_invalid},
    state::AppState,
};

use super::model::{Folder, FolderInput};

#[utoipa::path(
    get,
    path = "/api/folders",
    operation_id = "listFolders",
    responses((status = 200, description = "Every folder, flat; `parentId` carries the nesting", body = [Folder])),
    tag = "folders"
)]
pub(crate) async fn list_folders(
    State(state): State<AppState>,
) -> std::result::Result<Json<Vec<Folder>>, AppError> {
    Ok(Json(state.folders.list().await?))
}

#[utoipa::path(
    post,
    path = "/api/folders",
    operation_id = "createFolder",
    request_body = FolderInput,
    responses(
        (status = 201, description = "Created folder", body = Folder),
        (status = 400, description = "Invalid or duplicate name", body = String),
        (status = 404, description = "Parent folder not found", body = String),
    ),
    tag = "folders"
)]
pub(crate) async fn create_folder(
    State(state): State<AppState>,
    Json(input): Json<FolderInput>,
) -> std::result::Result<(StatusCode, Json<Folder>), AppError> {
    let name = name_or_invalid(&input.name)?;
    let id = optional_id_or_invalid(input.id.as_deref())?;
    let folder = state
        .folders
        .create(id, name, input.parent_id.as_deref())
        .await?;
    Ok((StatusCode::CREATED, Json(folder)))
}

#[utoipa::path(
    put,
    path = "/api/folders/{id}",
    operation_id = "updateFolder",
    params(("id" = String, Path, description = "Folder id")),
    request_body = FolderInput,
    responses(
        (status = 200, description = "Renamed and moved; `parentId` replaces the current parent, so omitting it moves the folder to the top level", body = Folder),
        (status = 400, description = "Invalid or duplicate name, or a move inside the folder's own subtree", body = String),
        (status = 404, description = "Folder or parent folder not found", body = String),
    ),
    tag = "folders"
)]
pub(crate) async fn update_folder(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<FolderInput>,
) -> std::result::Result<Json<Folder>, AppError> {
    let name = name_or_invalid(&input.name)?;
    Ok(Json(
        state
            .folders
            .update(&id, name, input.parent_id.as_deref())
            .await?,
    ))
}

#[utoipa::path(
    delete,
    path = "/api/folders/{id}",
    operation_id = "deleteFolder",
    params(("id" = String, Path, description = "Folder id")),
    responses(
        (status = 204, description = "Folder deleted; its projects and subfolders move to its parent"),
        (status = 404, description = "Folder not found", body = String),
    ),
    tag = "folders"
)]
pub(crate) async fn delete_folder(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> std::result::Result<StatusCode, AppError> {
    state.folders.delete(&id).await?;
    Ok(StatusCode::NO_CONTENT)
}
