INSERT INTO project_metadata (project_id, field_id, value)
VALUES (?, ?, ?)
ON CONFLICT (project_id, field_id) DO UPDATE SET value = excluded.value
