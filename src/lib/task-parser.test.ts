// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { nextWeeklyDate, parseTaskInput } from "./task-parser.ts";

const monday = new Date(2026, 2, 2, 9);

test("parses task metadata and leaves unknown tokens alone", () => {
  assert.deepEqual(parseTaskInput("Ship brief #Client_Work @tomorrow !friday", monday), {
    title: "Ship brief",
    project: "Client Work",
    plannedFor: "2026-03-03",
    dueOn: "2026-03-06",
    repeatWeekday: null,
  });
  assert.equal(parseTaskInput("Email @someone", monday).title, "Email @someone");
  assert.equal(parseTaskInput("Plan @monday", monday).plannedFor, "2026-03-09");
});

test("parses prefixed relative dates", () => {
  assert.deepEqual(parseTaskInput("Ship @in two weeks", monday), {
    title: "Ship",
    project: null,
    plannedFor: "2026-03-16",
    dueOn: null,
    repeatWeekday: null,
  });
  assert.equal(parseTaskInput("Ship !in 2 days", monday).dueOn, "2026-03-04");
  assert.equal(parseTaskInput("Ship @next monday", new Date(2026, 2, 3)).plannedFor, "2026-03-09");
  assert.equal(parseTaskInput("Ship @next monday", new Date(2026, 2, 8)).plannedFor, "2026-03-16");
  assert.equal(parseTaskInput("Ship @in one month", monday).plannedFor, "2026-04-02");
  assert.equal(parseTaskInput("Ship @in one year", monday).plannedFor, "2027-03-02");
  assert.equal(parseTaskInput("Ship in two weeks", monday).title, "Ship in two weeks");
});

test("parses and advances weekly repeats", () => {
  assert.deepEqual(parseTaskInput("Review @every friday", monday), {
    title: "Review",
    project: null,
    plannedFor: "2026-03-06",
    dueOn: null,
    repeatWeekday: 5,
  });
  assert.equal(parseTaskInput("Review !every friday", monday).dueOn, "2026-03-06");
  assert.equal(nextWeeklyDate("2026-03-06"), "2026-03-13");
});
