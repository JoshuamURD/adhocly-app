use serde::Serialize;
use utoipa::ToSchema;

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Reminder {
    pub(crate) remind_at: String,
    pub(crate) task_id: String,
}
