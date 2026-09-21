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

async fn send_with(
    state: &AppState,
    op: SyncOperation,
    snapshot: bool,
) -> Result<SyncReply, AppError> {
    apply(
        State(state.clone()),
        Query(SyncQuery {
            snapshot: Some(snapshot),
        }),
        Json(op),
    )
    .await
    .map(|Json(reply)| reply)
}

async fn send(state: &AppState, op: SyncOperation) -> Result<SyncReply, AppError> {
    send_with(state, op, true).await
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
    let replay_snapshot = replay.snapshot.unwrap();
    assert_eq!(replay_snapshot.tasks[0].title, "Newer browser edit");
    assert_eq!(replay_snapshot.versions["tasks/t1"], 2);
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
        .unwrap()
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

}

#[tokio::test]
async fn snapshot_can_be_skipped_without_losing_the_change_map() {
    let state = state().await;
    let reply = send_with(
        &state,
        operation("quiet", "/api/tasks", "POST", task("t1"), 0),
        false,
    )
    .await
    .unwrap();
    assert!(reply.snapshot.is_none());
    assert_eq!(reply.changes["tasks/t1"], 1);
    assert_eq!(state.tasks.get("t1").await.unwrap().title, "Original");

    // A replay of the same operation also skips the snapshot and keeps the receipt's changes.
    let replay = send_with(
        &state,
        operation("quiet", "/api/tasks", "POST", task("t1"), 0),
        false,
    )
    .await
    .unwrap();
    assert!(replay.snapshot.is_none());
    assert_eq!(replay.changes["tasks/t1"], 1);
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

#[tokio::test]
async fn kanban_schema_and_task_moves_share_the_sync_protocol() {
    let state = state().await;
    let mut status =
        serde_json::to_value(&snapshot(state.pool()).await.unwrap().task_fields[0]).unwrap();
    status["options"][2]["name"] = json!("Shipped");
    status["options"]
        .as_array_mut()
        .unwrap()
        .push(json!({"id":"review", "name":"Review"}));
    let change_status = operation(
        "statuses",
        "/api/task-fields/status",
        "PUT",
        status.clone(),
        1,
    );
    let first = send(&state, change_status.clone()).await.unwrap();
    assert_eq!(first.changes["task-fields/status"], 2);
    send(&state, change_status).await.unwrap();
    let board = json!({"id":"workflow", "name":"Workflow", "fieldId":"status"});
    let reply = send(&state, operation("board", "/api/boards", "POST", board, 0)).await.unwrap();
    assert_eq!(reply.changes["boards/workflow"], 1);

    let mut input = task("kanban-task");
    input["statusId"] = json!("review");
    send(
        &state,
        operation("create-card", "/api/tasks", "POST", input.clone(), 0),
    )
    .await
    .unwrap();
    // A legacy non-Apple client can edit a task without accidentally resetting its new fields.
    let mut legacy = task("kanban-task");
    legacy["title"] = json!("Legacy edit");
    send(
        &state,
        operation("legacy", "/api/tasks/kanban-task", "PUT", legacy, 1),
    )
    .await
    .unwrap();
    let persisted = state.tasks.get("kanban-task").await.unwrap();
    assert_eq!(persisted.status_id, "review");

    // Moving to Complete uses PUT, and must have exactly the same recurrence behavior as a toggle.
    input["statusId"] = json!("complete");
    input["completed"] = json!(true);
    let complete = operation("complete-card", "/api/tasks/kanban-task", "PUT", input, 2);
    send(&state, complete.clone()).await.unwrap();
    send(&state, complete).await.unwrap();
    let successor = state.tasks.get("next:kanban-task").await.unwrap();
    assert!(!successor.completed);
    assert_eq!(successor.status_id, "todo");
    assert_eq!(state.tasks.list().await.unwrap().len(), 2);

    let mut renamed = status.clone();
    renamed["options"][0]["name"] = json!("Ready");
    let before = snapshot(state.pool()).await.unwrap();
    send(&state, operation("rename-status", "/api/task-fields/status", "PUT", renamed.clone(), 2)).await.unwrap();
    assert_eq!(snapshot(state.pool()).await.unwrap().versions["tasks/kanban-task"], before.versions["tasks/kanban-task"]);
    assert!(matches!(send(&state, operation("stale-status", "/api/task-fields/status", "PUT", status.clone(), 2)).await, Err(AppError::Conflict(_))));
    let mut active = task("active-review");
    active["statusId"] = json!("review");
    send(&state, operation("review-task", "/api/tasks", "POST", active, 0)).await.unwrap();
    renamed["options"].as_array_mut().unwrap().retain(|o| o["id"] != "review");
    assert!(matches!(send(&state, operation("used-status", "/api/task-fields/status", "PUT", renamed, 3)).await, Err(AppError::Invalid(_))));
    status["options"].as_array_mut().unwrap().remove(2);
    assert!(matches!(
        send(
            &state,
            operation(
                "remove-complete",
                "/api/task-fields/status",
                "PUT",
                status,
                2
            )
        )
        .await,
        Err(AppError::Invalid(_))
    ));
    send(
        &state,
        operation(
            "delete-board",
            "/api/boards/workflow",
            "DELETE",
            json!({}),
            1,
        ),
    )
    .await
    .unwrap();
    assert_eq!(state.tasks.list().await.unwrap().len(), 3); // deleting a view keeps its tasks
}

#[tokio::test]
async fn task_status_validation_and_retired_properties_cannot_be_bypassed() {
    let state = state().await;
    let mut input = task("bad");
    input["statusId"] = json!("complete"); // disagrees with completed: false
    assert!(send(
        &state,
        operation("bad-complete", "/api/tasks", "POST", input.clone(), 0)
    )
    .await
    .is_err());
    input["statusId"] = json!("unknown");
    assert!(send(
        &state,
        operation("bad-status", "/api/tasks", "POST", input.clone(), 0)
    )
    .await
    .is_err());
    input["statusId"] = json!("todo");
    // Old queued task edits still save their task data, but cannot restore removed properties.
    input["properties"] = json!({"retired":"value"});
    let legacy = operation("legacy-properties", "/api/tasks", "POST", input, 0);
    send(&state, legacy.clone()).await.unwrap();
    send(&state, legacy).await.unwrap();
    let saved = serde_json::to_value(state.tasks.get("bad").await.unwrap()).unwrap();
    assert!(saved.get("properties").is_none());
    for (url, method, body) in [
        ("/api/task-fields", "POST", json!({"id":"effort","name":"Effort","kind":"number","options":[]})),
        ("/api/task-fields/effort", "PUT", json!({"id":"effort","name":"Effort","kind":"number","options":[]})),
        ("/api/metadata-fields", "POST", json!({"id":"client","name":"Client","kind":"text"})),
        ("/api/projects/inbox/metadata/client", "PUT", json!({"value":"Acme"})),
    ] {
        assert!(send(&state, operation(url, url, method, body, 0)).await.is_err());
    }
    assert!(
        sqlx::query("UPDATE tasks SET completed = 1 WHERE id = 'bad'")
            .execute(state.pool())
            .await
            .is_err()
    );
    assert!(!state.tasks.get("bad").await.unwrap().completed);
    assert!(send(
        &state,
        operation(
            "bad-board",
            "/api/boards",
            "POST",
            json!({"id":"bad-board", "name":"Missing field", "fieldId":"missing"}),
            0
        )
    )
    .await
    .is_err());
}

#[tokio::test]
async fn kanban_migration_preserves_old_completed_tasks_and_reminders() {
    let db = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    for migration in sqlx::migrate!().iter().filter(|m| m.version < 8) {
        sqlx::raw_sql(migration.sql.clone())
            .execute(&db)
            .await
            .unwrap();
    }
    sqlx::query("INSERT INTO tasks (id, title, project_id, created_at, updated_at, completed) VALUES ('old', 'Old completed task', 'inbox', '2026-01-01', '2026-01-01', 1)").execute(&db).await.unwrap();
    sqlx::query("INSERT INTO task_reminders VALUES ('old-reminder', '2026-01-01T09:00', 'old')")
        .execute(&db)
        .await
        .unwrap();
    for migration in sqlx::migrate!().iter().filter(|m| m.version >= 8) {
        sqlx::raw_sql(migration.sql.clone()).execute(&db).await.unwrap();
    }
    let state = AppState::new(db);
    let task = state.tasks.get("old").await.unwrap();
    assert!(task.completed);
    assert_eq!(task.status_id, "complete");
    assert!(task.reminders.is_empty());
    assert!(state.reminders.get("old-reminder").await.is_ok());
}

#[tokio::test]
async fn board_sorting_round_trips_replays_and_preserves_legacy_edits() {
    let state = state().await;
    let initial = snapshot(state.pool()).await.unwrap();
    assert_eq!(initial.protocol_version, 7);
    assert_eq!(initial.boards[0].sort_mode, "created");
    assert!(initial.boards[0].manual_order.is_empty());
    let mut version = 1;
    for mode in ["due", "planned", "created", "alphabetical", "manual"] {
        let op = operation(&format!("sort-{mode}"), "/api/boards/status", "PUT",
            json!({"id":"status", "name":"By status", "fieldId":"status", "sortMode":mode,
                "manualOrder":["t2", "next:t1", "t1"]}), version);
        let reply = send(&state, op.clone()).await.unwrap();
        version += 1;
        assert_eq!(reply.changes["boards/status"], version);
        let board = &reply.snapshot.unwrap().boards[0];
        assert_eq!(board.sort_mode, mode);
        assert_eq!(board.manual_order.0, ["t2", "next:t1", "t1"]);
        let replay = send(&state, op).await.unwrap();
        assert_eq!(replay.changes["boards/status"], version);
    }
    // Old clients can rename a board without clearing its newer sorting fields.
    let legacy = operation("legacy-name", "/api/boards/status", "PUT",
        json!({"id":"status", "name":"Renamed", "fieldId":"status"}), version);
    let reply = send(&state, legacy).await.unwrap();
    version += 1;
    let board = &reply.snapshot.unwrap().boards[0];
    assert_eq!(board.name, "Renamed");
    assert_eq!(board.sort_mode, "manual");
    assert_eq!(board.manual_order.0, ["t2", "next:t1", "t1"]);
    for (mode, order) in [("unknown", json!([])), ("manual", json!(["t1", "t1"])), ("manual", json!([""]))] {
        let op = operation("invalid-sort", "/api/boards/status", "PUT",
            json!({"id":"status", "name":"Invalid", "fieldId":"status", "sortMode":mode, "manualOrder":order}), version);
        assert!(matches!(send(&state, op).await, Err(AppError::Invalid(_))));
    }
    let stale = operation("stale-sort", "/api/boards/status", "PUT",
        json!({"id":"status", "name":"Stale", "fieldId":"status", "sortMode":"due"}), version - 1);
    assert!(matches!(send(&state, stale).await, Err(AppError::Conflict(_))));
    assert_eq!(snapshot(state.pool()).await.unwrap().versions["boards/status"], version);
}

#[tokio::test]
async fn contexts_validate_replay_preserve_overrides_and_cascade_atomically() {
    let state = state().await;
    let contact = json!({"id":"client", "name":"Client", "email":"client@example.com", "phone":"", "notes":""});
    send(
        &state,
        operation("contact", "/api/contacts/client", "PUT", contact, 0),
    )
    .await
    .unwrap();
    let context = json!({"id":"matter", "name":"Matter", "fields":[
        {"id":"number", "name":"Matter number", "kind":"identifier", "value":"M-123"},
        {"id":"client", "name":"Client", "kind":"contact", "value":"client"},
        {"id":"platform", "name":"Platform", "kind":"choice", "options":["Cloudflare", "Local"], "value":"Local"},
        {"id":"date", "name":"Opened", "kind":"date", "value":"2028-02-29"},
        {"id":"repo", "name":"Repository", "kind":"link", "value":"https://example.com/repo"}
    ]});
    let create = operation("context", "/api/contexts/matter", "PUT", context.clone(), 0);
    send(&state, create.clone()).await.unwrap();
    let replay = send(&state, create).await.unwrap();
    assert_eq!(replay.changes["contexts/matter"], 1);
    send(
        &state,
        operation("task", "/api/tasks", "POST", task("context-task"), 0),
    )
    .await
    .unwrap();
    let links = json!({"id":"tasks:context-task", "contextIds":["matter"], "overrides":{"matter":{"number":"LOCAL", "platform":"Cloudflare"}}});
    let attach = operation(
        "attach",
        "/api/context-links/tasks%3Acontext-task",
        "PUT",
        links.clone(),
        0,
    );
    let reply = send(&state, attach.clone()).await.unwrap();
    assert_eq!(reply.changes["context-links/tasks:context-task"], 1);
    assert!(!reply.changes.contains_key("tasks/context-task"));
    send(&state, attach).await.unwrap();
    assert!(matches!(
        send(
            &state,
            operation(
                "stale",
                "/api/context-links/tasks%3Acontext-task",
                "PUT",
                links.clone(),
                0
            )
        )
        .await,
        Err(AppError::Conflict(_))
    ));
    assert!(matches!(
        send(
            &state,
            operation(
                "delete-used-contact",
                "/api/contacts/client",
                "DELETE",
                json!({}),
                1
            )
        )
        .await,
        Err(AppError::Invalid(_))
    ));
    assert!(matches!(
        send(
            &state,
            operation(
                "delete-used-context",
                "/api/contexts/matter",
                "DELETE",
                json!({}),
                1
            )
        )
        .await,
        Err(AppError::Invalid(_))
    ));
    // Defaults can change without bumping task/link versions; local overrides remain intact.
    let mut edited = context.clone();
    edited["fields"][0]["value"] = json!("NEW-SHARED");
    send(
        &state,
        operation("default", "/api/contexts/matter", "PUT", edited.clone(), 1),
    )
    .await
    .unwrap();
    let mut removing = edited.clone();
    removing["fields"].as_array_mut().unwrap().remove(0);
    assert!(matches!(
        send(
            &state,
            operation("remove-field", "/api/contexts/matter", "PUT", removing, 2)
        )
        .await,
        Err(AppError::Invalid(_))
    ));
    let mut options = edited.clone();
    options["fields"][2]["options"] = json!(["Local"]);
    assert!(matches!(
        send(
            &state,
            operation("remove-option", "/api/contexts/matter", "PUT", options, 2)
        )
        .await,
        Err(AppError::Invalid(_))
    ));
    for (field, value) in [
        ("client", "missing"),
        ("date", "2026-02-29"),
        ("repo", "javascript:alert(1)"),
        ("platform", "missing"),
        ("unknown", "text"),
    ] {
        let mut invalid = links.clone();
        invalid["overrides"]["matter"][field] = json!(value);
        assert!(matches!(
            send(
                &state,
                operation(
                    "invalid",
                    "/api/context-links/tasks%3Acontext-task",
                    "PUT",
                    invalid,
                    1
                )
            )
            .await,
            Err(AppError::Invalid(_))
        ));
    }
    let missing = json!({"id":"tasks:missing", "contextIds":["matter"], "overrides":{}});
    assert!(matches!(
        send(
            &state,
            operation(
                "missing",
                "/api/context-links/tasks%3Amissing",
                "PUT",
                missing,
                0
            )
        )
        .await,
        Err(AppError::NotFound(_))
    ));
    // A failed receipt rolls back the attachment and its revision together.
    sqlx::query("CREATE TRIGGER fail_context_receipt BEFORE INSERT ON sync_receipts BEGIN SELECT RAISE(ABORT, 'test'); END").execute(state.pool()).await.unwrap();
    let mut cleared = links.clone();
    cleared["overrides"]["matter"]["number"] = json!("");
    let clear = operation(
        "clear",
        "/api/context-links/tasks%3Acontext-task",
        "PUT",
        cleared,
        1,
    );
    assert!(send(&state, clear.clone()).await.is_err());
    assert_eq!(
        snapshot(state.pool()).await.unwrap().versions["context-links/tasks:context-task"],
        1
    );
    sqlx::query("DROP TRIGGER fail_context_receipt")
        .execute(state.pool())
        .await
        .unwrap();
    send(&state, clear).await.unwrap();
    state
        .tasks
        .toggle("context-task", true, None)
        .await
        .unwrap();
    let snap = snapshot(state.pool()).await.unwrap();
    let successor = snap
        .context_links
        .iter()
        .find(|l| l.id == "tasks:next:context-task")
        .unwrap();
    assert_eq!(successor.overrides["matter"]["number"], "");
    assert_eq!(successor.context_ids, ["matter"]);
    let delete = operation(
        "delete-task",
        "/api/tasks/context-task",
        "DELETE",
        json!({}),
        snap.versions["tasks/context-task"],
    );
    let reply = send(&state, delete.clone()).await.unwrap();
    assert_eq!(reply.changes["context-links/tasks:context-task"], 3);
    send(&state, delete).await.unwrap();
    state.tasks.delete("next:context-task").await.unwrap();
    assert!(snapshot(state.pool())
        .await
        .unwrap()
        .context_links
        .is_empty());
    let delete_context = operation(
        "delete-context",
        "/api/contexts/matter",
        "DELETE",
        json!({}),
        2,
    );
    send(&state, delete_context.clone()).await.unwrap();
    send(&state, delete_context).await.unwrap();
    send(
        &state,
        operation(
            "delete-contact",
            "/api/contacts/client",
            "DELETE",
            json!({}),
            1,
        ),
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn removing_direct_properties_preserves_statuses_contexts_and_legacy_replays() {
    let db = SqlitePoolOptions::new().max_connections(1).connect("sqlite::memory:").await.unwrap();
    for migration in sqlx::migrate!().iter().filter(|m| m.version < 13) {
        sqlx::raw_sql(migration.sql.clone()).execute(&db).await.unwrap();
    }
    sqlx::raw_sql(r#"
        INSERT INTO metadata_fields (id, name, kind, created_at) VALUES ('client', 'Client', 'text', '2026-01-01');
        INSERT INTO project_metadata VALUES ('inbox', 'client', 'Acme');
        INSERT INTO task_fields VALUES ('priority', 'Priority', 'text', '[]');
        INSERT INTO boards (id, name, field_id) VALUES ('priority', 'Priorities', 'priority');
        INSERT INTO tasks (id, title, project_id, created_at, updated_at, status_id, properties)
            VALUES ('old', 'Keep task', 'inbox', '2026-01-01', '2026-01-01', 'doing', '{"priority":"High"}');
        UPDATE task_fields SET options = '[{"id":"todo","name":"Ready"},{"id":"doing","name":"Working"},{"id":"complete","name":"Shipped"}]' WHERE id = 'status';
        INSERT INTO contexts VALUES ('client', '{"id":"client","name":"Client","fields":[{"id":"name","name":"Name","kind":"text","value":"Acme"}]}');
        INSERT INTO context_links (id, data, task_id) VALUES ('tasks:old', '{"id":"tasks:old","contextIds":["client"],"overrides":{}}', 'old');
    "#).execute(&db).await.unwrap();
    let state = AppState::new(db.clone());
    let mut legacy = task("old");
    legacy["properties"] = json!({"priority":"High"});
    let op = operation("old-create", "/api/tasks", "POST", legacy, 0);
    let mut result = serde_json::to_value(state.tasks.get("old").await.unwrap()).unwrap();
    result["properties"] = json!({"priority":"High"});
    sqlx::query("INSERT INTO sync_receipts (id, request, result, changes) VALUES (?, ?, ?, ?)")
        .bind(&op.id).bind(serde_json::to_string(&op).unwrap()).bind(result.to_string())
        .bind(r#"{"tasks/old":1}"#).execute(&db).await.unwrap();
    for migration in sqlx::migrate!().iter().filter(|m| m.version >= 13) {
        sqlx::raw_sql(migration.sql.clone()).execute(&db).await.unwrap();
    }
    let snapshot = send(&state, op).await.unwrap().snapshot.unwrap();
    assert_eq!(snapshot.tasks.len(), 1);
    assert_eq!(snapshot.tasks[0].status_id, "doing");
    assert_eq!(snapshot.tasks[0].title, "Keep task");
    assert_eq!(snapshot.task_fields.len(), 1);
    assert_eq!(snapshot.task_fields[0].options[2].name, "Shipped");
    assert_eq!(snapshot.boards.len(), 1);
    assert_eq!(snapshot.boards[0].field_id, "status");
    assert_eq!(snapshot.contexts[0].fields[0].value, "Acme");
    assert_eq!(snapshot.context_links[0].context_ids, vec!["client"]);
    assert_eq!(snapshot.versions["boards/priority"], 2);
    assert_eq!(snapshot.versions["task-fields/priority"], 2);
    assert!(sqlx::query("SELECT properties FROM tasks").execute(&db).await.is_err());
    assert!(sqlx::query("SELECT * FROM project_metadata").execute(&db).await.is_err());
    assert!(sqlx::query("SELECT * FROM metadata_fields").execute(&db).await.is_err());
    assert!(sqlx::query("INSERT INTO task_fields VALUES ('new', 'New', 'text', '[]')").execute(&db).await.is_err());
}
