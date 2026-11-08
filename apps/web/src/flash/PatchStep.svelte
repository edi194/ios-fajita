<script lang="ts">
  import { session, PATCH_STAGES } from "./session.svelte.ts";
  import { patcherSupported, NEEDED_BYTES, sshKeyProblem } from "../patcher/patcher.ts";
  import { fmtBytes, fmtDuration } from "../lib/flasher.ts";

  const supported = patcherSupported();
  let now = $state(performance.now());
  $effect(() => {
    if (session.patchState !== "running") return;
    const t = setInterval(() => (now = performance.now()), 500);
    return () => clearInterval(t);
  });
  const at = $derived(PATCH_STAGES.findIndex(([k]) => k === session.patchStage));
  const elapsed = $derived((now - session.patchStartedAt) / 1000);
  const keyProblem = $derived(sshKeyProblem(session.sshKey));
  const frac = $derived(session.patchBytes.total ? session.patchBytes.done / session.patchBytes.total : 0);
</script>

<section class="sheet" aria-labelledby="patch-title">
  {#if !supported}
    <h2 id="patch-title">This browser can't patch here.</h2>
    <p>Patching needs a Web Worker with the browser's private file storage (OPFS), as Chrome and Edge have. Open this page in one of those, or build the root with Renegade on a computer and flash it with <b>Flash an image</b>.</p>
    <div class="row"><button class="btn leaf" onclick={() => session.setPath("image")}>Flash an image I built</button></div>
  {:else if session.patchState === "idle"}
    <h2 id="patch-title">Patch the IPSW in this page.</h2>
    <p>The IPSW is read from your disk, decrypted, rewritten for the Poco F1's processor and written as a root image into this browser's private storage (about {Math.round(NEEDED_BYTES / 2 ** 30)} GB). Nothing leaves your computer; the only request is for the decryption key Apple publishes.</p>
    <ol class="stages">
      {#each PATCH_STAGES as [, text]}<li>{text}</li>{/each}
    </ol>
    <label class="key">
      <span><b>Your SSH public key</b> (optional, recommended)</span>
      <input bind:value={session.sshKey} placeholder="ssh-ed25519 AAAA… you@computer" autocomplete="off" spellcheck="false" aria-invalid={!!keyProblem} />
      <small class:problem={!!keyProblem}>{keyProblem ?? "The phone runs an SSH server (over the USB cable) that only this key can open. Without a key there is no SSH. Paste the contents of ~/.ssh/id_ed25519.pub, never the private key."}</small>
    </label>
    <p class="muted">It takes a while: tens of minutes on a laptop. Keep this tab open and the computer awake.</p>
    <div class="row">
      <button class="btn leaf" disabled={!!keyProblem} onclick={() => session.startPatch()}>Start patching</button>
      <button class="btn ghost" onclick={() => session.setPath("image")}>Flash an image I built</button>
    </div>
  {:else if session.patchState === "running"}
    <h2 id="patch-title">Patching…</h2>
    <ol class="stages live">
      {#each PATCH_STAGES as [, text], i}
        <li class:done={i < at} class:now={i === at}>{text}{#if i === at && session.patchStage === "seal" && frac > 0} <b>{Math.floor(frac * 100)}%</b>{/if}</li>
      {/each}
    </ol>
    <div class="bar" role="progressbar" aria-label="Patch progress" aria-valuenow={Math.floor((at + frac) * 100 / PATCH_STAGES.length)} aria-valuemin={0} aria-valuemax={100}>
      <i style="width: {Math.min(100, ((Math.max(at, 0) + (session.patchStage === 'seal' ? frac : 0)) / PATCH_STAGES.length) * 100)}%"></i>
    </div>
    <p class="muted note" aria-live="off">{session.patchNote}</p>
    <div class="meta"><span>{session.patchBytes.total ? `${fmtBytes(session.patchBytes.done)} of ${fmtBytes(session.patchBytes.total)}` : "working"}</span><span>{fmtDuration(elapsed)}</span></div>
    <div class="row"><button class="btn ghost" onclick={() => session.cancelPatch()}>Cancel</button></div>
  {:else if session.patchState === "done"}
    <h2 id="patch-title">The root is ready.</h2>
    <p>
      {session.patchInfo ? `iOS ${session.patchInfo.version} (${session.patchInfo.build}) for ${session.patchInfo.device}` : "The root"} is in this browser as <code>{session.picked?.name}</code>{#if session.picked} ({fmtBytes(session.picked.size)}){/if}. Next, connect the phone.
    </p>
    <div class="row"><button class="btn leaf" onclick={() => session.go("Connect")}>Connect the phone</button></div>
  {:else}
    <h2 id="patch-title">Patching stopped.</h2>
    <p class="problem" role="alert">{session.patchError}</p>
    <div class="row">
      <button class="btn leaf" onclick={() => session.startPatch()}>Try again</button>
      <button class="btn ghost" onclick={() => session.go("IPSW")}>Choose another IPSW</button>
    </div>
  {/if}
</section>

<style>
  .key { display: grid; gap: 6px; margin: 4px 0 18px; font-size: 15px; }
  .key input { font: 500 14px var(--mono); padding: 12px 14px; border: 2px solid var(--ink); border-radius: 4px; background: var(--white); min-width: 0; }
  .key input[aria-invalid="true"] { border-color: #b3261e; }
  .key small { color: var(--ink-soft); }
  .key small.problem { color: #6b1d0c; }
  .stages { margin: 6px 0 18px; padding-left: 22px; display: grid; gap: 4px; color: var(--ink-soft); }
  .live li.done { color: var(--ink); text-decoration: line-through; text-decoration-thickness: 2px; }
  .live li.now { color: var(--ink); font-weight: 800; }
  .bar { height: 14px; background: #dddbd0; border-radius: 999px; overflow: hidden; margin: 22px 0 14px; }
  .bar i { display: block; height: 100%; background: var(--leaf); border-radius: 999px; transition: width 400ms cubic-bezier(0.2, 0.8, 0.2, 1); }
  .note { margin: 0 0 10px; font: 400 13px var(--mono); overflow-wrap: anywhere; }
  .meta { display: flex; justify-content: space-between; font: 400 14px var(--mono); color: var(--ink-soft); font-variant-numeric: tabular-nums; }
</style>
