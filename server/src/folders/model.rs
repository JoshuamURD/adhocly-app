use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use utoipa::ToSchema;

#[derive(Debug, Serialize, Deserialize, ToSchema, FromRow)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Folder {
    pub(crate) id: String,
    pub(crate) name: String,
    /// `None` is the top level; folders nest to any depth.
    pub(crate) parent_id: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct FolderInput {
    /// Optional client-selected entity id; sync uses a separate mutation id for safe replay.
    pub(crate) id: Option<String>,
    pub(crate) name: String,
    /// Omitted or null creates/moves the folder at the top level.
    pub(crate) parent_id: Option<String>,
}
