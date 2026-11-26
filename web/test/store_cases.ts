// The store's journal, case by case: what is dropped or cut short stays so through a crash, and what a segment's file
// was given after the journal last spoke of it is not written over. Files open in their own time here, as a browser's do.

import assert from "node:assert/strict";
import { Store } from "../src/store.ts";
import { MemoryVolume } from "../src/volume.ts";

const SEGMENT = 1000;
const bytes = (ch: string, n: number) => new TextEncoder().encode(ch.repeat(n));
const turn = () => new Promise((done) => setTimeout(done, 0));

// Opens a store, letting what it waits to open be opened meanwhile.
async function opened(volume: MemoryVolume): Promise<Store> {
  const settling = setInterval(() => volume.settle(), 1);
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

console.log("ok");
