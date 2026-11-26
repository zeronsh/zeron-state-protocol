// Where a relay keeps a space: the Durable Object's own SQLite, and an R2 bucket. See ../../zsp/remote.odin.
//
// SQLite holds the log's tail (what is not yet in R2, or is past the checkpoint), a small manifest naming the trees'
// roots, the roster, and a cache of recently used pages and stretches of log. R2 holds everything else: the log in
// extents, and the trees' pages in packs, never overwritten. The node decides all of it; this only does as it says,
// and tells it when what it started has finished.

const LOG_ROW = 64 << 10; // a row of the log grows, rewritten, up to this: one row written per burst, not one per write
const PAGE = 4096;
const CACHE_ROW = 2 << 20; // storage takes no larger value
const GET = 0, LOG = 1, HINTS = 2, PUT_PACK = 3, PUT_EXTENT = 4, DELETE = 5; // Remote_Op_Kind
const MOST = 8; // operations on R2 under way at once
const FULL = "this relay can keep no more of this space";

// What SQLite throws when it can keep no more; and what is thrown here for STORAGE_LIMIT, the same way.
export class Full extends Error {}

export class Storage {
  #ctx;
  #env;
  #sql;
  #bucket;
  #prefix = "";
  #made = false;
  #tail; // the log's last row, if it may grow: { off, bytes, len }
  #cache = [new Map(), new Map()]; // kind -> key -> bytes, once read
  #cached = [0, 0]; // bytes
  #budget;
  #queue = []; // operations to start
  #running = 0;
  #failures = 0; // in a row, for backing off
  stats = { gets: 0, puts: 0, deletes: 0, got: 0, put: 0, rowsWritten: 0, rowsRead: 0, failures: 0 };

  constructor(ctx, env) {
    this.#ctx = ctx;
    this.#env = env;
    this.#sql = ctx.storage.sql;
    this.#bucket = env.STORE;
    this.#made = this.#sql.exec("SELECT name FROM sqlite_master WHERE name = 'kept'").toArray().length > 0;
    const limit = Number(env.STORAGE_LIMIT ?? 0);
    const budget = Number(env.CACHE_BYTES ?? 64 << 20);
    // The cache never crowds out what must be kept: no more than a quarter of what may be kept at all.
    this.#budget = limit > 0 ? Math.min(budget, Math.floor(limit / 4)) : budget;
  }

  get made() {
    return this.#made;
  }

  // Nothing is stored until someone admitted has something to store: merely knocking leaves no trace.
  make(space) {
    if (this.#made) return;
    this.#made = true;
    this.#prefix = hex(space) + "/";
    this.write("CREATE TABLE IF NOT EXISTS log (off INTEGER PRIMARY KEY, data BLOB) STRICT");
    this.write("CREATE TABLE IF NOT EXISTS kept (name TEXT PRIMARY KEY, data BLOB) STRICT");
    this.#tables();
    this.keep("space", space);
  }

  // What there must be, made unless it is there already: past any limit, as it takes nothing when it is.
  #tables() {
    this.#sql.exec("CREATE TABLE IF NOT EXISTS manifest (id INTEGER PRIMARY KEY, data BLOB) STRICT");
    this.#sql.exec("CREATE TABLE IF NOT EXISTS cache0 (key INTEGER PRIMARY KEY, data BLOB) STRICT");
    this.#sql.exec("CREATE TABLE IF NOT EXISTS cache1 (key INTEGER PRIMARY KEY, data BLOB) STRICT");
  }

  // A space kept wholly in SQLite, as before: its pages are of a format no longer read, and go; its log stays, the
  // store is made again from it, and it moves to R2 an extent at a time.
  open(space) {
    this.#prefix = hex(space) + "/";
    if (!this.#made) return;
    if (this.#sql.exec("SELECT name FROM sqlite_master WHERE name = 'page'").toArray().length > 0) this.#sql.exec("DROP TABLE page");
    this.#tables();
    for (const kind of [0, 1]) {
      this.#cached[kind] = this.#sql.exec(`SELECT coalesce(sum(length(data)), 0) AS n FROM cache${kind}`).one().n;
    }
    const [row] = this.#sql.exec("SELECT off, data FROM log ORDER BY off DESC LIMIT 1").toArray();
    this.#tail = row && row.data.byteLength < LOG_ROW ? { off: row.off, bytes: grow(new Uint8Array(row.data), LOG_ROW), len: row.data.byteLength } : undefined;
  }

  // Writes, unless storage is full: a space may be kept up to STORAGE_LIMIT bytes, if that is given, as up to the
  // platform's own limit, past which SQLite throws.
  write(query, ...args) {
    const limit = Number(this.#env.STORAGE_LIMIT ?? 0);
    if (limit > 0 && this.#sql.databaseSize > limit) throw new Full(FULL);
    try {
      const cursor = this.#sql.exec(query, ...args);
      cursor.toArray();
      this.stats.rowsWritten += cursor.rowsWritten;
      return cursor;
    } catch (e) {
      throw /SQLITE_FULL|is full|exceeded|quota/i.test(String(e?.message ?? e)) ? new Full(String(e?.message ?? e)) : e;
    }
  }

  #read(query, ...args) {
    const cursor = this.#sql.exec(query, ...args);
    const rows = cursor.toArray();
    this.stats.rowsRead += cursor.rowsRead;
    return rows;
  }

  kept(name) {
    if (!this.#made) return undefined;
    const [row] = this.#read("SELECT data FROM kept WHERE name = ?", name);
    return row && new Uint8Array(row.data);
  }

  keep(name, bytes) {
    this.write("INSERT INTO kept VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET data = excluded.data", name, bytes);
  }

  // Whether a write the node asked for was kept.
  #kept_if(f) {
    try {
      f();
      return 1;
    } catch (e) {
      if (!(e instanceof Full)) throw e;
      return 0;
    }
  }

  // ---------------------------------------------------------------- what the node imports

  imports(view, space) {
    return {
      log_write: (off, ptr, len) => this.#kept_if(() => (this.make(space), this.#log_write(off, view(ptr, len)))),
      log_read: (off, ptr, len) => (this.#made && this.#log_read(off, view(ptr, len)) ? 1 : 0),
      log_end: () => {
        if (!this.#made) return 0;
        const [row] = this.#read("SELECT off + length(data) AS end FROM log ORDER BY off DESC LIMIT 1");
        return row?.end ?? 0;
      },
      log_cut: (lo, hi) => this.#made && this.#log_cut(lo, hi),
      manifest_size: () => {
        if (!this.#made) return -1;
        const [row] = this.#read("SELECT length(data) AS n FROM manifest WHERE id = 1");
        return row ? row.n : -1;
      },
      manifest_read: (ptr) => {
        const [row] = this.#read("SELECT data FROM manifest WHERE id = 1");
        view(ptr, row.data.byteLength).set(new Uint8Array(row.data));
      },
      manifest_write: (ptr, len) =>
        this.#kept_if(() => (this.make(space), this.write("INSERT INTO manifest VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET data = excluded.data", view(ptr, len).slice()))),
      cache_get: (kind, key, ptr, len) => (this.#made && this.#cache_get(kind, key, view(ptr, len)) ? 1 : 0),
      cache_put: (kind, key, ptr, len) => this.#made && this.#cache_put(kind, key, view(ptr, len)),
      cache_drop: (kind, lo, hi) => this.#made && this.#cache_drop(kind, lo, hi),
      start: (id, kind, number, off, len, ptr, size) => {
        // What it points at is the node's, and may be gone once this returns.
        this.#queue.push({ id, kind, number, off, len, body: size > 0 ? view(ptr, size).slice() : undefined });
      },
    };
  }

  #log_write(off, bytes) {
    const t = this.#tail;
    if (t && off === t.off + t.len && t.len + bytes.length <= LOG_ROW) {
      t.bytes.set(bytes, t.len);
      t.len += bytes.length;
    } else {
      for (let at = 0; at < bytes.length; at += LOG_ROW) {
        const part = bytes.subarray(at, Math.min(bytes.length, at + LOG_ROW));
        this.#tail = { off: off + at, bytes: grow(part, LOG_ROW), len: part.length };
        if (at + LOG_ROW < bytes.length) this.#put_log_row(this.#tail);
      }
    }
    this.#put_log_row(this.#tail);
  }

  #put_log_row(t) {
    this.write("INSERT INTO log VALUES (?, ?) ON CONFLICT (off) DO UPDATE SET data = excluded.data", t.off, t.bytes.subarray(0, t.len));
  }

  #log_read(off, into) {
    const t = this.#tail;
    if (t && off >= t.off && off + into.length <= t.off + t.len) {
      into.set(t.bytes.subarray(off - t.off, off - t.off + into.length));
      return true;
    }
    for (let got = 0; got < into.length; ) {
      const [row] = this.#read("SELECT off, data FROM log WHERE off <= ? ORDER BY off DESC LIMIT 1", off + got);
      const from = row && off + got - row.off;
      if (!row || from >= row.data.byteLength) return false;
      const part = new Uint8Array(row.data, from, Math.min(into.length - got, row.data.byteLength - from));
      into.set(part, got);
      got += part.length;
    }
    return true;
  }

  // Forgets lo <= offset < hi: the end of the log, or a stretch of it now in R2, or a segment dropped.
  #log_cut(lo, hi) {
    const rows = this.#read("SELECT off, length(data) AS n FROM log WHERE off < ? AND off + length(data) > ?", hi, lo);
    for (const { off, n } of rows) {
      const end = off + n;
      if (off >= lo && end <= hi) {
        this.write("DELETE FROM log WHERE off = ?", off);
        continue;
      }
      const [{ data }] = this.#read("SELECT data FROM log WHERE off = ?", off);
      const bytes = new Uint8Array(data);
      this.write("DELETE FROM log WHERE off = ?", off);
      if (off < lo) this.write("INSERT INTO log VALUES (?, ?)", off, bytes.subarray(0, lo - off));
      if (end > hi) this.write("INSERT INTO log VALUES (?, ?)", hi, bytes.subarray(hi - off));
    }
    const t = this.#tail;
    if (t && t.off + t.len > lo && t.off < hi) {
      this.#tail = undefined;
      const [row] = this.#read("SELECT off, data FROM log ORDER BY off DESC LIMIT 1");
      if (row && row.data.byteLength < LOG_ROW) this.#tail = { off: row.off, bytes: grow(new Uint8Array(row.data), LOG_ROW), len: row.data.byteLength };
    }
  }

  #cache_get(kind, key, into) {
    const [row] = this.#read(`SELECT key, data FROM cache${kind} WHERE key <= ? ORDER BY key DESC LIMIT 1`, key);
    if (!row) return false;
    const at = kind === 0 ? (key - row.key) * PAGE : key - row.key;
    if (at + into.length > row.data.byteLength) return false;
    into.set(new Uint8Array(row.data, at, into.length));
    return true;
  }

  // Kept if there is room, the oldest let go to make it; never at the cost of what must be kept.
  #cache_put(kind, key, bytes) {
    const budget = kind === 0 ? Math.floor((this.#budget * 3) / 4) : Math.floor(this.#budget / 4);
    if (bytes.length > CACHE_ROW || bytes.length > budget) return;
    try {
      while (this.#cached[kind] + bytes.length > budget) {
        const old = this.#read(`SELECT key, length(data) AS n FROM cache${kind} ORDER BY key LIMIT 16`);
        if (old.length === 0) break;
        for (const { key: k, n } of old) {
          this.write(`DELETE FROM cache${kind} WHERE key = ?`, k);
          this.#cached[kind] -= n;
        }
      }
      const [had] = this.#read(`SELECT length(data) AS n FROM cache${kind} WHERE key = ?`, key);
      this.write(`INSERT INTO cache${kind} VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET data = excluded.data`, key, bytes.slice());
      this.#cached[kind] += bytes.length - (had?.n ?? 0);
    } catch (e) {
      if (!(e instanceof Full)) throw e;
    }
  }

  #cache_drop(kind, lo, hi) {
    const [row] = this.#read(`SELECT coalesce(sum(length(data)), 0) AS n FROM cache${kind} WHERE key >= ? AND key < ?`, lo, hi);
    if (row.n === 0) return;
    this.write(`DELETE FROM cache${kind} WHERE key >= ? AND key < ?`, lo, hi);
    this.#cached[kind] -= row.n;
  }

  // ---------------------------------------------------------------- R2

  // Starts what the node asked for, as many at once as is reasonable. `done(op, ok, absent, bytes)` hears of each.
  run(done) {
    while (this.#queue.length > 0 && this.#running < MOST) {
      const op = this.#queue.shift();
      this.#running++;
      const finished = this.#do(op).then(
        (r) => r,
        (e) => (console.log("R2", e?.message ?? e), { ok: false }),
      ).then(async (r) => {
        if (!r.ok) {
          // Failing again and again: back off, up to a minute, before the node hears and asks again.
          this.stats.failures++;
          this.#failures++;
          const base = Number(this.#env.R2_BACKOFF ?? 100);
          await new Promise((wake) => setTimeout(wake, Math.min(600 * base, base * 2 ** Math.min(this.#failures, 10))));
        } else {
          this.#failures = 0;
        }
        this.#running--;
        done(op, r.ok, r.absent ?? false, r.bytes);
        this.run(done);
      });
      this.#ctx.waitUntil(finished);
    }
  }

  // Lets go of everything cached, here and in SQLite, and of whatever was to be started: for measuring.
  forget() {
    this.#queue = [];
    if (!this.#made) return;
    for (const kind of [0, 1]) {
      this.write(`DELETE FROM cache${kind}`);
      this.#cached[kind] = 0;
    }
  }

  // How long R2 takes from here: puts and gets of what the node puts and gets, timed, for measuring. Within a request,
  // the clock moves with each answer.
  async probe() {
    const key = this.#prefix + "probe", times = {};
    const median = (a) => a.sort((x, y) => x - y)[a.length >> 1];
    const time = async (what, n, f) => {
      const each = [];
      for (let i = 0; i < n; i++) {
        const began = Date.now();
        await f();
        each.push(Date.now() - began);
      }
      times[what] = median(each);
    };
    await time("put 1 MiB", 3, () => this.#bucket.put(key, new Uint8Array(1 << 20)));
    await time("get 4 KiB", 7, async () => (await this.#bucket.get(key, { range: { offset: 4096, length: 4096 } })).arrayBuffer());
    await time("get 64 KiB", 5, async () => (await this.#bucket.get(key, { range: { offset: 65536, length: 65536 } })).arrayBuffer());
    await time("get 1 MiB", 3, async () => (await this.#bucket.get(key)).arrayBuffer());
    await time("delete", 1, () => this.#bucket.delete(key));
    await time("sqlite sync", 5, () => (this.#sql.exec("SELECT 1"), this.#ctx.storage.sync()));
    return times;
  }

  get busy() {
    return this.#running > 0 || this.#queue.length > 0;
  }

  async #do(op) {
    if (!this.#bucket) return { ok: false }; // no R2 bound: nothing leaves, and the space is kept here until full
    // Nothing starts before what was written before it is durable: a pack before the manifest that spends its
    // generation, an extent before the log it holds, a delete before the manifest that no longer names it.
    await this.#ctx.storage.sync();
    const key = this.#prefix + (op.kind === GET || op.kind === HINTS || op.kind === PUT_PACK ? "p/" : "l/") + op.number;
    switch (op.kind) {
      case GET:
      case LOG:
      case HINTS: {
        this.stats.gets++;
        let object;
        try {
          object = await this.#bucket.get(key, { range: { offset: op.off, length: op.len } });
        } catch (e) {
          if (/range/i.test(String(e?.message ?? e))) return { ok: true, bytes: new Uint8Array() }; // past its end
          throw e;
        }
        if (object === null) return { ok: true, absent: true };
        const bytes = new Uint8Array(await object.arrayBuffer());
        this.stats.got += bytes.length;
        return { ok: true, bytes };
      }
      case PUT_PACK:
        this.stats.puts++;
        this.stats.put += op.body.length;
        await this.#bucket.put(key, op.body);
        return { ok: true };
      case PUT_EXTENT: {
        const bytes = new Uint8Array(op.len);
        if (!this.#log_read(op.off, bytes)) return { ok: false };
        this.stats.puts++;
        this.stats.put += bytes.length;
        await this.#bucket.put(key, bytes);
        return { ok: true };
      }
      case DELETE: {
        const d = new DataView(op.body.buffer, op.body.byteOffset, op.body.byteLength);
        const keys = [];
        for (let at = 0; at + 16 <= d.byteLength; at += 16) {
          const number = Number(d.getBigUint64(at, true));
          keys.push(this.#prefix + (d.getBigUint64(at + 8, true) ? "p/" : "l/") + number);
        }
        this.stats.deletes++;
        await this.#bucket.delete(keys);
        return { ok: true };
      }
    }
    return { ok: false };
  }
}

export const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

function grow(bytes, size) {
  const b = new Uint8Array(Math.max(size, bytes.length));
  b.set(bytes);
  return b;
}
