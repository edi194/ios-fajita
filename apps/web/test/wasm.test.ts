// The Renegade WebAssembly module end to end in Node: a synthetic IPSW (made by tools/renegade-rs/tests/rootbuild.rs
// with RENEGADE_KEEP_SYNTH_IPSW=path; our own content only) goes in, a sparse HFSX root comes out. Skipped unless
// RENEGADE_TEST_IPSW points at that file and src/patcher/renegade.wasm is built (npm run build:wasm).
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, openSync, readSync, fstatSync } from "node:fs";
import { Renegade, type HostIO } from "../src/patcher/wasm.ts";
import { parseImage, bufferSource, SPARSE_MAGIC } from "../src/lib/sparse.ts";

const ipswPath = process.env.RENEGADE_TEST_IPSW;
const wasmPath = new URL("../src/patcher/renegade.wasm", import.meta.url);
const skip = !ipswPath || !existsSync(ipswPath) || !existsSync(wasmPath);

test("the wasm patcher turns a synthetic IPSW into a sparse root", { skip }, async () => {
  const fd = openSync(ipswPath!, "r");
  const size = fstatSync(fd).size;
  let out = new Uint8Array(1 << 20);
  let outLen = 0;
  const events: string[] = [];
  let bytes = 0;
  const io: HostIO = {
    size: () => size,
    read: (_h, off, len) => {
      const b = new Uint8Array(len);
      assert.equal(readSync(fd, b, 0, len, off), len);
      return b;
    },
    write: (off, data) => {
      const end = off + data.length;
      if (end > out.length) {
        const n = new Uint8Array(Math.max(end, out.length * 2));
        n.set(out.subarray(0, outLen));
        out = n;
      }
      out.set(data, off);
      outLen = Math.max(outLen, end);
    },
    event: (kind, text, done) => {
      if (kind === "stage") events.push(text);
      if (kind === "bytes") bytes = Math.max(bytes, done);
    },
  };
  const rn = await Renegade.load(readFileSync(wasmPath), io);
  const info = rn.openIpsw();
  assert.equal(info.device, "iPhone11,8");
  assert.equal(info.build, "22H352");
  assert.deepEqual(info.images.map((i) => i.name), ["appos", "sysos", "os"]);
  assert.ok(info.images.every((i) => !i.encrypted));
  const summary = rn.build({ now: 1_700_000_000 });
  assert.ok(summary.signed >= 1 && summary.entries > 20, JSON.stringify(summary));
  assert.deepEqual(events, ["open", "copy", "scan", "tweaks", "macho", "cache", "seal"]);
  // the image is a valid Android sparse image the flasher can plan
  const img = out.subarray(0, outLen);
  assert.equal(new DataView(img.buffer, img.byteOffset).getUint32(0, true), SPARSE_MAGIC);
  const parsed = await parseImage(bufferSource(img));
  assert.ok(parsed.sparse);
  assert.equal(parsed.expandedBytes, summary.imageBytes);
  assert.ok(bytes > 0);
});

test("a file that is not an IPSW is refused with a message", { skip: !existsSync(wasmPath) }, async () => {
  const junk = new Uint8Array(4096).fill(7);
  const io: HostIO = { size: () => junk.length, read: (_h, o, n) => junk.subarray(o, o + n), write: () => {}, event: () => {} };
  const rn = await Renegade.load(readFileSync(wasmPath), io);
  assert.throws(() => rn.openIpsw(), /zip/i);
});
