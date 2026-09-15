use async_trait::async_trait;
use sqlx::SqlitePool;

use crate::error::AppError;

use super::model::{Task, TaskInput, ToggleResult};

const SELECT_ONE: &str =
    "SELECT t.*, p.name AS project FROM tasks t JOIN projects p ON p.id = t.project_id WHERE t.id = ?";
const SELECT_ALL: &str = "SELECT t.*, p.name AS project FROM tasks t JOIN projects p ON p.id = t.project_id ORDER BY t.created_at DESC, t.id DESC";

/// Persistence for tasks. Inputs are expected to be validated by the caller.
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
        sqlx::query_as::<_, Task>(SELECT_ONE)
            .bind(id)
            .fetch_optional(executor)
            .await?
            .ok_or(AppError::NotFound("task"))
    }
}

#[async_trait]
impl TaskRepository for SqliteTaskRepository {
    async fn list(&self) -> Result<Vec<Task>, AppError> {
        Ok(sqlx::query_as::<_, Task>(SELECT_ALL)
            .fetch_all(&self.db)
            .await?)
    }

    async fn get(&self, id: &str) -> Result<Task, AppError> {
        Self::fetch(&self.db, id).await
    }

    async fn create(&self, input: &TaskInput) -> Result<Task, AppError> {
        sqlx::query(
            "INSERT INTO tasks (
                id, title, project_id, planned_for, due_on, repeat_weekday, created_at, updated_at, completed
             ) VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?)",
        )
        .bind(&input.id)
        .bind(input.title.trim())
        .bind(input.project_id.trim())
        .bind(&input.planned_for)
        .bind(&input.due_on)
        .bind(input.repeat_weekday)
        .bind(input.completed)
        .execute(&self.db)
        .await?;

        Self::fetch(&self.db, &input.id).await
    }

    async fn update(&self, id: &str, input: &TaskInput) -> Result<Task, AppError> {
        let result = sqlx::query(
            "UPDATE tasks SET
                title = ?, project_id = ?, planned_for = ?, due_on = ?, repeat_weekday = ?,
                completed = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
             WHERE id = ?",
        )
        .bind(input.title.trim())
        .bind(input.project_id.trim())
        .bind(&input.planned_for)
        .bind(&input.due_on)
        .bind(input.repeat_weekday)
        .bind(input.completed)
        .bind(id)
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

        sqlx::query(
            "UPDATE tasks SET completed = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
        )
        .bind(completed)
        .bind(id)
        .execute(&mut *transaction)
        .await?;
        let task = Self::fetch(&mut *transaction, id).await?;

        let next_task = if !current.completed && completed && current.repeat_weekday.is_some() {
            let next_id = uuid::Uuid::now_v7().to_string();
            sqlx::query(
                "INSERT INTO tasks (
                    id, title, project_id, planned_for, due_on, repeat_weekday, created_at, updated_at, completed
                 ) SELECT ?, title, project_id,
                    CASE WHEN planned_for IS NULL THEN NULL ELSE date(planned_for, '+7 days') END,
                    CASE WHEN due_on IS NULL THEN NULL ELSE date(due_on, '+7 days') END,
                    repeat_weekday, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 0
                 FROM tasks WHERE id = ?",
            )
            .bind(&next_id)
            .bind(id)
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
        let result = sqlx::query("DELETE FROM tasks WHERE id = ?")
            .bind(id)
            .execute(&self.db)
            .await?;
        if result.rows_affected() == 0 {
            return Err(AppError::NotFound("task"));
        }
        Ok(())
    }
}
