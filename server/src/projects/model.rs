use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

/// Seeded by migration 0002; the fallback home for tasks whose project is deleted.
pub(crate) const INBOX_ID: &str = "inbox";

#[derive(Debug, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Project {
    pub(crate) id: String,
    pub(crate) name: String,
    /// `None` means the project sits at the top level of the sidebar.
    pub(crate) folder_id: Option<String>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
}

impl Project {
    pub(crate) fn new(
        id: String,
        name: String,
        folder_id: Option<String>,
        created_at: String,
        updated_at: String,
    ) -> Self {
        Self {
            id,
            name,
            folder_id,
            created_at,
            updated_at,
        }
    }
}

#[derive(Debug, Deserialize, ToSchema)]
pub(crate) struct ProjectInput {
    /// Optional client-selected entity id; sync uses a separate mutation id for safe replay.
    pub(crate) id: Option<String>,
    pub(crate) name: String,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ProjectFolderInput {
    /// Omitted or null files the project at the top level.
    pub(crate) folder_id: Option<String>,
}
