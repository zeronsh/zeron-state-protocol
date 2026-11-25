// What a node keeps, laid out in a volume: the log in segments, the trees' pages, the questions' index, and a few small
// things kept whole. The node reads and writes all of it synchronously; a browser opens files only in its own time.
//
// So segments are opened ahead of need. Should the log outrun that, what is written to a segment not yet open is held
// here; and should it have to be durable before the segment is open, it is put in the journal, which is always open, and
// written where it belongs when the segment is. At the next start the journal is played first. Nothing said to be durable
// ever is not.

import type { File, Volume } from "./volume.ts";

export const PAGE = 4096; // as zsp.PAGE_SIZE and find.PAGE_SIZE
const AHEAD = 2; // segments opened before they are needed

/** Small things, each kept whole: written to whichever of two files does not hold the latest, so a torn write loses nothing. */
export type Kept = "device" | "space" | "keys" | "roster";
const KEPT: Kept[] = ["device", "space", "keys", "roster"];
const KEPT_MAGIC = 0x7a73706b; // "zspk"

interface Slot {
  file: File;
  generation: number;
  bytes?: Uint8Array;
}

// A segment written to before its file was open.
interface Held {
  bytes: Uint8Array;
  length: number;
  journaled: number; // how much of it the journal has
}

function segmentName(n: number): string {
  // Eight hex digits, and more when there are more, as host/ names them.
  return n.toString(16).padStart(8, "0") + ".log";
}

function segmentNumber(name: string): number | undefined {
  const m = /^([0-9a-f]{8,})\.log$/.exec(name);
  return m ? parseInt(m[1], 16) : undefined;
}

const crcTable = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();

function crc32(bytes: Uint8Array): number {
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = crcTable[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

export class Store {
  readonly volume: Volume;
  /** How long a segment is, as the node says. */
  readonly segment: number;
  #segments = new Map<number, File>();
  #opening = new Map<number, Promise<void>>();
  #held = new Map<number, Held>();
  #dropped = new Set<number>(); // while being opened
  #dirty = new Set<File>();
  #tree!: File;
  #find!: File;
  #journal!: File;
  #journalEnd = 0;
  #kept = new Map<Kept, [Slot, Slot]>();
  #chain: Promise<void> = Promise.resolve(); // removals and openings, in the order they were asked for
  #closed = false;
  #abandoned = false;
  /** How often the ways round a file not yet open were taken: for tests, which must see that they were. */
  static readonly counts = { held: 0, journaled: 0, replayed: 0 };
  /** Called when something that was waiting for a file is done, should anyone want to know. */
  onSettled?: () => void;
  /** Called with what went wrong in the background, which the node will meet next time it asks for durability. */
  failure?: unknown;

  private constructor(volume: Volume, segment: number) {
    this.volume = volume;
    this.segment = segment;
  }

  static async open(volume: Volume, segment: number): Promise<Store> {
    const s = new Store(volume, segment);
    const names = await volume.list();
    for (const name of names) {
      const n = segmentNumber(name);
      if (n !== undefined) {
        const f = await volume.open(name, false);
        if (f) s.#segments.set(n, f);
      }
    }
    s.#tree = (await volume.open("tree", true))!;
    s.#find = (await volume.open("find", true))!;
    s.#journal = (await volume.open("journal", true))!;
    await s.#replay();
    for (const what of KEPT) {
      const a = (await volume.open(what + ".0", true))!;
      const b = (await volume.open(what + ".1", true))!;
      s.#kept.set(what, [Store.#slot(a), Store.#slot(b)]);
    }
    const last = Math.max(-1, ...s.#segments.keys());
    s.#ahead(last);
    return s;
  }

  // ---------------------------------------------------------------- kept

  // A kept file: magic (4) ‖ generation (8) ‖ length (4) ‖ bytes ‖ crc (4) of all after the magic.
  static #slot(file: File): Slot {
    const size = file.size();
    const all = new Uint8Array(size);
    if (size < 20 || file.read(all, 0) < size) return { file, generation: 0 };
    const v = new DataView(all.buffer);
    const length = v.getUint32(12);
    if (v.getUint32(0) !== KEPT_MAGIC || 20 + length > size || v.getUint32(16 + length) !== crc32(all.subarray(4, 16 + length))) {
      return { file, generation: 0 };
    }
    return { file, generation: v.getUint32(4) * 2 ** 32 + v.getUint32(8), bytes: all.slice(16, 16 + length) };
  }

  /** The latest of a kind kept, and the one before it. */
  kept(what: Kept): { latest?: Uint8Array; before?: Uint8Array } {
    const [a, b] = this.#kept.get(what)!;
    const [hi, lo] = a.generation >= b.generation ? [a, b] : [b, a];
    return { latest: hi.bytes, before: lo.bytes };
  }

  /** Keeps something whole, durably, the one it replaces becoming the one before. */
  keep(what: Kept, bytes: Uint8Array): void {
    const [a, b] = this.#kept.get(what)!;
    const [hi, lo] = a.generation >= b.generation ? [a, b] : [b, a];
    const generation = hi.generation + 1;
    const out = new Uint8Array(16 + bytes.length + 4);
    const v = new DataView(out.buffer);
    v.setUint32(0, KEPT_MAGIC);
    v.setUint32(4, Math.floor(generation / 2 ** 32));
    v.setUint32(8, generation >>> 0);
    v.setUint32(12, bytes.length);
    out.set(bytes, 16);
    v.setUint32(16 + bytes.length, crc32(out.subarray(4, 16 + bytes.length)));
    lo.file.write(out, 0);
    lo.file.truncate(out.length);
    lo.file.flush();
    lo.generation = generation;
    lo.bytes = bytes.slice();
  }

  // ---------------------------------------------------------------- the log

  logWrite(off: number, bytes: Uint8Array): boolean {
    const n = Math.floor(off / this.segment);
    const at = off % this.segment;
    let f = this.#segments.get(n);
    if (!f && !this.#held.has(n) && this.volume.openNow) {
      f = this.volume.openNow(segmentName(n), true)!;
      this.#segments.set(n, f);
    }
    if (f) {
      if (f.write(bytes, at) !== bytes.length) return false;
      this.#dirty.add(f);
    } else {
      this.#hold(n, at, bytes);
    }
    this.#ahead(n);
    return true;
  }

  #hold(n: number, at: number, bytes: Uint8Array): void {
    Store.counts.held++;
    let h = this.#held.get(n);
    if (!h) this.#held.set(n, (h = { bytes: new Uint8Array(Math.max(1 << 16, at + bytes.length)), length: 0, journaled: 0 }));
    if (at + bytes.length > h.bytes.length) {
      const grown = new Uint8Array(Math.max(at + bytes.length, h.bytes.length * 2));
      grown.set(h.bytes.subarray(0, h.length));
      h.bytes = grown;
    }
    h.bytes.set(bytes, at);
    h.length = Math.max(h.length, at + bytes.length);
    h.journaled = Math.min(h.journaled, at); // the log only grows, but should anything be written over, it is journaled again
    this.#openSegment(n);
  }

  // Opens segments before they are needed, where opening is not immediate.
  #ahead(n: number): void {
    if (this.volume.openNow || this.#closed) return;
    for (let k = n + 1; k <= n + AHEAD; k++) this.#openSegment(k);
  }

  #openSegment(n: number): void {
    if (this.#segments.has(n) || this.#opening.has(n)) return;
    this.#dropped.delete(n);
    const opening = this.#after(async () => {
      const f = (await this.volume.open(segmentName(n), true))!;
      this.#opening.delete(n);
      if (this.#abandoned) {
        f.close();
        return;
      }
      if (this.#dropped.delete(n)) {
        f.close();
        await this.volume.remove(segmentName(n));
        return;
      }
      this.#segments.set(n, f);
      const h = this.#held.get(n);
      if (h) {
        // What was held is written where it belongs, and once that is durable the journal need not say it.
        f.write(h.bytes.subarray(0, h.length), 0);
        f.flush();
        this.#held.delete(n);
        if (this.#held.size === 0 && this.#journalEnd > 0) {
          this.#journal.truncate(0);
          this.#journal.flush();
          this.#journalEnd = 0;
        }
        this.onSettled?.();
      }
    });
    this.#opening.set(n, opening);
  }

  // Runs file operations one after another, so that a removal and a making of one name are done in the order asked.
  #after(f: () => Promise<void>): Promise<void> {
    const next = this.#chain.then(f).catch((e) => {
      this.failure ??= e;
    });
    this.#chain = next;
    return next;
  }

  logRead(off: number, into: Uint8Array): boolean {
    const n = Math.floor(off / this.segment);
    const at = off % this.segment;
    const h = this.#held.get(n);
    if (h) {
      if (at + into.length > h.length) return false;
      into.set(h.bytes.subarray(at, at + into.length));
      return true;
    }
    const f = this.#segments.get(n);
    return f !== undefined && f.read(into, at) === into.length;
  }

  logEnd(): number {
    let end = 0;
    for (const [n, f] of this.#segments) {
      const size = f.size();
      if (size > 0) end = Math.max(end, n * this.segment + size);
    }
    for (const [n, h] of this.#held) if (h.length > 0) end = Math.max(end, n * this.segment + h.length);
    return end;
  }

  logDrop(n: number): void {
    this.#held.delete(n);
    const f = this.#segments.get(n);
    if (f) {
      f.close();
      this.#dirty.delete(f);
      this.#segments.delete(n);
      this.#after(() => this.volume.remove(segmentName(n)));
    } else if (this.#opening.has(n)) {
      this.#dropped.add(n);
    }
  }

  logTruncate(off: number): void {
    const last = Math.floor(off / this.segment);
    for (const n of [...this.#segments.keys(), ...this.#held.keys()]) if (n > last) this.logDrop(n);
    const h = this.#held.get(last);
    if (h) h.length = Math.min(h.length, off % this.segment), (h.journaled = Math.min(h.journaled, h.length));
    const f = this.#segments.get(last);
    if (f && f.size() > off % this.segment) f.truncate(off % this.segment), this.#dirty.add(f);
  }

  logSync(): boolean {
    if (this.failure !== undefined) return false;
    try {
      for (const f of this.#dirty) f.flush();
      this.#dirty.clear();
      if (this.#held.size > 0) this.#journalHeld();
      return true;
    } catch (e) {
      this.failure ??= e;
      return false;
    }
  }

  // Entries of the journal: segment (4) ‖ offset (4) ‖ length (4) ‖ bytes ‖ crc (4) of all before it.
  #journalHeld(): void {
    for (const [n, h] of this.#held) {
      if (h.journaled >= h.length) continue;
      const part = h.bytes.subarray(h.journaled, h.length);
      const entry = new Uint8Array(12 + part.length + 4);
      const v = new DataView(entry.buffer);
      v.setUint32(0, n);
      v.setUint32(4, h.journaled);
      v.setUint32(8, part.length);
      entry.set(part, 12);
      v.setUint32(12 + part.length, crc32(entry.subarray(0, 12 + part.length)));
      this.#journal.write(entry, this.#journalEnd);
      Store.counts.journaled++;
      this.#journalEnd += entry.length;
      h.journaled = h.length;
    }
    this.#journal.flush();
  }

  // Puts what the journal holds where it belongs: at the start, before anything reads the log.
  async #replay(): Promise<void> {
    const size = this.#journal.size();
    if (size === 0) return;
    const all = new Uint8Array(size);
    this.#journal.read(all, 0);
    const touched = new Set<File>();
    for (let at = 0; at + 16 <= size; ) {
      const v = new DataView(all.buffer, at);
      const length = v.getUint32(8);
      if (at + 16 + length > size || v.getUint32(12 + length) !== crc32(all.subarray(at, at + 12 + length))) break; // torn: never said to be durable
      const n = v.getUint32(0);
      let f = this.#segments.get(n);
      if (!f) this.#segments.set(n, (f = (await this.volume.open(segmentName(n), true))!));
      f.write(all.subarray(at + 12, at + 12 + length), v.getUint32(4));
      touched.add(f);
      Store.counts.replayed++;
      at += 16 + length;
    }
    for (const f of touched) f.flush();
    this.#journal.truncate(0);
    this.#journal.flush();
  }

  // ---------------------------------------------------------------- pages

  pageRead(no: number, into: Uint8Array): boolean {
    return this.#tree.read(into, no * PAGE) === into.length;
  }

  pageWrite(no: number, bytes: Uint8Array): boolean {
    const block = bytes.length === PAGE ? bytes : new Uint8Array(PAGE);
    if (block !== bytes) block.set(bytes);
    return this.#tree.write(block, no * PAGE) === PAGE;
  }

  pageSync(): boolean {
    try {
      this.#tree.flush();
      return true;
    } catch (e) {
      this.failure ??= e;
      return false;
    }
  }

  findRead(no: number, into: Uint8Array): boolean {
    return this.#find.read(into, no * PAGE) === into.length;
  }

  findWrite(no: number, bytes: Uint8Array): boolean {
    return this.#find.write(bytes, no * PAGE) === bytes.length;
  }

  findSync(): boolean {
    try {
      this.#find.flush();
      return true;
    } catch {
      return false; // it can always be made again
    }
  }

  /** Whether everything written is where it belongs, rather than held or journaled. */
  get settled(): boolean {
    return this.#held.size === 0;
  }

  /** Writes nothing more, ever, as a machine that has lost its power does not. For tests. */
  abandon(): void {
    this.#abandoned = true;
    this.#closed = true;
  }

  /** Closes every file, once whatever was being opened or removed is done. */
  async close(): Promise<void> {
    this.#closed = true;
    await this.#chain;
    for (const f of this.#segments.values()) f.close();
    this.#segments.clear();
    for (const [a, b] of this.#kept.values()) a.file.close(), b.file.close();
    this.#tree.close();
    this.#find.close();
    this.#journal.close();
    this.volume.close?.();
  }
}
