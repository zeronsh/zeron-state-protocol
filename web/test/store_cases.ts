// The store's journal, case by case: what is dropped or cut short stays so through a crash, and what a segment's file
// was given after the journal last spoke of it is not written over. Files open in their own time here, as a browser's do.

import assert from "node:assert/strict";
import { Store } from "../src/store.ts";
import { mkdtempSync, rmSync } from "node:fs";
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

console.log("ok");
