// @ts-nocheck -- node:test runner, not part of the app build
import assert from "node:assert/strict";
import test from "node:test";
import { folderPath, folderTree, isInside, projectOrder } from "./folders.ts";

const folder = (id, name, parentId = null) => ({ id, name, parentId, createdAt: "", updatedAt: "" });
const project = (id, name, folderId = null) => ({
  id,
  name,
  folderId,
  createdAt: "",
  updatedAt: "",
  metadata: [],
});

test("Nests folders to any depth and files projects under them", () => {
  const folders = [folder("work", "Work"), folder("clients", "Clients", "work"), folder("acme", "Acme", "clients")];
  const projects = [project("p1", "Website", "clients"), project("p2", "Inbox", "id-inbox"), project("p3", "Branding")];

  const tree = folderTree(folders, projects);
  assert.deepEqual(tree.folders.map((node) => node.folder.id), ["work"]);
  assert.deepEqual(tree.folders[0].folders[0].folders[0].folder.id, "acme");
  assert.deepEqual(tree.folders[0].folders[0].projects.map((p) => p.id), ["p1"]);
  // No folder at all: the root, Inbox first.
  assert.deepEqual(tree.projects.map((p) => p.id), ["p2", "p3"]);
});

test("Sorts folders and projects by name, keeping Inbox first", () => {
  const tree = folderTree(
    [folder("b", "Beta"), folder("a", "Alpha")],
    [project("z", "Zebra"), project("i", "Inbox"), project("m", "Mango")],
  );
  assert.deepEqual(tree.folders.map((node) => node.folder.id), ["a", "b"]);
  assert.deepEqual(tree.projects.map((p) => p.id), ["i", "m", "z"]);
  assert.equal([project("a", "Zebra"), project("b", "alpha")].sort(projectOrder)[1].name, "Zebra");
});

test("Survives a project whose folder is gone and a folder cycle", () => {
  const folders = [folder("a", "A", "b"), folder("b", "B", "a")];
  const tree = folderTree(folders, [project("p1", "Stray", "deleted"), project("p2", "Loose")]);
  assert.deepEqual(tree.folders, []);
  assert.deepEqual(tree.projects.map((p) => p.id), ["p2", "p1"]);
});

test("Folder paths name the ancestors of a nested folder", () => {
  const folders = [folder("work", "Work"), folder("clients", "Clients", "work")];
  assert.equal(folderPath(folders, "clients"), "Work › Clients");
  assert.equal(folderPath(folders, "work"), "Work");
  const cycle = [folder("a", "A", "b"), folder("b", "B", "a")];
  assert.equal(folderPath(cycle, "a"), "B › A");
});

test("isInside covers the folder itself, its subtree and unrelated branches", () => {
  const folders = [folder("work", "Work"), folder("clients", "Clients", "work"), folder("other", "Other")];
  assert.equal(isInside(folders, "work", "work"), true);
  assert.equal(isInside(folders, "work", "clients"), true);
  assert.equal(isInside(folders, "clients", "work"), false);
  assert.equal(isInside(folders, "work", "other"), false);
  // A cycle in the data must not hang the walk.
  assert.equal(isInside([folder("a", "A", "b"), folder("b", "B", "a")], "a", "b"), true);
});
