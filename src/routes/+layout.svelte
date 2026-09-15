<script lang="ts">
  import "../app.css";
  import { onMount } from "svelte";
  import { QueryClient, QueryClientProvider } from "@tanstack/svelte-query";
  import AppShell from "$lib/components/AppShell.svelte";
  import { isZoomShortcut } from "$lib/zoom";

  const queryClient = new QueryClient();
  const { children } = $props();

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

    window.addEventListener("keydown", onKeydown);
    window.addEventListener("wheel", onWheel, { passive: false });
    window.addEventListener("gesturestart" as string, onGesture);
    window.addEventListener("gesturechange" as string, onGesture);
    return () => {
      window.removeEventListener("keydown", onKeydown);
      window.removeEventListener("wheel", onWheel);
      window.removeEventListener("gesturestart" as string, onGesture);
      window.removeEventListener("gesturechange" as string, onGesture);
    };
  });
</script>

<QueryClientProvider client={queryClient}>
  <AppShell>{@render children()}</AppShell>
</QueryClientProvider>
