<script lang="ts">
  import { page } from "$app/state";
  import { goto } from "$app/navigation";
  import type { Folder, Project } from "$lib/api/generated";
  import { folderTree, isInside, type FolderNode } from "$lib/folders";
  import { useTasks } from "$lib/tasks.svelte";
  import Icon from "./Icon.svelte";

  const store = useTasks();
  const path = $derived(page.url.pathname);

  let drawer: HTMLDialogElement;
  let aside: HTMLElement;

  const COLLAPSED_KEY = "adhocly:collapsed-folders";
  /** Long enough to tell a hold from a flick, short enough not to feel stuck. */
  const HOLD_MS = 300;
  /** A resting finger drifts a few pixels, so a hold only cancels past this. */
  const SLOP = 10;

  type Dragged = { kind: "project" | "folder"; id: string; parentId: string | null };

  // Folders remember being collapsed between launches.
  let collapsed = $state<string[]>(readCollapsed());
  let renamingId = $state<string | null>(null);
  let creating = $state<{ parentId: string | null } | null>(null);
  let folderDraft = $state("");

  let dragging = $state<Dragged | null>(null);
  /** Folder under the drag: an id, "" for the top level, null for nowhere droppable. */
  let dropTarget = $state<string | null>(null);
  let holding: { item: Dragged; x: number; y: number; timer: number } | null = null;
  let origin = { x: 0, y: 0 };
  let moved = false;
  let suppressClick = false;

  const tree = $derived(folderTree(store.folders, store.projects));

  // iOS only cancels a scroll that has not started yet, and only for a listener that is allowed to
  // call preventDefault: Svelte's attribute listeners are not guaranteed to be non-passive.
  $effect(() => {
    if (!aside) return;
    const blockScroll = (event: TouchEvent) => {
      if (dragging) event.preventDefault();
    };
    aside.addEventListener("touchmove", blockScroll, { passive: false });
    return () => aside.removeEventListener("touchmove", blockScroll);
  });

  $effect(() => {
    if (store.state.drawerOpen && !drawer.open) drawer.showModal();
    else if (!store.state.drawerOpen && drawer.open) drawer.close();
  });

  function readCollapsed() {
    try {
      const stored: unknown = JSON.parse(localStorage.getItem(COLLAPSED_KEY) ?? "[]");
      return Array.isArray(stored) ? stored.filter((id) => typeof id === "string") : [];
    } catch {
      return [];
    }
  }

  function setCollapsed(ids: string[]) {
    collapsed = ids;
    localStorage.setItem(COLLAPSED_KEY, JSON.stringify(ids));
  }

  function expand(id: string) {
    if (collapsed.includes(id)) setCollapsed(collapsed.filter((folder) => folder !== id));
  }

  function toggleFolder(id: string) {
    setCollapsed(collapsed.includes(id) ? collapsed.filter((folder) => folder !== id) : [...collapsed, id]);
  }

  async function addProject(event: SubmitEvent) {
    event.preventDefault();
    const id = await store.addProject();
    if (!id) return;
    store.state.drawerOpen = false;
    await goto(`/projects/${id}`);
  }

  async function submitFolder(event: SubmitEvent, parentId: string | null) {
    event.preventDefault();
    const name = folderDraft.trim();
    if (!name) return;

    if (await store.addFolder(name, parentId)) {
      folderDraft = "";
      creating = null;
      if (parentId) expand(parentId);
    }
  }

  function renameFolder(event: FocusEvent & { currentTarget: HTMLInputElement }, folder: Folder) {
    // Escape clears renamingId first, and the unmounting input's blur must not save it.
    if (renamingId !== folder.id) return;
    renamingId = null;

    const name = event.currentTarget.value.trim();
    if (!name || name === folder.name) return;
    void store.renameFolderTo(folder.id, name, folder.parentId ?? null);
  }

  function deleteFolder(folder: Folder) {
    const question = `Delete the folder ${folder.name}? Its projects and folders move up one level.`;
    if (window.confirm(question)) void store.removeFolder(folder.id);
  }

  function openCount(node: FolderNode): number {
    return (
      node.projects.reduce((total, project) => total + store.openCountFor(project.id), 0) +
      node.folders.reduce((total, child) => total + openCount(child), 0)
    );
  }

  /** A mouse picks a row up at once; a finger holds it, so a swipe still scrolls the drawer. */
  function pressRow(event: PointerEvent, item: Dragged) {
    suppressClick = false;
    if (dragging || event.button !== 0 || (item.kind === "project" && item.id === "inbox")) return;

    origin = { x: event.clientX, y: event.clientY };
    moved = false;
    if (event.pointerType === "mouse") {
      dragging = item;
      return;
    }
    holding = { item, ...origin, timer: window.setTimeout(pickUp, HOLD_MS) };
  }

  function pickUp() {
    if (!holding) return;
    dragging = holding.item;
    releaseHold();
  }

  function releaseHold() {
    if (!holding) return;
    window.clearTimeout(holding.timer);
    holding = null;
  }

  function onPointerMove(event: PointerEvent) {
    if (Math.abs(event.clientX - origin.x) > SLOP || Math.abs(event.clientY - origin.y) > SLOP) {
      if (holding) releaseHold();
      if (dragging) moved = true;
    }
    if (!dragging) return;

    // Hit tested by position, not by `event.target`: a touch pointer is implicitly captured by the
    // row it started on, so its events keep targeting that row wherever the finger goes.
    const target = document.elementFromPoint(event.clientX, event.clientY);
    const folder = target?.closest("[data-folder]");
    if (folder) {
      dropTarget = folder.getAttribute("data-folder");
      if (dropTarget) expand(dropTarget);
    } else {
      dropTarget = target?.closest("[data-drop-root]") ? "" : null;
    }
  }

  function onPointerUp() {
    releaseHold();
    const item = dragging;
    const target = moved ? dropTarget : null;
    dragging = null;
    dropTarget = null;
    if (!item || target === null) return;

    // A row that moved is a drop, not a tap.
    suppressClick = true;
    const folderId = target === "" ? null : target;
    if (item.kind === "project") {
      void store.moveProject(item.id, folderId);
    } else if (folderId !== item.parentId && !isInside(store.folders, item.id, folderId ?? "")) {
      void store.moveFolder(item.id, folderId);
    }
  }

  /** Touch scrolling cannot be cancelled once it starts, so it never starts. */
  function onContextMenu(event: MouseEvent) {
    if (holding || dragging) event.preventDefault();
  }

  function indent(depth: number) {
    return `padding-left: ${12 + Math.min(depth, 4) * 14}px`;
  }

  /** Dragging is an enhancement on top of the row's buttons, so it is wired up as an action. */
  function dragRow(node: HTMLElement, item: Dragged) {
    let current = item;
    const down = (event: PointerEvent) => pressRow(event, current);
    node.addEventListener("pointerdown", down);
    return {
      update: (next: Dragged) => (current = next),
      destroy: () => node.removeEventListener("pointerdown", down),
    };
  }

  const autofocus = (node: HTMLInputElement) => node.focus();

  const draggedRow = "bg-[#3a4436] ring-1 ring-[#edaf83]";
  const linkClass =
    "grid min-h-12 grid-cols-[22px_minmax(0,1fr)_auto] items-center gap-3 rounded-[9px] px-3 py-[10px] text-left text-[13px] text-[#cbd0c3] no-underline hover:bg-[#ffffff08] aria-[current=page]:bg-[#404938] aria-[current=page]:text-white [&[aria-current=page]>svg]:text-[#edaf83]";
  const rowClass =
    "grid min-h-10 grid-cols-[20px_minmax(0,1fr)_auto_20px_20px] items-center gap-1 rounded-[9px] py-[6px] pr-1 text-left text-[13px] text-[#cbd0c3] hover:bg-[#ffffff08]";
  const rowButton =
    "grid size-5 place-items-center rounded-[5px] border-0 bg-transparent p-0 text-[#a7ae9e] hover:text-[#f4f0e7]";
  const fieldClass =
    "min-w-0 rounded-[7px] border border-[#4b5442] bg-[#ffffff0d] px-[10px] py-2 text-xs text-[#f4f0e7] placeholder:text-[#8f9787]";
  const countClass = "text-[11px] not-italic text-[#b2bbaa]";
</script>

<svelte:window
  onpointermove={onPointerMove}
  onpointerup={onPointerUp}
  onpointercancel={onPointerUp}
  onclickcapture={(event) => {
    if (!suppressClick) return;
    suppressClick = false;
    event.preventDefault();
    event.stopPropagation();
  }}
/>

<dialog
  bind:this={drawer}
  id="project-drawer"
  onclose={() => (store.state.drawerOpen = false)}
  class="inset-y-0 right-auto left-0 m-0 h-dvh max-h-dvh w-[min(340px,calc(100%_-_32px))] max-w-none animate-drawer-in bg-[#292f27] text-[#f4f0e7]"
  aria-labelledby="drawer-title"
>
  <aside
    bind:this={aside}
    class="flex min-h-full flex-col pt-[calc(24px_+_env(safe-area-inset-top))] pr-[22px] pb-[calc(20px_+_env(safe-area-inset-bottom))] pl-[max(22px,env(safe-area-inset-left))]"
    oncontextmenu={onContextMenu}
  >
    <header class="mb-[34px] flex items-center justify-between">
      <span class="font-display text-[32px] font-bold tracking-[-.055em]" id="drawer-title">adhocly<span class="text-[#eb8c71]">.</span></span>
      <button class="icon-button hover:bg-[#ffffff10]" onclick={() => (store.state.drawerOpen = false)} aria-label="Close project navigation"><Icon name="close" /></button>
    </header>

    <nav class="grid gap-[5px]" aria-label="Projects and task views" data-drop-root>
      <p class="m-0 px-3 pb-[10px] text-[10px] font-semibold tracking-[.14em] text-[#a7ae9e] uppercase">Workspace</p>
      <a class={linkClass} aria-current={path === "/" ? "page" : undefined} href="/" onclick={() => (store.state.drawerOpen = false)}>
        <Icon name="sun" /><span>Today</span><em class={countClass}>{store.todayCount}</em>
      </a>
      <a class={linkClass} aria-current={path === "/all" ? "page" : undefined} href="/all" onclick={() => (store.state.drawerOpen = false)}>
        <Icon name="list" /><span>All tasks</span><em class={countClass}>{store.openCount}</em>
      </a>

      <p
        class="mt-7 mb-0 flex items-center justify-between gap-2 rounded-[7px] px-3 py-[6px] text-[10px] font-semibold tracking-[.14em] text-[#a7ae9e] uppercase {dragging && dropTarget === ''
          ? 'bg-[#404938] text-white'
          : ''}"
      >
        Projects
        {#if dragging}
          <span class="text-[10px] normal-case">top level</span>
        {:else}
          <button
            class={rowButton}
            onclick={() => { creating = { parentId: null }; renamingId = null; }}
            aria-label="New folder"
            title="New folder"
          >
            <Icon name="plus" size={14} />
          </button>
        {/if}
      </p>

      {#each tree.folders as node (node.folder.id)}
        {@render folderNode(node, 0)}
      {/each}

      {#if creating?.parentId === null}
        {@render folderForm(null, 0)}
      {/if}

      {#each tree.projects as project (project.id)}
        {@render projectRow(project, 0)}
      {/each}

      <form class="mt-[10px] grid grid-cols-[minmax(0,1fr)_34px] gap-[6px] px-3" onsubmit={addProject}>
        <input
          class={fieldClass}
          bind:value={store.state.newProjectName}
          placeholder="New project"
          aria-label="New project name"
          autocomplete="off"
          disabled={store.busy}
        />
        <button class="rounded-[7px] border-0 bg-[#4b5442] text-base text-[#f4f0e7]" type="submit" disabled={store.busy || !store.state.newProjectName.trim()} aria-label="Create project">+</button>
      </form>
    </nav>

    {#if store.error}
      <p class="mt-4 mb-0 px-3 text-[11px] leading-[1.6] text-[#eb8c71]" role="alert">{store.error}</p>
    {/if}

    <footer class="mt-auto flex items-center gap-3 px-3 pt-8 text-[11px] leading-[1.8] text-[#b0b6a7]">
      <span class="font-display text-[28px] text-[#ce9f77]">#</span>
      <p class="m-0">Type <b class="font-medium text-[#deded2]">#project</b> in a new task to file it. Drag a project or folder onto another folder to nest it.</p>
    </footer>
  </aside>
</dialog>

{#snippet folderNode(node: FolderNode, depth: number)}
  {@const folder = node.folder}
  {@const open = !collapsed.includes(folder.id)}
  {@const dragged = dragging?.kind === "folder" && dragging.id === folder.id}
  <div
    class="{rowClass} {dragged ? `opacity-60 ${draggedRow}` : ''} {dropTarget === folder.id ? 'bg-[#414a37]' : ''}"
    style={indent(depth)}
    data-folder={folder.id}
    use:dragRow={{ kind: "folder", id: folder.id, parentId: folder.parentId ?? null }}
  >
    <button
      class={rowButton}
      onclick={() => toggleFolder(folder.id)}
      aria-expanded={open}
      aria-label={open ? `Collapse ${folder.name}` : `Expand ${folder.name}`}
    >
      <Icon name="chevron" size={14} class={open ? "rotate-90" : ""} />
    </button>

    {#if renamingId === folder.id}
      <input
        class={fieldClass}
        value={folder.name}
        aria-label={`Rename ${folder.name}`}
        use:autofocus
        onblur={(event) => renameFolder(event, folder)}
        onkeydown={(event) => {
          if (event.key === "Enter") event.currentTarget.blur();
          else if (event.key === "Escape") renamingId = null;
        }}
      />
    {:else}
      <button class="min-w-0 border-0 bg-transparent p-0 text-left" onclick={() => toggleFolder(folder.id)}>
        <span class="wrap-anywhere">{folder.name}</span>
      </button>
    {/if}

    <em class={countClass}>{openCount(node)}</em>
    <button class={rowButton} onclick={() => { renamingId = folder.id; creating = null; }} aria-label={`Rename ${folder.name}`} title="Rename">
      <Icon name="pencil" size={13} />
    </button>
    <button class={rowButton} onclick={() => deleteFolder(folder)} aria-label={`Delete ${folder.name}`} title="Delete">
      <Icon name="close" size={13} />
    </button>
  </div>

  {#if open}
    <div class="grid gap-[5px]">
      {#each node.folders as child (child.folder.id)}
        {@render folderNode(child, depth + 1)}
      {/each}
      {#each node.projects as project (project.id)}
        {@render projectRow(project, depth + 1)}
      {/each}
      {#if creating?.parentId === folder.id}
        {@render folderForm(folder.id, depth + 1)}
      {:else}
        <button
          class="justify-self-start border-0 bg-transparent py-1 text-[11px] text-[#8f9787] hover:text-[#cbd0c3]"
          style={indent(depth + 1)}
          onclick={() => { creating = { parentId: folder.id }; renamingId = null; }}
        >
          + New folder
        </button>
      {/if}
    </div>
  {/if}
{/snippet}

{#snippet projectRow(project: Project, depth: number)}
  <a
    class="{linkClass} {dragging?.kind === 'project' && dragging.id === project.id ? `opacity-60 ${draggedRow}` : ''}"
    style={indent(depth)}
    aria-current={path === `/projects/${project.id}` ? "page" : undefined}
    href={`/projects/${project.id}`}
    onclick={() => (store.state.drawerOpen = false)}
    onpointerdown={(event) => pressRow(event, { kind: "project", id: project.id, parentId: project.folderId ?? null })}
  >
    <span class="ml-[6px] size-2 rounded-[3px] {project.id === "inbox" ? "bg-[#d6a96d]" : "bg-[#8ba6ac]"}"></span>
    <span class="wrap-anywhere">{project.name}</span>
    <em class={countClass}>{store.openCountFor(project.id)}</em>
  </a>
{/snippet}

{#snippet folderForm(parentId: string | null, depth: number)}
  <form
    class="grid grid-cols-[minmax(0,1fr)_34px] gap-[6px] py-[2px] pr-1"
    style={indent(depth)}
    onsubmit={(event) => submitFolder(event, parentId)}
  >
    <input
      class={fieldClass}
      bind:value={folderDraft}
      placeholder="New folder"
      aria-label="New folder name"
      autocomplete="off"
      use:autofocus
      onkeydown={(event) => event.key === "Escape" && (creating = null)}
    />
    <button
      class="rounded-[7px] border-0 bg-[#4b5442] text-base text-[#f4f0e7]"
      type="submit"
      disabled={store.busy || !folderDraft.trim()}
      aria-label="Create folder"
    >+</button>
  </form>
{/snippet}
