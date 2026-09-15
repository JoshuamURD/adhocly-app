<script lang="ts">
  import { page } from "$app/state";
  import { goto } from "$app/navigation";
  import { useTasks } from "$lib/tasks.svelte";
  import Icon from "./Icon.svelte";

  const store = useTasks();
  const path = $derived(page.url.pathname);

  let drawer: HTMLDialogElement;

  $effect(() => {
    if (store.state.drawerOpen && !drawer.open) drawer.showModal();
    else if (!store.state.drawerOpen && drawer.open) drawer.close();
  });

  async function addProject(event: SubmitEvent) {
    event.preventDefault();
    const id = await store.addProject();
    if (!id) return;
    store.state.drawerOpen = false;
    await goto(`/projects/${id}`);
  }

  function close() {
    store.state.drawerOpen = false;
  }

  const linkClass =
    "grid min-h-12 grid-cols-[22px_minmax(0,1fr)_auto] items-center gap-3 rounded-[9px] px-3 py-[10px] text-left text-[13px] text-[#cbd0c3] no-underline hover:bg-[#ffffff08] aria-[current=page]:bg-[#404938] aria-[current=page]:text-white [&[aria-current=page]>svg]:text-[#edaf83]";
</script>

<dialog
  bind:this={drawer}
  id="project-drawer"
  onclose={close}
  class="inset-y-0 right-auto left-0 m-0 h-dvh max-h-dvh w-[min(340px,calc(100%_-_32px))] max-w-none animate-drawer-in bg-[#292f27] text-[#f4f0e7]"
  aria-labelledby="drawer-title"
>
  <aside class="flex min-h-full flex-col pt-[calc(24px_+_env(safe-area-inset-top))] pr-[22px] pb-[calc(20px_+_env(safe-area-inset-bottom))] pl-[max(22px,env(safe-area-inset-left))]">
    <header class="mb-[34px] flex items-center justify-between">
      <span class="font-display text-[32px] font-bold tracking-[-.055em]" id="drawer-title">adhocly<span class="text-[#eb8c71]">.</span></span>
      <button class="icon-button hover:bg-[#ffffff10]" onclick={close} aria-label="Close project navigation"><Icon name="close" /></button>
    </header>
    <nav class="grid gap-[5px]" aria-label="Projects and task views">
      <p class="m-0 px-3 pb-[10px] text-[10px] font-semibold tracking-[.14em] text-[#a7ae9e] uppercase">Workspace</p>
      <a class={linkClass} aria-current={path === "/" ? "page" : undefined} href="/" onclick={close}>
        <Icon name="sun" /><span>Today</span><em class="text-[11px] not-italic text-[#b2bbaa]">{store.todayCount}</em>
      </a>
      <a class={linkClass} aria-current={path === "/all" ? "page" : undefined} href="/all" onclick={close}>
        <Icon name="list" /><span>All tasks</span><em class="text-[11px] not-italic text-[#b2bbaa]">{store.openCount}</em>
      </a>
      <p class="mt-7 mb-0 flex justify-between px-3 pb-[10px] text-[10px] font-semibold tracking-[.14em] text-[#a7ae9e] uppercase">Projects <span>#</span></p>
      {#each store.projects as project (project.id)}
        <a
          class={linkClass}
          aria-current={path === `/projects/${project.id}` ? "page" : undefined}
          href={`/projects/${project.id}`}
          onclick={close}
        >
          <span class="ml-[6px] size-2 rounded-[3px] {project.id === "inbox" ? "bg-[#d6a96d]" : "bg-[#8ba6ac]"}"></span><span class="wrap-anywhere">{project.name}</span><em class="text-[11px] not-italic text-[#b2bbaa]">{store.openCountFor(project.id)}</em>
        </a>
      {/each}
      <form class="mt-[10px] grid grid-cols-[minmax(0,1fr)_34px] gap-[6px] px-3" onsubmit={addProject}>
        <input
          class="min-w-0 rounded-[7px] border border-[#4b5442] bg-[#ffffff0d] px-[10px] py-2 text-xs text-[#f4f0e7] placeholder:text-[#8f9787]"
          bind:value={store.state.newProjectName}
          placeholder="New project"
          aria-label="New project name"
          autocomplete="off"
          disabled={store.busy}
        />
        <button class="rounded-[7px] border-0 bg-[#4b5442] text-base text-[#f4f0e7]" type="submit" disabled={store.busy || !store.state.newProjectName.trim()} aria-label="Create project">+</button>
      </form>
    </nav>
    <footer class="mt-auto flex items-center gap-3 px-3 pt-8 text-[11px] leading-[1.8] text-[#b0b6a7]">
      <span class="font-display text-[28px] text-[#ce9f77]">#</span>
      <p class="m-0">Type <b class="font-medium text-[#deded2]">#project</b> in a new task to file it.</p>
    </footer>
  </aside>
</dialog>
