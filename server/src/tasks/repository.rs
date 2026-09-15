use async_trait::async_trait;
use sqlx::SqlitePool;

use crate::error::AppError;

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
    async fn toggle(&self, id: &str, completed: bool) -> Result<ToggleResult, AppError>;
    async fn delete(&self, id: &str) -> Result<(), AppError>;
}

pub(crate) struct SqliteTaskRepository {
    db: SqlitePool,
}

impl SqliteTaskRepository {
    pub(crate) fn new(db: SqlitePool) -> Self {
        Self { db }
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
        Ok(sqlx::query_file_as!(Task, "sql/tasks/select_all.sql")
            .fetch_all(&self.db)
            .await?)
    }

    async fn get(&self, id: &str) -> Result<Task, AppError> {
        Self::fetch(&self.db, id).await
    }

    async fn create(&self, input: &TaskInput) -> Result<Task, AppError> {
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
        .execute(&self.db)
        .await?;

        Self::fetch(&self.db, &input.id).await
    }

    async fn update(&self, id: &str, input: &TaskInput) -> Result<Task, AppError> {
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
        .execute(&self.db)
        .await?;

        if result.rows_affected() == 0 {
            return Err(AppError::NotFound("task"));
        }
        Self::fetch(&self.db, id).await
    }

    async fn toggle(&self, id: &str, completed: bool) -> Result<ToggleResult, AppError> {
        let mut transaction = self.db.begin().await?;
        let current = Self::fetch(&mut *transaction, id).await?;

        sqlx::query!(
            "UPDATE tasks SET completed = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            completed,
            id
        )
        .execute(&mut *transaction)
        .await?;
        let task = Self::fetch(&mut *transaction, id).await?;

        let next_task = if !current.completed && completed && current.repeat_weekday.is_some() {
            let next_id = uuid::Uuid::now_v7().to_string();
            sqlx::query_file!("sql/tasks/insert_next_occurrence.sql", &next_id, id)
                .execute(&mut *transaction)
                .await?;
            Some(Self::fetch(&mut *transaction, &next_id).await?)
        } else {
            None
        };

        transaction.commit().await?;
        Ok(ToggleResult { task, next_task })
    }

    async fn delete(&self, id: &str) -> Result<(), AppError> {
        let result = sqlx::query!("DELETE FROM tasks WHERE id = ?", id)
            .execute(&self.db)
            .await?;
        if result.rows_affected() == 0 {
            return Err(AppError::NotFound("task"));
        }
        Ok(())
    }
}
