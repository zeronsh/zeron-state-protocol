// relay/src/storage.js held to a model, seeded: node tests/relay_storage.mjs [seeds] [first]
//
// Its log is a sparse array of bytes, grown in rows rewritten as they fill and cut in stretches; its cache may
// forget anything but never answer wrongly; it says when it is full and lets go of nothing it was told to keep;
// and what it starts on R2, it finishes, through failures. A real SQLite stands in for the object's, made to
// answer as the object's does.

import { DatabaseSync } from "node:sqlite";
import assert from "node:assert";
import { Storage, Full } from "../relay/src/storage.js";

const seeds = Number(process.argv[2] ?? 10);
const first = Number(process.argv[3] ?? 0);

function random(seed) {
  let s = seed >>> 0 || 1;
  return (n) => {
    s ^= s << 13, s >>>= 0, s ^= s >>> 17, s ^= s << 5, s >>>= 0;
    return n === undefined ? s / 2 ** 32 : s % n;
  };
}

// The object's SQL, as far as storage.js uses it: blobs come back as ArrayBuffers, cursors count rows.
class Sql {
  constructor() {
    this.db = new DatabaseSync(":memory:");
    this.written = 0;
  }
  get databaseSize() {
    return this.db.prepare("PRAGMA page_count").get().page_count * this.db.prepare("PRAGMA page_size").get().page_size;
  }
  exec(query, ...args) {
    const st = this.db.prepare(query);
    let rows = [], changes = 0;
    if (/^\s*(SELECT|PRAGMA)/i.test(query)) {
      rows = st.all(...args).map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v instanceof Uint8Array ? v.slice().buffer : v])));
    } else {
      changes = st.run(...args.map((a) => (a instanceof Uint8Array ? a.slice() : a))).changes;
    }
    this.written += changes;
    return { toArray: () => rows, one: () => rows[0], rowsRead: rows.length, rowsWritten: changes };
  }
}

class Bucket {
  constructor(rand, fail) {
    this.objects = new Map();
    this.rand = rand;
    this.fail = fail;
  }
  async #later() {
    await new Promise((go) => setTimeout(go, this.rand(3)));
    if (this.fail && this.rand(this.fail) === 0) throw new Error("R2 is having a bad day");
  }
  async get(key, { range }) {
    await this.#later();
    const b = this.objects.get(key);
    if (!b) return null;
    const part = b.slice(range.offset, range.offset + range.length);
    return { arrayBuffer: async () => part.buffer.slice(part.byteOffset, part.byteOffset + part.length) };
  }
  async put(key, body) {
    await this.#later();
    this.objects.set(key, new Uint8Array(body));
  }
  async delete(keys) {
    await this.#later();
    for (const k of keys) this.objects.delete(k);
  }
}

function harness(seed, env = {}) {
  const rand = random(seed * 7919 + 1);
  const sql = new Sql();
  const waits = [];
  const ctx = { storage: { sql, sync: async () => {} }, waitUntil: (p) => waits.push(p) };
  const bucket = new Bucket(rand, env.FAIL);
  const s = new Storage(ctx, { STORE: bucket, ...env });
  const space = new Uint8Array(32).fill(seed & 255);
  s.open(space);
  const memory = new Uint8Array(1 << 22);
  const view = (ptr, len) => memory.subarray(ptr, ptr + len);
  const host = s.imports(view, space);
  return { rand, sql, s, host, memory, bucket, waits, space };
}

// The log: writes at the end, now and then past a gap (a segment rolled); cuts at the end, and of stretches below.
async function log_matches(seed) {
  const { rand, host, memory } = harness(seed);
  const model = new Map(); // offset -> byte
  let end = 0;
  for (let round = 0; round < 250; round++) {
    const r = rand(100);
    if (r < 55) {
      const len = 1 + rand(rand(25) === 0 ? 150000 : 3000);
      const off = rand(20) === 0 ? end + rand(5000) : end;
      for (let i = 0; i < len; i++) memory[i] = rand(256);
      assert.equal(host.log_write(off, 0, len), 1);
      for (let i = 0; i < len; i++) model.set(off + i, memory[i]);
      end = off + len;
    } else if (r < 80 && end > 0) {
      const off = rand(end), len = 1 + rand(Math.min(70000, end - off));
      const want = Array.from({ length: len }, (_, i) => model.get(off + i));
      const got = host.log_read(off, 1 << 21, len);
      assert.equal(got, want.every((b) => b !== undefined) ? 1 : 0, `seed ${seed} round ${round}: read ${off}+${len}`);
      if (got) assert.deepEqual(Array.from(memory.subarray(1 << 21, (1 << 21) + len)), want, `seed ${seed} round ${round}: bytes at ${off}`);
    } else if (r < 88 && end > 0) {
      const at = Math.max(0, end - rand(4000)); // the torn tail, or a step undone
      for (const k of [...model.keys()]) if (k >= at) model.delete(k);
      host.log_cut(at, 2 ** 64);
      end = Math.max(0, ...[...model.keys()].slice(-1).map((k) => k + 1));
    } else if (end > 0) {
      const lo = rand(end), hi = lo + rand(end - lo + 1); // in R2 now, or a segment dropped
      for (const k of [...model.keys()]) if (k >= lo && k < hi) model.delete(k);
      host.log_cut(lo, hi);
    }
    const last = [...model.keys()].reduce((a, b) => Math.max(a, b), -1) + 1;
    assert.ok(host.log_end() >= last, `seed ${seed} round ${round}: the log ends at ${host.log_end()}, before ${last}`);
  }
}

// The cache: never a wrong answer, never more than its budget. What is put is what is at that place, which never
// changes: a page's number is never reused, nor an offset of the log.
async function cache_is_sound(seed) {
  const { rand, host, memory, sql } = harness(seed, { CACHE_BYTES: String(300000) });
  host.log_write(0, 0, 1); // made
  const at = (kind, key, i) => ((kind * 977 + key * 131 + i * 7) ^ (key >> 3)) & 255; // what lies there
  for (let round = 0; round < 600; round++) {
    const kind = rand(2);
    if (rand(3) === 0) {
      const key = rand(5000), len = kind === 0 ? (1 + rand(20)) * 4096 : 1 + rand(30000);
      for (let i = 0; i < len; i++) memory[i] = kind === 0 ? at(0, key + Math.floor(i / 4096), i % 4096) : at(1, key + i, 0);
      host.cache_put(kind, key, 0, len);
    } else if (rand(10) === 0) {
      const lo = rand(5000);
      host.cache_drop(kind, lo, lo + rand(500));
    } else {
      const key = rand(5000), len = kind === 0 ? 4048 : 1 + rand(100);
      if (host.cache_get(kind, key, 1 << 21, len)) {
        for (let i = 0; i < len; i++) {
          const want = kind === 0 ? at(0, key, i) : at(1, key + i, 0);
          assert.equal(memory[(1 << 21) + i], want, `seed ${seed} round ${round}: the cache answered wrongly for ${kind}:${key}+${i}`);
        }
      }
    }
  }
  const sum = (k) => sql.exec(`SELECT coalesce(sum(length(data)), 0) AS n FROM cache${k}`).one().n;
  assert.ok(sum(0) <= 225000 && sum(1) <= 75000, `seed ${seed}: the cache holds ${sum(0)} + ${sum(1)}`);
}

// Full: what must be kept fails when it cannot be, and what may be forgotten is quietly not kept.
async function full_fails_cleanly(seed) {
  const { host, memory, sql } = harness(seed, { STORAGE_LIMIT: String(400000) });
  let kept = 0, refused = false;
  for (let i = 0; i < 200 && !refused; i++) {
    memory.fill(i, 0, 20000);
    if (host.log_write(i * 20000, 0, 20000)) kept++;
    else refused = true;
    host.cache_put(0, i * 16, 0, 4096 * 4); // never thrown
  }
  assert.ok(refused && kept > 5, `seed ${seed}: kept ${kept}, refused ${refused}`);
  for (let i = 0; i < kept; i++) {
    assert.equal(host.log_read(i * 20000, 1 << 21, 20000), 1);
    assert.ok(memory.subarray(1 << 21, (1 << 21) + 20000).every((b) => b === (i & 255)));
  }
  assert.ok(sql.databaseSize < 400000 * 1.5);
}

// R2: everything started is finished, through failures, and what was put can be read back.
async function r2_finishes(seed) {
  const { s, host, memory, bucket } = harness(seed, { FAIL: 4, R2_BACKOFF: "1" });
  memory.fill(7, 0, 9000);
  host.log_write(0, 0, 9000);
  const results = new Map();
  const finished = new Promise((all) => {
    let left = 0;
    const done = (op, ok, absent, bytes) => {
      results.set(op.id, { ok, absent, bytes });
      if (--left === 0) all();
    };
    memory.fill(9, 100, 100 + 8192);
    host.start(1, 3, 5, 0, 0, 100, 8192); // a pack
    host.start(2, 4, 0, 0, 9000, 0, 0); // an extent
    host.start(3, 0, 6, 0, 4096, 0, 0); // a page of a pack that is not there
    left = 3;
    s.run(done);
  });
  await finished;
  assert.equal(results.size, 3, "every operation started is heard of");
  assert.ok(!results.get(3).ok || results.get(3).absent, "a page of a pack that is not there is not made up");
  // What did not land is asked for again by the node; here, by hand, until it lands.
  for (let tries = 0; !bucket.objects.has(Buffer.from(new Uint8Array(32).fill(seed & 255)).toString("hex") + "/p/5"); tries++) {
    assert.ok(tries < 50);
    await new Promise((all) => {
      host.start(10 + tries, 3, 5, 0, 0, 100, 8192);
      s.run(() => all());
    });
  }
  const read = await new Promise((all) => {
    host.start(99, 0, 5, 4096, 4096, 0, 0);
    s.run((op, ok, absent, bytes) => all({ ok, absent, bytes }));
  });
  if (read.ok) assert.ok(read.bytes.length === 4096 && read.bytes.every((b) => b === 9));
  assert.ok(s.stats.puts >= 2 && s.stats.gets >= 1);
}

// An R2 that answers only when told to, to set operations of two nodes one after another.
class Held {
  constructor() {
    this.objects = new Map();
    this.pending = [];
  }
  #later(f) {
    return new Promise((resolve, reject) => this.pending.push(async () => { try { resolve(await f()); } catch (e) { reject(e); } }));
  }
  async answer() {
    while (this.pending.length > 0) {
      await this.pending.shift()();
      await new Promise((go) => setTimeout(go, 0));
    }
  }
  put(key, body) { return this.#later(() => void this.objects.set(key, new Uint8Array(body))); }
  get(key, { range }) {
    return this.#later(() => {
      const b = this.objects.get(key);
      if (!b) return null;
      const part = b.slice(range.offset, range.offset + range.length);
      return { arrayBuffer: async () => part.buffer.slice(part.byteOffset, part.byteOffset + part.length) };
    });
  }
  delete(keys) { return this.#later(() => { for (const k of keys) this.objects.delete(k); }); }
}

// A node let go of while its operations are under way, and the next: each hears of its own, and only of its own; what
// the first had not started is never started, so that one of the same number as the next's is never taken for it.
async function nodes_hear_their_own(seed) {
  const sql = new Sql(), held = new Held(), waits = [];
  const ctx = { storage: { sql, sync: async () => {} }, waitUntil: (p) => waits.push(p) };
  const s = new Storage(ctx, { STORE: held });
  const space = new Uint8Array(32).fill(seed & 255);
  s.open(space);
  const memory = new Uint8Array(1 << 16);
  const host = s.imports((ptr, len) => memory.subarray(ptr, ptr + len), space);
  host.log_write(0, 0, 1);
  const heard = [[], []];
  for (let i = 1; i <= 9; i++) host.start(i, 3, i, 0, 0, 0, 16); // more than are started at once
  s.run((op, ok) => heard[0].push([op.id, ok]));
  // Let go of: the ninth was never started, and is not.
  s.cancel();
  host.start(1, 3, 100, 0, 0, 0, 16); // the next node's first, of the same number as the first's
  s.run((op, ok) => heard[1].push([op.id, ok, op.number]));
  while (s.busy) {
    await new Promise((go) => setTimeout(go, 1));
    await held.answer();
  }
  await Promise.all(waits);
  assert.equal(heard[0].length, 8, `the first node heard of ${heard[0].length} of its 8 started`);
  assert.deepEqual(heard[1], [[1, true, 100]], `the next node heard ${JSON.stringify(heard[1])}`);
  assert.ok(held.objects.has(Buffer.from(space).toString("hex") + "/p/100"), "and what it heard of is there");
  assert.ok(!held.objects.has(Buffer.from(space).toString("hex") + "/p/9"), "what the first had not started never was");
}

// A node let go of while one of its operations is under way, and the next asking for one before it has said who
// hears of what it asks: the first's finishing does not start the next's on the first's account.
async function the_next_waits_to_say(seed) {
  const sql = new Sql(), held = new Held(), waits = [];
  const ctx = { storage: { sql, sync: async () => {} }, waitUntil: (p) => waits.push(p) };
  const s = new Storage(ctx, { STORE: held });
  const space = new Uint8Array(32).fill(seed & 255);
  s.open(space);
  const memory = new Uint8Array(64);
  const host = s.imports((ptr, len) => memory.subarray(ptr, ptr + len), space);
  host.log_write(0, 0, 1);
  const heard = [[], []];
  host.start(1, 3, 1, 0, 0, 0, 16);
  s.run((op) => heard[0].push(op.id));
  await new Promise((go) => setTimeout(go, 1));
  s.cancel(); // let go of, its put under way
  host.start(7, 5, 0, 0, 0, 0, 16); // the next asks, as it opens, before saying who hears
  await held.answer();
  await new Promise((go) => setTimeout(go, 1));
  s.run((op) => heard[1].push(op.id));
  while (s.busy) {
    await new Promise((go) => setTimeout(go, 1));
    await held.answer();
  }
  await Promise.all(waits);
  assert.deepEqual(heard, [[1], [7]], `heard ${JSON.stringify(heard)}`);
}

// With no bucket bound, objects are kept in the object's own SQLite, as R2 would keep them; and where there is no room
// for one, the node is told it is full, at once, rather than asked to try again for ever.
async function kept_here_without_a_bucket(seed) {
  const rand = random(seed * 31 + 5);
  for (const limit of [0, 1 << 20]) {
    const sql = new Sql(), waits = [];
    const ctx = { storage: { sql, sync: async () => {} }, waitUntil: (p) => waits.push(p) };
    const s = new Storage(ctx, limit ? { STORAGE_LIMIT: String(limit) } : {});
    let full = 0;
    const space = new Uint8Array(32).fill(seed & 255);
    s.open(space);
    const memory = new Uint8Array(4 << 20);
    const host = s.imports((ptr, len) => memory.subarray(ptr, ptr + len), space);
    host.log_write(0, 0, 1);
    const ask = (id, kind, number, off, len, size) =>
      new Promise((done) => {
        host.start(id, kind, number, off, len, 0, size);
        s.run((op, ok, absent, bytes, isFull) => (isFull && full++, done({ ok, absent, bytes })));
      });
    const size = (2 << 20) + 12345;
    for (let i = 0; i < size; i++) memory[i] = (i * 7 + (i >> 11)) & 255;
    const put = await Promise.race([ask(1, 3, 9, 0, 0, size), new Promise((go) => setTimeout(() => go({ full: true }), 200))]);
    if (limit) {
      assert.ok(full === 1 && !put.ok, `no room for it: told ${full} times`);
      const left = sql.exec("SELECT count(*) AS n FROM object").one().n;
      assert.equal(left, 0, `what could not be kept whole left ${left} part(s) of it`);
      assert.ok((await ask(2, 0, 9, 0, 10, 0)).absent, "and is not there");
      continue;
    }
    assert.ok(put.ok);
    for (let k = 0; k < 20; k++) {
      const off = rand(size + 100), len = 1 + rand(1 << 21);
      const got = await ask(10 + k, 0, 9, off, len, 0);
      assert.ok(got.ok && !got.absent);
      const want = Math.max(0, Math.min(len, size - off));
      assert.equal(got.bytes.length, want, `a read of ${len} at ${off}`);
      for (let i = 0; i < want; i += 997) assert.equal(got.bytes[i], ((off + i) * 7 + ((off + i) >> 11)) & 255);
    }
    memory.set(new Uint8Array(new BigUint64Array([9n, 1n]).buffer), 0); // Remote_Object{number = 9, pack = true}
    assert.ok((await ask(40, 5, 0, 0, 0, 16)).ok);
    const gone = await ask(41, 0, 9, 0, 10, 0);
    assert.ok(gone.ok && gone.absent, "deleted");
    await Promise.all(waits);
  }
}

// Full: what failed to be kept is not read back from memory as though it had been; what lessens what is kept is done
// whatever the limit; and a store too full to keep its first write still has its tables.
async function full_leaves_nothing_behind(seed) {
  {
    const { host, memory } = harness(seed, { STORAGE_LIMIT: String(60000) });
    let off = 0, failed = -1;
    for (let i = 0; i < 100 && failed < 0; i++) {
      memory.fill(0x5a, 0, 4096);
      if (host.log_write(off, 0, 4096) === 0) failed = off;
      else off += 4096;
    }
    assert.ok(failed >= 0);
    assert.equal(host.log_end(), failed);
    assert.equal(host.log_read(failed, 1 << 16, 4096), 0, "what was not kept is not read back");
    assert.equal(host.log_read(failed - 4096, 1 << 16, 4096), 1, "what was is");
    host.log_cut(0, 4096); // past the limit: a delete is how to get back under it
    host.log_cut(failed - 100, 2 ** 64);
    assert.equal(host.log_end(), failed - 100);
    host.cache_drop(0, 0, 2 ** 40);
  }
  {
    const { host } = harness(seed, { STORAGE_LIMIT: "1" });
    assert.equal(host.log_write(0, 0, 10), 0);
    assert.equal(host.log_end(), 0, "its tables are there");
    assert.equal(host.manifest_size(), -1);
  }
}

// A node let go of: what it asked for and was not yet started is never started.
async function cancelled_is_not_started(seed) {
  const { s, host, memory, bucket } = harness(seed);
  memory.fill(3, 0, 8192);
  host.log_write(0, 0, 1);
  host.start(1, 3, 9, 0, 0, 0, 8192); // a pack
  host.start(2, 5, 0, 0, 0, 0, 0); // a delete
  s.cancel();
  let heard = 0;
  s.run(() => heard++);
  await new Promise((go) => setTimeout(go, 20));
  assert.equal(heard, 0);
  assert.equal(bucket.objects.size, 0);
  assert.ok(!s.busy);
}

// Full, heard by the node whose operation it was, and only by it; and whatever waits behind it is started all the same.
async function full_is_heard_by_its_own(seed) {
  const sql = new Sql(), waits = [], gates = [];
  const ctx = { storage: { sql, sync: () => new Promise((go) => gates.push(go)) }, waitUntil: (p) => waits.push(p) };
  const s = new Storage(ctx, { STORAGE_LIMIT: String(1 << 20) });
  const space = new Uint8Array(32).fill(seed & 255);
  s.open(space);
  const memory = new Uint8Array(3 << 20);
  const host = s.imports((ptr, len) => memory.subarray(ptr, ptr + len), space);
  host.log_write(0, 0, 1);
  const heard = [[], []];
  for (let i = 1; i <= 8; i++) host.start(i, 3, i, 0, 0, 0, (2 << 20) + 100); // as many as are started at once, none of which fits
  s.run((op, ok, absent, bytes, full) => heard[0].push([op.id, ok, !!full]));
  s.cancel();
  host.start(9, 0, 1, 0, 10, 0, 0); // the next node's
  s.run((op, ok, absent, bytes, full) => heard[1].push([op.id, ok, !!full]));
  for (let i = 0; i < 100 && (gates.length > 0 || s.busy); i++) {
    while (gates.length > 0) gates.shift()();
    await new Promise((go) => setTimeout(go, 1));
  }
  await Promise.all(waits);
  assert.equal(heard[0].length, 8, `the first heard of ${heard[0].length} of its 8`);
  assert.ok(heard[0].every(([, ok, full]) => !ok && full), `the first heard ${JSON.stringify(heard[0])}`);
  assert.deepEqual(heard[1], [[9, true, false]], `the next heard ${JSON.stringify(heard[1])}`);
}

// With no bucket bound, objects are read a part at a time, only the parts a read wants; and probing measures what
// there is to measure, leaving nothing behind.
async function kept_here_read_as_wanted(seed) {
  const sql = new Sql(), waits = [];
  const ctx = { storage: { sql, sync: async () => {} }, waitUntil: (p) => waits.push(p) };
  const s = new Storage(ctx, {});
  const space = new Uint8Array(32).fill(seed & 255);
  s.open(space);
  assert.ok(typeof (await s.probe()) === "object", "probed before anything was kept");
  const memory = new Uint8Array(10 << 20);
  for (let i = 0; i < memory.length; i += 4093) memory[i] = (i >> 12) & 255;
  const host = s.imports((ptr, len) => memory.subarray(ptr, ptr + len), space);
  host.log_write(0, 0, 1);
  await s.probe();
  assert.equal(sql.exec("SELECT count(*) AS n FROM object").one().n, 0, "probing left something behind");
  const ask = (id, kind, number, off, len, size) =>
    new Promise((done) => {
      host.start(id, kind, number, off, len, 0, size);
      s.run((op, ok, absent, bytes) => done({ ok, absent, bytes }));
    });
  assert.ok((await ask(1, 3, 7, 0, 0, 10 << 20)).ok);
  for (const [off, len] of [[(5 << 20) + 4096, 4096], [(3 << 20) - 100, 200], [(10 << 20) - 10, 100], [(10 << 20) + 5, 10]]) {
    const before = s.stats.rowsRead;
    const got = await ask(2, 0, 7, off, len, 0);
    const want = Math.max(0, Math.min(len, (10 << 20) - off));
    assert.ok(got.ok && !got.absent && got.bytes.length === want, `a read of ${len} at ${off}: ${got.bytes?.length}`);
    for (let i = 0; i < want; i++) assert.equal(got.bytes[i], memory[off + i]);
    const parts = Math.max(1, Math.floor((off + Math.max(want, 1) - 1) / (1 << 20)) - Math.floor(off / (1 << 20)) + 1);
    assert.ok(s.stats.rowsRead - before <= parts + 1, `a read of ${len} at ${off} read ${s.stats.rowsRead - before} rows`);
  }
  assert.ok((await ask(3, 0, 8, 0, 10, 0)).absent, "what was never put is not there");
  await Promise.all(waits);
}

// A run of pages cached is not shortened by a shorter run put under the same key: what it held, it still holds.
async function cached_run_kept_longest(seed) {
  const { host, memory } = harness(seed, { CACHE_BYTES: String(1 << 22) });
  host.log_write(0, 0, 1);
  for (let i = 0; i < 8 * 4096; i++) memory[i] = (i >> 12) + 1;
  host.cache_put(0, 1000, 0, 8 * 4096);
  host.cache_put(0, 1000, 0, 2 * 4096);
  assert.equal(host.cache_get(0, 1005, 1 << 21, 4096), 1, "the page of the longer run is no longer cached");
  assert.equal(memory[1 << 21], 6);
}

// The trees' tops are kept apart: however much else is read and let go of, they stay, and a cache let go of as one
// turned over lets go of everything but them.
async function tops_outlast_the_rest(seed) {
  const { s, host, memory } = harness(seed, { CACHE_BYTES: String(1 << 20) });
  host.log_write(0, 0, 1);
  for (let i = 0; i < 4 * 4096; i++) memory[i] = 7;
  host.cache_put(2, 1 << 20, 0, 4 * 4096); // the tops of a pack
  for (let k = 0; k < 400; k++) {
    for (let i = 0; i < 8 * 4096; i++) memory[i] = k & 255;
    host.cache_put(0, (2 << 20) + k * 8, 0, 8 * 4096); // far more pages than there is room for
  }
  assert.equal(host.cache_get(2, (1 << 20) + 3, 1 << 21, 4096), 1, "the tops were let go of to make room for pages");
  assert.equal(host.cache_get(0, (1 << 20) + 3, 1 << 21, 4096), 0, "tops are not pages");
  s.forget(false);
  assert.equal(host.cache_get(2, (1 << 20) + 3, 1 << 21, 4096), 1, "a cache turned over still has its tops");
  assert.equal(host.cache_get(0, (2 << 20) + 399 * 8, 1 << 21, 4096), 0);
  s.forget(true);
  assert.equal(host.cache_get(2, (1 << 20) + 3, 1 << 21, 4096), 0);
  host.cache_put(2, 5 << 20, 0, 4096);
  host.cache_drop(2, 5 << 20, 6 << 20);
  assert.equal(host.cache_get(2, 5 << 20, 1 << 21, 4096), 0, "dropped with its pack");
}

// Read back a little at a time, as replay reads each place it meets, the log costs a row of SQLite read a row of it, not
// a row a read; and what is cut and written again is read as it now is.
async function log_read_a_row_once(seed) {
  const { s, host, memory } = harness(seed);
  for (let i = 0; i < 200; i++) {
    memory.fill(i, 0, 1000);
    assert.equal(host.log_write(i * 1000, 0, 1000), 1); // the first rows whole, the last at hand
  }
  const before = s.stats.rowsRead;
  for (let off = 0; off + 100 <= 64000; off += 100) {
    assert.equal(host.log_read(off, 1 << 21, 100), 1);
    assert.equal(memory[1 << 21], Math.floor(off / 1000));
  }
  assert.ok(s.stats.rowsRead - before <= 4, `${s.stats.rowsRead - before} rows read for one row of log`);
  host.log_cut(30000, 2 ** 64);
  memory.fill(200, 0, 1000);
  assert.equal(host.log_write(30000, 0, 1000), 1);
  assert.equal(host.log_read(30500, 1 << 21, 10), 1);
  assert.equal(memory[1 << 21], 200, "read as it was before it was cut");
  assert.equal(host.log_read(29000, 1 << 21, 10), 1);
  assert.equal(memory[1 << 21], 29);
}

for (let seed = first; seed < first + seeds; seed++) {
  await log_matches(seed);
  await cache_is_sound(seed);
  if (seed % 8 === 0) await full_fails_cleanly(seed);
  if (seed % 10 === 0) await r2_finishes(seed);
  if (seed === first) await cancelled_is_not_started(seed);
  if (seed === first) await nodes_hear_their_own(seed);
  if (seed === first) await the_next_waits_to_say(seed);
  if (seed % 5 === 0) await kept_here_without_a_bucket(seed);
  if (seed % 5 === 0) await full_leaves_nothing_behind(seed);
  if (seed === first) await full_is_heard_by_its_own(seed);
  if (seed % 5 === 0) await kept_here_read_as_wanted(seed);
  if (seed === first) await cached_run_kept_longest(seed);
  if (seed === first) await tops_outlast_the_rest(seed);
  if (seed === first) await log_read_a_row_once(seed);
}
console.log(`ok   relay storage held to its model over ${seeds} seeds`);
