<script lang="ts">
  import { useTasks } from "$lib/tasks.svelte";
  import Icon from "./Icon.svelte";

  const store = useTasks();
</script>

<header class="sticky top-0 z-[9] flex min-h-[89px] items-center justify-between gap-4 border-b border-line bg-paper pt-[calc(18px_+_env(safe-area-inset-top))] pr-[max(24px,env(safe-area-inset-right))] pb-[18px] pl-[max(24px,env(safe-area-inset-left))] max-[600px]:min-h-[76px] max-[600px]:pr-[max(18px,env(safe-area-inset-right))] max-[600px]:pl-[max(18px,env(safe-area-inset-left))]">
  <div class="flex items-center gap-5 max-[600px]:gap-[14px]">
    <button
      class="icon-button border border-line hover:bg-[#e7e6dc]"
      onclick={() => (store.state.drawerOpen = true)}
      aria-label="Open project navigation"
      aria-haspopup="dialog"
      aria-controls="project-drawer"
    >
      <Icon name="menu" />
    </button>
    <span class="font-display text-[27px] font-bold tracking-[-.055em]">adhocly<span class="text-ember">.</span></span>
  </div>
</header>
