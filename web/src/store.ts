// What a node keeps, laid out in a volume: the log in segments, the trees' pages, the questions' index, and a few small
// things kept whole. The node reads and writes all of it synchronously; a browser opens files only in its own time.
//
// So segments are opened ahead of need. Should the log outrun that, what is written to a segment not yet open is held
// here; and should it have to be durable before the segment is open, it is put in the journal, which is always open, and
// written where it belongs when the segment is. The journal says only what is held: when a segment's file has what was
// held of it, or it is dropped or cut short, the journal says so before anything more is done to it, and is emptied when
// nothing is held. At the next start it is played first, into the files of what was still held, and nothing else.
// Nothing said to be durable ever is not, and nothing let go of comes back.

import type { File, Volume } from "./volume.ts";

export const PAGE = 4096; // as zsp.PAGE_SIZE and find.PAGE_SIZE
const AHEAD = 2; // segments opened before they are needed
const WRITTEN = 1, FORGOTTEN = 2, TRUNCATED = 3; // what an entry of the journal says
const HEAD = 13; // of an entry
const EMPTY = new Uint8Array(0);

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
  journaled: number; // how much of it the journal has, from the start: what is written there next is journaled from here
  inJournal: boolean; // whether the journal says anything of it, so must say when it is held no longer
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

// Closes a file, whatever it throws: one that cannot be closed is let go of all the same, and keeps no other open.
function closing(f: File): void {
  try {
    f.close();
  } catch {
    // nothing more can be done with it
  }
}

export class Store {
  readonly volume: Volume;
  /** How long a segment is, as the node says. */
  readonly segment: number;
  #segments = new Map<number, File>();
  #opening = new Map<number, Promise<void>>();
  #held = new Map<number, Held>();
  #dropped = new Set<number>(); // while being opened
  #removing = new Map<number, number>(); // segments whose files are to be removed, and how many times, not yet done
  #dirty = new Set<File>();
  #tree!: File;
  #find!: File;
  #journal!: File;
  #journalEnd = 0;
  #kept = new Map<Kept, [Slot, Slot]>();
  #chain: Promise<void> = Promise.resolve(); // removals and openings, in the order they were asked for
  #closed = false;
  #abandoned = false;
  #isShut = false; // its files closed
  #pagesDirty = false; // written since they were last made durable
  #findDirty = false;
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
    // Whatever it opened is closed should opening fail: each file holds itself until closed, as a browser's do, and would
    // keep the next to open the store from it.
    const opened: File[] = [];
    const open = async (name: string, create: boolean) => {
      const f = await volume.open(name, create);
      if (f) opened.push(f);
      return f;
    };
    try {
      const names = await volume.list();
      for (const name of names) {
        const n = segmentNumber(name);
        if (n !== undefined) {
          const f = await open(name, false);
          if (f) s.#segments.set(n, f);
        }
      }
      s.#tree = (await open("tree", true))!;
      s.#find = (await open("find", true))!;
      s.#journal = (await open("journal", true))!;
      await s.#replay(open);
      for (const what of KEPT) {
        const a = (await open(what + ".0", true))!;
        const b = (await open(what + ".1", true))!;
        s.#kept.set(what, [Store.#slot(a), Store.#slot(b)]);
      }
    } catch (e) {
      for (const f of opened) closing(f);
      volume.close?.();
      throw e;
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
    // Opened at once where it can be, unless its file is yet to be removed: then held, and opened after, in order.
    if (!f && !this.#held.has(n) && this.volume.openNow && !this.#removing.has(n)) {
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
    if (!h) this.#held.set(n, (h = { bytes: new Uint8Array(Math.max(1 << 16, at + bytes.length)), length: 0, journaled: 0, inJournal: false }));
    if (at + bytes.length > h.bytes.length) {
      const grown = new Uint8Array(Math.max(at + bytes.length, h.bytes.length * 2));
      grown.set(h.bytes.subarray(0, h.length));
      h.bytes = grown;
    }
    if (at > h.length) h.bytes.fill(0, h.length, at); // as a file reads where nothing was written since it was cut short
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
    // Wanted again: what was dropped while being opened is not, now, and what is opened is for this.
    this.#dropped.delete(n);
    if (this.#segments.has(n) || this.#opening.has(n)) return;
    const opening = this.#after(async () => {
      let f: File;
      try {
        f = (await this.volume.open(segmentName(n), true))!;
      } finally {
        this.#opening.delete(n); // opened or not: should it be wanted again, it is opened again
      }
      if (this.#abandoned) {
        closing(f);
        return;
      }
      if (this.#dropped.delete(n)) {
        closing(f);
        await this.volume.remove(segmentName(n));
        return;
      }
      const h = this.#held.get(n);
      if (h) {
        // What was held is written where it belongs; once that is durable the journal need not say it, and must not,
        // before anything else is written to the file, or a replay would write it over what came after. Should that fail,
        // the file is closed, for nothing else would close it, and what was held is held still.
        try {
          f.write(h.bytes.subarray(0, h.length), 0);
          f.truncate(h.length);
          f.flush();
        } catch (e) {
          closing(f);
          throw e;
        }
        // The file has it all: it is the store's from now on, to be closed with it, whatever the journal can be told.
        this.#segments.set(n, f);
        this.#held.delete(n);
        this.#forget(n, h);
        this.onSettled?.();
        return;
      }
      this.#segments.set(n, f);
    });
    this.#opening.set(n, opening);
  }

  // Runs file operations one after another, so that a removal and a making of one name are done in the order asked; and
  // none at all once the store is let go of, for the files may be another's by then.
  #after(f: () => Promise<void>): Promise<void> {
    const next = this.#chain.then(() => (this.#abandoned ? undefined : f())).catch((e) => {
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
    const h = this.#held.get(n);
    if (h) {
      this.#held.delete(n);
      this.#forget(n, h);
    }
    const f = this.#segments.get(n);
    if (f) {
      f.close();
      this.#dirty.delete(f);
      this.#segments.delete(n);
      this.#removing.set(n, (this.#removing.get(n) ?? 0) + 1);
      this.#after(async () => {
        try {
          await this.volume.remove(segmentName(n));
        } finally {
          const k = this.#removing.get(n)! - 1;
          if (k > 0) this.#removing.set(n, k);
          else this.#removing.delete(n);
        }
      });
    } else if (this.#opening.has(n)) {
      this.#dropped.add(n);
    }
  }

  logTruncate(off: number): void {
    const last = Math.floor(off / this.segment);
    for (const n of [...this.#segments.keys(), ...this.#held.keys()]) if (n > last) this.logDrop(n);
    const h = this.#held.get(last);
    if (h && h.length > off % this.segment) {
      h.length = off % this.segment;
      h.journaled = Math.min(h.journaled, h.length);
      if (h.inJournal) {
        this.#record(TRUNCATED, last, h.length);
        this.#journal.flush();
      }
    }
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

  // Entries of the journal: kind (1) ‖ segment (4) ‖ offset (4) ‖ length (4) ‖ bytes ‖ crc (4) of all before it. Bytes
  // written at an offset of a held segment; a segment no longer held, whose file has all of it or which is dropped; or a
  // held segment cut short at an offset, and no bytes.
  #record(kind: number, n: number, offset: number, part: Uint8Array = EMPTY): void {
    const entry = new Uint8Array(HEAD + part.length + 4);
    const v = new DataView(entry.buffer);
    v.setUint8(0, kind);
    v.setUint32(1, n);
    v.setUint32(5, offset);
    v.setUint32(9, part.length);
    entry.set(part, HEAD);
    v.setUint32(HEAD + part.length, crc32(entry.subarray(0, HEAD + part.length)));
    this.#journal.write(entry, this.#journalEnd);
    this.#journalEnd += entry.length;
  }

  #journalHeld(): void {
    for (const [n, h] of this.#held) {
      if (h.journaled >= h.length) continue;
      this.#record(WRITTEN, n, h.journaled, h.bytes.subarray(h.journaled, h.length));
      Store.counts.journaled++;
      h.journaled = h.length;
      h.inJournal = true;
    }
    this.#journal.flush();
  }

  // A segment is held no longer. With nothing held the journal says nothing; else it says that this one is not, durably,
  // if it ever said it was.
  #forget(n: number, h: Held): void {
    if (this.#held.size === 0) {
      if (this.#journalEnd > 0) {
        this.#journal.truncate(0);
        this.#journal.flush();
        this.#journalEnd = 0;
      }
    } else if (h.inJournal) {
      this.#record(FORGOTTEN, n, 0);
      this.#journal.flush();
    }
  }

  // Puts what the journal holds where it belongs: at the start, before anything reads the log. What it says is played in
  // memory, and only what was still held at the end is written, to its segment, whole.
  async #replay(open: (name: string, create: boolean) => Promise<File | undefined>): Promise<void> {
    const size = this.#journal.size();
    if (size === 0) return;
    const all = new Uint8Array(size);
    this.#journal.read(all, 0);
    const images = new Map<number, { bytes: Uint8Array; length: number }>();
    for (let at = 0; at + HEAD + 4 <= size; ) {
      const v = new DataView(all.buffer, at);
      const kind = v.getUint8(0), n = v.getUint32(1), offset = v.getUint32(5), length = v.getUint32(9);
      if (at + HEAD + length + 4 > size || v.getUint32(HEAD + length) !== crc32(all.subarray(at, at + HEAD + length))) break; // torn: never said to be durable
      if (kind === WRITTEN) {
        let image = images.get(n);
        if (!image) images.set(n, (image = { bytes: new Uint8Array(offset + length), length: 0 }));
        if (offset + length > image.bytes.length) {
          const grown = new Uint8Array(Math.max(offset + length, image.bytes.length * 2));
          grown.set(image.bytes.subarray(0, image.length));
          image.bytes = grown;
        }
        image.bytes.set(all.subarray(at + HEAD, at + HEAD + length), offset);
        image.length = Math.max(image.length, offset + length);
      } else if (kind === FORGOTTEN) {
        images.delete(n);
      } else if (kind === TRUNCATED) {
        const image = images.get(n);
        if (image) image.length = Math.min(image.length, offset);
      } else {
        break; // what this does not know it did not write
      }
      at += HEAD + length + 4;
    }
    for (const [n, image] of images) {
      let f = this.#segments.get(n);
      if (!f) this.#segments.set(n, (f = (await open(segmentName(n), true))!));
      f.write(image.bytes.subarray(0, image.length), 0);
      f.truncate(image.length);
      f.flush();
      Store.counts.replayed++;
    }
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
    this.#pagesDirty = true;
    return this.#tree.write(block, no * PAGE) === PAGE;
  }

  pageSync(): boolean {
    try {
      this.#tree.flush();
      this.#pagesDirty = false;
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
    this.#findDirty = true;
    return this.#find.write(bytes, no * PAGE) === bytes.length;
  }

  findSync(): boolean {
    try {
      this.#find.flush();
      this.#findDirty = false;
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

  /**
   * Closes every file it has open now, making nothing more durable, for storage has failed: what is being opened is closed
   * as it comes, and nothing more is opened or removed. Resolves once nothing is being opened or removed either, and so no
   * file of the store is held: only then may another open it, though whoever is to be told it failed may be told at once.
   */
  letGo(): Promise<void> {
    this.#abandoned = true;
    this.#closed = true;
    this.#shut();
    return this.#chain;
  }

  /**
   * Makes durable what was written, and closes every file at once, as a worker about to be stopped must, for it cannot
   * wait: what is being opened is closed as it comes, and nothing more is opened or removed. Resolves as `letGo` does.
   */
  closeNow(): Promise<void> {
    if (!this.#abandoned) {
      // What fails here fails as it would at the next sync: nothing said to be durable depends on it, and every file is
      // closed whatever it does.
      this.logSync();
      if (this.#pagesDirty) this.pageSync();
      if (this.#findDirty) this.findSync();
    }
    return this.letGo();
  }

  /** Closes every file, once whatever was being opened or removed is done. */
  async close(): Promise<void> {
    this.#closed = true;
    await this.#chain;
    this.#shut();
  }

  // Closes every file it has, once, whichever way it is let go of; and lets go of the volume, which gives up waiting for
  // any file being opened.
  #shut(): void {
    if (this.#isShut) return;
    this.#isShut = true;
    for (const f of this.#segments.values()) closing(f);
    this.#segments.clear();
    this.#dirty.clear();
    for (const [a, b] of this.#kept.values()) closing(a.file), closing(b.file);
    this.#kept.clear();
    closing(this.#tree);
    closing(this.#find);
    closing(this.#journal);
    this.volume.close?.();
  }
}
