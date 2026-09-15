<script lang="ts">
  import { useTasks } from "$lib/tasks.svelte";
  import { displayDate, weekdayNames } from "$lib/task-views";
  import Icon from "./Icon.svelte";

  const store = useTasks();
  let composer: HTMLDialogElement;
  let taskInput: HTMLInputElement;

  const parsed = $derived(store.parsedDraft);

  $effect(() => {
    if (store.state.composerOpen && !composer.open) {
      composer.showModal();
      taskInput.focus();
    } else if (!store.state.composerOpen && composer.open) {
      composer.close();
    }
  });

  async function submit(event: SubmitEvent) {
    event.preventDefault();
    await store.addTask();
  }

  const chip = "rounded-[5px] px-2 py-1 wrap-anywhere";
</script>

<dialog
  bind:this={composer}
  id="task-composer"
  onclose={() => (store.state.composerOpen = false)}
  class="inset-x-0 top-auto bottom-0 mx-auto mb-[calc(104px_+_env(safe-area-inset-bottom))] max-h-[calc(100dvh_-_env(safe-area-inset-top)_-_20px)] w-[min(760px,calc(100%_-_40px))] max-w-none animate-compose rounded-[20px] border border-line bg-[#fcfaf5] shadow-[0_24px_70px_#20251d33] max-[600px]:mb-0 max-[600px]:w-full max-[600px]:rounded-t-[22px] max-[600px]:rounded-b-none"
  aria-labelledby="capture-title"
>
  <section class="p-[26px] max-[600px]:px-[18px] max-[600px]:pt-[22px] max-[600px]:pb-[calc(24px_+_env(safe-area-inset-bottom))]">
    <header class="mb-[22px] flex items-center justify-between gap-3">
      <h2 class="font-display text-[28px] font-normal tracking-[-.04em] max-[600px]:text-2xl" id="capture-title">What needs doing?</h2>
      <button class="icon-button hover:bg-[#e7e6dc]" onclick={() => (store.state.composerOpen = false)} aria-label="Close task entry"><Icon name="close" /></button>
    </header>
    <form class="flex items-center gap-2 rounded-xl border border-[#d8d7ca] bg-white p-[5px] focus-within:border-sage focus-within:shadow-[0_0_0_3px_#60745b12]" onsubmit={submit}>
      <label for="task-input" class="sr-only">New task</label>
      <input
        class="w-full min-w-0 border-0 bg-transparent px-[10px] py-[13px] text-base text-ink outline-0 placeholder:text-[#929486]"
        id="task-input"
        bind:this={taskInput}
        bind:value={store.state.draft}
        autocomplete="off"
        placeholder="A task, a thought, a little reminder…"
        aria-describedby="capture-help"
      />
      <button class="grid size-11 shrink-0 place-items-center rounded-[9px] border-0 bg-ember text-white" type="submit" aria-label="Add task" disabled={!parsed.title || store.busy}><Icon name="arrow" /></button>
    </form>
    <div class="mt-[14px] flex min-h-[26px] flex-wrap items-center gap-[6px] text-[11px]" aria-live="polite">
      <span class="{chip} bg-[#ebeddf] text-[#57674b]">#{parsed.project || store.defaultProjectName}</span>
      {#if parsed.plannedFor}<span class="{chip} bg-[#e8eef0] text-[#476873]">Plan · {displayDate(parsed.plannedFor, store.state.now)}</span>{/if}
      {#if parsed.dueOn}<span class="{chip} bg-[#f7e5dc] text-[#a14a31]">Due · {displayDate(parsed.dueOn, store.state.now)}</span>{/if}
      {#if parsed.repeatWeekday != null}<span class="{chip} bg-[#e8eef0] text-[#476873]">Every {weekdayNames[parsed.repeatWeekday]}</span>{/if}
      {#if store.busy}<span class="px-2 py-1">Saving…</span>{/if}
    </div>
    {#if store.error}<p class="rounded-lg bg-[#fbe8e0] px-[14px] py-3 text-xs wrap-anywhere text-[#a33828]" role="alert">{store.error}</p>{/if}
    <p class="mt-[18px] flex flex-wrap gap-1 text-[10px] leading-[1.8] text-muted" id="capture-help">
      <b class="font-semibold text-[#5e6556]">#project</b> to organise <span class="px-[5px]">·</span> <b class="font-semibold text-[#5e6556]">@today 9am</b> to plan <span class="px-[5px]">·</span> <b class="font-semibold text-[#5e6556]">!friday 5pm</b> for a deadline <span class="px-[5px]">·</span> <b class="font-semibold text-[#5e6556]">@every friday</b> to repeat
    </p>
  </section>
</dialog>
