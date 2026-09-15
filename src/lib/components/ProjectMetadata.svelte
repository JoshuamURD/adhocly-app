<script lang="ts">
  import {
    createCreateMetadataField,
    createDeleteMetadataField,
    createDeleteProject,
    createMoveProject,
    createSetProjectMetadata,
    createUpdateMetadataField,
    createUpdateProject,
    type FieldKind,
    type Folder,
    type MetadataField,
    type Project,
  } from "$lib/api/generated";
  import FieldRow from "$lib/components/FieldRow.svelte";
  import OptionRows from "$lib/components/OptionRows.svelte";
  import { folderPath } from "$lib/folders";
  import { choiceOptions, isValidValue, normalizeOptions, valueFor } from "$lib/metadata";

  let { project, fields, folders, onDeleted }: { project: Project; fields: MetadataField[]; folders: Folder[]; onDeleted: () => void } =
    $props();

  const kinds: FieldKind[] = ["text", "number", "choice"];

  const setValue = createSetProjectMetadata();
  const renameProject = createUpdateProject();
  const fileProject = createMoveProject();
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
  /** Folders indented by path, so a nested folder is not just a repeated name. */
  const folderOptions = $derived(
    [...folders]
      .map((folder) => ({ id: folder.id, path: folderPath(folders, folder.id) }))
      .sort((a, b) => a.path.localeCompare(b.path)),
  );

  const canAdd = $derived(
    !!newFieldName.trim() && (newFieldKind !== "choice" || normalizeOptions(newFieldOptions).length > 0),
  );

  const busy = $derived(
    setValue.isPending ||
      renameProject.isPending ||
      fileProject.isPending ||
      removeProject.isPending ||
      addFieldMutation.isPending ||
      renameField.isPending ||
      removeField.isPending,
  );

  const fieldInput =
    "w-full min-h-[34px] rounded-lg border border-line bg-[#fdfbf6] px-[9px] py-[6px] text-[13px] text-ink focus:border-sage";
  const settingInput =
    "rounded-lg border border-line bg-white px-[10px] py-2 text-[13px] text-ink";
  const textButton = "min-h-11 border-0 bg-transparent px-[10px] text-[11px] font-semibold text-ember";
  const message = "mt-[10px] text-[11px]";

  function reason(reason: unknown) {
    if (!reason) return "";
    return reason instanceof Error ? reason.message : String(reason);
  }

  async function run(action: () => Promise<unknown>, done = "") {
    error = "";
    notice = "";
    try {
      await action();
      notice = done;
    } catch (caught) {
      error = reason(caught);
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

  /** The drag-free way to file a project, for keyboards and touch. */
  function file(event: Event & { currentTarget: HTMLSelectElement }) {
    const folderId = event.currentTarget.value || null;
    if (folderId === (project.folderId ?? null)) return;
    void run(
      () => fileProject.mutateAsync({ id: project.id, data: { folderId } }),
      folderId ? "Filed." : "Moved to the top level.",
    );
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

<section class="mb-[30px]" aria-label="Project metadata">
  <header class="flex items-center justify-between gap-4">
    <h2 class="m-0 text-[10px] font-semibold tracking-[.14em] text-muted uppercase">Details</h2>
    <button class={textButton} onclick={() => { error = ""; settings.showModal(); }} disabled={busy}>
      Fields <span aria-hidden="true">#</span>
    </button>
  </header>

  {#if fields.length === 0}
    <p class="mt-1 mb-0 text-xs text-muted">No fields yet. Add one to track what matters for every project.</p>
  {:else}
    <dl class="mt-[6px] mb-0 grid grid-cols-[minmax(90px,160px)_minmax(0,1fr)] gap-x-4 gap-y-[6px] max-[600px]:grid-cols-1 max-[600px]:gap-1">
      {#each fields as field (field.id)}
        <div class="contents">
          <dt class="flex min-h-[34px] items-center text-[11px] text-muted wrap-anywhere max-[600px]:min-h-0 max-[600px]:pt-[6px]"><label for={`value-${project.id}-${field.id}`}>{field.name}</label></dt>
          <dd class="m-0">
            {#if field.kind === "choice"}
              <select
                class={fieldInput}
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
                class={fieldInput}
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

  {#if error}<p class="{message} text-[#a33828]" role="alert">{error}</p>{/if}
  {#if notice}<p class="{message} text-sage" role="status">{notice}</p>{/if}
</section>

<dialog bind:this={settings} class="m-auto w-[min(560px,calc(100%_-_32px))] max-h-[calc(100dvh_-_40px)] overflow-auto rounded-2xl border border-line bg-[#fcfaf5] text-ink" aria-labelledby="settings-title">
  <section class="p-6">
    <header class="mb-[18px] flex items-center justify-between gap-3">
      <h2 class="m-0 font-display text-2xl font-normal tracking-[-.04em]" id="settings-title">Project settings</h2>
      <button class={textButton} onclick={() => settings.close()} aria-label="Close project settings">
        Close
      </button>
    </header>

    <label class="grid gap-[5px] text-[11px] text-muted">
      <span>Name</span>
      <input class={settingInput} value={project.name} disabled={busy} onblur={rename} />
    </label>

    <label class="mt-[10px] grid gap-[5px] text-[11px] text-muted">
      <span>Folder</span>
      <select class={settingInput} value={project.folderId ?? ""} disabled={busy} onchange={file}>
        <option value="">— Top level</option>
        {#each folderOptions as option (option.id)}<option value={option.id}>{option.path}</option>{/each}
      </select>
    </label>

    <h3 class="mt-6 mb-[2px] text-[11px] font-bold tracking-[.12em] uppercase">Fields</h3>
    <p class="mb-[10px] text-[11px] leading-[1.7] text-muted">Fields are shared by every project; their type is fixed once created.</p>

    {#each fields as field (field.id)}
      <FieldRow
        {field}
        staleValue={valueFor(project, field.id)}
        {busy}
        onSave={(name, options) => saveField(field, name, options)}
        onRemove={() => deleteField(field)}
      />
    {/each}

    <form class="mt-[10px] grid gap-2" onsubmit={addField}>
      <div class="grid grid-cols-[minmax(0,1fr)_auto] gap-[6px]">
        <input class={settingInput} bind:value={newFieldName} placeholder="New field" aria-label="New field name" disabled={busy} />
        <select class={settingInput} bind:value={newFieldKind} aria-label="New field type" disabled={busy}>
          {#each kinds as kind (kind)}<option value={kind}>{kind}</option>{/each}
        </select>
      </div>
      {#if newFieldKind === "choice"}
        <p class="m-0 text-[11px] leading-[1.7] text-muted">Options — Enter for the next one, Tab to finish.</p>
        <OptionRows bind:options={newFieldOptions} disabled={busy} />
      {/if}
      <button class="justify-self-end rounded-lg border-0 bg-sage px-[14px] py-[9px] text-xs font-semibold text-white" type="submit" disabled={busy || !canAdd}>Add field</button>
    </form>

    {#if project.id !== "inbox"}
      <footer class="mt-7 grid gap-1 border-t border-line pt-[18px]">
        <button class="justify-self-start rounded-lg border border-[#e5c4b8] bg-[#fbe8e0] px-3 py-2 text-xs text-[#a33828]" onclick={deleteProject} disabled={busy}>
          Delete project
        </button>
        <p class="m-0 text-[11px] text-muted">Its tasks move to Inbox; its metadata is removed.</p>
      </footer>
    {/if}

    {#if error}<p class="{message} text-[#a33828]" role="alert">{error}</p>{/if}
  </section>
</dialog>
