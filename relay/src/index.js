// A Zeron State Protocol relay on Durable Objects: one object per space, asleep whenever nobody speaks.
//
// This file is plumbing. The protocol is ../wasm, compiled to relay.wasm; deciding who may use the relay
// is yours: pass `authenticate` to `relay()`.

import { DurableObject } from "cloudflare:workers";
import module from "./relay.wasm";

const CHUNK = 1 << 20; // storage takes no larger value than two of these

const hex = (bytes) => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
const unhex = (s) => Uint8Array.from(s.match(/../g) ?? [], (b) => parseInt(b, 16));

function instantiate(host) {
  let memory;
  const view = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
  const instance = new WebAssembly.Instance(module, {
    host: host(view),
    odin_env: {
      rand_bytes: (ptr, len) => crypto.getRandomValues(view(ptr, len)),
      write: (_fd, ptr, len) => console.log(new TextDecoder().decode(view(ptr, len))),
      trap: () => { throw new Error("trap"); },
      abort: () => { throw new Error("abort"); },
      alert: () => {}, evaluate: () => {}, open: () => {},
      time_now: () => BigInt(Date.now()) * 1000000n,
      tick_now: () => performance.now(),
      time_sleep: () => {},
      sqrt: Math.sqrt, sin: Math.sin, cos: Math.cos, pow: Math.pow, fmuladd: (x, y, z) => x * y + z, ln: Math.log, exp: Math.exp, ldexp: (x, e) => x * 2 ** e,
    },
  });
  memory = instance.exports.memory;
  instance.exports._start?.();
  return { exports: instance.exports, view };
}

const publicKeys = new Map();

/** The public key devices pin, for a 64-digit hex secret. */
export function publicKey(secret) {
  if (!publicKeys.has(secret)) publicKeys.set(secret, derivePublicKey(secret));
  return publicKeys.get(secret);
}

function derivePublicKey(secret) {
  const { exports, view } = instantiate(() => new Proxy({}, { get: () => () => 0 }));
  const ptr = exports.buffer(64);
  view(ptr, 32).set(unhex(secret));
  exports.public(ptr, ptr + 32);
  return hex(view(ptr + 32, 32));
}

export class Space extends DurableObject {
  #sql;
  #wasm;
  #view;
  #sockets = new Map(); // connection number -> WebSocket
  #next = 1;
  #space;
  #made = false; // the tables exist
  #sent = 0;

  constructor(ctx, env) {
    super(ctx, env);
    this.#sql = ctx.storage.sql;
    // Nothing is stored until someone admitted has something to store: merely knocking leaves no trace. Until
    // then a sleeping object's sockets remember which space it is.
    this.#made = this.#sql.exec("SELECT name FROM sqlite_master WHERE name = 'kept'").toArray().length > 0;
    const sockets = ctx.getWebSockets();
    for (const ws of sockets) this.#space ??= ws.deserializeAttachment()?.space;
    this.#space ??= this.#kept("space");
    if (this.#space) console.log("woke with", sockets.length, "sockets"), this.#wake(this.#space);
  }

  #make() {
    if (this.#made) return;
    this.#made = true;
    this.#sql.exec("CREATE TABLE log (off INTEGER PRIMARY KEY, data BLOB) STRICT");
    this.#sql.exec("CREATE TABLE page (no INTEGER PRIMARY KEY, data BLOB) STRICT");
    this.#sql.exec("CREATE TABLE kept (name TEXT PRIMARY KEY, data BLOB) STRICT");
    this.#keep("space", this.#space);
  }

  #kept(name) {
    if (!this.#made) return undefined;
    const [row] = this.#sql.exec("SELECT data FROM kept WHERE name = ?", name).toArray();
    return row && new Uint8Array(row.data);
  }

  #keep(name, bytes) {
    this.#make();
    this.#sql.exec("INSERT OR REPLACE INTO kept VALUES (?, ?)", name, bytes);
  }

  #wake(space) {
    const sql = this.#sql;
    const { exports, view } = instantiate((view) => ({
      log_write: (off, ptr, len) => {
        this.#make();
        for (let at = 0; at < len; at += CHUNK) {
          sql.exec("INSERT OR REPLACE INTO log VALUES (?, ?)", off + at, view(ptr + at, Math.min(CHUNK, len - at)).slice());
        }
      },
      log_read: (off, ptr, len) => {
        if (!this.#made) return 0;
        for (let got = 0; got < len; ) {
          const [row] = sql.exec("SELECT off, data FROM log WHERE off <= ? ORDER BY off DESC LIMIT 1", off + got).toArray();
          const from = row && off + got - row.off;
          if (!row || from >= row.data.byteLength) return 0;
          const part = new Uint8Array(row.data, from, Math.min(len - got, row.data.byteLength - from));
          view(ptr + got, part.length).set(part);
          got += part.length;
        }
        return 1;
      },
      log_end: () => {
        if (!this.#made) return 0;
        const [row] = sql.exec("SELECT off + length(data) AS end FROM log ORDER BY off DESC LIMIT 1").toArray();
        return row?.end ?? 0;
      },
      log_drop: (lo, hi) => void (this.#made && sql.exec("DELETE FROM log WHERE off >= ? AND off < ?", lo, hi)),
      log_truncate: (off) => {
        if (!this.#made) return;
        sql.exec("DELETE FROM log WHERE off >= ?", off);
        sql.exec("UPDATE log SET data = substr(data, 1, ?1 - off) WHERE off < ?1 AND off + length(data) > ?1", off);
      },
      page_read: (no, ptr) => {
        if (!this.#made) return 0;
        const [row] = sql.exec("SELECT data FROM page WHERE no = ?", no).toArray();
        if (!row) return 0;
        view(ptr, row.data.byteLength).set(new Uint8Array(row.data));
        return 1;
      },
      page_write: (no, ptr, len) => {
        this.#make();
        sql.exec("INSERT OR REPLACE INTO page VALUES (?, ?)", no, view(ptr, len).slice());
      },
      save_roster: (ptr, len) => this.#keep("roster", view(ptr, len).slice()),
      authenticate: (id, device, ptr, len) => this.#judge(id, hex(view(device, 32)), view(ptr, len).slice()),
      now: () => Date.now(),
    }));
    this.#wasm = exports;
    this.#view = view;
    const roster = this.#kept("roster") ?? new Uint8Array();
    const ptr = exports.buffer(64 + roster.length);
    view(ptr, 32).set(space);
    view(ptr + 32, 32).set(unhex(this.env.RELAY_SECRET));
    view(ptr + 64, roster.length).set(roster);
    if (!exports.init(ptr, ptr + 32, ptr + 64, roster.length)) throw new Error("storage is damaged");
    let lost = false;
    for (const ws of this.ctx.getWebSockets()) {
      const { id, state } = ws.deserializeAttachment() ?? {};
      if (!state || !this.#put(state, (n) => exports.load(id, n))) {
        ws.close(1012, "resume by reconnecting");
        lost = true;
        continue;
      }
      this.#sockets.set(id, ws);
      this.#next = Math.max(this.#next, id + 1);
    }
    if (lost) exports.present(), this.#settle();
  }

  #put(bytes, then) {
    this.#view(this.#wasm.buffer(bytes.length), bytes.length).set(bytes);
    return then(bytes.length);
  }

  // Runs your policy, which may take its time; the connection's input waits inside.
  #judge(id, device, credential) {
    const space = hex(this.#space);
    const answer = Promise.resolve(policy?.({ space, device, credential, env: this.env }) ?? true);
    this.ctx.waitUntil(
      answer.then(Boolean, () => false).then((yes) => {
        if (!this.#sockets.has(id)) return;
        this.#wasm.verdict(id, yes);
        this.#settle();
      }),
    );
  }

  fetch(request) {
    this.#space ??= unhex(new URL(request.url).pathname.slice(1));
    if (!this.#wasm) this.#wake(this.#space);
    const { 0: client, 1: server } = new WebSocketPair();
    const id = this.#next++;
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ id, space: this.#space });
    this.#sockets.set(id, server);
    this.#wasm.opened(id);
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    const { id } = ws.deserializeAttachment();
    if (typeof message === "string" || !this.#put(new Uint8Array(message), (n) => this.#wasm.received(id, n))) this.#drain(id, ws), this.#drop(id, ws);
    this.#settle();
  }

  webSocketClose(ws) {
    this.#gone(ws);
  }

  webSocketError(ws) {
    this.#gone(ws);
  }

  #gone(ws) {
    const { id } = ws.deserializeAttachment();
    if (!this.#sockets.delete(id)) return;
    this.#wasm.closed(id);
    this.#settle();
  }

  #drop(id, ws) {
    if (!this.#sockets.delete(id)) return;
    this.#wasm.closed(id);
    ws.close(1008, "");
  }

  #drain(id, ws) {
    let n;
    while ((n = this.#wasm.take(id)) > 0) this.#sent++, ws.send(this.#view(this.#wasm.data(), n).slice());
    return n;
  }

  // After every event: make it durable, say what follows from it, and be ready to sleep.
  #settle() {
    this.#wasm.settle();
    // One socket's end may give the others something to hear, so until nobody has anything.
    for (let said = true; said; ) {
      said = false;
      for (const [id, ws] of this.#sockets) {
        try {
          const before = this.#sent;
          if (this.#drain(id, ws) < 0) this.#drop(id, ws), (said = true);
          said ||= this.#sent !== before;
        } catch {
          this.#drop(id, ws);
          said = true;
        }
      }
    }
    for (const [id, ws] of this.#sockets) {
      const n = this.#wasm.save(id);
      const state = n > 0 ? this.#view(this.#wasm.data(), n).slice() : undefined;
      try {
        ws.serializeAttachment({ id, space: this.#space, state });
      } catch {
        ws.serializeAttachment({ id, space: this.#space }); // too much to carry: after a sleep, it reconnects
      }
    }
    this.#wasm.rest();
  }
}

let policy;

/**
 * A Worker that routes each space to its object.
 *
 * `authenticate({ space, device, credential, env })` decides whether a device that has proven its key may
 * use this relay for this space; `credential` is the bytes it presented, sealed to the relay in transit.
 * It may be async. `admit({ request, space, env })`, if given, runs before an object is so much as woken: the
 * place for limits on who may knock at all. What the device may then do is not its business: the space's own signed roster says.
 */
export function relay({ authenticate, admit } = {}) {
  policy = authenticate;
  return {
    async fetch(request, env) {
      const { pathname } = new URL(request.url);
      if (pathname === "/") return new Response(publicKey(env.RELAY_SECRET) + "\n");
      if (!/^\/[0-9a-f]{64}$/.test(pathname)) return new Response("no such space\n", { status: 404 });
      if (request.headers.get("Upgrade") !== "websocket") return new Response("expected a WebSocket\n", { status: 426 });
      if (admit && !(await admit({ request, space: pathname.slice(1), env }))) return new Response("not here\n", { status: 403 });
      return env.SPACE.get(env.SPACE.idFromName(pathname.slice(1))).fetch(request);
    },
  };
}
