use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::{FromRow, SqlitePool};
use utoipa::ToSchema;

use crate::error::AppError;

const TASK_SELECT_ONE: &str =
    "SELECT t.*, p.name AS project FROM tasks t JOIN projects p ON p.id = t.project_id WHERE t.id = ?";
const TASK_SELECT_ALL: &str = "SELECT t.*, p.name AS project FROM tasks t JOIN projects p ON p.id = t.project_id ORDER BY t.created_at DESC, t.id DESC";

#[derive(Debug, Serialize, ToSchema, FromRow)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Task {
    id: String,
    title: String,
    project_id: String,
    /// Name of the owning project, joined for display.
    project: String,
    planned_for: Option<String>,
    due_on: Option<String>,
    repeat_weekday: Option<i64>,
    created_at: String,
    updated_at: String,
    completed: bool,
}

#[derive(Debug, Deserialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TaskInput {
    id: String,
    title: String,
    project_id: String,
    planned_for: Option<String>,
    due_on: Option<String>,
    repeat_weekday: Option<i64>,
    completed: bool,
}

#[derive(Debug, Deserialize, ToSchema)]
pub(crate) struct ToggleInput {
    completed: bool,
}

#[derive(Debug, Serialize, ToSchema)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ToggleResult {
    task: Task,
    next_task: Option<Task>,
}

fn validate_task(task: &TaskInput) -> std::result::Result<(), AppError> {
    if task.id.trim().is_empty() {
        return Err(AppError::Invalid("id is required"));
    }
    if task.title.trim().is_empty() {
        return Err(AppError::Invalid("title is required"));
    }
    if task.project_id.trim().is_empty() {
        return Err(AppError::Invalid("projectId is required"));
    }
    if !matches!(task.repeat_weekday, None | Some(0..=6)) {
        return Err(AppError::Invalid("repeatWeekday must be between 0 and 6"));
    }
    Ok(())
}

async fn fetch_task<'e, E>(db: E, id: &str) -> std::result::Result<Task, AppError>
where
    E: sqlx::Executor<'e, Database = sqlx::Sqlite>,
{
    sqlx::query_as::<_, Task>(TASK_SELECT_ONE)
        .bind(id)
        .fetch_optional(db)
        .await?
        .ok_or(AppError::NotFound("task"))
}

#[utoipa::path(
    get,
    path = "/api/tasks",
    operation_id = "listTasks",
    responses((status = 200, description = "Tasks ordered newest first", body = [Task])),
    tag = "tasks"
)]
pub(crate) async fn list_tasks(
    State(db): State<SqlitePool>,
) -> std::result::Result<Json<Vec<Task>>, AppError> {
    let tasks = sqlx::query_as::<_, Task>(TASK_SELECT_ALL)
        .fetch_all(&db)
        .await?;
    Ok(Json(tasks))
}

#[utoipa::path(
    get,
    path = "/api/tasks/{id}",
    operation_id = "getTask",
    params(("id" = String, Path, description = "Task id")),
    responses(
        (status = 200, description = "Task", body = Task),
        (status = 404, description = "Task not found", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn get_task(
    Path(id): Path<String>,
    State(db): State<SqlitePool>,
) -> std::result::Result<Json<Task>, AppError> {
    Ok(Json(fetch_task(&db, &id).await?))
}

#[utoipa::path(
    post,
    path = "/api/tasks",
    operation_id = "createTask",
    request_body = TaskInput,
    responses(
        (status = 201, description = "Created task", body = Task),
        (status = 400, description = "Invalid task", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn create_task(
    State(db): State<SqlitePool>,
    Json(task): Json<TaskInput>,
) -> std::result::Result<(StatusCode, Json<Task>), AppError> {
    validate_task(&task)?;
    sqlx::query(
        "INSERT INTO tasks (
            id, title, project_id, planned_for, due_on, repeat_weekday, created_at, updated_at, completed
         ) VALUES (?, ?, ?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), ?)",
    )
    .bind(&task.id)
    .bind(task.title.trim())
    .bind(task.project_id.trim())
    .bind(task.planned_for)
    .bind(task.due_on)
    .bind(task.repeat_weekday)
    .bind(task.completed)
    .execute(&db)
    .await?;

    Ok((StatusCode::CREATED, Json(fetch_task(&db, &task.id).await?)))
}

#[utoipa::path(
    put,
    path = "/api/tasks/{id}",
    operation_id = "updateTask",
    params(("id" = String, Path, description = "Task id")),
    request_body = TaskInput,
    responses(
        (status = 200, description = "Updated task", body = Task),
        (status = 400, description = "Invalid task", body = String),
        (status = 404, description = "Task not found", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn update_task(
    Path(id): Path<String>,
    State(db): State<SqlitePool>,
    Json(task): Json<TaskInput>,
) -> std::result::Result<Json<Task>, AppError> {
    validate_task(&task)?;
    if id != task.id {
        return Err(AppError::Invalid("path and task ids must match"));
    }

    let result = sqlx::query(
        "UPDATE tasks SET
            title = ?, project_id = ?, planned_for = ?, due_on = ?, repeat_weekday = ?,
            completed = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
         WHERE id = ?",
    )
    .bind(task.title.trim())
    .bind(task.project_id.trim())
    .bind(task.planned_for)
    .bind(task.due_on)
    .bind(task.repeat_weekday)
    .bind(task.completed)
    .bind(&id)
    .execute(&db)
    .await?;

    if result.rows_affected() == 0 {
        return Err(AppError::NotFound("task"));
    }
    Ok(Json(fetch_task(&db, &id).await?))
}

#[utoipa::path(
    post,
    path = "/api/tasks/{id}/toggle",
    operation_id = "toggleTask",
    params(("id" = String, Path, description = "Task id")),
    request_body = ToggleInput,
    responses(
        (status = 200, description = "Toggled task and optional next recurring task", body = ToggleResult),
        (status = 404, description = "Task not found", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn toggle_task(
    Path(id): Path<String>,
    State(db): State<SqlitePool>,
    Json(input): Json<ToggleInput>,
) -> std::result::Result<Json<ToggleResult>, AppError> {
    let mut transaction = db.begin().await?;
    let current = fetch_task(&mut *transaction, &id).await?;

    sqlx::query(
        "UPDATE tasks SET completed = ?, updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now') WHERE id = ?",
    )
    .bind(input.completed)
    .bind(&id)
    .execute(&mut *transaction)
    .await?;
    let task = fetch_task(&mut *transaction, &id).await?;

    let next_task = if !current.completed && input.completed && current.repeat_weekday.is_some() {
        let next_id = uuid::Uuid::now_v7().to_string();
        sqlx::query(
            "INSERT INTO tasks (
                id, title, project_id, planned_for, due_on, repeat_weekday, created_at, updated_at, completed
             ) SELECT ?, title, project_id,
                CASE WHEN planned_for IS NULL THEN NULL ELSE date(planned_for, '+7 days') END,
                CASE WHEN due_on IS NULL THEN NULL ELSE date(due_on, '+7 days') END,
                repeat_weekday, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), 0
             FROM tasks WHERE id = ?",
        )
        .bind(&next_id)
        .bind(&id)
        .execute(&mut *transaction)
        .await?;
        Some(fetch_task(&mut *transaction, &next_id).await?)
    } else {
        None
    };

    transaction.commit().await?;
    Ok(Json(ToggleResult { task, next_task }))
}

#[utoipa::path(
    delete,
    path = "/api/tasks/{id}",
    operation_id = "deleteTask",
    params(("id" = String, Path, description = "Task id")),
    responses(
        (status = 204, description = "Deleted task"),
        (status = 404, description = "Task not found", body = String),
    ),
    tag = "tasks"
)]
pub(crate) async fn delete_task(
    Path(id): Path<String>,
    State(db): State<SqlitePool>,
) -> std::result::Result<StatusCode, AppError> {
    let result = sqlx::query("DELETE FROM tasks WHERE id = ?")
        .bind(id)
        .execute(&db)
        .await?;
    if result.rows_affected() == 0 {
        return Err(AppError::NotFound("task"));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sqlx::sqlite::SqlitePoolOptions;

    fn assert_task(
        task: &Task,
        id: &str,
        title: &str,
        project_id: &str,
        project: &str,
        planned_for: Option<&str>,
        due_on: Option<&str>,
        repeat_weekday: Option<i64>,
        completed: bool,
    ) {
        let Task {
            id: actual_id,
            title: actual_title,
            project_id: actual_project_id,
            project: actual_project,
            planned_for: actual_planned_for,
            due_on: actual_due_on,
            repeat_weekday: actual_repeat_weekday,
            created_at: _,
            updated_at: _,
            completed: actual_completed,
        } = task;

        assert_eq!(actual_id, id);
        assert_eq!(actual_title, title);
        assert_eq!(actual_project_id, project_id);
        assert_eq!(actual_project, project);
        assert_eq!(actual_planned_for.as_deref(), planned_for);
        assert_eq!(actual_due_on.as_deref(), due_on);
        assert_eq!(*actual_repeat_weekday, repeat_weekday);
        assert_eq!(*actual_completed, completed);
    }

    async fn test_db() -> SqlitePool {
        let db = SqlitePoolOptions::new()
            .max_connections(1)
            .connect("sqlite::memory:")
            .await
            .unwrap();
        sqlx::migrate!().run(&db).await.unwrap();
        sqlx::query(
            "INSERT INTO projects (id, name, created_at, updated_at)
             VALUES ('other', 'Other', '2026-01-01', '2026-01-01')",
        )
        .execute(&db)
        .await
        .unwrap();
        db
    }

    #[tokio::test]
    async fn crud_round_trip() {
        let db = test_db().await;

        let input = TaskInput {
            id: "task-1".into(),
            title: "Write test".into(),
            project_id: "inbox".into(),
            planned_for: Some("2026-04-01".into()),
            due_on: Some("2026-04-03".into()),
            repeat_weekday: Some(3),
            completed: false,
        };
        let (_, Json(created)) = create_task(State(db.clone()), Json(input)).await.unwrap();
        assert_task(
            &created,
            "task-1",
            "Write test",
            "inbox",
            "Inbox",
            Some("2026-04-01"),
            Some("2026-04-03"),
            Some(3),
            false,
        );

        let Json(result) = toggle_task(
            Path(created.id.clone()),
            State(db.clone()),
            Json(ToggleInput { completed: true }),
        )
        .await
        .unwrap();
        assert_task(
            &result.task,
            "task-1",
            "Write test",
            "inbox",
            "Inbox",
            Some("2026-04-01"),
            Some("2026-04-03"),
            Some(3),
            true,
        );
        let next = result.next_task.unwrap();
        assert_task(
            &next,
            &next.id,
            "Write test",
            "inbox",
            "Inbox",
            Some("2026-04-08"),
            Some("2026-04-10"),
            Some(3),
            false,
        );

        let next_id = next.id.clone();
        let update = TaskInput {
            id: next_id.clone(),
            title: "Updated test".into(),
            project_id: "other".into(),
            planned_for: Some("2026-05-01".into()),
            due_on: Some("2026-05-09".into()),
            repeat_weekday: Some(5),
            completed: true,
        };
        let Json(updated) = update_task(Path(next_id), State(db.clone()), Json(update))
            .await
            .unwrap();
        assert_task(
            &updated,
            &updated.id,
            "Updated test",
            "other",
            "Other",
            Some("2026-05-01"),
            Some("2026-05-09"),
            Some(5),
            true,
        );
        let Json(fetched) = get_task(Path(updated.id.clone()), State(db.clone()))
            .await
            .unwrap();
        assert_task(
            &fetched,
            &updated.id,
            "Updated test",
            "other",
            "Other",
            Some("2026-05-01"),
            Some("2026-05-09"),
            Some(5),
            true,
        );

        delete_task(Path(created.id), State(db.clone()))
            .await
            .unwrap();
        delete_task(Path(updated.id), State(db.clone()))
            .await
            .unwrap();
        let Json(tasks) = list_tasks(State(db)).await.unwrap();
        assert!(tasks.is_empty());
    }

    #[tokio::test]
    async fn rejects_unknown_project() {
        let db = test_db().await;
        let input = TaskInput {
            id: "task-1".into(),
            title: "Write test".into(),
            project_id: "nope".into(),
            planned_for: None,
            due_on: None,
            repeat_weekday: None,
            completed: false,
        };
        let error = create_task(State(db.clone()), Json(input)).await.unwrap_err();
        assert_eq!(error.to_string(), "project does not exist");

        let Json(tasks) = list_tasks(State(db)).await.unwrap();
        assert!(tasks.is_empty());
    }
}
