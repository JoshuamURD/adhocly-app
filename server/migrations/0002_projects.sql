CREATE TABLE projects (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE CHECK (length(trim(name)) > 0),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- Seeded first so the backfill below and new tasks have a default project.
INSERT INTO projects (id, name, created_at, updated_at)
VALUES (
    'inbox',
    'Inbox',
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
);

-- One project per name already used by a task; 'Inbox' collides on name and is ignored.
INSERT OR IGNORE INTO projects (id, name, created_at, updated_at)
SELECT
    lower(hex(randomblob(16))),
    project,
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
    strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
FROM tasks
GROUP BY project;

-- Rebuilt rather than altered: SQLite refuses to add a REFERENCES column with a non-NULL default.
CREATE TABLE tasks_new (
    id TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
    project_id TEXT NOT NULL REFERENCES projects(id),
    planned_for TEXT,
    due_on TEXT,
    repeat_weekday INTEGER CHECK (repeat_weekday BETWEEN 0 AND 6),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1))
);

INSERT INTO tasks_new (
    id, title, project_id, planned_for, due_on, repeat_weekday, created_at, updated_at, completed
)
SELECT
    t.id,
    t.title,
    COALESCE((SELECT p.id FROM projects p WHERE p.name = t.project), 'inbox'),
    t.planned_for,
    t.due_on,
    t.repeat_weekday,
    t.created_at,
    t.updated_at,
    t.completed
FROM tasks t;

DROP TABLE tasks;
ALTER TABLE tasks_new RENAME TO tasks;
CREATE INDEX tasks_created_at ON tasks (created_at DESC);

CREATE TABLE metadata_fields (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL COLLATE NOCASE UNIQUE CHECK (length(trim(name)) > 0),
    kind TEXT NOT NULL CHECK (kind IN ('text', 'number', 'choice')),
    -- ponytail: choice options are '\n'-joined, so a single option cannot contain a newline.
    options TEXT NOT NULL DEFAULT '',
    created_at TEXT NOT NULL
);

CREATE TABLE project_metadata (
    project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    field_id TEXT NOT NULL REFERENCES metadata_fields(id) ON DELETE CASCADE,
    value TEXT NOT NULL,
    PRIMARY KEY (project_id, field_id)
);
