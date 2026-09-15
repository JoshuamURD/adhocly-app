<script lang="ts">
  import { page } from "$app/state";
  import { useTasks } from "$lib/tasks.svelte";
  import Icon from "./Icon.svelte";

  const store = useTasks();
  const path = $derived(page.url.pathname);
</script>

<nav
  class="fixed inset-x-0 bottom-0 z-10 border-t border-line bg-[#faf8f2f5] pr-[env(safe-area-inset-right)] pb-[env(safe-area-inset-bottom)] pl-[env(safe-area-inset-left)] backdrop-blur-lg"
  aria-label="Main navigation"
>
  <div class="mx-auto grid h-[82px] max-w-[700px] grid-cols-[1fr_96px_1fr] items-center max-[600px]:h-[76px]">
    <a
      class="flex h-full flex-col items-center justify-center gap-[5px] p-2 text-[10px] font-semibold tracking-[.025em] text-muted no-underline hover:bg-[#ebe7dc55] aria-[current=page]:text-ember"
      aria-current={path === "/" ? "page" : undefined}
      href="/"
    >
      <span class="relative flex"><Icon name="sun" />{#if store.todayCount}<span class="absolute -top-[5px] left-6 min-w-4 rounded-[5px] bg-[#eee5d9] px-1 py-px text-[9px] text-[#8a5745]">{store.todayCount}</span>{/if}</span>
      <span>Today</span>
    </a>
    <button
      class="grid size-[58px] box-content place-items-center justify-self-center -mt-[25px] rounded-[21px] border-[5px] border-paper bg-ember p-0 text-white shadow-[0_6px_16px_#713b2520] transition-[transform,background] duration-150 hover:-translate-y-[3px] hover:bg-[#b7422c]"
      onclick={store.openComposer}
      aria-label="Create a task"
      aria-haspopup="dialog"
      aria-controls="task-composer"
    >
      <Icon name="plus" size={28} />
    </button>
    <a
      class="flex h-full flex-col items-center justify-center gap-[5px] p-2 text-[10px] font-semibold tracking-[.025em] text-muted no-underline hover:bg-[#ebe7dc55] aria-[current=page]:text-ember"
      aria-current={path === "/all" ? "page" : undefined}
      href="/all"
    >
      <Icon name="list" /><span>All tasks</span>
    </a>
  </div>
</nav>
