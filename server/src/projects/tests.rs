use axum::{
    extract::{Path, State},
    Json,
};
use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};

use super::*;
use crate::state::AppState;

async fn test_db() -> SqlitePool {
    let db = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    sqlx::migrate!().run(&db).await.unwrap();
    db
}

async fn add_task(db: &SqlitePool, id: &str, project_id: &str) {
    sqlx::query(
        "INSERT INTO tasks (id, title, project_id, created_at, updated_at, completed)
         VALUES (?, 'A task', ?, '2026-01-01', '2026-01-01', 0)",
    )
    .bind(id)
    .bind(project_id)
    .execute(db)
    .await
    .unwrap();
}

async fn project_name(db: &SqlitePool, id: &str) -> Option<String> {
    sqlx::query_scalar("SELECT name FROM projects WHERE id = ?")
        .bind(id)
        .fetch_optional(db)
        .await
        .unwrap()
}

#[tokio::test]
async fn create_rename_and_delete_moves_tasks_to_inbox() {
    let db = test_db().await;
    let state = AppState::new(db.clone());
    let (_, Json(project)) = create_project(
        State(state.clone()),
        Json(ProjectInput {
            id: Some("project-1".into()),
            name: "  Client Work  ".into(),
        }),
    )
    .await
    .unwrap();
    assert_eq!(project.id, "project-1");
    assert_eq!(project.name, "Client Work");

    // Same name in another case is rejected by the NOCASE unique index.
    let conflict = create_project(
        State(state.clone()),
        Json(ProjectInput {
            id: None,
            name: "client work".into(),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(conflict.to_string(), "that name is already taken");

    add_task(&db, "task-1", &project.id).await;

    let Json(renamed) = update_project(
        Path(project.id.clone()),
        State(state.clone()),
        Json(ProjectInput {
            id: None,
            name: "Acme".into(),
        }),
    )
    .await
    .unwrap();
    assert_eq!(renamed.name, "Acme");

    delete_project(Path(project.id.clone()), State(state.clone()))
        .await
        .unwrap();
    assert_eq!(project_name(&db, &project.id).await, None);
    let project_id: String = sqlx::query_scalar("SELECT project_id FROM tasks WHERE id = 'task-1'")
        .fetch_one(&db)
        .await
        .unwrap();
    assert_eq!(project_id, INBOX_ID);

    let inbox_error = delete_project(Path(INBOX_ID.to_owned()), State(state.clone()))
        .await
        .unwrap_err();
    assert_eq!(inbox_error.to_string(), "Inbox cannot be deleted");
    assert!(project_name(&db, INBOX_ID).await.is_some());
}
