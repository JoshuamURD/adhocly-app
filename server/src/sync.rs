use std::collections::BTreeMap;

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::Value;
use sqlx::{Sqlite, SqliteConnection, SqlitePool, Transaction};
use utoipa::ToSchema;

use crate::{contexts, error::AppError, folders, kanban, projects, state::AppState, tasks};

type Versions = BTreeMap<String, i64>;

#[derive(Clone, Debug, Deserialize, Serialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct SyncOperation {
    pub id: String,
    pub url: String,
    pub method: String,
    pub body: Value,
    pub expected_version: i64,
}

impl SyncOperation {
    fn parts(&self) -> Result<Vec<String>, AppError> {
        if !self.url.starts_with("/api/") || self.url.contains('?') || self.url.contains('#') {
            return Err(AppError::Invalid("invalid sync URL"));
        }
        self.url[5..]
            .split('/')
            .map(|part| {
                percent_encoding::percent_decode_str(part)
                    .decode_utf8()
                    .map(|part| part.into_owned())
                    .map_err(|_| AppError::Invalid("invalid sync URL"))
            })
            .collect()
    }

    /// The revision this operation is checked against. A project's metadata values carry their own
    /// revisions (`projects/{id}/metadata/{field}`) so they do not conflict with the project row.
    fn key(&self) -> Result<String, AppError> {
        let parts = self.parts()?;
        if parts.len() == 4 && parts[0] == "projects" && parts[2] == "metadata" {
            if parts[1].trim().is_empty() || parts[3].trim().is_empty() {
                return Err(AppError::Invalid("sync requires an entity id"));
            }
            return Ok(format!("projects/{}/metadata/{}", parts[1], parts[3]));
        }
        let id = if parts.len() == 1 && self.method == "POST" {
            self.body.get("id").and_then(Value::as_str)
        } else {
            parts.get(1).map(String::as_str)
        }
        .filter(|id| !id.trim().is_empty())
        .ok_or(AppError::Invalid("sync requires an entity id"))?;
        Ok(format!("{}/{id}", parts[0]))
    }
}

#[derive(Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SyncSnapshot {
    protocol_version: u32,
    contexts: Vec<contexts::WorkContext>,
    contacts: Vec<contexts::Contact>,
    context_links: Vec<contexts::ContextLinks>,
    tasks: Vec<tasks::Task>,
    projects: Vec<projects::Project>,
    folders: Vec<folders::Folder>,
    fields: Vec<projects::MetadataField>,
    task_fields: Vec<kanban::TaskField>,
    boards: Vec<kanban::Board>,
    versions: Versions,
}

#[derive(Serialize, ToSchema)]
pub(crate) struct SyncReply {
    /// Omitted when the caller asked for `?snapshot=false`: the client only needs the snapshot for
    /// the last operation of a batch, and a whole-dataset reply per operation is the dominant cost.
    snapshot: Option<SyncSnapshot>,
    /// Only versions changed by this operation, not unrelated changes from another device.
    changes: Versions,
}

/// Query options for `POST /api/sync`; kept out of `SyncOperation` so retry receipts still compare.
#[derive(Debug, Deserialize)]
pub(crate) struct SyncQuery {
    snapshot: Option<bool>,
}

async fn versions(conn: &mut SqliteConnection) -> Result<Versions, AppError> {
    Ok(
        sqlx::query_as::<_, (String, i64)>("SELECT key, version FROM sync_versions")
            .fetch_all(conn)
            .await?
            .into_iter()
            .collect(),
    )
}

/// Owns the business write, revision check, and durable retry receipt in one transaction.
/// Dropping an unfinished Write rolls back all three, including on request cancellation.
pub(crate) struct Write {
    pub transaction: Transaction<'static, Sqlite>,
    operation: Option<SyncOperation>,
    before: Versions,
    replay: Option<String>,
}

impl Write {
    pub async fn begin(
        pool: &SqlitePool,
        operation: Option<&SyncOperation>,
    ) -> Result<Self, AppError> {
        let mut transaction = pool.begin_with("BEGIN IMMEDIATE").await?;
        let mut before = Versions::new();
        let mut replay = None;
        if let Some(operation) = operation {
            let request = serde_json::to_string(operation)?;
            // The stored result is what a replay returns: the row can be gone by then (deleted on
            // another device, or a deleted recurring successor), so the receipt remembers the answer.
            let receipt = sqlx::query_as::<_, (String, String)>(
                "SELECT request, result FROM sync_receipts WHERE id = ?",
            )
            .bind(&operation.id)
            .fetch_optional(&mut *transaction)
            .await?;
            if let Some((original, result)) = receipt {
                if original != request {
                    return Err(AppError::Conflict(
                        "mutation id was already used for a different request",
                    ));
                }
                replay = Some(result);
            } else {
                // ponytail: full version maps fit a personal app; use a change sequence if this becomes large.
                before = versions(&mut transaction).await?;
                if before.get(&operation.key()?).copied().unwrap_or(0) != operation.expected_version
                {
                    return Err(AppError::Conflict("This item changed on another device. Review the server version before keeping your change."));
                }
            }
        }
        Ok(Self {
            transaction,
            operation: operation.cloned(),
            before,
            replay,
        })
    }

    pub fn replay<T: DeserializeOwned>(&self) -> Result<Option<T>, AppError> {
        self.replay
            .as_deref()
            .map(serde_json::from_str)
            .transpose()
            .map_err(Into::into)
    }

    pub async fn commit<T: Serialize>(mut self, value: T) -> Result<T, AppError> {
        if let Some(operation) = &self.operation {
            let after = versions(&mut self.transaction).await?;
            let changes: Versions = after
                .into_iter()
                .filter(|(key, version)| self.before.get(key) != Some(version))
                .collect();
            sqlx::query(
                "INSERT INTO sync_receipts (id, request, result, changes) VALUES (?, ?, ?, ?)",
            )
            .bind(&operation.id)
            .bind(serde_json::to_string(operation)?)
            .bind(serde_json::to_string(&value)?)
            .bind(serde_json::to_string(&changes)?)
            .execute(&mut *self.transaction)
            .await?;
        }
        self.transaction.commit().await?;
        Ok(value)
    }
}

async fn snapshot(pool: &SqlitePool) -> Result<SyncSnapshot, AppError> {
    let mut tx = pool.begin().await?;
    let snapshot = SyncSnapshot {
        protocol_version: 6,
        contexts: contexts::contexts_in(&mut tx).await?,
        contacts: contexts::contacts_in(&mut tx).await?,
        context_links: contexts::links_in(&mut tx).await?,
        tasks: tasks::SqliteTaskRepository::list_in(&mut tx).await?,
        projects: projects::SqliteProjectRepository::list_in(&mut tx).await?,
        folders: folders::SqliteFolderRepository::list_in(&mut tx).await?,
        fields: projects::SqliteProjectRepository::list_fields_in(&mut tx).await?,
        task_fields: kanban::KanbanRepository::fields_in(&mut tx).await?,
        boards: kanban::KanbanRepository::boards_in(&mut tx).await?,
        versions: versions(&mut tx).await?,
    };
    tx.commit().await?;
    Ok(snapshot)
}

#[utoipa::path(get, path = "/api/sync", operation_id = "getSyncSnapshot",
    responses((status = 200, description = "Atomic server snapshot and entity revisions", body = SyncSnapshot)), tag = "sync")]
pub(crate) async fn get_snapshot(
    State(state): State<AppState>,
) -> Result<Json<SyncSnapshot>, AppError> {
    Ok(Json(snapshot(state.pool()).await?))
}

#[utoipa::path(post, path = "/api/sync", operation_id = "applySyncOperation", request_body = SyncOperation,
    params(("snapshot" = Option<bool>, Query, description = "Set false to omit the full snapshot from the reply; absent means true")),
    responses((status = 200, description = "Committed or previously committed mutation", body = SyncReply),
        (status = 400, description = "Invalid mutation", body = String),
        (status = 404, description = "Entity not found", body = String),
        (status = 409, description = "Revision or mutation id conflict", body = String)), tag = "sync")]
pub(crate) async fn apply(
    State(state): State<AppState>,
    Query(query): Query<SyncQuery>,
    Json(operation): Json<SyncOperation>,
) -> Result<Json<SyncReply>, AppError> {
    if operation.id.trim().is_empty() || operation.id.len() > 128 || operation.expected_version < 0
    {
        return Err(AppError::Invalid("invalid mutation id or expected version"));
    }
    operation.key()?;
    let parts = operation.parts()?;
    let parts: Vec<&str> = parts.iter().map(String::as_str).collect();
    let scoped = State(AppState::with_sync(
        state.pool().clone(),
        Some(operation.clone()),
    ));
    macro_rules! body {
        () => {
            Json(
                serde_json::from_value(operation.body.clone())
                    .map_err(|_| AppError::Invalid("invalid mutation body"))?,
            )
        };
    }
    // Reuse the same handlers and validation as online clients; each write owns its transaction.
    match (operation.method.as_str(), parts.as_slice()) {
        ("PUT", ["contexts", id]) => {
            let _ = contexts::save_context(Path(id.to_string()), scoped, body!()).await?;
        }
        ("DELETE", ["contexts", id]) => {
            let _ = contexts::delete_context(Path(id.to_string()), scoped).await?;
        }
        ("PUT", ["contacts", id]) => {
            let _ = contexts::save_contact(Path(id.to_string()), scoped, body!()).await?;
        }
        ("DELETE", ["contacts", id]) => {
            let _ = contexts::delete_contact(Path(id.to_string()), scoped).await?;
        }
        ("PUT", ["context-links", id]) => {
            let _ = contexts::save_links(Path(id.to_string()), scoped, body!()).await?;
        }
        ("POST", ["task-fields"]) => {
            let _ = kanban::create_field(scoped, body!()).await?;
        }
        ("PUT", ["task-fields", id]) => {
            let _ = kanban::update_field(Path(id.to_string()), scoped, body!()).await?;
        }
        ("POST", ["boards"]) => {
            let _ = kanban::create_board(scoped, body!()).await?;
        }
        ("PUT", ["boards", id]) => {
            let _ = kanban::update_board(Path(id.to_string()), scoped, body!()).await?;
        }
        ("DELETE", ["boards", id]) => {
            let _ = kanban::delete_board(Path(id.to_string()), scoped).await?;
        }
        ("POST", ["tasks"]) => {
            let _ = tasks::create_task(scoped, body!()).await?;
        }
        ("PUT", ["tasks", id]) => {
            let _ = tasks::update_task(Path(id.to_string()), scoped, body!()).await?;
        }
        ("DELETE", ["tasks", id]) => {
            let _ = tasks::delete_task(Path(id.to_string()), scoped).await?;
        }
        ("POST", ["tasks", id, "toggle"]) => {
            let _ = tasks::toggle_task(Path(id.to_string()), scoped, body!()).await?;
        }
        ("POST", ["projects"]) => {
            let _ = projects::create_project(scoped, body!()).await?;
        }
        ("PUT", ["projects", id]) => {
            let _ = projects::update_project(Path(id.to_string()), scoped, body!()).await?;
        }
        ("DELETE", ["projects", id]) => {
            let _ = projects::delete_project(Path(id.to_string()), scoped).await?;
        }
        ("PUT", ["projects", id, "folder"]) => {
            let _ = projects::move_project(Path(id.to_string()), scoped, body!()).await?;
        }
        ("PUT", ["projects", id, "metadata", field]) => {
            let _ = projects::set_project_metadata(
                Path((id.to_string(), field.to_string())),
                scoped,
                body!(),
            )
            .await?;
        }
        ("POST", ["folders"]) => {
            let _ = folders::create_folder(scoped, body!()).await?;
        }
        ("PUT", ["folders", id]) => {
            let _ = folders::update_folder(Path(id.to_string()), scoped, body!()).await?;
        }
        ("DELETE", ["folders", id]) => {
            let _ = folders::delete_folder(Path(id.to_string()), scoped).await?;
        }
        ("POST", ["metadata-fields"]) => {
            let _ = projects::create_metadata_field(scoped, body!()).await?;
        }
        ("PUT", ["metadata-fields", id]) => {
            let _ = projects::update_metadata_field(Path(id.to_string()), scoped, body!()).await?;
        }
        ("DELETE", ["metadata-fields", id]) => {
            let _ = projects::delete_metadata_field(Path(id.to_string()), scoped).await?;
        }
        _ => return Err(AppError::Invalid("unsupported sync operation")),
    }
    // A handler that writes nothing leaves no receipt; that is a routed-operation bug, so say so
    // instead of reporting the database as unavailable (which clients retry as transient).
    let changes: String = sqlx::query_scalar("SELECT changes FROM sync_receipts WHERE id = ?")
        .bind(&operation.id)
        .fetch_optional(state.pool())
        .await?
        .ok_or(AppError::Internal("sync operation recorded no receipt"))?;
    let snapshot = if query.snapshot.unwrap_or(true) {
        Some(snapshot(state.pool()).await?)
    } else {
        None
    };
    Ok(Json(SyncReply {
        snapshot,
        changes: serde_json::from_str(&changes)?,
    }))
}

#[cfg(test)]
mod tests;
