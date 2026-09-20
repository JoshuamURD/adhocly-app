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
    assert!(project.metadata.is_empty());

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

#[tokio::test]
async fn metadata_fields_round_trip_and_validate_values() {
    let db = test_db().await;
    let state = AppState::new(db.clone());

    let (_, Json(client)) = create_metadata_field(
        State(state.clone()),
        Json(MetadataFieldInput {
            id: Some("field-1".into()),
            name: "Client".into(),
            kind: FieldKind::Text,
            options: vec!["ignored".into()],
        }),
    )
    .await
    .unwrap();
    assert_eq!(client.id, "field-1");
    assert!(client.options.is_empty());

    let (_, Json(budget)) = create_metadata_field(
        State(state.clone()),
        Json(MetadataFieldInput {
            id: None,
            name: "Budget".into(),
            kind: FieldKind::Number,
            options: vec![],
        }),
    )
    .await
    .unwrap();

    let (_, Json(status)) = create_metadata_field(
        State(state.clone()),
        Json(MetadataFieldInput {
            id: None,
            name: "Status".into(),
            kind: FieldKind::Choice,
            options: vec![
                "Active".into(),
                " Active ".into(),
                "Paused".into(),
                "".into(),
            ],
        }),
    )
    .await
    .unwrap();
    assert_eq!(status.options, vec!["Active", "Paused"]);

    let no_options = create_metadata_field(
        State(state.clone()),
        Json(MetadataFieldInput {
            id: None,
            name: "Stage".into(),
            kind: FieldKind::Choice,
            options: vec![],
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(
        no_options.to_string(),
        "choice fields need at least one option"
    );

    let (_, Json(project)) = create_project(
        State(state.clone()),
        Json(ProjectInput {
            id: None,
            name: "Website".into(),
        }),
    )
    .await
    .unwrap();

    for (field, value) in [(&client, "Acme"), (&budget, "1200"), (&status, "Paused")] {
        set_project_metadata(
            Path((project.id.clone(), field.id.clone())),
            State(state.clone()),
            Json(MetadataValueInput {
                value: Some(value.into()),
            }),
        )
        .await
        .unwrap();
    }

    let Json(loaded) = get_project(Path(project.id.clone()), State(state.clone()))
        .await
        .unwrap();
    let mut values: Vec<(&str, &str)> = loaded
        .metadata
        .iter()
        .map(|value| (value.field_id.as_str(), value.value.as_str()))
        .collect();
    values.sort();
    let mut expected = vec![
        (client.id.as_str(), "Acme"),
        (budget.id.as_str(), "1200"),
        (status.id.as_str(), "Paused"),
    ];
    expected.sort();
    assert_eq!(values, expected);

    let not_a_number = set_project_metadata(
        Path((project.id.clone(), budget.id.clone())),
        State(state.clone()),
        Json(MetadataValueInput {
            value: Some("abc".into()),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(not_a_number.to_string(), "value must be a number");

    let not_an_option = set_project_metadata(
        Path((project.id.clone(), status.id.clone())),
        State(state.clone()),
        Json(MetadataValueInput {
            value: Some("Archived".into()),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(
        not_an_option.to_string(),
        "value must be one of the field options"
    );

    // Blank clears, and the invalid attempts above left the stored values alone.
    set_project_metadata(
        Path((project.id.clone(), budget.id.clone())),
        State(state.clone()),
        Json(MetadataValueInput {
            value: Some("  ".into()),
        }),
    )
    .await
    .unwrap();
    let Json(loaded) = get_project(Path(project.id.clone()), State(state.clone()))
        .await
        .unwrap();
    assert_eq!(loaded.metadata.len(), 2);
    assert!(!loaded
        .metadata
        .iter()
        .any(|value| value.field_id == budget.id));

    let Json(projects) = list_projects(State(state.clone())).await.unwrap();
    let website = projects.iter().find(|p| p.id == project.id).unwrap();
    assert_eq!(website.metadata.len(), 2);

    let Json(fields) = list_metadata_fields(State(state.clone())).await.unwrap();
    assert_eq!(fields.len(), 3);
    assert_eq!(
        fields
            .iter()
            .find(|field| field.name == "Status")
            .unwrap()
            .kind,
        FieldKind::Choice
    );

    // Renaming keeps the kind and option list; values are untouched.
    let Json(renamed) = update_metadata_field(
        Path(status.id.clone()),
        State(state.clone()),
        Json(MetadataFieldUpdate {
            name: "State".into(),
            options: vec!["Active".into()],
        }),
    )
    .await
    .unwrap();
    assert_eq!(renamed.name, "State");
    assert_eq!(renamed.options, vec!["Active"]);

    delete_metadata_field(Path(status.id.clone()), State(state.clone()))
        .await
        .unwrap();
    let Json(loaded) = get_project(Path(project.id), State(state.clone()))
        .await
        .unwrap();
    assert_eq!(loaded.metadata.len(), 1);

    let missing = set_project_metadata(
        Path((INBOX_ID.to_owned(), status.id)),
        State(state.clone()),
        Json(MetadataValueInput {
            value: Some("Active".into()),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(missing.to_string(), "field not found");
}
