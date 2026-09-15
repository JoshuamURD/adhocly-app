<script module lang="ts">
  export type IconName = "menu" | "sun" | "list" | "plus" | "close" | "arrow";
</script>

<script lang="ts">
  let { name, size = 22 }: { name: IconName; size?: number } = $props();
</script>

<svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
  {#if name === "menu"}
    <path d="M4 6h16M4 12h10M4 18h16" />
  {:else if name === "sun"}
    <circle cx="12" cy="12" r="4" /><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5" />
  {:else if name === "list"}
    <path d="M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01" />
  {:else if name === "plus"}
    <path d="M12 5v14M5 12h14" />
  {:else if name === "close"}
    <path d="m6 6 12 12M6 18 18 6" />
  {:else}
    <path d="M12 19V5m-6 6 6-6 6 6" />
  {/if}
</svg>
