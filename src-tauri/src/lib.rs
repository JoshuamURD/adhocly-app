use tauri::Emitter;
use tauri_plugin_sql::{Migration, MigrationKind};

#[tauri::command]
fn is_ios() -> bool {
    cfg!(target_os = "ios")
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let migrations = vec![Migration {
        version: 1,
        description: "offline_cache_and_outbox",
        sql: "CREATE TABLE cache (url TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL, status INTEGER NOT NULL);\n\
              CREATE TABLE outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL, method TEXT NOT NULL, headers TEXT NOT NULL, body TEXT);",
        kind: MigrationKind::Up,
    }];

    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(
            tauri_plugin_sql::Builder::default()
                .add_migrations("sqlite:adhocly-offline.db", migrations)
                .build(),
        )
        .invoke_handler(tauri::generate_handler![is_ios])
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Resumed) {
                let _ = app.emit("adhocly:resume", ());
            }
        });
}
