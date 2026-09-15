<script lang="ts">
  import type { Snippet } from "svelte";
  import Icon, { type IconName } from "./Icon.svelte";

  let {
    title,
    message = "",
    icon = null,
    children,
  }: { title: string; message?: string; icon?: IconName | null; children?: Snippet } = $props();
</script>

<div class="px-5 py-[62px] text-center max-[600px]:px-1 max-[600px]:py-[42px]" role="status">
  {#if icon}
    <div class="mx-auto mb-[26px] grid size-16 place-items-center rounded-full border border-[#d9ddcd] bg-[#edefe3] text-sage"><Icon name={icon} size={29} /></div>
  {/if}
  <h2 class="m-0 font-display text-[clamp(25px,5vw,32px)] font-normal tracking-[-.035em]">{title}</h2>
  {#if message}<p class="mx-auto mt-2 max-w-[330px] text-[13px] leading-[1.8] text-muted">{message}</p>{/if}
  {@render children?.()}
</div>
