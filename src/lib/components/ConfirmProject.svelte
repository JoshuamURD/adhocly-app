<script lang="ts">
  import { useTasks } from "$lib/tasks.svelte";

  const store = useTasks();
  let confirm: HTMLDialogElement;

  $effect(() => {
    if (store.state.confirmName !== null && !confirm.open) confirm.showModal();
    else if (store.state.confirmName === null && confirm.open) confirm.close();
  });

  const action =
    "min-h-10 rounded-[9px] border border-line bg-transparent px-[14px] py-2 text-xs font-semibold";
</script>

<dialog
  bind:this={confirm}
  class="w-[min(400px,calc(100%_-_32px))] m-auto rounded-2xl border border-line bg-[#fcfaf5] text-ink"
  aria-labelledby="confirm-project-title"
  onclose={() => store.answerConfirm(false)}
>
  <section class="p-6">
    <h2 class="mb-[10px] font-display text-2xl font-normal tracking-[-.04em]" id="confirm-project-title">Create this project?</h2>
    <p class="mb-5 text-[13px] leading-[1.8] text-muted wrap-anywhere"><span class="font-semibold text-ink">#{store.state.confirmName}</span> doesn’t exist yet. Create it and file this task there?</p>
    <div class="flex justify-end gap-2">
      <button class={action} type="button" onclick={() => store.answerConfirm(false)}>Keep editing</button>
      <button class="{action} border-transparent bg-ember text-white" type="button" onclick={() => store.answerConfirm(true)}>Create project</button>
    </div>
  </section>
</dialog>
