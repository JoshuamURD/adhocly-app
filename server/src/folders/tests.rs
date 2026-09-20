use axum::{
    extract::{Path, State},
    Json,
};
use sqlx::{sqlite::SqlitePoolOptions, SqlitePool};

use super::*;
use crate::{projects::*, state::AppState};

async fn test_db() -> SqlitePool {
    let db = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    sqlx::migrate!().run(&db).await.unwrap();
    db
}

async fn create(state: &AppState, name: &str, parent_id: Option<&str>) -> Folder {
    let (_, Json(folder)) = create_folder(
        State(state.clone()),
        Json(FolderInput {
            id: None,
            name: name.into(),
            parent_id: parent_id.map(str::to_owned),
        }),
    )
    .await
    .unwrap();
    folder
}

async fn project_folder(db: &SqlitePool, id: &str) -> Option<String> {
    sqlx::query_scalar("SELECT folder_id FROM projects WHERE id = ?")
        .bind(id)
        .fetch_one(db)
        .await
        .unwrap()
}

#[tokio::test]
async fn folders_nest_rename_and_move_without_closing_a_loop() {
    let db = test_db().await;
    let state = AppState::new(db.clone());

    let work = create(&state, "  Work  ", None).await;
    assert_eq!(work.name, "Work");
    assert_eq!(work.parent_id, None);

    let clients = create(&state, "Clients", Some(&work.id)).await;
    assert_eq!(clients.parent_id.as_deref(), Some(work.id.as_str()));

    // Sibling names collide, the same name under another parent does not.
    let duplicate = create_folder(
        State(state.clone()),
        Json(FolderInput {
            id: None,
            name: "clients".into(),
            parent_id: Some(work.id.clone()),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(duplicate.to_string(), "that name is already taken");
    let elsewhere = create(&state, "Clients", None).await;
    assert_eq!(elsewhere.parent_id, None);

    let missing_parent = create_folder(
        State(state.clone()),
        Json(FolderInput {
            id: None,
            name: "Orphan".into(),
            parent_id: Some("nope".into()),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(missing_parent.to_string(), "folder not found");

    // A folder cannot become its own ancestor, at any depth.
    for parent in [&work.id, &clients.id] {
        let looped = update_folder(
            Path(work.id.clone()),
            State(state.clone()),
            Json(FolderInput {
                id: None,
                name: "Work".into(),
                parent_id: Some(parent.clone()),
            }),
        )
        .await
        .unwrap_err();
        assert_eq!(looped.to_string(), "a folder cannot move inside itself");
    }

    // Renaming and moving to the top level are one update.
    let Json(moved) = update_folder(
        Path(clients.id.clone()),
        State(state.clone()),
        Json(FolderInput {
            id: None,
            name: "Accounts".into(),
            parent_id: None,
        }),
    )
    .await
    .unwrap();
    assert_eq!(moved.name, "Accounts");
    assert_eq!(moved.parent_id, None);

    let Json(folders) = list_folders(State(state.clone())).await.unwrap();
    assert_eq!(folders.len(), 3);
}

#[tokio::test]
async fn deleting_a_folder_hands_its_projects_and_subfolders_to_its_parent() {
    let db = test_db().await;
    let state = AppState::new(db.clone());

    let work = create(&state, "Work", None).await;
    let clients = create(&state, "Clients", Some(&work.id)).await;

    let (_, Json(project)) = create_project(
        State(state.clone()),
        Json(ProjectInput {
            id: None,
            name: "Website".into(),
        }),
    )
    .await
    .unwrap();
    assert_eq!(project.folder_id, None);
    let _ = move_project(
        Path(project.id.clone()),
        State(state.clone()),
        Json(ProjectFolderInput {
            folder_id: Some(clients.id.clone()),
        }),
    )
    .await
    .unwrap();
    assert_eq!(
        project_folder(&db, &project.id).await.as_deref(),
        Some(clients.id.as_str())
    );

    let unfile = move_project(
        Path(project.id.clone()),
        State(state.clone()),
        Json(ProjectFolderInput { folder_id: None }),
    )
    .await
    .unwrap();
    assert_eq!(unfile.0.folder_id, None);
    assert_eq!(project_folder(&db, &project.id).await, None);

    // Back in, then delete the parent: the nested folder and its project land one level up.
    let _ = move_project(
        Path(project.id.clone()),
        State(state.clone()),
        Json(ProjectFolderInput {
            folder_id: Some(clients.id.clone()),
        }),
    )
    .await
    .unwrap();
    delete_folder(Path(clients.id.clone()), State(state.clone()))
        .await
        .unwrap();
    assert_eq!(
        project_folder(&db, &project.id).await.as_deref(),
        Some(work.id.as_str())
    );
    let deleted: Option<Option<String>> =
        sqlx::query_scalar("SELECT parent_id FROM folders WHERE id = ?")
            .bind(&clients.id)
            .fetch_optional(&db)
            .await
            .unwrap();
    assert_eq!(deleted, None, "the folder row is gone");

    let unknown_folder = move_project(
        Path(project.id.clone()),
        State(state.clone()),
        Json(ProjectFolderInput {
            folder_id: Some("nope".into()),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(unknown_folder.to_string(), "folder not found");

    let inbox = move_project(
        Path(INBOX_ID.to_owned()),
        State(state.clone()),
        Json(ProjectFolderInput {
            folder_id: Some(work.id.clone()),
        }),
    )
    .await
    .unwrap_err();
    assert_eq!(inbox.to_string(), "Inbox cannot be filed");

    let gone = delete_folder(Path(clients.id), State(state.clone()))
        .await
        .unwrap_err();
    assert_eq!(gone.to_string(), "folder not found");
}
