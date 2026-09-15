// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { isZoomShortcut } from "./zoom.ts";

function key(key, { ctrl = false, meta = false } = {}) {
  return { key, ctrlKey: ctrl, metaKey: meta };
}

test("blocks every zoom shortcut and nothing else", () => {
  for (const stroke of ["+", "-", "=", "_", "0"]) {
    assert.equal(isZoomShortcut(key(stroke, { ctrl: true })), true);
    assert.equal(isZoomShortcut(key(stroke, { meta: true })), true);
    assert.equal(isZoomShortcut(key(stroke)), false, `plain ${stroke} stays available`);
  }

  for (const stroke of ["a", "d", "s", "1", "3", "ArrowUp", "PageDown"]) {
    assert.equal(isZoomShortcut(key(stroke, { ctrl: true })), false, `ctrl+${stroke} stays available`);
  }
});
