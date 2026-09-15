INSERT INTO metadata_fields (id, name, kind, options, created_at)
VALUES (?, ?, ?, ?, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
RETURNING id, name, kind, options, created_at
