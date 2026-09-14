CREATE TABLE tasks (
    id TEXT PRIMARY KEY NOT NULL,
    title TEXT NOT NULL CHECK (length(trim(title)) > 0),
    project TEXT NOT NULL DEFAULT 'Inbox',
    planned_for TEXT,
    due_on TEXT,
    repeat_weekday INTEGER CHECK (repeat_weekday BETWEEN 0 AND 6),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    completed INTEGER NOT NULL DEFAULT 0 CHECK (completed IN (0, 1))
);

CREATE INDEX tasks_created_at ON tasks (created_at DESC);
