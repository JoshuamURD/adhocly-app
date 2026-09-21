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
        ..
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
        status_id: None,
        reminders: None,
        details: None,
    };
    let (_, Json(created)) = create_task(State(state.clone()), Json(input))
        .await
        .unwrap();
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
        Json(ToggleInput {
            completed: true,
            next_id: Some("next:task-1".into()),
        }),
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
    assert_eq!(next.id, "next:task-1");
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
        status_id: None,
        reminders: None,
        details: None,
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

    // Completing through PUT also creates the next recurrence.
    delete_task(Path(format!("next:{}", updated.id)), State(state.clone()))
        .await
        .unwrap();
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
        status_id: None,
        reminders: None,
        details: None,
    };
    let error = create_task(State(state.clone()), Json(input))
        .await
        .unwrap_err();
    assert_eq!(error.to_string(), "project does not exist");

    let Json(tasks) = list_tasks(State(state)).await.unwrap();
    assert!(tasks.is_empty());
}

#[tokio::test]
async fn custom_reminders_round_trip_preserve_legacy_edits_and_validate() {
    use serde_json::json;
    let state = AppState::new(test_db().await);
    let mut input = json!({
        "id":"reminders", "title":"Reminders", "details":"Long description\nWith notes.", "projectId":"inbox", "completed":false,
        "plannedFor":"2026-04-01T09:00", "dueOn":"2026-04-02T09:00", "repeatWeekday":3,
        "reminders":[
            {"id":"fixed", "kind":"custom", "at":"2026-03-30T10:00", "urgent":true},
            {"id":"relative", "kind":"due", "offsetMinutes":1440, "urgent":false},
            {"id":"months", "kind":"planned", "offsetUnit":"months", "offsetValue":3}
        ]
    });
    let (_, Json(created)) = create_task(State(state.clone()), Json(serde_json::from_value(input.clone()).unwrap())).await.unwrap();
    assert_eq!(created.reminders.len(), 3);
    assert_eq!(created.details, "Long description\nWith notes.");
    assert!(created.reminders[0].urgent);
    let Json(fetched) = get_task(Path(created.id.clone()), State(state.clone())).await.unwrap();
    assert_eq!(serde_json::to_value(&fetched.reminders).unwrap(), serde_json::to_value(&created.reminders).unwrap());
    input.as_object_mut().unwrap().remove("reminders");
    input.as_object_mut().unwrap().remove("details");
    let Json(legacy) = update_task(Path(created.id.clone()), State(state.clone()), Json(serde_json::from_value(input.clone()).unwrap())).await.unwrap();
    assert_eq!(legacy.details, created.details);
    assert_eq!(legacy.reminders.len(), 3, "old clients must not delete reminders");

    let Json(result) = toggle_task(Path(created.id.clone()), State(state.clone()), Json(ToggleInput { completed:true, next_id:None })).await.unwrap();
    let next = result.next_task.unwrap();
    assert_eq!(next.details, created.details);
    assert_eq!(next.reminders.len(), 2);
    assert_eq!(next.reminders[1].offset_value, Some(3));
    assert_eq!(next.reminders[0].id, "relative");
    assert_eq!(next.due_on.as_deref(), Some("2026-04-09T09:00"));

    let invalid = [
        json!([{"id":"x","kind":"custom","at":"2026-01-01T09:00","offsetUnit":"days","offsetValue":1}]),
        json!([{"id":"x","kind":"due","offsetUnit":"days"}]),
        json!([{"id":"x","kind":"due","offsetValue":1}]),
        json!([{"id":"x","kind":"due","offsetUnit":"days","offsetValue":0}]),
        json!([{"id":"x","kind":"due","offsetUnit":"weeks","offsetValue":-1}]),
        json!([{"id":"x","kind":"due","offsetUnit":"months","offsetValue":1000}]),
        json!([{"id":"x","kind":"due","offsetUnit":"hours","offsetValue":1,"offsetMinutes":60}]),
        json!([{"id":"x","kind":"custom","at":"2026-02-30T09:00"}]),
        json!([{"id":"x","kind":"custom","at":"2026-01-01T25:00"}]),
        json!([{"id":"x","kind":"custom","at":"2026-01-01T09:00","offsetMinutes":60}]),
        json!([{"id":"x","kind":"planned","offsetMinutes":0}]),
        json!([{"id":"x","kind":"due","offsetMinutes":-60}]),
        json!([{"id":"x","kind":"due"}]),
        json!([{"id":"","kind":"due","offsetMinutes":60}]),
        json!([{"id":"x","kind":"due","offsetMinutes":60},{"id":"x","kind":"due","offsetMinutes":1440}]),
    ];
    for reminders in invalid {
        input["reminders"] = reminders;
        assert!(update_task(Path(created.id.clone()), State(state.clone()), Json(serde_json::from_value(input.clone()).unwrap())).await.is_err(), "{input}");
        assert_eq!(state.tasks.get(&created.id).await.unwrap().reminders.len(), 3);
    }
    for unit in ["minutes", "hours", "days", "weeks", "months"] {
        input["reminders"] = json!([{"id":"units","kind":"due","offsetUnit":unit,"offsetValue":4}]);
        let Json(updated) = update_task(Path(created.id.clone()), State(state.clone()), Json(serde_json::from_value(input.clone()).unwrap())).await.unwrap();
        assert_eq!(serde_json::to_value(&updated.reminders).unwrap()[0]["offsetUnit"], unit);
        assert_eq!(updated.reminders[0].offset_value, Some(4));
    }
    input["details"] = json!("");
    input["reminders"] = json!([]);
    let Json(cleared) = update_task(Path(created.id.clone()), State(state.clone()), Json(serde_json::from_value(input).unwrap())).await.unwrap();
    assert!(cleared.details.is_empty());
    assert!(cleared.reminders.is_empty());
}
