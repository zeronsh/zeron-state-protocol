// The store's journal, case by case: what is dropped or cut short stays so through a crash, and what a segment's file
// was given after the journal last spoke of it is not written over. Files open in their own time here, as a browser's do.

import assert from "node:assert/strict";
import { Store } from "../src/store.ts";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { MemoryVolume, type Volume } from "../src/volume.ts";
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

console.log("ok");
