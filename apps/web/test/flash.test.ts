import { test } from "node:test";
import assert from "node:assert/strict";
import { FastbootDevice, FastbootError } from "../src/lib/fastboot.ts";
import { checkImage, flash, identify, phoneProblems } from "../src/lib/flasher.ts";
import { bufferSource } from "../src/lib/sparse.ts";
import { applyImage, FakePhone, makeSparse } from "./helpers.ts";

const ABL = { product: "beryllium", unlocked: "yes", "version-bootloader": "unknown", "max-download-size": "0x10000", "partition-size:userdata": "0x400000", "partition-size:boot": "0x4000000" };

test("end to end: a sparse root goes onto userdata through a fake ABL", async () => {
  const phone = new FakePhone(1024 * 4096, ABL);
  const fb = await FastbootDevice.open(phone.usb());
  const info = await identify(fb);
  assert.equal(info.kind, "abl");
  assert.deepEqual(phoneProblems(info), []);
  assert.equal(info.maxDownload, 0x10000);
  const img = makeSparse([{ type: "skip", blocks: 10 }, { type: "raw", blocks: 50 }, { type: "fill", blocks: 300 }, { type: "skip", blocks: 600 }, { type: "raw", blocks: 64 }]);
  const src = bufferSource(img);
  // a 64 MiB minimum applies to real roots; this test image is tiny, so only check the plan and flash
  const checked = await checkImage(src, "test.simg", "userdata", info);
  checked.problems = checked.problems.filter((p) => !/not an iOS root image/.test(p));
  assert.deepEqual(checked.problems, []);
  let last = 0;
  const ok = await flash({ fb, src, partition: "userdata", checked, onProgress: (p) => { assert.ok(p.sentBytes >= last); last = p.sentBytes; } });
  assert.equal(ok, true);
  const expected = new Uint8Array(1024 * 4096).fill(0xaa);
  applyImage(img, expected);
  assert.deepEqual(phone.part, expected);
  assert.ok(phone.downloads.every((n) => n <= 0x10000));
  assert.ok(phone.log.filter((c) => c === "flash:userdata").length >= 2, "flashed in several pieces");
  assert.ok(phone.log.every((c) => /^(getvar:|download:|flash:userdata$)/.test(c)), `only allowed commands: ${phone.log.join(", ")}`);
});

test("refuses partitions and commands outside the allowlist", async () => {
  const phone = new FakePhone(4096, ABL);
  const fb = await FastbootDevice.open(phone.usb());
  for (const p of ["modem", "persist", "bluetooth", "dsp", "xbl", "abl", "userdata_b"]) {
    // @ts-expect-error deliberately not a Partition
    await assert.rejects(fb.flash(p), FastbootError);
  }
  // the private command() refuses everything not allowlisted
  const cmd = (fb as unknown as { command(c: string): Promise<unknown> }).command.bind(fb);
  for (const c of ["erase:userdata", "format:userdata", "oem unlock", "flashing unlock", "set_active:a", "flash:modem", "boot"]) {
    await assert.rejects(cmd(c), /not an allowed command/);
  }
  assert.deepEqual(phone.log, [], "nothing reached the phone");
});

test("a phone that is not a Poco F1, or locked, is refused", async () => {
  const other = await identify(await FastbootDevice.open(new FakePhone(4096, { ...ABL, product: "sagit" }).usb()));
  assert.match(phoneProblems(other)[0], /not a Poco F1/);
  const locked = await identify(await FastbootDevice.open(new FakePhone(4096, { ...ABL, unlocked: "no" }).usb()));
  assert.match(phoneProblems(locked)[0], /locked/);
  const oldBerga = await identify(await FastbootDevice.open(new FakePhone(4096, { ...ABL, "version-bootloader": "bergamota-1" }).usb()));
  assert.equal(oldBerga.kind, "bergamota");
  assert.match(phoneProblems(oldBerga)[0], /too old/);
});

test("image checks: boot needs ANDROID!, sizes, partition fit", async () => {
  const phone = new FakePhone(4096, ABL);
  const info = await identify(await FastbootDevice.open(phone.usb()));
  const notBoot = bufferSource(new Uint8Array(2 << 20));
  assert.ok((await checkImage(notBoot, "x.img", "boot", info)).problems.some((p) => /ANDROID!/.test(p)));
  const bootImg = new Uint8Array(2 << 20);
  bootImg.set(new TextEncoder().encode("ANDROID!"));
  assert.deepEqual((await checkImage(bufferSource(bootImg), "boot.img", "boot", info)).problems, []);
  const tooBig = makeSparse([{ type: "skip", blocks: 2048 }]); // 8 MiB > 4 MiB userdata in this fake
  assert.ok((await checkImage(bufferSource(tooBig), "big.simg", "userdata", info)).problems.some((p) => /holds only/.test(p)));
});

test("stop after the current piece", async () => {
  const phone = new FakePhone(1024 * 4096, ABL);
  const fb = await FastbootDevice.open(phone.usb());
  const info = await identify(fb);
  const img = makeSparse([{ type: "raw", blocks: 100 }]);
  const src = bufferSource(img);
  const checked = await checkImage(src, "t.simg", "userdata", info);
  checked.problems = [];
  let stop = false;
  const ok = await flash({ fb, src, partition: "userdata", checked, onProgress: (p) => { if (p.phase === "writing") stop = true; }, shouldStop: () => stop });
  assert.equal(ok, false);
  assert.equal(phone.log.filter((c) => c === "flash:userdata").length, 1);
});
