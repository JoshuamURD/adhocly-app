// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { reduceOffline, type OfflineSnapshot } from "./api-fetch.ts";

const now = "2026-04-01T12:00:00.000Z";

function apply(state: OfflineSnapshot, url: string, method: string, body?: object) {
  return reduceOffline(state, url, method, body && JSON.stringify(body), now);
}

test("offline reducer applies each current resource type and stable recurring ids", () => {
  let state: OfflineSnapshot = {
    tasks: [],
    projects: [{ id: "inbox", name: "Inbox", folderId: null, metadata: [] }],
    folders: [],
    fields: [],
  };

  let result = apply(state, "/api/folders", "POST", { id: "folder-1", name: "Work", parentId: null });
  state = result.snapshot;
  result = apply(state, "/api/projects", "POST", { id: "project-1", name: "Client" });
  state = result.snapshot;
  result = apply(state, "/api/projects/project-1/folder", "PUT", { folderId: "folder-1" });
  state = result.snapshot;
  result = apply(state, "/api/metadata-fields", "POST", {
    id: "field-1",
    name: "Status",
    kind: "choice",
    options: ["Active"],
  });
  state = result.snapshot;
  result = apply(state, "/api/projects/project-1/metadata/field-1", "PUT", { value: "Active" });
  state = result.snapshot;
  result = apply(state, "/api/tasks", "POST", {
    id: "task-1",
    title: "Call client",
    projectId: "project-1",
    plannedFor: "2026-04-01T09:00",
    dueOn: null,
    repeatWeekday: 3,
    completed: false,
  });
  state = result.snapshot;
  result = apply(state, "/api/tasks/task-1/toggle", "POST", { completed: true, nextId: "next:task-1" });
  state = result.snapshot;

  assert.equal(state.projects[1].folderId, "folder-1");
  assert.deepEqual(state.projects[1].metadata, [{ fieldId: "field-1", value: "Active" }]);
  assert.equal(state.tasks[0].id, "next:task-1");
  assert.equal(state.tasks[0].plannedFor, "2026-04-08T09:00");
  assert.equal(JSON.parse(result.body).nextId, "next:task-1");

  state = apply(state, "/api/folders/folder-1", "DELETE").snapshot;
  state = apply(state, "/api/metadata-fields/field-1", "DELETE").snapshot;
  state = apply(state, "/api/projects/project-1", "DELETE").snapshot;
  assert.equal(state.projects.length, 1);
  assert.equal(state.tasks[0].projectId, "inbox");
  assert.equal(state.projects[0].metadata.length, 0);
});
