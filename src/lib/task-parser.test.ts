// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { parseTaskInput } from "./task-parser.ts";

const monday = new Date(2026, 2, 2, 9);

test("parses task metadata and leaves unknown tokens alone", () => {
  assert.deepEqual(parseTaskInput("Ship brief #Client_Work @tomorrow !friday", monday), {
    title: "Ship brief",
    project: "Client Work",
    plannedFor: "2026-03-03T09:00",
    dueOn: "2026-03-06T09:00",
    repeatWeekday: null,
  });
  assert.equal(parseTaskInput("Email @someone", monday).title, "Email @someone");
  assert.equal(parseTaskInput("Plan @monday", monday).plannedFor, "2026-03-02T09:00");
});

test("parses prefixed relative dates", () => {
  assert.deepEqual(parseTaskInput("Ship @in two weeks", monday), {
    title: "Ship",
    project: null,
    plannedFor: "2026-03-16T09:00",
    dueOn: null,
    repeatWeekday: null,
  });
  assert.equal(parseTaskInput("Ship !in 2 days", monday).dueOn, "2026-03-04T09:00");
  assert.equal(parseTaskInput("Ship @next monday", new Date(2026, 2, 3)).plannedFor, "2026-03-09T09:00");
  // Sunday: "next monday" is the one coming tomorrow.
  assert.equal(parseTaskInput("Ship @next monday", new Date(2026, 2, 8)).plannedFor, "2026-03-09T09:00");
  assert.equal(parseTaskInput("Ship @in one month", monday).plannedFor, "2026-04-02T09:00");
  assert.equal(parseTaskInput("Ship @in one year", monday).plannedFor, "2027-03-02T09:00");
  assert.equal(parseTaskInput("Ship in two weeks", monday).title, "Ship in two weeks");
});

test("reads date phrases chrono knows beyond our own vocabulary", () => {
  assert.equal(parseTaskInput("Ship @jul 4", monday).plannedFor, "2026-07-04T09:00");
  assert.equal(parseTaskInput("Ship @friday at 5pm", monday).plannedFor, "2026-03-06T17:00");
  assert.equal(parseTaskInput("Ship @march 3rd 2pm", monday).plannedFor, "2026-03-03T14:00");
  assert.equal(parseTaskInput("Standup @9am tomorrow", monday).plannedFor, "2026-03-03T09:00");
  assert.equal(parseTaskInput("Ship @end of day", monday).title, "Ship @end of day");
});

test("parses a time on a date and defaults to 9am", () => {
  const now = new Date(2026, 2, 2, 10, 30);
  assert.equal(parseTaskInput("Ship @tomorrow 3pm", now).plannedFor, "2026-03-03T15:00");
  assert.equal(parseTaskInput("Ship @tomorrow 3 pm", now).plannedFor, "2026-03-03T15:00");
  assert.equal(parseTaskInput("Ship @tomorrow 14:30", now).plannedFor, "2026-03-03T14:30");
  assert.equal(parseTaskInput("Ship !friday 9:05", now).dueOn, "2026-03-06T09:05");
  assert.equal(parseTaskInput("Ship @tomorrow 12am", now).plannedFor, "2026-03-03T00:00");
  assert.equal(parseTaskInput("Ship @tomorrow 12pm", now).plannedFor, "2026-03-03T12:00");
  assert.equal(parseTaskInput("Ship @every friday 8am", now).plannedFor, "2026-03-06T08:00");
  assert.equal(parseTaskInput("Ship @tomorrow", now).plannedFor, "2026-03-03T09:00");
  assert.equal(parseTaskInput("Ship @tomorrow 3pm", now).title, "Ship");
});

test("a bare time means the next one to come", () => {
  const morning = new Date(2026, 2, 2, 8, 0);
  const later = new Date(2026, 2, 2, 10, 30);
  assert.equal(parseTaskInput("Standup @9am", morning).plannedFor, "2026-03-02T09:00");
  assert.equal(parseTaskInput("Standup @9am", later).plannedFor, "2026-03-03T09:00");
  assert.equal(parseTaskInput("Standup @9:00", new Date(2026, 2, 2, 9, 0)).plannedFor, "2026-03-02T09:00");
  assert.equal(parseTaskInput("Send report !5pm", later).dueOn, "2026-03-02T17:00");
  assert.equal(parseTaskInput("Send report !9:15", later).dueOn, "2026-03-03T09:15");
  assert.equal(parseTaskInput("Standup @9am", later).title, "Standup");
});

test("parses weekly repeats", () => {
  assert.deepEqual(parseTaskInput("Review @every friday", monday), {
    title: "Review",
    project: null,
    plannedFor: "2026-03-06T09:00",
    dueOn: null,
    repeatWeekday: 5,
  });
  assert.equal(parseTaskInput("Review !every friday", monday).dueOn, "2026-03-06T09:00");
  assert.equal(parseTaskInput("Review @every monday 8am", monday).repeatWeekday, 1);
});
