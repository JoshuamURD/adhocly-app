use axum::{
    extract::{Path, State},
    Json,
};
use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};

use super::*;
use crate::state::AppState;

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
    let state = AppState::new(db.clone());

    let input = TaskInput {
        id: "task-1".into(),
        title: "Write test".into(),
        project_id: "inbox".into(),
        planned_for: Some("2026-04-01T09:00".into()),
        due_on: Some("2026-04-03T09:00".into()),
        repeat_weekday: Some(3),
        completed: false,
    };
    let (_, Json(created)) = create_task(State(state.clone()), Json(input)).await.unwrap();
    assert_task(
        &created,
        "task-1",
        "Write test",
        "inbox",
        "Inbox",
        Some("2026-04-01T09:00"),
        Some("2026-04-03T09:00"),
        Some(3),
        false,
    );

    let Json(result) = toggle_task(
        Path(created.id.clone()),
        State(state.clone()),
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
        Some("2026-04-01T09:00"),
        Some("2026-04-03T09:00"),
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
        Some("2026-04-08T09:00"),
        Some("2026-04-10T09:00"),
        Some(3),
        false,
    );

    let next_id = next.id.clone();
    let update = TaskInput {
        id: next_id.clone(),
        title: "Updated test".into(),
        project_id: "other".into(),
        planned_for: Some("2026-05-01T09:00".into()),
        due_on: Some("2026-05-09T09:00".into()),
        repeat_weekday: Some(5),
        completed: true,
    };
    let Json(updated) = update_task(Path(next_id), State(state.clone()), Json(update))
        .await
        .unwrap();
    assert_task(
        &updated,
        &updated.id,
        "Updated test",
        "other",
        "Other",
        Some("2026-05-01T09:00"),
        Some("2026-05-09T09:00"),
        Some(5),
        true,
    );
    let Json(fetched) = get_task(Path(updated.id.clone()), State(state.clone()))
        .await
        .unwrap();
    assert_task(
        &fetched,
        &updated.id,
        "Updated test",
        "other",
        "Other",
        Some("2026-05-01T09:00"),
        Some("2026-05-09T09:00"),
        Some(5),
        true,
    );

    delete_task(Path(created.id), State(state.clone()))
        .await
        .unwrap();
    delete_task(Path(updated.id), State(state.clone()))
        .await
        .unwrap();
    let Json(tasks) = list_tasks(State(state)).await.unwrap();
    assert!(tasks.is_empty());
}

#[tokio::test]
async fn rejects_unknown_project() {
    let db = test_db().await;
    let state = AppState::new(db.clone());
    let input = TaskInput {
        id: "task-1".into(),
        title: "Write test".into(),
        project_id: "nope".into(),
        planned_for: None,
        due_on: None,
        repeat_weekday: None,
        completed: false,
    };
    let error = create_task(State(state.clone()), Json(input))
        .await
        .unwrap_err();
    assert_eq!(error.to_string(), "project does not exist");

    let Json(tasks) = list_tasks(State(state)).await.unwrap();
    assert!(tasks.is_empty());
}
