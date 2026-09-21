UPDATE tasks SET
    title = ?,
    details = ?,
    project_id = ?,
    planned_for = ?,
    due_on = ?,
    repeat_weekday = ?,
    completed = ?,
    status_id = ?,
    reminders = ?,
    updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
WHERE id = ?
