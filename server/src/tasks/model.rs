use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use utoipa::ToSchema;

#[derive(Debug, Serialize, Deserialize, ToSchema, FromRow)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Task {
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) project_id: String,
    /// Name of the owning project, joined for display.
    pub(crate) project: String,
    /// Local wall-clock date and time, `YYYY-MM-DDTHH:MM`.
    pub(crate) planned_for: Option<String>,
    /// Local wall-clock date and time, `YYYY-MM-DDTHH:MM`.
    pub(crate) due_on: Option<String>,
    pub(crate) repeat_weekday: Option<i64>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) completed: bool,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TaskInput {
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) project_id: String,
    /// Local wall-clock date and time, `YYYY-MM-DDTHH:MM`.
    pub(crate) planned_for: Option<String>,
    /// Local wall-clock date and time, `YYYY-MM-DDTHH:MM`.
    pub(crate) due_on: Option<String>,
    pub(crate) repeat_weekday: Option<i64>,
    pub(crate) completed: bool,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ToggleInput {
    pub(crate) completed: bool,
    /// If supplied, must equal `next:{taskId}`; all clients share one successor.
    pub(crate) next_id: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ToggleResult {
    pub(crate) task: Task,
    pub(crate) next_task: Option<Task>,
}
