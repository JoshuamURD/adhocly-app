use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use utoipa::ToSchema;

#[derive(Debug, Serialize, ToSchema, FromRow)]
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
pub(crate) struct ToggleInput {
    pub(crate) completed: bool,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ToggleResult {
    pub(crate) task: Task,
    pub(crate) next_task: Option<Task>,
}
