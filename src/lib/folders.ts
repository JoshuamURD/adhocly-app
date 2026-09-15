import type { Folder, Project } from "./api/generated";

export type FolderNode = {
  folder: Folder;
  folders: FolderNode[];
  projects: Project[];
};

/** Inbox first, everything else alphabetically — the order projects take in the sidebar. */
export function projectOrder(a: Project, b: Project) {
  if (a.name === "Inbox") return -1;
  if (b.name === "Inbox") return 1;
  return a.name.localeCompare(b.name);
}

/**
 * Splits projects and folders into the tree the sidebar draws: folders nest to any depth, each
 * project sits in its folder, and anything without one sits at the root. A project pointing at a
 * folder that no longer exists lands at the root; a folder cycle is simply left unreachable
 * rather than drawn forever.
 */
export function folderTree(folders: Folder[], projects: Project[]) {
  const nodes = new Map<string, FolderNode>();
  for (const folder of folders) nodes.set(folder.id, { folder, folders: [], projects: [] });

  const roots: FolderNode[] = [];
  for (const node of nodes.values()) {
    const parent = node.folder.parentId ? nodes.get(node.folder.parentId) : undefined;
    (parent ? parent.folders : roots).push(node);
  }

  const loose: Project[] = [];
  for (const project of projects) {
    const node = project.folderId ? nodes.get(project.folderId) : undefined;
    (node ? node.projects : loose).push(project);
  }

  const byName = (a: FolderNode, b: FolderNode) => a.folder.name.localeCompare(b.folder.name);
  const sort = (node: FolderNode) => {
    node.folders.sort(byName);
    node.projects.sort(projectOrder);
    node.folders.forEach(sort);
  };
  roots.sort(byName);
  roots.forEach(sort);
  loose.sort(projectOrder);

  return { folders: roots, projects: loose };
}

/** "Work › Clients" — a folder's name with its ancestors, for flat pickers. */
export function folderPath(folders: Folder[], id: string) {
  const byId = new Map(folders.map((folder) => [folder.id, folder]));
  const path: string[] = [];
  const seen = new Set<string>();
  for (let at = byId.get(id); at && !seen.has(at.id); at = at.parentId ? byId.get(at.parentId) : undefined) {
    path.unshift(at.name);
    seen.add(at.id);
  }
  return path.join(" › ") || id;
}

/** True when `id` is `ancestorId` or nests somewhere beneath it — the moves a folder may not make. */
export function isInside(folders: Folder[], ancestorId: string, id: string) {
  const parentOf = new Map(folders.map((folder) => [folder.id, folder.parentId ?? null]));
  const seen = new Set<string>();
  for (let at: string | null = id; at && !seen.has(at); at = parentOf.get(at) ?? null) {
    if (at === ancestorId) return true;
    seen.add(at);
  }
  return false;
}
