-- `completed` is INTEGER in SQLite, which sqlx would infer as i64; the annotation maps it to
-- the Rust bool field. It must stay on the column for query_file_as(Task, ..) to compile.
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
WHERE t.id = ?
