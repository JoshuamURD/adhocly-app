use async_trait::async_trait;
use sqlx::SqlitePool;

use crate::{
    error::AppError,
    sync::{SyncOperation, Write},
};

use super::model::{Task, TaskInput, ToggleResult};

/// Persistence for tasks. Inputs are expected to be validated by the caller.
///
/// Long queries live in `sql/tasks/` (`query_file!`); one-liners use the inline `query!` macros.
/// Both are checked against the migrated schema at compile time, so `DATABASE_URL` must point at
/// a migrated database when compiling — see the `db:schema` task in `mise.toml`.
#[async_trait]
pub(crate) trait TaskRepository: Send + Sync {
    /// Newest first.
    async fn list(&self) -> Result<Vec<Task>, AppError>;
    async fn get(&self, id: &str) -> Result<Task, AppError>;
    async fn create(&self, input: &TaskInput) -> Result<Task, AppError>;
    async fn update(&self, id: &str, input: &TaskInput) -> Result<Task, AppError>;
    /// Completing a repeating task creates its next occurrence in the same transaction.
    async fn toggle(
        &self,
        id: &str,
        completed: bool,
        next_id: Option<&str>,
    ) -> Result<ToggleResult, AppError>;
    async fn delete(&self, id: &str) -> Result<(), AppError>;
}

pub(crate) struct SqliteTaskRepository {
    db: SqlitePool,
    sync: Option<SyncOperation>,
}

impl SqliteTaskRepository {
    pub(crate) fn new(db: SqlitePool, sync: Option<SyncOperation>) -> Self {
        Self { db, sync }
    }

    async fn fetch<'e, E>(executor: E, id: &str) -> Result<Task, AppError>
    where
        E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
    {
        sqlx::query_file_as!(Task, "sql/tasks/select_one.sql", id)
            .fetch_optional(executor)
            .await?
            .ok_or(AppError::NotFound("task"))
    }
}

#[async_trait]
impl TaskRepository for SqliteTaskRepository {
    async fn list(&self) -> Result<Vec<Task>, AppError> {
        Self::list_in(&mut *self.db.acquire().await?).await
    }

    async fn get(&self, id: &str) -> Result<Task, AppError> {
        Self::fetch(&self.db, id).await
    }

    async fn create(&self, input: &TaskInput) -> Result<Task, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            sqlx::query_file!(
                "sql/tasks/insert.sql",
                &input.id,
                input.title.trim(),
                input.project_id.trim(),
                &input.planned_for,
                &input.due_on,
                input.repeat_weekday,
                input.completed
            )
            .execute(&mut *conn)
            .await?;

            Self::fetch(&mut *conn, &input.id).await
        };
        write.commit(value?).await
    }

    async fn update(&self, id: &str, input: &TaskInput) -> Result<Task, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            let result = sqlx::query_file!(
                "sql/tasks/update.sql",
                input.title.trim(),
                input.project_id.trim(),
                &input.planned_for,
                &input.due_on,
                input.repeat_weekday,
                input.completed,
                id
            )
            .execute(&mut *conn)
            .await?;

            if result.rows_affected() == 0 {
                return Err(AppError::NotFound("task"));
            }
            Self::fetch(&mut *conn, id).await
        };
        write.commit(value?).await
    }

    async fn toggle(
        &self,
        id: &str,
        completed: bool,
        next_id: Option<&str>,
    ) -> Result<ToggleResult, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            let current = Self::fetch(&mut *conn, id).await?;

            sqlx::query!(
            "UPDATE tasks SET completed = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            completed,
            id
        )
        .execute(&mut *conn)
        .await?;
            let task = Self::fetch(&mut *conn, id).await?;

            let next_task = if completed && current.repeat_weekday.is_some() {
                // One successor per occurrence, shared by every device (including browser clients).
                // ponytail: ids grow with each occurrence; use UUIDv5 if very long recurrence chains matter.
                let canonical = format!("next:{id}");
                if next_id.is_some_and(|value| value != canonical) {
                    return Err(AppError::Invalid(
                        "nextId must be the canonical successor id",
                    ));
                }
                let key = format!("tasks/{canonical}");
                let seen: bool =
                    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_versions WHERE key = ?)")
                        .bind(&key)
                        .fetch_one(&mut *conn)
                        .await?;
                // A deleted successor remains a tombstone: retries must not resurrect it.
                if !seen {
                    sqlx::query_file!("sql/tasks/insert_next_occurrence.sql", &canonical, id)
                        .execute(&mut *conn)
                        .await?;
                }
                sqlx::query_file_as!(Task, "sql/tasks/select_one.sql", &canonical)
                    .fetch_optional(&mut *conn)
                    .await?
            } else {
                None
            };

            Ok(ToggleResult { task, next_task })
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
            let result = sqlx::query!("DELETE FROM tasks WHERE id = ?", id)
                .execute(&mut *conn)
                .await?;
            if result.rows_affected() == 0 {
                return Err(AppError::NotFound("task"));
            }
            Ok(())
        };
        write.commit(value?).await
    }
}

impl SqliteTaskRepository {
    pub(crate) async fn list_in(conn: &mut sqlx::SqliteConnection) -> Result<Vec<Task>, AppError> {
        Ok(sqlx::query_file_as!(Task, "sql/tasks/select_all.sql")
            .fetch_all(&mut *conn)
            .await?)
    }
}
