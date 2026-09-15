<script lang="ts">
  import type { Task } from "$lib/api/generated";
  import TaskCard from "./TaskCard.svelte";

  let { title, tasks, showTitle = false }: { title: string; tasks: Task[]; showTitle?: boolean } = $props();

  const overdue = $derived(title === "Overdue");
</script>

<div class="mt-[22px] first:mt-0">
  {#if showTitle}
    <h2 class="mt-0 mb-3 flex items-center gap-[9px] text-xs font-semibold {overdue ? "text-ember" : ""}">
      <span class="size-[6px] rounded-full {overdue ? "bg-ember" : "bg-sage"}"></span>{title}<span class="text-[10px] font-normal text-muted">{tasks.length}</span>
    </h2>
  {/if}
  <div class="grid gap-[7px]">
    {#each tasks as task (task.id)}
      <TaskCard {task} />
    {/each}
  </div>
</div>
