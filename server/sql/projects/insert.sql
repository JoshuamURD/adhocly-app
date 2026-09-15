INSERT INTO projects (id, name, created_at, updated_at)
VALUES (
    ?, ?,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
)
