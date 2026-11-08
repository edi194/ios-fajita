// The site is static except for one route: /api/fcs-key. An IPSW's disk images are encrypted (AEA) with a key
// that is wrapped for a private key Apple publishes on its CDN (the same file `ipsw fw aea` downloads). Browsers
// cannot fetch it directly (no CORS headers), so this route fetches that one file, and only that file, for the page.
// It carries no user data and nothing from the IPSW; the answer is cached for ten minutes like Apple's own.

interface Env {
  ASSETS: { fetch(req: Request): Promise<Response> };
}

// only Apple's published key locations, and only the key file itself
const KEY_URL = /^https:\/\/(wkms-public\.apple\.com|fcs-keys-pub-prod\.cdn-apple\.com)\/fcs-keys\/[A-Za-z0-9_=+-]{20,80}$/;

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (url.pathname !== "/api/fcs-key") return env.ASSETS.fetch(req);
    if (req.method !== "GET") return new Response("method not allowed", { status: 405 });
    const target = url.searchParams.get("url") ?? "";
    if (!KEY_URL.test(target)) return new Response("not an Apple FCS key URL", { status: 400 });
    const r = await fetch(target, { redirect: "follow", cf: { cacheTtl: 600, cacheEverything: true } });
    if (!r.ok) return new Response(`the key server answered ${r.status}`, { status: 502 });
    const pem = await r.text();
    if (pem.length > 4096 || !pem.startsWith("-----BEGIN PRIVATE KEY-----")) return new Response("unexpected answer from the key server", { status: 502 });
    return new Response(pem, { headers: { "content-type": "application/x-pem-file", "cache-control": "public, max-age=600" } });
  },
};
