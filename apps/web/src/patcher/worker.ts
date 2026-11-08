// The patcher's Web Worker: runs the Renegade WebAssembly module over the IPSW the user picked and writes the
// finished sparse image into an OPFS file (this browser's private storage). Both the IPSW reads
// (FileReaderSync) and the image writes (a sync access handle) are synchronous, which is what lets the
// module stay a plain synchronous program.

import wasmUrl from "./renegade.wasm?url";
import { Renegade, PatcherError, type BuildConfig, type HostIO } from "./wasm.ts";

export const IMAGE_FILE = "bergamota-userdata.simg";

export type ToWorker = { type: "open"; ipsw: File } | { type: "build"; config: BuildConfig; tools?: File } | { type: "cancel" };
export type FromWorker =
  | { type: "info"; info: unknown }
  | { type: "event"; kind: "stage" | "log" | "bytes"; text: string; done: number; total: number }
  | { type: "done"; summary: unknown }
  | { type: "error"; message: string };

const post = (m: FromWorker) => (self as unknown as Worker).postMessage(m);

let ipsw: File | null = null;
let tools: File | null = null;
let out: FileSystemSyncAccessHandle | null = null;
let rn: Renegade | null = null;
const reader = new FileReaderSync();

const io: HostIO = {
  size: (h) => (h === 0 ? ipsw!.size : tools?.size ?? 0),
  read: (h, off, len) => {
    const f = h === 0 ? ipsw! : tools!;
    return new Uint8Array(reader.readAsArrayBuffer(f.slice(off, off + len)));
  },
  write: (off, data) => {
    let done = 0;
    while (done < data.length) {
      const n = out!.write(data.subarray(done), { at: off + done });
      if (n <= 0) throw new Error("short write");
      done += n;
    }
  },
  event: (kind, text, done, total) => post({ type: "event", kind, text, done, total }),
};

async function load(): Promise<Renegade> {
  const res = await fetch(wasmUrl);
  const mod = await WebAssembly.compileStreaming(res);
  return Renegade.load(mod, io);
}

self.onmessage = async (e: MessageEvent<ToWorker>) => {
  const m = e.data;
  try {
    if (m.type === "open") {
      ipsw = m.ipsw;
      rn = await load();
      post({ type: "info", info: rn.openIpsw() });
    } else if (m.type === "build") {
      if (!rn) throw new PatcherError("open the IPSW first");
      tools = m.tools ?? null;
      const root = await navigator.storage.getDirectory();
      const fh = await root.getFileHandle(IMAGE_FILE, { create: true });
      out = await fh.createSyncAccessHandle();
      out.truncate(0);
      try {
        const summary = rn.build(m.config);
        out.flush();
        post({ type: "done", summary });
      } finally {
        out.close();
        out = null;
      }
    }
  } catch (err) {
    post({ type: "error", message: (err as Error).message || String(err) });
  }
};
