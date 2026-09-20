CREATE TABLE sync_versions (key TEXT PRIMARY KEY NOT NULL, version INTEGER NOT NULL);
CREATE TABLE sync_receipts (
    id TEXT PRIMARY KEY NOT NULL,
    request TEXT NOT NULL,
    result TEXT NOT NULL,
    changes TEXT NOT NULL
);
-- Receipts/tombstones cannot expire until all devices have acknowledged them.
INSERT INTO sync_versions SELECT 'tasks/' || id, 1 FROM tasks;
CREATE TRIGGER sync_tasks_insert AFTER INSERT ON tasks BEGIN
    INSERT INTO sync_versions VALUES ('tasks/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_tasks_update AFTER UPDATE ON tasks BEGIN
    INSERT INTO sync_versions VALUES ('tasks/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_tasks_delete AFTER DELETE ON tasks BEGIN
    INSERT INTO sync_versions VALUES ('tasks/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
INSERT INTO sync_versions SELECT 'projects/' || id, 1 FROM projects;
CREATE TRIGGER sync_projects_insert AFTER INSERT ON projects BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_projects_update AFTER UPDATE ON projects BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_projects_delete AFTER DELETE ON projects BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
INSERT INTO sync_versions SELECT 'folders/' || id, 1 FROM folders;
CREATE TRIGGER sync_folders_insert AFTER INSERT ON folders BEGIN
    INSERT INTO sync_versions VALUES ('folders/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_folders_update AFTER UPDATE ON folders BEGIN
    INSERT INTO sync_versions VALUES ('folders/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_folders_delete AFTER DELETE ON folders BEGIN
    INSERT INTO sync_versions VALUES ('folders/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
INSERT INTO sync_versions SELECT 'metadata-fields/' || id, 1 FROM metadata_fields;
CREATE TRIGGER sync_metadata_fields_insert AFTER INSERT ON metadata_fields BEGIN
    INSERT INTO sync_versions VALUES ('metadata-fields/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_metadata_fields_update AFTER UPDATE ON metadata_fields BEGIN
    INSERT INTO sync_versions VALUES ('metadata-fields/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_metadata_fields_delete AFTER DELETE ON metadata_fields BEGIN
    INSERT INTO sync_versions VALUES ('metadata-fields/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_metadata_insert AFTER INSERT ON project_metadata BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || NEW.project_id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_metadata_update AFTER UPDATE ON project_metadata BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || NEW.project_id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_metadata_delete AFTER DELETE ON project_metadata BEGIN
    INSERT INTO sync_versions VALUES ('projects/' || OLD.project_id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
