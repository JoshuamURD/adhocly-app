-- planned_for/due_on now hold a local wall-clock time as 'YYYY-MM-DDTHH:MM'.
-- Existing date-only rows get the same 09:00 default quick capture uses.
UPDATE tasks SET planned_for = planned_for || 'T09:00'
WHERE planned_for IS NOT NULL AND length(planned_for) = 10;

UPDATE tasks SET due_on = due_on || 'T09:00'
WHERE due_on IS NOT NULL AND length(due_on) = 10;
