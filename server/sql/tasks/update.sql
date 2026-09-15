UPDATE tasks SET
    title = ?,
    project_id = ?,
    planned_for = ?,
    due_on = ?,
    repeat_weekday = ?,
    completed = ?,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE id = ?
