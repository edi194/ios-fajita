// The Renegade root builder (tools/renegade-wasm) as a typed object. The module is synchronous: it reads the IPSW
// and writes the image through the callbacks below, which the worker backs with FileReaderSync and an OPFS file
// (and the tests with buffers).

export interface HostIO {
  /** Source 0 is the IPSW, source 1 an optional tools bundle. */
  size(handle: number): number;
  read(handle: number, offset: number, length: number): Uint8Array;
  write(offset: number, data: Uint8Array): void;
  event(kind: "stage" | "log" | "bytes", text: string, done: number, total: number): void;
}

export interface IpswInfo {
  device: string;
  version: string;
  build: string;
  images: { name: string; path: string; encrypted: boolean; keyUrl: string | null }[];
}

export interface BuildConfig {
  /** Private keys (PEM) by the key URL the encrypted images name. */
  pems?: Record<string, string>;
  /** Unix seconds for dates of new files. */
  now?: number;
  macho?: boolean;
  cache?: boolean;
  tweaks?: boolean;
  verify?: boolean;
  /** The tools bundle (berga-tools.zip) is source 1: SSH, first-boot job, ... */
  tools?: boolean;
  /** The public key SSH logs in with (one line). */
  sshKey?: string;
}

export interface BuildSummary {
  imageBytes: number;
  entries: number;
  machos: number;
  signed: number;
  chunks: number;
}

interface Exports {
  memory: WebAssembly.Memory;
  rr_alloc(n: number): number;
  rr_free(p: number, n: number): void;
  rr_result_ptr(): number;
  rr_result_len(): number;
  rr_open_ipsw(): number;
  rr_build(p: number, n: number): number;
}

export class PatcherError extends Error {}

export class Renegade {
  private x: Exports;
  private constructor(x: Exports) {
    this.x = x;
  }

  static async load(module: WebAssembly.Module | BufferSource, io: HostIO): Promise<Renegade> {
    let mem: WebAssembly.Memory;
    const dec = new TextDecoder();
    const view = (p: number, n: number) => new Uint8Array(mem.buffer, p, n);
    const imports = {
      host: {
        size: (h: number) => io.size(h),
        read: (h: number, off: number, ptr: number, len: number) => {
          try {
            const d = io.read(h, off, len);
            if (d.length !== len) return 2;
            view(ptr, len).set(d);
            return 0;
          } catch {
            return 1;
          }
        },
        write: (off: number, ptr: number, len: number) => {
          try {
            io.write(off, view(ptr, len));
            return 0;
          } catch {
            return 1;
          }
        },
        event: (kind: number, ptr: number, len: number, a: number, b: number) => {
          io.event(kind === 0 ? "stage" : kind === 1 ? "log" : "bytes", dec.decode(view(ptr, len)), a, b);
        },
      },
    };
    const inst = module instanceof WebAssembly.Module ? await WebAssembly.instantiate(module, imports) : (await WebAssembly.instantiate(module, imports)).instance;
    const x = inst.exports as unknown as Exports;
    mem = x.memory;
    return new Renegade(x);
  }

  private result(): string {
    const { rr_result_ptr, rr_result_len, memory } = this.x;
    return new TextDecoder().decode(new Uint8Array(memory.buffer, rr_result_ptr(), rr_result_len()).slice());
  }

  openIpsw(): IpswInfo {
    if (this.x.rr_open_ipsw() !== 0) throw new PatcherError(this.result());
    return JSON.parse(this.result());
  }

  build(cfg: BuildConfig): BuildSummary {
    const flat: Record<string, unknown> = { now: cfg.now ?? Math.floor(Date.now() / 1000), macho: cfg.macho ?? true, cache: cfg.cache ?? true, tweaks: cfg.tweaks ?? true, verify: cfg.verify ?? false, tools: cfg.tools ?? false, ssh_key: cfg.sshKey ?? "" };
    for (const [url, pem] of Object.entries(cfg.pems ?? {})) flat[`pem:${url}`] = pem;
    const bytes = new TextEncoder().encode(JSON.stringify(flat));
    const p = this.x.rr_alloc(bytes.length);
    new Uint8Array(this.x.memory.buffer, p, bytes.length).set(bytes);
    const rc = this.x.rr_build(p, bytes.length);
    this.x.rr_free(p, bytes.length);
    if (rc !== 0) throw new PatcherError(this.result());
    return JSON.parse(this.result());
  }
}
