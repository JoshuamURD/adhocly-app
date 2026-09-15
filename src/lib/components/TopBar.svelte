<script lang="ts">
  import { page } from "$app/state";
  import { onMount } from "svelte";
  import {
    discardSyncConflict,
    getSyncStatus,
    keepSyncConflict,
    retrySyncConflict,
    offlineSyncEnabled,
    renameSyncConflict,
    syncOfflineData,
    type SyncConflict,
    type SyncStatus,
  } from "$lib/api-fetch";
  import { useTasks } from "$lib/tasks.svelte";
  import Icon from "./Icon.svelte";

  const store = useTasks();
  let syncDialog: HTMLDialogElement;
  let syncEnabled = $state(false);
  let sync = $state<SyncStatus>(getSyncStatus());
  let renameTo = $state("");
  let actionError = $state("");

  // Mirrors the `title` each route hands to TaskPage.
  const title = $derived(
    page.route.id === "/"
      ? "Today"
      : page.route.id === "/all"
        ? "All tasks"
        : (store.projectById(page.params.id ?? "")?.name ?? "Project"),
  );
  const renameable = $derived(
    sync.conflict?.message === "that name is already taken" && typeof sync.conflict.body?.name === "string",
  );
  const existingCreate = $derived(sync.conflict?.method === "POST" && sync.conflict.url.split("/").length === 3 && !!sync.conflict.server);
  const lastSync = $derived(sync.lastSyncedAt ? relativeTime(sync.lastSyncedAt, store.state.now) : "Never synced");

  onMount(() => {
    const update = (event: Event) => (sync = (event as CustomEvent<SyncStatus>).detail);
    window.addEventListener("adhocly:sync-status", update);
    void offlineSyncEnabled().then((enabled) => {
      syncEnabled = enabled;
      sync = getSyncStatus();
    });
    return () => window.removeEventListener("adhocly:sync-status", update);
  });

  function relativeTime(value: string, now: Date) {
    const minutes = Math.max(0, Math.floor((now.getTime() - new Date(value).getTime()) / 60_000));
    if (minutes < 1) return "just now";
    if (minutes < 60) return `${minutes}m ago`;
    const hours = Math.floor(minutes / 60);
    if (hours < 24) return `${hours}h ago`;
    const days = Math.floor(hours / 24);
    return days < 7 ? `${days}d ago` : new Date(value).toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }

  function describe(conflict?: SyncConflict) {
    if (!conflict) return "The server could not be reached.";
    const resource = conflict.url.split("/")[2]?.replace("metadata-fields", "field") ?? "change";
    const subject = conflict.body?.title ?? conflict.body?.name;
    if (conflict.method === "DELETE") return `Delete ${resource}`;
    return `${conflict.method === "POST" ? "Create or change" : "Update"} ${subject ? `“${subject}”` : resource}`;
  }

  function openSync() {
    if (sync.phase !== "failed") {
      void syncOfflineData();
      return;
    }
    actionError = "";
    renameTo = sync.conflict?.body?.name ?? "";
    syncDialog.showModal();
  }

  async function decide(action: () => Promise<void>) {
    actionError = "";
    syncDialog.close();
    try { await action(); }
    catch (error) {
      actionError = error instanceof Error ? error.message : "Could not save your decision";
      syncDialog.showModal();
    }
  }

  function retry() {
    const conflict = sync.conflict;
    void decide(() => conflict ? retrySyncConflict(conflict.id) : syncOfflineData());
  }

  function discard() {
    const conflict = sync.conflict;
    if (!conflict) return;
    const dependents = conflict.dependents ? ` This also discards ${conflict.dependents} later change(s) that depend on items it creates.` : "";
    if (!window.confirm(`Discard this local change and use the server version?${dependents}`)) return;
    void decide(() => discardSyncConflict(conflict.id, conflict.dependents));
  }

  function keep() {
    const conflict = sync.conflict;
    if (!conflict || !window.confirm("Apply your queued change over the server version shown here?")) return;
    void decide(() => keepSyncConflict(conflict.id, conflict.serverVersion));
  }

  async function renameAndRetry(event: SubmitEvent) {
    event.preventDefault();
    const conflict = sync.conflict;
    if (!conflict) return;
    actionError = "";
    try {
      syncDialog.close();
      await renameSyncConflict(conflict.id, renameTo);
    } catch (error) {
      actionError = error instanceof Error ? error.message : "Could not update the change";
      syncDialog.showModal();
    }
  }
</script>

<header class="sticky top-0 z-[9] flex min-h-[89px] items-center justify-between gap-4 border-b border-line bg-paper pt-[calc(18px_+_env(safe-area-inset-top))] pr-[max(24px,env(safe-area-inset-right))] pb-[18px] pl-[max(24px,env(safe-area-inset-left))] max-[600px]:min-h-[76px] max-[600px]:pr-[max(18px,env(safe-area-inset-right))] max-[600px]:pl-[max(18px,env(safe-area-inset-left))]">
  <div class="flex min-w-0 items-center gap-5 max-[600px]:gap-[14px]">
    <button
      class="icon-button border border-line hover:bg-[#e7e6dc]"
      onclick={() => (store.state.drawerOpen = true)}
      aria-label="Open project navigation"
      aria-haspopup="dialog"
      aria-controls="project-drawer"
    >
      <Icon name="menu" />
    </button>
    <h1 class="m-0 min-w-0 font-display text-[27px] font-bold tracking-[-.055em] wrap-anywhere">{title}<span class="text-ember">.</span></h1>
  </div>

  {#if syncEnabled}
    <button
      class="flex min-h-11 shrink-0 items-center gap-2 rounded-xl border px-3 text-[11px] font-semibold transition-colors {sync.phase === 'failed' ? 'border-[#ddb4aa] bg-[#f8e3dc] text-[#9f3828]' : 'border-line bg-[#eeece4] text-muted hover:bg-[#e7e6dc]'}"
      onclick={openSync}
      disabled={sync.phase === "syncing"}
      aria-label={sync.phase === "failed" ? `Sync failed: ${sync.message}` : sync.lastSyncedAt ? `Synced ${lastSync}. Sync now` : "Sync now"}
      aria-haspopup={sync.phase === "failed" ? "dialog" : undefined}
      aria-controls={sync.phase === "failed" ? "sync-dialog" : undefined}
    >
      <Icon name="sync" size={18} class={sync.phase === "syncing" ? "animate-spin" : ""} />
      <span>{sync.phase === "syncing" ? "Syncing" : sync.phase === "failed" ? "Sync failed" : sync.lastSyncedAt ? "Synced" : "Sync"}</span>
      {#if sync.phase === "idle" && sync.lastSyncedAt}<span class="border-l border-current/20 pl-2 font-normal">{lastSync}</span>{/if}
      {#if sync.pending > 0}<span class="grid min-w-5 place-items-center rounded-full bg-current/10 px-1 py-0.5 text-[10px]">{sync.pending}</span>{/if}
    </button>
  {/if}
</header>

<dialog id="sync-dialog" bind:this={syncDialog} class="m-auto w-[min(460px,calc(100%_-_32px))] rounded-2xl border border-line bg-[#fcfaf5] text-ink" aria-labelledby="sync-title">
  <section class="p-6">
    <header class="flex items-start justify-between gap-4">
      <div>
        <p class="m-0 text-[10px] font-bold tracking-[.14em] text-ember uppercase">Sync failed</p>
        <h2 id="sync-title" class="mt-1 mb-0 font-display text-[26px] tracking-[-.04em]">Your device needs a decision.</h2>
      </div>
      <button class="icon-button -mt-2 -mr-2" onclick={() => syncDialog.close()} aria-label="Close sync conflict"><Icon name="close" /></button>
    </header>

    <div class="mt-5 rounded-xl border border-[#e8d6ce] bg-[#fbede7] p-4">
      <p class="m-0 text-sm font-semibold">{describe(sync.conflict)}</p>
      <p class="mt-1 mb-0 text-xs leading-5 text-[#7f554c]">{sync.message}</p>
      <p class="mt-2 mb-0 text-[11px] text-[#7f554c]">Last successful sync: {lastSync}.</p>
      {#if sync.pending > 1}<p class="mt-2 mb-0 text-[11px] text-[#7f554c]">{sync.pending - 1} later {sync.pending === 2 ? "change is" : "changes are"} waiting behind this one.</p>{/if}
    </div>

    {#if sync.conflict}
      <details class="mt-4 text-xs">
        <summary class="cursor-pointer font-semibold">Compare your change with the server</summary>
        <p>Your queued change</p>
        <pre class="max-h-40 overflow-auto rounded-lg bg-white p-3 whitespace-pre-wrap wrap-anywhere">{JSON.stringify(sync.conflict.body, null, 2)}</pre>
        <p>Last fetched server version</p>
        <pre class="max-h-40 overflow-auto rounded-lg bg-white p-3 whitespace-pre-wrap wrap-anywhere">{sync.conflict.server ? JSON.stringify(sync.conflict.server, null, 2) : "This item is not on the server."}</pre>
      </details>
      {#if existingCreate}
        <p class="mt-3 text-xs text-muted">This item already exists on the server. Discard this create to use the server item; its dependent changes will be kept.</p>
      {:else if sync.conflict.status === 409}
        <button class="mt-3 min-h-11 px-2 text-xs font-semibold text-sage" onclick={keep}>Keep my change</button>
      {/if}
    {/if}

    {#if renameable}
      <form class="mt-5 grid gap-2" onsubmit={renameAndRetry}>
        <label class="grid gap-1 text-[11px] text-muted">
          <span>Choose a different name</span>
          <input class="rounded-lg border border-line bg-white px-3 py-2.5 text-sm text-ink" bind:value={renameTo} required />
        </label>
        <button class="justify-self-start rounded-lg border-0 bg-sage px-4 py-2.5 text-xs font-semibold text-white" type="submit">Rename and retry</button>
      </form>
    {/if}

    {#if actionError}<p class="mt-3 mb-0 text-xs text-[#a33828]" role="alert">{actionError}</p>{/if}

    <footer class="mt-6 flex flex-wrap items-center justify-between gap-3 border-t border-line pt-4">
      <button class="min-h-11 px-2 text-xs font-semibold text-sage" onclick={retry}>Retry unchanged</button>
      {#if sync.conflict}
        <button class="min-h-11 px-2 text-xs font-semibold text-[#a33828]" onclick={discard}>Discard local change</button>
      {:else}
        <button class="min-h-11 px-2 text-xs text-muted" onclick={() => syncDialog.close()}>Not now</button>
      {/if}
    </footer>
  </section>
</dialog>
