// Test helpers: a sparse image generator, an independent expander (simg2img semantics, DONT_CARE = untouched),
// and a fake fastboot phone that implements enough of WebUSB for FastbootDevice.

export function rng(seed: number) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32);
}

type Spec = { type: "raw" | "fill" | "skip" | "crc"; blocks: number };

/** Builds a sparse image from a chunk list; RAW data is pseudo-random. */
export function makeSparse(specs: Spec[], bs = 4096, seed = 1): Uint8Array {
  const r = rng(seed);
  const parts: Uint8Array[] = [];
  let blocks = 0;
  for (const s of specs) {
    const h = new Uint8Array(12);
    const v = new DataView(h.buffer);
    const type = { raw: 0xcac1, fill: 0xcac2, skip: 0xcac3, crc: 0xcac4 }[s.type];
    const data = s.type === "raw" ? new Uint8Array(s.blocks * bs).map(() => (r() * 256) | 0) : s.type === "fill" || s.type === "crc" ? new Uint8Array([1, 2, 3, (r() * 256) | 0]) : new Uint8Array(0);
    v.setUint16(0, type, true);
    v.setUint32(4, s.type === "crc" ? 0 : s.blocks, true);
    v.setUint32(8, 12 + data.length, true);
    parts.push(h, data);
    if (s.type !== "crc") blocks += s.blocks;
  }
  const fh = new Uint8Array(28);
  const v = new DataView(fh.buffer);
  v.setUint32(0, 0xed26ff3a, true);
  v.setUint16(4, 1, true);
  v.setUint16(8, 28, true);
  v.setUint16(10, 12, true);
  v.setUint32(12, bs, true);
  v.setUint32(16, blocks, true);
  v.setUint32(20, specs.length, true);
  return concat([fh, ...parts]);
}

export function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let o = 0;
  for (const p of parts) {
    out.set(p, o);
    o += p.length;
  }
  return out;
}

/** Applies an image (sparse or raw) onto `part`, like a fastboot flash. */
export function applyImage(img: Uint8Array, part: Uint8Array): void {
  const dv = new DataView(img.buffer, img.byteOffset, img.length);
  if (img.length < 28 || dv.getUint32(0, true) !== 0xed26ff3a) {
    part.set(img, 0);
    return;
  }
  const fileHdr = dv.getUint16(8, true);
  const chunkHdr = dv.getUint16(10, true);
  const bs = dv.getUint32(12, true);
  const total = dv.getUint32(16, true);
  const chunks = dv.getUint32(20, true);
  if (total * bs > part.length) throw new Error("image larger than partition");
  let off = fileHdr;
  let blk = 0;
  for (let i = 0; i < chunks; i++) {
    const type = dv.getUint16(off, true);
    const n = dv.getUint32(off + 4, true);
    const size = dv.getUint32(off + 8, true);
    const d = off + chunkHdr;
    if (type === 0xcac1) part.set(img.subarray(d, d + n * bs), blk * bs);
    else if (type === 0xcac2) for (let b = 0; b < n * bs; b += 4) part.set(img.subarray(d, d + 4), blk * bs + b);
    blk += n;
    off += size;
  }
  if (blk !== total) throw new Error(`piece covers ${blk} blocks, header says ${total}`);
}

/** A fake fastboot phone behind a WebUSB-shaped object. */
export class FakePhone {
  part: Uint8Array;
  vars: Record<string, string>;
  log: string[] = [];
  downloads: number[] = [];
  private queue: string[] = [];
  private waiters: ((s: string) => void)[] = [];
  private expect = 0;
  private buf: Uint8Array[] = [];
  private staged: Uint8Array | null = null;
  opened = false;

  constructor(partBytes: number, vars: Record<string, string>) {
    this.part = new Uint8Array(partBytes).fill(0xaa);
    this.vars = vars;
  }

  private reply(s: string) {
    const w = this.waiters.shift();
    if (w) w(s);
    else this.queue.push(s);
  }

  usb(): USBDevice {
    const alt = { alternateSetting: 0, interfaceClass: 0xff, interfaceSubclass: 0x42, interfaceProtocol: 0x03, interfaceName: null,
      endpoints: [{ endpointNumber: 1, direction: "in", type: "bulk", packetSize: 512 }, { endpointNumber: 1, direction: "out", type: "bulk", packetSize: 512 }] };
    const iface = { interfaceNumber: 0, alternate: alt, alternates: [alt], claimed: false };
    const cfg = { configurationValue: 1, configurationName: null, interfaces: [iface] };
    const self = this;
    return {
      get opened() { return self.opened; },
      vendorId: 0x18d1,
      productId: 0xd00d,
      productName: "Android",
      configuration: cfg,
      configurations: [cfg],
      open: async () => { self.opened = true; },
      close: async () => { self.opened = false; },
      selectConfiguration: async () => {},
      claimInterface: async () => {},
      releaseInterface: async () => {},
      selectAlternateInterface: async () => {},
      transferOut: async (_ep: number, data: BufferSource) => {
        const bytes = new Uint8Array(data instanceof ArrayBuffer ? data : (data as ArrayBufferView).buffer.slice((data as ArrayBufferView).byteOffset, (data as ArrayBufferView).byteOffset + (data as ArrayBufferView).byteLength));
        if (self.expect > 0) {
          self.buf.push(bytes);
          self.expect -= bytes.length;
          if (self.expect < 0) throw new Error("device got more data than announced");
          if (self.expect === 0) {
            self.staged = concat(self.buf);
            self.buf = [];
            self.reply("OKAY");
          }
          return { status: "ok", bytesWritten: bytes.length };
        }
        const cmd = new TextDecoder().decode(bytes);
        self.log.push(cmd);
        self.command(cmd);
        return { status: "ok", bytesWritten: bytes.length };
      },
      transferIn: async () => {
        const s = self.queue.length ? self.queue.shift()! : await new Promise<string>((r) => self.waiters.push(r));
        const enc = new TextEncoder().encode(s);
        return { status: "ok", data: new DataView(enc.buffer) };
      },
    } as unknown as USBDevice;
  }

  private command(cmd: string) {
    let m: RegExpExecArray | null;
    if ((m = /^getvar:(.+)$/.exec(cmd))) {
      const v = this.vars[m[1]];
      this.reply(v === undefined ? "FAILunknown variable" : `OKAY${v}`);
    } else if ((m = /^download:([0-9a-f]{8})$/.exec(cmd))) {
      const n = parseInt(m[1], 16);
      const max = parseInt(this.vars["max-download-size"] ?? "0x20000000", 16);
      if (n > max) return this.reply("FAILdata too large");
      this.expect = n;
      this.downloads.push(n);
      this.reply(`DATA${m[1]}`);
    } else if ((m = /^flash:(.+)$/.exec(cmd))) {
      if (!this.staged) return this.reply("FAILno data");
      this.reply("INFOwriting");
      applyImage(this.staged, this.part);
      this.staged = null;
      this.reply("OKAY");
    } else if (cmd === "reboot") this.reply("OKAY");
    else this.reply("FAILunknown command");
  }
}
