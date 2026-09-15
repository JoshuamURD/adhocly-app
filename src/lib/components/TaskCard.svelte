<script lang="ts">
  import type { Task } from "$lib/api/generated";
  import { useTasks } from "$lib/tasks.svelte";
  import { displayDate, weekdayNames } from "$lib/task-views";
  import Icon from "./Icon.svelte";

  let { task }: { task: Task } = $props();

  const store = useTasks();

  const check = $derived(
    task.completed
      ? "before:border-sage before:bg-sage"
      : "before:border-[#b6b9a9] hover:before:border-sage",
  );
  const meta = "text-[10px]";
</script>

<article class="group grid min-h-[88px] grid-cols-[44px_minmax(0,1fr)_44px] items-center gap-[7px] rounded-xl border border-line bg-[#fdfbf6] px-2 py-[10px] animate-arrive transition-[border-color] duration-[140ms] hover:border-[#b8bca9] max-[600px]:gap-[2px] max-[600px]:px-1">
  <button
    class="relative isolate grid size-11 place-items-center border-0 bg-transparent p-0 text-xs text-white before:absolute before:inset-[11px] before:z-[-1] before:rounded-full before:border-[1.5px] before:content-[''] {check}"
    onclick={() => store.toggleTask(task.id)}
    disabled={store.busy}
    aria-label={task.completed ? `Mark ${task.title} incomplete` : `Complete ${task.title}`}
  >
    {#if task.completed}✓{/if}
  </button>
  <div class="min-w-0">
    <h3 class="mt-0 mb-[6px] text-sm leading-[1.5] font-medium wrap-anywhere {task.completed ? "text-muted line-through" : ""}">{task.title}</h3>
    <div class="flex flex-wrap items-center gap-x-3 gap-y-[3px] text-[10px] text-muted">
      <a class="flex min-h-6 max-w-full items-center gap-[5px] text-[#62705c] no-underline wrap-anywhere" href={`/projects/${task.projectId}`}><span class="size-[5px] shrink-0 rounded-full bg-[#8b9c83]"></span>{task.project}</a>
      {#if task.plannedFor}
        <span class="{meta} text-[#546e77]">↗ Plan {displayDate(task.plannedFor, store.state.now)}</span>
      {/if}
      {#if task.dueOn}
        <span class="{meta} {task.dueOn < store.today ? "text-ember" : ""}">◇ Due {displayDate(task.dueOn, store.state.now)}</span>
      {/if}
      {#if task.repeatWeekday != null}
        <span class="{meta} text-[#546e77]">↻ Every {weekdayNames[task.repeatWeekday]}</span>
      {/if}
    </div>
  </div>
  <button
    class="icon-button text-[#9a8a7d] opacity-0 transition-opacity duration-[120ms] group-hover:opacity-100 group-focus-within:opacity-100 hover:bg-[#f8e5dc] hover:text-ember [@media(hover:none)]:opacity-100"
    onclick={() => store.deleteTask(task.id)}
    disabled={store.busy}
    aria-label={`Delete ${task.title}`}
  >
    <Icon name="close" size={17} />
  </button>
</article>
