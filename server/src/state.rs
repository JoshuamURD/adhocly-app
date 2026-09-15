use std::sync::Arc;

use sqlx::SqlitePool;

use crate::{
    folders::{FolderRepository, SqliteFolderRepository},
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
}

impl AppState {
    pub(crate) fn new(pool: SqlitePool) -> Self {
        Self {
            tasks: Arc::new(SqliteTaskRepository::new(pool.clone())),
            projects: Arc::new(SqliteProjectRepository::new(pool.clone())),
            folders: Arc::new(SqliteFolderRepository::new(pool.clone())),
            reminders: Arc::new(SqliteReminderRepository::new(pool.clone())),
            pool,
        }
    }

    /// Only the health check uses this; everything else goes through a repository.
    pub(crate) fn pool(&self) -> &SqlitePool {
        &self.pool
    }
}
