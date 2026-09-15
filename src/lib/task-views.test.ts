// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { dateFromToday, displayDate, todaySection } from "./task-views.ts";

test("Today groups planned and due tasks once, keeping overdue deadlines visible", () => {
  const today = "2026-04-02";
  assert.equal(todaySection({ plannedFor: `${today}T09:00` }, today), "Planned today");
  assert.equal(todaySection({ dueOn: `${today}T09:00` }, today), "Due today");
  assert.equal(todaySection({ dueOn: `${today}T09:00`, plannedFor: `${today}T09:00` }, today), "Due today");
  assert.equal(todaySection({ dueOn: "2026-04-01T09:00", plannedFor: `${today}T09:00` }, today), "Overdue");
  assert.equal(todaySection({ dueOn: "2026-04-03T09:00", plannedFor: `${today}T09:00` }, today), "Planned today");
  assert.equal(todaySection({ dueOn: "2026-04-03T09:00", plannedFor: "2026-04-03T09:00" }, today), null);
  assert.equal(todaySection({ plannedFor: "2026-04-01T09:00" }, today), null);
  assert.equal(todaySection({ dueOn: null, plannedFor: null }, today), null);
});

test("Names today and tomorrow, then falls back to a short date and time", () => {
  const now = new Date(2026, 3, 2, 23, 30);
  assert.equal(dateFromToday(now, 0), "2026-04-02");
  assert.equal(dateFromToday(now, 1), "2026-04-03");
  assert.equal(displayDate("2026-04-02", now), "Today");
  assert.equal(displayDate("2026-04-03", now), "Tomorrow");
  assert.match(displayDate("2026-04-02T09:00", now), /^Today \d{1,2}:00/);
  assert.match(displayDate("2026-04-09T14:30", now), /^Apr 9 \d{1,2}:30/);
});
