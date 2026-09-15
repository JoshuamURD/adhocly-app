<script lang="ts">
  import { page } from "$app/state";
  import { useTasks } from "$lib/tasks.svelte";
  import Icon from "./Icon.svelte";

  const store = useTasks();

  // Mirrors the `title` each route hands to TaskPage.
  const title = $derived(
    page.route.id === "/"
      ? "Today"
      : page.route.id === "/all"
        ? "All tasks"
        : (store.projectById(page.params.id ?? "")?.name ?? "Project"),
  );
</script>

<header class="sticky top-0 z-[9] flex min-h-[89px] items-center justify-between gap-4 border-b border-line bg-paper pt-[calc(18px_+_env(safe-area-inset-top))] pr-[max(24px,env(safe-area-inset-right))] pb-[18px] pl-[max(24px,env(safe-area-inset-left))] max-[600px]:min-h-[76px] max-[600px]:pr-[max(18px,env(safe-area-inset-right))] max-[600px]:pl-[max(18px,env(safe-area-inset-left))]">
  <div class="flex min-w-0 items-center gap-5 max-[600px]:gap-[14px]">
    <button
      class="icon-button border border-line hover:bg-[#e7e6dc]"
      onclick={() => (store.state.drawerOpen = true)}
      aria-label="Open project navigation"
      aria-haspopup="dialog"
      aria-controls="project-drawer"
    >
      <Icon name="menu" />
    </button>
    <h1 class="m-0 min-w-0 font-display text-[27px] font-bold tracking-[-.055em] wrap-anywhere">{title}<span class="text-ember">.</span></h1>
  </div>
</header>
