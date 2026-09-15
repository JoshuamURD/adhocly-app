<script lang="ts">
  import "../app.css";
  import { onMount } from "svelte";
  import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
  import AppShell from "$lib/components/AppShell.svelte";
  import { listen } from "@tauri-apps/api/event";
  import { offlineSyncEnabled, stopOfflineSync, syncOfflineData } from "$lib/api-fetch";
  import { isZoomShortcut } from "$lib/zoom";

  const queryClient = new QueryClient();
  const { children } = $props();
  let ready = $state(false);

  onMount(() => {
    // The viewport meta and Tauri's window config do most of this; these cover the browser build
    // and whatever the engines still let through.
    function onKeydown(event: KeyboardEvent) {
      if (isZoomShortcut(event)) event.preventDefault();
    }
    // Trackpad pinch arrives as a ctrl+wheel, and ctrl+scroll zooms in Chromium/WebKit.
    function onWheel(event: WheelEvent) {
      if (event.ctrlKey) event.preventDefault();
    }
    const onGesture = (event: Event) => event.preventDefault();

    const sync = () => void syncOfflineData().catch(console.error);
    const foreground = () => {
      if (document.visibilityState === "visible") sync();
      else stopOfflineSync();
    };
    let disposed = false;
    let unlisten: (() => void) | undefined;
    void offlineSyncEnabled().then(async (enabled) => {
      if (disposed) return;
      if (enabled) queryClient.setDefaultOptions({
        queries: { networkMode: "always" },
        mutations: { networkMode: "always" },
      });
      // Configure local query/mutation execution before any consumer is mounted.
      ready = true;
      if (enabled) {
        try {
          const stop = await listen("adhocly:resume", sync);
          if (disposed) stop(); else unlisten = stop;
        } catch (error) { console.error(error); }
      }
      if (!disposed) sync();
    });
    const refresh = () => void queryClient.invalidateQueries();

    window.addEventListener("keydown", onKeydown);
    window.addEventListener("wheel", onWheel, { passive: false });
    window.addEventListener("gesturestart" as string, onGesture);
    window.addEventListener("gesturechange" as string, onGesture);
    window.addEventListener("online", sync);
    window.addEventListener("adhocly:sync", refresh);
    window.addEventListener("focus", sync);
    window.addEventListener("pageshow", sync);
    document.addEventListener("visibilitychange", foreground);
    return () => {
      disposed = true;
      unlisten?.();
      stopOfflineSync();
      window.removeEventListener("focus", sync);
      window.removeEventListener("pageshow", sync);
      document.removeEventListener("visibilitychange", foreground);
      window.removeEventListener("keydown", onKeydown);
      window.removeEventListener("wheel", onWheel);
      window.removeEventListener("gesturestart" as string, onGesture);
      window.removeEventListener("gesturechange" as string, onGesture);
      window.removeEventListener("online", sync);
      window.removeEventListener("adhocly:sync", refresh);
    };
  });
</script>

<QueryClientProvider client={queryClient}>
  {#if ready}<AppShell>{@render children()}</AppShell>{/if}
</QueryClientProvider>
