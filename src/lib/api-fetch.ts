import { invoke } from "@tauri-apps/api/core";
import Database from "@tauri-apps/plugin-sql";
import {
  acknowledge, collections, discardedIds, operationKey, projectState, reduceOffline,
  validateSnapshot, validateVersions,
  type OfflineSnapshot, type OfflineState, type PendingOperation,
} from "./offline-store.ts";

export { reduceOffline, type OfflineSnapshot } from "./offline-store.ts";
const apiOrigin = (import.meta as ImportMeta & { env?: Record<string, string> }).env?.PUBLIC_API_URL || "";
const stateKey = "adhocly:sync-v2";
const coreUrls = ["/api/tasks", "/api/projects", "/api/folders", "/api/metadata-fields"];

type CacheRow = { url: string; data: string; status: number };
type ResponseData<T> = { data: T; status: number; headers: Headers };
export type SyncConflict = {
  id: string; url: string; method: string; message: string; status: number;
  body: Record<string, any>; server?: Record<string, any>; serverVersion: number; dependents: number;
};
export type SyncStatus = {
  phase: "idle" | "syncing" | "failed";
  pending: number; message: string; conflict?: SyncConflict; lastSyncedAt?: string;
};

let database: Promise<Database> | undefined;
let ios: Promise<boolean> | undefined;
let writing: Promise<unknown> = Promise.resolve();
let syncing: Promise<void> | undefined;
let syncAgain = false;
let retryTimer: ReturnType<typeof setTimeout> | undefined;
let retriesEnabled = true;
let retryDelay = 2_000;
let syncStatus: SyncStatus = { phase: "idle", pending: 0, message: "" };

class HttpError extends Error {
  readonly status: number;
  constructor(message: string, status: number) {
    super(message);
    this.status = status;
  }
}

function parseBody(text: string) {
  if (!text) return undefined;
  try { return JSON.parse(text); } catch { return text; }
}

async function remoteFetch<T>(url: string, options: RequestInit): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  options.signal?.addEventListener("abort", abort, { once: true });
  if (options.signal?.aborted) abort();
  const timeout = setTimeout(abort, 20_000);
  try {
    const response = await fetch(`${apiOrigin}${url}`, { ...options, signal: controller.signal });
    const data = parseBody(await response.text());
    if (!response.ok) throw new HttpError(typeof data === "string" ? data : `Request failed (${response.status})`, response.status);
    return { data, status: response.status, headers: response.headers } as T;
  } finally {
    clearTimeout(timeout);
    options.signal?.removeEventListener("abort", abort);
  }
}

export function offlineSyncEnabled() {
  return (ios ??= invoke<boolean>("is_ios").catch(() => false));
}

export function getSyncStatus() { return structuredClone(syncStatus); }

function notify() {
  if (typeof window !== "undefined") window.dispatchEvent(new Event("adhocly:sync"));
}

function publish(state: OfflineState, phase: SyncStatus["phase"], message: string) {
  const head = state.pending[0];
  const blocked = head?.blocked;
  let conflict: SyncConflict | undefined;
  if (blocked) {
    const key = operationKey(head);
    const slash = key.indexOf("/");
    const collection = collections[key.slice(0, slash)];
    conflict = {
      id: head.id, url: head.url, method: head.method, body: head.body, ...blocked,
      server: collection ? state.base[collection]?.find((item) => item.id === key.slice(slash + 1)) : undefined,
      serverVersion: state.base.versions?.[key] ?? 0,
      dependents: discardedIds(state, head.id).size - 1,
    };
  }
  syncStatus = { phase: blocked ? "failed" : phase, pending: state.pending.length, message: blocked?.message ?? message, conflict, lastSyncedAt: state.lastSyncedAt };
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("adhocly:sync-status", { detail: getSyncStatus() }));
}

function db() {
  return (database ??= Database.load("sqlite:adhocly-offline.db").catch((error) => { database = undefined; throw error; }));
}

/** Serialize ALL read/modify/commit operations, never the network requests. */
function exclusive<T>(action: () => Promise<T>): Promise<T> {
  const result = writing.then(action, action);
  writing = result.catch(() => undefined);
  return result;
}

async function load(): Promise<OfflineState> {
  const local = await db();
  const rows = await local.select<CacheRow[]>("SELECT url, data, status FROM cache WHERE url = $1", [stateKey]);
  if (rows[0]) {
    const state = JSON.parse(rows[0].data);
    if (state.schema !== 2 || !Array.isArray(state.pending)) throw new Error("Unsupported local sync data. Do not clear the app's storage.");
    if (state.origin !== apiOrigin) throw new Error("Saved data belongs to a different server. Resolve or export it before switching servers.");
    return state;
  }

  const cached = await local.select<CacheRow[]>("SELECT url, data, status FROM cache");
  const values = new Map(cached.map((row) => [row.url, JSON.parse(row.data)]));
  const legacy = await local.select<{ url: string; method: string; body: string | null }[]>("SELECT url, method, body FROM outbox ORDER BY id");
  const state: OfflineState = {
    schema: 2,
    base: {
      tasks: values.get(coreUrls[0]) ?? [],
      projects: values.get(coreUrls[1]) ?? [{ id: "inbox", name: "Inbox", folderId: null, metadata: [] }],
      folders: values.get(coreUrls[2]) ?? [], fields: values.get(coreUrls[3]) ?? [], versions: {},
    },
    pending: legacy.map((row) => ({
      id: crypto.randomUUID(), url: row.url, method: row.method, body: row.body ? JSON.parse(row.body) : {},
      expectedVersion: -1, createdAt: new Date().toISOString(),
      blocked: { status: 409, message: "This change was saved by the older sync protocol. Review the server version before keeping or discarding it." },
    })),
    lastSyncedAt: values.get("adhocly:last-sync"),
  };
  // Old cache/outbox rows stay untouched as a recovery backup. Never blindly replay unversioned writes.
  await save(state);
  return state;
}

async function save(state: OfflineState) {
  // ponytail: one document makes base + outbox atomic; use normalized rows if whole-state writes become costly.
  await (await db()).execute(
    "INSERT INTO cache (url, data, status) VALUES ($1, $2, 200) ON CONFLICT(url) DO UPDATE SET data = excluded.data, status = excluded.status",
    [stateKey, JSON.stringify({ ...state, origin: apiOrigin })],
  );
}

async function localGet<T>(url: string, options: RequestInit): Promise<T> {
  const parts = url.split("/").filter(Boolean).map(decodeURIComponent);
  if (parts[0] === "api" && Object.hasOwn(collections, parts[1]) && (parts.length === 2 || parts.length === 3)) {
    return exclusive(async () => {
      const snapshot = projectState(await load());
      const items = snapshot[collections[parts[1]]];
      const data = parts.length === 2 ? items : items.find((item) => item.id === parts[2]);
      if (data === undefined) throw new HttpError("item not found", 404);
      return { data, status: 200, headers: new Headers() } as T;
    });
  }
  return remoteFetch<T>(url, options);
}

async function localMutation<T>(url: string, options: RequestInit): Promise<T> {
  const response = await exclusive(async () => {
    const state = await load();
    const createdAt = new Date().toISOString();
    const result = reduceOffline(projectState(state), url, options.method ?? "GET", options.body?.toString(), createdAt);
    const operation: PendingOperation = {
      id: crypto.randomUUID(), url, method: options.method!, body: JSON.parse(result.body), expectedVersion: 0, createdAt,
    };
    operation.expectedVersion = state.base.versions?.[operationKey(operation)] ?? 0;
    state.pending.push(operation);
    await save(state);
    publish(state, syncStatus.phase, "Changes saved on this device");
    notify();
    return { data: result.data, status: result.status, headers: new Headers() } as T;
  });
  void syncOfflineData();
  return response;
}

async function pull() {
  const response = await remoteFetch<ResponseData<unknown>>("/api/sync", { method: "GET" });
  validateSnapshot(response.data);
  const snapshot = response.data;
  await exclusive(async () => {
    const state = await load();
    state.base = snapshot;
    await save(state);
    publish(state, "syncing", "Syncing…");
    notify();
  });
}

async function runSync(): Promise<boolean> {
  let state = await exclusive(load);
  if (typeof navigator !== "undefined" && !navigator.onLine) throw new Error("No connection. Your changes are saved on this device.");
  publish(state, "syncing", "Syncing…");
  // Pull even with a conflict: unrelated remote work must not be held hostage by the outbox.
  await pull();
  while (true) {
    state = await exclusive(load);
    const head = state.pending[0];
    if (!head) {
      await exclusive(async () => {
        const latest = await load();
        if (!latest.pending.length) latest.lastSyncedAt = new Date().toISOString();
        await save(latest);
        publish(latest, "idle", latest.pending.length ? "Changes waiting to sync" : "Up to date");
      });
      return true;
    }
    if (head.blocked) { publish(state, "failed", head.blocked.message); return false; }
    try {
      const { id, url, method, body, expectedVersion } = head;
      const response = await remoteFetch<ResponseData<{ snapshot: unknown; changes: unknown }>>("/api/sync", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id, url, method, body, expectedVersion }),
      });
      validateSnapshot(response.data?.snapshot);
      validateVersions(response.data?.changes);
      const snapshot = response.data.snapshot;
      const changes = response.data.changes;
      await exclusive(async () => {
        const latest = await load();
        acknowledge(latest, head.id, snapshot, changes);
        await save(latest);
        publish(latest, "syncing", "Syncing…");
        notify();
      });
    } catch (error) {
      if (!(error instanceof HttpError) || ![400, 404, 409, 422].includes(error.status)) throw error;
      await exclusive(async () => {
        const latest = await load();
        if (latest.pending[0]?.id !== head.id) throw new Error("Pending operation changed during sync");
        latest.pending[0].blocked = { status: error.status, message: error.message };
        await save(latest);
        publish(latest, "failed", error.message);
      });
      // Refresh the version shown in the decision dialog, without rebasing the queued write.
      try { await pull(); } catch { /* The conflict and its last known server version remain durable. */ }
      return false;
    }
  }
}

export function stopOfflineSync() {
  retriesEnabled = false;
  clearTimeout(retryTimer);
  retryTimer = undefined;
}

function scheduleRetry() {
  if (!retriesEnabled) return;
  if ((typeof navigator !== "undefined" && !navigator.onLine) ||
    (typeof document !== "undefined" && document.visibilityState === "hidden")) return;
  retryTimer = setTimeout(() => void syncOfflineData(), retryDelay);
  retryDelay = Math.min(retryDelay * 2, 60_000);
}

export async function syncOfflineData(): Promise<void> {
  if (!(await offlineSyncEnabled())) return;
  if (syncing) { syncAgain = true; return syncing; }
  stopOfflineSync();
  retriesEnabled = true;
  syncing = (async () => {
    do {
      syncAgain = false;
      if (!(await runSync())) break;
      retryDelay = 2_000;
    } while (syncAgain && retriesEnabled);
  })().catch(async (error) => {
    const message = error instanceof Error ? error.message : "Sync failed";
    try { publish(await exclusive(load), "failed", message); }
    catch {
      syncStatus = { ...syncStatus, phase: "failed", message };
      if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent("adhocly:sync-status", { detail: getSyncStatus() }));
    }
    if (!syncStatus.conflict) scheduleRetry();
  }).finally(() => {
    syncing = undefined;
    // A write may arrive after the worker's last empty-queue check but before this finalizer.
    if (retriesEnabled && syncAgain && syncStatus.phase !== "failed") void syncOfflineData();
  });
  return syncing;
}

async function resolveConflict(id: string, action: "discard" | "retry" | "keep" | "rename", name?: string, serverVersion?: number, dependents?: number) {
  // Only settled, rejected requests can be changed; uncertain requests retain their original mutation id.
  if (syncing) await syncing;
  await exclusive(async () => {
    const state = await load();
    const head = state.pending[0];
    if (!head || head.id !== id || !head.blocked) throw new Error("Sync conflict no longer exists");
    if (action === "discard") {
      const removed = discardedIds(state, id);
      if (dependents !== undefined && removed.size - 1 !== dependents) throw new Error("Dependent changes have changed. Review the discard again.");
      state.pending = state.pending.filter((operation) => !removed.has(operation.id));
    } else {
      if (action === "rename") {
        if (!name?.trim()) throw new Error("Name is required");
        head.body.name = name.trim();
      }
      if (action === "keep") {
        if (!Number.isSafeInteger(serverVersion) || serverVersion! < 0) throw new Error("Review the server version before keeping your change");
        head.expectedVersion = serverVersion!;
      }
      if (action !== "retry") head.id = crypto.randomUUID();
      delete head.blocked;
    }
    await save(state);
    publish(state, "idle", "Conflict decision saved");
    notify();
  });
  await syncOfflineData();
}

export const discardSyncConflict = (id: string, dependents?: number) => resolveConflict(id, "discard", undefined, undefined, dependents);
export const retrySyncConflict = (id: string) => resolveConflict(id, "retry");
export const keepSyncConflict = (id: string, serverVersion: number) => resolveConflict(id, "keep", undefined, serverVersion);
export const renameSyncConflict = (id: string, name: string) => resolveConflict(id, "rename", name);

export async function apiFetch<T>(url: string, options: RequestInit): Promise<T> {
  if (!(await offlineSyncEnabled()) || url === "/api/sync") return remoteFetch<T>(url, options);
  return (options.method ?? "GET") === "GET" ? localGet<T>(url, options) : localMutation<T>(url, options);
}
