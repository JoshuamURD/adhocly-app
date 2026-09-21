CREATE TABLE task_fields (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE CHECK (length(trim(name)) > 0),
    kind TEXT NOT NULL CHECK (kind IN ('text', 'number', 'choice')),
    options TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(options))
);
INSERT INTO task_fields VALUES ('status', 'Status', 'choice',
    '[{"id":"todo","name":"To do"},{"id":"doing","name":"In progress"},{"id":"complete","name":"Complete"}]');

ALTER TABLE tasks ADD COLUMN status_id TEXT NOT NULL DEFAULT 'todo';
ALTER TABLE tasks ADD COLUMN properties TEXT NOT NULL DEFAULT '{}' CHECK (json_valid(properties));
UPDATE tasks SET status_id = 'complete' WHERE completed = 1;

-- All API writers (including old clients that only send completed) resolve status and
-- completion together. Reject inconsistent writes rather than silently splitting the two.
CREATE TRIGGER tasks_status_insert BEFORE INSERT ON tasks
WHEN NEW.completed != (NEW.status_id = 'complete') BEGIN
    SELECT RAISE(ABORT, 'status and completion must agree');
END;
CREATE TRIGGER tasks_status_update BEFORE UPDATE ON tasks
WHEN NEW.completed != (NEW.status_id = 'complete') BEGIN
    SELECT RAISE(ABORT, 'status and completion must agree');
END;

CREATE TABLE boards (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL CHECK (length(trim(name)) > 0),
    field_id TEXT NOT NULL REFERENCES task_fields(id)
);
INSERT INTO boards VALUES ('status', 'By status', 'status');

INSERT INTO sync_versions SELECT 'task-fields/' || id, 1 FROM task_fields;
INSERT INTO sync_versions SELECT 'boards/' || id, 1 FROM boards;
CREATE TRIGGER sync_task_fields_insert AFTER INSERT ON task_fields BEGIN
    INSERT INTO sync_versions VALUES ('task-fields/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_task_fields_update AFTER UPDATE ON task_fields BEGIN
    INSERT INTO sync_versions VALUES ('task-fields/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_task_fields_delete AFTER DELETE ON task_fields BEGIN
    INSERT INTO sync_versions VALUES ('task-fields/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_boards_insert AFTER INSERT ON boards BEGIN
    INSERT INTO sync_versions VALUES ('boards/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_boards_update AFTER UPDATE ON boards BEGIN
    INSERT INTO sync_versions VALUES ('boards/' || NEW.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
CREATE TRIGGER sync_boards_delete AFTER DELETE ON boards BEGIN
    INSERT INTO sync_versions VALUES ('boards/' || OLD.id, 1)
    ON CONFLICT(key) DO UPDATE SET version = version + 1;
END;
