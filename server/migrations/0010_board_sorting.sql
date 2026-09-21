ALTER TABLE boards ADD COLUMN sort_mode TEXT NOT NULL DEFAULT 'created'
    CHECK (sort_mode IN ('due', 'planned', 'created', 'alphabetical', 'manual'));
ALTER TABLE boards ADD COLUMN manual_order TEXT NOT NULL DEFAULT '[]'
    CHECK (json_valid(manual_order) AND json_type(manual_order) = 'array');
