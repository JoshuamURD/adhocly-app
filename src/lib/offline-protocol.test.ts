// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { DatabaseSync } from "node:sqlite";
import { mockIPC } from "@tauri-apps/api/mocks";
import { QueryClient, MutationObserver, onlineManager } from "@tanstack/query-core";
import { acknowledge, discardedIds, operationKey, projectState, reduceOffline } from "./offline-store.ts";
import { apiFetch, discardSyncConflict, getSyncStatus, keepSyncConflict, renameSyncConflict, stopOfflineSync, syncOfflineData } from "./api-fetch.ts";

const empty = () => ({ tasks: [], projects: [{ id: "inbox", name: "Inbox", metadata: [], folderId: null }], folders: [], fields: [], versions: { "projects/inbox": 1 } });
const task = (id = "t1", projectId = "inbox") => ({ id, title: "Local task", projectId, plannedFor: null, dueOn: null, repeatWeekday: null, completed: false });
const op = (id, url, method, body, expectedVersion = 0) => ({ id, url, method, body, expectedVersion, createdAt: "2026-04-01T12:00:00.000Z" });

// Real SQLite statements through the same Tauri SQL IPC boundary used by the app.
let local;
let failSave = false;
let server;
let receipts;
let posts;
function setup() {
  stopOfflineSync();
  local?.close();
  local = new DatabaseSync(":memory:");
  local.exec("CREATE TABLE cache (url TEXT PRIMARY KEY, data TEXT, status INTEGER); CREATE TABLE outbox (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT, method TEXT, headers TEXT, body TEXT)");
  failSave = false;
  server = empty(); receipts = new Map(); posts = [];
  globalThis.window = Object.assign(new EventTarget(), { crypto });
  Object.defineProperty(globalThis, "navigator", { value: { onLine: false }, configurable: true });
  mockIPC((command, args) => {
    if (command === "is_ios") return true;
    if (command === "plugin:sql|load") return args.db;
    const query = args?.query?.replace(/\$\d+/g, "?");
    if (command === "plugin:sql|select") return local.prepare(query).all(...(args.values ?? []));
    if (command === "plugin:sql|execute") {
      if (failSave) throw new Error("simulated disk failure");
      const result = local.prepare(query).run(...(args.values ?? []));
      return [result.changes, result.lastInsertRowid];
    }
    throw new Error(command);
  });
  globalThis.fetch = serve;
}
function saved() { return JSON.parse(local.prepare("SELECT data FROM cache WHERE url = 'adhocly:sync-v2'").get().data); }
async function mutate(url, method, body = {}) {
  return apiFetch(url, { method, body: JSON.stringify(body) });
}
async function settle() { await syncOfflineData(); stopOfflineSync(); }
async function list(url = "/api/tasks") { return (await apiFetch(url, { method: "GET" })).data; }

async function serve(url, options) {
  assert.equal(url, "/api/sync");
  if (!navigator.onLine) throw new Error("offline");
  if (options.method === "GET") return Response.json(server);
  const operation = JSON.parse(options.body);
  posts.push(operation);
  let changes = receipts.get(operation.id)?.changes;
  if (changes) {
    assert.deepEqual(operation, receipts.get(operation.id).operation);
  } else {
    const key = operationKey(operation);
    if ((server.versions[key] ?? 0) !== operation.expectedVersion) return new Response("This item changed on another device", { status: 409 });
    try {
      const result = reduceOffline(server, operation.url, operation.method, JSON.stringify(operation.body));
      server = result.snapshot;
    } catch (error) { return new Response(error.message, { status: 400 }); }
    server.versions[key] = (server.versions[key] ?? 0) + 1;
    changes = { [key]: server.versions[key] };
    receipts.set(operation.id, { operation, changes });
  }
  return Response.json({ snapshot: server, changes });
}

test("offline persistence and reconciliation protocol", async (t) => {
  t.after(() => { stopOfflineSync(); local?.close(); onlineManager.setOnline(true); });

  await t.test("offline TanStack mutations execute and persist; a failed commit persists neither half", async () => {
    setup();
    onlineManager.setOnline(false);
    const client = new QueryClient({ defaultOptions: { queries: { networkMode: "always" }, mutations: { networkMode: "always" } } });
    const observer = new MutationObserver(client, { mutationFn: () => mutate("/api/tasks", "POST", task()) });
    await observer.mutate();
    await settle();
    assert.equal(observer.getCurrentResult().isPaused, false);
    assert.equal(saved().pending.length, 1);
    assert.equal((await list()).length, 1);
    assert.deepEqual(await client.fetchQuery({ queryKey: ["local"], queryFn: () => list() }), await list());
    const before = saved();
    failSave = true;
    await assert.rejects(mutate("/api/tasks", "POST", task("t2")), /disk failure/);
    failSave = false;
    assert.deepEqual(saved(), before);
    assert.equal((await list()).length, 1);
    onlineManager.setOnline(true);
    client.clear();
  });

  await t.test("a pull cannot overwrite a task created while the GET is in flight", async () => {
    setup();
    navigator.onLine = true;
    const started = Promise.withResolvers(); const release = Promise.withResolvers();
    globalThis.fetch = async (url, options) => {
      if (options.method === "POST") throw new Error("connection lost");
      started.resolve(); await release.promise;
      return Response.json(server);
    };
    const syncing = syncOfflineData();
    await started.promise;
    await mutate("/api/tasks", "POST", task());
    release.resolve(); await syncing; stopOfflineSync();
    assert.equal(saved().pending.length, 1);
    assert.equal((await list())[0].id, "t1");
    assert.equal(getSyncStatus().phase, "failed");
    assert.equal(getSyncStatus().lastSyncedAt, undefined);
    // Reloading the persisted document reconstructs the same local task without a materialized cache.
    assert.equal(projectState(saved()).tasks[0].id, "t1");
  });

  await t.test("lost acknowledgements replay the identical operation without clobbering newer server data", async () => {
    setup();
    await mutate("/api/tasks", "POST", task()); await settle();
    const id = saved().pending[0].id;
    navigator.onLine = true;
    globalThis.fetch = async (url, options) => {
      const response = await serve(url, options);
      if (options.method === "POST") {
        server.tasks[0].title = "Newer server title";
        server.versions["tasks/t1"]++;
        throw new Error("response lost after commit");
      }
      return response;
    };
    await settle();
    assert.equal(saved().pending[0].id, id);
    globalThis.fetch = serve;
    await settle();
    assert.equal(saved().pending.length, 0);
    assert.equal((await list()).length, 1);
    assert.equal((await list())[0].title, "Newer server title");
    assert.deepEqual(posts[0], posts[1]);
  });

  await t.test("queued edits rebase only onto their own preceding acknowledged effects", async () => {
    setup();
    await mutate("/api/tasks", "POST", task());
    await mutate("/api/tasks/t1", "PUT", { ...task(), title: "Edited locally" });
    await settle(); navigator.onLine = true; await settle();
    assert.equal(posts[1].expectedVersion, 1);
    assert.equal((await list())[0].title, "Edited locally");
    assert.equal(saved().pending.length, 0);
    const state = { schema: 2, base: empty(), pending: [op("a", "/api/tasks/t1", "DELETE", {}, 1), op("b", "/api/projects/inbox", "PUT", { name: "Inbox local" }, 1)] };
    const snapshot = empty(); snapshot.versions["projects/inbox"] = 5;
    acknowledge(state, "a", snapshot, { "tasks/t1": 2 });
    assert.equal(state.pending[0].expectedVersion, 1); // unrelated remote revision must NOT be adopted
  });

  await t.test("discard removes dependent creates, preserves unrelated work, and refreshes despite a conflict", async () => {
    setup();
    await mutate("/api/projects", "POST", { id: "p1", name: "Work" });
    await mutate("/api/tasks", "POST", task("dependent", "p1"));
    await mutate("/api/tasks", "POST", task("independent")); await settle();
    server.projects.push({ id: "remote", name: "Work", metadata: [], folderId: null }); server.versions["projects/remote"] = 1;
    navigator.onLine = true; await settle();
    const conflict = getSyncStatus().conflict;
    assert.equal(conflict.dependents, 1);
    assert.equal(saved().base.projects.length, 2);
    assert.equal(saved().pending.length, 3);
    await discardSyncConflict(conflict.id, 1); stopOfflineSync();
    assert.equal(saved().pending.length, 0);
    assert.deepEqual((await list()).map((task) => task.id), ["independent"]);
    assert.ok(!(await list("/api/projects")).some((project) => project.id === "p1"));
  });

  await t.test("rename updates the local overlay and retains dependent entity ids", async () => {
    setup();
    await mutate("/api/projects", "POST", { id: "p1", name: "Work" });
    await mutate("/api/tasks", "POST", task("dependent", "p1")); await settle();
    server.projects.push({ id: "remote", name: "Work", metadata: [] }); server.versions["projects/remote"] = 1;
    navigator.onLine = true; await settle();
    const conflict = getSyncStatus().conflict;
    navigator.onLine = false;
    await renameSyncConflict(conflict.id, "Personal"); stopOfflineSync();
    assert.equal((await list("/api/projects")).find((project) => project.id === "p1").name, "Personal");
    assert.equal((await list())[0].project, "Personal");
    assert.notEqual(saved().pending[0].id, conflict.id);
    navigator.onLine = true; await settle();
    assert.equal(saved().pending.length, 0);
    assert.equal(server.tasks[0].projectId, "p1");
  });

  await t.test("keep uses the version the user reviewed, not a newer unseen version", async () => {
    setup(); navigator.onLine = true;
    server = reduceOffline(server, "/api/tasks", "POST", JSON.stringify(task())).snapshot;
    server.versions["tasks/t1"] = 1; await settle();
    navigator.onLine = false;
    await mutate("/api/tasks/t1", "PUT", { ...task(), title: "Mine" }); await settle();
    server.tasks[0].title = "Theirs"; server.versions["tasks/t1"] = 2;
    navigator.onLine = true; await settle();
    const reviewed = getSyncStatus().conflict;
    assert.equal(reviewed.server.title, "Theirs"); assert.equal(reviewed.serverVersion, 2);
    server.tasks[0].title = "Even newer"; server.versions["tasks/t1"] = 3;
    await keepSyncConflict(reviewed.id, reviewed.serverVersion); stopOfflineSync();
    assert.equal(server.tasks[0].title, "Even newer");
    assert.equal(getSyncStatus().conflict.serverVersion, 3);
    const latest = getSyncStatus().conflict;
    await keepSyncConflict(latest.id, latest.serverVersion); stopOfflineSync();
    assert.equal(server.tasks[0].title, "Mine"); assert.equal(saved().pending.length, 0);
  });

  await t.test("legacy outboxes are backed up and require a decision rather than blind replay", async () => {
    setup();
    local.prepare("INSERT INTO outbox (url, method, headers, body) VALUES (?, ?, ?, ?)").run("/api/tasks", "POST", "{}", JSON.stringify(task()));
    navigator.onLine = true; await settle();
    assert.equal(posts.length, 0);
    assert.equal(saved().pending[0].expectedVersion, -1);
    assert.match(getSyncStatus().conflict.message, /older sync protocol/);
    assert.equal(local.prepare("SELECT count(*) AS n FROM outbox").get().n, 1);
    assert.equal((await list())[0].id, "t1");
  });

  await t.test("a failed local acknowledgement commit retains the exact retry request", async () => {
    setup(); await mutate("/api/tasks", "POST", task()); await settle();
    navigator.onLine = true;
    globalThis.fetch = async (url, options) => {
      const response = await serve(url, options);
      if (options.method === "POST") failSave = true;
      return response;
    };
    await settle();
    assert.equal(saved().pending.length, 1);
    assert.equal(server.tasks.length, 1);
    failSave = false; globalThis.fetch = serve; await settle();
    assert.equal(saved().pending.length, 0);
    assert.deepEqual(posts[0], posts[1]);
  });

  await t.test("a hung request times out without losing queued changes", async () => {
    setup(); await mutate("/api/tasks", "POST", task()); await settle();
    navigator.onLine = true;
    const originalTimeout = globalThis.setTimeout;
    globalThis.setTimeout = (fn, delay, ...args) => originalTimeout(fn, delay === 20_000 ? 5 : delay, ...args);
    globalThis.fetch = (_url, options) => new Promise((_resolve, reject) => {
      options.signal.addEventListener("abort", () => reject(new Error("request timed out")), { once: true });
    });
    try {
      await settle();
      assert.equal(saved().pending.length, 1);
      assert.match(getSyncStatus().message, /timed out/);
    } finally { globalThis.setTimeout = originalTimeout; stopOfflineSync(); }
  });

  await t.test("transient failures retry without another connectivity event", async () => {
    setup(); navigator.onLine = true; await settle();
    let attempts = 0;
    const recovered = Promise.withResolvers();
    globalThis.fetch = async (url, options) => {
      if (++attempts === 1) throw new Error("temporary outage");
      const response = await serve(url, options);
      recovered.resolve();
      return response;
    };
    await syncOfflineData();
    const guard = setTimeout(() => recovered.reject(new Error("retry was not scheduled")), 5_000);
    try { await recovered.promise; await settle(); }
    finally { clearTimeout(guard); stopOfflineSync(); }
    assert.ok(attempts >= 2);
    assert.equal(getSyncStatus().phase, "idle");
  });

  await t.test("malformed acknowledgements never remove pending work", async () => {
    setup(); await mutate("/api/tasks", "POST", task()); await settle();
    navigator.onLine = true;
    globalThis.fetch = async (url, options) => options.method === "GET" ? Response.json(server) : Response.json({ snapshot: {}, changes: {} });
    await settle();
    assert.equal(saved().pending.length, 1);
    assert.equal((await list())[0].id, "t1");
  });
});

test("discard follows transitive create dependencies but leaves later edits to existing entities", () => {
  const state = { schema: 2, base: empty(), pending: [
    op("folder", "/api/folders", "POST", { id: "f1", name: "Work" }),
    op("child", "/api/folders", "POST", { id: "f2", name: "Child", parentId: "f1" }),
    op("project", "/api/projects", "POST", { id: "p1", name: "Project" }),
    op("move", "/api/projects/p1/folder", "PUT", { folderId: "f2" }),
    op("task", "/api/tasks", "POST", task("t1", "p1")),
  ] };
  assert.deepEqual([...discardedIds(state, "folder")], ["folder", "child", "move"]);
  state.pending = [op("rename", "/api/projects/inbox", "PUT", { name: "A" }, 1), op("rename2", "/api/projects/inbox", "PUT", { name: "B" }, 1)];
  assert.deepEqual([...discardedIds(state, "rename")], ["rename"]);
});
