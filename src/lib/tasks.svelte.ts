import { page } from "$app/state";
import {
  createCreateFolder,
  createCreateProject,
  createCreateTask,
  createDeleteFolder,
  createDeleteTask,
  createListFolders,
  createListMetadataFields,
  createListProjects,
  createListTasks,
  createMoveProject,
  createToggleTask,
  createUpdateFolder,
  type Folder,
  type Project,
  type Task,
  type TaskInput,
} from "./api/generated";
import { projectOrder } from "./folders";
import { parseTaskInput } from "./task-parser";
import { dateFromToday, todaySection } from "./task-views";

function errorMessage(error: unknown) {
  if (!error) return "";
  if (typeof error === "string") return error;
  return error instanceof Error ? error.message : "Could not reach the task server";
}

type TaskStore = ReturnType<typeof buildTaskStore>;

let store: TaskStore | null = null;

/**
 * Builds the shared task store. Must be called during component init inside a `QueryClientProvider`
 * (see `AppShell.svelte`) because TanStack's create* helpers need the query client context.
 */
export function initTaskStore() {
  return (store ??= buildTaskStore());
}

export function useTasks() {
  if (!store) throw new Error("useTasks() ran before AppShell initialised the task store.");
  return store;
}

function buildTaskStore() {
  const tasksQuery = createListTasks();
  const projectsQuery = createListProjects();
  const foldersQuery = createListFolders();
  const fieldsQuery = createListMetadataFields();
  const createTask = createCreateTask();
  const createProject = createCreateProject();
  const createFolder = createCreateFolder();
  const renameFolder = createUpdateFolder();
  const deleteFolderMutation = createDeleteFolder();
  const moveProjectMutation = createMoveProject();
  const toggleTaskMutation = createToggleTask();
  const deleteTaskMutation = createDeleteTask();

  const state = $state({
    notice: "",
    draft: "",
    now: new Date(),
    showCompleted: false,
    newProjectName: "",
    drawerOpen: false,
    composerOpen: false,
    confirmName: null as string | null,
  });

  let answerProject: ((approved: boolean) => void) | null = null;

  const tasks = $derived<Task[]>(tasksQuery.data?.data ?? []);
  const fields = $derived(fieldsQuery.data?.data ?? []);
  const folders = $derived<Folder[]>(foldersQuery.data?.data ?? []);
  const projects = $derived<Project[]>([...(projectsQuery.data?.data ?? [])].sort(projectOrder));
  const loading = $derived(tasksQuery.isPending);
  const busy = $derived(
    createTask.isPending ||
      createProject.isPending ||
      createFolder.isPending ||
      renameFolder.isPending ||
      deleteFolderMutation.isPending ||
      moveProjectMutation.isPending ||
      toggleTaskMutation.isPending ||
      deleteTaskMutation.isPending,
  );
  const error = $derived(
    errorMessage(
      tasksQuery.error ??
        projectsQuery.error ??
        foldersQuery.error ??
        fieldsQuery.error ??
        createTask.error ??
        createProject.error ??
        createFolder.error ??
        renameFolder.error ??
        deleteFolderMutation.error ??
        moveProjectMutation.error ??
        toggleTaskMutation.error ??
        deleteTaskMutation.error,
    ),
  );
  const today = $derived(dateFromToday(state.now, 0));
  /** New tasks land in the project being viewed, else Inbox. */
  const routeProjectId = $derived(page.route.id === "/projects/[id]" ? page.params.id ?? "inbox" : "inbox");
  const defaultProjectName = $derived(projectById(routeProjectId)?.name ?? "Inbox");
  const parsedDraft = $derived(parseTaskInput(state.draft));
  const openCount = $derived(tasks.filter((task) => !task.completed).length);
  const taskQueryError = $derived(tasksQuery.isError && !tasksQuery.data);
  const todayCount = $derived(tasks.filter((task) => !task.completed && todaySection(task, today)).length);

  function projectById(id: string) {
    return projects.find((project) => project.id === id);
  }

  function openCountFor(projectId: string) {
    return tasks.filter((task) => !task.completed && task.projectId === projectId).length;
  }

  /** Applies the "show completed" toggle. Call inside a `$derived` so it tracks state. */
  function visible(list: Task[]) {
    return state.showCompleted ? list : list.filter((task) => !task.completed);
  }

  function openComposer() {
    state.notice = "";
    if (!createTask.isPending) createTask.reset();
    state.composerOpen = true;
  }

  async function addTask() {
    const parsed = parseTaskInput(state.draft);
    if (!parsed.title || busy) return;

    try {
      const projectId = await projectIdFor(parsed.project);
      if (!projectId) return;
      const projectName = projectById(projectId)?.name ?? parsed.project!;
      const task: TaskInput = {
        id: crypto.randomUUID(),
        title: parsed.title,
        projectId,
        plannedFor: parsed.plannedFor,
        dueOn: parsed.dueOn,
        repeatWeekday: parsed.repeatWeekday,
        completed: false,
      };

      const response = await createTask.mutateAsync({ data: task });
      if (response.status !== 201) throw new Error(response.data);
      state.draft = "";
      state.composerOpen = false;
      state.notice = `Added “${task.title}” to ${projectName}.`;
    } catch {
      // The mutation exposes the error through syncError.
    }
  }

  /** Resolves a `#project` name, asking before an unknown one is created. Returns null if declined. */
  async function projectIdFor(name: string | null) {
    if (!name) return projectById(routeProjectId)?.id ?? "inbox";
    const existing = projects.find((project) => project.name.toLowerCase() === name.toLowerCase());
    if (existing) return existing.id;

    if (!(await askAboutProject(name))) return null;

    return await createProjectNamed(name);
  }

  function askAboutProject(name: string) {
    state.confirmName = name;
    return new Promise<boolean>((resolve) => (answerProject = resolve));
  }

  function answerConfirm(approved: boolean) {
    const resolve = answerProject;
    answerProject = null;
    state.confirmName = null;
    resolve?.(approved);
  }

  async function createProjectNamed(name: string) {
    const response = await createProject.mutateAsync({ data: { name } });
    if (response.status !== 201) throw new Error(response.data);
    return response.data.id;
  }

  /** Returns the new project id, or null when the name was blank or the request failed. */
  async function addProject() {
    const name = state.newProjectName.trim();
    if (!name || busy) return null;

    try {
      state.newProjectName = "";
      return await createProjectNamed(name);
    } catch {
      // The mutation exposes the error through syncError.
      return null;
    }
  }

  /** Returns the new folder id, or null when the name was blank or the request failed. */
  async function addFolder(name: string, parentId: string | null) {
    if (!name.trim() || busy) return null;

    try {
      const response = await createFolder.mutateAsync({ data: { name: name.trim(), parentId } });
      if (response.status !== 201) throw new Error(response.data);
      return response.data.id;
    } catch {
      // The mutation exposes the error through syncError.
      return null;
    }
  }

  /** Renames and re-parents in one request, so the current parent has to travel with the name. */
  async function moveFolder(id: string, parentId: string | null) {
    const folder = folders.find((item) => item.id === id);
    if (!folder || busy || folder.parentId === parentId) return;

    try {
      await renameFolder.mutateAsync({
        id,
        data: { name: folder.name, parentId },
      });
    } catch {
      // The mutation exposes the error through syncError.
    }
  }

  async function renameFolderTo(id: string, name: string, parentId: string | null) {
    if (!name.trim() || busy) return;
    try {
      await renameFolder.mutateAsync({ id, data: { name: name.trim(), parentId } });
    } catch {
      // The mutation exposes the error through syncError.
    }
  }

  async function removeFolder(id: string) {
    if (busy) return;
    try {
      await deleteFolderMutation.mutateAsync({ id });
    } catch {
      // The mutation exposes the error through syncError.
    }
  }

  /** Files a project into a folder, or at the top level when `folderId` is null. */
  async function moveProject(id: string, folderId: string | null) {
    const project = projectById(id);
    if (!project || busy || (project.folderId ?? null) === folderId) return;

    try {
      await moveProjectMutation.mutateAsync({ id, data: { folderId } });
    } catch {
      // The mutation exposes the error through syncError.
    }
  }

  async function toggleTask(id: string) {
    const task = tasks.find((item) => item.id === id);
    if (!task || busy) return;

    try {
      const response = await toggleTaskMutation.mutateAsync({ id, data: { completed: !task.completed } });
      if (response.status !== 200) throw new Error(response.data);
    } catch {
      // The mutation exposes the error through syncError.
    }
  }

  async function deleteTask(id: string) {
    if (busy) return;
    try {
      await deleteTaskMutation.mutateAsync({ id });
    } catch {
      // The mutation exposes the error through syncError.
    }
  }

  // Getters, not values: a plain object literal would snapshot the deriveds above.
  return {
    state,
    get tasks() {
      return tasks;
    },
    get fields() {
      return fields;
    },
    get folders() {
      return folders;
    },
    get projects() {
      return projects;
    },
    get loading() {
      return loading;
    },
    get busy() {
      return busy;
    },
    get error() {
      return error;
    },
    get today() {
      return today;
    },
    get defaultProjectName() {
      return defaultProjectName;
    },
    get parsedDraft() {
      return parsedDraft;
    },
    get openCount() {
      return openCount;
    },
    get todayCount() {
      return todayCount;
    },
    get taskQueryError() {
      return taskQueryError;
    },
    refetchTasks: () => tasksQuery.refetch(),
    projectById,
    openCountFor,
    visible,
    openComposer,
    addTask,
    addProject,
    addFolder,
    moveFolder,
    renameFolderTo,
    removeFolder,
    moveProject,
    toggleTask,
    deleteTask,
    answerConfirm,
  };
}
