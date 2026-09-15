// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { choiceOptions, isValidValue, normalizeOptions, optionKey, valueFor, valuesFor } from "./metadata.ts";

function field(kind, options = []) {
  return { id: `field-${kind}`, name: kind, kind, options, createdAt: "2026-01-01" };
}

function project(metadata) {
  return { id: "project-1", name: "Website", createdAt: "2026-01-01", updatedAt: "2026-01-01", metadata };
}

test("validates values the way the API does", () => {
  const budget = field("number");
  assert.equal(isValidValue(budget, "1200"), true);
  assert.equal(isValidValue(budget, "-1.5"), true);
  assert.equal(isValidValue(budget, " 42 "), true);
  assert.equal(isValidValue(budget, "1e3"), true);
  assert.equal(isValidValue(budget, "abc"), false);
  assert.equal(isValidValue(budget, "Infinity"), false);
  assert.equal(isValidValue(budget, "12px"), false);

  const client = field("text");
  assert.equal(isValidValue(client, "anything at all"), true);

  const status = field("choice", ["Active", "Paused"]);
  assert.equal(isValidValue(status, "Paused"), true);
  assert.equal(isValidValue(status, "paused"), false);
  assert.equal(isValidValue(status, "Archived"), false);

  // Blank always means "clear", whichever the kind.
  for (const value of [budget, client, status]) assert.equal(isValidValue(value, "   "), true);
});

test("normalizes typed options the way the API does", () => {
  assert.deepEqual(normalizeOptions(["High", " Medium ", "", "   ", "High"]), ["High", "Medium"]);
  assert.deepEqual(normalizeOptions([""]), []);
  assert.deepEqual(normalizeOptions([]), []);
});

test("moves and deletes option rows on Enter and Backspace", () => {
  // Enter on the last row opens a new one; anywhere else it steps forward.
  assert.equal(optionKey("Enter", "High", 2, 3), "append");
  assert.equal(optionKey("Enter", "High", 1, 3), "next");
  assert.equal(optionKey("Enter", "High", 0, 1), "append");

  // Backspace only deletes an empty row, and never the last one.
  assert.equal(optionKey("Backspace", "", 1, 3), "back");
  assert.equal(optionKey("Backspace", "Hig", 1, 3), null);
  assert.equal(optionKey("Backspace", "", 0, 1), null);

  assert.equal(optionKey("a", "H", 0, 1), null);
  assert.equal(optionKey("Tab", "", 0, 2), null);
});

test("keeps a stored choice value visible after the options change", () => {
  const status = field("choice", ["Active"]);
  assert.deepEqual(choiceOptions(status, "Active"), ["Active"]);
  assert.deepEqual(choiceOptions(status, ""), ["Active"]);
  assert.deepEqual(choiceOptions(status, "Paused"), ["Active", "Paused"]);
});

test("reads values out of a project", () => {
  const website = project([{ fieldId: "budget", value: "1200" }]);
  assert.equal(valueFor(website, "budget"), "1200");
  assert.equal(valueFor(website, "missing"), "");
  assert.equal(valueFor(undefined, "budget"), "");
  assert.deepEqual([...valuesFor(website)], [["budget", "1200"]]);
  assert.equal(valuesFor(undefined).size, 0);
});
