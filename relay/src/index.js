// A Zeron State Protocol relay on Durable Objects: one object per space, asleep whenever nobody speaks.
//
// This file is plumbing. The protocol is ../wasm, compiled to relay.wasm; where a space is kept is ./storage.js, the
// object's own SQLite before an R2 bucket bound as STORE; deciding who may use the relay is yours: pass
// `authenticate` to `relay()`.

import { DurableObject } from "cloudflare:workers";
import module from "./relay.wasm";
import { Storage, Full, hex } from "./storage.js";

const FULL = "this relay can keep no more of this space";

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
  #storage;
  #wasm;
  #view;
  #sockets = new Map(); // connection number -> WebSocket
  #next = 1;
  #space;
  #sent = 0;
  #epoch = 0; // of the node: what an earlier one started, it does not hear the end of
  #soon = false; // a settle is due at once
  #full = 0; // when storage last could keep no more: for a while after, nobody is let in
  #broken = false; // storage failed where the node was not there to be told
  #ending = new Set(); // connections whose input failed: let go of once what they have to hear is said, if anything is

  constructor(ctx, env) {
    super(ctx, env);
    // A browser cannot send a WebSocket's own ping, so it says this, which is answered without waking anyone.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    // Nothing is stored until someone admitted has something to store: merely knocking leaves no trace. Until
    // then a sleeping object's sockets remember which space it is.
    this.#storage = new Storage(ctx, env);
    const sockets = ctx.getWebSockets();
    for (const ws of sockets) this.#space ??= ws.deserializeAttachment()?.space;
    this.#space ??= this.#storage.kept("space");
    if (this.#space) console.log("woke with", sockets.length, "sockets"), this.#begin() && this.#settle();
  }

  // Wakes the node, unless storage can keep nothing: then everyone is told so and let go.
  #begin() {
    try {
      this.#wake(this.#space);
    } catch (e) {
      if (!(e instanceof Full)) throw e;
      this.#fail();
      return false;
    }
    return true;
  }

  // Nothing more can be kept: what was not kept was not acknowledged, and every device still has it. Everyone here is
  // told and let go, the node with all it held in memory is let go too, and for a while nobody is let in.
  #fail() {
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.close(1011, FULL);
      } catch {}
    }
    this.#sockets.clear();
    this.#ending.clear();
    this.#wasm = undefined;
    this.#epoch++;
    this.#storage.cancel();
    this.#broken = false;
    this.#full = Date.now();
    console.log(FULL);
  }

  #wake(space) {
    const storage = this.#storage;
    storage.open(space);
    const epoch = ++this.#epoch;
    const { exports, view } = instantiate((view) => ({
      ...storage.imports(view, space),
      save_roster: (ptr, len) => {
        try {
          const old = storage.kept("roster");
          storage.make(space);
          if (old) storage.keep("roster.old", old);
          storage.keep("roster", view(ptr, len).slice());
        } catch (e) {
          if (!(e instanceof Full)) throw e;
          this.#broken = true;
        }
      },
      authenticate: (id, device, ptr, len) => this.#judge(id, hex(view(device, 32)), view(ptr, len).slice()),
      now: () => Date.now(),
    }));
    this.#done = (op, ok, absent, bytes, full) => {
      if (epoch !== this.#epoch || !this.#wasm) return; // an earlier node's, let go of
      if (full) return void this.#fail(); // to be kept here, and no room for it
      const n = bytes?.length ?? 0;
      if (n > 0) this.#view(this.#wasm.buffer(n), n).set(bytes);
      this.#wasm.done(op.id, ok, absent, n);
      this.#settle();
    };
    this.#wasm = exports;
    this.#view = view;
    const old = storage.kept("roster.old") ?? new Uint8Array();
    const roster = storage.kept("roster") ?? new Uint8Array();
    const ptr = exports.buffer(64 + old.length + roster.length);
    view(ptr, 32).set(space);
    view(ptr + 32, 32).set(unhex(this.env.RELAY_SECRET));
    view(ptr + 64, old.length).set(old);
    view(ptr + 64 + old.length, roster.length).set(roster);
    const pages = Number(this.env.PAGES_KEPT ?? 2048), blocks = Number(this.env.BLOCKS_KEPT ?? 64);
    // The log's latest bytes stay here though in R2, for what is shown: 4 MiB, or a quarter of what may be kept here.
    const limit = Number(this.env.STORAGE_LIMIT ?? 0), keep = limit > 0 ? Math.min(4 << 20, Math.floor(limit / 4)) : 4 << 20;
    // And writing waits for R2, should it fall behind, before this storage holds more of the log than 64 MiB, or half of
    // what may be kept here: a space R2 can keep never fills it.
    const most = limit > 0 ? Math.min(64 << 20, Math.floor(limit / 2)) : 64 << 20;
    if (!exports.init(ptr, ptr + 32, ptr + 64, old.length, ptr + 64 + old.length, roster.length, pages, blocks, keep, most)) {
      throw exports.failed() ? new Full(FULL) : new Error("storage is damaged");
    }
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
    const url = new URL(request.url);
    this.#space ??= unhex(url.pathname.slice(1));
    if (this.env.STATS === "1" && url.searchParams.has("stats")) return this.#stats();
    if (this.env.STATS === "1" && url.searchParams.has("evict")) return this.#evict(url.searchParams.get("evict") === "cold");
    if (this.env.STATS === "1" && url.searchParams.has("probe")) return this.#storage.probe().then((t) => new Response(JSON.stringify(t) + "\n"));
    const wait = Number(this.env.FULL_WAIT ?? 60000);
    if (this.#full && Date.now() - this.#full < wait) return new Response(FULL + "\n", { status: 507 });
    if (!this.#wasm && (!this.#begin() || (this.#settle(), !this.#wasm))) return new Response(FULL + "\n", { status: 507 });
    const { 0: client, 1: server } = new WebSocketPair();
    const id = this.#next++;
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ id, space: this.#space });
    this.#sockets.set(id, server);
    this.#wasm.opened(id);
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws, message) {
    if (!this.#wasm) return void ws.close(1011, FULL); // what came before it was let go
    const { id } = ws.deserializeAttachment();
    // Its last words, if any, are said by #settle, and only once what it came to is kept: else, nothing is said at all.
    if (typeof message === "string" || !this.#put(new Uint8Array(message), (n) => this.#wasm.received(id, n))) this.#ending.add(id);
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

  #done;

  // After every event: make it durable, say what follows from it, start fetching what it wants, and be ready to sleep.
  #settle() {
    if (!this.#wasm) return;
    if (this.#broken) return void this.#fail(); // as where the roster could not be kept: nothing more is done
    const more = this.#wasm.settle();
    // What failed to be kept is said to nobody: not passed on, and no session saved as though it had been.
    if (this.#broken || this.#wasm.failed()) return void this.#fail();
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
      for (const id of this.#ending) {
        const ws = this.#sockets.get(id);
        if (ws) this.#drop(id, ws), (said = true);
      }
      this.#ending.clear();
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
    this.#wasm.ops(); // what taking output wanted, fetched now: not when something next happens
    this.#wasm.rest();
    if (this.#broken || this.#wasm.failed()) return void this.#fail();
    this.#storage.run(this.#done);
    if (more && !this.#soon) {
      // There is more it could do at once, as making a store again from a long log: after whatever else is waiting.
      this.#soon = true;
      this.ctx.waitUntil(new Promise((go) => setTimeout(() => (this.#soon = false, this.#settle(), go()), 0)));
    }
  }

  // As though evicted and woken: the node starts again from its sockets and its storage, its own cache kept, or with
  // that let go too where `cold`, so that what a read then costs can be measured. Only where STATS is set.
  #evict(cold) {
    if (this.#wasm) {
      this.#wasm = undefined;
      this.#epoch++;
      this.#sockets.clear();
      this.#storage.cancel();
      if (cold) this.#storage.forget();
      this.#begin() && this.#settle();
    }
    return new Response("evicted\n");
  }

  // What keeping this space has cost so far, for whoever measures: only where STATS is set.
  #stats() {
    const out = { storage: this.#storage.stats, sqlite: this.ctx.storage.sql.databaseSize };
    if (this.#wasm) {
      const n = this.#wasm.stats();
      const d = new DataView(this.#view(this.#wasm.data(), n).slice().buffer);
      const names = ["gets", "puts", "deletes", "got", "put", "checkpoints", "extents", "fetched_pages", "local_hits", "relocated", "dirty", "log_gets", "uploaded", "local_from", "tail"];
      out.node = Object.fromEntries(names.map((k, i) => [k, Number(d.getBigUint64(i * 8, false))]));
      out.memory = this.#wasm.memory.buffer.byteLength;
    }
    return new Response(JSON.stringify(out) + "\n", { headers: { "content-type": "application/json" } });
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
      if (env.STATS === "1" && /[?&](stats|evict|probe)\b/.test(request.url)) return env.SPACE.get(env.SPACE.idFromName(pathname.slice(1))).fetch(request);
      if (request.headers.get("Upgrade") !== "websocket") return new Response("expected a WebSocket\n", { status: 426 });
      if (admit && !(await admit({ request, space: pathname.slice(1), env }))) return new Response("not here\n", { status: 403 });
      return env.SPACE.get(env.SPACE.idFromName(pathname.slice(1))).fetch(request);
    },
  };
}
