<script lang="ts">
  import { session } from "./session.svelte.ts";
  import FilePick from "./FilePick.svelte";
  import { PROFILES, profileForIpsw } from "../lib/profiles.ts";
  import { fmtBytes } from "../lib/flasher.ts";

  const found = $derived(session.ipsw ? profileForIpsw(session.ipsw.name) : null);
</script>

<section class="sheet" aria-labelledby="ipsw-title">
  <h2 id="ipsw-title">Start with Apple's IPSW for the iPhone.</h2>
  <p>Bergamota runs the iOS userland of a real iPhone. Download the IPSW from Apple yourself and drop it here: it is read on this computer and never uploaded.</p>

  <FilePick accept=".ipsw" label="IPSW file" has={!!session.ipsw} onfile={(f) => (session.ipsw = f)}>
    {#snippet children()}
      {#if session.ipsw}
        <b>{session.ipsw.name}</b>
        <small>
          {fmtBytes(session.ipsw.size)}
          {#if found?.profile} · iOS {found.profile.version} ({found.profile.build}) · {found.profile.model} · profile {found.profile.id}{/if}
        </small>
      {/if}
    {/snippet}
  </FilePick>

  {#if session.ipsw && !found?.profile}
    <p class="problem">
      {#if found?.device}This is iOS {found.version} ({found.build}) for {found.device}, which Renegade has no profile for.{:else}This does not look like an Apple restore IPSW (<code>Device_Version_Build_Restore.ipsw</code>).{/if}
      Supported: {#each PROFILES as p, i}{i ? " or " : ""}<b>{p.device}_{p.version}_{p.build}_Restore.ipsw</b>{/each}.
    </p>
  {/if}

  <p class="muted" style="margin-top: 20px">Patching needs about 20 GB of free disk space for this browser. The finished root image stays in the browser's private storage until you flash it.</p>
  <div class="row">
    <button class="btn leaf" disabled={!found?.profile} onclick={() => session.go("Patch")}>Patch it</button>
  </div>
</section>
