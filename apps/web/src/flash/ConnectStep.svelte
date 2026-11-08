<script lang="ts">
  import { session } from "./session.svelte.ts";

  const ok = $derived(!!session.phone && !session.phoneProblems.length);
  const udev = 'SUBSYSTEM=="usb", ATTR{idVendor}=="18d1", MODE="0660", TAG+="uaccess"';
</script>

<section class="sheet" aria-labelledby="connect-title">
  {#if session.phone}
    <div class="chip" class:bad={!ok}>
      <i class="dot"></i>
      <b>{ok ? "Poco F1 found" : "Phone found"}</b>
      <span>{session.phone.product ?? "unknown"} · {session.phone.kind === "bergamota" ? "Bergamota fastboot" : "ABL fastboot"}{session.phone.unlocked === "yes" ? " · unlocked" : ""}</span>
    </div>
  {/if}

  {#if ok}
    <h2 id="connect-title">Your phone is connected.</h2>
    <p>Nothing has been written. Next, {session.path === "patch" ? "confirm what goes on it" : "choose what to put on it"}.</p>
    <div class="row">
      <button class="btn leaf" onclick={() => session.go(session.path === "patch" ? "Confirm" : "Choose")}>Continue</button>
      <button class="btn ghost" onclick={() => session.connect()}>Use another phone</button>
    </div>
  {:else}
    <h2 id="connect-title">Put your Poco F1 in fastboot and plug it in.</h2>
    <p>Hold <b>Power + Volume down</b> until the fastboot screen appears, or boot Bergamota fastboot from Enxerto. Then let this page find it. Nothing is written yet.</p>
    {#each session.phoneProblems as p}
      <p class="problem">{p}</p>
    {/each}
    {#if session.connectError}
      <p class="problem" role="alert">{session.connectError}</p>
    {/if}
    <div class="row">
      <button class="btn leaf" disabled={session.connecting} onclick={() => session.connect()}>{session.connecting ? "Talking to the phone…" : "Find my phone"}</button>
    </div>
  {/if}

  <div class="note">
    <div>
      <b>Linux</b>
      Chrome needs permission to open the fastboot device. Add this udev rule (for example in <code>/etc/udev/rules.d/51-android.rules</code>), run <code>sudo udevadm control --reload</code>, then replug:
      <pre>{udev}</pre>
    </div>
    <div>
      <b>Windows</b>
      The fastboot device must use the WinUSB driver. If the phone does not show up in the picker, install Google's USB driver, or bind WinUSB to "Android" with Zadig, then replug.
      <b style="margin-top: 14px">macOS, ChromeOS</b>
      No setup. Close <code>fastboot</code>, <code>adb</code> and the Bergamota app first: only one program can hold the phone.
    </div>
  </div>
</section>
