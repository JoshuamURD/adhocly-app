use async_trait::async_trait;
use sqlx::SqlitePool;

use crate::{
    error::AppError,
    kanban::validate_task_values,
    sync::{SyncOperation, Write},
};

use super::model::{CustomReminder, ReminderKind, Task, TaskInput, ToggleResult};

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
        let (status, properties) = Self::values(conn, input, None).await?;
        let properties = serde_json::to_string(&properties)?;
        let reminders = Self::reminders(conn, input.reminders.as_deref().unwrap_or(&[])).await?;
        sqlx::query_file!(
            "sql/tasks/insert.sql",
            &input.id,
            input.title.trim(),
            input.details.as_deref().unwrap_or(""),
            input.project_id.trim(),
            &input.planned_for,
            &input.due_on,
            input.repeat_weekday,
            input.completed,
            status,
            properties,
            reminders
        )
        .execute(&mut *conn)
        .await?;
        let task = Self::fetch(&mut *conn, &input.id).await?;
        Self::successor(conn, &task, None).await?;
        write.commit(task).await
    }

    async fn update(&self, id: &str, input: &TaskInput) -> Result<Task, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let current = Self::fetch(&mut *conn, id).await?;
        let (status, properties) = Self::values(conn, input, Some(&current)).await?;
        let properties = serde_json::to_string(&properties)?;
        let reminders = Self::reminders(conn, input.reminders.as_deref().unwrap_or(&current.reminders)).await?;
        sqlx::query_file!(
            "sql/tasks/update.sql",
            input.title.trim(),
            input.details.as_deref().unwrap_or(&current.details),
            input.project_id.trim(),
            &input.planned_for,
            &input.due_on,
            input.repeat_weekday,
            input.completed,
            status,
            properties,
            reminders,
            id
        )
        .execute(&mut *conn)
        .await?;
        let task = Self::fetch(&mut *conn, id).await?;
        if !current.completed {
            Self::successor(conn, &task, None).await?;
        }
        write.commit(task).await
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
        let current = Self::fetch(&mut *conn, id).await?;
        let status = if completed {
            "complete"
        } else if current.completed {
            "todo"
        } else {
            &current.status_id
        };
        sqlx::query!(
            "UPDATE tasks SET completed = ?, status_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
            completed, status, id
        ).execute(&mut *conn).await?;
        let task = Self::fetch(&mut *conn, id).await?;
        let next_task = Self::successor(conn, &task, next_id).await?;
        write.commit(ToggleResult { task, next_task }).await
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
    async fn reminders(
        conn: &mut sqlx::SqliteConnection,
        reminders: &[CustomReminder],
    ) -> Result<String, AppError> {
        let mut ids = std::collections::HashSet::new();
        if reminders.len() > 64 {
            return Err(AppError::Invalid("at most 64 custom reminders per task"));
        }
        for reminder in reminders {
            if reminder.id.trim().is_empty() || reminder.id.len() > 128 || !ids.insert(&reminder.id) {
                return Err(AppError::Invalid("reminder ids must be nonempty and unique"));
            }
            if reminder.kind == ReminderKind::Custom {
                let at = reminder.at.as_deref().unwrap_or("");
                // SQLite normalizes impossible dates; require an exact wall-clock round trip.
                let normalized: Option<String> = sqlx::query_scalar("SELECT strftime('%Y-%m-%dT%H:%M', ?)")
                    .bind(at).fetch_one(&mut *conn).await?;
                if at.len() != 16
                    || reminder.offset_minutes.is_some()
                    || reminder.offset_unit.is_some()
                    || reminder.offset_value.is_some()
                    || normalized.as_deref() != Some(at)
                {
                    return Err(AppError::Invalid("custom reminders need a valid YYYY-MM-DDTHH:MM date and no offset"));
                }
            } else {
                let valid_offset = matches!(
                    (&reminder.offset_unit, reminder.offset_value, reminder.offset_minutes),
                    (Some(_), Some(1..=999), None)
                        | (None, None, Some(5 | 15 | 30 | 60 | 120 | 1440 | 2880 | 10080))
                );
                if reminder.at.is_some() || !valid_offset {
                    return Err(AppError::Invalid("relative reminders need a unit and amount from 1 to 999 (or a legacy preset), and no fixed date"));
                }
            }
        }
        Ok(serde_json::to_string(reminders)?)
    }

    async fn values(
        conn: &mut sqlx::SqliteConnection,
        input: &TaskInput,
        current: Option<&Task>,
    ) -> Result<(String, std::collections::BTreeMap<String, String>), AppError> {
        let fallback = if input.completed {
            "complete"
        } else {
            current
                .filter(|task| !task.completed)
                .map(|task| task.status_id.as_str())
                .unwrap_or("todo")
        };
        let status = input.status_id.as_deref().unwrap_or(fallback);
        if input.completed != (status == "complete") {
            return Err(AppError::Invalid("statusId and completed must agree"));
        }
        let mut properties = input.properties.clone().unwrap_or_else(|| {
            current
                .map(|task| task.properties.0.clone())
                .unwrap_or_default()
        });
        properties.retain(|_, value| !value.trim().is_empty());
        validate_task_values(conn, status, &properties).await?;
        Ok((status.to_owned(), properties))
    }

    /// One completion path for checkbox toggles, Kanban moves and ordinary API updates.
    async fn successor(
        conn: &mut sqlx::SqliteConnection,
        task: &Task,
        next_id: Option<&str>,
    ) -> Result<Option<Task>, AppError> {
        if !task.completed || task.repeat_weekday.is_none() {
            return Ok(None);
        }
        // ponytail: ids grow with each occurrence; use UUIDv5 if very long chains matter.
        let canonical = format!("next:{}", task.id);
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
        // Tombstones prevent a retry or re-completion from resurrecting deleted successors.
        if !seen {
            sqlx::query_file!("sql/tasks/insert_next_occurrence.sql", &canonical, &task.id)
                .execute(&mut *conn)
                .await?;
            sqlx::query("INSERT INTO context_links (id, data, task_id) SELECT 'tasks:' || ?, json_set(data, '$.id', 'tasks:' || ?), ? FROM context_links WHERE task_id = ?")
                .bind(&canonical).bind(&canonical).bind(&canonical).bind(&task.id)
                .execute(&mut *conn).await?;
        }
        Ok(
            sqlx::query_file_as!(Task, "sql/tasks/select_one.sql", &canonical)
                .fetch_optional(conn)
                .await?,
        )
    }

    pub(crate) async fn list_in(conn: &mut sqlx::SqliteConnection) -> Result<Vec<Task>, AppError> {
        Ok(sqlx::query_file_as!(Task, "sql/tasks/select_all.sql")
            .fetch_all(&mut *conn)
            .await?)
    }
}
