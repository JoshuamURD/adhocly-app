use std::sync::Arc;

use sqlx::SqlitePool;

use crate::{
    folders::{FolderRepository, SqliteFolderRepository},
    kanban::KanbanRepository,
    projects::{ProjectRepository, SqliteProjectRepository},
    reminders::{ReminderRepository, SqliteReminderRepository},
    tasks::{SqliteTaskRepository, TaskRepository},
};

/// Shared handler state. Handlers only ever see the repository traits, never SQL.
#[derive(Clone)]
pub(crate) struct AppState {
    pool: SqlitePool,
    pub(crate) tasks: Arc<dyn TaskRepository>,
    pub(crate) projects: Arc<dyn ProjectRepository>,
    pub(crate) folders: Arc<dyn FolderRepository>,
    pub(crate) reminders: Arc<dyn ReminderRepository>,
    pub(crate) kanban: KanbanRepository,
}

impl AppState {
    pub(crate) fn new(pool: SqlitePool) -> Self {
        Self::with_sync(pool, None)
    }

    pub(crate) fn with_sync(pool: SqlitePool, sync: Option<crate::sync::SyncOperation>) -> Self {
        Self {
            tasks: Arc::new(SqliteTaskRepository::new(pool.clone(), sync.clone())),
            projects: Arc::new(SqliteProjectRepository::new(pool.clone(), sync.clone())),
            folders: Arc::new(SqliteFolderRepository::new(pool.clone(), sync.clone())),
            kanban: KanbanRepository::new(pool.clone(), sync),
            reminders: Arc::new(SqliteReminderRepository::new(pool.clone())),
            pool,
        }
    }

    /// Health and sync use the pool for consistent snapshots and durable receipts.
    pub(crate) fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}
