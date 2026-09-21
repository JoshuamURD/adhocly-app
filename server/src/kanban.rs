use std::collections::{BTreeMap, BTreeSet};

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::{types::Json as SqlJson, FromRow, SqliteConnection, SqlitePool};
use utoipa::ToSchema;

use crate::{
    error::AppError,
    projects::FieldKind,
    state::AppState,
    sync::{SyncOperation, Write},
};

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct FieldOption {
    pub id: String,
    pub name: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema, FromRow)]
#[serde(deny_unknown_fields)]
pub(crate) struct TaskField {
    pub id: String,
    pub name: String,
    // Stored as a string so FromRow doesn't need a database-specific enum encoding.
    pub kind: String,
    #[schema(value_type = Vec<FieldOption>)]
    pub options: SqlJson<Vec<FieldOption>>,
}

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema, FromRow)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Board {
    pub id: String,
    pub name: String,
    pub field_id: String,
    #[serde(default = "default_sort_mode")]
    pub sort_mode: String,
    #[serde(default)]
    #[schema(value_type = Vec<String>)]
    pub manual_order: SqlJson<Vec<String>>,
}

fn default_sort_mode() -> String {
    "created".into()
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct BoardInput {
    pub id: String,
    pub name: String,
    pub field_id: String,
    /// Missing sorting fields preserve existing settings for older clients.
    pub sort_mode: Option<String>,
    pub manual_order: Option<Vec<String>>,
}

#[derive(Clone)]
pub(crate) struct KanbanRepository {
    db: SqlitePool,
    sync: Option<SyncOperation>,
}

impl KanbanRepository {
    pub fn new(db: SqlitePool, sync: Option<SyncOperation>) -> Self {
        Self { db, sync }
    }

    pub async fn fields_in(conn: &mut SqliteConnection) -> Result<Vec<TaskField>, AppError> {
        Ok(
            sqlx::query_as("SELECT id, name, kind, options FROM task_fields ORDER BY id")
                .fetch_all(conn)
                .await?,
        )
    }

    pub async fn boards_in(conn: &mut SqliteConnection) -> Result<Vec<Board>, AppError> {
        Ok(sqlx::query_as(
            "SELECT id, name, field_id, sort_mode, manual_order FROM boards ORDER BY name, id",
        )
        .fetch_all(conn)
        .await?)
    }

    pub async fn save_field(
        &self,
        mut field: TaskField,
        create: bool,
    ) -> Result<TaskField, AppError> {
        validate_id(&field.id)?;
        field.name = field.name.trim().to_owned();
        if field.name.is_empty() {
            return Err(AppError::Invalid("field name is required"));
        }
        let kind =
            FieldKind::parse(&field.kind).ok_or(AppError::Invalid("unknown task field kind"))?;
        if kind != FieldKind::Choice && !field.options.is_empty() {
            return Err(AppError::Invalid("only choice fields have options"));
        }
        let mut ids = BTreeSet::new();
        let mut names = BTreeSet::new();
        for option in &mut field.options.0 {
            validate_id(&option.id)?;
            option.name = option.name.trim().to_owned();
            if option.name.is_empty()
                || !ids.insert(option.id.clone())
                || !names.insert(option.name.to_lowercase())
            {
                return Err(AppError::Invalid(
                    "option ids and names must be nonempty and unique",
                ));
            }
        }
        if kind == FieldKind::Choice && field.options.is_empty() {
            return Err(AppError::Invalid("choice fields need at least one option"));
        }
        if field.id == "status"
            && (kind != FieldKind::Choice || !ids.contains("todo") || !ids.contains("complete"))
        {
            return Err(AppError::Invalid(
                "Status must keep the todo and complete options; their names may change",
            ));
        }
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        if !create {
            let existing: Option<String> =
                sqlx::query_scalar("SELECT kind FROM task_fields WHERE id = ?")
                    .bind(&field.id)
                    .fetch_optional(&mut *conn)
                    .await?;
            let existing = existing.ok_or(AppError::NotFound("task field"))?;
            if existing != field.kind {
                return Err(AppError::Invalid(
                    "a field's type cannot change; create a new field",
                ));
            }
            let values: Vec<String> = if field.id == "status" {
                sqlx::query_scalar("SELECT DISTINCT status_id FROM tasks")
                    .fetch_all(&mut *conn)
                    .await?
            } else {
                sqlx::query_scalar("SELECT DISTINCT value FROM tasks, json_each(tasks.properties) WHERE json_each.key = ?")
                    .bind(&field.id).fetch_all(&mut *conn).await?
            };
            if kind == FieldKind::Choice && values.iter().any(|v| !ids.contains(v)) {
                return Err(AppError::Invalid(
                    "an option still has tasks; move them before removing it",
                ));
            }
        }
        let options = serde_json::to_string(&field.options)?;
        if create {
            sqlx::query("INSERT INTO task_fields (id, name, kind, options) VALUES (?, ?, ?, ?)")
                .bind(&field.id)
                .bind(&field.name)
                .bind(&field.kind)
                .bind(options)
                .execute(conn)
                .await?;
        } else {
            sqlx::query("UPDATE task_fields SET name = ?, options = ? WHERE id = ?")
                .bind(&field.name)
                .bind(options)
                .bind(&field.id)
                .execute(conn)
                .await?;
        }
        write.commit(field).await
    }

    pub async fn save_board(&self, mut board: BoardInput, create: bool) -> Result<Board, AppError> {
        validate_id(&board.id)?;
        board.name = board.name.trim().to_owned();
        if board.name.is_empty() {
            return Err(AppError::Invalid("board name is required"));
        }
        if board.sort_mode.as_deref().is_some_and(|mode| {
            !["due", "planned", "created", "alphabetical", "manual"].contains(&mode)
        }) {
            return Err(AppError::Invalid("unknown board sort mode"));
        }
        if let Some(order) = &board.manual_order {
            let mut ids = BTreeSet::new();
            if order
                .iter()
                .any(|id| id.trim().is_empty() || !ids.insert(id))
            {
                return Err(AppError::Invalid(
                    "manual order requires unique, nonempty task ids",
                ));
            }
        }
        let manual_order = board
            .manual_order
            .as_ref()
            .map(serde_json::to_string)
            .transpose()?;
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let exists: bool =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM task_fields WHERE id = ?)")
                .bind(&board.field_id)
                .fetch_one(&mut *conn)
                .await?;
        if !exists {
            return Err(AppError::Invalid("task field does not exist"));
        }
        if create {
            sqlx::query("INSERT INTO boards (id, name, field_id, sort_mode, manual_order) VALUES (?, ?, ?, COALESCE(?, 'created'), COALESCE(?, '[]'))")
                .bind(&board.id)
                .bind(&board.name)
                .bind(&board.field_id)
                .bind(&board.sort_mode)
                .bind(&manual_order)
                .execute(&mut *conn)
                .await?;
        } else if sqlx::query("UPDATE boards SET name = ?, field_id = ?, sort_mode = COALESCE(?, sort_mode), manual_order = COALESCE(?, manual_order) WHERE id = ?")
            .bind(&board.name)
            .bind(&board.field_id)
            .bind(&board.sort_mode)
            .bind(&manual_order)
            .bind(&board.id)
            .execute(&mut *conn)
            .await?
            .rows_affected()
            == 0
        {
            return Err(AppError::NotFound("board"));
        }
        let saved: Board = sqlx::query_as(
            "SELECT id, name, field_id, sort_mode, manual_order FROM boards WHERE id = ?",
        )
        .bind(&board.id)
        .fetch_one(conn)
        .await?;
        write.commit(saved).await
    }

    pub async fn delete_board(&self, id: &str) -> Result<(), AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        if sqlx::query("DELETE FROM boards WHERE id = ?")
            .bind(id)
            .execute(&mut *write.transaction)
            .await?
            .rows_affected()
            == 0
        {
            return Err(AppError::NotFound("board"));
        }
        write.commit(()).await
    }
}

fn validate_id(id: &str) -> Result<(), AppError> {
    if id.is_empty()
        || id.len() > 128
        || !id
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
    {
        return Err(AppError::Invalid(
            "ids must contain 1–128 letters, digits, hyphens or underscores",
        ));
    }
    Ok(())
}

/// Task fields and values are checked inside the same write transaction as the task, so an option
/// cannot be removed between validation and saving. Missing properties on old clients are preserved.
pub(crate) async fn validate_task_values(
    conn: &mut SqliteConnection,
    status: &str,
    properties: &BTreeMap<String, String>,
) -> Result<(), AppError> {
    let fields = KanbanRepository::fields_in(conn).await?;
    let status_field = fields
        .iter()
        .find(|f| f.id == "status")
        .ok_or(AppError::Internal("status field is missing"))?;
    if !status_field.options.iter().any(|o| o.id == status) {
        return Err(AppError::Invalid("unknown task status"));
    }
    for (id, value) in properties {
        if id == "status" {
            return Err(AppError::Invalid("use statusId for a task's status"));
        }
        let field = fields
            .iter()
            .find(|f| f.id == *id)
            .ok_or(AppError::Invalid("unknown task property"))?;
        match FieldKind::parse(&field.kind).ok_or(AppError::Invalid("unknown task field kind"))? {
            FieldKind::Choice if !field.options.iter().any(|o| o.id == *value) => {
                return Err(AppError::Invalid("unknown task property option"))
            }
            FieldKind::Number if !value.parse::<f64>().is_ok_and(f64::is_finite) => {
                return Err(AppError::Invalid("task property must be a finite number"))
            }
            _ => {}
        }
    }
    Ok(())
}

#[utoipa::path(get, path = "/api/task-fields", responses((status = 200, body = [TaskField])), tag = "kanban")]
pub(crate) async fn list_fields(
    State(state): State<AppState>,
) -> Result<Json<Vec<TaskField>>, AppError> {
    Ok(Json(
        KanbanRepository::fields_in(&mut *state.pool().acquire().await?).await?,
    ))
}
#[utoipa::path(post, path = "/api/task-fields", request_body = TaskField, responses((status = 201, body = TaskField), (status = 400, body = String)), tag = "kanban")]
pub(crate) async fn create_field(
    State(state): State<AppState>,
    Json(input): Json<TaskField>,
) -> Result<(StatusCode, Json<TaskField>), AppError> {
    Ok((
        StatusCode::CREATED,
        Json(state.kanban.save_field(input, true).await?),
    ))
}
#[utoipa::path(put, path = "/api/task-fields/{id}", params(("id" = String, Path)), request_body = TaskField, responses((status = 200, body = TaskField), (status = 400, body = String)), tag = "kanban")]
pub(crate) async fn update_field(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<TaskField>,
) -> Result<Json<TaskField>, AppError> {
    if id != input.id {
        return Err(AppError::Invalid("path and field ids must match"));
    }
    Ok(Json(state.kanban.save_field(input, false).await?))
}
#[utoipa::path(get, path = "/api/boards", responses((status = 200, body = [Board])), tag = "kanban")]
pub(crate) async fn list_boards(
    State(state): State<AppState>,
) -> Result<Json<Vec<Board>>, AppError> {
    Ok(Json(
        KanbanRepository::boards_in(&mut *state.pool().acquire().await?).await?,
    ))
}
#[utoipa::path(post, path = "/api/boards", request_body = BoardInput, responses((status = 201, body = Board), (status = 400, body = String)), tag = "kanban")]
pub(crate) async fn create_board(
    State(state): State<AppState>,
    Json(input): Json<BoardInput>,
) -> Result<(StatusCode, Json<Board>), AppError> {
    Ok((
        StatusCode::CREATED,
        Json(state.kanban.save_board(input, true).await?),
    ))
}
#[utoipa::path(put, path = "/api/boards/{id}", params(("id" = String, Path)), request_body = BoardInput, responses((status = 200, body = Board), (status = 400, body = String)), tag = "kanban")]
pub(crate) async fn update_board(
    Path(id): Path<String>,
    State(state): State<AppState>,
    Json(input): Json<BoardInput>,
) -> Result<Json<Board>, AppError> {
    if id != input.id {
        return Err(AppError::Invalid("path and board ids must match"));
    }
    Ok(Json(state.kanban.save_board(input, false).await?))
}
#[utoipa::path(delete, path = "/api/boards/{id}", params(("id" = String, Path)), responses((status = 204)), tag = "kanban")]
pub(crate) async fn delete_board(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> Result<StatusCode, AppError> {
    state.kanban.delete_board(&id).await?;
    Ok(StatusCode::NO_CONTENT)
}
