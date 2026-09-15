type Entity = Record<string, any>;
export type OfflineSnapshot = {
  tasks: Entity[];
  projects: Entity[];
  folders: Entity[];
  fields: Entity[];
  versions?: Record<string, number>;
};
type LocalResult = { snapshot: OfflineSnapshot; data: unknown; status: number; body: string };
export type PendingOperation = {
  id: string;
  url: string;
  method: string;
  body: Entity;
  expectedVersion: number;
  createdAt: string;
  blocked?: { status: number; message: string };
};
export type OfflineState = {
  schema: 2;
  base: OfflineSnapshot;
  pending: PendingOperation[];
  lastSyncedAt?: string;
};
export const collections: Record<string, "tasks" | "projects" | "folders" | "fields"> = {
  tasks: "tasks", projects: "projects", folders: "folders", "metadata-fields": "fields",
};

export function operationKey(op: Pick<PendingOperation, "url" | "body">) {
  const parts = op.url.split("/").filter(Boolean).map(decodeURIComponent);
  return `${parts[1]}/${parts[2] ?? op.body.id}`;
}

export function projectState(state: OfflineState): OfflineSnapshot {
  return state.pending.reduce((snapshot, operation) => {
    try {
      return reduceOffline(snapshot, operation.url, operation.method, JSON.stringify(operation.body), operation.createdAt, true).snapshot;
    } catch {
      // Keep the operation for server replay/explicit resolution, even if its target was deleted.
      return snapshot;
    }
  }, structuredClone(state.base));
}

export function acknowledge(state: OfflineState, id: string, base: OfflineSnapshot, changes: Record<string, number>) {
  if (state.pending[0]?.id !== id) throw new Error("Sync acknowledgement does not match the pending operation");
  state.pending.shift();
  state.base = base;
  for (const operation of state.pending) {
    const changed = changes[operationKey(operation)];
    if (changed !== undefined) operation.expectedVersion = changed;
  }
}

function references(operation: PendingOperation) {
  const parts = operation.url.split("/").filter(Boolean).map(decodeURIComponent);
  return [
    operationKey(operation),
    operation.body.projectId && `projects/${operation.body.projectId}`,
    operation.body.folderId && `folders/${operation.body.folderId}`,
    operation.body.parentId && `folders/${operation.body.parentId}`,
    parts[3] === "metadata" && `metadata-fields/${parts[4]}`,
  ].filter(Boolean) as string[];
}

/** Explicitly discards the selected change and only the changes depending on its new entities. */
export function discardedIds(state: OfflineState, id: string): Set<string> {
  const removed = new Set<string>();
  const missing = new Set<string>();
  for (const operation of state.pending) {
    if (operation.id !== id && !references(operation).some((key) => missing.has(key))) continue;
    removed.add(operation.id);
    const parts = operation.url.split("/").filter(Boolean).map(decodeURIComponent);
    const created = parts.length === 2 && operation.method === "POST" ? operationKey(operation) :
      operation.body.nextId ? `tasks/${operation.body.nextId}` : undefined;
    if (created) {
      const slash = created.indexOf("/");
      const collection = collections[created.slice(0, slash)];
      if (!state.base[collection].some((entity) => entity.id === created.slice(slash + 1))) missing.add(created);
    }
  }
  return removed;
}

export function validateSnapshot(value: unknown): asserts value is OfflineSnapshot {
  if (!value || typeof value !== "object") throw new Error("Invalid sync snapshot");
  const snapshot = value as OfflineSnapshot;
  for (const key of Object.values(collections)) {
    if (!Array.isArray(snapshot[key]) || snapshot[key].some((entity) => !entity || typeof entity.id !== "string")) throw new Error("Invalid sync snapshot");
  }
  if (!snapshot.projects.some((project) => project.id === "inbox") ||
    snapshot.projects.some((project) => typeof project.name !== "string" || !Array.isArray(project.metadata)) ||
    snapshot.folders.some((folder) => typeof folder.name !== "string") ||
    snapshot.fields.some((field) => typeof field.name !== "string" || !Array.isArray(field.options))) throw new Error("Invalid sync snapshot");
  validateVersions(snapshot.versions);
  for (const [resource, collection] of Object.entries(collections)) {
    const ids = snapshot[collection].map((entity) => entity.id);
    if (new Set(ids).size !== ids.length || ids.some((id) => !snapshot.versions![`${resource}/${id}`])) throw new Error("Invalid sync snapshot revisions");
  }
}

export function validateVersions(value: unknown): asserts value is Record<string, number> {
  if (!value || typeof value !== "object" || Array.isArray(value) || Object.values(value).some((version) => !Number.isSafeInteger(version) || version < 1)) throw new Error("Invalid sync versions");
}

function required<T>(value: T | undefined, message: string): T {
  if (value === undefined) throw new Error(message);
  return value;
}

function uniqueName(items: Entity[], name: string, parentId?: string | null, except?: string) {
  if (
    items.some(
      (item) =>
        item.id !== except &&
        item.name.toLowerCase() === name.toLowerCase() &&
        (parentId === undefined || (item.parentId ?? null) === parentId),
    )
  ) {
    throw new Error("that name is already taken");
  }
}

function nextWeek(value: string | null | undefined) {
  if (!value) return null;
  const date = new Date(`${value}:00Z`);
  date.setUTCDate(date.getUTCDate() + 7);
  return date.toISOString().slice(0, 16);
}

/** Pure local reducer; exported so offline behavior has one cheap runnable test. */
export function reduceOffline(
  current: OfflineSnapshot,
  url: string,
  method: string,
  requestBody: string | undefined,
  now = new Date().toISOString(),
  replay = false,
): LocalResult {
  const next = structuredClone(current);
  const parts = url.split("/").filter(Boolean).map(decodeURIComponent);
  const body: Entity = requestBody ? JSON.parse(requestBody) : {};
  if (!body || typeof body !== "object" || Array.isArray(body)) throw new Error("invalid mutation body");
  const id = parts[2];
  const resource = parts[1];
  const collection = collections[resource];
  const create = method === "POST" && parts.length === 2;
  const regular = (method === "PUT" || method === "DELETE") && parts.length === 3;
  const special = (resource === "tasks" && method === "POST" && parts.length === 4 && parts[3] === "toggle") ||
    (resource === "projects" && method === "PUT" && ((parts.length === 4 && parts[3] === "folder") || (parts.length === 5 && parts[3] === "metadata")));
  if (parts[0] !== "api" || !Object.hasOwn(collections, resource) || !(create || regular || special)) throw new Error(`Offline write is not supported for ${url}`);
  if (create) {
    body.id ||= crypto.randomUUID();
    if (typeof body.id !== "string" || !body.id.trim()) throw new Error("id is required");
  }
  if (create && !replay && next[collection].some((item) => item.id === body.id)) throw new Error("id already exists");
  if ((create || (regular && method === "PUT")) && resource !== "tasks") {
    if (typeof body.name !== "string" || !body.name.trim()) throw new Error("name is required");
  }
  if (resource === "tasks" && (create || method === "PUT")) {
    if (typeof body.id !== "string" || !body.id.trim() || (!create && body.id !== id)) throw new Error("path and task ids must match");
    if (create && body.id.startsWith("next:")) throw new Error("next: ids are reserved for recurring tasks");
    if (typeof body.title !== "string" || !body.title.trim()) throw new Error("title is required");
    if (typeof body.projectId !== "string" || !body.projectId.trim()) throw new Error("projectId is required");
    if (body.repeatWeekday != null && (!Number.isInteger(body.repeatWeekday) || body.repeatWeekday < 0 || body.repeatWeekday > 6)) throw new Error("repeatWeekday must be between 0 and 6");
    body.title = body.title.trim();
  }
  if (resource === "tasks" && method !== "DELETE" && typeof body.completed !== "boolean") throw new Error("completed must be a boolean");
  if (resource === "metadata-fields" && create && !["text", "number", "choice"].includes(body.kind)) throw new Error("invalid field kind");
  // A lost acknowledgement may leave this create in the overlay after it exists on the server.
  const existing = create ? next[collection].find((item) => item.id === body.id) : undefined;
  if (create && replay) next[collection] = next[collection].filter((item) => item.id !== body.id);
  let data: unknown;
  let status = method === "POST" ? 200 : method === "DELETE" ? 204 : 200;

  if (parts[1] === "tasks") {
    if (method === "POST" && parts.length === 2) {
      const project = required(next.projects.find((item) => item.id === body.projectId), "project does not exist");
      data = { ...body, project: project.name, createdAt: existing?.createdAt ?? now, updatedAt: now };
      next.tasks.unshift(data as Entity);
      status = 201;
    } else {
      const index = next.tasks.findIndex((item) => item.id === id);
      const task = required(next.tasks[index], "task not found");
      if (method === "PUT") {
        const project = required(next.projects.find((item) => item.id === body.projectId), "project does not exist");
        data = { ...task, ...body, project: project.name, updatedAt: now };
        next.tasks[index] = data as Entity;
      } else if (method === "DELETE") {
        next.tasks.splice(index, 1);
      } else if (method === "POST" && parts[3] === "toggle") {
        const wasCompleted = task.completed;
        const toggled = { ...task, completed: body.completed, updatedAt: now };
        next.tasks[index] = toggled;
        let nextTask = null;
        if (!wasCompleted && body.completed && task.repeatWeekday != null) {
          body.nextId = `next:${task.id}`;
          nextTask = {
            ...task,
            id: body.nextId,
            plannedFor: nextWeek(task.plannedFor),
            dueOn: nextWeek(task.dueOn),
            createdAt: now,
            updatedAt: now,
            completed: false,
          };
          const successor = next.tasks.find((item) => item.id === body.nextId);
          if (successor) nextTask = successor;
          else if (next.versions?.[`tasks/${body.nextId}`]) nextTask = null;
          else next.tasks.unshift(nextTask);
        }
        data = { task: toggled, nextTask };
      }
    }
  } else if (parts[1] === "projects") {
    if (method === "POST" && parts.length === 2) {
      const name = body.name.trim();
      if (!replay) uniqueName(next.projects, name);
      data = { id: body.id, name, folderId: existing?.folderId ?? null, createdAt: existing?.createdAt ?? now, updatedAt: now, metadata: existing?.metadata ?? [] };
      next.projects.push(data as Entity);
      status = 201;
    } else {
      const index = next.projects.findIndex((item) => item.id === id);
      const project = required(next.projects[index], "project not found");
      if (method === "DELETE") {
        if (id === "inbox") throw new Error("Inbox cannot be deleted");
        next.projects.splice(index, 1);
        next.tasks = next.tasks.map((task) =>
          task.projectId === id ? { ...task, projectId: "inbox", project: next.projects.find((item) => item.id === "inbox")?.name ?? "Inbox" } : task,
        );
      } else if (method === "PUT" && parts[3] === "folder") {
        if (id === "inbox") throw new Error("Inbox cannot be filed");
        if (body.folderId != null) required(next.folders.find((item) => item.id === body.folderId), "folder not found");
        data = { ...project, folderId: body.folderId ?? null, updatedAt: now };
        next.projects[index] = data as Entity;
      } else if (method === "PUT" && parts[3] === "metadata") {
        const fieldId = parts[4];
        const field = required(next.fields.find((item) => item.id === fieldId), "field not found");
        const value = body.value?.trim();
        if (value && field.kind === "number" && !Number.isFinite(Number(value))) throw new Error("value must be a number");
        if (value && field.kind === "choice" && !field.options.includes(value)) {
          throw new Error("value must be one of the field options");
        }
        const metadata = project.metadata.filter((item: Entity) => item.fieldId !== fieldId);
        if (value) metadata.push({ fieldId, value });
        next.projects[index] = { ...project, metadata };
        status = 204;
      } else if (method === "PUT") {
        const name = body.name.trim();
        if (!replay) uniqueName(next.projects, name, undefined, id);
        data = { ...project, name, updatedAt: now };
        next.projects[index] = data as Entity;
        next.tasks = next.tasks.map((task) => (task.projectId === id ? { ...task, project: name } : task));
      }
    }
  } else if (parts[1] === "folders") {
    if (method === "POST" && parts.length === 2) {
      const name = body.name.trim();
      const parentId = body.parentId ?? null;
      if (parentId) required(next.folders.find((item) => item.id === parentId), "folder not found");
      if (!replay) uniqueName(next.folders, name, parentId);
      data = { id: body.id, name, parentId, createdAt: now, updatedAt: now };
      next.folders.push(data as Entity);
      status = 201;
    } else {
      const index = next.folders.findIndex((item) => item.id === id);
      const folder = required(next.folders[index], "folder not found");
      if (method === "DELETE") {
        next.folders.splice(index, 1);
        next.folders = next.folders.map((item) => (item.parentId === id ? { ...item, parentId: folder.parentId ?? null } : item));
        next.projects = next.projects.map((item) => (item.folderId === id ? { ...item, folderId: folder.parentId ?? null } : item));
      } else if (method === "PUT") {
        const name = body.name.trim();
        const parentId = body.parentId ?? null;
        if (parentId) required(next.folders.find((item) => item.id === parentId), "folder not found");
        const seen = new Set([id]);
        for (let parent = parentId; parent; ) {
          if (seen.has(parent)) throw new Error("a folder cannot move inside itself");
          seen.add(parent);
          parent = next.folders.find((item) => item.id === parent)?.parentId ?? null;
        }
        if (!replay) uniqueName(next.folders, name, parentId, id);
        data = { ...folder, name, parentId, updatedAt: now };
        next.folders[index] = data as Entity;
      }
    }
  } else if (parts[1] === "metadata-fields") {
    if (method === "POST" && parts.length === 2) {
      const name = body.name.trim();
      if (!replay) uniqueName(next.fields, name);
      const options = body.kind === "choice" ? [...new Set((body.options ?? []).map((item: string) => item.trim()).filter(Boolean))] : [];
      if (body.kind === "choice" && !options.length) throw new Error("choice fields need at least one option");
      data = { id: body.id, name, kind: body.kind, options, createdAt: now };
      next.fields.push(data as Entity);
      status = 201;
    } else {
      const index = next.fields.findIndex((item) => item.id === id);
      const field = required(next.fields[index], "field not found");
      if (method === "DELETE") {
        next.fields.splice(index, 1);
        next.projects = next.projects.map((project) => ({
          ...project,
          metadata: project.metadata.filter((item: Entity) => item.fieldId !== id),
        }));
      } else if (method === "PUT") {
        const name = body.name.trim();
        if (!replay) uniqueName(next.fields, name, undefined, id);
        const options = field.kind === "choice" ? [...new Set((body.options ?? []).map((item: string) => item.trim()).filter(Boolean))] : [];
        if (field.kind === "choice" && !options.length) throw new Error("choice fields need at least one option");
        data = { ...field, name, options };
        next.fields[index] = data as Entity;
      }
    }
  } else {
    throw new Error(`Offline write is not supported for ${url}`);
  }

  return { snapshot: next, data, status, body: JSON.stringify(body) };
}

