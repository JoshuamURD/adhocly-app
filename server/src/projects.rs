use std::collections::HashMap;

use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, SqlitePool};
use utoipa::ToSchema;

use crate::error::AppError;

/// Seeded by migration 0002; the fallback home for tasks whose project is deleted.
pub(crate) const INBOX_ID: &str = "inbox";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "lowercase")]
pub(crate) enum FieldKind {
    Text,
    Number,
    Choice,
}

impl FieldKind {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "text" => Some(Self::Text),
            "number" => Some(Self::Number),
            "choice" => Some(Self::Choice),
            _ => None,
        }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Number => "number",
            Self::Choice => "choice",
        }
    }
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Project {
    id: String,
    name: String,
    created_at: String,
    updated_at: String,
    /// Loaded in a second query, never a column on `projects`.
    metadata: Vec<MetadataValue>,
}

#[derive(Debug, FromRow)]
struct ProjectRow {
    id: String,
    name: String,
    created_at: String,
    updated_at: String,
}

impl From<ProjectRow> for Project {
    fn from(row: ProjectRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            created_at: row.created_at,
            updated_at: row.updated_at,
            metadata: Vec::new(),
        }
    }
}

#[derive(Debug, Serialize, ToSchema, FromRow)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataValue {
    field_id: String,
    value: String,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataField {
    id: String,
    name: String,
    kind: FieldKind,
    options: Vec<String>,
    created_at: String,
}

/// `metadata_fields.kind` and `.options` are stored as text; the API exposes them decoded.
#[derive(Debug, FromRow)]
struct FieldRow {
    id: String,
    name: String,
    kind: String,
    options: String,
    created_at: String,
}

impl From<FieldRow> for MetadataField {
    fn from(row: FieldRow) -> Self {
        Self {
            id: row.id,
            name: row.name,
            // The CHECK constraint in migration 0002 makes an unknown kind unreachable.
            kind: FieldKind::parse(&row.kind).unwrap_or(FieldKind::Text),
            options: row.options.lines().map(str::to_owned).collect(),
            created_at: row.created_at,
        }
    }
}

#[derive(Debug, FromRow)]
struct ProjectValue {
    project_id: String,
    field_id: String,
    value: String,
}

#[derive(Debug, Deserialize, ToSchema)]
pub(crate) struct ProjectInput {
    name: String,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataFieldInput {
    name: String,
    kind: FieldKind,
    #[serde(default)]
    options: Vec<String>,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MetadataFieldUpdate {
    name: String,
    #[serde(default)]
    options: Vec<String>,
}

#[derive(Debug, Deserialize, ToSchema)]
pub(crate) struct MetadataValueInput {
    /// Omit or send null/blank to clear the value.
    value: Option<String>,
}

fn encode_options(options: &[String]) -> String {
    options.join("\n")
}

fn name_or_invalid(name: &str) -> Result<&str, AppError> {
    let name = name.trim();
    if name.is_empty() {
        return Err(AppError::Invalid("name is required"));
    }
    Ok(name)
}

/// Choice fields keep their option list; every other kind stores none.
fn normalize_options(kind: FieldKind, options: Vec<String>) -> Result<Vec<String>, AppError> {
    if kind != FieldKind::Choice {
        return Ok(Vec::new());
    }

    let mut unique: Vec<String> = Vec::new();
    for option in options {
        let option = option.trim();
        if !option.is_empty() && !unique.iter().any(|existing| existing == option) {
            unique.push(option.to_owned());
        }
    }
    if unique.is_empty() {
        return Err(AppError::Invalid("choice fields need at least one option"));
    }
    Ok(unique)
}

fn validate_value(kind: FieldKind, options: &[String], value: &str) -> Result<(), AppError> {
    match kind {
        FieldKind::Text => Ok(()),
        FieldKind::Number => {
            if value.parse::<f64>().is_ok_and(f64::is_finite) {
                Ok(())
            } else {
                Err(AppError::Invalid("value must be a number"))
            }
        }
        FieldKind::Choice => {
            if options.iter().any(|option| option.as_str() == value) {
                Ok(())
            } else {
                Err(AppError::Invalid("value must be one of the field options"))
            }
        }
    }
}

async fn project_or_404<'e, E>(db: E, id: &str) -> Result<Project, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    sqlx::query_as::<_, ProjectRow>("SELECT * FROM projects WHERE id = ?")
        .bind(id)
        .fetch_optional(db)
        .await?
        .map(Project::from)
        .ok_or(AppError::NotFound("project"))
}

async fn field_or_404<'e, E>(db: E, id: &str) -> Result<MetadataField, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    let row = sqlx::query_as::<_, FieldRow>("SELECT * FROM metadata_fields WHERE id = ?")
        .bind(id)
        .fetch_optional(db)
        .await?
        .ok_or(AppError::NotFound("field"))?;
    Ok(row.into())
}

async fn load_project(db: &SqlitePool, id: &str) -> Result<Project, AppError> {
    let mut project = project_or_404(db, id).await?;
    project.metadata = sqlx::query_as::<_, MetadataValue>(
        "SELECT field_id, value FROM project_metadata WHERE project_id = ? ORDER BY field_id",
    )
    .bind(id)
    .fetch_all(db)
    .await?;
    Ok(project)
}

#[utoipa::path(
    get,
    path = "/api/projects",
    operation_id = "listProjects",
    responses((status = 200, description = "Projects with their metadata values", body = [Project])),
    tag = "projects"
)]
pub(crate) async fn list_projects(
    State(db): State<SqlitePool>,
) -> std::result::Result<Json<Vec<Project>>, AppError> {
    let mut projects: Vec<Project> = sqlx::query_as::<_, ProjectRow>(
        "SELECT * FROM projects ORDER BY name COLLATE NOCASE",
    )
    .fetch_all(&db)
    .await?
    .into_iter()
    .map(Project::from)
    .collect();

    let values = sqlx::query_as::<_, ProjectValue>(
        "SELECT project_id, field_id, value FROM project_metadata ORDER BY project_id, field_id",
    )
    .fetch_all(&db)
    .await?;

    let mut by_project: HashMap<String, Vec<MetadataValue>> = HashMap::new();
    for row in values {
        by_project
            .entry(row.project_id)
            .or_default()
            .push(MetadataValue {
                field_id: row.field_id,
                value: row.value,
            });
    }
    for project in &mut projects {
        project.metadata = by_project.remove(&project.id).unwrap_or_default();
    }

    Ok(Json(projects))
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
    State(db): State<SqlitePool>,
) -> std::result::Result<Json<Project>, AppError> {
    Ok(Json(load_project(&db, &id).await?))
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
    State(db): State<SqlitePool>,
    Json(input): Json<ProjectInput>,
) -> std::result::Result<(StatusCode, Json<Project>), AppError> {
    let name = name_or_invalid(&input.name)?;
    let saved = sqlx::query_as::<_, ProjectRow>(
        "INSERT INTO projects (id, name, created_at, updated_at)
         VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
         RETURNING *",
    )
    .bind(uuid::Uuid::now_v7().to_string())
    .bind(name)
    .fetch_one(&db)
    .await?;
    Ok((StatusCode::CREATED, Json(saved.into())))
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
    State(db): State<SqlitePool>,
    Json(input): Json<ProjectInput>,
) -> std::result::Result<Json<Project>, AppError> {
    let name = name_or_invalid(&input.name)?;
    let result = sqlx::query(
        "UPDATE projects SET name = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
    )
    .bind(name)
    .bind(&id)
    .execute(&db)
    .await?;
    if result.rows_affected() == 0 {
        return Err(AppError::NotFound("project"));
    }
    Ok(Json(load_project(&db, &id).await?))
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
    State(db): State<SqlitePool>,
) -> std::result::Result<StatusCode, AppError> {
    if id == INBOX_ID {
        return Err(AppError::Invalid("Inbox cannot be deleted"));
    }

    let mut transaction = db.begin().await?;
    sqlx::query("UPDATE tasks SET project_id = ? WHERE project_id = ?")
        .bind(INBOX_ID)
        .bind(&id)
        .execute(&mut *transaction)
        .await?;
    let deleted = sqlx::query("DELETE FROM projects WHERE id = ?")
        .bind(&id)
        .execute(&mut *transaction)
        .await?;
    if deleted.rows_affected() == 0 {
        return Err(AppError::NotFound("project"));
    }
    transaction.commit().await?;
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
    State(db): State<SqlitePool>,
) -> std::result::Result<Json<Vec<MetadataField>>, AppError> {
    let rows = sqlx::query_as::<_, FieldRow>(
        "SELECT * FROM metadata_fields ORDER BY created_at, id",
    )
    .fetch_all(&db)
    .await?;
    Ok(Json(rows.into_iter().map(MetadataField::from).collect()))
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
    State(db): State<SqlitePool>,
    Json(input): Json<MetadataFieldInput>,
) -> std::result::Result<(StatusCode, Json<MetadataField>), AppError> {
    let name = name_or_invalid(&input.name)?;
    let options = normalize_options(input.kind, input.options)?;
    let row = sqlx::query_as::<_, FieldRow>(
        "INSERT INTO metadata_fields (id, name, kind, options, created_at)
         VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
         RETURNING *",
    )
    .bind(uuid::Uuid::now_v7().to_string())
    .bind(name)
    .bind(input.kind.as_str())
    .bind(encode_options(&options))
    .fetch_one(&db)
    .await?;
    Ok((StatusCode::CREATED, Json(row.into())))
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
    State(db): State<SqlitePool>,
    Json(input): Json<MetadataFieldUpdate>,
) -> std::result::Result<Json<MetadataField>, AppError> {
    let name = name_or_invalid(&input.name)?.to_owned();
    let existing = field_or_404(&db, &id).await?;
    let options = normalize_options(existing.kind, input.options)?;
    let row = sqlx::query_as::<_, FieldRow>(
        "UPDATE metadata_fields SET name = ?, options = ? WHERE id = ? RETURNING *",
    )
    .bind(name)
    .bind(encode_options(&options))
    .bind(id)
    .fetch_one(&db)
    .await?;
    Ok(Json(row.into()))
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
    State(db): State<SqlitePool>,
) -> std::result::Result<StatusCode, AppError> {
    let result = sqlx::query("DELETE FROM metadata_fields WHERE id = ?")
        .bind(id)
        .execute(&db)
        .await?;
    if result.rows_affected() == 0 {
        return Err(AppError::NotFound("field"));
    }
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
    State(db): State<SqlitePool>,
    Json(input): Json<MetadataValueInput>,
) -> std::result::Result<StatusCode, AppError> {
    let field = field_or_404(&db, &field_id).await?;
    project_or_404(&db, &id).await?;

    let value = input
        .value
        .map(|value| value.trim().to_owned())
        .filter(|value| !value.is_empty());

    match value {
        None => {
            sqlx::query("DELETE FROM project_metadata WHERE project_id = ? AND field_id = ?")
                .bind(&id)
                .bind(&field_id)
                .execute(&db)
                .await?;
        }
        Some(value) => {
            validate_value(field.kind, &field.options, &value)?;
            sqlx::query(
                "INSERT INTO project_metadata (project_id, field_id, value) VALUES (?, ?, ?)
                 ON CONFLICT (project_id, field_id) DO UPDATE SET value = excluded.value",
            )
            .bind(&id)
            .bind(&field_id)
            .bind(value)
            .execute(&db)
            .await?;
        }
    }

    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::sqlite::SqlitePoolOptions;

    async fn test_db() -> SqlitePool {
        let db = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!().run(&db).await.unwrap();
        db
    }

    async fn add_task(db: &SqlitePool, id: &str, project_id: &str) {
        sqlx::query(
            "INSERT INTO tasks (id, title, project_id, created_at, updated_at, completed)
             VALUES (?, 'A task', ?, '2026-01-01', '2026-01-01', 0)",
        )
        .bind(id)
        .bind(project_id)
        .execute(db)
        .await
        .unwrap();
    }

    async fn project_name(db: &SqlitePool, id: &str) -> Option<String> {
        sqlx::query_scalar("SELECT name FROM projects WHERE id = ?")
            .bind(id)
            .fetch_optional(db)
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn create_rename_and_delete_moves_tasks_to_inbox() {
        let db = test_db().await;
        let (_, Json(project)) = create_project(
            State(db.clone()),
            Json(ProjectInput {
                name: "  Client Work  ".into(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(project.name, "Client Work");
        assert!(project.metadata.is_empty());

        // Same name in another case is rejected by the NOCASE unique index.
        let conflict = create_project(
            State(db.clone()),
            Json(ProjectInput {
                name: "client work".into(),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(conflict.to_string(), "that name is already taken");

        add_task(&db, "task-1", &project.id).await;

        let Json(renamed) = update_project(
            Path(project.id.clone()),
            State(db.clone()),
            Json(ProjectInput {
                name: "Acme".into(),
            }),
        )
        .await
        .unwrap();
        assert_eq!(renamed.name, "Acme");

        delete_project(Path(project.id.clone()), State(db.clone()))
            .await
            .unwrap();
        assert_eq!(project_name(&db, &project.id).await, None);
        let project_id: String = sqlx::query_scalar("SELECT project_id FROM tasks WHERE id = 'task-1'")
            .fetch_one(&db)
            .await
            .unwrap();
        assert_eq!(project_id, INBOX_ID);

        let inbox_error = delete_project(Path(INBOX_ID.to_owned()), State(db.clone()))
            .await
            .unwrap_err();
        assert_eq!(inbox_error.to_string(), "Inbox cannot be deleted");
        assert!(project_name(&db, INBOX_ID).await.is_some());
    }

    #[tokio::test]
    async fn metadata_fields_round_trip_and_validate_values() {
        let db = test_db().await;

        let (_, Json(client)) = create_metadata_field(
            State(db.clone()),
            Json(MetadataFieldInput {
                name: "Client".into(),
                kind: FieldKind::Text,
                options: vec!["ignored".into()],
            }),
        )
        .await
        .unwrap();
        assert!(client.options.is_empty());

        let (_, Json(budget)) = create_metadata_field(
            State(db.clone()),
            Json(MetadataFieldInput {
                name: "Budget".into(),
                kind: FieldKind::Number,
                options: vec![],
            }),
        )
        .await
        .unwrap();

        let (_, Json(status)) = create_metadata_field(
            State(db.clone()),
            Json(MetadataFieldInput {
                name: "Status".into(),
                kind: FieldKind::Choice,
                options: vec!["Active".into(), " Active ".into(), "Paused".into(), "".into()],
            }),
        )
        .await
        .unwrap();
        assert_eq!(status.options, vec!["Active", "Paused"]);

        let no_options = create_metadata_field(
            State(db.clone()),
            Json(MetadataFieldInput {
                name: "Stage".into(),
                kind: FieldKind::Choice,
                options: vec![],
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(no_options.to_string(), "choice fields need at least one option");

        let (_, Json(project)) = create_project(
            State(db.clone()),
            Json(ProjectInput {
                name: "Website".into(),
            }),
        )
        .await
        .unwrap();

        for (field, value) in [
            (&client, "Acme"),
            (&budget, "1200"),
            (&status, "Paused"),
        ] {
            set_project_metadata(
                Path((project.id.clone(), field.id.clone())),
                State(db.clone()),
                Json(MetadataValueInput {
                    value: Some(value.into()),
                }),
            )
            .await
            .unwrap();
        }

        let Json(loaded) = get_project(Path(project.id.clone()), State(db.clone()))
            .await
            .unwrap();
        let mut values: Vec<(&str, &str)> = loaded
            .metadata
            .iter()
            .map(|value| (value.field_id.as_str(), value.value.as_str()))
            .collect();
        values.sort();
        let mut expected = vec![
            (client.id.as_str(), "Acme"),
            (budget.id.as_str(), "1200"),
            (status.id.as_str(), "Paused"),
        ];
        expected.sort();
        assert_eq!(values, expected);

        let not_a_number = set_project_metadata(
            Path((project.id.clone(), budget.id.clone())),
            State(db.clone()),
            Json(MetadataValueInput {
                value: Some("abc".into()),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(not_a_number.to_string(), "value must be a number");

        let not_an_option = set_project_metadata(
            Path((project.id.clone(), status.id.clone())),
            State(db.clone()),
            Json(MetadataValueInput {
                value: Some("Archived".into()),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(
            not_an_option.to_string(),
            "value must be one of the field options"
        );

        // Blank clears, and the invalid attempts above left the stored values alone.
        set_project_metadata(
            Path((project.id.clone(), budget.id.clone())),
            State(db.clone()),
            Json(MetadataValueInput {
                value: Some("  ".into()),
            }),
        )
        .await
        .unwrap();
        let Json(loaded) = get_project(Path(project.id.clone()), State(db.clone()))
            .await
            .unwrap();
        assert_eq!(loaded.metadata.len(), 2);
        assert!(!loaded.metadata.iter().any(|value| value.field_id == budget.id));

        let Json(projects) = list_projects(State(db.clone())).await.unwrap();
        let website = projects.iter().find(|p| p.id == project.id).unwrap();
        assert_eq!(website.metadata.len(), 2);

        let Json(fields) = list_metadata_fields(State(db.clone())).await.unwrap();
        assert_eq!(fields.len(), 3);
        assert_eq!(fields[2].kind, FieldKind::Choice);

        // Renaming keeps the kind and option list; values are untouched.
        let Json(renamed) = update_metadata_field(
            Path(status.id.clone()),
            State(db.clone()),
            Json(MetadataFieldUpdate {
                name: "State".into(),
                options: vec!["Active".into()],
            }),
        )
        .await
        .unwrap();
        assert_eq!(renamed.name, "State");
        assert_eq!(renamed.options, vec!["Active"]);

        delete_metadata_field(Path(status.id.clone()), State(db.clone()))
            .await
            .unwrap();
        let Json(loaded) = get_project(Path(project.id), State(db.clone()))
            .await
            .unwrap();
        assert_eq!(loaded.metadata.len(), 1);

        let missing = set_project_metadata(
            Path((INBOX_ID.to_owned(), status.id)),
            State(db.clone()),
            Json(MetadataValueInput {
                value: Some("Active".into()),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(missing.to_string(), "field not found");
    }
}
