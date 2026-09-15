<script lang="ts">
  import { onMount, type Snippet } from "svelte";
  import { initTaskStore } from "$lib/tasks.svelte";
  import BottomBar from "./BottomBar.svelte";
  import ConfirmProject from "./ConfirmProject.svelte";
  import Sidebar from "./Sidebar.svelte";
  import TaskComposer from "./TaskComposer.svelte";
  import TopBar from "./TopBar.svelte";

  let { children }: { children: Snippet } = $props();

  // Created here so the queries and mutations see the layout's QueryClientProvider.
  const store = initTaskStore();

  onMount(() => {
    const timer = window.setInterval(() => (store.state.now = new Date()), 60_000);
    return () => window.clearInterval(timer);
  });
</script>

<div class="min-h-dvh">
  <TopBar />
  <main class="mx-auto w-full max-w-[860px] px-8 pt-11 pb-[calc(120px_+_env(safe-area-inset-bottom))] max-[600px]:px-5 max-[600px]:pt-9">
    {@render children()}
  </main>
  <BottomBar />
</div>

<Sidebar />
<TaskComposer />
<ConfirmProject />
