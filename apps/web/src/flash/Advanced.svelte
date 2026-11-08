<script lang="ts">
  import { session } from "./session.svelte.ts";
  import { MiB, SAFE_PIECE } from "../lib/flasher.ts";

  let logEl: HTMLElement | undefined = $state();
  $effect(() => {
    session.log.length;
    if (logEl) logEl.scrollTop = logEl.scrollHeight;
  });
  const deviceMax = $derived(session.phone?.maxDownload ?? null);
  const sizes = $derived([128 * MiB, 256 * MiB, SAFE_PIECE, ...(deviceMax && deviceMax > SAFE_PIECE ? [deviceMax] : [])]);
  const label = (n: number) => `${Math.round(n / MiB)} MiB${n === SAFE_PIECE ? " (safe for ABL)" : n === deviceMax ? " (device max)" : ""}`;
</script>

<aside class="adv" aria-label="Advanced">
  <section class="panel">
    <h3>Device</h3>
    {#if session.phone}
      <table class="vars"><tbody>
        {#each session.phone.vars as [k, v]}<tr><td>{k}</td><td>{v}</td></tr>{/each}
      </tbody></table>
    {:else}
      <p class="muted">No phone connected.</p>
    {/if}
  </section>
  <section class="panel">
    <h3>Transfer</h3>
    <label class="field"><span>Piece size</span>
      <select bind:value={session.pieceCap} onchange={() => session.recheck()} disabled={session.flashState === "flashing"}>
        {#each sizes as s}<option value={s}>{label(s)}</option>{/each}
      </select>
    </label>
    <label class="field"><span>Restart when done</span>
      <select bind:value={session.rebootWhenDone} disabled={session.flashState === "flashing"}>
        <option value={true}>yes</option><option value={false}>no</option>
      </select>
    </label>
    {#if session.checked}
      <div class="field"><span>Pieces</span><span class="val">{session.checked.pieces.length}</span></div>
      <div class="field"><span>Format</span><span class="val">{session.checked.image.sparse ? `sparse · ${session.checked.image.blockSize} B blocks` : "raw"}</span></div>
    {/if}
    <p class="muted">Only <code>userdata</code>, <code>boot</code> and <code>logo</code> can be written. There is no erase, format or oem command in this page.</p>
  </section>
  <section class="log" bind:this={logEl} aria-label="Fastboot protocol log">
    {#each session.log as l}
      <div class={l.kind}>{l.kind === "cmd" ? "> " : l.kind === "okay" ? "OKAY " : l.kind === "fail" ? "FAIL " : l.kind === "data" ? "DATA " : l.kind === "info" ? "INFO " : "# "}{l.text}</div>
    {:else}
      <div class="note"># the fastboot conversation appears here</div>
    {/each}
  </section>
</aside>

<style>
  .adv { position: relative; z-index: 1; display: grid; grid-template-columns: 1fr; gap: 18px; align-content: start; }
  .panel { background: var(--paper); padding: 24px 26px; box-shadow: var(--lift); }
  h3 { margin: 0 0 12px; font-size: 20px; font-weight: 850; }
  .vars { width: 100%; border-collapse: collapse; font: 400 13px/1.3 var(--mono); }
  .vars td { padding: 6px 0; border-top: 1px solid var(--paper-line); word-break: break-all; }
  .vars td:last-child { text-align: right; font-weight: 600; padding-left: 12px; }
  .field { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 9px 0; border-top: 1px solid var(--paper-line); font-size: 15px; }
  select, .val { font: 600 13px var(--mono); padding: 6px 10px; border: 2px solid var(--ink); border-radius: 4px; background: var(--white); }
  .muted { color: var(--ink-soft); font-size: 13px; margin: 12px 0 0; }
  .log { grid-column: 1 / -1; background: var(--ink); color: #e8e6dc; font: 400 13px/1.6 var(--mono); padding: 18px 22px; height: 300px; overflow: auto; white-space: pre-wrap; word-break: break-all; }
  .log .cmd { color: var(--ground); }
  .log .okay { color: #8be09b; }
  .log .fail { color: #ff8a6a; }
  .log .note { color: #9a988c; }
</style>
