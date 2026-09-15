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

<div class="options" bind:this={list}>
  {#each options as option, index (index)}
    <div class="option-row">
      <input
        value={option}
        {disabled}
        placeholder="Option"
        aria-label={`Option ${index + 1}`}
        oninput={(event) => (options = options.map((row, i) => (i === index ? event.currentTarget.value : row)))}
        onkeydown={(event) => void onKeydown(event, index)}
      />
      <button
        type="button"
        class="remove-option"
        disabled={disabled || options.length === 1}
        onclick={() => (options = options.filter((_, row) => row !== index))}
        aria-label={`Remove option ${index + 1}`}
      >
        ×
      </button>
    </div>
  {/each}

  <button type="button" class="add-option" {disabled} onclick={() => void add()}>+ Add option</button>
</div>

<style>
  .options { display: grid; gap: 2px; padding: 6px; border: 1px solid var(--line); border-radius: 8px; background: white; }
  .option-row { display: grid; grid-template-columns: minmax(0, 1fr) auto; align-items: center; gap: 2px; }
  .option-row input { padding: 6px 8px; border: 1px solid transparent; border-radius: 6px; background: transparent; }
  .option-row input:hover { border-color: var(--line); }
  .option-row input:focus { border-color: var(--green); background: white; }
  .remove-option {
    width: 26px; height: 26px; padding: 0; border: 0; border-radius: 6px; background: transparent;
    color: #b3a89c; font-size: 15px; line-height: 1;
  }
  .remove-option:not(:disabled):hover { color: var(--red); background: #fbe8e0; }
  .add-option {
    justify-self: start; margin-top: 2px; padding: 5px 8px; border: 0; border-radius: 6px;
    background: transparent; color: var(--green); font-size: 12px; font-weight: 600;
  }
  .add-option:not(:disabled):hover { background: #edefe3; }
</style>
