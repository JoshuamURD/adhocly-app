CREATE TABLE folders (
    id TEXT PRIMARY KEY NOT NULL,
    name TEXT NOT NULL COLLATE NOCASE CHECK (length(trim(name)) > 0),
    -- NULL is the top level; the repository reparents children before deleting a folder.
    parent_id TEXT REFERENCES folders(id),
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

-- One name per level. `ifnull` because SQLite treats NULLs in a UNIQUE index as distinct,
-- which would let two top-level folders share a name.
CREATE UNIQUE INDEX folders_sibling_names ON folders (ifnull(parent_id, ''), name);
CREATE INDEX folders_parent_id ON folders (parent_id);

-- SQLite only adds a REFERENCES column while foreign keys are on when the default is NULL.
ALTER TABLE projects ADD COLUMN folder_id TEXT REFERENCES folders(id) ON DELETE SET NULL;
CREATE INDEX projects_folder_id ON projects (folder_id);
