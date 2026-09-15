<script lang="ts">
  import TaskPage from "$lib/components/TaskPage.svelte";
  import { useTasks } from "$lib/tasks.svelte";
  import { todaySection } from "$lib/task-views";

  const store = useTasks();

  const shown = $derived(store.visible(store.tasks.filter((task) => todaySection(task, store.today) !== null)));
  const sections = $derived(
    ["Overdue", "Due today", "Planned today"]
      .map((title) => ({ title, tasks: shown.filter((task) => todaySection(task, store.today) === title) }))
      .filter((section) => section.tasks.length),
  );
</script>

<TaskPage title="Today" icon="sun" tasks={shown} {sections} />
