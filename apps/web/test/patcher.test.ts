import { test } from "node:test";
import assert from "node:assert/strict";
import { sshKeyProblem } from "../src/patcher/patcher.ts";
import worker from "../worker/index.ts";

test("SSH public key check", () => {
  assert.equal(sshKeyProblem(""), null, "no key is allowed (no SSH)");
  assert.equal(sshKeyProblem("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIabc me@laptop"), null);
  assert.equal(sshKeyProblem("ecdsa-sha2-nistp256 AAAAE2VjZHNh= x"), null);
  assert.match(sshKeyProblem("-----BEGIN OPENSSH PRIVATE KEY-----")!, /private key/);
  assert.match(sshKeyProblem("hello world")!, /not an SSH public key/);
  assert.match(sshKeyProblem("ssh-ed25519 AAAA a\nssh-ed25519 AAAA b")!, /one line/);
});

const env = { ASSETS: { fetch: async () => new Response("asset") } };
const key = "https://wkms-public.apple.com/fcs-keys/-XvgMdyfJKIBToo18Q5JqEGDry3aIY8riMBBqYpE9as=";

test("/api/fcs-key only fetches Apple's key files", async () => {
  const asked: string[] = [];
  const real = globalThis.fetch;
  globalThis.fetch = (async (u: string) => {
    asked.push(String(u));
    return new Response("-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n");
  }) as typeof fetch;
  try {
    const ok = await worker.fetch(new Request(`https://x.test/api/fcs-key?url=${encodeURIComponent(key)}`), env);
    assert.equal(ok.status, 200);
    assert.match(await ok.text(), /BEGIN PRIVATE KEY/);
    assert.deepEqual(asked, [key]);
    for (const bad of ["https://evil.test/fcs-keys/abcdefghijklmnopqrstuvwx", "http://wkms-public.apple.com/fcs-keys/abcdefghijklmnopqrstuvwx", "https://wkms-public.apple.com/other/abcdefghijklmnopqrstuvwx", "https://wkms-public.apple.com/fcs-keys/../x", ""]) {
      const r = await worker.fetch(new Request(`https://x.test/api/fcs-key?url=${encodeURIComponent(bad)}`), env);
      assert.equal(r.status, 400, bad);
    }
    assert.equal(asked.length, 1, "nothing else was fetched");
    assert.equal((await worker.fetch(new Request("https://x.test/api/fcs-key", { method: "POST" }), env)).status, 405);
    assert.equal(await (await worker.fetch(new Request("https://x.test/flash/"), env)).text(), "asset", "everything else is the static site");
  } finally {
    globalThis.fetch = real;
  }
});
