<script lang="ts">
  import type { Snippet } from "svelte";

  let { accept, label, has, onfile, children }: { accept: string; label: string; has: boolean; onfile: (f: File) => void; children?: Snippet } = $props();
  let input: HTMLInputElement;
  let over = $state(false);

  function drop(e: DragEvent) {
    e.preventDefault();
    over = false;
    const f = e.dataTransfer?.files[0];
    if (f) onfile(f);
  }
</script>

<div
  class="drop"
  class:has
  class:over
  role="group"
  aria-label={label}
  ondragover={(e) => { e.preventDefault(); over = true; }}
  ondragleave={() => (over = false)}
  ondrop={drop}
>
  <div>
    {#if has && children}
      {@render children()}
    {:else}
      <b>Drop the file here</b>
      <small>or choose it from your computer</small>
    {/if}
  </div>
  <button class="btn ghost" onclick={() => input.click()}>{has ? "Change" : "Choose file"}</button>
  <input bind:this={input} type="file" {accept} hidden onchange={() => input.files?.[0] && onfile(input.files[0])} />
</div>
