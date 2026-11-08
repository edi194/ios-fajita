<script lang="ts">
  import { session, type Path } from "./session.svelte.ts";
  import { FastbootDevice } from "../lib/fastboot.ts";
  import IpswStep from "./IpswStep.svelte";
  import PatchStep from "./PatchStep.svelte";
  import ConnectStep from "./ConnectStep.svelte";
  import ChooseStep from "./ChooseStep.svelte";
  import ConfirmStep from "./ConfirmStep.svelte";
  import FlashStep from "./FlashStep.svelte";
  import Advanced from "./Advanced.svelte";

  const supported = FastbootDevice.supported() && window.isSecureContext;
  const paths: [Path, string][] = [["patch", "Patch IPSW + flash"], ["image", "Flash an image"]];

  // a step can be opened once the steps before it are done
  function reachable(i: number): boolean {
    if (session.flashState === "flashing") return session.stepName === "Flash" && i === session.step;
    const name = session.steps[i];
    if (session.path === "patch") {
      if (name === "IPSW") return true;
      if (name === "Patch") return !!session.ipsw;
      if (name === "Connect") return session.patchState === "done";
      const ready = session.patchState === "done" && !!session.phone && !session.phoneProblems.length;
      if (name === "Confirm") return ready && !!session.checked && !session.checked.problems.length;
      return ready && session.flashState !== "idle";
    }
    if (name === "Connect") return true;
    const phoneOk = !!session.phone && !session.phoneProblems.length;
    if (name === "Choose") return phoneOk;
    const imageOk = phoneOk && !!session.checked && !session.checked.problems.length;
    if (name === "Confirm") return imageOk;
    return imageOk && session.flashState !== "idle";
  }
</script>

<div class="page" class:adv={session.advanced}>
  <header class="top">
    <a class="mark" href="/"><img src="/favicon.svg" alt="" width="32" height="32" /> Bergamota <span>Flash</span></a>
    <div class="controls">
      <div class="seg paths" role="tablist" aria-label="What to do">
        {#each paths as [p, label]}
          <button role="tab" aria-selected={session.path === p} class:on={session.path === p} disabled={session.flashState === "flashing"} onclick={() => session.setPath(p)}>{label}</button>
        {/each}
      </div>
      <div class="seg mode" role="group" aria-label="Detail">
        <button aria-pressed={!session.advanced} class:on={!session.advanced} onclick={() => (session.advanced = false)}>Simple</button>
        <button aria-pressed={session.advanced} class:on={session.advanced} onclick={() => (session.advanced = true)}>Advanced</button>
      </div>
    </div>
  </header>

  <ol class="steps" aria-label="Steps">
    {#each session.steps as name, i}
      <li class:on={i === session.step} class:done={i < session.step}>
        <button disabled={!reachable(i)} aria-current={i === session.step ? "step" : undefined} onclick={() => (session.step = i)}>
          <i>{i + 1}</i><em>{name}</em>
        </button>
      </li>
    {/each}
  </ol>

  <main class="work">
    {#if !supported}
      <section class="sheet">
        <h2>This browser can't talk to the phone.</h2>
        <p>Flashing uses WebUSB, which Chrome and Edge have on desktop computers (Windows, macOS, Linux, ChromeOS). Firefox, Safari and phone browsers don't. Open this page in Chrome or Edge.</p>
        <p class="muted">You can still read the steps here; nothing will be written.</p>
      </section>
    {:else if session.stepName === "IPSW"}
      <IpswStep />
    {:else if session.stepName === "Patch"}
      <PatchStep />
    {:else if session.stepName === "Connect"}
      <ConnectStep />
    {:else if session.stepName === "Choose"}
      <ChooseStep />
    {:else if session.stepName === "Confirm"}
      <ConfirmStep />
    {:else}
      <FlashStep />
    {/if}
    {#if session.advanced}
      <Advanced />
    {/if}
  </main>
</div>

<style>
  .page { min-height: 100vh; display: grid; grid-template-columns: minmax(220px, 360px) 1fr; grid-template-rows: auto 1fr; column-gap: clamp(16px, 3vw, 48px); padding: 0 clamp(16px, 3.4vw, 48px) 48px; }
  .top { grid-column: 1 / -1; display: flex; align-items: center; justify-content: space-between; gap: 16px; padding: 26px 0 30px; flex-wrap: wrap; }
  .mark { display: inline-flex; align-items: center; gap: 12px; font-weight: 900; font-size: 24px; font-stretch: 112%; letter-spacing: -0.02em; text-decoration: none; }
  .mark img { border-radius: 8px; }
  .mark span { font-weight: 600; font-stretch: 100%; }
  .controls { display: flex; gap: 12px; flex-wrap: wrap; }
  .seg { display: inline-flex; background: var(--paper); border-radius: 999px; padding: 4px; box-shadow: 0 8px 18px -12px rgba(0, 0, 0, 0.4); }
  .seg button { border: 0; background: transparent; padding: 9px 18px; border-radius: 999px; font-weight: 700; font-size: 14px; cursor: pointer; }
  .seg button:disabled { cursor: not-allowed; opacity: 0.5; }
  .paths button.on { background: var(--leaf); color: var(--white); }
  .mode button.on { background: var(--ink); color: var(--white); }

  .steps { list-style: none; margin: 0; padding: 0; display: grid; align-content: start; gap: 2px; }
  .steps button { display: flex; align-items: baseline; gap: 18px; background: none; border: 0; padding: 0; cursor: pointer; text-align: left; font-weight: 900; font-stretch: 112%; color: rgba(255, 255, 255, 0.55); }
  .steps button:disabled { cursor: default; }
  .steps i { font-style: normal; font-size: clamp(72px, 7.6vw, 116px); line-height: 0.86; letter-spacing: -0.04em; width: 0.8em; }
  .steps em { font-style: normal; font-size: 21px; font-stretch: 100%; font-weight: 800; color: rgba(22, 22, 22, 0.35); }
  .steps li.on button { color: var(--white); }
  .steps li.on em { color: var(--ink); }
  .steps li.done button { color: rgba(255, 255, 255, 0.9); }
  .steps li.done em { color: var(--ink); text-decoration: line-through; text-decoration-thickness: 2px; }
  .steps button:not(:disabled):hover em { color: var(--ink); }

  .work { display: grid; gap: 18px; align-content: start; max-width: 760px; }
  .adv .work { max-width: 1280px; grid-template-columns: minmax(0, 1.15fr) minmax(320px, 1fr); align-items: start; }

  @media (max-width: 980px) {
    .page { grid-template-columns: 1fr; }
    .steps { display: flex; flex-wrap: wrap; gap: 4px 18px; margin-bottom: 22px; }
    .steps i { font-size: 46px; }
    .steps em { font-size: 16px; }
    .adv .work { grid-template-columns: 1fr; }
  }
</style>
