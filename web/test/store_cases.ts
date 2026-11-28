// The store's journal, case by case: what is dropped or cut short stays so through a crash, and what a segment's file
// was given after the journal last spoke of it is not written over. Files open in their own time here, as a browser's do.

import assert from "node:assert/strict";
import { Store } from "../src/store.ts";
import fs, { mkdtempSync, rmSync } from "node:fs";
import { syncBuiltinESMExports } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MemoryVolume, type File, type Volume } from "../src/volume.ts";
import { NodeVolume } from "../src/volume-node.ts";

const SEGMENT = 1000;
const bytes = (ch: string, n: number) => new TextEncoder().encode(ch.repeat(n));
const turn = () => new Promise((done) => setTimeout(done, 0));

// Opens a store, letting what it waits to open be opened meanwhile.
async function opened(volume: Volume): Promise<Store> {
  const settling = setInterval(() => (volume as MemoryVolume).settle?.(), 1);
  try {
    return await Store.open(volume, SEGMENT);
  } finally {
    clearInterval(settling);
  }
}

// What a segment holds, as the store reads it.
function read(s: Store, n: number): string {
  let length = 0;
  const end = s.logEnd();
  if (end <= n * SEGMENT) return "";
  length = Math.min(SEGMENT, end - n * SEGMENT);
  for (let k = length; k > 0; k--) {
    const into = new Uint8Array(k);
    if (s.logRead(n * SEGMENT, into)) return new TextDecoder().decode(into);
  }
  return "";
}

async function crashed(volume: MemoryVolume, s: Store): Promise<Store> {
  s.abandon();
  volume.crash();
  return opened(volume);
}

// A held segment that is dropped does not come back.
{
  const volume = new MemoryVolume({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(0, bytes("a", 100)));
  assert(s.logWrite(SEGMENT, bytes("b", 100)));
  assert(s.logSync());
  s.logDrop(1);
  s = await crashed(volume, s);
  assert.equal(s.logEnd(), 100, "the dropped segment came back");
  assert.equal(read(s, 0), "a".repeat(100));
}

// A segment whose file has what was held of it, cut short and written again while another is still held: a replay does
// not write the old bytes over the new.
{
  const volume = new MemoryVolume({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(0, bytes("a", 100)));
  assert(s.logWrite(SEGMENT, bytes("b", 50)));
  assert(s.logSync());
  volume.settle(); // the first file opens, and only that
  for (let i = 0; i < 5; i++) await turn();
  assert.equal(s.settled, false, "the second is still held");
  s.logTruncate(40);
  assert(s.logWrite(40, bytes("c", 30)));
  assert(s.logSync());
  s = await crashed(volume, s);
  assert.equal(read(s, 0), "a".repeat(40) + "c".repeat(30));
  assert.equal(s.logEnd(), 70, "what was cut short came back");
}

// A held segment cut short stays short, and what is written after stands.
{
  const volume = new MemoryVolume({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(0, bytes("a", 100)));
  assert(s.logSync());
  s.logTruncate(30);
  assert(s.logWrite(30, bytes("d", 20)));
  assert(s.logSync());
  s = await crashed(volume, s);
  assert.equal(read(s, 0), "a".repeat(30) + "d".repeat(20));
}

// And a journal that says nothing once nothing is held: what settles is not played again at every start.
{
  const volume = new MemoryVolume({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(0, bytes("a", 10)));
  assert(s.logSync());
  for (let i = 0; i < 20 && !s.settled; i++) volume.settle(), await turn();
  assert(s.settled);
  const replayed = Store.counts.replayed;
  s = await crashed(volume, s);
  assert.equal(Store.counts.replayed, replayed, "a settled journal was played again");
  assert.equal(read(s, 0), "a".repeat(10));
}

// Opening one file at a time, until what was held of a segment is in its file.
async function settleOnce(volume: MemoryVolume, s: Store): Promise<void> {
  let settled = false;
  s.onSettled = () => (settled = true);
  for (let i = 0; i < 50 && !settled; i++) volume.settle(), await turn();
  assert(settled, "a segment settled");
  s.onSettled = undefined;
}

// A segment cut to nothing, then opened while another is still held: the journal says it is held no longer, though it
// had nothing in it when it went; and what is written to its file after is not wiped by a replay.
{
  const volume = new MemoryVolume({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(5 * SEGMENT, bytes("x", 100)));
  assert(s.logWrite(4 * SEGMENT, bytes("w", 50))); // asked to open after the fifth
  assert(s.logSync());
  s.logTruncate(5 * SEGMENT);
  await settleOnce(volume, s); // the fifth opens; the fourth is still held
  assert(s.logWrite(5 * SEGMENT, bytes("n", 500)));
  assert(s.logSync());
  s = await crashed(volume, s);
  assert.equal(read(s, 5), "n".repeat(500), "what was written after was wiped");
}

// Written over at its start before its file opens: the journal says it is held no longer, and old bytes do not come back
// over new ones.
{
  const volume = new MemoryVolume({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(5 * SEGMENT, bytes("x", 100)));
  assert(s.logWrite(4 * SEGMENT, bytes("w", 50)));
  assert(s.logSync());
  assert(s.logWrite(5 * SEGMENT, bytes("y", 20)));
  await settleOnce(volume, s);
  assert(s.logWrite(5 * SEGMENT + 100, bytes("z", 10)));
  assert(s.logSync());
  s = await crashed(volume, s);
  assert.equal(read(s, 5), "y".repeat(20) + "x".repeat(80) + "z".repeat(10), "old bytes came back");
}

// Written, dropped, and written again, all while its file is being opened: what was written last is kept.
{
  const volume = new MemoryVolume({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(9 * SEGMENT, bytes("a", 30)));
  s.logDrop(9);
  assert(s.logWrite(9 * SEGMENT, bytes("b", 40)));
  assert(s.logSync());
  for (let i = 0; i < 50 && !s.settled; i++) volume.settle(), await turn();
  assert(s.settled, "what was held never found its file");
  assert.equal(read(s, 9), "b".repeat(40));
  const settling = setInterval(() => volume.settle(), 1);
  await s.close();
  clearInterval(settling);
  s = await opened(volume);
  assert.equal(read(s, 9), "b".repeat(40), "and it was lost when the store closed");
}

// Cut short, so that its file is to go, and written again at once where files open at once: the file that is written to
// is not removed after, whichever kind of volume it is.
for (const volume of [new MemoryVolume(), new NodeVolume(mkdtempSync(join(tmpdir(), "zsp-store-")))]) {
  let s = await opened(volume);
  assert(s.logWrite(1 * SEGMENT, bytes("a", 30)));
  assert(s.logSync());
  s.logTruncate(100);
  assert(s.logWrite(1 * SEGMENT, bytes("b", 40)));
  assert(s.logSync());
  await new Promise((done) => setTimeout(done, 20));
  assert((await volume.list()).includes("00000001.log"), "the file written to was removed");
  await s.close();
  s = await opened(volume);
  assert.equal(read(s, 1), "b".repeat(40), "and what was written to it lost");
  await s.close();
  if (volume instanceof NodeVolume) rmSync(volume.path, { recursive: true, force: true });
}

// Let go of, as when storage fails, with files still being opened and removed: what was queued is not done after, when
// another store has the files.
{
  class Gated extends MemoryVolume {
    gate?: Promise<void>;
    override async open(name: string, create: boolean) {
      if (name === "00000004.log" && this.gate) await this.gate;
      return super.open(name, create);
    }
  }
  const volume = new Gated();
  volume.openNow = undefined; // through open, which is gated
  const a = await Store.open(volume, SEGMENT);
  assert(a.logWrite(1 * SEGMENT, bytes("a", 30)));
  assert(a.logSync());
  for (let i = 0; i < 50 && !a.settled; i++) await turn();
  let release!: () => void;
  volume.gate = new Promise((done) => (release = done));
  assert(a.logWrite(4 * SEGMENT, bytes("x", 10))); // whose file is held up, and those after it queued behind
  a.logDrop(1); // and the removal of this one too
  a.letGo();
  const b = await Store.open(volume, SEGMENT);
  assert(b.logWrite(1 * SEGMENT, bytes("b", 40)));
  assert(b.logSync());
  for (let i = 0; i < 50 && !b.settled; i++) await turn();
  release();
  for (let i = 0; i < 20; i++) await turn();
  const names = await volume.list();
  assert(names.includes("00000001.log"), "what another store wrote was removed by the one let go of");
  assert(!names.includes("00000006.log"), "and files were opened by it after");
  await b.close();
  const c = await Store.open(volume, SEGMENT);
  assert.equal(read(c, 1), "b".repeat(40));
  await c.close();
}

// A held segment cut short and then written past its end reads nothing but zeroes between, as a file does: not what was
// there before it was cut short.
{
  const volume = new MemoryVolume({ slow: true });
  const s = await opened(volume);
  const at = 50 * SEGMENT; // well past what was opened ahead: held
  assert(s.logWrite(at, bytes("a", 64)));
  s.logTruncate(at + 8);
  assert(s.logWrite(at + 32, bytes("b", 8)));
  assert.equal(s.settled, false, "it was not held");
  const between = new Uint8Array(24);
  assert(s.logRead(at + 8, between));
  assert.deepEqual([...between], new Array(24).fill(0), "what was cut short came back");
  assert(s.logSync());
  for (let i = 0; i < 50 && !s.settled; i++) volume.settle(), await turn(); // and so once its file has it
  assert(s.settled);
  assert(s.logRead(at + 8, between));
  assert.deepEqual([...between], new Array(24).fill(0), "what was cut short came back, written");
  const settling = setInterval(() => volume.settle(), 1);
  await s.close();
  clearInterval(settling);
}

// Files are closed whatever goes wrong: each holds itself until closed, as a browser's do, and would keep the store from
// the next to open it. When opening fails partway, what was opened is closed; and so is a segment's file that could not
// be given what was held of it.
{
  class Counting extends MemoryVolume {
    open_ = 0;
    closed_ = 0;
    failOn?: string;
    failFlush = false;
    override async open(name: string, create: boolean): Promise<File | undefined> {
      if (name === this.failOn) throw new Error("no room to make it");
      const f = await super.open(name, create);
      if (!f) return f;
      this.open_++;
      const close = f.close.bind(f), flush = f.flush.bind(f);
      f.close = () => (this.closed_++, close());
      f.flush = () => {
        if (this.failFlush && /\.log$/.test(name)) throw new Error("the disk is full");
        flush();
      };
      return f;
    }
  }
  const failing = new Counting();
  failing.failOn = "roster.1";
  await assert.rejects(Store.open(failing, SEGMENT), /no room/);
  assert(failing.open_ > 3);
  assert.equal(failing.closed_, failing.open_, "files opened before it failed were left open");

  const volume = new Counting({ slow: true });
  const s = await opened(volume);
  assert(s.logWrite(50 * SEGMENT, bytes("a", 10))); // held, its file not open
  volume.failFlush = true;
  for (let i = 0; i < 50 && !s.failure; i++) volume.settle(), await turn();
  assert(s.failure, "it says that storage failed");
  s.letGo();
  assert.equal(volume.closed_, volume.open_, "a segment's file that could not be given what was held was left open");
}

// Nor is a segment's file that was given what was held of it, but whose journal could not then be told so.
{
  class Journal extends MemoryVolume {
    open_ = 0;
    closed_ = 0;
    failing = false;
    override async open(name: string, create: boolean): Promise<File | undefined> {
      const f = await super.open(name, create);
      if (!f) return f;
      this.open_++;
      const close = f.close.bind(f), truncate = f.truncate.bind(f);
      f.close = () => (this.closed_++, close());
      if (name === "journal") f.truncate = (size) => (this.failing ? (() => { throw new Error("the disk is full"); })() : truncate(size));
      return f;
    }
  }
  const volume = new Journal({ slow: true });
  const s = await opened(volume);
  assert(s.logWrite(50 * SEGMENT, bytes("a", 10))); // held
  assert(s.logSync()); // and so journaled
  volume.failing = true;
  for (let i = 0; i < 50 && !s.failure; i++) volume.settle(), await turn();
  assert(s.failure, "it says that storage failed");
  s.letGo();
  assert.equal(volume.closed_, volume.open_, "a segment's file whose journal could not be told was left open");
}

// A volume whose journal fails, once told to: as a full disk, or one that cannot be written any more.
class Unjournaled extends MemoryVolume {
  failing = false;
  override async open(name: string, create: boolean): Promise<File | undefined> {
    const f = await super.open(name, create);
    if (!f || name !== "journal") return f;
    const write = f.write.bind(f), truncate = f.truncate.bind(f), flush = f.flush.bind(f);
    const fail = () => {
      if (this.failing) throw new Error("the disk cannot be written");
    };
    f.write = (b, at) => (fail(), write(b, at));
    f.truncate = (size) => (fail(), truncate(size));
    f.flush = () => (fail(), flush());
    return f;
  }
}

// A held segment dropped while the journal cannot be told so: storage has failed, and the segment is held still, as the next
// start finds it; nothing more is made durable, a checkpoint no more than the log.
{
  const volume = new Unjournaled({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(50 * SEGMENT, bytes("a", 10))); // held, as is the next, their files not open
  assert(s.logWrite(51 * SEGMENT, bytes("b", 10)));
  assert(s.logSync()); // and so journaled
  volume.failing = true;
  assert.throws(() => s.logDrop(50), /cannot be written/);
  assert(s.failure, "it did not say that storage failed");
  assert.equal(read(s, 50), "a".repeat(10), "it let go of what the journal still says it holds");
  assert(!s.logSync() && !s.pageSync(), "it made something durable after");
  volume.failing = false;
  s = await crashed(volume, s);
  assert.equal(read(s, 50), "a".repeat(10), "as the next start finds it");
}

// Nor is a held segment cut short where the journal cannot be told so: it is as long as the next start finds it.
{
  const volume = new Unjournaled({ slow: true });
  let s = await opened(volume);
  assert(s.logWrite(50 * SEGMENT, bytes("a", 100)));
  assert(s.logSync());
  volume.failing = true;
  assert.throws(() => s.logTruncate(50 * SEGMENT + 30), /cannot be written/);
  assert(s.failure, "it did not say that storage failed");
  assert.equal(read(s, 50), "a".repeat(100), "it was cut short though the journal does not say so");
  assert(!s.logWrite(50 * SEGMENT + 30, bytes("c", 5)), "it was written to after");
  volume.failing = false;
  s = await crashed(volume, s);
  assert.equal(read(s, 50), "a".repeat(100));
}

// Once something has failed in the background, as a segment's file that could not be given what was held of it, nothing
// more is made durable: no checkpoint, no more than the log; and nothing more is written, dropped, cut short or kept.
{
  const volume = new MemoryVolume({ slow: true });
  const s = await opened(volume);
  assert(s.logWrite(0, bytes("a", 10)));
  assert(s.logWrite(50 * SEGMENT, bytes("b", 10))); // held, its file not open
  let told = 0;
  s.onSettled = () => told++;
  const open = volume.open.bind(volume);
  volume.open = async (name, create) => {
    if (name.endsWith(".log")) throw new Error("too many files open");
    return open(name, create);
  };
  for (let i = 0; i < 50 && !s.failure; i++) volume.settle(), await turn();
  assert(s.failure, "it says that storage failed");
  assert(told > 0, "whoever was to be told was not");
  assert(s.pageWrite(0, new Uint8Array(4096)) === false, "a page was written after");
  assert(!s.pageSync(), "a checkpoint was made durable after");
  assert(!s.logSync() && !s.logWrite(10, bytes("c", 5)) && !s.findWrite(0, new Uint8Array(4096)));
  s.logDrop(0);
  s.logTruncate(5);
  assert.equal(read(s, 0), "a".repeat(10), "it was dropped or cut short after");
  assert.throws(() => s.keep("roster", bytes("r", 4)), /storage has failed/);
  s.letGo();
}

// A store's directory that cannot be listed, as with too many files open, is not opened as an empty one, which would have
// none of the log: it fails to open. One that is not there yet is empty.
{
  const dir = mkdtempSync(join(tmpdir(), "zsp-store-"));
  let s = await opened(new NodeVolume(dir));
  assert(s.logWrite(0, bytes("a", 10)));
  assert(s.logSync());
  await s.close();
  const readdir = fs.readdirSync;
  for (const code of ["EMFILE", "EACCES", "EIO"]) {
    fs.readdirSync = ((path: fs.PathLike, ...rest: unknown[]) => {
      if (String(path).includes("zsp-store-")) throw Object.assign(new Error(`${code}: cannot list ${path}`), { code });
      return (readdir as (...a: unknown[]) => unknown)(path, ...rest);
    }) as typeof fs.readdirSync;
    syncBuiltinESMExports();
    try {
      await assert.rejects(Store.open(new NodeVolume(dir), SEGMENT), new RegExp(code), `${code}: opened as empty`);
    } finally {
      fs.readdirSync = readdir;
      syncBuiltinESMExports();
    }
  }
  s = await opened(new NodeVolume(dir));
  assert.equal(read(s, 0), "a".repeat(10), "and it opens as it was once it can be listed");
  await s.close();
  s = await opened(new NodeVolume(join(dir, "new")));
  assert.equal(s.logEnd(), 0);
  await s.close();
  rmSync(dir, { recursive: true, force: true });
}

// Power lost, as on a disk that tears what it was writing: what was written to a file and not flushed is lost, and whatever
// it was written over with it. And a process killed: what it wrote and did not flush is in the system's keeping still.
class Tearing extends MemoryVolume {
  killFlush?: RegExp; // the files whose flush never comes, the process killed first
  #unflushed = new Set<string>();
  constructor() {
    super();
    const now = this.openNow!;
    this.openNow = (name, create) => this.#watched(name, now(name, create));
  }
  override async open(name: string, create: boolean): Promise<File | undefined> {
    return this.#watched(name, await super.open(name, create));
  }
  #watched(name: string, f: File | undefined): File | undefined {
    if (!f) return f;
    const write = f.write.bind(f), truncate = f.truncate.bind(f), flush = f.flush.bind(f);
    f.write = (b, at) => (this.#unflushed.add(name), write(b, at));
    f.truncate = (size) => (this.#unflushed.add(name), truncate(size));
    f.flush = () => {
      if (this.killFlush?.test(name)) throw new Error("killed");
      this.#unflushed.delete(name);
      flush();
    };
    return f;
  }
  async cut(): Promise<void> {
    for (const name of this.#unflushed) {
      const f = (await super.open(name, false))!;
      f.write(new Uint8Array(Math.max(1, f.size())).fill(0xee), 0);
      f.flush();
      f.close();
    }
    this.#unflushed.clear();
    this.crash();
  }
}

// A process killed as it kept something, the latest written but not flushed, then started again and killed as it kept the
// next, over the one before; then power lost: what was kept is not lost, for the latest was made durable as it started.
{
  const volume = new Tearing();
  let s = await opened(volume);
  s.keep("roster", bytes("A", 8)); // durable
  volume.killFlush = /^roster\./;
  assert.throws(() => s.keep("roster", bytes("B", 8)), /killed/);
  s.abandon();
  volume.killFlush = undefined;
  s = await opened(volume);
  assert.deepEqual(s.kept("roster").latest, bytes("B", 8));
  volume.killFlush = /^roster\./;
  assert.throws(() => s.keep("roster", bytes("C", 8)), /killed/); // over A, which was all the disk had
  s.abandon();
  volume.killFlush = undefined;
  await volume.cut();
  s = await opened(volume);
  assert(s.kept("roster").latest !== undefined, "a roster kept was lost, both its files");
  s.letGo();
}

// A process killed with what it wrote to the log not yet flushed, then started again: what the node finds there, and so
// counts on once the log is synced, is durable once it is, though nothing more was written to its segment.
{
  const volume = new Tearing();
  let s = await opened(volume);
  assert(s.logWrite(0, bytes("a", 10))); // never synced
  s.abandon();
  s = await opened(volume);
  assert.equal(read(s, 0), "a".repeat(10));
  assert(s.logSync());
  s.abandon();
  await volume.cut();
  s = await opened(volume);
  assert.equal(read(s, 0), "a".repeat(10), "what a sync said was durable was lost");
  s.letGo();
}

// And so on a disk: as a store opens, the latest of each thing kept is made durable; and the next sync of the log makes
// durable every segment it found.
{
  const dir = mkdtempSync(join(tmpdir(), "zsp-store-"));
  let s = await opened(new NodeVolume(dir));
  for (const what of ["device", "space", "keys", "roster"] as const) s.keep(what, bytes("k", 4)), s.keep(what, bytes("l", 4));
  assert(s.logWrite(0, bytes("a", 10)));
  assert(s.logSync());
  await s.close();
  const fsync = fs.fsyncSync;
  let synced = 0;
  fs.fsyncSync = (fd: number) => (synced++, fsync(fd));
  syncBuiltinESMExports();
  try {
    const began = performance.now();
    s = await opened(new NodeVolume(dir));
    const took = performance.now() - began;
    assert.equal(synced, 4, "the latest of each thing kept was not made durable as the store opened");
    console.log(`     a store opened, the latest of each of four things kept made durable, in ${took.toFixed(1)} ms`);
    synced = 0;
    assert(s.logSync());
    assert(synced >= 1, "a sync of the log made nothing it found durable");
  } finally {
    fs.fsyncSync = fsync;
    syncBuiltinESMExports();
  }
  await s.close();
  rmSync(dir, { recursive: true, force: true });
}

console.log("ok");
