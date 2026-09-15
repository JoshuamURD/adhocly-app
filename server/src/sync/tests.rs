use super::*;
use serde_json::json;
use sqlx::sqlite::SqlitePoolOptions;

async fn state() -> AppState {
    let db = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    sqlx::migrate!().run(&db).await.unwrap();
    AppState::new(db)
}

fn operation(id: &str, url: &str, method: &str, body: Value, version: i64) -> SyncOperation {
    SyncOperation {
        id: id.into(),
        url: url.into(),
        method: method.into(),
        body,
        expected_version: version,
    }
}

fn task(id: &str) -> Value {
    json!({"id": id, "title": "Original", "projectId": "inbox", "plannedFor": "2026-04-01T09:00",
        "dueOn": null, "repeatWeekday": 3, "completed": false})
}

async fn send(state: &AppState, op: SyncOperation) -> Result<SyncReply, AppError> {
    apply(State(state.clone()), Json(op))
        .await
        .map(|Json(reply)| reply)
}

#[tokio::test]
async fn committed_requests_replay_without_overwriting_newer_work() {
    let state = state().await;
    let create = operation("create", "/api/tasks", "POST", task("t1"), 0);
    let first = send(&state, create.clone()).await.unwrap();
    assert_eq!(first.changes["tasks/t1"], 1);

    // A browser edit after an iOS response was lost.
    let mut newer = task("t1");
    newer["title"] = json!("Newer browser edit");
    state
        .tasks
        .update("t1", &serde_json::from_value(newer.clone()).unwrap())
        .await
        .unwrap();
    let replay = send(&state, create.clone()).await.unwrap();
    assert_eq!(replay.snapshot.tasks[0].title, "Newer browser edit");
    assert_eq!(replay.snapshot.versions["tasks/t1"], 2);
    assert_eq!(replay.changes["tasks/t1"], 1); // only the original operation's effects

    let mut reused = create.clone();
    reused.body = newer.clone();
    assert!(matches!(
        send(&state, reused).await,
        Err(AppError::Conflict(_))
    ));
    assert!(matches!(
        send(
            &state,
            operation("stale", "/api/tasks/t1", "PUT", task("t1"), 1)
        )
        .await,
        Err(AppError::Conflict(_))
    ));
    assert!(state
        .tasks
        .create(&serde_json::from_value(task("t1")).unwrap())
        .await
        .is_err());
    assert_eq!(
        state.tasks.get("t1").await.unwrap().title,
        "Newer browser edit"
    );

    let delete = operation("delete", "/api/tasks/t1", "DELETE", json!({}), 2);
    send(&state, delete.clone()).await.unwrap();
    send(&state, delete).await.unwrap();
    send(&state, create).await.unwrap(); // a late create retry must not resurrect a deleted task
    assert!(state.tasks.list().await.unwrap().is_empty());
}

#[tokio::test]
async fn receipt_failure_and_cancellation_roll_back_the_business_write() {
    let state = state().await;
    sqlx::query("CREATE TRIGGER fail_receipt BEFORE INSERT ON sync_receipts BEGIN SELECT RAISE(ABORT, 'simulated disk error'); END")
        .execute(state.pool()).await.unwrap();
    let create = operation("atomic", "/api/tasks", "POST", task("t1"), 0);
    assert!(send(&state, create.clone()).await.is_err());
    assert!(state.tasks.list().await.unwrap().is_empty());
    assert!(!snapshot(state.pool())
        .await
        .unwrap()
        .versions
        .contains_key("tasks/t1"));
    sqlx::query("DROP TRIGGER fail_receipt")
        .execute(state.pool())
        .await
        .unwrap();
    send(&state, create).await.unwrap();

    let mut write = Write::begin(state.pool(), None).await.unwrap();
    sqlx::query("UPDATE tasks SET title = 'cancelled' WHERE id = 't1'")
        .execute(&mut *write.transaction)
        .await
        .unwrap();
    drop(write);
    assert_eq!(state.tasks.get("t1").await.unwrap().title, "Original");
    assert_eq!(
        snapshot(state.pool()).await.unwrap().versions["tasks/t1"],
        1
    );
}

#[tokio::test]
async fn recurring_successor_is_shared_and_never_overwritten_or_resurrected() {
    let state = state().await;
    send(
        &state,
        operation("create", "/api/tasks", "POST", task("t1"), 0),
    )
    .await
    .unwrap();
    let complete = operation(
        "complete-a",
        "/api/tasks/t1/toggle",
        "POST",
        json!({"completed": true, "nextId": "next:t1"}),
        1,
    );
    let result = send(&state, complete.clone()).await.unwrap();
    assert!(result
        .snapshot
        .tasks
        .iter()
        .any(|task| task.id == "next:t1"));
    assert!(matches!(
        send(
            &state,
            operation(
                "complete-b",
                "/api/tasks/t1/toggle",
                "POST",
                complete.body.clone(),
                1
            )
        )
        .await,
        Err(AppError::Conflict(_))
    ));

    let mut edited = task("next:t1");
    edited["title"] = json!("Edited successor");
    state
        .tasks
        .update("next:t1", &serde_json::from_value(edited).unwrap())
        .await
        .unwrap();
    state.tasks.toggle("t1", false, None).await.unwrap();
    send(&state, complete).await.unwrap(); // replay does not re-complete a task reopened on another device
    assert!(!state.tasks.get("t1").await.unwrap().completed);
    let next = state
        .tasks
        .toggle("t1", true, None)
        .await
        .unwrap()
        .next_task
        .unwrap();
    assert_eq!(next.title, "Edited successor");
    assert_eq!(state.tasks.list().await.unwrap().len(), 2);
    state.tasks.delete("next:t1").await.unwrap();
    state.tasks.toggle("t1", false, None).await.unwrap();
    assert!(state
        .tasks
        .toggle("t1", true, None)
        .await
        .unwrap()
        .next_task
        .is_none());
}

#[tokio::test]
async fn cascade_versions_and_create_validation_cannot_be_bypassed() {
    let state = state().await;
    state
        .folders
        .create(Some("f1"), "Folder", None)
        .await
        .unwrap();
    assert!(state
        .folders
        .create(Some("f1"), "Folder", Some("f1"))
        .await
        .is_err());
    assert_eq!(state.folders.list().await.unwrap()[0].parent_id, None);
    state
        .folders
        .create(Some("f2"), "Child", Some("f1"))
        .await
        .unwrap();
    assert!(state
        .folders
        .update("f1", "Folder", Some("f2"))
        .await
        .is_err());
    state.projects.create(Some("p1"), "Project").await.unwrap();
    state.projects.set_folder("p1", Some("f1")).await.unwrap();
    let before = snapshot(state.pool()).await.unwrap();
    let deleted = send(
        &state,
        operation(
            "delete-folder",
            "/api/folders/f1",
            "DELETE",
            json!({}),
            before.versions["folders/f1"],
        ),
    )
    .await
    .unwrap();
    assert!(deleted.changes["projects/p1"] > before.versions["projects/p1"]);
    assert!(deleted.changes["folders/f2"] > before.versions["folders/f2"]);

    let field: projects::MetadataFieldInput =
        serde_json::from_value(json!({"id":"field", "name":"Status", "kind":"text"})).unwrap();
    state.projects.create_field(&field).await.unwrap();
    let revision = snapshot(state.pool()).await.unwrap().versions["projects/p1"];
    state
        .projects
        .set_value("p1", "field", Some("Active".into()))
        .await
        .unwrap();
    assert!(snapshot(state.pool()).await.unwrap().versions["projects/p1"] > revision);
    let changed_kind =
        serde_json::from_value(json!({"id":"field", "name":"Status", "kind":"number"})).unwrap();
    assert!(state.projects.create_field(&changed_kind).await.is_err());
    assert_eq!(
        state.projects.list_fields().await.unwrap()[0].kind,
        projects::FieldKind::Text
    );
    let revision = snapshot(state.pool()).await.unwrap().versions["projects/p1"];
    state.projects.delete_field("field").await.unwrap();
    assert!(snapshot(state.pool()).await.unwrap().versions["projects/p1"] > revision);
}

#[tokio::test]
async fn concurrent_retries_commit_once_and_invalid_requests_leave_no_receipts() {
    let state = state().await;
    let create = operation("once", "/api/tasks", "POST", task("t1"), 0);
    let (a, b) = tokio::join!(send(&state, create.clone()), send(&state, create));
    assert!(a.is_ok() && b.is_ok());
    assert_eq!(state.tasks.list().await.unwrap().len(), 1);
    assert_eq!(
        snapshot(state.pool()).await.unwrap().versions["tasks/t1"],
        1
    );
    assert!(send(
        &state,
        operation("bad", "/api/tasks/t1/nonsense", "POST", json!({}), 1)
    )
    .await
    .is_err());
    assert!(send(
        &state,
        operation("bad-body", "/api/tasks", "POST", json!({"id":"bad"}), 0)
    )
    .await
    .is_err());
    let count: i64 = sqlx::query_scalar("SELECT count(*) FROM sync_receipts")
        .fetch_one(state.pool())
        .await
        .unwrap();
    assert_eq!(count, 1);
}
