// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { dateFromToday, displayDate, todaySection } from "./task-views.ts";

test("Today groups planned and due tasks once, keeping overdue deadlines visible", () => {
  const today = "2026-04-02";
  assert.equal(todaySection({ plannedFor: today }, today), "Planned today");
  assert.equal(todaySection({ dueOn: today }, today), "Due today");
  assert.equal(todaySection({ dueOn: today, plannedFor: today }, today), "Due today");
  assert.equal(todaySection({ dueOn: "2026-04-01", plannedFor: today }, today), "Overdue");
  assert.equal(todaySection({ dueOn: "2026-04-03", plannedFor: today }, today), "Planned today");
  assert.equal(todaySection({ dueOn: "2026-04-03", plannedFor: "2026-04-03" }, today), null);
  assert.equal(todaySection({ plannedFor: "2026-04-01" }, today), null);
  assert.equal(todaySection({ dueOn: null, plannedFor: null }, today), null);
});

test("Names today and tomorrow, then falls back to a short date", () => {
  const now = new Date(2026, 3, 2, 23, 30);
  assert.equal(dateFromToday(now, 0), "2026-04-02");
  assert.equal(dateFromToday(now, 1), "2026-04-03");
  assert.equal(displayDate("2026-04-02", now), "Today");
  assert.equal(displayDate("2026-04-03", now), "Tomorrow");
  assert.match(displayDate("2026-04-09", now), /9/);
});
