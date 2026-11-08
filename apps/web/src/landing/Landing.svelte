<script lang="ts">
  import { hug } from "../lib/hug.ts";

  const repo = "https://github.com/ry-diffusion/Bergamota";
  const parts = [
    { name: "Renegade", what: "Rewrites every arm64e Mach-O and the whole shared cache for a CPU without pointer authentication, then builds the HFS+ root.", where: "userdata · from your IPSW" },
    { name: "Heartwood", what: "Apple's open-source XNU kernel with our patches for the Snapdragon 845.", where: "xnu-11215" },
    { name: "Enxerto", what: "The graft: started from the boot partition, it shows the splash, boots the kernel and has its own fastboot.", where: "boot" },
    { name: "Qualcomm ABL", what: "The phone's own bootloader, unlocked.", where: "stock" },
  ];
  const status: [string, string, "yes" | "wip" | "no"][] = [
    ["SpringBoard, the home screen and the stock apps", "Boots", "yes"],
    ["All 8 CPU cores, touch, buttons, battery", "Works", "yes"],
    ["USB networking and SSH", "Works", "yes"],
    ["GPU acceleration (Adreno 630)", "In progress", "wip"],
    ["Wi-Fi, cellular, audio, camera, sensors", "Not yet", "no"],
  ];
</script>

<header class="nav">
  <a class="mark" href="/" aria-label="Bergamota home"><img src="/favicon.svg" alt="" width="34" height="34" /> Bergamota</a>
  <nav aria-label="Main">
    <a href="#boot">How it boots</a>
    <a href="#status">Status</a>
    <a href="/flash/">Flash</a>
    <a class="gh" href={repo}>GitHub</a>
  </nav>
</header>

<main>
  <section class="hero" use:hug aria-labelledby="hero-title">
    <p class="giant l" aria-hidden="true">2</p>
    <p class="giant r" aria-hidden="true">6</p>
    <img class="figure" data-subject src="/img/newton.webp" width="900" height="1264" alt="Isaac Newton, after Godfrey Kneller's 1689 portrait, printed as a black-and-white halftone" />
    <div class="pitch">
      <h1 id="hero-title">iOS was not built for this phone.</h1>
      <p>Apple's unmodified iOS userland, booting on a Xiaomi Poco F1. Bring your own IPSW: this page patches it and flashes your phone, all on your computer.</p>
      <a class="btn leaf" href="/flash/">
        Patch your IPSW and flash
        <svg viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="2.4" aria-hidden="true"><path d="M4 10h11M11 5l5 5-5 5" /></svg>
      </a>
      <a class="alt" href="/flash/#image">or flash an image you already built</a>
    </div>
  </section>

  <section id="boot" class="boot" aria-labelledby="boot-title">
    <h2 id="boot-title">Four parts of one tree.</h2>
    <ol class="chain">
      {#each parts as p, i}
        <li style="--i: {i}">
          <b>{p.name}</b>
          <span>{p.what}</span>
          <code>{p.where}</code>
        </li>
      {/each}
    </ol>
  </section>

  <section id="status" class="status" aria-labelledby="status-title">
    <div class="sheet">
      <h2 id="status-title">What works today</h2>
      <table>
        <tbody>
          {#each status as [what, state, kind]}
            <tr class={kind}><td>{what}</td><td>{state}</td></tr>
          {/each}
        </tbody>
      </table>
      <p class="fine">An experimental bring-up, not a daily phone. It replaces Android's user data, and Apple's security model is mostly switched off: keep anything personal off it.</p>
    </div>
    <div class="sheet need">
      <h2>What you need</h2>
      <ul>
        <li>A Poco F1 (<code>beryllium</code>) with an unlocked bootloader</li>
        <li>Chrome or Edge on a desktop computer, any OS</li>
        <li>The IPSW from Apple, downloaded by you</li>
        <li>About 20 GB of free disk space</li>
      </ul>
      <p class="fine">Nothing from Apple or Qualcomm is hosted here. Your IPSW and your images are read on your computer and never uploaded.</p>
      <a class="btn" href="/flash/">Open the flasher</a>
    </div>
  </section>
</main>

<footer>
  <span>Bergamota is open source: <a href={repo}>ry-diffusion/Bergamota</a>.</span>
  <span>Portrait: Isaac Newton, after Godfrey Kneller, 1689 (public domain).</span>
  <span>iOS is a trademark of Apple Inc. This project is not affiliated with Apple or Xiaomi.</span>
</footer>

<style>
  .nav {
    position: absolute; inset: 0 0 auto 0; z-index: 5;
    display: flex; align-items: center; justify-content: space-between;
    padding: 28px clamp(16px, 3.4vw, 48px);
  }
  .mark { display: inline-flex; align-items: center; gap: 12px; font-weight: 900; font-size: 26px; font-stretch: 112%; letter-spacing: -0.02em; text-decoration: none; }
  .mark img { border-radius: 9px; }
  nav { display: flex; gap: clamp(16px, 2.2vw, 32px); font-weight: 650; font-size: 16px; }
  nav a { text-decoration: none; }
  nav a:hover, nav a.gh { text-decoration: underline; }

  .hero {
    position: relative; overflow: hidden;
    height: max(640px, min(100svh, 1000px));
  }
  .giant {
    position: absolute; margin: 0; top: 17%;
    font-weight: 900; font-stretch: 112%; color: var(--white);
    font-size: clamp(300px, 42vw, 640px); line-height: 0.8; letter-spacing: -0.04em;
    user-select: none; opacity: 0; transition: opacity 400ms ease-out;
  }
  .giant.l { left: 6%; }
  .giant.r { left: 62%; }
  :global(.hugged) .giant { opacity: 1; }
  .figure {
    position: absolute; bottom: 0; left: 31%;
    width: min(33vw, 520px); height: auto; max-height: 76%;
    object-fit: contain; object-position: bottom center;
  }
  .pitch { position: absolute; right: clamp(16px, 3.4vw, 48px); bottom: clamp(32px, 5vh, 56px); width: min(390px, 30vw); z-index: 3; }
  h1 { font-size: clamp(34px, 3.2vw, 46px); line-height: 1; letter-spacing: -0.03em; font-weight: 850; margin: 0 0 16px; text-wrap: balance; }
  .pitch p { margin: 0 0 26px; font-size: 18px; max-width: 36ch; }
  .alt { display: block; margin-top: 16px; font-size: 15px; }

  .boot { padding: clamp(64px, 9vw, 120px) clamp(16px, 3.4vw, 56px) 40px; }
  h2 { font-weight: 900; letter-spacing: -0.03em; margin: 0 0 24px; }
  .boot h2 { font-size: clamp(56px, 7vw, 104px); line-height: 0.9; font-stretch: 112%; color: var(--white); max-width: 11ch; margin-bottom: 48px; }
  .chain { list-style: none; margin: 0; padding: 0; display: grid; gap: 14px; }
  .chain li {
    display: grid; grid-template-columns: minmax(150px, 220px) 1fr auto; align-items: baseline; gap: 12px 32px;
    background: var(--paper); padding: 22px 28px; box-shadow: var(--lift);
    margin-right: calc(var(--i) * clamp(0px, 6vw, 80px));
  }
  .chain li:first-child { background: var(--ink); color: var(--paper); }
  .chain li:first-child code { color: var(--ground); }
  .chain b { font-size: 28px; font-weight: 850; letter-spacing: -0.02em; }
  .chain code { color: var(--ink-soft); text-align: right; white-space: nowrap; }

  .status { display: grid; grid-template-columns: 1.2fr 1fr; gap: 18px; padding: 40px clamp(16px, 3.4vw, 56px) clamp(64px, 8vw, 110px); align-items: start; }
  .sheet { background: var(--paper); padding: 30px 32px; box-shadow: var(--lift); }
  .sheet h2 { font-size: 30px; }
  table { width: 100%; border-collapse: collapse; font-size: 16px; }
  td { padding: 10px 0; border-top: 1px solid var(--paper-line); }
  td:last-child { text-align: right; font-weight: 750; white-space: nowrap; padding-left: 16px; }
  tr.wip td:last-child { color: var(--leaf); }
  tr.no td:last-child { color: var(--ink-faint); font-weight: 500; }
  .fine { font-size: 14px; color: var(--ink-soft); margin: 18px 0 0; }
  .need ul { margin: 0; padding-left: 20px; display: grid; gap: 8px; }
  .need .btn { margin-top: 22px; }

  footer { display: flex; flex-wrap: wrap; gap: 8px 28px; padding: 28px clamp(16px, 3.4vw, 56px) 40px; font-size: 13px; color: var(--ink-soft); }

  @media (max-width: 820px) {
    nav a:not(.gh) { display: none; }
    .hero { height: auto; padding-top: 110px; display: grid; }
    .giant { top: 120px; font-size: 62vw; }
    .figure { position: relative; left: auto; bottom: auto; width: 74vw; max-height: none; margin: 0 auto; z-index: 1; }
    .pitch { position: relative; right: auto; bottom: auto; width: auto; padding: 28px 16px 48px; background: var(--ground) var(--halftone); }
    .chain li { grid-template-columns: 1fr; margin-right: 0; }
    .chain code { text-align: left; }
    .status { grid-template-columns: 1fr; }
  }
</style>
