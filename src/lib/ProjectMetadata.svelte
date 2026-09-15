<script lang="ts">
  import {
    createCreateMetadataField,
    createDeleteMetadataField,
    createDeleteProject,
    createSetProjectMetadata,
    createUpdateMetadataField,
    createUpdateProject,
    type FieldKind,
    type MetadataField,
    type Project,
  } from "$lib/api/generated";
  import FieldRow from "$lib/FieldRow.svelte";
  import OptionRows from "$lib/OptionRows.svelte";
  import { choiceOptions, isValidValue, normalizeOptions, valueFor } from "$lib/metadata";

  let { project, fields, onDeleted }: { project: Project; fields: MetadataField[]; onDeleted: () => void } =
    $props();

  const kinds: FieldKind[] = ["text", "number", "choice"];

  const setValue = createSetProjectMetadata();
  const renameProject = createUpdateProject();
  const removeProject = createDeleteProject();
  const addFieldMutation = createCreateMetadataField();
  const renameField = createUpdateMetadataField();
  const removeField = createDeleteMetadataField();

  let settings: HTMLDialogElement;
  let error = $state("");
  let notice = $state("");
  let newFieldName = $state("");
  let newFieldKind = $state<FieldKind>("text");
  let newFieldOptions = $state<string[]>([""]);

  /** A choice field needs a name and at least one non-blank option; the API rejects the rest. */
  const canAdd = $derived(
    !!newFieldName.trim() && (newFieldKind !== "choice" || normalizeOptions(newFieldOptions).length > 0),
  );

  const busy = $derived(
    setValue.isPending ||
      renameProject.isPending ||
      removeProject.isPending ||
      addFieldMutation.isPending ||
      renameField.isPending ||
      removeField.isPending,
  );

  function message(reason: unknown) {
    if (!reason) return "";
    return reason instanceof Error ? reason.message : String(reason);
  }

  async function run(action: () => Promise<unknown>, done = "") {
    error = "";
    notice = "";
    try {
      await action();
      notice = done;
    } catch (reason) {
      error = message(reason);
    }
  }

  async function saveValue(field: MetadataField, element: HTMLInputElement | HTMLSelectElement) {
    const value = element.value.trim();
    if (!isValidValue(field, value)) {
      error =
        field.kind === "number"
          ? `Enter a number for ${field.name}.`
          : `Choose one of the options for ${field.name}.`;
      element.value = valueFor(project, field.id);
      return;
    }
    if (value === valueFor(project, field.id)) return;

    await run(() =>
      setValue.mutateAsync({ id: project.id, fieldId: field.id, data: { value: value || null } }),
    );
  }

  // Name and options go in one update so an edit cannot clobber a concurrent one.
  function saveField(field: MetadataField, name: string, options: string[]) {
    void run(
      () => renameField.mutateAsync({ id: field.id, data: { name, options } }),
      `Updated ${name}.`,
    );
  }

  function rename(event: FocusEvent & { currentTarget: HTMLInputElement }) {
    const name = event.currentTarget.value.trim();
    if (!name || name === project.name) {
      event.currentTarget.value = project.name;
      return;
    }
    void run(() => renameProject.mutateAsync({ id: project.id, data: { name } }), `Renamed to ${name}.`);
  }

  function addField(event: SubmitEvent) {
    event.preventDefault();
    if (!canAdd) return;

    const name = newFieldName.trim();
    const options = newFieldKind === "choice" ? normalizeOptions(newFieldOptions) : [];

    void run(async () => {
      await addFieldMutation.mutateAsync({ data: { name, kind: newFieldKind, options } });
      newFieldName = "";
      newFieldOptions = [""];
      newFieldKind = "text";
    }, `Added ${name}.`);
  }

  function deleteField(field: MetadataField) {
    if (!window.confirm(`Remove ${field.name} and its value from every project?`)) return;
    void run(() => removeField.mutateAsync({ id: field.id }), `Removed ${field.name}.`);
  }

  function deleteProject() {
    if (!window.confirm(`Delete ${project.name}? Its tasks move to Inbox.`)) return;
    void run(async () => {
      await removeProject.mutateAsync({ id: project.id });
      settings.close();
      onDeleted();
    }, "Project deleted. Its tasks are in Inbox.");
  }
</script>

<section class="project-metadata" aria-label="Project metadata">
  <header class="metadata-heading">
    <h2>Details</h2>
    <button class="text-button" onclick={() => { error = ""; settings.showModal(); }} disabled={busy}>
      Fields <span aria-hidden="true">#</span>
    </button>
  </header>

  {#if fields.length === 0}
    <p class="metadata-empty">No fields yet. Add one to track what matters for every project.</p>
  {:else}
    <dl class="value-list">
      {#each fields as field (field.id)}
        <div class="value-row">
          <dt><label for={`value-${project.id}-${field.id}`}>{field.name}</label></dt>
          <dd>
            {#if field.kind === "choice"}
              <select
                id={`value-${project.id}-${field.id}`}
                value={valueFor(project, field.id)}
                disabled={busy}
                onchange={(event) => saveValue(field, event.currentTarget)}
              >
                <option value="">—</option>
                {#each choiceOptions(field, valueFor(project, field.id)) as option (option)}
                  <option value={option}>{option}</option>
                {/each}
              </select>
            {:else}
              <input
                id={`value-${project.id}-${field.id}`}
                type={field.kind === "number" ? "number" : "text"}
                value={valueFor(project, field.id)}
                disabled={busy}
                onblur={(event) => saveValue(field, event.currentTarget)}
                onkeydown={(event) => event.key === "Enter" && event.currentTarget.blur()}
              />
            {/if}
          </dd>
        </div>
      {/each}
    </dl>
  {/if}

  {#if error}<p class="metadata-error" role="alert">{error}</p>{/if}
  {#if notice}<p class="metadata-notice" role="status">{notice}</p>{/if}
</section>

<dialog bind:this={settings} class="settings" aria-labelledby="settings-title">
  <section class="settings-body">
    <header class="settings-heading">
      <h2 id="settings-title">Project settings</h2>
      <button class="text-button" onclick={() => settings.close()} aria-label="Close project settings">
        Close
      </button>
    </header>

    <label class="name-field">
      <span>Name</span>
      <input value={project.name} disabled={busy} onblur={rename} />
    </label>

    <h3>Fields</h3>
    <p class="hint">Fields are shared by every project; their type is fixed once created.</p>

    {#each fields as field (field.id)}
      <FieldRow
        {field}
        staleValue={valueFor(project, field.id)}
        {busy}
        onSave={(name, options) => saveField(field, name, options)}
        onRemove={() => deleteField(field)}
      />
    {/each}

    <form class="add-field" onsubmit={addField}>
      <div class="add-field-head">
        <input bind:value={newFieldName} placeholder="New field" aria-label="New field name" disabled={busy} />
        <select bind:value={newFieldKind} aria-label="New field type" disabled={busy}>
          {#each kinds as kind (kind)}<option value={kind}>{kind}</option>{/each}
        </select>
      </div>
      {#if newFieldKind === "choice"}
        <p class="hint">Options — Enter for the next one, Tab to finish.</p>
        <OptionRows bind:options={newFieldOptions} disabled={busy} />
      {/if}
      <button type="submit" disabled={busy || !canAdd}>Add field</button>
    </form>

    {#if project.id !== "inbox"}
      <footer class="settings-footer">
        <button class="delete-project" onclick={deleteProject} disabled={busy}>
          Delete project
        </button>
        <p>Its tasks move to Inbox; its metadata is removed.</p>
      </footer>
    {/if}

    {#if error}<p class="metadata-error" role="alert">{error}</p>{/if}
  </section>
</dialog>

<style>
  .project-metadata { margin-bottom: 30px; }
  .metadata-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; }
  .metadata-heading h2 { margin: 0; color: var(--muted); font-size: 10px; font-weight: 600; letter-spacing: .14em; text-transform: uppercase; }
  .text-button { min-height: 44px; padding: 0 10px; border: 0; background: transparent; color: var(--red); font-size: 11px; font-weight: 600; }
  .metadata-empty { margin: 4px 0 0; color: var(--muted); font-size: 12px; }
  .value-list { display: grid; grid-template-columns: minmax(90px, 160px) minmax(0, 1fr); gap: 6px 16px; margin: 6px 0 0; }
  .value-row { display: contents; }
  .value-list dt { display: flex; align-items: center; min-height: 34px; color: var(--muted); font-size: 11px; overflow-wrap: anywhere; }
  .value-list dd { margin: 0; }
  .value-list input, .value-list select {
    width: 100%; min-height: 34px; padding: 6px 9px; border: 1px solid var(--line); border-radius: 8px;
    background: #fdfbf6; color: var(--ink); font-size: 13px;
  }
  .value-list input:focus, .value-list select:focus { border-color: var(--green); }
  .metadata-error { margin: 10px 0 0; color: #a33828; font-size: 11px; }
  .metadata-notice { margin: 10px 0 0; color: var(--green); font-size: 11px; }
  .settings {
    width: min(560px, calc(100% - 32px)); max-height: calc(100dvh - 40px); padding: 0; overflow: auto;
    border: 1px solid var(--line); border-radius: 16px; color: var(--ink); background: #fcfaf5;
  }
  .settings::backdrop { background: #20251d66; backdrop-filter: blur(3px); }
  .settings-body { padding: 24px; }
  .settings-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 18px; }
  .settings h2 { margin: 0; font-family: Georgia, serif; font-size: 24px; font-weight: 400; letter-spacing: -.04em; }
  .settings h3 { margin: 24px 0 2px; font-size: 11px; letter-spacing: .12em; text-transform: uppercase; }
  .hint { margin: 0 0 10px; color: var(--muted); font-size: 11px; line-height: 1.7; }
  .name-field { display: grid; gap: 5px; font-size: 11px; color: var(--muted); }
  .settings input, .settings select {
    padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; background: white; color: var(--ink); font-size: 13px;
  }
  .add-field { display: grid; gap: 8px; margin-top: 10px; }
  .add-field .hint { margin: 0; }
  .add-field-head { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 6px; }
  .add-field button { justify-self: end; padding: 9px 14px; border: 0; border-radius: 8px; background: var(--green); color: white; font-size: 12px; font-weight: 600; }
  .settings-footer { display: grid; gap: 4px; margin-top: 28px; padding-top: 18px; border-top: 1px solid var(--line); }
  .delete-project { justify-self: start; padding: 8px 12px; border: 1px solid #e5c4b8; border-radius: 8px; background: #fbe8e0; color: #a33828; font-size: 12px; }
  .settings-footer p { margin: 0; color: var(--muted); font-size: 11px; }
  @media (max-width: 600px) {
    .value-list { grid-template-columns: minmax(0, 1fr); gap: 4px; }
    .value-list dt { min-height: 0; padding-top: 6px; }
  }
</style>
