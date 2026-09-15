-- Spawns the next occurrence of a repeating task, a week after the one being completed.
-- planned_for / due_on keep their wall-clock time; NULL stays NULL.
INSERT INTO tasks (
    id, title, project_id, planned_for, due_on, repeat_weekday, created_at, updated_at, completed
)
SELECT
    ?,
    title,
    project_id,
    CASE WHEN planned_for IS NULL THEN NULL
         ELSE strftime('%Y-%m-%dT%H:%M', planned_for, '+7 days') END,
    CASE WHEN due_on IS NULL THEN NULL
         ELSE strftime('%Y-%m-%dT%H:%M', due_on, '+7 days') END,
    repeat_weekday,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    0
FROM tasks
WHERE id = ?
