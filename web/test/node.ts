// A device, on its own: what it keeps of itself, what it refuses, and what it does when there is nothing to do.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Node, spaceUrl } from "../src/node.ts";
import { Client, columns } from "../src/client.ts";
import { MemoryVolume, type File } from "../src/volume.ts";
import { loadModule } from "../src/wasm.ts";
import { BIN } from "./procs.ts";

const module = await loadModule();
const TMP = mkdtempSync(join(tmpdir(), "zsp-node-"));

// One that never joined anything closes as well as any.
{
  const node = await Node.open({ volume: new MemoryVolume(), module });
  assert.equal(node.space, undefined);
  assert.equal(node.member, false);
  assert.equal(node.connect(() => {}, () => {}), undefined, "no client before there is a space");
  await node.close();
}

// Its key is its own for good, and so is the space it joins.
{
  const volume = new MemoryVolume();
  const first = await Node.open({ volume, module });
  assert.match(first.key, /^[0-9a-f]{128}$/);
  assert.equal(first.key.slice(0, 64), first.id);
  assert.throws(() => first.join("no", { key: "a".repeat(64), url: "ws://127.0.0.1:1" }));
  first.join("ab".repeat(32), { key: "cd".repeat(32), url: "ws://127.0.0.1:1" });
  assert.throws(() => first.join("ab".repeat(32), { key: "cd".repeat(32), url: "ws://127.0.0.1:1" }), "one space, once");
  await first.close();
  const again = await Node.open({ volume, module });
  assert.equal(again.key, first.key);
  assert.equal(again.space, "ab".repeat(32));
  await again.close();
}

// Nonsense, or a roster that is not its space's, does not make a device of a space; and it can join one after.
{
  const volume = new MemoryVolume();
  const node = await Node.open({ volume, module, log: () => {} });
  const forged = new Uint8Array(200);
  forged.set(new TextEncoder().encode("zsp-r1"));
  crypto.getRandomValues(forged.subarray(6));
  assert(!node.adopt(forged));
  assert.equal(node.space, undefined, "a forged roster made it of a space");
  const owner = join(TMP, "forged-owner");
  const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  execFileSync(BIN, ["admit", owner, node.key, "1"]);
  await node.close();
  const again = await Node.open({ volume, module, log: () => {} });
  assert.equal(again.space, undefined, "and is so after a restart");
  assert(again.adopt(readFileSync(join(owner, space, "roster"))));
  assert.equal(again.space, space);
  await again.close();
}

// By a roster alone, and a member at once.
{
  const owner = join(TMP, "owner");
  const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  const node = await Node.open({ volume: new MemoryVolume(), module });
  execFileSync(BIN, ["admit", owner, node.key, "1"]);
  assert(node.adopt(readFileSync(join(owner, space, "roster"))));
  assert.equal(node.space, space);
  assert(node.member);
  assert(!node.adopt(new Uint8Array(100)), "nonsense is not a roster");
  await node.close();
}

// What it cannot keep of the space, it does not go on without: keys it could not keep would be lost at the next start, and
// with them everything sealed under them, so the change is refused, the node stops, and nothing more is said durable.
{
  let failing = false;
  const order: string[] = [];
  class Failing extends MemoryVolume {
    close() {
      order.push("files let go of");
    }
    override async open(name: string, create: boolean): Promise<File | undefined> {
      const f = await super.open(name, create);
      if (!f || !/^(keys|roster)\./.test(name)) return f;
      const write = f.write.bind(f);
      f.write = (b, at) => {
        if (failing) throw new Error("the disk is full");
        return write(b, at);
      };
      return f;
    }
  }
  const volume = new Failing();
  volume.openNow = undefined; // through open, which is watched
  const node = await Node.open({ volume, module, log: () => {} });
  let failure: Error | undefined;
  node.onFailure = (e) => ((failure = e), order.push("told"));
  node.create();
  const client = new Client({ connect: node.connect });
  while (!client.may(1, "write")) await new Promise((done) => setTimeout(done, 1));
  failing = true;
  assert.throws(() => node.scope(true), /storage has failed/);
  let durable = false;
  void client.write(1, (change) => change.insert({}, "x", 1, {})).then(() => (durable = true));
  await new Promise((done) => setTimeout(done, 300));
  assert(failure, "it says that it has stopped");
  assert.deepEqual(order, ["files let go of", "told"], "it said so before its files were let go of, which whoever is told may want");
  assert(!durable, "and says nothing more is durable");
  assert.throws(() => node.member, /storage/, "and answers nothing it would make up");
  assert.throws(() => node.members());
  client.close();
}

// And it says so at once, though files are still being opened, which a full disk may keep from ever being done: it lets
// go of what it has open, and what is opened after is let go of as it comes.
{
  let failing = false;
  class Failing extends MemoryVolume {
    override async open(name: string, create: boolean): Promise<File | undefined> {
      const f = await super.open(name, create);
      if (!f || !/^(keys|roster)\./.test(name)) return f;
      const write = f.write.bind(f);
      f.write = (b, at) => {
        if (failing) throw new Error("the disk is full");
        return write(b, at);
      };
      return f;
    }
  }
  const volume = new Failing({ slow: true });
  const settling = setInterval(() => volume.settle(), 1);
  const node = await Node.open({ volume, module, log: () => {} });
  let failure: Error | undefined;
  node.onFailure = (e) => (failure = e);
  node.create(); // which writes, and so opens segments ahead, in the volume's own time
  while (volume.waiting === 0) await new Promise((done) => setTimeout(done, 1));
  clearInterval(settling); // and now nothing more is opened
  failing = true;
  assert.throws(() => node.scope(true), /storage has failed/);
  await new Promise((done) => setTimeout(done, 100));
  assert(failure, "it waited for files being opened to say it had stopped");
}

// Closed twice, it is closed once, and the second waits for the first: for what is being opened to be, and its files to be
// let go of.
{
  const volume = new MemoryVolume({ slow: true });
  const settling = setInterval(() => volume.settle(), 1);
  const node = await Node.open({ volume, module, log: () => {} });
  clearInterval(settling);
  node.create(); // which writes, and so opens segments ahead, in the volume's own time
  const first = node.close();
  let second = false;
  void node.close().then(() => (second = true));
  await new Promise((done) => setTimeout(done, 50));
  assert(!second, "the second close was done before the first");
  const letting = setInterval(() => volume.settle(), 1);
  await first;
  clearInterval(letting);
  await new Promise((done) => setTimeout(done, 0));
  assert(second);
}

// One client of a device that begins to look while another of its clients is typing sees what was typed before it
// looked, and the rest as it is typed: not once the piece is sealed, a second after it began; though it is sent more
// first than its pipe takes at once of live text.
{
  const node = await Node.open({ volume: new MemoryVolume(), module, log: () => {} });
  node.create();
  const writer = new Client({ connect: node.connect }), reader = new Client({ connect: node.connect });
  while (!writer.may(1, "write") || !reader.may(1, "read")) await new Promise((done) => setTimeout(done, 1));
  const Note = { body: columns.text(17), more: columns.string(18) };
  let id = "";
  // Behind more than a pipe takes at once of live text: the reader is sent all of these first.
  await writer.write(1, (change) => {
    for (let i = 0; i < 40; i++) change.insert(Note, "late", i, { more: "x".repeat(512) });
  });
  await writer.write(1, (change) => (id = change.insert(Note, "late", 100, {})));
  const editor = writer.text(id, Note.body);
  editor.append("typed before it looked");
  await new Promise((done) => setTimeout(done, 200));
  let shown: string | undefined;
  const looked = Date.now();
  const w = reader.window({ scope: 1, list: "late", table: Note, size: 100 }, (state) => (shown = state.rows.find((r) => r.id === id)?.body));
  while (shown !== "typed before it looked" && Date.now() - looked < 5000) await new Promise((done) => setTimeout(done, 1));
  assert(Date.now() - looked < 500, `shown ${Date.now() - looked} ms after looking: once sealed, not live`);
  editor.close();
  w.stop();
  writer.close();
  reader.close();
  await node.close();
}

// A relay that cannot even be dialled, as a ws:// one from an https:// page cannot, is tried again soon, as any is.
{
  let dials = 0;
  class Refused {
    constructor() {
      dials++;
      throw new DOMException("refused", "SecurityError");
    }
  }
  const node = await Node.open({ volume: new MemoryVolume(), module, log: () => {}, WebSocket: Refused as unknown as typeof WebSocket });
  node.join("ab".repeat(32), { key: "cd".repeat(32), url: "ws://127.0.0.1:1" });
  await new Promise((done) => setTimeout(done, 1500));
  assert(dials >= 3, `dialled ${dials} times in a second and a half`);
  await node.close();
}

// Nothing is said in text by a relay but "pong": one that says anything else is not gone on with, but dialled again.
{
  let dials = 0;
  class Chatty extends EventTarget {
    binaryType = "arraybuffer";
    readyState = 0;
    bufferedAmount = 0;
    onopen: (() => void) | null = null;
    onmessage: ((e: { data: unknown }) => void) | null = null;
    onclose: (() => void) | null = null;
    onerror: (() => void) | null = null;
    constructor() {
      super();
      dials++;
      setTimeout(() => {
        this.readyState = 1;
        this.onopen?.();
        this.onmessage?.({ data: "hello" });
      }, 1);
    }
    send() {}
    close() {
      this.readyState = 3;
    }
  }
  const node = await Node.open({ volume: new MemoryVolume(), module, log: () => {}, WebSocket: Chatty as unknown as typeof WebSocket });
  node.join("ab".repeat(32), { key: "cd".repeat(32), url: "ws://127.0.0.1:1" });
  await new Promise((done) => setTimeout(done, 1000));
  assert(dials >= 2, `a relay that chatted in text was gone on with: dialled ${dials} times`);
  await node.close();
}

// A partial replica with nothing to do but, in a month, let go of what it no longer watches sets no timer for longer than
// a timer can be set for: one that is goes off at once, and again, and again.
{
  const owner = join(TMP, "keep-owner");
  const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  const node = await Node.open({ volume: new MemoryVolume(), module, full: false, log: () => {} });
  execFileSync(BIN, ["admit", owner, node.key, "1"]);
  const longest: number[] = [];
  const set = globalThis.setTimeout;
  globalThis.setTimeout = ((f: () => void, ms?: number) => (longest.push(ms ?? 0), set(f, ms))) as typeof setTimeout;
  try {
    assert(node.adopt(readFileSync(join(owner, space, "roster"))));
    const c = new Client({ connect: node.connect });
    while (!c.may(1, "write")) await new Promise((done) => set(done, 10));
    await c.write(1, (change) => change.insert({}, "x", 1, {}));
    c.close();
    await new Promise((done) => set(done, 300));
  } finally {
    globalThis.setTimeout = set;
  }
  assert(longest.length > 0 && longest.every((ms) => ms <= 2 ** 31 - 1), `timers set for ${Math.max(...longest)} ms`);
  assert(longest.length < 50, `${longest.length} timers set while there was nothing to do`);
  await node.close();
}

// What it keeps is said in days and bytes, of none or more.
for (const keep of [{ days: -1 }, { bytes: -5 }, { days: NaN }, { bytes: Infinity }]) {
  await assert.rejects(Node.open({ volume: new MemoryVolume(), module, full: false, keep, log: () => {} }), RangeError);
}

// Where a relay keeps a space, a proxy's query staying at the end.
assert.equal(spaceUrl("wss://relay.example/", "ab"), "wss://relay.example/ab");
assert.equal(spaceUrl("wss://relay.example/zsp?key=1", "ab"), "wss://relay.example/zsp/ab?key=1");

rmSync(TMP, { recursive: true, force: true });
console.log("ok");
