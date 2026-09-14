// @ts-nocheck
import assert from "node:assert/strict";
import test from "node:test";
import { parseTaskInput } from "./task-parser.js";

const monday = new Date(2026, 2, 2, 9);

test("parses task metadata and leaves unknown tokens alone", () => {
  assert.deepEqual(parseTaskInput("Ship brief #Client_Work @tomorrow !friday", monday), {
    title: "Ship brief",
    project: "Client Work",
    plannedFor: "2026-03-03",
    dueOn: "2026-03-06",
  });
  assert.equal(parseTaskInput("Email @someone", monday).title, "Email @someone");
  assert.equal(parseTaskInput("Plan @monday", monday).plannedFor, "2026-03-09");
});
