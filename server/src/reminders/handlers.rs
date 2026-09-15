use axum::{
    extract::{Path, State},
    Json,
};

use crate::{error::AppError, state::AppState};

use super::model::Reminder;

#[utoipa::path(
    get,
    path = "/api/reminders/{id}",
    operation_id = "getReminder",
    params(("id" = String, Path, description = "Reminder id")),
    responses(
        (status = 200, description = "Reminder", body = Reminder),
        (status = 404, description = "Reminder not found", body = String),
    ),
    tag = "reminders"
)]
pub(crate) async fn get_reminder(
    Path(id): Path<String>,
    State(state): State<AppState>,
) -> std::result::Result<Json<Reminder>, AppError> {
    Ok(Json(state.reminders.get(&id).await?))
}
