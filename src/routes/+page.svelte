<script lang="ts">
  import { onMount } from "svelte";
  import ProjectMetadata from "$lib/ProjectMetadata.svelte";
  import { todaySection } from "$lib/task-views";
  import {
    createCreateProject,
    createCreateTask,
    createDeleteTask,
    createListMetadataFields,
    createListProjects,
    createListTasks,
    createToggleTask,
    type Project,
    type Task,
    type TaskInput,
  } from "$lib/api/generated";
  import { parseTaskInput } from "$lib/task-parser";

  const weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

  function dateFromToday(days: number) {
    const date = new Date(now);
    date.setDate(date.getDate() + days);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  }

  function errorMessage(error: unknown) {
    if (!error) return "";
    if (typeof error === "string") return error;
    return error instanceof Error ? error.message : "Could not reach the task server";
  }

  const tasksQuery = createListTasks();
  const projectsQuery = createListProjects();
  const fieldsQuery = createListMetadataFields();
  const createTask = createCreateTask();
  const createProjectMutation = createCreateProject();
  const toggleTaskMutation = createToggleTask();
  const deleteTaskMutation = createDeleteTask();

  let draft = $state("");
  let newProjectName = $state("");
  let view = $state<"today" | "all" | "project">("today");
  let activeProjectId = $state("inbox");
  let pendingProjectName = $state("");
  let answerProject: ((approved: boolean) => void) | null = null;
  let drawer: HTMLDialogElement;
  let composer: HTMLDialogElement;
  let confirmProject: HTMLDialogElement;
  let taskInput: HTMLInputElement;
  let now = $state(new Date());
  let notice = $state("");

  onMount(() => {
    const timer = window.setInterval(() => (now = new Date()), 60_000);
    return () => window.clearInterval(timer);
  });

  const today = $derived(dateFromToday(0));
  let showCompleted = $state(false);

  const tasks = $derived<Task[]>(tasksQuery.data?.data ?? []);
  const fields = $derived(fieldsQuery.data?.data ?? []);
  const projects = $derived<Project[]>(
    [...(projectsQuery.data?.data ?? [])].sort((a, b) =>
      a.name === "Inbox" ? -1 : b.name === "Inbox" ? 1 : a.name.localeCompare(b.name),
    ),
  );
  const activeProject = $derived(projects.find((project) => project.id === activeProjectId) ?? projects[0]);
  const viewTitle = $derived(
    view === "today" ? "Today" : view === "all" ? "All tasks" : activeProject?.name ?? "Inbox",
  );
  const loading = $derived(tasksQuery.isPending);
  const busy = $derived(
    createTask.isPending ||
      createProjectMutation.isPending ||
      toggleTaskMutation.isPending ||
      deleteTaskMutation.isPending,
  );
  const syncError = $derived(
    errorMessage(
      tasksQuery.error ??
        projectsQuery.error ??
        fieldsQuery.error ??
        createTask.error ??
        createProjectMutation.error ??
        toggleTaskMutation.error ??
        deleteTaskMutation.error,
    ),
  );
  const parsedDraft = $derived(parseTaskInput(draft));
  const visibleTasks = $derived(
    tasks.filter(
      (task) =>
        (view === "today"
          ? todaySection(task, today) !== null
          : view === "all" || task.projectId === activeProjectId) &&
        (showCompleted || !task.completed),
    ),
  );
  const openCount = $derived(tasks.filter((task) => !task.completed).length);
  const todayCount = $derived(tasks.filter((task) => !task.completed && todaySection(task, today)).length);
  const viewCount = $derived(visibleTasks.filter((task) => !task.completed).length);
  const sections = $derived(
    view === "today"
      ? ["Overdue", "Due today", "Planned today"].map((title) => ({
          title,
          tasks: visibleTasks.filter((task) => todaySection(task, today) === title),
        })).filter((section) => section.tasks.length)
      : [{ title: "Your tasks", tasks: visibleTasks }],
  );

  function navigate(next: typeof view, projectId = activeProjectId) {
    view = next;
    activeProjectId = projectId;
    drawer.close();
  }

  /** Resolves a `#project` name, asking before an unknown one is created. Returns null if declined. */
  async function projectIdFor(name: string | null) {
    if (!name) return activeProject?.id ?? "inbox";
    const existing = projects.find((project) => project.name.toLowerCase() === name.toLowerCase());
    if (existing) return existing.id;

    if (!(await askAboutProject(name))) return null;

    const response = await createProjectMutation.mutateAsync({ data: { name } });
    if (response.status !== 201) throw new Error(response.data);
    return response.data.id;
  }

  function askAboutProject(name: string) {
    pendingProjectName = name;
    confirmProject.showModal();
    return new Promise<boolean>((resolve) => (answerProject = resolve));
  }

  function settleProject(approved: boolean) {
    const resolve = answerProject;
    answerProject = null;
    confirmProject.close();
    resolve?.(approved);
  }

  async function addProject(event: SubmitEvent) {
    event.preventDefault();
    const name = newProjectName.trim();
    if (!name || busy) return;

    try {
      const response = await createProjectMutation.mutateAsync({ data: { name } });
      if (response.status !== 201) throw new Error(response.data);
      newProjectName = "";
      navigate("project", response.data.id);
    } catch {
      // The mutation exposes the error through syncError.
    }
  }

  function openComposer() {
    notice = "";
    if (!createTask.isPending) createTask.reset();
    composer.showModal();
    taskInput.focus();
  }

  async function addTask(event: SubmitEvent) {
    event.preventDefault();
    const parsed = parseTaskInput(draft);
    if (!parsed.title || busy) return;

    try {
      const projectId = await projectIdFor(parsed.project);
      if (!projectId) return;
      const projectName = projects.find((project) => project.id === projectId)?.name ?? parsed.project!;
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
      draft = "";
      composer.close();
      notice = `Added “${task.title}” to ${projectName}.`;
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

  function countFor(projectId: string) {
    return tasks.filter((task) => !task.completed && task.projectId === projectId).length;
  }

  function displayDate(value: string) {
    if (value === dateFromToday(0)) return "Today";
    if (value === dateFromToday(1)) return "Tomorrow";
    return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(
      new Date(`${value}T00:00:00`),
    );
  }
</script>

<svelte:head>
  <title>Adhocly — {viewTitle}</title>
  <meta name="description" content="Make room for today. A thoughtful task list with quick, natural-language capture." />
</svelte:head>

{#snippet icon(name: "menu" | "sun" | "list" | "plus" | "close" | "arrow")}
  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
    {#if name === "menu"}
      <path d="M4 6h16M4 12h10M4 18h16" />
    {:else if name === "sun"}
      <circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" />
    {:else if name === "list"}
      <path d="M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01" />
    {:else if name === "plus"}
      <path d="M12 5v14M5 12h14" />
    {:else if name === "close"}
      <path d="m6 6 12 12M6 18 18 6" />
    {:else}
      <path d="M12 19V5m-6 6 6-6 6 6" />
    {/if}
  </svg>
{/snippet}

<div class="app-shell">
  <header class="topbar">
    <div class="topbar-left">
      <button class="icon-button menu-button" onclick={() => drawer.showModal()} aria-label="Open project navigation" aria-haspopup="dialog" aria-controls="project-drawer">
        {@render icon("menu")}
      </button>
      <span class="wordmark">adhocly<span>.</span></span>
    </div>
  </header>

  <main>
    <header class="view-heading">
      <h1>{viewTitle}<span class="title-dot">.</span></h1>
      <div class="view-tools">
        <label class="completed-toggle">
          <input type="checkbox" bind:checked={showCompleted} />
          Show completed
        </label>
        <span class="status" aria-label={`${viewCount} open tasks in this view`}>{String(viewCount).padStart(2, "0")}</span>
      </div>
    </header>

    {#if syncError}
      <p class="sync-error" role="alert">{syncError}</p>
    {/if}
    <p class="notice" role="status">{notice}</p>

    {#if view === "project" && activeProject}
      <ProjectMetadata
        project={activeProject}
        {fields}
        onDeleted={() => {
          navigate("all", "inbox");
          notice = "Project deleted. Its tasks are in Inbox.";
        }}
      />
    {/if}

    <section class="task-section" aria-label={`${viewTitle} tasks`}>
      {#if loading}
        <div class="empty-state" role="status"><p>Gathering your tasks…</p></div>
      {:else if tasksQuery.isError && !tasksQuery.data}
        <div class="empty-state">
          <h2>Let’s reconnect.</h2>
          <p>Couldn’t load your tasks.</p>
          <button class="text-button" onclick={() => tasksQuery.refetch()}>Try again →</button>
        </div>
      {:else if visibleTasks.length === 0}
        <div class="empty-state">
          <div class="empty-mark">{@render icon(view === "today" ? "sun" : "list")}</div>
          <h2>{view === "today" ? "Nothing today." : "Clear for now."}</h2>
          <button class="text-button" onclick={openComposer}>Add a task <span aria-hidden="true">↗</span></button>
        </div>
      {:else}
        {#each sections as section (section.title)}
          <div class="task-group">
            {#if sections.length > 1}
              <h2 class="group-title" class:overdue={section.title === "Overdue"}>
                <span class="group-dot"></span>{section.title}<span class="group-count">{section.tasks.length}</span>
              </h2>
            {/if}
            <div class="task-list">
              {#each section.tasks as task (task.id)}
                <article class:done={task.completed} class="task-card">
                  <button class="check" class:checked={task.completed} onclick={() => toggleTask(task.id)} disabled={busy} aria-label={task.completed ? `Mark ${task.title} incomplete` : `Complete ${task.title}`}>
                    {#if task.completed}✓{/if}
                  </button>
                  <div class="task-body">
                    <h3>{task.title}</h3>
                    <div class="metadata">
                      <button class="project-name" onclick={() => navigate("project", task.projectId)}><span></span>{task.project}</button>
                      {#if task.plannedFor}
                        <span class="meta plan">↗ Plan {displayDate(task.plannedFor)}</span>
                      {/if}
                      {#if task.dueOn}
                        <span class:overdue={task.dueOn < today} class="meta due">◇ Due {displayDate(task.dueOn)}</span>
                      {/if}
                      {#if task.repeatWeekday != null}
                        <span class="meta plan">↻ Every {weekdayNames[task.repeatWeekday]}</span>
                      {/if}
                    </div>
                  </div>
                  <button class="delete icon-button" onclick={() => deleteTask(task.id)} disabled={busy} aria-label={`Delete ${task.title}`}>
                    {@render icon("close")}
                  </button>
                </article>
              {/each}
            </div>
          </div>
        {/each}
      {/if}
    </section>
  </main>

  <nav class="bottom-bar" aria-label="Main navigation">
    <div class="bottom-inner">
      <button class="bottom-link" class:active={view === "today"} aria-current={view === "today" ? "page" : undefined} onclick={() => navigate("today")}>
        <span class="bottom-icon">{@render icon("sun")}{#if todayCount}<span class="nav-count">{todayCount}</span>{/if}</span>
        <span>Today</span>
      </button>
      <button class="add-button" onclick={openComposer} aria-label="Create a task" aria-haspopup="dialog" aria-controls="task-composer">
        {@render icon("plus")}
      </button>
      <button class="bottom-link" class:active={view === "all"} aria-current={view === "all" ? "page" : undefined} onclick={() => navigate("all")}>
        {@render icon("list")}<span>All tasks</span>
      </button>
    </div>
  </nav>
</div>

<dialog bind:this={drawer} id="project-drawer" class="drawer" aria-labelledby="drawer-title">
  <aside class="sidebar">
    <header class="drawer-header">
      <span class="wordmark" id="drawer-title">adhocly<span>.</span></span>
      <button class="icon-button" onclick={() => drawer.close()} aria-label="Close project navigation">{@render icon("close")}</button>
    </header>
    <nav class="project-nav" aria-label="Projects and task views">
      <p class="nav-label">Workspace</p>
      <button class:active={view === "today"} aria-current={view === "today" ? "page" : undefined} onclick={() => navigate("today")}>
        {@render icon("sun")}<span>Today</span><em>{todayCount}</em>
      </button>
      <button class:active={view === "all"} aria-current={view === "all" ? "page" : undefined} onclick={() => navigate("all")}>
        {@render icon("list")}<span>All tasks</span><em>{openCount}</em>
      </button>
      <p class="nav-label project-heading">Projects <span>#</span></p>
      {#each projects as project (project.id)}
        <button class:active={view === "project" && activeProjectId === project.id} aria-current={view === "project" && activeProjectId === project.id ? "page" : undefined} onclick={() => navigate("project", project.id)}>
          <span class="project-dot" class:inbox={project.id === "inbox"}></span><span class="project-label">{project.name}</span><em>{countFor(project.id)}</em>
        </button>
      {/each}
      <form class="new-project" onsubmit={addProject}>
        <input bind:value={newProjectName} placeholder="New project" aria-label="New project name" autocomplete="off" disabled={busy} />
        <button type="submit" disabled={busy || !newProjectName.trim()} aria-label="Create project">+</button>
      </form>
    </nav>
    <footer class="sidebar-footer"><span>#</span><p>Type <b>#project</b> in a new task to file it.</p></footer>
  </aside>
</dialog>

<dialog bind:this={composer} id="task-composer" class="composer" aria-labelledby="capture-title">
  <section class="capture">
    <header class="capture-heading">
      <h2 id="capture-title">What needs doing?</h2>
      <button class="icon-button" onclick={() => composer.close()} aria-label="Close task entry">{@render icon("close")}</button>
    </header>
    <form onsubmit={addTask}>
      <label for="task-input" class="sr-only">New task</label>
      <input id="task-input" bind:this={taskInput} bind:value={draft} autocomplete="off" placeholder="A task, a thought, a little reminder…" aria-describedby="capture-help" disabled={createTask.isPending} />
      <button class="submit-task" type="submit" aria-label="Add task" disabled={!parsedDraft.title || busy}>{@render icon("arrow")}</button>
    </form>
    <div class="syntax" aria-live="polite">
      <span class="project-chip">#{parsedDraft.project || activeProject?.name || "Inbox"}</span>
      {#if parsedDraft.plannedFor}<span class="plan-chip">Plan · {displayDate(parsedDraft.plannedFor)}</span>{/if}
      {#if parsedDraft.dueOn}<span class="due-chip">Due · {displayDate(parsedDraft.dueOn)}</span>{/if}
      {#if parsedDraft.repeatWeekday != null}<span class="plan-chip">Every {weekdayNames[parsedDraft.repeatWeekday]}</span>{/if}
      {#if createTask.isPending}<span>Saving…</span>{/if}
    </div>
    {#if syncError}<p class="sync-error" role="alert">{syncError}</p>{/if}
    <p id="capture-help" class="capture-help"><b>#project</b> to organise <span>·</span> <b>@today</b> to plan <span>·</span> <b>!friday</b> for a deadline <span>·</span> <b>@every friday</b> to repeat</p>
  </section>
</dialog>

<dialog
  bind:this={confirmProject}
  class="confirm"
  aria-labelledby="confirm-project-title"
  onclose={() => settleProject(false)}
>
  <section class="confirm-body">
    <h2 id="confirm-project-title">Create this project?</h2>
    <p><span class="confirm-name">#{pendingProjectName}</span> doesn’t exist yet. Create it and file this task there?</p>
    <div class="confirm-actions">
      <button type="button" onclick={() => settleProject(false)} disabled={createProjectMutation.isPending}>Keep editing</button>
      <button type="button" class="primary" onclick={() => settleProject(true)} disabled={createProjectMutation.isPending}>Create project</button>
    </div>
  </section>
</dialog>

<style>
  :global(*) { box-sizing: border-box; }
  :global(:root) {
    font-family: "Avenir Next", Avenir, "Gill Sans", sans-serif;
    color: #292d26;
    background: #f6f3ec;
    font-synthesis: none;
    text-rendering: optimizeLegibility;
    --ink: #292d26;
    --muted: #77776b;
    --paper: #f6f3ec;
    --line: #e2dfd4;
    --red: #c64e36;
    --green: #60745b;
  }
  :global(body) { margin: 0; min-width: 320px; min-height: 100dvh; }
  :global(body:has(dialog[open])) { overflow: hidden; }
  :global(button), :global(input) { font: inherit; }
  :global(button) { color: inherit; cursor: pointer; -webkit-tap-highlight-color: transparent; }
  :global(button:disabled) { cursor: not-allowed; opacity: .45; }
  :global(:focus-visible) { outline: 2px solid var(--red); outline-offset: 4px; }
  :global(::selection) { color: var(--ink); background: #f0cbbb; }
  .app-shell { min-height: 100dvh; }
  .topbar {
    position: sticky; top: 0; z-index: 9; background: var(--paper);
    display: flex; align-items: center; justify-content: space-between; gap: 16px;
    min-height: 89px; padding: calc(18px + env(safe-area-inset-top)) max(24px, env(safe-area-inset-right)) 18px max(24px, env(safe-area-inset-left));
    border-bottom: 1px solid var(--line);
  }
  .topbar-left { display: flex; align-items: center; gap: 20px; }
  .icon-button { display: grid; place-items: center; width: 44px; height: 44px; flex-shrink: 0; padding: 0; border: 0; border-radius: 12px; background: transparent; }
  .icon-button:hover { background: #e7e6dc; }
  .menu-button { border: 1px solid var(--line); }
  .wordmark { font-family: Georgia, "Times New Roman", serif; font-size: 27px; font-weight: bold; letter-spacing: -.055em; }
  .wordmark > span { color: var(--red); }
  main { width: min(100%, 860px); margin: 0 auto; padding: 44px 32px calc(120px + env(safe-area-inset-bottom)); }
  .view-heading { display: flex; align-items: center; justify-content: space-between; gap: 24px; margin-bottom: 30px; }
  .view-tools { display: flex; align-items: center; gap: 20px; }
  .nav-label { margin: 0; color: var(--muted); font-size: 10px; font-weight: 600; letter-spacing: .14em; text-transform: uppercase; }
  h1 { margin: 0; font-family: Georgia, "Times New Roman", serif; font-size: clamp(34px, 6vw, 52px); line-height: 1.1; font-weight: 400; letter-spacing: -.055em; overflow-wrap: anywhere; }
  .title-dot { color: var(--red); }
  .status { font-family: Georgia, serif; font-size: 30px; letter-spacing: -.04em; }
  .notice { color: var(--green); font-size: 12px; overflow-wrap: anywhere; }
  .notice:empty { margin: 0; }
  .sync-error { padding: 12px 14px; color: #a33828; background: #fbe8e0; border-radius: 8px; font-size: 12px; overflow-wrap: anywhere; }
  .completed-toggle { display: flex; align-items: center; gap: 7px; min-height: 44px; color: var(--muted); font-size: 11px; cursor: pointer; }
  .completed-toggle input { width: 14px; height: 14px; margin: 0; accent-color: var(--green); }
  .task-group { margin-top: 22px; }
  .task-group:first-child { margin-top: 0; }
  .group-title { display: flex; align-items: center; gap: 9px; margin: 0 0 12px; font-size: 12px; font-weight: 600; }
  .group-dot { width: 6px; height: 6px; border-radius: 50%; background: var(--green); }
  .group-title.overdue { color: var(--red); }
  .overdue .group-dot { background: var(--red); }
  .group-count { color: var(--muted); font-size: 10px; font-weight: 400; }
  .task-list { display: grid; gap: 7px; }
  .task-card { display: grid; grid-template-columns: 44px minmax(0, 1fr) 44px; align-items: center; gap: 7px; min-height: 88px; padding: 10px 8px; border: 1px solid var(--line); border-radius: 12px; background: #fdfbf6; transition: border-color 140ms; animation: arrive 220ms ease both; }
  .task-card:hover { border-color: #b8bca9; }
  .task-card.done h3 { color: var(--muted); text-decoration: line-through; }
  .check { position: relative; display: grid; place-items: center; width: 44px; height: 44px; padding: 0; border: 0; background: transparent; color: white; font-size: 12px; isolation: isolate; }
  .check::before { content: ""; position: absolute; z-index: -1; inset: 11px; border: 1.5px solid #b6b9a9; border-radius: 50%; }
  .check:hover::before { border-color: var(--green); }
  .check.checked::before { background: var(--green); border-color: var(--green); }
  .task-body { min-width: 0; }
  .task-body h3 { margin: 0 0 6px; font-size: 14px; line-height: 1.5; font-weight: 500; overflow-wrap: anywhere; }
  .metadata { display: flex; flex-wrap: wrap; align-items: center; gap: 3px 12px; color: var(--muted); font-size: 10px; }
  .project-name { display: flex; align-items: center; gap: 5px; min-height: 24px; max-width: 100%; padding: 0; border: 0; background: transparent; color: #62705c; text-align: left; overflow-wrap: anywhere; }
  .project-name > span { width: 5px; height: 5px; flex-shrink: 0; border-radius: 50%; background: #8b9c83; }
  .meta.plan { color: #546e77; }
  .meta.overdue { color: var(--red); }
  .delete { color: #9a8a7d; opacity: 0; transition: opacity 120ms; }
  .delete :global(svg) { width: 17px; height: 17px; }
  .task-card:hover .delete, .task-card:focus-within .delete { opacity: 1; }
  .delete:hover { color: var(--red); background: #f8e5dc; }
  .empty-state { padding: 62px 20px; text-align: center; }
  .empty-mark { display: grid; place-items: center; width: 64px; height: 64px; margin: 0 auto 26px; color: var(--green); border: 1px solid #d9ddcd; border-radius: 50%; background: #edefe3; }
  .empty-mark :global(svg) { width: 29px; height: 29px; }
  .empty-state h2 { margin: 0; font-family: Georgia, serif; font-weight: 400; font-size: clamp(25px, 5vw, 32px); letter-spacing: -.035em; }
  .empty-state > p { max-width: 330px; margin: 8px auto 0; color: var(--muted); font-size: 13px; line-height: 1.8; }
  .text-button { min-height: 44px; margin-top: 16px; padding: 8px; border: 0; background: transparent; color: var(--red); font-size: 12px; font-weight: 600; }
  .text-button span { padding-left: 10px; }
  .bottom-bar { position: fixed; z-index: 10; inset: auto 0 0; padding: 0 env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left); border-top: 1px solid var(--line); background: #faf8f2f5; backdrop-filter: blur(16px); }
  .bottom-inner { display: grid; grid-template-columns: 1fr 96px 1fr; align-items: center; max-width: 700px; height: 82px; margin: 0 auto; }
  .bottom-link { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 5px; height: 100%; padding: 8px; border: 0; background: transparent; color: var(--muted); font-size: 10px; font-weight: 600; letter-spacing: .025em; }
  .bottom-link.active { color: var(--red); }
  .bottom-link:hover { background: #ebe7dc55; }
  .bottom-icon { position: relative; display: flex; }
  .nav-count { position: absolute; top: -5px; left: 24px; min-width: 16px; padding: 1px 4px; border-radius: 5px; background: #eee5d9; color: #8a5745; font-size: 9px; }
  .add-button { display: grid; place-items: center; justify-self: center; width: 58px; height: 58px; margin-top: -25px; padding: 0; border: 5px solid var(--paper); border-radius: 21px; box-sizing: content-box; background: var(--red); color: white; box-shadow: 0 6px 16px #713b2520; transition: transform 150ms, background 150ms; }
  .add-button :global(svg) { width: 28px; height: 28px; }
  .add-button:hover { transform: translateY(-3px); background: #b7422c; }
  dialog { padding: 0; border: 0; color: var(--ink); }
  dialog::backdrop { background: #20251d66; backdrop-filter: blur(3px); }
  .drawer { inset: 0 auto 0 0; width: min(340px, calc(100% - 32px)); max-width: none; height: 100dvh; max-height: 100dvh; margin: 0; background: #292f27; color: #f4f0e7; }
  .drawer[open] { animation: drawer-in 200ms ease-out; }
  .sidebar { display: flex; flex-direction: column; min-height: 100%; padding: calc(24px + env(safe-area-inset-top)) 22px calc(20px + env(safe-area-inset-bottom)) max(22px, env(safe-area-inset-left)); }
  .drawer-header { display: flex; align-items: center; justify-content: space-between; margin-bottom: 34px; }
  .drawer .wordmark { font-size: 32px; }
  .drawer .wordmark > span { color: #eb8c71; }
  .drawer .icon-button:hover { background: #ffffff10; }
  .project-nav { display: grid; gap: 5px; }
  .nav-label { padding: 0 12px 10px; color: #a7ae9e; }
  .project-heading { display: flex; justify-content: space-between; margin-top: 28px; }
  .project-nav button { display: grid; grid-template-columns: 22px minmax(0, 1fr) auto; align-items: center; gap: 12px; min-height: 48px; padding: 10px 12px; border: 0; border-radius: 9px; background: transparent; color: #cbd0c3; text-align: left; font-size: 13px; }
  .project-nav button:hover { background: #ffffff08; }
  .project-nav button.active { background: #404938; color: #fff; }
  .project-nav button.active :global(svg) { color: #edaf83; }
  .project-nav em { color: #b2bbaa; font-size: 11px; font-style: normal; }
  .project-label { overflow-wrap: anywhere; }
  .project-dot { width: 8px; height: 8px; margin-left: 6px; border-radius: 3px; background: #8ba6ac; }
  .project-dot.inbox { background: #d6a96d; }
  .new-project { display: grid; grid-template-columns: minmax(0, 1fr) 34px; gap: 6px; margin-top: 10px; padding: 0 12px; }
  .new-project input { min-width: 0; padding: 8px 10px; border: 1px solid #4b5442; border-radius: 7px; background: #ffffff0d; color: #f4f0e7; font-size: 12px; }
  .new-project input::placeholder { color: #8f9787; }
  .new-project button { border: 0; border-radius: 7px; background: #4b5442; color: #f4f0e7; font-size: 16px; }
  .sidebar-footer { display: flex; align-items: center; gap: 12px; margin-top: auto; padding: 32px 12px 0; color: #b0b6a7; font-size: 11px; line-height: 1.8; }
  .sidebar-footer > span { font-family: Georgia, serif; font-size: 28px; color: #ce9f77; }
  .sidebar-footer p { margin: 0; }
  .sidebar-footer b { color: #deded2; font-weight: 500; }
  .composer { inset: auto 0 0; width: min(760px, calc(100% - 40px)); max-width: none; max-height: calc(100dvh - env(safe-area-inset-top) - 20px); margin: 0 auto calc(104px + env(safe-area-inset-bottom)); border: 1px solid var(--line); border-radius: 20px; background: #fcfaf5; box-shadow: 0 24px 70px #20251d33; }
  .composer[open] { animation: arrive 180ms ease-out; }
  .capture { padding: 26px; }
  .capture-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 22px; }
  .capture h2 { margin: 0; font-family: Georgia, serif; font-size: 28px; font-weight: 400; letter-spacing: -.04em; }
  .capture form { display: flex; align-items: center; gap: 8px; padding: 5px; border: 1px solid #d8d7ca; border-radius: 12px; background: white; }
  .capture form:focus-within { border-color: var(--green); box-shadow: 0 0 0 3px #60745b12; }
  .capture form input { width: 100%; min-width: 0; padding: 13px 10px; border: 0; outline: 0; background: transparent; color: var(--ink); font-size: 16px; }
  .capture form input::placeholder { color: #929486; }
  .submit-task { display: grid; place-items: center; flex-shrink: 0; width: 44px; height: 44px; border: 0; border-radius: 9px; background: var(--red); color: white; }
  .syntax { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; min-height: 26px; margin-top: 14px; font-size: 11px; }
  .syntax > span { padding: 4px 8px; border-radius: 5px; overflow-wrap: anywhere; }
  .project-chip { background: #ebeddf; color: #57674b; }
  .plan-chip { background: #e8eef0; color: #476873; }
  .due-chip { background: #f7e5dc; color: #a14a31; }
  .capture-help { display: flex; flex-wrap: wrap; gap: 4px; margin: 18px 0 0; color: var(--muted); font-size: 10px; line-height: 1.8; }
  .capture-help b { font-weight: 600; color: #5e6556; }
  .capture-help > span { padding: 0 5px; }
  .confirm { width: min(400px, calc(100% - 32px)); padding: 0; border: 1px solid var(--line); border-radius: 16px; background: #fcfaf5; }
  .confirm::backdrop { background: #20251d66; backdrop-filter: blur(3px); }
  .confirm-body { padding: 24px; }
  .confirm h2 { margin: 0 0 10px; font-family: Georgia, serif; font-size: 24px; font-weight: 400; letter-spacing: -.04em; }
  .confirm p { margin: 0 0 20px; color: var(--muted); font-size: 13px; line-height: 1.8; overflow-wrap: anywhere; }
  .confirm-name { color: var(--ink); font-weight: 600; }
  .confirm-actions { display: flex; justify-content: flex-end; gap: 8px; }
  .confirm-actions button { min-height: 40px; padding: 8px 14px; border: 1px solid var(--line); border-radius: 9px; background: transparent; font-size: 12px; font-weight: 600; }
  .confirm-actions .primary { border-color: transparent; background: var(--red); color: white; }
  .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; overflow: hidden; clip: rect(0, 0, 0, 0); white-space: nowrap; border: 0; }
  @keyframes arrive { from { opacity: 0; transform: translateY(10px); } }
  @keyframes drawer-in { from { transform: translateX(-100%); } }
  @media (hover: none) { .delete { opacity: 1; } }
  @media (max-width: 600px) {
    .topbar { min-height: 76px; padding-inline: max(18px, env(safe-area-inset-left)) max(18px, env(safe-area-inset-right)); }
    .topbar-left { gap: 14px; }
    main { padding: 36px 20px calc(120px + env(safe-area-inset-bottom)); }
    .view-heading { gap: 12px; margin-bottom: 22px; }
    .view-tools { gap: 14px; }
    .status { font-size: 24px; }
    .completed-toggle { font-size: 10px; }
    .empty-state { padding: 42px 4px; }
    .task-card { gap: 2px; padding-inline: 4px; }
    .bottom-inner { height: 76px; }
    .composer { width: 100%; margin-bottom: 0; max-height: calc(100dvh - env(safe-area-inset-top) - 20px); border-radius: 22px 22px 0 0; }
    .capture { padding: 22px 18px calc(24px + env(safe-area-inset-bottom)); }
    .capture h2 { font-size: 24px; }
  }
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation: none !important; transition: none !important; }
  }
</style>
