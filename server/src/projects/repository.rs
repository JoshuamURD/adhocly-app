use async_trait::async_trait;
use sqlx::{FromRow, SqlitePool};

use crate::{
    error::AppError,
    sync::{SyncOperation, Write},
};

use super::model::Project;

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

/// Persistence for projects. Names are validated by the caller.
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
}

pub(crate) struct SqliteProjectRepository {
    db: SqlitePool,
    sync: Option<SyncOperation>,
}

impl SqliteProjectRepository {
    pub(crate) fn new(db: SqlitePool, sync: Option<SyncOperation>) -> Self {
        Self { db, sync }
    }

    // Read back after writes: SQLite RETURNING can decode a NULL folder_id as an empty string.
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

}

#[async_trait]
impl ProjectRepository for SqliteProjectRepository {
    async fn list(&self) -> Result<Vec<Project>, AppError> {
        Self::list_in(&mut *self.db.acquire().await?).await
    }

    async fn get(&self, id: &str) -> Result<Project, AppError> {
        Self::project_or_404(&mut *self.db.acquire().await?, id).await
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
            Self::project_or_404(&mut *conn, &id).await
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
            Self::project_or_404(&mut *conn, id).await
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
            Self::project_or_404(&mut *conn, id).await
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
}

impl SqliteProjectRepository {
    pub(crate) async fn list_in(
        conn: &mut sqlx::SqliteConnection,
    ) -> Result<Vec<Project>, AppError> {
        let projects: Vec<Project> = sqlx::query_as!(
            ProjectRow,
            "SELECT id, name, folder_id, created_at, updated_at FROM projects ORDER BY name COLLATE NOCASE"
        )
        .fetch_all(&mut *conn)
        .await?
        .into_iter()
        .map(Project::from)
        .collect();

        Ok(projects)
    }
}
