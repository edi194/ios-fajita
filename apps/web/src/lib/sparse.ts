// Android sparse images, streamed: parse the chunk table of a (possibly 18 GB) image without reading its data,
// split it into pieces that each fit the device's download buffer, and produce each piece's bytes on the fly.
//
// Format (libsparse): 28-byte file header, then chunks with a 12-byte header each.
//   RAW (0xCAC1): blocks * blk_sz bytes of data follow; FILL (0xCAC2): one u32 repeated;
//   DONT_CARE (0xCAC3): nothing is written there; CRC32 (0xCAC4): a checksum, ignored (and dropped).
// A piece is itself a complete sparse image covering the whole partition: a leading DONT_CARE up to its first
// block, its chunks, and a trailing DONT_CARE to the end. That is what the fastboot client (libsparse resparse)
// sends for images bigger than max-download-size, and what both Qualcomm ABL and Bergamota fastboot accept.

export const SPARSE_MAGIC = 0xed26ff3a;
export const CHUNK_RAW = 0xcac1;
export const CHUNK_FILL = 0xcac2;
export const CHUNK_SKIP = 0xcac3;
export const CHUNK_CRC = 0xcac4;
const FILE_HDR = 28;
const CHUNK_HDR = 12;

/** Random access to the image: a File, an OPFS file, or a buffer in tests. */
export interface ByteSource {
  readonly size: number;
  read(offset: number, length: number): Promise<Uint8Array>;
}

export function blobSource(blob: Blob): ByteSource {
  return {
    size: blob.size,
    async read(offset, length) {
      return new Uint8Array(await blob.slice(offset, offset + length).arrayBuffer());
    },
  };
}

export function bufferSource(buf: Uint8Array): ByteSource {
  return { size: buf.length, read: async (o, n) => buf.subarray(o, Math.min(o + n, buf.length)) };
}

/** A run of blocks. `offset` (raw) is where its data starts in the source; `value` (fill) is the u32 pattern. */
export type Segment =
  | { kind: "raw"; block: number; blocks: number; offset: number }
  | { kind: "fill"; block: number; blocks: number; value: number };

export interface Image {
  /** true for an Android sparse image, false for a raw image. */
  sparse: boolean;
  blockSize: number;
  totalBlocks: number;
  /** Size once expanded (what lands on the partition). */
  expandedBytes: number;
  sourceBytes: number;
  /** Written runs in block order (DONT_CARE and CRC chunks are gaps here). */
  segments: Segment[];
  /** Raw image only: the source's last block is short by this many bytes and gets zero padding. */
  tailPad: number;
}

export class SparseError extends Error {}

/** Buffered sequential reader for the chunk table (headers are tiny, data is skipped). */
class Window {
  private buf: Uint8Array = new Uint8Array(0);
  private start = 0;
  private src: ByteSource;
  private span: number;
  constructor(src: ByteSource, span = 1 << 20) {
    this.src = src;
    this.span = span;
  }
  async view(offset: number, length: number): Promise<DataView> {
    if (offset < this.start || offset + length > this.start + this.buf.length) {
      this.start = offset;
      this.buf = await this.src.read(offset, Math.max(length, this.span));
      if (this.buf.length < length) throw new SparseError(`image is truncated at byte ${offset}`);
    }
    return new DataView(this.buf.buffer, this.buf.byteOffset + (offset - this.start), length);
  }
}

export async function isSparse(src: ByteSource): Promise<boolean> {
  if (src.size < FILE_HDR) return false;
  const h = await src.read(0, 4);
  return new DataView(h.buffer, h.byteOffset, 4).getUint32(0, true) === SPARSE_MAGIC;
}

/** Reads the chunk table (never the data) and validates it completely. */
export async function parseImage(src: ByteSource, rawBlockSize = 4096): Promise<Image> {
  if (!(await isSparse(src))) {
    const totalBlocks = Math.ceil(src.size / rawBlockSize);
    return {
      sparse: false,
      blockSize: rawBlockSize,
      totalBlocks,
      expandedBytes: totalBlocks * rawBlockSize,
      sourceBytes: src.size,
      segments: totalBlocks ? [{ kind: "raw", block: 0, blocks: totalBlocks, offset: 0 }] : [],
      tailPad: totalBlocks * rawBlockSize - src.size,
    };
  }
  const win = new Window(src);
  const h = await win.view(0, FILE_HDR);
  const major = h.getUint16(4, true);
  const fileHdr = h.getUint16(8, true);
  const chunkHdr = h.getUint16(10, true);
  const blockSize = h.getUint32(12, true);
  const totalBlocks = h.getUint32(16, true);
  const totalChunks = h.getUint32(20, true);
  if (major !== 1) throw new SparseError(`unsupported sparse format version ${major}`);
  if (fileHdr < FILE_HDR || chunkHdr < CHUNK_HDR) throw new SparseError("bad sparse header sizes");
  if (blockSize === 0 || blockSize % 4 !== 0) throw new SparseError(`bad block size ${blockSize}`);

  const segments: Segment[] = [];
  let off = fileHdr;
  let block = 0;
  for (let i = 0; i < totalChunks; i++) {
    const c = await win.view(off, CHUNK_HDR);
    const type = c.getUint16(0, true);
    const blocks = c.getUint32(4, true);
    const total = c.getUint32(8, true);
    const data = off + chunkHdr;
    const at = `chunk ${i} (byte ${off})`;
    switch (type) {
      case CHUNK_RAW:
        if (total !== chunkHdr + blocks * blockSize) throw new SparseError(`${at}: RAW size mismatch`);
        if (blocks) segments.push({ kind: "raw", block, blocks, offset: data });
        break;
      case CHUNK_FILL: {
        if (total !== chunkHdr + 4) throw new SparseError(`${at}: FILL size mismatch`);
        const value = (await win.view(data, 4)).getUint32(0, true);
        if (blocks) segments.push({ kind: "fill", block, blocks, value });
        break;
      }
      case CHUNK_SKIP:
        if (total !== chunkHdr) throw new SparseError(`${at}: DONT_CARE size mismatch`);
        break;
      case CHUNK_CRC:
        if (total !== chunkHdr + 4 || blocks !== 0) throw new SparseError(`${at}: CRC32 chunk malformed`);
        break;
      default:
        throw new SparseError(`${at}: unknown chunk type 0x${type.toString(16)}`);
    }
    block += blocks;
    off += total;
    if (off > src.size) throw new SparseError(`${at}: runs past the end of the file`);
    if (block > totalBlocks) throw new SparseError(`${at}: more blocks than the header declares`);
  }
  if (block !== totalBlocks) throw new SparseError(`chunks cover ${block} blocks, header says ${totalBlocks}`);
  return { sparse: true, blockSize, totalBlocks, expandedBytes: totalBlocks * blockSize, sourceBytes: src.size, segments, tailPad: 0 };
}

export interface Piece {
  /** Exact number of bytes this piece sends (the fastboot download size). */
  bytes: number;
  /** Send the source file unchanged (it fits in one download); otherwise a rebuilt sparse image. */
  verbatim: boolean;
  segments: Segment[];
}

/** Bytes a piece with these segments occupies when sent as a sparse image. */
function sparseBytes(img: Image, segs: Segment[]): number {
  return FILE_HDR + countChunks(img, segs) * CHUNK_HDR + segs.reduce((n, s) => n + (s.kind === "raw" ? s.blocks * img.blockSize : 4), 0);
}

function countChunks(img: Image, segs: Segment[]): number {
  let n = 0;
  let at = 0;
  for (const s of segs) {
    if (s.block > at) n++;
    n++;
    at = s.block + s.blocks;
  }
  if (at < img.totalBlocks) n++;
  return n;
}

/** Splits the image into pieces of at most `maxBytes` each. */
export function planPieces(img: Image, maxBytes: number): Piece[] {
  if (img.sourceBytes <= maxBytes) return [{ bytes: img.sourceBytes, verbatim: true, segments: img.segments }];
  const bs = img.blockSize;
  if (maxBytes < FILE_HDR + 3 * CHUNK_HDR + bs) throw new SparseError(`download size ${maxBytes} is too small for ${bs}-byte blocks`);
  const pieces: Piece[] = [];
  let cur: Segment[] = [];
  // worst case per piece: header + leading and trailing DONT_CARE; each segment adds its header,
  // its data and possibly a DONT_CARE for the gap before it
  let used = FILE_HDR + 2 * CHUNK_HDR;
  let end = 0;
  const close = () => {
    if (cur.length) pieces.push({ bytes: sparseBytes(img, cur), verbatim: false, segments: cur });
    cur = [];
    used = FILE_HDR + 2 * CHUNK_HDR;
    end = 0;
  };
  for (const seg of img.segments) {
    let s: Segment = seg;
    for (;;) {
      const gap = cur.length && s.block > end ? CHUNK_HDR : 0;
      const cost = gap + CHUNK_HDR + (s.kind === "raw" ? s.blocks * bs : 4);
      if (used + cost <= maxBytes) {
        cur.push(s);
        used += cost;
        end = s.block + s.blocks;
        break;
      }
      if (s.kind === "raw") {
        const fit = Math.floor((maxBytes - used - gap - CHUNK_HDR) / bs);
        if (fit >= 1) {
          cur.push({ kind: "raw", block: s.block, blocks: fit, offset: s.offset });
          s = { kind: "raw", block: s.block + fit, blocks: s.blocks - fit, offset: s.offset + fit * bs };
        }
      }
      close();
    }
  }
  close();
  return pieces;
}

/**
 * The bytes of one piece, in buffers of up to `bufBytes`: headers and data are packed together so the USB
 * transfers stay large. Memory use is bounded by `bufBytes` whatever the image size.
 */
export async function* pieceBytes(src: ByteSource, img: Image, piece: Piece, bufBytes = 1 << 20): AsyncGenerator<Uint8Array> {
  if (piece.verbatim) {
    for (let o = 0; o < img.sourceBytes; o += bufBytes) yield await src.read(o, Math.min(bufBytes, img.sourceBytes - o));
    return;
  }
  const bs = img.blockSize;
  let out = new Uint8Array(bufBytes);
  let n = 0;
  async function* put(bytes: Uint8Array): AsyncGenerator<Uint8Array> {
    let i = 0;
    while (i < bytes.length) {
      const k = Math.min(bytes.length - i, out.length - n);
      out.set(bytes.subarray(i, i + k), n);
      n += k;
      i += k;
      if (n === out.length) {
        yield out;
        out = new Uint8Array(bufBytes);
        n = 0;
      }
    }
  }
  const hdr = (type: number, blocks: number, total: number) => {
    const b = new Uint8Array(CHUNK_HDR);
    const v = new DataView(b.buffer);
    v.setUint16(0, type, true);
    v.setUint32(4, blocks, true);
    v.setUint32(8, total, true);
    return b;
  };
  const fh = new Uint8Array(FILE_HDR);
  const v = new DataView(fh.buffer);
  v.setUint32(0, SPARSE_MAGIC, true);
  v.setUint16(4, 1, true);
  v.setUint16(6, 0, true);
  v.setUint16(8, FILE_HDR, true);
  v.setUint16(10, CHUNK_HDR, true);
  v.setUint32(12, bs, true);
  v.setUint32(16, img.totalBlocks, true);
  v.setUint32(20, countChunks(img, piece.segments), true);
  yield* put(fh);

  let at = 0;
  for (const s of piece.segments) {
    if (s.block > at) yield* put(hdr(CHUNK_SKIP, s.block - at, CHUNK_HDR));
    if (s.kind === "fill") {
      const f = new Uint8Array(4);
      new DataView(f.buffer).setUint32(0, s.value, true);
      yield* put(hdr(CHUNK_FILL, s.blocks, CHUNK_HDR + 4));
      yield* put(f);
    } else {
      yield* put(hdr(CHUNK_RAW, s.blocks, CHUNK_HDR + s.blocks * bs));
      // the raw image's short last block is padded with zeros
      const avail = Math.min(s.blocks * bs, img.sourceBytes - s.offset);
      for (let o = 0; o < avail; o += bufBytes) yield* put(await src.read(s.offset + o, Math.min(bufBytes, avail - o)));
      if (avail < s.blocks * bs) yield* put(new Uint8Array(s.blocks * bs - avail));
    }
    at = s.block + s.blocks;
  }
  if (at < img.totalBlocks) yield* put(hdr(CHUNK_SKIP, img.totalBlocks - at, CHUNK_HDR));
  if (n) yield out.subarray(0, n);
}
