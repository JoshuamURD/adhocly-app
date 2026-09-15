SELECT
    t.id,
    t.title,
    t.project_id,
    p.name AS project,
    t.planned_for,
    t.due_on,
    t.repeat_weekday,
    t.created_at,
    t.updated_at,
    t.completed AS "completed: bool"
FROM tasks t
JOIN projects p ON p.id = t.project_id
ORDER BY t.created_at DESC, t.id DESC
