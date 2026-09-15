use async_trait::async_trait;
use sqlx::SqlitePool;

use crate::error::AppError;

use super::model::Folder;

/// Persistence for the folder tree. Names are expected to be validated by the caller.
#[async_trait]
pub(crate) trait FolderRepository: Send + Sync {
    async fn list(&self) -> Result<Vec<Folder>, AppError>;
    /// The parent, when given, must exist.
    async fn create(&self, name: &str, parent_id: Option<&str>) -> Result<Folder, AppError>;
    /// Renames and moves in one update. A folder may not move inside its own subtree.
    async fn update(&self, id: &str, name: &str, parent_id: Option<&str>) -> Result<Folder, AppError>;
    /// Deletes the folder after handing its projects and subfolders to its parent.
    async fn delete(&self, id: &str) -> Result<(), AppError>;
}

pub(crate) struct SqliteFolderRepository {
    db: SqlitePool,
}

impl SqliteFolderRepository {
    pub(crate) fn new(db: SqlitePool) -> Self {
        Self { db }
    }

    async fn folder_or_404(&self, id: &str) -> Result<Folder, AppError> {
        // Every write reads its row back through here: SQLite echoes a NULL bind in a
        // `RETURNING` clause as an empty string, which would report `parentId: ""`.
        sqlx::query_as!(
            Folder,
            "SELECT id, name, parent_id, created_at, updated_at FROM folders WHERE id = ?",
            id
        )
        .fetch_optional(&self.db)
        .await?
        .ok_or(AppError::NotFound("folder"))
    }

    async fn parent_or_404(&self, parent_id: Option<&str>) -> Result<(), AppError> {
        match parent_id {
            Some(parent_id) => self.folder_or_404(parent_id).await.map(|_| ()),
            None => Ok(()),
        }
    }

    /// Walks up from the new parent; reaching `id` means the move would close a loop.
    async fn check_not_inside_itself(
        &self,
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
        .fetch_one(&self.db)
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
        Ok(sqlx::query_as!(
            Folder,
            "SELECT id, name, parent_id, created_at, updated_at FROM folders
             ORDER BY name COLLATE NOCASE"
        )
        .fetch_all(&self.db)
        .await?)
    }

    async fn create(&self, name: &str, parent_id: Option<&str>) -> Result<Folder, AppError> {
        self.parent_or_404(parent_id).await?;
        let id = uuid::Uuid::now_v7().to_string();
        sqlx::query!(
            "INSERT INTO folders (id, name, parent_id, created_at, updated_at)
             VALUES (?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))",
            id,
            name,
            parent_id
        )
        .execute(&self.db)
        .await?;
        self.folder_or_404(&id).await
    }

    async fn update(
        &self,
        id: &str,
        name: &str,
        parent_id: Option<&str>,
    ) -> Result<Folder, AppError> {
        self.folder_or_404(id).await?;
        self.parent_or_404(parent_id).await?;
        self.check_not_inside_itself(id, parent_id).await?;

        sqlx::query!(
            "UPDATE folders
             SET name = ?, parent_id = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
             WHERE id = ?",
            name,
            parent_id,
            id
        )
        .execute(&self.db)
        .await?;
        self.folder_or_404(id).await
    }

    async fn delete(&self, id: &str) -> Result<(), AppError> {
        let parent_id = self.folder_or_404(id).await?.parent_id;
        let mut transaction = self.db.begin().await?;
        sqlx::query!(
            "UPDATE folders SET parent_id = ? WHERE parent_id = ?",
            parent_id,
            id
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query!(
            "UPDATE projects SET folder_id = ? WHERE folder_id = ?",
            parent_id,
            id
        )
        .execute(&mut *transaction)
        .await?;
        sqlx::query!("DELETE FROM folders WHERE id = ?", id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(())
    }
}
