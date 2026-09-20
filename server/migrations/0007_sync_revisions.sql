-- A metadata value gets its own revision instead of bumping its project's revision, so editing a value
-- on one device no longer invalidates an unrelated rename or folder move queued against the project row.
DROP TRIGGER sync_metadata_insert;
DROP TRIGGER sync_metadata_update;
DROP TRIGGER sync_metadata_delete;
INSERT INTO sync_versions
SELECT 'projects/' || project_id || '/metadata/' || field_id, 1 FROM project_metadata;
CREATE TRIGGER sync_metadata_insert AFTER INSERT ON project_metadata BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || NEW.project_id || '/metadata/' || NEW.field_id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_metadata_update AFTER UPDATE ON project_metadata BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || NEW.project_id || '/metadata/' || NEW.field_id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_metadata_delete AFTER DELETE ON project_metadata BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || OLD.project_id || '/metadata/' || OLD.field_id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
