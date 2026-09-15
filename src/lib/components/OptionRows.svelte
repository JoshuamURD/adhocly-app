<script lang="ts">
  import { tick } from "svelte";
  import { optionKey } from "$lib/metadata";

  /**
   * Raw option text, blanks included: rows are edited in place and only trimmed/deduped on save, so a
   * row can be empty while it is being typed. `bind:options` keeps at least one row.
   */
  let { options = $bindable(), disabled = false }: { options: string[]; disabled?: boolean } = $props();

  let list: HTMLDivElement;

  function focusRow(index: number) {
    list.querySelectorAll<HTMLInputElement>(".option-row input")[index]?.focus();
  }

  async function add() {
    options = [...options, ""];
    await tick();
    focusRow(options.length - 1);
  }

  async function onKeydown(event: KeyboardEvent & { currentTarget: HTMLInputElement }, index: number) {
    const action = optionKey(event.key, event.currentTarget.value, index, options.length);
    if (!action) return;

    // Enter must not submit the surrounding form.
    event.preventDefault();
    if (action === "append") return void add();
    if (action === "next") return focusRow(index + 1);

    options = options.filter((_, row) => row !== index);
    await tick();
    focusRow(index - 1);
  }
</script>

<div class="grid gap-[2px] rounded-lg border border-line bg-white p-[6px]" bind:this={list}>
  {#each options as option, index (index)}
    <div class="option-row grid grid-cols-[minmax(0,1fr)_auto] items-center gap-[2px]">
      <input
        class="rounded-md border border-transparent bg-transparent px-2 py-[6px] hover:border-line focus:border-sage focus:bg-white"
        value={option}
        {disabled}
        placeholder="Option"
        aria-label={`Option ${index + 1}`}
        oninput={(event) => (options = options.map((row, i) => (i === index ? event.currentTarget.value : row)))}
        onkeydown={(event) => void onKeydown(event, index)}
      />
      <button
        type="button"
        class="size-[26px] rounded-md border-0 bg-transparent p-0 text-[15px] leading-none text-[#b3a89c] enabled:hover:bg-[#fbe8e0] enabled:hover:text-ember"
        disabled={disabled || options.length === 1}
        onclick={() => (options = options.filter((_, row) => row !== index))}
        aria-label={`Remove option ${index + 1}`}
      >
        ×
      </button>
    </div>
  {/each}

  <button type="button" class="mt-[2px] justify-self-start rounded-md border-0 bg-transparent px-2 py-[5px] text-xs font-semibold text-sage enabled:hover:bg-[#edefe3]" {disabled} onclick={() => void add()}>+ Add option</button>
</div>
