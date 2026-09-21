-- Custom reminders travel with the task through the existing revisioned sync protocol.
-- The legacy task_reminders lookup table remains available to older clients.
ALTER TABLE tasks ADD COLUMN reminders TEXT NOT NULL DEFAULT '[]'
    CHECK (json_valid(reminders) AND json_type(reminders) = 'array');
