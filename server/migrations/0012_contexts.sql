-- Context schemas and shared contacts are small JSON documents, independently revisioned.
CREATE TABLE contexts (id TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE contacts (id TEXT PRIMARY KEY NOT NULL, data TEXT NOT NULL CHECK(json_valid(data)));
CREATE TABLE context_links (
    id TEXT PRIMARY KEY NOT NULL,
    data TEXT NOT NULL CHECK(json_valid(data)),
    task_id TEXT REFERENCES tasks(id) ON DELETE CASCADE,
    project_id TEXT REFERENCES projects(id) ON DELETE CASCADE,
    folder_id TEXT REFERENCES folders(id) ON DELETE CASCADE,
    CHECK((task_id IS NOT NULL) + (project_id IS NOT NULL) + (folder_id IS NOT NULL) = 1)
);
CREATE INDEX context_links_task ON context_links(task_id);
CREATE INDEX context_links_project ON context_links(project_id);
CREATE INDEX context_links_folder ON context_links(folder_id);
CREATE TRIGGER sync_contexts_insert AFTER INSERT ON contexts BEGIN
    INSERT INTO sync_versions VALUES ('contexts/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_contexts_update AFTER UPDATE ON contexts BEGIN
    INSERT INTO sync_versions VALUES ('contexts/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_contexts_delete AFTER DELETE ON contexts BEGIN
    INSERT INTO sync_versions VALUES ('contexts/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_contacts_insert AFTER INSERT ON contacts BEGIN
    INSERT INTO sync_versions VALUES ('contacts/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_contacts_update AFTER UPDATE ON contacts BEGIN
    INSERT INTO sync_versions VALUES ('contacts/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_contacts_delete AFTER DELETE ON contacts BEGIN
    INSERT INTO sync_versions VALUES ('contacts/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_context_links_insert AFTER INSERT ON context_links BEGIN
    INSERT INTO sync_versions VALUES ('context-links/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_context_links_update AFTER UPDATE ON context_links BEGIN
    INSERT INTO sync_versions VALUES ('context-links/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_context_links_delete AFTER DELETE ON context_links BEGIN
    INSERT INTO sync_versions VALUES ('context-links/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
