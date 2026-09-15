use async_trait::async_trait;
use sqlx::{FromRow, SqlitePool};

use crate::error::AppError;

use super::model::Reminder;

#[derive(Debug, FromRow)]
struct ReminderRow {
    remind_at: String,
    task_id: String,
}

impl From<ReminderRow> for Reminder {
    fn from(row: ReminderRow) -> Self {
        Self {
            remind_at: row.remind_at,
            task_id: row.task_id,
        }
    }
}

#[async_trait]
pub(crate) trait ReminderRepository: Send + Sync {
    async fn get(&self, id: &str) -> Result<Reminder, AppError>;
}

pub(crate) struct SqliteReminderRepository {
    db: SqlitePool,
}

impl SqliteReminderRepository {
    pub(crate) fn new(db: SqlitePool) -> Self {
        Self { db }
    }
}

#[async_trait]
impl ReminderRepository for SqliteReminderRepository {
    async fn get(&self, id: &str) -> Result<Reminder, AppError> {
        sqlx::query_as!(
            ReminderRow,
            "SELECT remind_at, task_id FROM task_reminders WHERE id = ?",
            id
        )
        .fetch_optional(&self.db)
        .await?
        .map(Reminder::from)
        .ok_or(AppError::NotFound("reminder"))
    }
}
