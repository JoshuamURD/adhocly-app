-- Custom properties now belong to contexts. Status remains shared task configuration.
-- Keep revision tombstones so stale clients cannot resurrect removed boards/fields.
DELETE FROM boards WHERE field_id != 'status';
DELETE FROM task_fields WHERE id != 'status';
DROP TABLE project_metadata;
DROP TABLE metadata_fields;
ALTER TABLE tasks DROP COLUMN properties;

CREATE TRIGGER task_status_configuration_insert BEFORE INSERT ON task_fields
WHEN NEW.id != 'status' OR NEW.kind != 'choice' BEGIN
    SELECT RAISE(ABORT, 'only task statuses are supported');
END;
CREATE TRIGGER task_status_configuration_update BEFORE UPDATE ON task_fields
WHEN NEW.id != 'status' OR NEW.kind != 'choice' BEGIN
    SELECT RAISE(ABORT, 'only task statuses are supported');
END;
