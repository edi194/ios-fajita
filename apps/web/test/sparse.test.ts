import { test } from "node:test";
import assert from "node:assert/strict";
import { bufferSource, parseImage, pieceBytes, planPieces, SparseError } from "../src/lib/sparse.ts";
import { applyImage, concat, makeSparse, rng } from "./helpers.ts";

async function collect(gen: AsyncIterable<Uint8Array>): Promise<Uint8Array> {
  const parts: Uint8Array[] = [];
  for await (const b of gen) parts.push(b.slice());
  return concat(parts);
}

/** Splits `img` with `max` and checks that flashing the pieces equals flashing the image. */
async function roundTrip(img: Uint8Array, max: number, partBytes: number, expectedImg = img) {
  const src = bufferSource(img);
  const parsed = await parseImage(src);
  const pieces = planPieces(parsed, max);
  const expected = new Uint8Array(partBytes).fill(0xaa);
  applyImage(expectedImg, expected);
  const got = new Uint8Array(partBytes).fill(0xaa);
  for (const p of pieces) {
    const bytes = await collect(pieceBytes(src, parsed, p, 7000));
    assert.equal(bytes.length, p.bytes, "piece length matches its announced size");
    assert.ok(bytes.length <= max, `piece ${bytes.length} fits in ${max}`);
    applyImage(bytes, got);
  }
  assert.deepEqual(got, expected);
  return pieces;
}

test("small sparse image is sent verbatim", async () => {
  const img = makeSparse([{ type: "raw", blocks: 3 }, { type: "skip", blocks: 5 }, { type: "fill", blocks: 2 }]);
  const pieces = await roundTrip(img, 1 << 20, 10 * 4096);
  assert.equal(pieces.length, 1);
  assert.equal(pieces[0].verbatim, true);
});

test("big sparse image is split, DONT_CARE regions stay untouched", async () => {
  const img = makeSparse([
    { type: "skip", blocks: 7 },
    { type: "raw", blocks: 40 },
    { type: "fill", blocks: 100 },
    { type: "crc", blocks: 0 },
    { type: "skip", blocks: 30 },
    { type: "raw", blocks: 9 },
    { type: "raw", blocks: 1 },
    { type: "fill", blocks: 3 },
    { type: "skip", blocks: 2 },
  ]);
  const pieces = await roundTrip(img, 64 * 1024, 192 * 4096);
  assert.ok(pieces.length > 3, `split into ${pieces.length} pieces`);
  assert.ok(pieces.every((p) => !p.verbatim));
});

test("random images survive any piece size", async () => {
  const r = rng(42);
  for (let round = 0; round < 25; round++) {
    const specs = Array.from({ length: 1 + ((r() * 20) | 0) }, () => {
      const t = r();
      return { type: (t < 0.45 ? "raw" : t < 0.7 ? "fill" : t < 0.95 ? "skip" : "crc") as "raw" | "fill" | "skip" | "crc", blocks: 1 + ((r() * 12) | 0) };
    });
    const img = makeSparse(specs, 4096, round + 1);
    const blocks = specs.filter((s) => s.type !== "crc").reduce((n, s) => n + s.blocks, 0);
    const max = 28 + 36 + 4096 + ((r() * 40000) | 0);
    await roundTrip(img, max, blocks * 4096);
  }
});

test("raw image larger than the download size becomes sparse pieces, short last block padded", async () => {
  const r = rng(7);
  const raw = new Uint8Array(20 * 4096 + 123).map(() => (r() * 256) | 0);
  const parsed = await parseImage(bufferSource(raw));
  assert.equal(parsed.sparse, false);
  assert.equal(parsed.tailPad, 4096 - 123);
  const padded = new Uint8Array(21 * 4096);
  padded.set(raw);
  const pieces = await roundTrip(raw, 5 * 4096, 21 * 4096, padded);
  assert.ok(pieces.length >= 4);
});

test("small raw image (boot.img) is sent verbatim even when not block aligned", async () => {
  const raw = new Uint8Array(3 * 4096 + 5).fill(9);
  const pieces = planPieces(await parseImage(bufferSource(raw)), 1 << 20);
  assert.equal(pieces.length, 1);
  assert.equal(pieces[0].verbatim, true);
  assert.equal(pieces[0].bytes, raw.length);
});

test("corrupt sparse images are rejected before anything is sent", async () => {
  const img = makeSparse([{ type: "raw", blocks: 2 }, { type: "fill", blocks: 2 }]);
  const truncated = img.subarray(0, img.length - 100);
  await assert.rejects(parseImage(bufferSource(truncated)), SparseError);
  const bad = img.slice();
  new DataView(bad.buffer).setUint32(16, 99, true); // header claims more blocks
  await assert.rejects(parseImage(bufferSource(bad)), SparseError);
  const badType = img.slice();
  new DataView(badType.buffer).setUint16(28, 0xbeef, true);
  await assert.rejects(parseImage(bufferSource(badType)), /unknown chunk type/);
});
