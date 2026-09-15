<script lang="ts">
  import type { Snippet } from "svelte";
  import type { Task } from "$lib/api/generated";
  import { useTasks } from "$lib/tasks.svelte";
  import EmptyState from "./EmptyState.svelte";
  import Icon, { type IconName } from "./Icon.svelte";
  import TaskSection from "./TaskSection.svelte";

  let {
    title,
    tasks,
    sections,
    icon = "list",
    children,
  }: {
    title: string;
    /** Tasks visible in this view, used for the heading count. */
    tasks: Task[];
    sections: { title: string; tasks: Task[] }[];
    icon?: IconName;
    children?: Snippet;
  } = $props();

  const store = useTasks();
  const openCount = $derived(tasks.filter((task) => !task.completed).length);
</script>

<svelte:head>
  <title>Adhocly — {title}</title>
  <meta name="description" content="Make room for today. A thoughtful task list with quick, natural-language capture." />
</svelte:head>

<header class="mb-[30px] flex items-center justify-between gap-6 max-[600px]:mb-[22px] max-[600px]:gap-3">
  <h1 class="m-0 font-display text-[clamp(34px,6vw,52px)] leading-[1.1] font-normal tracking-[-.055em] wrap-anywhere">{title}<span class="text-ember">.</span></h1>
  <div class="flex items-center gap-5 max-[600px]:gap-[14px]">
    <label class="flex min-h-11 cursor-pointer items-center gap-[7px] text-[11px] text-muted max-[600px]:text-[10px]">
      <input class="m-0 size-[14px] accent-sage" type="checkbox" bind:checked={store.state.showCompleted} />
      Show completed
    </label>
    <span class="font-display text-[30px] tracking-[-.04em] max-[600px]:text-2xl" aria-label={`${openCount} open tasks in this view`}>{String(openCount).padStart(2, "0")}</span>
  </div>
</header>

{#if store.error}
  <p class="rounded-lg bg-[#fbe8e0] px-[14px] py-3 text-xs wrap-anywhere text-[#a33828]" role="alert">{store.error}</p>
{/if}
<p class="text-xs text-sage wrap-anywhere empty:m-0" role="status">{store.state.notice}</p>

{@render children?.()}

<section aria-label={`${title} tasks`}>
  {#if store.loading}
    <div class="px-5 py-[62px] text-center max-[600px]:py-[42px]" role="status"><p class="text-[13px] text-muted">Gathering your tasks…</p></div>
  {:else if store.taskQueryError}
    <EmptyState title="Let’s reconnect." message="Couldn’t load your tasks.">
      <button class="mt-4 min-h-11 border-0 bg-transparent px-2 py-2 text-xs font-semibold text-ember" onclick={() => store.refetchTasks()}>Try again →</button>
    </EmptyState>
  {:else if tasks.length === 0}
    <EmptyState title={icon === "sun" ? "Nothing today." : "Clear for now."} {icon}>
      <button class="mt-4 min-h-11 border-0 bg-transparent px-2 py-2 text-xs font-semibold text-ember" onclick={store.openComposer}>Add a task <span class="pl-[10px]" aria-hidden="true">↗</span></button>
    </EmptyState>
  {:else}
    {#each sections as section (section.title)}
      <TaskSection title={section.title} tasks={section.tasks} showTitle={sections.length > 1} />
    {/each}
  {/if}
</section>
