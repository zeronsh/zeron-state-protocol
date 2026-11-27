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
    if (this.handle) {
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
    if (!this.entries.delete(name)) throw new DOMException(name, "NotFoundError");
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

// Web Locks: one holder of a name at a time, the rest in line, in order.
const locks = new Set<string>();
const lines = new Map<string, (() => void)[]>();
function request<T>(name: string, f: () => T | Promise<T>): Promise<T> {
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
    (lines.get(name) ?? (lines.set(name, []), lines.get(name)!)).push(grant);
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
  const scope = { location: { href: "file:///" }, onmessage: null as ((e: { data: unknown }) => Promise<void>) | null, postMessage: (r: Report) => said.push(r) };
  Object.defineProperty(globalThis, "self", { value: scope, configurable: true });
  await import(`../src/worker.ts?${++workers}`); // a module of its own, as a worker's is
  const on = scope.onmessage!;
  return {
    said,
    tell: (data: unknown) => on({ data }),
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
  const t = performance.now();
  await assert.rejects(volume.open("tree", true), (e) => e instanceof StoreLocked);
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
}

// Put away, as its tab is frozen or left: every file is closed at once, as the worker is told, for nothing after is sure to
// be run; and the lock let go of once nothing is being opened.
{
  const w = await worker();
  await w.tell({ open: { name: "away" } });
  await w.tell({ ask: 1, op: "create", args: [] });
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

console.log("ok");
process.exit(0); // the workers' channels, which a browser closes with them
