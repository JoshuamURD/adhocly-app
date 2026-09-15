<script lang="ts">
  import { goto } from "$app/navigation";
  import EmptyState from "$lib/components/EmptyState.svelte";
  import ProjectMetadata from "$lib/components/ProjectMetadata.svelte";
  import TaskPage from "$lib/components/TaskPage.svelte";
  import { useTasks } from "$lib/tasks.svelte";

  let { params }: { params: { id: string } } = $props();

  const store = useTasks();

  const project = $derived(store.projectById(params.id));
  const shown = $derived(store.visible(store.tasks.filter((task) => task.projectId === params.id)));
  const sections = $derived([{ title: "Your tasks", tasks: shown }]);

  function onDeleted() {
    store.state.notice = "Project deleted. Its tasks are in Inbox.";
    void goto("/all");
  }
</script>

{#if !project && !store.loading}
  <EmptyState title="That project is gone." message="It may have been deleted. Its tasks are in Inbox.">
    <a class="mt-4 inline-block min-h-11 px-2 py-2 text-xs font-semibold text-ember no-underline" href="/all">Back to all tasks →</a>
  </EmptyState>
{:else}
  <TaskPage title={project?.name ?? "Project"} tasks={shown} {sections}>
    {#snippet children()}
      {#if project}
        <ProjectMetadata {project} fields={store.fields} folders={store.folders} {onDeleted} />
      {/if}
    {/snippet}
  </TaskPage>
{/if}
