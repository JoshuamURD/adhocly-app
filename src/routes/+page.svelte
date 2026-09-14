<script lang="ts">
  import {
    createCreateTask,
    createDeleteTask,
    createListTasks,
    createToggleTask,
    type Task,
    type TaskInput,
  } from "$lib/api/generated";
  import { parseTaskInput } from "$lib/task-parser";

  const weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

  function dateFromToday(days: number) {
    const date = new Date();
    date.setDate(date.getDate() + days);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
  }

  function errorMessage(error: unknown) {
    if (!error) return "";
    if (typeof error === "string") return error;
    return error instanceof Error ? error.message : "Could not reach the task server";
  }

  const tasksQuery = createListTasks();
  const createTask = createCreateTask();
  const toggleTaskMutation = createToggleTask();
  const deleteTaskMutation = createDeleteTask();

  let draft = $state("");
  let activeProject = $state("All tasks");
  let showCompleted = $state(false);

  const tasks = $derived<Task[]>(tasksQuery.data?.data ?? []);
  const loading = $derived(tasksQuery.isPending);
  const busy = $derived(createTask.isPending || toggleTaskMutation.isPending || deleteTaskMutation.isPending);
  const syncError = $derived(
    errorMessage(tasksQuery.error ?? createTask.error ?? toggleTaskMutation.error ?? deleteTaskMutation.error),
  );
  const parsedDraft = $derived(parseTaskInput(draft));
  const projects = $derived(
    ["Inbox", ...new Set(tasks.map((task) => task.project).filter((project) => project !== "Inbox"))].sort((a, b) =>
      a === "Inbox" ? -1 : b === "Inbox" ? 1 : a.localeCompare(b),
    ),
  );
  const visibleTasks = $derived(
    tasks.filter(
      (task) =>
        (activeProject === "All tasks" || task.project === activeProject) &&
        (showCompleted || !task.completed),
    ),
  );
  const openCount = $derived(tasks.filter((task) => !task.completed).length);

  async function addTask(event: SubmitEvent) {
    event.preventDefault();
    const parsed = parseTaskInput(draft);
    if (!parsed.title || busy) return;

    const project = parsed.project
      ? projects.find((name) => name.toLowerCase() === parsed.project?.toLowerCase()) ?? parsed.project
      : "Inbox";
    const task: TaskInput = {
      id: crypto.randomUUID(),
      title: parsed.title,
      project,
      plannedFor: parsed.plannedFor,
      dueOn: parsed.dueOn,
      repeatWeekday: parsed.repeatWeekday,
      completed: false,
    };

    try {
      const response = await createTask.mutateAsync({ data: task });
      if (response.status !== 201) throw new Error(response.data);
      draft = "";
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

  function countFor(project: string) {
    return tasks.filter((task) => !task.completed && task.project === project).length;
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
  <title>Adhocly — make a plan, quickly</title>
  <meta
    name="description"
    content="A fast, project-first task list with natural-language dates."
  />
</svelte:head>

<div class="app-shell">
  <aside class="sidebar">
    <header class="brand">
      <span class="brand-mark" aria-hidden="true">A</span>
      <div>
        <strong>adhocly</strong>
        <small>make room for the work</small>
      </div>
    </header>

    <nav aria-label="Task views">
      <p class="nav-label">Workspace</p>
      <button
        class:active={activeProject === "All tasks"}
        onclick={() => (activeProject = "All tasks")}
      >
        <span class="nav-icon">◎</span>
        <span>All tasks</span>
        <em>{openCount}</em>
      </button>

      <div class="project-heading">
        <p class="nav-label">Projects</p>
        <span title="Create a project by typing #project in a task">#</span>
      </div>
      {#each projects as project}
        <button class:active={activeProject === project} onclick={() => (activeProject = project)}>
          <span class="project-dot" class:inbox={project === "Inbox"}></span>
          <span>{project}</span>
          <em>{countFor(project)}</em>
        </button>
      {/each}
    </nav>

    <footer class="sidebar-footer" aria-live="polite" title={syncError}>
      <span class:error={syncError} class="signal"></span>
      {syncError || (loading ? "Connecting…" : "Synced with server")}
    </footer>
  </aside>

  <main>
    <header class="topbar">
      <div>
        <p class="eyebrow">Current view</p>
        <h1>{activeProject}</h1>
      </div>
      <div class="status">
        <span>{openCount}</span>
        <small>open {openCount === 1 ? "task" : "tasks"}</small>
      </div>
    </header>

    <section class="capture" aria-labelledby="capture-title">
      <div class="capture-copy">
        <p class="eyebrow">Quick capture</p>
        <h2 id="capture-title">What needs doing?</h2>
      </div>
      <form onsubmit={addTask}>
        <label for="task-input" class="sr-only">New task</label>
        <input
          id="task-input"
          bind:value={draft}
          autocomplete="off"
          placeholder="Write a task…  #project  @in 2 days  @every friday"
        />
        <button type="submit" aria-label="Add task" disabled={!parsedDraft.title || busy}>
          <span>Add task</span><b aria-hidden="true">↵</b>
        </button>
      </form>
      {#if syncError}
        <p class="sync-error" role="alert">{syncError}</p>
      {/if}
      <div class="syntax" aria-live="polite">
        {#if parsedDraft.project}
          <span class="project-chip">#{parsedDraft.project}</span>
        {:else}
          <span><b>#project</b> assigns a project</span>
        {/if}
        {#if parsedDraft.plannedFor}
          <span class="plan-chip">Plan · {displayDate(parsedDraft.plannedFor)}</span>
        {:else}
          <span><b>@tomorrow</b> plans it</span>
        {/if}
        {#if parsedDraft.dueOn}
          <span class="due-chip">Due · {displayDate(parsedDraft.dueOn)}</span>
        {:else}
          <span><b>!friday</b> sets a deadline</span>
        {/if}
        {#if parsedDraft.repeatWeekday !== null}
          <span class="plan-chip">Every {weekdayNames[parsedDraft.repeatWeekday]}</span>
        {:else}
          <span><b>@every friday</b> repeats it</span>
        {/if}
      </div>
    </section>

    <section class="task-section" aria-labelledby="task-list-title">
      <div class="section-heading">
        <h2 id="task-list-title">Open work</h2>
        <label class="completed-toggle">
          <input type="checkbox" bind:checked={showCompleted} />
          Show completed
        </label>
      </div>

      <div class="task-list">
        {#if loading}
          <div class="empty-state">
            <p>Loading tasks…</p>
          </div>
        {:else}
        {#each visibleTasks as task (task.id)}
          <article class:done={task.completed} class="task-card">
            <button
              class="check"
              class:checked={task.completed}
              onclick={() => toggleTask(task.id)}
              disabled={busy}
              aria-label={task.completed ? `Mark ${task.title} incomplete` : `Complete ${task.title}`}
            >
              {#if task.completed}✓{/if}
            </button>

            <div class="task-body">
              <h3>{task.title}</h3>
              <div class="metadata">
                <button class="project-name" onclick={() => (activeProject = task.project)}>
                  <span></span>{task.project}
                </button>
                {#if task.plannedFor}
                  <span class="meta plan"><i>↗</i> Plan {displayDate(task.plannedFor)}</span>
                {/if}
                {#if task.dueOn}
                  <span class:overdue={task.dueOn < dateFromToday(0)} class="meta due">
                    <i>◇</i> Due {displayDate(task.dueOn)}
                  </span>
                {/if}
                {#if task.repeatWeekday != null}
                  <span class="meta plan"><i>↻</i> Every {weekdayNames[task.repeatWeekday]}</span>
                {/if}
              </div>
            </div>

            <button class="delete" onclick={() => deleteTask(task.id)} disabled={busy} aria-label={`Delete ${task.title}`}>
              ×
            </button>
          </article>
        {:else}
          <div class="empty-state">
            <span aria-hidden="true">✓</span>
            <h3>Clear for now.</h3>
            <p>Add a task above or choose another project.</p>
          </div>
        {/each}
        {/if}
      </div>
    </section>
  </main>
</div>

<style>
  :global(*) {
    box-sizing: border-box;
  }

  :global(:root) {
    font-family: "Avenir Next", Avenir, "Gill Sans", sans-serif;
    color: #25231f;
    background: #ebe7df;
    font-synthesis: none;
    text-rendering: optimizeLegibility;
    --ink: #25231f;
    --muted: #777269;
    --paper: #f8f5ee;
    --paper-deep: #eee9df;
    --line: #d7d0c4;
    --red: #e45b42;
    --blue: #3f6f7b;
    --green: #637c67;
  }

  :global(body) {
    margin: 0;
    min-width: 320px;
    min-height: 100vh;
    background:
      radial-gradient(circle at 85% 8%, rgba(228, 91, 66, 0.08), transparent 25rem),
      #ebe7df;
  }

  :global(button),
  :global(input) {
    font: inherit;
  }

  :global(button) {
    color: inherit;
  }

  .app-shell {
    min-height: 100vh;
    display: grid;
    grid-template-columns: 248px minmax(0, 1fr);
  }

  .sidebar {
    position: sticky;
    top: 0;
    height: 100vh;
    display: flex;
    flex-direction: column;
    padding: 28px 20px 22px;
    background: #242722;
    color: #f4f0e7;
    border-right: 1px solid #171916;
  }

  .brand {
    display: flex;
    align-items: center;
    gap: 12px;
    margin: 0 8px 46px;
  }

  .brand-mark {
    width: 38px;
    height: 38px;
    display: grid;
    place-items: center;
    color: #242722;
    background: var(--red);
    border-radius: 50% 50% 46% 54% / 55% 44% 56% 45%;
    font-family: Georgia, serif;
    font-size: 21px;
    font-style: italic;
    transform: rotate(-5deg);
  }

  .brand strong {
    display: block;
    font-family: Georgia, "Times New Roman", serif;
    font-size: 20px;
    letter-spacing: -0.03em;
  }

  .brand small {
    display: block;
    margin-top: 1px;
    color: #999c92;
    font-size: 9px;
    letter-spacing: 0.07em;
    text-transform: uppercase;
  }

  nav {
    display: grid;
    gap: 4px;
  }

  .nav-label,
  .eyebrow {
    margin: 0;
    color: #979a91;
    font-size: 10px;
    font-weight: 700;
    letter-spacing: 0.14em;
    text-transform: uppercase;
  }

  nav > .nav-label {
    padding: 0 12px 8px;
  }

  .project-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin: 29px 12px 6px;
  }

  .project-heading span {
    color: #73766e;
    font-family: Georgia, serif;
    font-size: 18px;
  }

  nav button {
    width: 100%;
    display: grid;
    grid-template-columns: 19px 1fr auto;
    align-items: center;
    gap: 7px;
    padding: 9px 11px;
    border: 0;
    border-radius: 7px;
    color: #c5c6bf;
    background: transparent;
    text-align: left;
    cursor: pointer;
    transition: 150ms ease;
  }

  nav button:hover {
    color: #fff;
    background: #2d312b;
  }

  nav button.active {
    color: #fff;
    background: #353a32;
  }

  nav button em {
    color: #777b72;
    font-size: 11px;
    font-style: normal;
  }

  .nav-icon {
    color: #d6a96d;
    font-size: 18px;
  }

  .project-dot {
    width: 8px;
    height: 8px;
    margin-left: 4px;
    border-radius: 50%;
    background: #8ba6ac;
    box-shadow: 0 0 0 3px rgba(139, 166, 172, 0.1);
  }

  .project-dot.inbox {
    background: #d6a96d;
    box-shadow: 0 0 0 3px rgba(214, 169, 109, 0.1);
  }

  .sidebar-footer {
    margin-top: auto;
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 12px;
    color: #80847a;
    border-top: 1px solid #363a34;
    font-size: 10px;
    letter-spacing: 0.04em;
  }

  .signal {
    width: 7px;
    height: 7px;
    border-radius: 50%;
    background: #78977b;
    box-shadow: 0 0 0 3px rgba(120, 151, 123, 0.12);
  }

  .signal.error {
    background: var(--red);
  }

  main {
    width: min(100%, 1040px);
    padding: 31px clamp(30px, 5vw, 76px) 80px;
  }

  .topbar {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    margin-bottom: 55px;
  }

  .topbar .eyebrow {
    color: #9a9388;
  }

  h1,
  .capture h2,
  .empty-state h3 {
    font-family: Georgia, "Times New Roman", serif;
  }

  h1 {
    margin: 3px 0 0;
    font-size: clamp(29px, 4vw, 43px);
    font-weight: 400;
    letter-spacing: -0.045em;
  }

  .status {
    min-width: 84px;
    padding-left: 18px;
    border-left: 1px solid #cbc4b8;
  }

  .status span {
    display: block;
    font-family: Georgia, serif;
    font-size: 25px;
    line-height: 1;
  }

  .status small {
    color: var(--muted);
    font-size: 10px;
    letter-spacing: 0.06em;
    text-transform: uppercase;
  }

  .capture {
    position: relative;
    padding: clamp(23px, 4vw, 38px);
    overflow: hidden;
    color: #f7f1e8;
    background: #343832;
    border: 1px solid #1e211d;
    border-radius: 3px 3px 14px 3px;
    box-shadow: 0 14px 35px rgba(37, 35, 31, 0.12);
  }

  .capture::after {
    content: "";
    position: absolute;
    right: -45px;
    top: -80px;
    width: 220px;
    height: 220px;
    border: 1px solid rgba(228, 91, 66, 0.45);
    border-radius: 46% 54% 58% 42%;
    transform: rotate(28deg);
    pointer-events: none;
  }

  .capture-copy {
    position: relative;
    z-index: 1;
    margin-bottom: 21px;
  }

  .capture .eyebrow {
    color: #e08b79;
  }

  .capture h2 {
    margin: 3px 0 0;
    font-size: clamp(24px, 3vw, 32px);
    font-weight: 400;
    letter-spacing: -0.035em;
  }

  form {
    position: relative;
    z-index: 1;
    display: flex;
    gap: 8px;
  }

  form input {
    min-width: 0;
    flex: 1;
    padding: 15px 17px;
    color: #282b27;
    border: 2px solid transparent;
    border-radius: 5px;
    outline: 0;
    background: #fbf8f1;
    box-shadow: inset 0 1px 0 #fff;
  }

  form input:focus {
    border-color: #e07862;
  }

  form input::placeholder {
    color: #9b968c;
  }

  form button[type="submit"] {
    display: flex;
    align-items: center;
    gap: 15px;
    padding: 0 15px 0 19px;
    border: 0;
    border-radius: 5px;
    color: #fff;
    background: var(--red);
    cursor: pointer;
    transition: transform 120ms ease, background 120ms ease;
  }

  form button[type="submit"]:hover:not(:disabled) {
    background: #f06449;
    transform: translateY(-1px);
  }

  form button[type="submit"]:disabled {
    opacity: 0.45;
    cursor: not-allowed;
  }

  form button b {
    padding: 1px 5px;
    border: 1px solid rgba(255, 255, 255, 0.35);
    border-radius: 3px;
    font-size: 12px;
  }

  .sync-error {
    margin: 10px 0 0;
    color: #a13f2e;
    font-size: 12px;
  }

  .syntax {
    position: relative;
    z-index: 1;
    display: flex;
    flex-wrap: wrap;
    gap: 9px 20px;
    min-height: 18px;
    margin-top: 14px;
    color: #999e94;
    font-size: 10px;
    letter-spacing: 0.025em;
  }

  .syntax b {
    color: #cfcbc2;
    font-weight: 600;
  }

  .syntax .project-chip,
  .syntax .plan-chip,
  .syntax .due-chip {
    padding: 2px 7px;
    color: #edf0ea;
    border-radius: 3px;
    background: #4a5148;
  }

  .syntax .plan-chip {
    color: #c8dde0;
    background: #3e5557;
  }

  .syntax .due-chip {
    color: #ffd4ca;
    background: #5b433c;
  }

  .task-section {
    margin-top: 43px;
  }

  .section-heading {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 12px;
    padding: 0 2px;
  }

  .section-heading h2 {
    margin: 0;
    font-size: 11px;
    letter-spacing: 0.13em;
    text-transform: uppercase;
  }

  .completed-toggle {
    display: flex;
    align-items: center;
    gap: 7px;
    color: var(--muted);
    font-size: 11px;
    cursor: pointer;
  }

  .completed-toggle input {
    accent-color: var(--green);
  }

  .task-list {
    display: grid;
    gap: 8px;
  }

  .task-card {
    position: relative;
    display: grid;
    grid-template-columns: auto 1fr auto;
    align-items: center;
    gap: 14px;
    min-height: 76px;
    padding: 15px 16px;
    background: rgba(248, 245, 238, 0.86);
    border: 1px solid var(--line);
    border-radius: 4px;
    box-shadow: 0 2px 0 rgba(77, 68, 55, 0.03);
    transition: transform 140ms ease, border-color 140ms ease, background 140ms ease;
    animation: task-in 300ms both;
  }

  .task-card:hover {
    z-index: 1;
    border-color: #bdb4a7;
    background: var(--paper);
    transform: translateX(3px);
  }

  .task-card.done {
    opacity: 0.56;
  }

  .task-card.done h3 {
    text-decoration: line-through;
  }

  .check {
    width: 22px;
    height: 22px;
    padding: 0;
    color: white;
    border: 1.5px solid #aaa398;
    border-radius: 50%;
    background: transparent;
    cursor: pointer;
  }

  .check:hover {
    border-color: var(--green);
  }

  .check.checked {
    border-color: var(--green);
    background: var(--green);
    font-size: 12px;
  }

  .task-body {
    min-width: 0;
  }

  .task-body h3 {
    margin: 0 0 7px;
    overflow: hidden;
    font-family: Georgia, "Times New Roman", serif;
    font-size: 17px;
    font-weight: 400;
    letter-spacing: -0.015em;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .metadata {
    display: flex;
    flex-wrap: wrap;
    align-items: center;
    gap: 7px 13px;
    color: var(--muted);
    font-size: 10px;
  }

  .project-name {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 0;
    color: #5d6c67;
    border: 0;
    background: transparent;
    cursor: pointer;
  }

  .project-name span {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: #78979e;
  }

  .meta {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .meta i {
    font-family: Georgia, serif;
    font-size: 12px;
    font-style: normal;
  }

  .meta.plan {
    color: var(--blue);
  }

  .meta.due {
    color: #806b62;
  }

  .meta.overdue {
    color: #c64631;
  }

  .delete {
    width: 27px;
    height: 27px;
    padding: 0;
    opacity: 0;
    color: #9d7168;
    border: 0;
    border-radius: 4px;
    background: transparent;
    font-size: 20px;
    cursor: pointer;
    transition: opacity 120ms, background 120ms;
  }

  .task-card:hover .delete,
  .delete:focus-visible {
    opacity: 1;
  }

  .delete:hover {
    background: #f0dfda;
  }

  .empty-state {
    padding: 60px 20px;
    color: var(--muted);
    border: 1px dashed #c9c1b5;
    border-radius: 4px;
    text-align: center;
  }

  .empty-state > span {
    display: grid;
    width: 35px;
    height: 35px;
    margin: 0 auto 12px;
    place-items: center;
    color: var(--green);
    border: 1px solid #9cad9e;
    border-radius: 50%;
  }

  .empty-state h3 {
    margin: 0;
    color: var(--ink);
    font-size: 21px;
    font-weight: 400;
  }

  .empty-state p {
    margin: 5px 0 0;
    font-size: 12px;
  }

  .sr-only {
    position: absolute;
    width: 1px;
    height: 1px;
    padding: 0;
    overflow: hidden;
    clip: rect(0, 0, 0, 0);
    white-space: nowrap;
    border: 0;
  }

  @keyframes task-in {
    from {
      opacity: 0;
      transform: translateY(6px);
    }
  }

  @media (max-width: 720px) {
    .app-shell {
      display: block;
    }

    .sidebar {
      position: static;
      width: 100%;
      height: auto;
      padding: 16px 18px;
    }

    .brand {
      margin: 0 0 15px;
    }

    .brand small,
    .sidebar-footer,
    .project-heading {
      display: none;
    }

    nav {
      display: flex;
      gap: 6px;
      overflow-x: auto;
      padding-bottom: 2px;
    }

    nav > .nav-label {
      display: none;
    }

    nav button {
      width: auto;
      min-width: max-content;
      grid-template-columns: auto 1fr auto;
    }

    main {
      padding: 25px 18px 55px;
    }

    .topbar {
      margin-bottom: 28px;
    }

    .capture {
      padding: 22px 18px;
    }

    form {
      display: grid;
    }

    form button[type="submit"] {
      min-height: 45px;
      justify-content: center;
    }

    .syntax {
      gap: 7px 12px;
    }
  }

  @media (prefers-reduced-motion: reduce) {
    *,
    *::before,
    *::after {
      scroll-behavior: auto !important;
      animation-duration: 0.01ms !important;
      transition-duration: 0.01ms !important;
    }
  }
</style>
