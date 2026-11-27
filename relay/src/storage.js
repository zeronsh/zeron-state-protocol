// Where a relay keeps a space: the Durable Object's own SQLite, and an R2 bucket. See ../../zsp/remote.odin.
//
// SQLite holds the log's tail (what is not yet in R2, or is past the checkpoint), a small manifest naming the trees'
// roots, the roster, and a cache of recently used pages and stretches of log. R2 holds everything else: the log in
// extents, and the trees' pages in packs, never overwritten. The node decides all of it; this only does as it says,
// and tells it when what it started has finished.

const LOG_ROW = 64 << 10; // a row of the log grows, rewritten, up to this: one row written per burst, not one per write
const PAGE = 4096;
const CACHE_ROW = 2 << 20; // storage takes no larger value
const LOG_ROWS_READ = 4; // rows of the log kept as read, for reads of a little of one after another
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
  #made = false; // its tables are there
  #named = false; // and whose space it is is kept
  #tail; // the log's last row, if it may grow: { off, bytes, len }
  #rows = []; // rows of the log lately read, latest first: { off, bytes }. What lies at an offset changes only once cut
  #cached = [0, 0, 0]; // bytes: of pages, of the log, of tops
  #budget;
  #queue = []; // operations to start
  #running = 0;
  #done; // who hears of what finishes: the node of the moment
  #failures = 0; // in a row, for backing off
  stats = { gets: 0, puts: 0, deletes: 0, got: 0, put: 0, rowsWritten: 0, rowsRead: 0, failures: 0 };

  constructor(ctx, env) {
    this.#ctx = ctx;
    this.#env = env;
    this.#sql = ctx.storage.sql;
    // With no bucket bound, objects are kept here too, and a space is kept here alone, as it always was, until full.
    this.#bucket = env.STORE ?? new Here(this);
    this.#made = this.#sql.exec("SELECT name FROM sqlite_master WHERE name = 'kept'").toArray().length > 0;
    const limit = Number(env.STORAGE_LIMIT ?? 0);
    const budget = Number(env.CACHE_BYTES ?? 64 << 20);
    // The cache never crowds out what must be kept: no more than a quarter of what may be kept at all.
    this.#budget = !env.STORE ? 0 : limit > 0 ? Math.min(budget, Math.floor(limit / 4)) : budget;
  }

  get made() {
    return this.#made;
  }

  // Nothing is stored until someone admitted has something to store: merely knocking leaves no trace. Whose space it
  // is is kept before anything else: with no room for it, nothing else is, and the next write keeps it first.
  make(space) {
    if (this.#named) return;
    this.#prefix = hex(space) + "/";
    if (!this.#made) {
      this.#sql.exec("CREATE TABLE IF NOT EXISTS log (off INTEGER PRIMARY KEY, data BLOB) STRICT");
      this.#sql.exec("CREATE TABLE IF NOT EXISTS kept (name TEXT PRIMARY KEY, data BLOB) STRICT");
      this.#tables();
      this.#made = true; // the tables are there, whatever comes of what follows
    }
    if (!this.kept("space")) this.keep("space", space);
    this.#named = true;
  }

  // What there must be, made unless it is there already: past any limit, as it takes nothing when it is.
  #tables() {
    this.#sql.exec("CREATE TABLE IF NOT EXISTS manifest (id INTEGER PRIMARY KEY, data BLOB) STRICT");
    this.#sql.exec("CREATE TABLE IF NOT EXISTS cache0 (key INTEGER PRIMARY KEY, data BLOB) STRICT");
    this.#sql.exec("CREATE TABLE IF NOT EXISTS cache1 (key INTEGER PRIMARY KEY, data BLOB) STRICT");
    this.#sql.exec("CREATE TABLE IF NOT EXISTS cache2 (key INTEGER PRIMARY KEY, data BLOB) STRICT");
    if (!this.#env.STORE) this.#sql.exec("CREATE TABLE IF NOT EXISTS object (key TEXT PRIMARY KEY, data BLOB) WITHOUT ROWID");
  }

  // A space kept wholly in SQLite, as before: its pages are of a format no longer read, and go; its log stays, the
  // store is made again from it, and it moves to R2 an extent at a time.
  open(space) {
    this.#prefix = hex(space) + "/";
    if (!this.#made) return;
    if (this.#sql.exec("SELECT name FROM sqlite_master WHERE name = 'page'").toArray().length > 0) this.#sql.exec("DROP TABLE page");
    this.#tables();
    for (const kind of [0, 1, 2]) {
      this.#cached[kind] = this.#sql.exec(`SELECT coalesce(sum(length(data)), 0) AS n FROM cache${kind}`).one().n;
      this.#trim(kind, 0); // as kept by a relay that shared the room otherwise
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

  // Writes that leave less than there was: past any limit, which they are the way back under.
  #shrink(query, ...args) {
    const cursor = this.#sql.exec(query, ...args);
    cursor.toArray();
    this.stats.rowsWritten += cursor.rowsWritten;
  }

  // For objects kept here.
  select(query, ...args) {
    return this.#read(query, ...args);
  }
  drop(query, ...args) {
    this.#shrink(query, ...args);
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

  // Names and their bytes, one after another, in one statement: all of them kept, or none.
  keep(...named) {
    const rows = Array.from({ length: named.length / 2 }, () => "(?, ?)").join(", ");
    this.write(`INSERT INTO kept VALUES ${rows} ON CONFLICT (name) DO UPDATE SET data = excluded.data`, ...named);
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

  // What is not kept is not remembered either: the tail row changes only once SQLite has it.
  #log_write(off, bytes) {
    const t = this.#tail;
    if (t && off === t.off + t.len && t.len + bytes.length <= LOG_ROW) {
      t.bytes.set(bytes, t.len); // past t.len, where nothing is believed until it is kept
      this.#put_log_row(t.off, t.bytes.subarray(0, t.len + bytes.length));
      t.len += bytes.length;
      return;
    }
    for (let at = 0; at < bytes.length; at += LOG_ROW) {
      const part = bytes.subarray(at, Math.min(bytes.length, at + LOG_ROW));
      this.#put_log_row(off + at, part);
      this.#tail = { off: off + at, bytes: grow(part, LOG_ROW), len: part.length };
    }
  }

  #put_log_row(off, bytes) {
    this.#rows = this.#rows.filter((r) => r.off !== off);
    this.write("INSERT INTO log VALUES (?, ?) ON CONFLICT (off) DO UPDATE SET data = excluded.data", off, bytes);
  }

  #log_read(off, into) {
    const t = this.#tail;
    if (t && off >= t.off && off + into.length <= t.off + t.len) {
      into.set(t.bytes.subarray(off - t.off, off - t.off + into.length));
      return true;
    }
    for (let got = 0; got < into.length; ) {
      const at = off + got;
      let row = this.#rows.find((r) => r.off <= at && at < r.off + r.bytes.length);
      if (!row) {
        const [r] = this.#read("SELECT off, data FROM log WHERE off <= ? ORDER BY off DESC LIMIT 1", at);
        if (!r || at - r.off >= r.data.byteLength) return false;
        row = { off: r.off, bytes: new Uint8Array(r.data) };
        this.#rows.unshift(row);
        if (this.#rows.length > LOG_ROWS_READ) this.#rows.pop();
      }
      const from = at - row.off;
      const part = row.bytes.subarray(from, Math.min(row.bytes.length, from + into.length - got));
      into.set(part, got);
      got += part.length;
    }
    return true;
  }

  // Forgets lo <= offset < hi: the end of the log, or a stretch of it now in R2, or a segment dropped.
  // In an order that loses nothing it keeps, wherever it stops: what lies past the cut is written anew before the row
  // it was in is cut short or goes.
  #log_cut(lo, hi) {
    this.#rows = [];
    const rows = this.#read("SELECT off, length(data) AS n FROM log WHERE off < ? AND off + length(data) > ?", hi, lo);
    for (const { off, n } of rows) {
      const end = off + n;
      if (end > hi) {
        const [{ data }] = this.#read("SELECT data FROM log WHERE off = ?", off);
        this.#shrink("INSERT INTO log VALUES (?, ?) ON CONFLICT (off) DO UPDATE SET data = excluded.data", hi, new Uint8Array(data).subarray(hi - off));
      }
      if (off < lo) this.#shrink("UPDATE log SET data = substr(data, 1, ?) WHERE off = ?", lo - off, off);
      else this.#shrink("DELETE FROM log WHERE off = ?", off);
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
    const at = kind !== 1 ? (key - row.key) * PAGE : key - row.key;
    if (at + into.length > row.data.byteLength) return false;
    into.set(new Uint8Array(row.data, at, into.length));
    return true;
  }

  // Kept if there is room, the oldest let go to make it; never at the cost of what must be kept.
  // Pages half, the log a quarter, and the trees' tops a quarter, apart, so that what else is read never crowds them out.
  #share(kind) {
    return Math.floor((this.#budget * [2, 1, 1][kind]) / 4);
  }

  // Lets go of the oldest, until there is room for `room` more.
  #trim(kind, room) {
    while (this.#cached[kind] + room > this.#share(kind)) {
      const old = this.#read(`SELECT key, length(data) AS n FROM cache${kind} ORDER BY key LIMIT 16`);
      if (old.length === 0) break;
      for (const { key: k, n } of old) {
        this.#shrink(`DELETE FROM cache${kind} WHERE key = ?`, k);
        this.#cached[kind] -= n;
      }
    }
  }

  // Runs never overlap, so that the one a place is in is the last to begin at or before it, and nothing is paid for
  // twice. What lies at a place never changes: what is cached already is not cached again, and a run held whole by
  // this one gives way to it.
  #cache_put(kind, key, bytes) {
    const budget = this.#share(kind), unit = kind === 1 ? 1 : PAGE;
    // A run longer than a row may be, or than there is room for, is kept as far as it fits: its first pages, whole.
    const most = Math.min(CACHE_ROW, budget);
    if (bytes.length > most) bytes = bytes.subarray(0, kind === 1 ? most : most - (most % PAGE));
    if (bytes.length === 0) return;
    let end = key + bytes.length / unit;
    // In one read: the run before, if it runs on into this, and those that begin within.
    const rows = this.#read(
      `SELECT key, length(data) AS n FROM cache${kind} WHERE key >= coalesce((SELECT max(key) FROM cache${kind} WHERE key < ?), ?) AND key < ? AND key + length(data) / ${unit} > ? ORDER BY key`,
      key, key, end, key,
    );
    const held = [];
    for (const r of rows) {
      const to = r.key + r.n / unit;
      if (r.key < key) {
        if (to >= end) return; // all of it is cached already
        bytes = bytes.subarray((to - key) * unit);
        key = to;
      } else if (to > end) {
        end = r.key; // what lies from here on is cached already
        break;
      } else {
        held.push(r);
      }
    }
    if (end <= key) return;
    bytes = bytes.subarray(0, (end - key) * unit);
    try {
      for (const r of held) {
        this.#shrink(`DELETE FROM cache${kind} WHERE key = ?`, r.key);
        this.#cached[kind] -= r.n;
      }
      this.#trim(kind, bytes.length);
      this.write(`INSERT INTO cache${kind} VALUES (?, ?)`, key, bytes.slice());
      this.#cached[kind] += bytes.length;
    } catch (e) {
      if (!(e instanceof Full)) throw e;
    }
  }

  // Lets go of lo <= place < hi: a run that begins before and runs on into it is cut short where it begins.
  #cache_drop(kind, lo, hi) {
    const unit = kind === 1 ? 1 : PAGE;
    const [before] = this.#read(`SELECT key, length(data) AS n FROM cache${kind} WHERE key < ? ORDER BY key DESC LIMIT 1`, lo);
    if (before && before.key + before.n / unit > lo) {
      const n = (lo - before.key) * unit;
      this.#shrink(`UPDATE cache${kind} SET data = substr(data, 1, ?) WHERE key = ?`, n, before.key);
      this.#cached[kind] -= before.n - n;
    }
    const [row] = this.#read(`SELECT coalesce(sum(length(data)), 0) AS n FROM cache${kind} WHERE key >= ? AND key < ?`, lo, hi);
    if (row.n === 0) return;
    this.#shrink(`DELETE FROM cache${kind} WHERE key >= ? AND key < ?`, lo, hi);
    this.#cached[kind] -= row.n;
  }

  // ---------------------------------------------------------------- R2

  // Starts what the node asked for, as many at once as is reasonable. `done(op, ok, absent, bytes, full)` hears of each:
  // the `done` given when it was started, of the node that asked, whatever has become of that node by the time it
  // finishes. `full` is where it was to be kept here, and there was no room.
  run(done) {
    this.#done = done;
    this.#start();
  }

  #start() {
    while (this.#done && this.#queue.length > 0 && this.#running < MOST) {
      const op = this.#queue.shift();
      const done = this.#done;
      this.#running++;
      const finished = this.#do(op).then(
        (r) => r,
        (e) => (e instanceof Full ? { ok: false, full: true } : (console.log("R2", e?.message ?? e), { ok: false })),
      ).then(async (r) => {
        if (r.full) {
          // Kept here, and no room: nothing will make room, so it is said at once, to the node that asked.
          this.#running--;
          done(op, false, false, undefined, true);
          this.#start();
          return;
        }
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
        this.#start(); // for whoever asks now

      });
      this.#ctx.waitUntil(finished);
    }
  }

  // What a node that has been let go of asked for and was not yet started is not: nothing it did not finish is done.
  cancel() {
    this.#queue = [];
    this.#done = undefined; // and what the next asks for waits for it to say who hears of it
  }

  // Lets go of what is cached, here and in SQLite, and of whatever was to be started: for measuring. The trees' tops
  // too, if `all`: else what is let go of is what a cache the budget has wholly turned over would not have.
  forget(all) {
    this.cancel();
    if (!this.#made) return;
    for (const kind of all ? [0, 1, 2] : [0, 1]) {
      this.#shrink(`DELETE FROM cache${kind}`);
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
    if (this.#bucket instanceof Here) {
      // No bucket: nothing but SQLite to measure.
      await time("sqlite sync", 5, () => (this.#sql.exec("SELECT 1"), this.#ctx.storage.sync()));
      return times;
    }
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

// Objects kept in the object's own SQLite, where no bucket is bound: as R2 would keep them, in parts of 1 MiB.
const PART = 1 << 20;
class Here {
  #s;
  constructor(storage) {
    this.#s = storage;
  }
  #key = (key, part) => `${key}#${String(part).padStart(6, "0")}`;
  // Only the parts the range is in are read. Past its end, nothing; of an object never put, null.
  async get(key, { range } = {}) {
    const offset = range?.offset ?? 0, length = range?.length ?? Infinity;
    const first = Math.floor(offset / PART), last = length === Infinity ? Infinity : Math.floor((offset + Math.max(length, 1) - 1) / PART);
    const rows = this.#s.select(
      "SELECT key, data FROM object WHERE key >= ? AND key < ? ORDER BY key",
      this.#key(key, first),
      last === Infinity ? key + "$" : this.#key(key, last + 1),
    );
    if (rows.length === 0 && this.#s.select("SELECT 1 AS x FROM object WHERE key >= ? AND key < ? LIMIT 1", key + "#", key + "$").length === 0) {
      return null;
    }
    const size = rows.reduce((n, r) => n + r.data.byteLength, 0); // of the parts read, from the first
    const out = new Uint8Array(Math.max(0, Math.min(length, first * PART + size - offset)));
    for (let at = 0; at < out.length; ) {
      const off = offset + at, part = new Uint8Array(rows[Math.floor(off / PART) - first].data);
      const n = Math.min(out.length - at, part.length - (off % PART));
      out.set(part.subarray(off % PART, off % PART + n), at);
      at += n;
    }
    return { arrayBuffer: async () => out.buffer };
  }
  // Whole or not at all: what could not all be kept leaves none of itself behind.
  async put(key, body) {
    const bytes = body instanceof Uint8Array ? body : new Uint8Array(body);
    this.#s.drop("DELETE FROM object WHERE key >= ? AND key < ?", key + "#", key + "$");
    try {
      for (let at = 0, part = 0; at < bytes.length || part === 0; at += PART, part++) {
        this.#s.write("INSERT INTO object VALUES (?, ?)", this.#key(key, part), bytes.subarray(at, Math.min(bytes.length, at + PART)));
      }
    } catch (e) {
      this.#s.drop("DELETE FROM object WHERE key >= ? AND key < ?", key + "#", key + "$");
      throw e;
    }
  }
  async delete(keys) {
    for (const key of Array.isArray(keys) ? keys : [keys]) this.#s.drop("DELETE FROM object WHERE key >= ? AND key < ?", key + "#", key + "$");
  }
}

export const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

function grow(bytes, size) {
  const b = new Uint8Array(Math.max(size, bytes.length));
  b.set(bytes);
  return b;
}
