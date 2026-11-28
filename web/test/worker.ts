// A browser's worker, in Node: ./src/worker.ts itself, and the store under it, with the origin's private file system, Web
// Locks and BroadcastChannel as a browser has them, as far as they are used. What it holds of the store as it opens it,
// fails, is closed and is put away; what it says; and when it lets go of the lock. `node test/worker.ts`

import assert from "node:assert/strict";
import { Client } from "../src/client.ts";
import { Node } from "../src/node.ts";
import { Store } from "../src/store.ts";
import { HELD_WITHIN, OpfsVolume, storePath, take } from "../src/volume-opfs.ts";
import { MemoryVolume, StoreLocked } from "../src/volume.ts";
import { loadModule } from "../src/wasm.ts";
import type { Report } from "../src/worker.ts";

const module = await loadModule();
const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));
const HELD = "Access Handles cannot be created if there is another open Access Handle or Writable stream associated with the same file.";

// ---------------------------------------------------------------- the platform

// Every file is held by one handle at most, which is had in its own time, a turn later: as a browser's are.
const open = new Set<Handle>(); // every handle not closed
let refused = 0; // how often a handle was asked for and the file was held
let failFlush: string | undefined; // the name of a file whose flush throws, as a full disk's may, or "*" for every one
let failClose: string | undefined; // and whose close throws
const heldForEver = new Set<string>(); // paths of files something else holds, and never lets go of
const heldOnce = new Set<string>(); // and that it holds for one try more, as a worker just gone may
let writes = 0; // to any file
const pauses = new Map<string, { reached: () => void; release: Promise<void> }>(); // by path: a file's next handle, held as it is had

class Handle {
  readonly file: Entry;
  constructor(file: Entry) {
    this.file = file;
    open.add(this);
  }
  #check(): void {
    if (!open.has(this)) throw new DOMException("closed", "InvalidStateError");
  }
  read(into: Uint8Array, { at }: { at: number }): number {
    this.#check();
    const n = Math.max(0, Math.min(into.length, this.file.data.length - at));
    into.set(this.file.data.subarray(at, at + n));
    return n;
  }
  write(bytes: Uint8Array, { at }: { at: number }): number {
    writes++;
    this.#check();
    if (at + bytes.length > this.file.data.length) {
      const grown = new Uint8Array(at + bytes.length);
      grown.set(this.file.data);
      this.file.data = grown;
    }
    this.file.data.set(bytes, at);
    return bytes.length;
  }
  getSize(): number {
    return this.file.data.length;
  }
  truncate(size: number): void {
    this.#check();
    const cut = new Uint8Array(size);
    cut.set(this.file.data.subarray(0, Math.min(size, this.file.data.length)));
    this.file.data = cut;
  }
  flush(): void {
    this.#check();
    if (failFlush === "*" || failFlush === this.file.name) throw new DOMException("the disk is full", "QuotaExceededError");
  }
  close(): void {
    if (failClose === this.file.name) throw new DOMException("it could not be closed", "UnknownError");
    open.delete(this);
    if (this.file.handle === this) this.file.handle = undefined;
  }
}

class Entry {
  readonly kind = "file";
  readonly name: string;
  readonly path: string;
  data = new Uint8Array(0);
  handle?: Handle;
  constructor(name: string, path: string) {
    this.name = name;
    this.path = path;
  }
  async createSyncAccessHandle(): Promise<Handle> {
    await Promise.resolve();
    if (this.handle || heldForEver.has(this.path) || heldOnce.delete(this.path)) {
      refused++;
      throw new DOMException(HELD, "NoModificationAllowedError");
    }
    const h = (this.handle = new Handle(this));
    const pause = pauses.get(this.path);
    if (pause) pauses.delete(this.path), pause.reached(), await pause.release;
    return h;
  }
}

class Dir {
  readonly kind = "directory";
  readonly path: string;
  entries = new Map<string, Dir | Entry>();
  constructor(path: string) {
    this.path = path;
  }
  async getDirectoryHandle(name: string, o?: { create?: boolean }): Promise<Dir> {
    let e = this.entries.get(name);
    if (!e && o?.create) this.entries.set(name, (e = new Dir(this.path + "/" + name)));
    if (!(e instanceof Dir)) throw new DOMException(name, e ? "TypeMismatchError" : "NotFoundError");
    return e;
  }
  async getFileHandle(name: string, o?: { create?: boolean }): Promise<Entry> {
    let e = this.entries.get(name);
    if (!e && o?.create) this.entries.set(name, (e = new Entry(name, this.path + "/" + name)));
    if (!(e instanceof Entry)) throw new DOMException(name, e ? "TypeMismatchError" : "NotFoundError");
    return e;
  }
  async removeEntry(name: string): Promise<void> {
    const e = this.entries.get(name);
    if (!e) throw new DOMException(name, "NotFoundError");
    if (e instanceof Entry && e.handle) throw new DOMException(HELD, "NoModificationAllowedError"); // as a browser's is
    this.entries.delete(name);
  }
  async *[Symbol.asyncIterator](): AsyncIterator<[string, Dir | Entry]> {
    for (const pair of this.entries) yield pair;
  }
}
const root = new Dir("");

/** The next handle of a store's file is held, once had, until `release`. */
function pause(store: string, name: string): { reached: Promise<void>; release: () => void } {
  let reached!: () => void, release!: () => void;
  const was = new Promise<void>((done) => (reached = done));
  pauses.set(`/zsp/${store}/${name}`, { reached, release: new Promise<void>((done) => (release = done)) });
  return { reached: was, release };
}

/** The handles open in a store's directory. */
const held = (store: string) => [...open].filter((h) => h.file.path.startsWith(`/zsp/${store}/`)).length;

// Web Locks: one holder of a name at a time, the rest in line, in order, any of which may give up its place.
const locks = new Set<string>();
const lines = new Map<string, (() => void)[]>();
function request<T>(name: string, a: { signal?: AbortSignal } | (() => T | Promise<T>), b?: () => T | Promise<T>): Promise<T> {
  const f = (typeof a === "function" ? a : b)!;
  const signal = typeof a === "function" ? undefined : a.signal;
  return new Promise<T>((resolve, reject) => {
    const grant = () => {
      locks.add(name);
      void (async () => {
        try {
          resolve(await f());
        } catch (e) {
          reject(e);
        } finally {
          locks.delete(name);
          lines.get(name)?.shift()?.();
        }
      })();
    };
    if (!locks.has(name)) return grant();
    const line = lines.get(name) ?? (lines.set(name, []), lines.get(name)!);
    line.push(grant);
    signal?.addEventListener("abort", () => {
      const at = line.indexOf(grant);
      if (at >= 0) line.splice(at, 1), reject(new DOMException("given up", "AbortError"));
    });
  });
}

// BroadcastChannel: what is said is heard a turn later by every other of the name.
const channels = new Map<string, Set<Channel>>();
class Channel {
  readonly name: string;
  onmessage: ((e: { data: unknown }) => void) | null = null;
  constructor(name: string) {
    this.name = name;
    (channels.get(name) ?? (channels.set(name, new Set()), channels.get(name)!)).add(this);
  }
  postMessage(data: unknown): void {
    for (const c of channels.get(this.name) ?? []) {
      if (c === this) continue;
      const copy = structuredClone(data);
      setTimeout(() => c.onmessage?.({ data: copy }));
    }
  }
  close(): void {
    channels.get(this.name)?.delete(this);
  }
}

Object.defineProperty(globalThis, "navigator", { value: { storage: { getDirectory: async () => root }, locks: { request } }, configurable: true });
Object.defineProperty(globalThis, "BroadcastChannel", { value: Channel, configurable: true });
Object.defineProperty(globalThis, "FileSystemFileHandle", { value: Entry, configurable: true });

// A worker of its own, as each tab has: what it says to its tab, and a way to tell it something as its tab would.
let workers = 0;
async function worker() {
  const said: Report[] = [];
  let onSaid: ((r: Report) => void) | undefined;
  const scope = { location: { href: "file:///" }, onmessage: null as ((e: { data: unknown }) => Promise<void>) | null, postMessage: (r: Report) => (said.push(r), onSaid?.(r)) };
  Object.defineProperty(globalThis, "self", { value: scope, configurable: true });
  await import(`../src/worker.ts?${++workers}`); // a module of its own, as a worker's is
  const on = scope.onmessage!;
  return {
    said,
    tell: (data: unknown) => on({ data }),
    /** Says, as it is said, what was so then. */
    watch: (f: (r: Report) => void) => void (onSaid = f),
  };
}
const answered = (said: Report[], id: number) => said.find((r) => "answer" in r && r.answer === id) as { answer: number; value?: unknown; error?: string; name?: string } | undefined;
async function until(what: string, f: () => boolean, ms = 5000): Promise<void> {
  for (const t = performance.now(); !f(); await sleep(1)) if (performance.now() - t > ms) throw new Error(`not in time: ${what}`);
}

// ---------------------------------------------------------------- a file held by another

// Taken once whatever holds it lets go, after a try or a few; held as it was in Chromium before, the same.
{
  for (const name of ["NoModificationAllowedError", "InvalidStateError"]) {
    let tries = 0;
    const t = performance.now();
    const got = await take("f", async () => (++tries < 4 ? Promise.reject(new DOMException(HELD, name)) : "handle"), (ms) => sleep(ms).then(() => true));
    assert.equal(got, "handle");
    assert.equal(tries, 4);
    assert(performance.now() - t < 200, "it waited longer than it had to");
  }
  // Anything else is thrown at once.
  let tries = 0;
  await assert.rejects(take("f", async () => (tries++, Promise.reject(new DOMException("no", "NotAllowedError"))), async () => true), { name: "NotAllowedError" });
  assert.equal(tries, 1);
  // Held for ever, it is said to be locked once `within` is up, and not before.
  const t = performance.now();
  const e = await take("f", () => Promise.reject(new DOMException(HELD, "NoModificationAllowedError")), (ms) => sleep(ms).then(() => true), 300).catch((e) => e);
  const took = performance.now() - t;
  assert(e instanceof StoreLocked && e.name === "StoreLocked", String(e));
  assert.equal((e.cause as DOMException).name, "NoModificationAllowedError");
  assert(took >= 300 && took < 600, `said to be locked after ${took} ms`);
}

// In the origin's file system: a file another handle holds is had once it lets go; held for ever, the store is said to be
// locked in HELD_WITHIN; and a volume let go of gives up at once, waiting on no timer.
{
  const volume = await OpfsVolume.at("zsp/held");
  const entry = await (await (await root.getDirectoryHandle("zsp")).getDirectoryHandle("held")).getFileHandle("tree", { create: true });
  const other = await entry.createSyncAccessHandle();
  setTimeout(() => other.close(), 30);
  const before = refused;
  const f = (await volume.open("tree", true))!;
  assert(refused > before, "it was never held");
  f.close();
  const another = await entry.createSyncAccessHandle();
  const fresh = await OpfsVolume.at("zsp/held");
  const t = performance.now();
  await assert.rejects(fresh.open("tree", true), (e) => e instanceof StoreLocked);
  const took = performance.now() - t;
  assert(took >= HELD_WITHIN && took < HELD_WITHIN + 500, `said to be locked after ${took} ms`);
  const letGo = await OpfsVolume.at("zsp/held");
  const opening = letGo.open("tree", true).catch((e) => e);
  await sleep(20);
  const at = performance.now();
  letGo.close();
  const e = await opening;
  assert(!(e instanceof StoreLocked) && (e as DOMException).name === "NoModificationAllowedError", String(e));
  assert(performance.now() - at < 20, "it went on waiting once the volume was let go of");
  another.close();
}

// A file found held is waited for HELD_WITHIN from when it was first found held, and from nothing before: once had, a file
// found held after, as a segment is opened while the node runs, is waited for afresh, however long after the last was.
{
  const volume = await OpfsVolume.at("zsp/episode");
  heldOnce.add("/zsp/episode/a");
  (await volume.open("a", true))!.close();
  await sleep(HELD_WITHIN + 50); // the node getting on, longer than any file is waited for
  heldOnce.add("/zsp/episode/b");
  const before = refused;
  (await volume.open("b", true))!.close();
  assert.equal(refused, before + 1, "found held once, and had at the next try");
  await sleep(HELD_WITHIN + 50);
  const dir = await (await root.getDirectoryHandle("zsp")).getDirectoryHandle("episode");
  const other = await (await dir.getFileHandle("a")).createSyncAccessHandle();
  setTimeout(() => other.close(), 30);
  await volume.remove("a"); // removed as found held afresh, too
  assert(!dir.entries.has("a"));
}

// A file is removed once whatever holds it lets go, as it is opened; and a volume let go of closes what it has open, and what
// is had as it is let go of, as when a worker is put away as it opens the store.
{
  const dir = await (await root.getDirectoryHandle("zsp")).getDirectoryHandle("removing", { create: true });
  const held = await (await dir.getFileHandle("00000003.log", { create: true })).createSyncAccessHandle();
  const volume = await OpfsVolume.at("zsp/removing");
  setTimeout(() => held.close(), 30);
  await volume.remove("00000003.log");
  assert(!dir.entries.has("00000003.log"), "a file held a while was not removed");
  const f = (await volume.open("tree", true))!;
  const slow = pause("removing", "find");
  const opening = volume.open("find", true).catch((e) => e);
  await slow.reached;
  volume.close();
  assert.equal(open.size - [...open].filter((h) => !h.file.path.startsWith("/zsp/removing/")).length, 1, "only what is being had is open");
  slow.release();
  assert(String(await opening).includes("let go of"), "a file had as its volume was let go of was handed over");
  assert.equal([...open].filter((h) => h.file.path.startsWith("/zsp/removing/")).length, 0, "a file of a volume let go of was left open");
  void f;
}

// And a worker that, given the store's lock, finds a file of it held for ever tells its tab so, by name, and what it was asked
// too; and lets go of the lock, to be tried again when it is next wanted.
{
  const dir = await (await root.getDirectoryHandle("zsp", { create: true })).getDirectoryHandle("locked", { create: true });
  const other = await (await dir.getFileHandle("tree", { create: true })).createSyncAccessHandle();
  const w = await worker();
  await w.tell({ open: { name: "locked" } });
  await w.tell({ ask: 1, op: "identity", args: [] });
  assert.equal(answered(w.said, 1)?.name, "StoreLocked", JSON.stringify(answered(w.said, 1)));
  assert(w.said.some((r) => "failed" in r && r.name === "StoreLocked"), "its tab was not told the store is locked");
  assert(!locks.has("zsp:locked"));
  other.close();
}

// ---------------------------------------------------------------- the store

// A node that cannot be opened, its store opened and a segment of it still being opened, lets go of it only once that
// segment is had and closed: until then the next to open the store would find it held. And then nothing is open.
{
  const volume = await OpfsVolume.at("zsp/inflight");
  failFlush = "device.1"; // keeping its key, as a new device does once its store is open
  const segment = pause("inflight", "00000000.log");
  let failed: unknown;
  const opening = Node.open({ volume, module }).catch((e) => (failed = e));
  await segment.reached;
  await sleep(20);
  assert.equal(failed, undefined, "said to have failed with a segment still being opened");
  assert(held("inflight") > 0);
  segment.release();
  const e = (await opening) as unknown;
  assert(e instanceof DOMException && e.name === "QuotaExceededError", String(e));
  assert.equal(held("inflight"), 0, "a file of a store that could not be opened was left open");
  failFlush = undefined;
}

// A file that cannot be closed keeps no other open, however the store is let go of.
for (const how of ["letGo", "closeNow", "close"] as const) {
  const volume = await OpfsVolume.at(`zsp/close-${how}`);
  const store = await Store.open(volume, 1 << 20);
  await sleep(10); // its segments opened ahead
  failClose = "tree";
  await store[how]();
  failClose = undefined;
  assert.equal(held(`close-${how}`), 1, `${how}: a file that could not be closed kept others open`);
  for (const h of [...open]) if (h.file.path.startsWith(`/zsp/close-${how}/`)) h.close();
}

// ---------------------------------------------------------------- the worker

// Store names: what is one store is one lock, one channel and one directory.
{
  for (const name of ["app", "app/", "/app", "app//", "//app/"]) assert.equal(storePath(name), "app");
  assert.equal(storePath("a//b/"), "a/b");
  for (const name of ["", "/", "//", ".", "a/./b", "a/../b", ".."]) assert.throws(() => storePath(name), RangeError, name);
  // Two tabs that name it differently share it: the second's worker waits in line for the first's, and asks it.
  const a = await worker();
  await a.tell({ open: { name: "app" } });
  await a.tell({ ask: 1, op: "identity", args: [] });
  const b = await worker();
  await b.tell({ open: { name: "app//" } });
  const before = refused;
  const asking = b.tell({ ask: 1, op: "identity", args: [] });
  await Promise.race([asking, sleep(500)]);
  assert.equal(refused, before, "the second worker opened the store's files, held by the first");
  assert.deepEqual(answered(b.said, 1)?.value, answered(a.said, 1)?.value, "the second tab's device is not the first's");
  await a.tell({ ask: 2, op: "close", args: [] });
  await b.tell({ ask: 2, op: "close", args: [] });
  assert.equal(held("app"), 0);
}

// Closed as it opens the store, the device is closed once it has, every file closed and the lock let go of, before it says
// it is: its tab stops the worker as soon as it hears.
{
  const roster = pause("closing", "roster.1");
  const w = await worker();
  await w.tell({ open: { name: "closing" } });
  void w.tell({ ask: 1, op: "identity", args: [] });
  await roster.reached;
  assert(held("closing") > 5);
  let then: { files: number; lock: boolean } | undefined;
  w.watch((r) => "answer" in r && r.answer === 2 && (then = { files: held("closing"), lock: locks.has("zsp:closing") }));
  const closing = w.tell({ ask: 2, op: "close", args: [] });
  await sleep(20);
  assert.equal(then, undefined, "said to be closed while it was still opening the store");
  roster.release();
  await closing;
  assert.deepEqual(then, { files: 0, lock: false }, "said to be closed with files open, or the lock held");
}

// And a tab in line for the store, run by another's, closes at once, giving up its place.
{
  const a = await worker();
  await a.tell({ open: { name: "line" } });
  await a.tell({ ask: 1, op: "identity", args: [] });
  const b = await worker();
  await b.tell({ open: { name: "line" } });
  await b.tell({ ask: 1, op: "identity", args: [] });
  assert.equal(await Promise.race([b.tell({ ask: 2, op: "close", args: [] }).then(() => "closed"), sleep(500).then(() => "waiting")]), "closed");
  await a.tell({ ask: 2, op: "close", args: [] });
  assert(!locks.has("zsp:line"), "the store was had by one closed");
  assert.equal(lines.get("zsp:line")?.length ?? 0, 0, "one closed is still in line");
}

// A store held by something that answers nothing, as a tab whose renderer has hung does: what is asked is said to have
// failed as the store is locked, after a silence and as long again asked whether it is there, rather than waited on for
// ever; and the worker, still in line, runs the device once it is let go of. One that holds it and is there, opening it
// slowly, is waited for.
{
  let letGo!: () => void;
  void request("zsp:mute", () => new Promise<void>((done) => (letGo = done)));
  const w = await worker();
  await w.tell({ open: { name: "mute" } });
  const t = performance.now();
  await Promise.race([w.tell({ ask: 1, op: "identity", args: [] }), sleep(10000)]);
  const took = performance.now() - t;
  assert.equal(answered(w.said, 1)?.name, "StoreLocked", `asked of a store held by what answers nothing: ${JSON.stringify(answered(w.said, 1))}`);
  assert(took > 2 * 3000 - 50 && took < 2 * 3000 + 1000, `said to be locked after ${took} ms`);
  assert(w.said.some((r) => "failed" in r && r.name === "StoreLocked"), "its tab was not told the store is locked");
  letGo();
  await w.tell({ ask: 2, op: "identity", args: [] });
  assert.equal(answered(w.said, 2)?.error, undefined, "not run once it was let go of");

  let opened!: () => void;
  void request("zsp:slow", () => new Promise<void>((done) => (opened = done)));
  const holder = new Channel("zsp:slow");
  holder.onmessage = (e) => (e.data as { anyone?: true }).anyone && holder.postMessage({ here: true });
  const s = await worker();
  await s.tell({ open: { name: "slow" } });
  setTimeout(() => (holder.close(), opened()), 8000);
  await s.tell({ ask: 1, op: "identity", args: [] });
  assert.equal(answered(s.said, 1)?.error, undefined, `one there, if slow, was given up on: ${JSON.stringify(answered(s.said, 1))}`);
  await w.tell({ ask: 3, op: "close", args: [] });
  await s.tell({ ask: 2, op: "close", args: [] });
}

// Put away, as its tab is frozen or left: every file is closed at once, as the worker is told, for nothing after is sure to
// be run; and the lock let go of once nothing is being opened.
{
  const w = await worker();
  await w.tell({ open: { name: "away" } });
  await w.tell({ ask: 1, op: "create", args: [] });
  await sleep(20); // and the segments it opens ahead opened, which, being opened, could be closed only as they come
  assert(held("away") > 10);
  void w.tell({ away: true });
  assert.equal(held("away"), 0, "files left open as it was put away");
  await until("the lock is let go of", () => !locks.has("zsp:away"));
}

// A node that fails in its first turn, as it opens, its storage failing: every tab is told, and the lock is let go of, for
// another to have; not held for ever by a worker waiting to be told what it was told before it listened.
{
  // A device of a space, whose roster has changed since its trees were last made durable, as after a crash: the first
  // thing it does, opened again, is write, and make that durable.
  const other = await Node.open({ volume: new MemoryVolume(), module });
  const node = await Node.open({ volume: await OpfsVolume.at("zsp/first"), module, full: true });
  node.create();
  node.admit(other.key, 1);
  const c = new Client({ connect: node.connect });
  while (!c.may(1, "write")) await sleep(1);
  await c.write(1, (change) => change.insert({}, "x", 1, {}));
  await node.settled();
  const tree = await (await (await root.getDirectoryHandle("zsp")).getDirectoryHandle("first")).getFileHandle("tree");
  const before = tree.data.slice();
  node.revoke(other.key, 1);
  await node.settled();
  c.close();
  await node.close();
  await other.close();
  tree.data = before;
  failFlush = "*";
  const w = await worker();
  await w.tell({ open: { name: "first", full: true } });
  await until("its tab is told", () => w.said.some((r) => "failed" in r), 2000);
  await until("the lock is let go of", () => !locks.has("zsp:first"), 2000);
  assert.equal(held("first"), 0);
  failFlush = undefined;
}

// ---------------------------------------------------------------- what goes wrong as the store is let go of

// Whatever stopping a node throws, as a client told its pipe is closed, or UDP, may: every file is closed all the same, by
// close, closeNow, or as storage fails, when whoever listens is told too; and a node whose storage failed makes nothing more
// durable as it stops, writing nothing.
{
  const datagrams = { port: 1, listen() {}, send() {}, interfaces: () => [], close: () => { throw new Error("UDP would not close"); } };
  for (const how of ["close", "closeNow"] as const) {
    const node = await Node.open({ volume: await OpfsVolume.at(`zsp/stop-${how}`), module, datagrams, log: () => {} });
    node.create();
    await sleep(10);
    let threw: unknown;
    try {
      await node[how]();
    } catch (e) {
      threw = e;
    }
    await node.close().catch(() => {});
    assert.match(String(threw), /UDP would not close/, `${how}: what stopping it threw was not said`);
    assert.equal(held(`stop-${how}`), 0, `${how}: files left open, stopping it having thrown`);
  }
  const node = await Node.open({ volume: await OpfsVolume.at("zsp/stop-fail"), module, datagrams, log: () => {} });
  node.create();
  await sleep(10);
  let told: Error | undefined;
  let written = -1;
  node.onFailure = (e) => ((told = e), (written = writes));
  const client = new Client({ connect: node.connect });
  while (!client.may(1, "write")) await sleep(1);
  failFlush = "*";
  void client.write(1, (c) => c.insert({}, "x", 1, {})).catch(() => {}); // never durable
  await until("it is told", () => told !== undefined);
  await node.close();
  failFlush = undefined;
  assert.equal(held("stop-fail"), 0, "files left open as it failed, stopping it having thrown");
  assert.equal(writes, written, "something was written as a node whose storage failed was stopped");
  client.close();
}

// A worker whose node failed, still letting go of a segment being opened, is asked something meanwhile: it gets in line
// again, and what it asked waits on whoever has the store next, as anything that waits on a holder does; and is given up on
// should that answer nothing.
{
  const w = await worker();
  await w.tell({ open: { name: "relisten" } });
  const segment = pause("relisten", "00000001.log"); // opened ahead as the store opens
  await w.tell({ ask: 1, op: "identity", args: [] });
  await segment.reached;
  await w.tell({ ask: 2, op: "create", args: [] });
  failFlush = "*";
  void w.tell({ ask: 4, op: "scope", args: [] }); // which the node fails to keep, and so stops
  await until("the node has failed", () => w.said.some((r) => "failed" in r));
  failFlush = undefined;
  void request("zsp:relisten", () => new Promise<void>(() => {})); // next in line, and answering nothing
  const asked = w.tell({ ask: 3, op: "member", args: [] }); // in line again, behind it
  await sleep(20);
  segment.release();
  const t = performance.now();
  await Promise.race([asked, sleep(10000)]);
  assert.equal(answered(w.said, 3)?.name, "StoreLocked", `asked as its node let go, of a store then held by what answers nothing: ${JSON.stringify(answered(w.said, 3))}`);
  assert(performance.now() - t < 7500, "given up on only after it should have been");
}

// A worker whose node is stopped without its files being closed, by what throws, lets go of them and the lock all the same
// as it leaves; and one whose node's close fails lets go of the lock, and says it holds the store no more.
{
  const w = await worker();
  await w.tell({ open: { name: "leave-throws" } });
  await w.tell({ ask: 1, op: "create", args: [] });
  await sleep(20);
  const closeNow = Node.prototype.closeNow;
  Node.prototype.closeNow = () => {
    throw new Error("it would not stop");
  };
  try {
    void w.tell({ away: true });
  } finally {
    Node.prototype.closeNow = closeNow;
  }
  assert.equal(held("leave-throws"), 0, "files left open as it left, stopping its node having thrown");
  await until("the lock is let go of", () => !locks.has("zsp:leave-throws"));

  const v = await worker();
  await v.tell({ open: { name: "close-rejects" } });
  await v.tell({ ask: 1, op: "create", args: [] });
  const close = Node.prototype.close;
  Node.prototype.close = function () {
    return close.call(this).then(() => Promise.reject(new Error("it would not close")));
  };
  try {
    await v.tell({ ask: 2, op: "close", args: [] });
  } finally {
    Node.prototype.close = close;
  }
  await until("the lock is let go of", () => !locks.has("zsp:close-rejects"));
  let here = false;
  const probe = new Channel("zsp:close-rejects");
  probe.onmessage = (e) => void ((e.data as { here?: true }).here && (here = true));
  probe.postMessage({ anyone: true });
  await sleep(50);
  probe.close();
  assert(!here, "a worker that let go of the store says it is there");
}

// Closed as it waits for a file of the store held by another, a worker gives up waiting at once, and tells nobody the
// store is locked; put away as it opens the store, it closes at once what it has opened of it.
{
  const dir = await (await root.getDirectoryHandle("zsp")).getDirectoryHandle("closing-held", { create: true });
  const other = await (await dir.getFileHandle("tree", { create: true })).createSyncAccessHandle();
  let told = false;
  const bystander = new Channel("zsp:closing-held");
  bystander.onmessage = (e) => void ((e.data as { failed?: string }).failed !== undefined && (told = true));
  const w = await worker();
  await w.tell({ open: { name: "closing-held" } });
  void w.tell({ ask: 1, op: "identity", args: [] });
  await sleep(200); // waiting for the tree
  const t = performance.now();
  await w.tell({ ask: 2, op: "close", args: [] });
  const took = performance.now() - t;
  await sleep(50);
  bystander.close();
  other.close();
  assert(took < 300, `closed only after ${took} ms, waiting for a file held by another`);
  assert(!told, "other tabs were told the store failed, as one left it");
  assert(!locks.has("zsp:closing-held"));

  const roster = pause("away-opening", "roster.1");
  const a = await worker();
  await a.tell({ open: { name: "away-opening" } });
  void a.tell({ ask: 1, op: "identity", args: [] });
  await roster.reached;
  assert(held("away-opening") > 5);
  void a.tell({ away: true });
  assert(held("away-opening") <= 1, `${held("away-opening")} files left open as it was put away opening the store, but for the one being had`);
  roster.release();
  await until("the lock is let go of", () => !locks.has("zsp:away-opening"));
  assert.equal(held("away-opening"), 0);
}

// A segment of the log found held by another as it is opened, in the store's own time, fails the node as the store being
// locked, not as storage failing: whoever is told can tell.
{
  heldForEver.add("/zsp/segment-held/00000001.log");
  const node = await Node.open({ volume: await OpfsVolume.at("zsp/segment-held"), module, log: () => {} });
  let told: Error | undefined;
  node.onFailure = (e) => (told = e);
  node.create();
  const client = new Client({ connect: node.connect });
  while (!client.may(1, "write")) await sleep(1);
  await sleep(HELD_WITHIN + 200); // given up on by now
  void client.write(1, (c) => c.insert({}, "x", 1, {})).catch(() => {}); // never durable
  await until("it is told", () => told !== undefined);
  assert(told instanceof StoreLocked, `told ${told}`);
  client.close();
  await node.close();
  heldForEver.clear();
}

// A follower whose tab only has pipes to a leader that answers nothing, as one hung: a pipe it sends something on and
// hears nothing back from, and a new one, are waited on as asks are, and then broken, the tab told the store is locked.
{
  const a = await worker();
  await a.tell({ open: { name: "pipes" } });
  await a.tell({ ask: 1, op: "create", args: [] });
  const leaders = [...(channels.get("zsp:pipes") ?? [])];
  const b = await worker();
  await b.tell({ open: { name: "pipes" } });
  const { port1, port2 } = new MessageChannel();
  let closed = false;
  port1.onmessage = (e) => void ((e.data as { close?: true }).close && (closed = true));
  await b.tell({ connect: port2 });
  await until("the pipe is carried", () => [...channels.keys()].some((n) => n.startsWith("zsp:pipes:") && channels.get(n)!.size === 2));
  await sleep(50); // and what the leader said on it heard
  // The leader hangs: it hears nothing more, and says nothing.
  const hang = (c: Channel) => ((c.onmessage = null), (c.postMessage = () => {}));
  for (const c of leaders) hang(c);
  for (const [n, set] of channels) if (n.startsWith("zsp:pipes:")) hang([...set][1]);
  const t = performance.now();
  port1.postMessage({ data: new Uint8Array([1, 2, 3]) });
  await until("the pipe is broken", () => closed, 12000);
  assert(b.said.some((r) => "failed" in r && r.name === "StoreLocked"), "the tab was not told the store is locked");
  const took = performance.now() - t;
  // Given up on in three intervals at most: the rest of the one it was sent in, a silence, and as long again asked.
  assert(took < 3 * 3000 + 500, `broken after ${took} ms`);
  port1.close();
}

// A worker holding the store that is stuck opening it, waiting on a file that never opens, does not say it is there, but
// for once, as it is first asked: what waits on it is given up on. Many waiting on it ask whether it is there, as one does
// at a time, for a worker that hears another ask need not ask too: what the holder says, every worker hears.
{
  const stuck = pause("stuck", "tree"); // never let go of
  const a = await worker();
  await a.tell({ open: { name: "stuck" } });
  void a.tell({ ask: 1, op: "identity", args: [] });
  await stuck.reached;
  let anyone = 0;
  const spy = new Channel("zsp:stuck");
  spy.onmessage = (e) => void ((e.data as { anyone?: true }).anyone && anyone++);
  const waiting = [];
  for (let i = 0; i < 8; i++) {
    const f = await worker();
    await f.tell({ open: { name: "stuck" } });
    waiting.push(Promise.race([f.tell({ ask: 1, op: "identity", args: [] }), sleep(15000)]).then(() => answered(f.said, 1)));
    await sleep(100);
  }
  const said = await Promise.all(waiting);
  spy.close();
  console.log(`     eight waiting on a holder stuck opening the store: ${anyone} asked whether it is there`);
  assert(said.every((x) => x?.name === "StoreLocked"), `asked of a holder stuck opening the store: ${JSON.stringify(said)}`);
  assert(anyone <= 4, `${anyone} asked whether it is there, each for itself`);
}

// A leader slow to answer, as one busy for long may be, asked at once by many whether it is there, says so once a second.
{
  const l = await worker();
  await l.tell({ open: { name: "busy" } });
  await l.tell({ ask: 1, op: "create", args: [] });
  for (const c of channels.get("zsp:busy") ?? []) {
    const hear = c.onmessage!;
    c.onmessage = (e) => void (!(e.data as { ask?: string }).ask && hear(e)); // asks go unanswered
  }
  let here = 0;
  const spy = new Channel("zsp:busy");
  spy.onmessage = (e) => void ((e.data as { here?: true }).here && here++);
  const followers = [];
  for (let i = 0; i < 8; i++) {
    const f = await worker();
    await f.tell({ open: { name: "busy" } });
    followers.push(f);
  }
  for (const f of followers) void f.tell({ ask: 1, op: "member", args: [] });
  await sleep(3000 + 500); // each has asked whether it is there
  spy.close();
  console.log(`     eight asking at once of a leader slow to answer: it said it is there ${here} times`);
  assert(here <= 1, `it said it is there ${here} times, at once`);
}

// A store's name with a backslash is no store's, as the File System standard allows it in no name; and a segment dropped
// whose file cannot be closed is dropped all the same.
{
  assert.throws(() => storePath("a\\b"), RangeError);
  const store = await Store.open(await OpfsVolume.at("zsp/drop"), 1 << 20);
  store.logWrite(0, new Uint8Array(10));
  await sleep(10);
  failClose = "00000000.log";
  store.logDrop(0);
  failClose = undefined;
  await store.close();
}

console.log("ok");
process.exit(0); // the workers' channels, which a browser closes with them
