-- Spawns the next occurrence of a repeating task, a week after the one being completed.
-- planned_for / due_on keep their wall-clock time; NULL stays NULL.
INSERT INTO tasks (
    id, title, details, project_id, planned_for, due_on, repeat_weekday, created_at, updated_at, completed, status_id, properties, reminders
)
SELECT
    ?,
    title,
    details,
    project_id,
    CASE WHEN planned_for IS NULL THEN NULL
         ELSE strftime('%Y-%m-%dT%H:%M', planned_for, '+7 days') END,
    CASE WHEN due_on IS NULL THEN NULL
         ELSE strftime('%Y-%m-%dT%H:%M', due_on, '+7 days') END,
    repeat_weekday,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    0,
    'todo',
    properties,
    -- Relative reminders follow the new occurrence; fixed calendar dates are one-off.
    (SELECT json_group_array(json(value)) FROM json_each(tasks.reminders)
     WHERE json_extract(value, '$.kind') != 'custom')
FROM tasks
WHERE id = ?
