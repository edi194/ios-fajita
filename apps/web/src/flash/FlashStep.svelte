<script lang="ts">
  import { session } from "./session.svelte.ts";
  import { fmtBytes, fmtDuration } from "../lib/flasher.ts";

  let now = $state(performance.now());
  // the clock runs only while flashing, so speed and time freeze at the end
  $effect(() => {
    if (session.flashState !== "flashing") return;
    const t = setInterval(() => (now = performance.now()), 500);
    return () => clearInterval(t);
  });

  const p = $derived(session.progress);
  const frac = $derived(p && p.totalBytes ? p.sentBytes / p.totalBytes : 0);
  const pct = $derived(session.flashState === "done" ? 100 : Math.floor(frac * 100));
  const elapsed = $derived(p ? (now - p.startedAt) / 1000 : 0);
  const rate = $derived(p && elapsed > 1 ? p.sentBytes / elapsed : 0);
  const left = $derived(rate ? (p!.totalBytes - p!.sentBytes) / rate : NaN);
  const titles = { flashing: "Writing", done: "Done.", stopped: "Stopped.", error: "The flash failed.", idle: "" };
</script>

<p class="pct" aria-hidden="true">{pct}</p>
<section class="sheet" aria-labelledby="flash-title">
  <h2 id="flash-title">
    {#if session.flashState === "flashing"}Writing {session.partition === "userdata" ? "the iOS root" : session.partition}.{:else}{titles[session.flashState]}{/if}
  </h2>

  {#if session.flashState === "flashing"}
    <p>Keep the cable in and this tab open. The phone can sit on its fastboot screen.</p>
  {:else if session.flashState === "done"}
    <p>{session.partition} is written{session.rebooted ? " and the phone is restarting" : ""}. {session.partition === "userdata" ? "The first boot of iOS takes a few minutes." : ""}</p>
  {:else if session.flashState === "stopped"}
    <p>Stopped after piece {p?.piece} of {p?.pieces}. The partition is only partly written: flash again before booting it.</p>
  {:else if session.flashState === "error"}
    <p class="problem" role="alert">{session.flashError}</p>
  {/if}

  <div class="bar" role="progressbar" aria-label="Flash progress" aria-valuenow={pct} aria-valuemin={0} aria-valuemax={100}><i style="width: {pct}%"></i></div>
  <div class="meta">
    <span>{fmtBytes(p?.sentBytes ?? 0)} of {fmtBytes(p?.totalBytes ?? 0)}</span>
    <span>{rate ? `${(rate / 1e6).toFixed(0)} MB/s` : "–"}</span>
    <span>{session.flashState === "flashing" ? `${fmtDuration(left)} left` : fmtDuration(elapsed)}</span>
  </div>
  {#if p && p.pieces > 1}
    <div class="pieces" aria-hidden="true" style="--n: {Math.min(p.pieces, 48)}">
      {#each Array(p.pieces) as _, i}
        <i class:d={i + 1 < p.piece || session.flashState === "done"} class:n={i + 1 === p.piece && session.flashState === "flashing"}></i>
      {/each}
    </div>
  {/if}
  <p class="muted" aria-live="polite">
    {#if p}Piece {p.piece} of {p.pieces} · {p.phase === "writing" ? "the phone is writing it" : p.phase === "sending" ? "sending" : "finished"}{/if}
  </p>

  <div class="row">
    {#if session.flashState === "flashing"}
      <button class="btn ghost" disabled={session.stopRequested} onclick={() => (session.stopRequested = true)}>{session.stopRequested ? "Stopping after this piece…" : "Stop after this piece"}</button>
    {:else if session.flashState === "done"}
      {#if !session.rebooted}<button class="btn leaf" onclick={() => session.reboot()}>Restart the phone</button>{/if}
      <a class="btn ghost" href="/">Back to Bergamota</a>
    {:else}
      <button class="btn" onclick={() => session.resetFlash()}>Try again</button>
    {/if}
  </div>
</section>

<style>
  .pct { position: fixed; right: clamp(8px, 3vw, 48px); bottom: 2vh; margin: 0; z-index: 0; pointer-events: none; font-weight: 900; font-stretch: 112%; color: var(--white); font-size: clamp(180px, 26vw, 400px); line-height: 0.8; letter-spacing: -0.04em; font-variant-numeric: tabular-nums; }
  .sheet { position: relative; z-index: 1; }
  .bar { height: 14px; background: #dddbd0; border-radius: 999px; overflow: hidden; margin: 22px 0 14px; }
  .bar i { display: block; height: 100%; background: var(--leaf); border-radius: 999px; transition: width 400ms cubic-bezier(0.2, 0.8, 0.2, 1); }
  .meta { display: flex; justify-content: space-between; font: 400 14px var(--mono); color: var(--ink-soft); font-variant-numeric: tabular-nums; }
  .pieces { display: grid; grid-template-columns: repeat(var(--n), 1fr); gap: 3px; margin-top: 22px; }
  .pieces i { height: 20px; background: #dddbd0; }
  .pieces i.d { background: var(--ink); }
  .pieces i.n { background: var(--leaf); animation: pulse 1.2s ease-in-out infinite; }
  @keyframes pulse { 50% { opacity: 0.45; } }
</style>
