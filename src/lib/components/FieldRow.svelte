<script lang="ts">
  import OptionRows from "./OptionRows.svelte";
  import { normalizeOptions } from "$lib/metadata";
  import type { MetadataField } from "$lib/api/generated";

  let {
    field,
    staleValue = "",
    busy = false,
    onSave,
    onRemove,
  }: {
    field: MetadataField;
    /** The value this project stores for the field, used to warn before an option disappears. */
    staleValue?: string;
    busy?: boolean;
    onSave: (name: string, options: string[]) => void;
    onRemove: () => void;
  } = $props();

  // Edited locally and committed with Save; nothing else writes to a field while this row is open.
  // svelte-ignore state_referenced_locally
  let name = $state(field.name);
  // svelte-ignore state_referenced_locally
  let options = $state([...field.options]);

  const normalized = $derived(normalizeOptions(options));
  const choice = $derived(field.kind === "choice");
  const dirty = $derived(name.trim() !== field.name || normalized.join("\n") !== field.options.join("\n"));
  const invalid = $derived(!name.trim() || (choice && !normalized.length));
  /** Kept selectable by `choiceOptions`, but the option is about to leave the list. */
  const hint = $derived(
    `${normalized.length} option${normalized.length === 1 ? "" : "s"}` +
      (choice && staleValue && !normalized.includes(staleValue)
        ? ` — “${staleValue}” is still set on this project and stays selectable until it is changed`
        : ""),
  );

  function save() {
    if (invalid) return;
    onSave(name.trim(), choice ? normalized : []);
  }

  function cancel() {
    name = field.name;
    options = [...field.options];
  }
</script>

<div class="mb-2 grid grid-cols-[minmax(0,1fr)_auto_auto] items-center gap-[6px] border-b border-line pb-[10px]">
  <input
    class="col-start-1 min-h-[34px] w-full rounded-lg border border-line bg-white px-[10px] py-2 text-[13px] text-ink focus:border-sage"
    bind:value={name}
    disabled={busy}
    aria-label={`${field.name} name`}
  />
  <span class="col-start-2 text-[10px] tracking-[.1em] text-muted uppercase">{field.kind}</span>
  <button class="col-start-3 border-0 bg-transparent px-2 py-1 text-[11px] text-[#9a8a7d] enabled:hover:text-ember" type="button" onclick={onRemove} disabled={busy} aria-label={`Remove ${field.name}`}>Remove</button>

  {#if choice}
    <div class="col-span-full">
      <OptionRows bind:options disabled={busy} />
      <p class="mt-[5px] mb-0 text-[11px] leading-[1.6] text-muted">{hint}</p>
    </div>
  {/if}

  {#if dirty}
    <div class="col-span-full mt-2 flex gap-[6px]">
      <button class="rounded-lg border-0 bg-sage px-3 py-[7px] text-xs font-semibold text-white" type="button" onclick={save} disabled={busy || invalid}>Save</button>
      <button class="rounded-lg border border-line bg-transparent px-3 py-[7px] text-xs font-semibold text-muted" type="button" onclick={cancel} disabled={busy}>Cancel</button>
    </div>
  {/if}
</div>
