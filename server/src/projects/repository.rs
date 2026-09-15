use std::collections::HashMap;

use async_trait::async_trait;
use sqlx::{FromRow, SqlitePool};

use crate::error::AppError;

use super::model::{
    encode_options, normalize_options, validate_value, FieldKind, MetadataField,
    MetadataFieldInput, MetadataFieldUpdate, MetadataValue, Project,
};

#[derive(Debug, FromRow)]
struct ProjectRow {
    id: String,
    name: String,
    created_at: String,
    updated_at: String,
}

impl From<ProjectRow> for Project {
    fn from(row: ProjectRow) -> Self {
        Self::new(row.id, row.name, row.created_at, row.updated_at)
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
    async fn create(&self, name: &str) -> Result<Project, AppError>;
    async fn update(&self, id: &str, name: &str) -> Result<Project, AppError>;
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
}

impl SqliteProjectRepository {
    pub(crate) fn new(db: SqlitePool) -> Self {
        Self { db }
    }

    async fn project_or_404<'e, E>(executor: E, id: &str) -> Result<Project, AppError>
    where
        E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
    {
        sqlx::query_as::<_, ProjectRow>("SELECT * FROM projects WHERE id = ?")
            .bind(id)
            .fetch_optional(executor)
            .await?
            .map(Project::from)
            .ok_or(AppError::NotFound("project"))
    }

    async fn field_or_404<'e, E>(executor: E, id: &str) -> Result<MetadataField, AppError>
    where
        E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
    {
        let row = sqlx::query_as::<_, FieldRow>("SELECT * FROM metadata_fields WHERE id = ?")
            .bind(id)
            .fetch_optional(executor)
            .await?
            .ok_or(AppError::NotFound("field"))?;
        Ok(row.into())
    }

    async fn load_project(&self, id: &str) -> Result<Project, AppError> {
        let mut project = Self::project_or_404(&self.db, id).await?;
        project.metadata = sqlx::query_as::<_, MetadataValue>(
            "SELECT field_id, value FROM project_metadata WHERE project_id = ? ORDER BY field_id",
        )
        .bind(id)
        .fetch_all(&self.db)
        .await?;
        Ok(project)
    }
}

#[async_trait]
impl ProjectRepository for SqliteProjectRepository {
    async fn list(&self) -> Result<Vec<Project>, AppError> {
        let mut projects: Vec<Project> =
            sqlx::query_as::<_, ProjectRow>("SELECT * FROM projects ORDER BY name COLLATE NOCASE")
                .fetch_all(&self.db)
                .await?
                .into_iter()
                .map(Project::from)
                .collect();

        let values = sqlx::query_as::<_, ProjectValue>(
            "SELECT project_id, field_id, value FROM project_metadata ORDER BY project_id, field_id",
        )
        .fetch_all(&self.db)
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

    async fn get(&self, id: &str) -> Result<Project, AppError> {
        self.load_project(id).await
    }

    async fn create(&self, name: &str) -> Result<Project, AppError> {
        let saved = sqlx::query_as::<_, ProjectRow>(
            "INSERT INTO projects (id, name, created_at, updated_at)
             VALUES (?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
             RETURNING *",
        )
        .bind(uuid::Uuid::now_v7().to_string())
        .bind(name)
        .fetch_one(&self.db)
        .await?;
        Ok(saved.into())
    }

    async fn update(&self, id: &str, name: &str) -> Result<Project, AppError> {
        let result = sqlx::query(
            "UPDATE projects SET name = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
        )
        .bind(name)
        .bind(id)
        .execute(&self.db)
        .await?;
        if result.rows_affected() == 0 {
            return Err(AppError::NotFound("project"));
        }
        self.load_project(id).await
    }

    async fn delete(&self, id: &str) -> Result<(), AppError> {
        let mut transaction = self.db.begin().await?;
        sqlx::query("UPDATE tasks SET project_id = ? WHERE project_id = ?")
            .bind(super::model::INBOX_ID)
            .bind(id)
            .execute(&mut *transaction)
            .await?;
        let deleted = sqlx::query("DELETE FROM projects WHERE id = ?")
            .bind(id)
            .execute(&mut *transaction)
            .await?;
        if deleted.rows_affected() == 0 {
            return Err(AppError::NotFound("project"));
        }
        transaction.commit().await?;
        Ok(())
    }

    async fn list_fields(&self) -> Result<Vec<MetadataField>, AppError> {
        let rows =
            sqlx::query_as::<_, FieldRow>("SELECT * FROM metadata_fields ORDER BY created_at, id")
                .fetch_all(&self.db)
                .await?;
        Ok(rows.into_iter().map(MetadataField::from).collect())
    }

    async fn create_field(&self, input: &MetadataFieldInput) -> Result<MetadataField, AppError> {
        let options = normalize_options(input.kind, input.options.clone())?;
        let row = sqlx::query_as::<_, FieldRow>(
            "INSERT INTO metadata_fields (id, name, kind, options, created_at)
             VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
             RETURNING *",
        )
        .bind(uuid::Uuid::now_v7().to_string())
        .bind(input.name.trim())
        .bind(input.kind.as_str())
        .bind(encode_options(&options))
        .fetch_one(&self.db)
        .await?;
        Ok(row.into())
    }

    async fn update_field(
        &self,
        id: &str,
        input: &MetadataFieldUpdate,
    ) -> Result<MetadataField, AppError> {
        let existing = Self::field_or_404(&self.db, id).await?;
        let options = normalize_options(existing.kind, input.options.clone())?;
        let row = sqlx::query_as::<_, FieldRow>(
            "UPDATE metadata_fields SET name = ?, options = ? WHERE id = ? RETURNING *",
        )
        .bind(input.name.trim())
        .bind(encode_options(&options))
        .bind(id)
        .fetch_one(&self.db)
        .await?;
        Ok(row.into())
    }

    async fn delete_field(&self, id: &str) -> Result<(), AppError> {
        let result = sqlx::query("DELETE FROM metadata_fields WHERE id = ?")
            .bind(id)
            .execute(&self.db)
            .await?;
        if result.rows_affected() == 0 {
            return Err(AppError::NotFound("field"));
        }
        Ok(())
    }

    async fn set_value(
        &self,
        project_id: &str,
        field_id: &str,
        value: Option<String>,
    ) -> Result<(), AppError> {
        let field = Self::field_or_404(&self.db, field_id).await?;
        Self::project_or_404(&self.db, project_id).await?;

        match value {
            None => {
                sqlx::query("DELETE FROM project_metadata WHERE project_id = ? AND field_id = ?")
                    .bind(project_id)
                    .bind(field_id)
                    .execute(&self.db)
                    .await?;
            }
            Some(value) => {
                validate_value(field.kind, &field.options, &value)?;
                sqlx::query(
                    "INSERT INTO project_metadata (project_id, field_id, value) VALUES (?, ?, ?)
                     ON CONFLICT (project_id, field_id) DO UPDATE SET value = excluded.value",
                )
                .bind(project_id)
                .bind(field_id)
                .bind(value)
                .execute(&self.db)
                .await?;
            }
        }

        Ok(())
    }
}
