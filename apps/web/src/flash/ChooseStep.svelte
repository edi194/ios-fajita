<script lang="ts">
  import { session } from "./session.svelte.ts";
  import FilePick from "./FilePick.svelte";
  import type { Partition } from "../lib/fastboot.ts";
  import { fmtBytes } from "../lib/flasher.ts";

  const targets: { p: Partition; name: string; what: string; accept: string }[] = [
    { p: "userdata", name: "iOS root", what: "userdata · .simg", accept: ".simg,.img" },
    { p: "boot", name: "Enxerto", what: "boot · boot.img", accept: ".img" },
    { p: "logo", name: "Splash", what: "logo · logo.img", accept: ".img" },
  ];
  const accept = $derived(targets.find((t) => t.p === session.partition)!.accept);

  // images a patcher run left in this browser's private storage (OPFS)
  let stored = $state<{ name: string; size: number; file: File }[]>([]);
  $effect(() => {
    (async () => {
      try {
        const dir = await navigator.storage.getDirectory();
        const out: typeof stored = [];
        for await (const [name, h] of dir as unknown as AsyncIterable<[string, FileSystemHandle]>) {
          if (h.kind === "file" && /\.(s?img)$/i.test(name)) {
            const file = await (h as FileSystemFileHandle).getFile();
            out.push({ name, size: file.size, file });
          }
        }
        stored = out;
      } catch {
        stored = [];
      }
    })();
  });

  const c = $derived(session.checked);
</script>

<section class="sheet" aria-labelledby="choose-title">
  {#if session.phone}
    <div class="chip"><i class="dot"></i><b>Poco F1 found</b><span>{session.phone.kind === "bergamota" ? "Bergamota fastboot" : "ABL fastboot"} · unlocked</span></div>
  {/if}
  <h2 id="choose-title">What do you want to write?</h2>

  <div class="targets" role="radiogroup" aria-label="Partition">
    {#each targets as t}
      <button role="radio" aria-checked={session.partition === t.p} class:on={session.partition === t.p} onclick={() => session.setPartition(t.p)}>
        <b>{t.name}</b><small>{t.what}</small>
      </button>
    {/each}
  </div>

  <FilePick {accept} label="Image file" has={!!session.picked} onfile={(f) => session.pick(f, f.name, "file")}>
    {#snippet children()}
      {#if session.picked}
        <b>{session.picked.name}</b>
        <small>
          {fmtBytes(session.picked.size)}
          {#if c}· {c.image.sparse ? "Android sparse" : "raw"} · expands to {fmtBytes(c.image.expandedBytes)}{/if}
          {#if session.checking}· reading…{/if}
        </small>
      {/if}
    {/snippet}
  </FilePick>

  {#if stored.length}
    <div class="stored">
      <span class="muted">In this browser:</span>
      {#each stored as s}
        <button class="pill" onclick={() => session.pick(s.file, s.name, "browser")}>{s.name} · {fmtBytes(s.size)}</button>
      {/each}
    </div>
  {/if}

  {#if session.checkError}<p class="problem" role="alert">{session.checkError}</p>{/if}
  {#each c?.problems ?? [] as p}<p class="problem">{p}</p>{/each}

  <p class="muted" style="margin-top: 20px">The file stays on this computer. It is read in pieces while flashing, never uploaded.</p>
  <div class="row">
    <button class="btn" disabled={!c || c.problems.length > 0 || session.checking} onclick={() => session.go("Confirm")}>Continue</button>
  </div>
</section>

<style>
  .targets { display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px; margin: 4px 0 20px; }
  .targets button { text-align: left; padding: 16px; border: 2px dashed var(--ink-faint); border-radius: 4px; background: transparent; cursor: pointer; transition: border-color 160ms, background-color 160ms; }
  .targets button:hover { border-color: var(--ink); }
  .targets button.on { border: 2px solid var(--ink); background: var(--white); }
  .targets b { display: block; font-size: 20px; font-weight: 850; }
  .targets small { font-size: 13px; color: var(--ink-soft); }
  .stored { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
  .pill { border: 0; background: var(--white); border-radius: 999px; padding: 8px 14px; font: 600 13px var(--mono); cursor: pointer; box-shadow: inset 0 0 0 1px var(--paper-line); }
  @media (max-width: 600px) { .targets { grid-template-columns: 1fr; } }
</style>
