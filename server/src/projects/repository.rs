use std::collections::HashMap;

use async_trait::async_trait;
use sqlx::{FromRow, SqlitePool};

use crate::{
    error::AppError,
    sync::{SyncOperation, Write},
};

use super::model::{
    encode_options, normalize_options, validate_value, FieldKind, MetadataField,
    MetadataFieldInput, MetadataFieldUpdate, MetadataValue, Project,
};

#[derive(Debug, FromRow)]
struct ProjectRow {
    id: String,
    name: String,
    folder_id: Option<String>,
    created_at: String,
    updated_at: String,
}

impl From<ProjectRow> for Project {
    fn from(row: ProjectRow) -> Self {
        Self::new(
            row.id,
            row.name,
            row.folder_id,
            row.created_at,
            row.updated_at,
        )
    }
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

/// Persistence for projects, the shared metadata field library, and per-project values.
/// Names are expected to be validated by the caller; field options and values are checked here
/// because they depend on what is already stored.
#[async_trait]
pub(crate) trait ProjectRepository: Send + Sync {
    async fn list(&self) -> Result<Vec<Project>, AppError>;
    async fn get(&self, id: &str) -> Result<Project, AppError>;
    async fn create(&self, id: Option<&str>, name: &str) -> Result<Project, AppError>;
    async fn update(&self, id: &str, name: &str) -> Result<Project, AppError>;
    /// Moves the project into a folder, or to the top level when `folder_id` is `None`.
    async fn set_folder(&self, id: &str, folder_id: Option<&str>) -> Result<Project, AppError>;
    /// Moves the project's tasks to Inbox before deleting it.
    async fn delete(&self, id: &str) -> Result<(), AppError>;

    async fn list_fields(&self) -> Result<Vec<MetadataField>, AppError>;
    async fn create_field(&self, input: &MetadataFieldInput) -> Result<MetadataField, AppError>;
    /// The field kind is fixed once created; only the name and options change.
    async fn update_field(
        &self,
        id: &str,
        input: &MetadataFieldUpdate,
    ) -> Result<MetadataField, AppError>;
    async fn delete_field(&self, id: &str) -> Result<(), AppError>;

    /// `None` clears the value.
    async fn set_value(
        &self,
        project_id: &str,
        field_id: &str,
        value: Option<String>,
    ) -> Result<(), AppError>;
}

pub(crate) struct SqliteProjectRepository {
    db: SqlitePool,
    sync: Option<SyncOperation>,
}

impl SqliteProjectRepository {
    pub(crate) fn new(db: SqlitePool, sync: Option<SyncOperation>) -> Self {
        Self { db, sync }
    }

    async fn project_or_404<'e, E>(executor: E, id: &str) -> Result<Project, AppError>
    where
        E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
    {
        sqlx::query_as!(
            ProjectRow,
            "SELECT id, name, folder_id, created_at, updated_at FROM projects WHERE id = ?",
            id
        )
        .fetch_optional(executor)
        .await?
        .map(Project::from)
        .ok_or(AppError::NotFound("project"))
    }

    async fn field_or_404<'e, E>(executor: E, id: &str) -> Result<MetadataField, AppError>
    where
        E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
    {
        let row = sqlx::query_as!(
            FieldRow,
            "SELECT id, name, kind, options, created_at FROM metadata_fields WHERE id = ?",
            id
        )
        .fetch_optional(executor)
        .await?
        .ok_or(AppError::NotFound("field"))?;
        Ok(row.into())
    }

    async fn load_project(
        conn: &mut sqlx::SqliteConnection,
        id: &str,
    ) -> Result<Project, AppError> {
        // Reads back rather than trusting a write's `RETURNING` clause: SQLite reports a NULL
        // column there as SQLITE_TEXT, so an unbound `folder_id` decodes as an empty string.
        let mut project = Self::project_or_404(&mut *conn, id).await?;
        project.metadata = sqlx::query_as!(
            MetadataValue,
            "SELECT field_id, value FROM project_metadata WHERE project_id = ? ORDER BY field_id",
            id
        )
        .fetch_all(&mut *conn)
        .await?;
        Ok(project)
    }
}

#[async_trait]
impl ProjectRepository for SqliteProjectRepository {
    async fn list(&self) -> Result<Vec<Project>, AppError> {
        Self::list_in(&mut *self.db.acquire().await?).await
    }

    async fn get(&self, id: &str) -> Result<Project, AppError> {
        Self::load_project(&mut *self.db.acquire().await?, id).await
    }

    async fn create(&self, id: Option<&str>, name: &str) -> Result<Project, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            let id = id
                .map(str::to_owned)
                .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
            sqlx::query_file!("sql/projects/insert.sql", id, name)
                .execute(&mut *conn)
                .await?;
            Self::load_project(&mut *conn, &id).await
        };
        write.commit(value?).await
    }

    async fn update(&self, id: &str, name: &str) -> Result<Project, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            let result = sqlx::query!(
            "UPDATE projects SET name = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            name,
            id
        )
        .execute(&mut *conn)
        .await?;
            if result.rows_affected() == 0 {
                return Err(AppError::NotFound("project"));
            }
            Self::load_project(&mut *conn, id).await
        };
        write.commit(value?).await
    }

    async fn set_folder(&self, id: &str, folder_id: Option<&str>) -> Result<Project, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            Self::project_or_404(&mut *conn, id).await?;
            if let Some(folder_id) = folder_id {
                let parent = sqlx::query_scalar!("SELECT id FROM folders WHERE id = ?", folder_id)
                    .fetch_optional(&mut *conn)
                    .await?;
                if parent.is_none() {
                    return Err(AppError::NotFound("folder"));
                }
            }

            sqlx::query!(
            "UPDATE projects SET folder_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            folder_id,
            id
        )
        .execute(&mut *conn)
        .await?;
            Self::load_project(&mut *conn, id).await
        };
        write.commit(value?).await
    }

    async fn delete(&self, id: &str) -> Result<(), AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            sqlx::query!(
                "UPDATE tasks SET project_id = ? WHERE project_id = ?",
                super::model::INBOX_ID,
                id
            )
            .execute(&mut *conn)
            .await?;
            let deleted = sqlx::query!("DELETE FROM projects WHERE id = ?", id)
                .execute(&mut *conn)
                .await?;
            if deleted.rows_affected() == 0 {
                return Err(AppError::NotFound("project"));
            }
            Ok(())
        };
        write.commit(value?).await
    }

    async fn list_fields(&self) -> Result<Vec<MetadataField>, AppError> {
        Self::list_fields_in(&mut *self.db.acquire().await?).await
    }

    async fn create_field(&self, input: &MetadataFieldInput) -> Result<MetadataField, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            let options = normalize_options(input.kind, input.options.clone())?;
            let row = sqlx::query_file_as!(
                FieldRow,
                "sql/projects/insert_field_returning.sql",
                input
                    .id
                    .clone()
                    .unwrap_or_else(|| uuid::Uuid::now_v7().to_string()),
                input.name.trim(),
                input.kind.as_str(),
                encode_options(&options)
            )
            .fetch_one(&mut *conn)
            .await?;
            Ok(row.into())
        };
        write.commit(value?).await
    }

    async fn update_field(
        &self,
        id: &str,
        input: &MetadataFieldUpdate,
    ) -> Result<MetadataField, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            let existing = Self::field_or_404(&mut *conn, id).await?;
            let options = normalize_options(existing.kind, input.options.clone())?;
            let row = sqlx::query_file_as!(
                FieldRow,
                "sql/projects/update_field_returning.sql",
                input.name.trim(),
                encode_options(&options),
                id
            )
            .fetch_one(&mut *conn)
            .await?;
            Ok(row.into())
        };
        write.commit(value?).await
    }

    async fn delete_field(&self, id: &str) -> Result<(), AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            let result = sqlx::query!("DELETE FROM metadata_fields WHERE id = ?", id)
                .execute(&mut *conn)
                .await?;
            if result.rows_affected() == 0 {
                return Err(AppError::NotFound("field"));
            }
            Ok(())
        };
        write.commit(value?).await
    }

    async fn set_value(
        &self,
        project_id: &str,
        field_id: &str,
        value: Option<String>,
    ) -> Result<(), AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            let field = Self::field_or_404(&mut *conn, field_id).await?;
            Self::project_or_404(&mut *conn, project_id).await?;

            match value {
                None => {
                    sqlx::query!(
                        "DELETE FROM project_metadata WHERE project_id = ? AND field_id = ?",
                        project_id,
                        field_id
                    )
                    .execute(&mut *conn)
                    .await?;
                }
                Some(value) => {
                    validate_value(field.kind, &field.options, &value)?;
                    sqlx::query_file!(
                        "sql/projects/upsert_metadata.sql",
                        project_id,
                        field_id,
                        value
                    )
                    .execute(&mut *conn)
                    .await?;
                }
            }

            Ok(())
        };
        write.commit(value?).await
    }
}

impl SqliteProjectRepository {
    pub(crate) async fn list_in(
        conn: &mut sqlx::SqliteConnection,
    ) -> Result<Vec<Project>, AppError> {
        let mut projects: Vec<Project> = sqlx::query_as!(
            ProjectRow,
            "SELECT id, name, folder_id, created_at, updated_at FROM projects ORDER BY name COLLATE NOCASE"
        )
        .fetch_all(&mut *conn)
        .await?
        .into_iter()
        .map(Project::from)
        .collect();

        let values = sqlx::query_as!(
            ProjectValue,
            "SELECT project_id, field_id, value FROM project_metadata ORDER BY project_id, field_id"
        )
        .fetch_all(&mut *conn)
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

        Ok(projects)
    }
    pub(crate) async fn list_fields_in(
        conn: &mut sqlx::SqliteConnection,
    ) -> Result<Vec<MetadataField>, AppError> {
        let rows = sqlx::query_as!(
            FieldRow,
            "SELECT id, name, kind, options, created_at FROM metadata_fields ORDER BY created_at, id"
        )
        .fetch_all(&mut *conn)
        .await?;
        Ok(rows.into_iter().map(MetadataField::from).collect())
    }
}
