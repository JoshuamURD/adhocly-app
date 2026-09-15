-- kind is immutable after creation; only name and options change.
UPDATE metadata_fields
SET name = ?, options = ?
WHERE id = ?
RETURNING id, name, kind, options, created_at
