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

// A change to the space whose keys could not be kept is not done at all: not kept, roster and all, to be found done at the
// next start though it was said to have failed.
{
  let failing = false;
  class Failing extends MemoryVolume {
    override async open(name: string, create: boolean): Promise<File | undefined> {
      const f = await super.open(name, create);
      if (!f || !/^keys\./.test(name)) return f;
      const write = f.write.bind(f);
      f.write = (b, at) => {
        if (failing) throw new Error("the disk is full");
        return write(b, at);
      };
      return f;
    }
  }
  const volume = new Failing();
  volume.openNow = undefined;
  const node = await Node.open({ volume, module, log: () => {} });
  node.create();
  failing = true;
  assert.throws(() => node.scope(), /storage has failed/);
  failing = false;
  const again = await Node.open({ volume, module, log: () => {} });
  assert.equal(again.scope(), 2, "the scope said not to have been made was made, its keys never kept");
  await again.close();
}

// A change to the space whose roster was kept is done, though storage failed after: what is said of it is what the next
// start finds.
{
  let failing = false;
  class Failing extends MemoryVolume {
    override async open(name: string, create: boolean): Promise<File | undefined> {
      const f = await super.open(name, create);
      if (!f || name !== "tree") return f;
      const write = f.write.bind(f);
      f.write = (b, at) => (failing ? (() => { throw new Error("the disk is full"); })() : write(b, at));
      return f;
    }
  }
  const volume = new Failing();
  volume.openNow = undefined;
  const node = await Node.open({ volume, module, log: () => {} });
  node.create();
  failing = true;
  let said: number | string;
  try {
    said = node.scope();
  } catch (e) {
    said = "error: " + (e as Error).message;
  }
  failing = false;
  const again = await Node.open({ volume, module, log: () => {} });
  const next = again.scope();
  assert(said === 2 ? next === 3 : next === 2, `said ${said}, and the next start made scope ${next}`);
  await again.close();
}

// A space whose first roster could not be kept is not this device's: it may make another, rather than be of one it can
// never be a member of.
{
  let failing = false;
  class Failing extends MemoryVolume {
    override async open(name: string, create: boolean): Promise<File | undefined> {
      const f = await super.open(name, create);
      if (!f || !/^roster\./.test(name)) return f;
      const write = f.write.bind(f);
      f.write = (b, at) => (failing ? (() => { throw new Error("the disk is full"); })() : write(b, at));
      return f;
    }
  }
  const volume = new Failing();
  volume.openNow = undefined;
  const node = await Node.open({ volume, module, log: () => {} });
  failing = true;
  assert.throws(() => node.create(), /storage failed/);
  assert.equal(node.space, undefined, "it says it is of a space it never kept, though only until it stops");
  const settled = await Promise.race([node.settled().then(() => "settled"), new Promise((done) => setTimeout(() => done("waiting"), 500))]);
  assert.equal(settled, "settled", "a node that has stopped is never settled");
  failing = false;
  const again = await Node.open({ volume, module, log: () => {} });
  assert.equal(again.space, undefined, "the device is of a space whose roster it never kept");
  assert.match(again.create(), /^[0-9a-f]{64}$/);
  assert(again.member);
  await again.close();
  // And so for a space adopted by its roster alone.
  const owner = join(TMP, "unkept-owner");
  const sid = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  const fresh = new Failing();
  fresh.openNow = undefined;
  const adopting = await Node.open({ volume: fresh, module, log: () => {} });
  execFileSync(BIN, ["admit", owner, adopting.key, "1"]);
  failing = true;
  assert.equal(adopting.adopt(readFileSync(join(owner, sid, "roster"))), false);
  assert.equal(adopting.space, undefined, "it says it is of a space whose roster it never kept");
  failing = false;
  const later = await Node.open({ volume: fresh, module, log: () => {} });
  assert.equal(later.space, undefined);
  assert(later.adopt(readFileSync(join(owner, sid, "roster"))));
  assert.equal(later.space, sid);
  await later.close();
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

// A pipe waiting for room is given its turn after whatever else is waiting, and that holds nothing else back: not when
// a timer would take a minute to go off, as a browser makes one take in a tab hidden for long, nor four milliseconds, as
// it makes one set from another take. A client that comes meanwhile is answered at once.
{
  const node = await Node.open({ volume: new MemoryVolume(), module, log: () => {} });
  node.create();
  const writer = new Client({ connect: node.connect });
  while (!writer.may(1, "write")) await new Promise((done) => setTimeout(done, 1));
  await writer.write(1, (change) => {
    for (let i = 0; i < 400; i++) change.insert({ more: columns.string(18) }, "big", i, { more: "x".repeat(2048) });
  });
  const set = globalThis.setTimeout;
  let held = 0;
  globalThis.setTimeout = ((f: () => void, ms?: number) => (ms ? set(f, ms) : (held++, set(f, 60000)))) as typeof setTimeout;
  let answered = -1;
  const reader = new Client({ connect: node.connect, after: (ms, f) => ((t) => () => clearTimeout(t))(set(f, ms)) });
  let late: Client | undefined;
  const asked = performance.now();
  const w = reader.window({ scope: 1, list: "big", table: { more: columns.string(18) }, size: 400 }, (state) => {
    // More than a pipe takes at once is on its way to the reader, which waits its turn for the rest: another comes now.
    if (state.rows.length > 0 && !late) {
      late = new Client({ connect: node.connect, after: (ms, f) => ((t) => () => clearTimeout(t))(set(f, ms)) });
      late.on("status", (ready) => ready && answered < 0 && (answered = performance.now() - asked));
    }
  });
  try {
    for (const t = performance.now(); answered < 0 && performance.now() - t < 5000; ) await new Promise((done) => set(done, 5));
  } finally {
    globalThis.setTimeout = set;
  }
  assert(late, "the reader was sent nothing");
  assert(answered >= 0 && answered < 1000, `a client that came while another waited for room was answered ${answered < 0 ? "not at all" : `after ${answered.toFixed(0)} ms`}`);
  assert.equal(held, 0, "a turn was waited for by a timer");
  w.stop();
  reader.close();
  late.close();
  writer.close();
  await node.close();
}

// A credential given as the old one expires is presented to a relay not yet letting the device in, which is dialled
// again for it at once, however long it would otherwise have waited to try again.
{
  const dialled: number[] = [];
  class Silent extends EventTarget {
    binaryType = "arraybuffer";
    readyState = 0;
    bufferedAmount = 0;
    onopen: (() => void) | null = null;
    onmessage: ((e: { data: unknown }) => void) | null = null;
    onclose: (() => void) | null = null;
    onerror: (() => void) | null = null;
    constructor() {
      super();
      dialled.push(performance.now());
      setTimeout(() => ((this.readyState = 1), this.onopen?.()), 1); // and then says nothing, as one judging a credential
    }
    send() {}
    close() {
      this.readyState = 3;
    }
  }
  const node = await Node.open({ volume: new MemoryVolume(), module, log: () => {}, credential: "old", WebSocket: Silent as unknown as typeof WebSocket });
  node.join("ab".repeat(32), { key: "cd".repeat(32), url: "ws://127.0.0.1:1" });
  await new Promise((done) => setTimeout(done, 100));
  assert.equal(dialled.length, 1);
  const given = performance.now();
  node.setCredential("new");
  await new Promise((done) => setTimeout(done, 100));
  assert.equal(dialled.length, 2, "not dialled again for the new credential");
  assert(dialled[1] - given < 50, `dialled again ${(dialled[1] - given).toFixed(0)} ms after`);
  await node.close();
  assert.throws(() => node.setCredential("later"), /closed/);
}

// What it keeps is said in days and bytes, of none or more.
for (const keep of [{ days: -1 }, { bytes: -5 }, { days: NaN }, { bytes: Infinity }, { days: 1e15 }, { bytes: 2 ** 60 }]) {
  await assert.rejects(Node.open({ volume: new MemoryVolume(), module, full: false, keep, log: () => {} }), RangeError);
}

// A browser's device, closed twice, or twice at once, is closed once: its node stopped before its worker goes, and neither
// close waits for ever. (With a worker of nothing but what the device says to it.)
{
  let terminated = false, closes = 0, release!: () => void;
  const finished = new Promise<void>((done) => (release = done));
  let closed = false;
  class FakeWorker {
    onmessage: ((e: { data: unknown }) => void) | null = null;
    onerror: unknown = null;
    postMessage(msg: { ask?: number; op?: string }) {
      if (terminated || msg.ask === undefined) return;
      const answer = (value?: unknown) => queueMicrotask(() => terminated || this.onmessage?.({ data: { answer: msg.ask, value } }));
      if (msg.op === "identity") answer({ id: "a", key: "b" });
      else if (msg.op === "close") {
        closes++;
        void finished.then(() => ((closed = true), answer()));
      }
    }
    terminate() {
      assert(closed, "the worker went before its node was stopped");
      terminated = true;
    }
  }
  const was = (globalThis as { Worker?: unknown }).Worker;
  (globalThis as { Worker?: unknown }).Worker = FakeWorker;
  try {
    const { open } = await import("../src/browser.ts");
    const device = await open();
    const both = Promise.all([device.close(), device.close()]);
    release();
    const over = await Promise.race([both.then(() => "closed"), new Promise((done) => setTimeout(() => done("waiting"), 500))]);
    assert.equal(over, "closed");
    assert.equal(await Promise.race([device.close().then(() => "closed"), new Promise((done) => setTimeout(() => done("waiting"), 500))]), "closed");
    assert.equal(closes, 1);
  } finally {
    (globalThis as { Worker?: unknown }).Worker = was;
  }
}

// A node that cannot be opened lets go of what it opened, and of the UDP it was given: a file left open would hold the
// store against the next to open it, as a browser's are held.
{
  let opened = 0, closed = 0, udpClosed = false;
  class Full extends MemoryVolume {
    override async open(name: string, create: boolean): Promise<File | undefined> {
      const f = await super.open(name, create);
      if (!f) return f;
      opened++;
      const close = f.close.bind(f);
      f.close = () => (closed++, close());
      if (name.startsWith("device.")) f.write = () => { throw new Error("the disk is full"); };
      return f;
    }
  }
  const datagrams = { port: 1, listen() {}, send() {}, interfaces: () => [], close: () => (udpClosed = true) };
  await assert.rejects(Node.open({ volume: new Full(), module, datagrams, log: () => {} }), /full/);
  assert(opened > 0);
  assert.equal(closed, opened, "files it opened were left open");
  assert(udpClosed, "the UDP it was given was left open");
  udpClosed = false;
  let volumeClosed = false;
  const refused: MemoryVolume & { close?: () => void } = new MemoryVolume();
  refused.close = () => void (volumeClosed = true);
  await assert.rejects(Node.open({ volume: refused, module, datagrams, keep: { days: -1 } }), RangeError);
  assert(udpClosed, "the UDP it was given was left open, though it refused what it was told to keep");
  assert(volumeClosed, "the volume it was given was left open, though it refused what it was told to keep");
}

// One client that throws at what it is told does not keep the node's clients from being told the rest of theirs, itself
// included; and what it threw is thrown, once all are told.
{
  const node = await Node.open({ volume: new MemoryVolume(), module, log: () => {} });
  node.create();
  let throwing = false;
  const thrown: unknown[] = [];
  const catching = (e: unknown) => thrown.push(e);
  process.on("uncaughtException", catching);
  const Note = { title: columns.string(16), more: columns.bytes(18) };
  const fail = (): never => {
    throw new Error("the application's own");
  };
  // It throws once, at the first piece of a row bigger than the node sends at once: the rest is sent it in the same turn.
  const first = new Client({ connect: (receive, closed) => node.connect((data) => (receive(data), throwing && data.length > 32 << 10 && ((throwing = false), fail())), closed) });
  const second = new Client({ connect: node.connect });
  const writer = new Client({ connect: node.connect });
  const seen = [0, 0];
  const windows = [first, second].map((c, k) => c.window({ scope: 1, list: "n", table: Note }, (st) => (seen[k] = st.rows.length)));
  while (!writer.may(1, "write") || !first.ready || !second.ready) await new Promise((done) => setTimeout(done, 1));
  await new Promise((done) => setTimeout(done, 50));
  let lost = 0;
  for (const c of [first, second]) c.on("status", (ready) => !ready && lost++);
  throwing = true;
  let written = false;
  void writer.write(1, (change) => change.insert(Note, "n", 1, { title: "one", more: new Uint8Array(200 << 10).fill(1) })).then(() => (written = true));
  for (let i = 0; i < 400 && !(written && seen.join() === "1,1"); i++) await new Promise((done) => setTimeout(done, 5));
  process.off("uncaughtException", catching);
  assert(written, "the writer was never told its write was durable, another client having thrown");
  assert.deepEqual(seen, [1, 1], "a client was never told the rest, one having thrown");
  assert.equal(lost, 0, "what was for a client was dropped, one having thrown, and its pipe broke on what it was told after");
  assert.equal(thrown.length, 1, "what it threw was not thrown");
  windows.forEach((w) => w.stop());
  first.close(), second.close(), writer.close();
  await node.close();
}

// What a link straight to another device has to say once what it acknowledges is durable is said then: not when something
// else next happens, which may be never.
{
  const loopback = Uint8Array.of(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1);
  const peers = new Map<number, (ip: Uint8Array, port: number, data: Uint8Array) => void>();
  const datagrams = (port: number, out?: Uint8Array[]) => ({
    port,
    listen: (f: (ip: Uint8Array, port: number, data: Uint8Array) => void) => void peers.set(port, f),
    send: (_ip: Uint8Array, to: number, data: Uint8Array) => {
      out?.push(data);
      const f = peers.get(to);
      if (f) queueMicrotask(() => f(loopback, port, data));
      else if (to === 9083) for (const [p, g] of peers) if (p !== port) queueMicrotask(() => g(loopback, port, data)); // a beacon
    },
    interfaces: () => [{ ip: loopback, broadcast: Uint8Array.of(127, 0, 0, 1) }],
    close: () => void peers.delete(port),
  });
  const fromB: Uint8Array[] = [];
  const a = await Node.open({ module, volume: new MemoryVolume(), datagrams: datagrams(40011), log: () => {} });
  const b = await Node.open({ module, volume: new MemoryVolume(), datagrams: datagrams(40012, fromB), log: () => {} });
  a.create();
  a.admit(b.key, 1);
  assert(b.adopt(a.store.kept("roster").latest!));
  const ca = new Client({ connect: a.connect }), cb = new Client({ connect: b.connect });
  const T = { v: columns.string(16) };
  let got = 0;
  const w = cb.window({ scope: 1, list: "udp", table: T, size: 10 }, (st) => (got = st.rows.length));
  while (!ca.may(1, "write") || !cb.ready) await new Promise((done) => setTimeout(done, 1));
  await new Promise((done) => setTimeout(done, 300)); // linked
  await ca.write(1, (change) => change.insert(T, "udp", 1, { v: "x".repeat(3000) })); // more than a packet
  for (let i = 0; i < 200 && got === 0; i++) await new Promise((done) => setTimeout(done, 5));
  assert.equal(got, 1, "not had over the link");
  await new Promise((done) => setTimeout(done, 400));
  const before = fromB.length;
  b.connect(() => {}, () => {})!.close(); // something else happens on b, which says nothing over the link of itself
  await new Promise((done) => setTimeout(done, 100));
  assert.equal(fromB.length, before, `${fromB.length - before} packets were waiting to be said until something else happened`);
  w.stop(), ca.close(), cb.close();
  await a.close();
  await b.close();
}

// A device in Node whose node could not be compiled tries again the next time, rather than failing for ever; and one that
// cannot be opened leaves no socket open.
{
  const { open: openDevice } = await import("../src/nodejs.ts");
  const udp = () => process.getActiveResourcesInfo().filter((r) => r === "UDPWrap").length;
  const compile = WebAssembly.compile;
  WebAssembly.compile = () => Promise.reject(new Error("out of memory"));
  try {
    await assert.rejects(openDevice({ dir: join(TMP, "nodejs-a"), udp: false }), /out of memory/);
  } finally {
    WebAssembly.compile = compile;
  }
  const d = await openDevice({ dir: join(TMP, "nodejs-a"), udp: false });
  await d.close();
  const sockets = udp();
  await assert.rejects(openDevice({ dir: join(TMP, "nodejs-b"), keep: { days: -1 } }), RangeError);
  await new Promise((done) => setTimeout(done, 50));
  assert.equal(udp(), sockets, "a device that could not be opened left its sockets open");
}

// A browser's device whose worker cannot open it lets go of the worker, which would hold whatever it had of the store.
{
  let terminated = false;
  class Failing {
    onmessage: ((e: { data: unknown }) => void) | null = null;
    onerror: unknown = null;
    postMessage(msg: { ask?: number }) {
      if (msg.ask !== undefined) queueMicrotask(() => this.onmessage?.({ data: { failed: "the origin's file system is not there" } }));
    }
    terminate() {
      terminated = true;
    }
  }
  const was = (globalThis as { Worker?: unknown }).Worker;
  (globalThis as { Worker?: unknown }).Worker = Failing;
  try {
    const { open } = await import("../src/browser.ts");
    await assert.rejects(open(), /file system/);
    assert(terminated, "the worker was left running");
  } finally {
    (globalThis as { Worker?: unknown }).Worker = was;
  }
}

// Where a relay keeps a space, a proxy's query staying at the end.
assert.equal(spaceUrl("wss://relay.example/", "ab"), "wss://relay.example/ab");
assert.equal(spaceUrl("wss://relay.example/zsp?key=1", "ab"), "wss://relay.example/zsp/ab?key=1");

rmSync(TMP, { recursive: true, force: true });
console.log("ok");
