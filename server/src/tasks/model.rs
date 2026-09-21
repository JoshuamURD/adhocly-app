use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use std::collections::BTreeMap;
use utoipa::ToSchema;

#[derive(Debug, Serialize, Deserialize, ToSchema, FromRow)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Task {
    pub(crate) id: String,
    pub(crate) title: String,
    #[serde(default)]
    pub(crate) details: String,
    pub(crate) project_id: String,
    pub(crate) project: String,
    /// Local wall-clock date and time, `YYYY-MM-DDTHH:MM`.
    pub(crate) planned_for: Option<String>,
    /// Local wall-clock date and time, `YYYY-MM-DDTHH:MM`.
    pub(crate) due_on: Option<String>,
    pub(crate) repeat_weekday: Option<i64>,
    pub(crate) created_at: String,
    pub(crate) updated_at: String,
    pub(crate) completed: bool,
    #[serde(default = "default_status")]
    pub(crate) status_id: String,
    #[serde(default)]
    #[schema(value_type = BTreeMap<String, String>)]
    pub(crate) properties: sqlx::types::Json<BTreeMap<String, String>>,
    #[serde(default)]
    #[schema(value_type = Vec<CustomReminder>)]
    pub(crate) reminders: sqlx::types::Json<Vec<CustomReminder>>,
}

#[derive(Clone, Debug, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CustomReminder {
    pub(crate) id: String,
    pub(crate) kind: ReminderKind,
    /// Local wall-clock time; required only for custom-date reminders.
    pub(crate) at: Option<String>,
    /// Legacy presets; omit when using offsetUnit and offsetValue.
    pub(crate) offset_minutes: Option<i64>,
    pub(crate) offset_unit: Option<ReminderUnit>,
    /// Whole units before the anchor, from 1 through 999.
    pub(crate) offset_value: Option<i64>,
    #[serde(default)]
    pub(crate) urgent: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ReminderKind {
    Custom,
    Planned,
    Due,
}

#[derive(Clone, Debug, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ReminderUnit {
    Minutes,
    Hours,
    Days,
    Weeks,
    Months,
}

fn default_status() -> String {
    "todo".into()
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TaskInput {
    pub(crate) id: String,
    pub(crate) title: String,
    /// Omission preserves details; an empty string clears them.
    pub(crate) details: Option<String>,
    pub(crate) project_id: String,
    /// Local wall-clock date and time, `YYYY-MM-DDTHH:MM`.
    pub(crate) planned_for: Option<String>,
    /// Local wall-clock date and time, `YYYY-MM-DDTHH:MM`.
    pub(crate) due_on: Option<String>,
    pub(crate) repeat_weekday: Option<i64>,
    pub(crate) completed: bool,
    /// Omission preserves an existing non-complete status on updates from older clients.
    pub(crate) status_id: Option<String>,
    /// Omission preserves existing properties. An empty map explicitly clears them.
    pub(crate) properties: Option<BTreeMap<String, String>>,
    /// Omission preserves reminders; an empty list removes all custom reminders.
    pub(crate) reminders: Option<Vec<CustomReminder>>,
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
