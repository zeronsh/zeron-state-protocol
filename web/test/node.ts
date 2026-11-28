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
import { timerInternals } from "../src/timers.ts";
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

// A scope is named by the number it is, and one the space has: 2^32 is not 0, which is every scope, nor 2^32 + 1 scope 1,
// nor 1.5 scope 1; and a scope the space has not is no scope to admit to or revoke from.
{
  const node = await Node.open({ volume: new MemoryVolume(), module, log: () => {} });
  const other = await Node.open({ volume: new MemoryVolume(), module, log: () => {} });
  node.create();
  node.admit(other.key, 1);
  const grants = () => JSON.stringify([...node.members().find((m) => m.id === other.id)!.grants]);
  const before = grants();
  for (const scope of [2 ** 32, 2 ** 32 + 1, 1.5, -1, NaN, Infinity]) {
    assert.throws(() => node.revoke(other.key, scope), RangeError, `revoke from ${scope}`);
    assert.throws(() => node.admit(other.key, scope), RangeError, `admit to ${scope}`);
  }
  assert.throws(() => node.admit(other.key, 0), RangeError, "admit to every scope");
  assert.throws(() => node.admit(other.key, 99), /no such member, or no sense/, "admit to a scope the space has not");
  assert.throws(() => node.revoke(other.key, 99), /no such member, or no sense/, "revoke from a scope the space has not");
  assert.equal(grants(), before, "what it may do was changed by a scope that is none");
  node.revoke(other.key, 1);
  assert.notEqual(grants(), before, "and a scope it has is revoked from as ever");
  await other.close();
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
  // But whoever would open the store next must wait for them, or find them held: it is closed, as its worker waits for
  // before it lets go of the store's lock, only once they are had, and closed as they come.
  let closed = false;
  void node.close().then(() => (closed = true));
  await new Promise((done) => setTimeout(done, 20));
  assert(!closed, "said to be closed with files still being opened");
  while (volume.waiting > 0) volume.settle(), await new Promise((done) => setTimeout(done, 1));
  await new Promise((done) => setTimeout(done, 0));
  assert(closed, "not closed once nothing was being opened");
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
  // Clients in Node keep time by setTimeout, which nothing holds back here: they take no share of a page's timer worker.
  assert.deepEqual(timerInternals(), { worker: false, broken: false, users: 0, pending: 0 });
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

// A UDP send that throws, as Node's does for a port of 0 that a peer may say it is at, is a packet lost: not a node stopped,
// nor one left in the midst of a tick, never settled again. And UDP refuses what it is told that is no address, before it
// binds anything.
{
  const loopback = Uint8Array.of(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1);
  const peers = new Map<number, (ip: Uint8Array, port: number, data: Uint8Array) => void>();
  let thrown = 0;
  const datagrams = (port: number, throwing: boolean) => ({
    port,
    listen: (f: (ip: Uint8Array, port: number, data: Uint8Array) => void) => void peers.set(port, f),
    send: (_ip: Uint8Array, to: number, data: Uint8Array) => {
      if (throwing) {
        thrown++;
        throw new RangeError("ERR_SOCKET_BAD_PORT");
      }
      if (to === 9083) for (const [p, g] of peers) if (p !== port) queueMicrotask(() => g(loopback, port, data));
    },
    interfaces: () => [{ ip: loopback, broadcast: Uint8Array.of(127, 0, 0, 1) }],
    close: () => void peers.delete(port),
  });
  const a = await Node.open({ module, volume: new MemoryVolume(), datagrams: datagrams(40021, false), log: () => {} });
  const b = await Node.open({ module, volume: new MemoryVolume(), datagrams: datagrams(40022, true), log: () => {} });
  let failed: Error | undefined;
  b.onFailure = (e) => (failed = e);
  a.create();
  a.admit(b.key, 1);
  assert(b.adopt(a.store.kept("roster").latest!));
  const cb = new Client({ connect: b.connect });
  while (!cb.may(1, "write")) await new Promise((done) => setTimeout(done, 1));
  await new Promise((done) => setTimeout(done, 300)); // beacons heard, and answered, by a send that throws
  assert(thrown > 0, "b never sent");
  assert.equal(failed, undefined, "a send that threw stopped the node");
  await cb.write(1, (change) => change.insert({}, "x", 1, {}));
  const settled = await Promise.race([b.settled().then(() => "settled"), new Promise((done) => setTimeout(() => done("waiting"), 1000))]);
  assert.equal(settled, "settled", "a send that threw left the node never settled");
  cb.close();
  await a.close();
  await b.close();
  const { nodeDatagrams } = await import("../src/udp-node.ts");
  const udp = () => process.getActiveResourcesInfo().filter((r) => r === "UDPWrap").length;
  const before = udp();
  for (const stun of ["127.0.0.1:0", "127.0.0.1:abc", "127.0.0.1:70000", "nowhere"]) await assert.rejects(nodeDatagrams({ stun }), RangeError, stun);
  await assert.rejects(nodeDatagrams({ port: -1 }), RangeError);
  await new Promise((done) => setTimeout(done, 50));
  assert.equal(udp(), before, "UDP that refused what it was told left sockets bound");
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

// A device revoked is answered no more over UDP, however well it was known: once the link it had is gone, it says where it
// is, or knocks, and is told nothing, nor learns of any roster after it.
{
  const owner = join(TMP, "revoking-owner");
  const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  // Two ports on one network of nothing: broadcasts reach the other, and the test sees what goes where.
  const ip = Uint8Array.of(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1);
  const hear = new Map<number, (ip: Uint8Array, port: number, data: Uint8Array) => void>();
  const sent: { from: number; to: number; type: number }[] = [];
  let toB = 0; // when a last sent b anything
  const datagrams = (port: number) => ({
    port,
    interfaces: () => [{ ip, broadcast: Uint8Array.of(127, 0, 0, 255) }],
    send(_to: Uint8Array, to: number, data: Uint8Array) {
      const at = to === 9083 ? (port === 40001 ? 40002 : 40001) : to;
      sent.push({ from: port, to: at, type: data[0] });
      if (port === 40001 && at === 40002) toB = Date.now();
      const receive = hear.get(at);
      if (receive) queueMicrotask(() => receive(ip, port, data.slice()));
    },
    listen(receive: (ip: Uint8Array, port: number, data: Uint8Array) => void) {
      hear.set(port, receive);
    },
    close() {
      hear.delete(port);
    },
  });
  const until = async (what: string, f: () => boolean, within = 5000) => {
    for (const end = Date.now() + within; !f(); await new Promise((done) => setTimeout(done, 10))) {
      if (Date.now() > end) throw new Error("never: " + what);
    }
  };
  const a = await Node.open({ volume: new MemoryVolume(), module, datagrams: datagrams(40001), log: () => {} });
  const kept = new MemoryVolume();
  const b = await Node.open({ volume: kept, module, datagrams: datagrams(40002), log: () => {} });
  execFileSync(BIN, ["admit", owner, a.key, "1"]);
  execFileSync(BIN, ["admit", owner, b.key, "1"]);
  const first = readFileSync(join(owner, space, "roster"));
  assert(a.adopt(first) && b.adopt(first));
  await until("a links to b directly", () => sent.some((p) => p.from === 40001 && p.to === 40002 && p.type === 0x43));
  // Gone, as a process is, before it is revoked: so that it is told nothing then, on the session it had.
  await b.close();
  execFileSync(BIN, ["revoke", owner, b.key]);
  const c = await Node.open({ volume: new MemoryVolume(), module, log: () => {} });
  execFileSync(BIN, ["admit", owner, c.key, "1"]);
  execFileSync(BIN, ["subject", owner, c.key, "after b"]);
  assert(a.adopt(readFileSync(join(owner, space, "roster"))));
  // What its session there says as it ends goes unanswered, and the link with it, in LINK_DEAD: after which a probes no
  // more, as it would at least every PROBE_MOST while it had it.
  await until("a lets go of its link to b", () => Date.now() - toB > 4000, 30_000);
  sent.length = 0;
  const again = await Node.open({ volume: kept, module, datagrams: datagrams(40002), log: () => {} });
  await until("b says where it is", () => sent.some((p) => p.from === 40002 && p.to === 40001));
  await new Promise((done) => setTimeout(done, 1000));
  const answered = sent.filter((p) => p.from === 40001 && p.to === 40002 && (p.type === 0x41 || p.type === 0x42));
  assert.equal(answered.length, 0, "a revoked device was knocked for, or answered");
  assert(!again.members().some((m) => m.subject === "after b"), "a revoked device learned of a roster after it");
  await Promise.all([a.close(), again.close(), c.close()]);
}

// A member that says it is at port 0, or anywhere that is nobody, is sent nothing there: it is knocked for only where it
// could be.
{
  const owner = join(TMP, "nowhere-owner");
  const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  const ip = Uint8Array.of(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1);
  const hear = new Map<number, (ip: Uint8Array, port: number, data: Uint8Array) => void>();
  const sent: number[] = []; // ports a sent to
  // b says it is at port 0, and the network of nothing carries what it says from 40002.
  const datagrams = (port: number, says: number) => ({
    port: says,
    interfaces: () => [{ ip, broadcast: Uint8Array.of(127, 0, 0, 255) }],
    send(_to: Uint8Array, to: number, data: Uint8Array) {
      const at = to === 9083 ? (port === 40001 ? 40002 : 40001) : to;
      if (port === 40001) sent.push(at);
      const receive = hear.get(at);
      if (receive) queueMicrotask(() => receive(ip, port, data.slice()));
    },
    listen(receive: (ip: Uint8Array, port: number, data: Uint8Array) => void) {
      hear.set(port, receive);
    },
    close() {
      hear.delete(port);
    },
  });
  // a dials, being the lesser key: so that, hearing b, it knocks where b says it is.
  let a: Node, b: Node;
  for (;;) {
    a = await Node.open({ volume: new MemoryVolume(), module, datagrams: datagrams(40001, 40001), log: () => {} });
    b = await Node.open({ volume: new MemoryVolume(), module, datagrams: datagrams(40002, 0), log: () => {} });
    if (a.id < b.id) break;
    await Promise.all([a.close(), b.close()]);
  }
  execFileSync(BIN, ["admit", owner, a.key, "1"]);
  execFileSync(BIN, ["admit", owner, b.key, "1"]);
  const roster = readFileSync(join(owner, space, "roster"));
  assert(a.adopt(roster) && b.adopt(roster));
  await new Promise((done) => setTimeout(done, 1000));
  assert(!sent.includes(0), `sent to port 0: ${sent.filter((p) => p === 0).length} packets`);
  await Promise.all([a.close(), b.close()]);
}

// While the way to the relay is full, what a link it carries would send waits in the link, unsent: not handed on to be
// dropped, which the link would take for the path's congestion and send again. Not one packet of a burst sent while the
// WebSocket says it is full is dropped by the node. (What either burst costs on the wire is no measure of that: a link
// whose acknowledgements are late, as a busy machine's are, may send a packet again, with or without anything held.)
{
  const { spawn } = await import("node:child_process");
  const relay = spawn(BIN, ["serve", join(TMP, "full-relay"), "--listen=127.0.0.1:0", "--no-udp"], { stdio: ["ignore", "pipe", "ignore"] });
  try {
    const said: string = await new Promise((done) => relay.stdout!.once("data", (d) => done(String(d))));
    const [, key, address] = said.match(/(\w{64}) listening on ws:\/\/(\S+)/)!;
    let full = false;
    let wire = 0;
    // A WebSocket that says it is full while told to, and counts what is sent on it.
    class Counted {
      #ws: WebSocket;
      binaryType = "arraybuffer";
      onopen: ((e: Event) => void) | null = null;
      onmessage: ((e: MessageEvent) => void) | null = null;
      onclose: ((e: CloseEvent) => void) | null = null;
      onerror: ((e: Event) => void) | null = null;
      constructor(url: string) {
        this.#ws = new WebSocket(url);
        this.#ws.binaryType = "arraybuffer";
        this.#ws.onopen = (e) => this.onopen?.(e);
        this.#ws.onmessage = (e) => this.onmessage?.(e);
        this.#ws.onclose = (e) => this.onclose?.(e);
        this.#ws.onerror = (e) => this.onerror?.(e);
      }
      get readyState() {
        return this.#ws.readyState;
      }
      get bufferedAmount() {
        return full ? 300_000 : this.#ws.bufferedAmount;
      }
      send(data: Uint8Array<ArrayBuffer> | ArrayBuffer | string) {
        if (typeof data !== "string") wire += data.byteLength;
        this.#ws.send(data);
      }
      close() {
        this.#ws.close();
      }
    }
    let dropped = 0;
    const a = await Node.open({
      volume: new MemoryVolume(),
      module,
      log: (_level, text) => void (text.includes("a link's packet was dropped") && dropped++),
      WebSocket: Counted as unknown as typeof WebSocket,
    });
    const b = await Node.open({ volume: new MemoryVolume(), module, log: () => {} });
    const space = a.create();
    a.relay(key, `ws://${address}`);
    a.admit(b.key, 1);
    b.join(space, { url: `ws://${address}`, key });
    const ca = new Client({ connect: a.connect });
    const cb = new Client({ connect: b.connect });
    await Promise.all([ca.ready, cb.ready]);
    let got = 0;
    cb.serve(1, "sink", (call) => {
      call.ondata = (chunk: Uint8Array) => void (got += chunk.length);
    });
    for (const end = Date.now() + 10_000; !ca.devices.some((d) => d.id === b.id); await new Promise((done) => setTimeout(done, 25))) {
      assert(Date.now() < end, "b never came online");
    }
    const calls = [ca.call(b.id, 1, "sink", new Uint8Array(0)), ca.call(b.id, 1, "sink", new Uint8Array(0))];
    for (const c of calls) c.send(Uint8Array.of(1, 2, 3, 4));
    for (const end = Date.now() + 10_000; got < 8; await new Promise((done) => setTimeout(done, 10))) assert(Date.now() < end, "the calls never began");
    const chunk = new Uint8Array(4096).fill(0x5a);
    const burst = async (held: boolean) => {
      wire = 0;
      dropped = 0;
      const want = got + 2 * 50 * chunk.length; // more than a relay queues for a session
      full = held;
      for (let i = 0; i < 50; i++) for (const c of calls) c.send(chunk);
      if (held) await new Promise((done) => setTimeout(done, 200));
      full = false;
      for (const end = Date.now() + 20_000; got < want; await new Promise((done) => setTimeout(done, 5))) assert(Date.now() < end, "the burst never arrived");
      assert(wire >= 2 * 50 * chunk.length, `only ${wire} bytes of a burst went by the counted way`);
      return dropped;
    };
    assert.equal(await burst(false), 0, "packets of a burst dropped by the node, its way not full");
    assert.equal(await burst(true), 0, "packets of a burst dropped by the node while its way was full");
    ca.close();
    cb.close();
    await Promise.all([a.close(), b.close()]);
  } finally {
    relay.kill();
  }
}

// A relay that turns this device away, as one does a device whose clock is far ahead of its own, is asked again ever
// less often: not every quarter of a second for as long as it says no, its session having been ready first.
{
  const { spawn } = await import("node:child_process");
  const relay = spawn(BIN, ["serve", join(TMP, "refusing-relay"), "--listen=127.0.0.1:0", "--no-udp"], { stdio: ["ignore", "pipe", "ignore"] });
  const realNow = Date.now;
  try {
    const said: string = await new Promise((done) => relay.stdout!.once("data", (d) => done(String(d))));
    const [, key, address] = said.match(/(\w{64}) listening on ws:\/\/(\S+)/)!;
    const owner = join(TMP, "refused-owner");
    const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
    execFileSync(BIN, ["relay", owner, key, `ws://${address}`]);
    Date.now = () => realNow() + 20 * 60 * 1000; // a quarter of an hour and more ahead of the relay's
    const volume = new MemoryVolume();
    const prep = await Node.open({ volume, module, log: () => {} });
    execFileSync(BIN, ["admit", owner, prep.key, "1"]);
    assert(prep.adopt(readFileSync(join(owner, space, "roster"))));
    const writer = new Client({ connect: prep.connect });
    while (!writer.may(1, "write")) await new Promise((done) => setTimeout(done, 1));
    await writer.write(1, (change) => change.insert({ title: columns.string(16) }, "items", 1, { title: "from later" }));
    writer.close();
    await prep.close();
    let dials = 0;
    class Counting extends WebSocket {
      constructor(url: string | URL, protocols?: string | string[]) {
        super(url, protocols);
        dials++;
      }
    }
    const node = await Node.open({ volume, module, log: () => {}, WebSocket: Counting });
    await new Promise((done) => setTimeout(done, 2800));
    await node.close();
    // 200, 400, 800 ms apart and more, with up to half again of each: four at most in 2.8 s, where it was eleven.
    assert(dials >= 1 && dials <= 5, `the relay was dialled ${dials} times in 2.8 s`);
  } finally {
    Date.now = realNow;
    relay.kill("SIGKILL");
  }
}

// What a node sends is only ever where one peer could be. A beacon is answered where it says its device is, from the
// address it came from, not at that address's port, which may be anyone's, as the shared port beacons are said from
// is; nothing from port 0 or nobody is answered at all, a beacon nor a request for this machine's outside address; and
// beacons go to everyone only by what may broadcast, never by what packets for peers go by.
{
  const owner = join(TMP, "answers-owner");
  const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  const loopback = Uint8Array.of(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 0, 0, 1);
  const nobody = Uint8Array.of(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0, 0, 0, 0);
  type Sent = { ip: number[]; to: number; type: number; data: Uint8Array; announced: boolean };
  const sent = new Map<number, Sent[]>();
  const hear = new Map<number, (ip: Uint8Array, port: number, data: Uint8Array) => void>();
  const datagrams = (port: number) => {
    sent.set(port, []);
    const put = (announced: boolean) => (ip: Uint8Array, to: number, data: Uint8Array) =>
      sent.get(port)!.push({ ip: [...ip.subarray(12)], to, type: data[0], data: data.slice(), announced });
    return {
      port,
      interfaces: () => [{ ip: loopback, broadcast: Uint8Array.of(127, 255, 255, 255) }],
      send: put(false),
      announce: put(true),
      listen: (receive: (ip: Uint8Array, port: number, data: Uint8Array) => void) => void hear.set(port, receive),
      close: () => void hear.delete(port),
    };
  };
  const a = await Node.open({ volume: new MemoryVolume(), module, datagrams: datagrams(40001), log: () => {} });
  const b = await Node.open({ volume: new MemoryVolume(), module, datagrams: datagrams(40002), log: () => {} });
  execFileSync(BIN, ["admit", owner, a.key, "1"]);
  execFileSync(BIN, ["admit", owner, b.key, "1"]);
  const roster = readFileSync(join(owner, space, "roster"));
  assert(a.adopt(roster) && b.adopt(roster));
  // The one with the lesser key dials; the other answers a beacon with its own, so that the first knows to.
  const [sayerPort, answererPort] = a.id < b.id ? [40001, 40002] : [40002, 40001];
  const wait = (ms: number) => new Promise((done) => setTimeout(done, ms));
  for (let i = 0; i < 200 && !sent.get(sayerPort)!.some((p) => p.type === 0x44); i++) await wait(10);
  const beacon = sent.get(sayerPort)!.find((p) => p.type === 0x44);
  assert(beacon, "no beacon was said");
  const all = [...sent.values()].flat();
  assert(all.every((p) => p.announced === (p.ip.join() === "255,255,255,255" || p.ip.join() === "127,255,255,255")), "a broadcast sent as to a peer, or the other way");
  const out = sent.get(answererPort)!;
  const answer = hear.get(answererPort)!;
  out.length = 0;
  answer(loopback, 50000, beacon.data); // from a port that may be anyone's, saying it is at sayerPort
  answer(loopback, 0, beacon.data);
  await wait(300);
  assert(!out.some((p) => p.to === 50000 || p.to === 0), `answered where a beacon came from, not where it said: ${out.map((p) => p.to)}`);
  assert(out.some((p) => p.to === sayerPort && p.type === 0x44), "a beacon went unanswered");
  const ask = new Uint8Array(20);
  ask[1] = 1;
  ask.set([0x21, 0x12, 0xa4, 0x42], 4);
  out.length = 0;
  answer(nobody, 0, ask);
  answer(nobody, 50001, ask);
  answer(loopback, 50002, ask);
  await wait(100);
  assert.deepEqual(out.filter((p) => p.type === 1).map((p) => p.to), [50002], "asked from nowhere, and answered there");
  await Promise.all([a.close(), b.close()]);
}

// Where a relay keeps a space, a proxy's query staying at the end.
assert.equal(spaceUrl("wss://relay.example/", "ab"), "wss://relay.example/ab");
assert.equal(spaceUrl("wss://relay.example/zsp?key=1", "ab"), "wss://relay.example/zsp/ab?key=1");

rmSync(TMP, { recursive: true, force: true });
console.log("ok");
