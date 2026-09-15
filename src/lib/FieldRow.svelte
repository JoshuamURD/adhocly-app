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

<div class="field-row">
  <input
    class="field-name"
    bind:value={name}
    disabled={busy}
    aria-label={`${field.name} name`}
  />
  <span class="kind">{field.kind}</span>
  <button class="remove" type="button" onclick={onRemove} disabled={busy} aria-label={`Remove ${field.name}`}>Remove</button>

  {#if choice}
    <div class="field-options">
      <OptionRows bind:options disabled={busy} />
      <p class="hint">{hint}</p>
    </div>
  {/if}

  {#if dirty}
    <div class="field-actions">
      <button class="save" type="button" onclick={save} disabled={busy || invalid}>Save</button>
      <button class="cancel" type="button" onclick={cancel} disabled={busy}>Cancel</button>
    </div>
  {/if}
</div>

<style>
  .field-row {
    display: grid; grid-template-columns: minmax(0, 1fr) auto auto; align-items: center; gap: 6px;
    margin-bottom: 8px; padding-bottom: 10px; border-bottom: 1px solid var(--line);
  }
  .field-name { grid-column: 1; }
  .kind { grid-column: 2; color: var(--muted); font-size: 10px; letter-spacing: .1em; text-transform: uppercase; }
  .remove { grid-column: 3; padding: 4px 8px; border: 0; background: transparent; color: #9a8a7d; font-size: 11px; }
  .remove:not(:disabled):hover { color: var(--red); }
  .field-options { grid-column: 1 / -1; }
  .field-options .hint { margin: 5px 0 0; color: var(--muted); font-size: 11px; line-height: 1.6; }
  .field-actions { grid-column: 1 / -1; display: flex; gap: 6px; margin-top: 8px; }
  .field-actions button { padding: 7px 12px; border-radius: 8px; font-size: 12px; font-weight: 600; }
  .save { border: 0; background: var(--green); color: white; }
  .cancel { border: 1px solid var(--line); background: transparent; color: var(--muted); }
</style>
