use async_trait::async_trait;
use sqlx::SqlitePool;

use crate::{
    error::AppError,
    sync::{SyncOperation, Write},
};

use super::model::Folder;

/// Persistence for the folder tree. Names are expected to be validated by the caller.
#[async_trait]
pub(crate) trait FolderRepository: Send + Sync {
    async fn list(&self) -> Result<Vec<Folder>, AppError>;
    /// The parent, when given, must exist.
    async fn create(
        &self,
        id: Option<&str>,
        name: &str,
        parent_id: Option<&str>,
    ) -> Result<Folder, AppError>;
    /// Renames and moves in one update. A folder may not move inside its own subtree.
    async fn update(
        &self,
        id: &str,
        name: &str,
        parent_id: Option<&str>,
    ) -> Result<Folder, AppError>;
    /// Deletes the folder after handing its projects and subfolders to its parent.
    async fn delete(&self, id: &str) -> Result<(), AppError>;
}

pub(crate) struct SqliteFolderRepository {
    db: SqlitePool,
    sync: Option<SyncOperation>,
}

impl SqliteFolderRepository {
    pub(crate) fn new(db: SqlitePool, sync: Option<SyncOperation>) -> Self {
        Self { db, sync }
    }

    async fn folder_or_404(
        conn: &mut sqlx::SqliteConnection,
        id: &str,
    ) -> Result<Folder, AppError> {
        // Every write reads its row back through here: SQLite echoes a NULL bind in a
        // `RETURNING` clause as an empty string, which would report `parentId: ""`.
        sqlx::query_as!(
            Folder,
            "SELECT id, name, parent_id, created_at, updated_at FROM folders WHERE id = ?",
            id
        )
        .fetch_optional(&mut *conn)
        .await?
        .ok_or(AppError::NotFound("folder"))
    }

    async fn parent_or_404(
        conn: &mut sqlx::SqliteConnection,
        parent_id: Option<&str>,
    ) -> Result<(), AppError> {
        match parent_id {
            Some(parent_id) => Self::folder_or_404(&mut *conn, parent_id).await.map(|_| ()),
            None => Ok(()),
        }
    }

    /// Walks up from the new parent; reaching `id` means the move would close a loop.
    async fn check_not_inside_itself(
        conn: &mut sqlx::SqliteConnection,
        id: &str,
        parent_id: Option<&str>,
    ) -> Result<(), AppError> {
        let Some(parent_id) = parent_id else {
            return Ok(());
        };
        // UNION, not UNION ALL: a loop already in the data must not hang the walk.
        let looped = sqlx::query_scalar::<_, i64>(
            "WITH RECURSIVE chain(id) AS (
                 SELECT id FROM folders WHERE id = ?
                 UNION
                 SELECT f.parent_id FROM folders f JOIN chain ON f.id = chain.id
                 WHERE f.parent_id IS NOT NULL
             )
             SELECT EXISTS (SELECT 1 FROM chain WHERE id = ?)",
        )
        .bind(parent_id)
        .bind(id)
        .fetch_one(&mut *conn)
        .await?;

        if looped == 1 {
            return Err(AppError::Invalid("a folder cannot move inside itself"));
        }
        Ok(())
    }
}

#[async_trait]
impl FolderRepository for SqliteFolderRepository {
    async fn list(&self) -> Result<Vec<Folder>, AppError> {
        Self::list_in(&mut *self.db.acquire().await?).await
    }

    async fn create(
        &self,
        id: Option<&str>,
        name: &str,
        parent_id: Option<&str>,
    ) -> Result<Folder, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            Self::parent_or_404(&mut *conn, parent_id).await?;
            let id = id
                .map(str::to_owned)
                .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
            sqlx::query!(
            "INSERT INTO folders (id, name, parent_id, created_at, updated_at)
             VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            id,
            name,
            parent_id
        )
        .execute(&mut *conn)
        .await?;
            Self::folder_or_404(&mut *conn, &id).await
        };
        write.commit(value?).await
    }

    async fn update(
        &self,
        id: &str,
        name: &str,
        parent_id: Option<&str>,
    ) -> Result<Folder, AppError> {
        let mut write = Write::begin(&self.db, self.sync.as_ref()).await?;
        if let Some(value) = write.replay()? {
            return Ok(value);
        }
        let conn = &mut *write.transaction;
        let value: Result<_, AppError> = {
            Self::folder_or_404(&mut *conn, id).await?;
            Self::parent_or_404(&mut *conn, parent_id).await?;
            Self::check_not_inside_itself(&mut *conn, id, parent_id).await?;

            sqlx::query!(
                "UPDATE folders
             SET name = ?, parent_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
             WHERE id = ?",
                name,
                parent_id,
                id
            )
            .execute(&mut *conn)
            .await?;
            Self::folder_or_404(&mut *conn, id).await
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
            let parent_id = Self::folder_or_404(&mut *conn, id).await?.parent_id;
            sqlx::query!(
                "UPDATE folders SET parent_id = ? WHERE parent_id = ?",
                parent_id,
                id
            )
            .execute(&mut *conn)
            .await?;
            sqlx::query!(
                "UPDATE projects SET folder_id = ? WHERE folder_id = ?",
                parent_id,
                id
            )
            .execute(&mut *conn)
            .await?;
            sqlx::query!("DELETE FROM folders WHERE id = ?", id)
                .execute(&mut *conn)
                .await?;
            Ok(())
        };
        write.commit(value?).await
    }
}

impl SqliteFolderRepository {
    pub(crate) async fn list_in(
        conn: &mut sqlx::SqliteConnection,
    ) -> Result<Vec<Folder>, AppError> {
        Ok(sqlx::query_as!(
            Folder,
            "SELECT id, name, parent_id, created_at, updated_at FROM folders
             ORDER BY name COLLATE NOCASE"
        )
        .fetch_all(&mut *conn)
        .await?)
    }
}
