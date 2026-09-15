<script lang="ts">
  import TaskPage from "$lib/components/TaskPage.svelte";
  import { useTasks } from "$lib/tasks.svelte";

  const store = useTasks();

  const shown = $derived(store.visible(store.tasks));
  const sections = $derived([{ title: "Your tasks", tasks: shown }]);
</script>

<TaskPage title="All tasks" tasks={shown} {sections} />
