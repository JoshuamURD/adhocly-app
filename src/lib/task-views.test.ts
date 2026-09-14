// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { todaySection } from "./task-views.ts";

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
