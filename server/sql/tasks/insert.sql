INSERT INTO tasks (
    id, title, project_id, planned_for, due_on, repeat_weekday, created_at, updated_at, completed
) VALUES (
    ?, ?, ?, ?, ?, ?,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    ?
)
