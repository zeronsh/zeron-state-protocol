// The relay's Durable Object, run in Node with the real relay.wasm, storage.js and index.js, and two web devices: what
// it fails to keep it passes on to nobody. A device writes past STORAGE_LIMIT; the other never sees what was refused,
// and the writer is let go of. Needs build/zspd, relay/src/relay.wasm and web/src/node.wasm: run by ./x test.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";

// `./x selftest` sets ZSP_FAIL, to see that ./x test says this failed.
if (process.env.ZSP_FAIL) throw new Error("failing, as ZSP_FAIL asks");

const REPO = resolve(".");
const ZSPD = resolve("./build/zspd" + (process.platform === "win32" ? ".exe" : ""));

class Sql {
  constructor() { this.db = new DatabaseSync(":memory:"); this.full = null; }
  get databaseSize() { return this.db.prepare("PRAGMA page_count").get().page_count * this.db.prepare("PRAGMA page_size").get().page_size; }
  exec(query, ...args) {
    if (this.full?.(query, args)) throw new Error("SQLITE_FULL: database or disk is full"); // as the object's says it
    const st = this.db.prepare(query);
    let rows = [], changes = 0;
    if (/^\s*(SELECT|PRAGMA)/i.test(query))
      rows = st.all(...args).map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v instanceof Uint8Array ? v.slice().buffer : v])));
    else changes = st.run(...args.map((a) => (a instanceof Uint8Array ? a.slice() : a))).changes;
    return { toArray: () => rows, one: () => rows[0], rowsRead: rows.length, rowsWritten: changes };
  }
}

registerHooks({
  resolve(spec, ctx, next) {
    if (spec === "cloudflare:workers") return { url: "mock:cf", shortCircuit: true };
    if (spec === "./relay.wasm") return { url: "mock:wasm", shortCircuit: true };
    return next(spec, ctx);
  },
  load(url, ctx, next) {
    if (url === "mock:cf") return { format: "module", shortCircuit: true, source: "export class DurableObject { constructor(c,e){ this.ctx=c; this.env=e; } }" };
    if (url === "mock:wasm") return { format: "module", shortCircuit: true, source: `import { readFileSync } from "node:fs"; export default new WebAssembly.Module(readFileSync(${JSON.stringify(join(REPO, "relay/src/relay.wasm"))}));` };
    return next(url, ctx);
  },
});

globalThis.WebSocketRequestResponsePair = class { constructor(a, b) { this.request = a; this.response = b; } };
const OrigResponse = globalThis.Response;
globalThis.Response = class extends OrigResponse {
  constructor(b, init) { init?.status === 101 ? (super(null, { status: 200 }), (this.webSocket = init.webSocket)) : super(b, init); }
};
class MockServerWS {
  constructor(onSend, onClose) { this._onSend = onSend; this._onClose = onClose; this.sent = []; this.attachments = []; this.closed = null; }
  send(d) { const b = new Uint8Array(d).slice(); this.sent.push(b); this._onSend(b); }
  close(code, reason) { this.closed = { code, reason }; this._onClose(code, reason); }
  serializeAttachment(v) { this._att = structuredClone(v); this.attachments.push(structuredClone(v)); }
  deserializeAttachment() { return this._att; }
}
let nextPair;
globalThis.WebSocketPair = class {
  constructor() {
    const pair = { onMsg: null, onClose: null };
    const server = new MockServerWS((b) => pair.onMsg?.(b), (c, r) => pair.onClose?.(c, r));
    this[0] = {}; this[1] = server; nextPair = { server, pair };
  }
};

const { Space, publicKey, relay } = await import(pathToFileURL(join(REPO, "relay/src/index.js")).href);
const { Node } = await import(pathToFileURL(join(REPO, "web/src/node.ts")).href);
const { Store } = await import(pathToFileURL(join(REPO, "web/src/store.ts")).href);
const { Client, columns } = await import(pathToFileURL(join(REPO, "web/src/client.ts")).href);
const { MemoryVolume } = await import(pathToFileURL(join(REPO, "web/src/volume.ts")).href);
const { loadModule } = await import(pathToFileURL(join(REPO, "web/src/wasm.ts")).href);

const tmp = mkdtempSync(join(tmpdir(), "zsp-r2-"));
try {
  const spaceId = execFileSync(ZSPD, ["create", tmp], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sql = new Sql(), sockets = new Set(), serverSockets = [];
  const env = { RELAY_SECRET: relaySecret, STORAGE_LIMIT: 45_000 };
  const ctx = { storage: { sql, sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const doSpace = new Space(ctx, env);

  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server; serverSockets.push(server);
      pair.onMsg = (b) => { if (this.readyState === 1) this._emit("message", { data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }); };
      pair.onClose = (code, reason) => { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(server); this._emit("close", { code, reason }); } };
      queueMicrotask(() => { this.readyState = 1; this._emit("open", {}); });
    }
    _emit(t, ev) { this["on" + t]?.(ev); for (const f of this._l.get(t) ?? []) f(ev); }
    addEventListener(t, f) { (this._l.get(t) ?? this._l.set(t, new Set()).get(t)).add(f); }
    send(d) { if (this.readyState === 1) { const b = typeof d === "string" ? d : new Uint8Array(d).slice(); queueMicrotask(() => doSpace.webSocketMessage(this._s, b)); } }
    close() { if (this.readyState !== 3) { this.readyState = 3; queueMicrotask(() => { sockets.delete(this._s); doSpace.webSocketClose(this._s); }); } } // after what was sent before it, as a WebSocket's close comes
  }

  const mod = await loadModule();
  const volA = new MemoryVolume();
  const stA = await Store.open(volA, 16 << 20);
  stA.keep("device", readFileSync(join(tmp, "device.key")));
  await stA.close();
  const nodeA = await Node.open({ volume: volA, module: mod, WebSocket: BridgeWS, log: () => {} });
  const nodeB = await Node.open({ volume: new MemoryVolume(), module: mod, WebSocket: BridgeWS, log: () => {} });
  execFileSync(ZSPD, ["relay", tmp, relayPub, "ws://relay.local"]);
  execFileSync(ZSPD, ["admit", tmp, nodeB.key, "1"]);
  const roster = readFileSync(join(tmp, spaceId, "roster"));
  assert(nodeA.adopt(roster) && nodeB.adopt(roster));

  const schema = { body: columns.bytes(16) };
  const clientA = new Client({ connect: nodeA.connect.bind(nodeA) });
  const clientB = new Client({ connect: nodeB.connect.bind(nodeB) });
  let stateB = { rows: [] };
  clientB.window({ scope: 1, list: "items", table: schema, size: 100, from: "start" }, (s) => (stateB = s));
  await new Promise((r) => setTimeout(r, 120));

  // Near STORAGE_LIMIT, 45 KiB, with a cell of 40 KiB; then one that does not fit.
  await clientA.write(1, (ch) => ch.insert(schema, "items", 1, { body: new Uint8Array(40_000).fill(0x11) }));
  await new Promise((r) => setTimeout(r, 120));
  assert.equal(stateB.rows.length, 1);

  const [wsA, wsB] = serverSockets;
  const sentBefore = wsB.sent.length, attBefore = wsA.attachments.length;
  const logBefore = sql.exec("SELECT COALESCE(SUM(length(data)), 0) AS n FROM log").one().n;

  void clientA.write(1, (ch) => ch.insert(schema, "items", 2, { body: new Uint8Array(1000).fill(0xab) }));
  await new Promise((r) => setTimeout(r, 120));

  const logAfter = sql.exec("SELECT COALESCE(SUM(length(data)), 0) AS n FROM log").one().n;
  const bSaw = stateB.rows.some((r) => r.body?.length === 1000 && r.body[0] === 0xab);
  clientA.close(); clientB.close(); await nodeA.close(); await nodeB.close();

  assert.equal(logAfter, logBefore);
  assert.equal(wsA.closed?.code, 1011);
  assert.equal(bSaw, false, `Peer B received unpersisted cell (wsB.sent ${sentBefore}->${wsB.sent.length}, wsA.att ${attBefore}->${wsA.attachments.length})`);
  console.log("ok   a relay that cannot keep a cell passes it on to nobody");
} finally { rmSync(tmp, { recursive: true, force: true }); }

// A device that sends a roster revoking itself to a relay with no room to keep it: the relay says nothing on the
// strength of a roster it did not keep, and lets everyone go as full, rather than turning the device away.
const tmp2 = mkdtempSync(join(tmpdir(), "zsp-r2-"));
try {
  const spaceId = execFileSync(ZSPD, ["create", tmp2], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sql = new Sql(), sockets = new Set(), serverSockets = [];
  const env = { RELAY_SECRET: relaySecret, STORAGE_LIMIT: 45_000 };
  const ctx = { storage: { sql, sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const doSpace = new Space(ctx, env);
  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server; serverSockets.push(server);
      pair.onMsg = (b) => { if (this.readyState === 1) this._emit("message", { data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }); };
      pair.onClose = (code, reason) => { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(server); this._emit("close", { code, reason }); } };
      queueMicrotask(() => { this.readyState = 1; this._emit("open", {}); });
    }
    _emit(t, ev) { this["on" + t]?.(ev); for (const f of this._l.get(t) ?? []) f(ev); }
    addEventListener(t, f) { (this._l.get(t) ?? this._l.set(t, new Set()).get(t)).add(f); }
    send(d) { if (this.readyState === 1) { const b = typeof d === "string" ? d : new Uint8Array(d).slice(); queueMicrotask(() => doSpace.webSocketMessage(this._s, b)); } }
    close() { if (this.readyState !== 3) { this.readyState = 3; queueMicrotask(() => { sockets.delete(this._s); doSpace.webSocketClose(this._s); }); } } // after what was sent before it, as a WebSocket's close comes
  }
  const mod = await loadModule();
  const volA = new MemoryVolume();
  const stA = await Store.open(volA, 16 << 20);
  stA.keep("device", readFileSync(join(tmp2, "device.key")));
  await stA.close();
  const nodeA = await Node.open({ volume: volA, module: mod, WebSocket: BridgeWS, log: () => {} });
  const nodeB = await Node.open({ volume: new MemoryVolume(), module: mod, WebSocket: BridgeWS, log: () => {} });
  execFileSync(ZSPD, ["relay", tmp2, relayPub, "ws://relay.local"]);
  execFileSync(ZSPD, ["admit", tmp2, nodeB.key, "1"]);
  const roster1 = readFileSync(join(tmp2, spaceId, "roster"));
  assert(nodeA.adopt(roster1) && nodeB.adopt(roster1));
  const schema = { body: columns.bytes(16) };
  const clientA = new Client({ connect: nodeA.connect.bind(nodeA) });
  await new Promise((r) => setTimeout(r, 100));
  await clientA.write(1, (ch) => ch.insert(schema, "items", 1, { body: new Uint8Array(40_000).fill(0x11) }));
  await new Promise((r) => setTimeout(r, 120));
  assert(sql.databaseSize > env.STORAGE_LIMIT);
  const rosterBefore = new Uint8Array(sql.exec("SELECT data FROM kept WHERE name = 'roster'").one().data);
  const [, wsB] = serverSockets;
  const sentBefore = wsB.sent.length;
  execFileSync(ZSPD, ["revoke", tmp2, nodeB.key]);
  assert(nodeB.adopt(readFileSync(join(tmp2, spaceId, "roster"))));
  await new Promise((r) => setTimeout(r, 120));
  const rosterAfter = new Uint8Array(sql.exec("SELECT data FROM kept WHERE name = 'roster'").one().data);
  clientA.close(); await nodeA.close(); await nodeB.close();
  assert.deepEqual(rosterAfter, rosterBefore, "the roster with no room for it was not kept");
  assert.equal(wsB.sent.length, sentBefore, `${wsB.sent.length - sentBefore} frame(s) said on the strength of it, and closed with ${wsB.closed?.code}`);
  assert.equal(wsB.closed?.code, 1011);
  console.log("ok   a relay that cannot keep a roster says nothing of it");
} finally { rmSync(tmp2, { recursive: true, force: true }); }

// Bug hunt. A policy that throws, and at once, as one that is not async may: the device is turned away as by any other
// no, and nothing is thrown through the node, which was in the midst of that device's input, nor out of the object.
const tmp3 = mkdtempSync(join(tmpdir(), "zsp-r2-"));
try {
  relay({ authenticate: () => { throw new Error("no such account"); } });
  const spaceId = execFileSync(ZSPD, ["create", tmp3], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sockets = new Set(), serverSockets = [], thrown = [];
  const ctx = { storage: { sql: new Sql(), sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const doSpace = new Space(ctx, { RELAY_SECRET: relaySecret });
  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server; serverSockets.push(server);
      pair.onMsg = (b) => { if (this.readyState === 1) this._emit("message", { data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }); };
      pair.onClose = (code, reason) => { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(server); this._emit("close", { code, reason }); } };
      queueMicrotask(() => { this.readyState = 1; this._emit("open", {}); });
    }
    _emit(t, ev) { this["on" + t]?.(ev); for (const f of this._l.get(t) ?? []) f(ev); }
    addEventListener(t, f) { (this._l.get(t) ?? this._l.set(t, new Set()).get(t)).add(f); }
    send(d) {
      if (this.readyState !== 1) return;
      const b = typeof d === "string" ? d : new Uint8Array(d).slice();
      queueMicrotask(() => { try { doSpace.webSocketMessage(this._s, b); } catch (e) { thrown.push(e.message); } });
    }
    close() { if (this.readyState !== 3) { this.readyState = 3; queueMicrotask(() => { sockets.delete(this._s); doSpace.webSocketClose(this._s); }); } } // after what was sent before it, as a WebSocket's close comes
  }
  const mod = await loadModule();
  const vol = new MemoryVolume();
  const st = await Store.open(vol, 16 << 20);
  st.keep("device", readFileSync(join(tmp3, "device.key")));
  await st.close();
  const node = await Node.open({ volume: vol, module: mod, WebSocket: BridgeWS, log: () => {} });
  execFileSync(ZSPD, ["relay", tmp3, relayPub, "ws://relay.local"]);
  assert(node.adopt(readFileSync(join(tmp3, spaceId, "roster"))));
  for (let i = 0; i < 100 && !serverSockets[0]?.closed && thrown.length === 0; i++) await new Promise((r) => setTimeout(r, 20));
  await node.close();
  assert.deepEqual(thrown, [], "thrown out of the object");
  assert.equal(serverSockets[0]?.closed?.code, 1008, "and the device was not turned away");
  console.log("ok   a relay whose policy throws turns the device away");
} finally { relay({}); rmSync(tmp3, { recursive: true, force: true }); }

// Bug hunt. A roster kept as the latest, with the one before it: where there is no room for the next, neither is
// changed, so that the one before is not lost to the latest standing in for it.
const tmp4 = mkdtempSync(join(tmpdir(), "zsp-r2-"));
try {
  const spaceId = execFileSync(ZSPD, ["create", tmp4], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sql = new Sql(), sockets = new Set(), serverSockets = [];
  const ctx = { storage: { sql, sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const doSpace = new Space(ctx, { RELAY_SECRET: relaySecret });
  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server; serverSockets.push(server);
      pair.onMsg = (b) => { if (this.readyState === 1) this._emit("message", { data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }); };
      pair.onClose = (code, reason) => { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(server); this._emit("close", { code, reason }); } };
      queueMicrotask(() => { this.readyState = 1; this._emit("open", {}); });
    }
    _emit(t, ev) { this["on" + t]?.(ev); for (const f of this._l.get(t) ?? []) f(ev); }
    addEventListener(t, f) { (this._l.get(t) ?? this._l.set(t, new Set()).get(t)).add(f); }
    send(d) { if (this.readyState === 1) { const b = typeof d === "string" ? d : new Uint8Array(d).slice(); queueMicrotask(() => doSpace.webSocketMessage(this._s, b)); } }
    close() { if (this.readyState !== 3) { this.readyState = 3; queueMicrotask(() => { sockets.delete(this._s); doSpace.webSocketClose(this._s); }); } } // after what was sent before it, as a WebSocket's close comes
  }
  const mod = await loadModule();
  const vol = new MemoryVolume();
  const st = await Store.open(vol, 16 << 20);
  st.keep("device", readFileSync(join(tmp4, "device.key")));
  await st.close();
  const node = await Node.open({ volume: vol, module: mod, WebSocket: BridgeWS, log: () => {} });
  const other = await Node.open({ volume: new MemoryVolume(), module: mod, WebSocket: BridgeWS, log: () => {} });
  const roster = () => readFileSync(join(tmp4, spaceId, "roster"));
  const kept = (name) => {
    if (!sql.exec("SELECT name FROM sqlite_master WHERE name = 'kept'").one()) return undefined; // nothing kept yet
    const row = sql.exec("SELECT data FROM kept WHERE name = ?", name).one();
    return row && Buffer.from(row.data);
  };
  const until = async (f) => { for (let i = 0; i < 100 && !f(); i++) await new Promise((r) => setTimeout(r, 20)); return f(); };
  execFileSync(ZSPD, ["relay", tmp4, relayPub, "ws://relay.local"]);
  const first = roster();
  assert(node.adopt(first));
  assert(await until(() => kept("roster")?.equals(first)), "the first roster kept");
  execFileSync(ZSPD, ["admit", tmp4, other.key, "1"]);
  const second = roster();
  assert(node.adopt(second));
  assert(await until(() => kept("roster")?.equals(second) && kept("roster.old")?.equals(first)), "the second kept, the first before it");
  sql.full = (query, args) => /INSERT INTO kept/.test(query) && args.includes("roster"); // no room for the latest
  execFileSync(ZSPD, ["revoke", tmp4, other.key]);
  assert(node.adopt(roster()));
  await until(() => serverSockets[0].closed);
  sql.full = null;
  await node.close(); await other.close();
  assert.equal(serverSockets[0].closed?.code, 1011, "the relay with no room for it did not say so");
  assert(kept("roster").equals(second), "the roster with no room for it is not the latest");
  assert(kept("roster.old").equals(first), "the one before the latest was lost to it");
  console.log("ok   a relay with no room for a roster keeps the two before it as they were");
} finally { rmSync(tmp4, { recursive: true, force: true }); }

// Bug hunt. A WebSocket asked for as RFC 6455 has it, in any case, and among other protocols: let through to its space,
// and nothing else is.
{
  const at = `https://relay.example/${"ab".repeat(32)}`;
  const env = { RELAY_SECRET: "11".repeat(32), SPACE: { idFromName: (name) => name, get: () => ({ fetch: async () => new Response("let through") }) } };
  const worker = relay();
  for (const upgrade of ["websocket", "WebSocket", "WEBSOCKET", "h2c, websocket", "websocket ,h2c"]) {
    const { status } = await worker.fetch(new Request(at, { headers: { Upgrade: upgrade } }), env);
    assert.equal(status, 200, `a WebSocket asked for with Upgrade: ${upgrade} turned away with ${status}`);
  }
  for (const upgrade of [undefined, "h2c", "websockets", "web socket"]) {
    const { status } = await worker.fetch(new Request(at, upgrade && { headers: { Upgrade: upgrade } }), env);
    assert.equal(status, 426, `Upgrade: ${upgrade} let through`);
  }
  console.log("ok   a relay lets a WebSocket through however RFC 6455 lets it be asked for");
}

// Bug hunt. A message longer than a Noise message may be (SPEC §7: the handshake's 104 bytes first, then at most 65535)
// is not taken in, before the handshake or after it: else one, from anyone, would grow the node's memory for good,
// which never shrinks. The connection that sent it is let go of.
{
  const sockets = new Set();
  const ctx = { storage: { sql: new Sql(), sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const doSpace = new Space(ctx, { RELAY_SECRET: "11".repeat(32), STATS: "1" });
  const at = `http://relay.local/${"ab".repeat(32)}`;
  const memory = async () => JSON.parse(await (await doSpace.fetch(new Request(at + "?stats"))).text()).memory;
  doSpace.fetch(new Request(at));
  const { server } = nextPair;
  server._onSend = server._onClose = () => {};
  const before = await memory();
  doSpace.webSocketMessage(server, new Uint8Array(16 << 20).buffer); // before any handshake
  const after = await memory();
  assert.equal(server.closed?.code, 1008, "the connection that sent it was not let go of");
  assert.ok(after - before < 1 << 20, `one message, before any handshake, grew the node's memory from ${before} to ${after}`);
  console.log("ok   a relay takes in no message longer than the handshake before it");
}
// And after it: nothing longer than a Noise message, from a device that has done the handshake.
const tmp5 = mkdtempSync(join(tmpdir(), "zsp-r2-"));
try {
  const spaceId = execFileSync(ZSPD, ["create", tmp5], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sockets = new Set(), serverSockets = [];
  const ctx = { storage: { sql: new Sql(), sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const doSpace = new Space(ctx, { RELAY_SECRET: relaySecret, STATS: "1" });
  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server; serverSockets.push(server);
      pair.onMsg = (b) => { if (this.readyState === 1) this._emit("message", { data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }); };
      pair.onClose = (code, reason) => { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(server); this._emit("close", { code, reason }); } };
      queueMicrotask(() => { this.readyState = 1; this._emit("open", {}); });
    }
    _emit(t, ev) { this["on" + t]?.(ev); for (const f of this._l.get(t) ?? []) f(ev); }
    addEventListener(t, f) { (this._l.get(t) ?? this._l.set(t, new Set()).get(t)).add(f); }
    send(d) { if (this.readyState === 1) { const b = typeof d === "string" ? d : new Uint8Array(d).slice(); queueMicrotask(() => doSpace.webSocketMessage(this._s, b)); } }
    close() { if (this.readyState !== 3) { this.readyState = 3; queueMicrotask(() => { sockets.delete(this._s); doSpace.webSocketClose(this._s); }); } } // after what was sent before it, as a WebSocket's close comes
  }
  const mod = await loadModule();
  const vol = new MemoryVolume();
  const st = await Store.open(vol, 16 << 20);
  st.keep("device", readFileSync(join(tmp5, "device.key")));
  await st.close();
  const node = await Node.open({ volume: vol, module: mod, WebSocket: BridgeWS, log: () => {} });
  execFileSync(ZSPD, ["relay", tmp5, relayPub, "ws://relay.local"]);
  assert(node.adopt(readFileSync(join(tmp5, spaceId, "roster"))));
  const memory = async () => JSON.parse(await (await doSpace.fetch(new Request(`http://relay.local/${spaceId}?stats`))).text()).memory;
  for (let i = 0; i < 100 && !serverSockets[0]?.attachments.at(-1)?.state; i++) await new Promise((r) => setTimeout(r, 20)); // handshake done, kept
  const [ws] = serverSockets;
  assert(ws?.attachments.at(-1)?.state, "the device never connected");
  const before = await memory();
  ws._onClose = () => {}; // its device does not hear of it, and reconnect, while this is measured
  doSpace.webSocketMessage(ws, new Uint8Array(16 << 20).buffer);
  const after = await memory();
  await node.close();
  assert.equal(ws.closed?.code, 1008, "the connection that sent it was not let go of");
  assert.ok(after - before < 1 << 20, `one message, after the handshake, grew the node's memory from ${before} to ${after}`);
  console.log("ok   a relay takes in no message longer than a Noise message after it");
} finally { rmSync(tmp5, { recursive: true, force: true }); }

// Bug hunt. A connection with no session ready HANDSHAKE_MS after it opened is let go of, as zspd lets go of one after
// HANDSHAKE_WAIT: else anyone could hold sockets, and the node's memory for them, for as long as the object is awake.
// One that is ready stays, however long it is quiet.
const tmp6 = mkdtempSync(join(tmpdir(), "zsp-r2-"));
try {
  const spaceId = execFileSync(ZSPD, ["create", tmp6], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sockets = new Set(), serverSockets = [];
  const ctx = { storage: { sql: new Sql(), sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const doSpace = new Space(ctx, { RELAY_SECRET: relaySecret, HANDSHAKE_MS: 300 });
  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server; serverSockets.push(server);
      pair.onMsg = (b) => { if (this.readyState === 1) this._emit("message", { data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }); };
      pair.onClose = (code, reason) => { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(server); this._emit("close", { code, reason }); } };
      queueMicrotask(() => { this.readyState = 1; this._emit("open", {}); });
    }
    _emit(t, ev) { this["on" + t]?.(ev); for (const f of this._l.get(t) ?? []) f(ev); }
    addEventListener(t, f) { (this._l.get(t) ?? this._l.set(t, new Set()).get(t)).add(f); }
    send(d) { if (this.readyState === 1) { const b = typeof d === "string" ? d : new Uint8Array(d).slice(); queueMicrotask(() => doSpace.webSocketMessage(this._s, b)); } }
    close() { if (this.readyState !== 3) { this.readyState = 3; queueMicrotask(() => { sockets.delete(this._s); doSpace.webSocketClose(this._s); }); } } // after what was sent before it, as a WebSocket's close comes
  }
  const mod = await loadModule();
  const vol = new MemoryVolume();
  const st = await Store.open(vol, 16 << 20);
  st.keep("device", readFileSync(join(tmp6, "device.key")));
  await st.close();
  const node = await Node.open({ volume: vol, module: mod, WebSocket: BridgeWS, log: () => {} });
  execFileSync(ZSPD, ["relay", tmp6, relayPub, "ws://relay.local"]);
  assert(node.adopt(readFileSync(join(tmp6, spaceId, "roster"))));
  for (let i = 0; i < 100 && !serverSockets[0]?.attachments.at(-1)?.state; i++) await new Promise((r) => setTimeout(r, 20)); // ready, kept
  const [device] = serverSockets;
  assert(device?.attachments.at(-1)?.state, "the device never connected");
  doSpace.fetch(new Request(`http://relay.local/${spaceId}`)); // and someone who says nothing
  const { server: silent } = nextPair;
  silent._onSend = silent._onClose = () => {};
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(silent.closed, null, "let go of before its time");
  await new Promise((r) => setTimeout(r, 400));
  const closed = silent.closed?.code, deviceClosed = device.closed;
  await node.close();
  assert.equal(closed, 1008, "a connection with no session ready was not let go of");
  assert.equal(deviceClosed, null, "a ready connection was let go of");
  console.log("ok   a relay lets go of a connection with no session ready in HANDSHAKE_MS, and of no other");
} finally { rmSync(tmp6, { recursive: true, force: true }); }

// Bug hunt. Nothing keeps the object awake for connections no longer timed: one let go of for what it sent, or all of
// them as the object is evicted, leaves no HANDSHAKE_MS timer behind.
{
  const live = new Map(), st = globalThis.setTimeout, ct = globalThis.clearTimeout;
  globalThis.setTimeout = (f, ms, ...a) => { const h = st(() => { live.delete(h); f(...a); }, ms); live.set(h, ms); return h; };
  globalThis.clearTimeout = (h) => { live.delete(h); ct(h); };
  const long = () => [...live.values()].filter((ms) => ms >= 30_000).length;
  try {
    const sockets = new Set();
    const ctx = { storage: { sql: new Sql(), sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
    const doSpace = new Space(ctx, { RELAY_SECRET: "11".repeat(32), STATS: "1", HANDSHAKE_MS: 60_000 });
    const at = `http://relay.local/${"ab".repeat(32)}`;
    doSpace.fetch(new Request(at));
    const { server: bad } = nextPair;
    bad._onSend = bad._onClose = () => {};
    assert.equal(long(), 1, "a connection not ready was not timed");
    doSpace.webSocketMessage(bad, new Uint8Array(50).buffer); // no handshake
    assert.equal(bad.closed?.code, 1008);
    assert.equal(long(), 0, "a timer was left for a connection let go of");
    doSpace.fetch(new Request(at));
    const { server: waiting } = nextPair;
    waiting._onSend = waiting._onClose = () => {};
    sockets.add(waiting);
    assert.equal(long(), 1);
    await doSpace.fetch(new Request(at + "?evict=warm"));
    assert.equal(long(), 0, "a timer was left for connections an eviction let go of");
    console.log("ok   a relay keeps no timer for connections it no longer times");
  } finally {
    globalThis.setTimeout = st;
    globalThis.clearTimeout = ct;
  }
}

// Bug hunt. A web device that has joined, with no roster yet, waits at a relay that has none either; let go of only for
// waiting so long, it dials again soon, not ever later: it failed at nothing, and the roster may come at any moment.
const tmp7 = mkdtempSync(join(tmpdir(), "zsp-r2-"));
try {
  const spaceId = execFileSync(ZSPD, ["create", tmp7], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sockets = new Set(), dials = [];
  const ctx = { storage: { sql: new Sql(), sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  // Long enough that the device has said hello before it is let go of, however slow the machine: one let go of before
  // that has failed, and asks again sooner, ever later; so all of what is timed below is waiting.
  const HANDSHAKE_MS = 500;
  const doSpace = new Space(ctx, { RELAY_SECRET: relaySecret, HANDSHAKE_MS });
  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      dials.push(performance.now());
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server;
      pair.onMsg = (b) => { if (this.readyState === 1) this._emit("message", { data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }); };
      pair.onClose = (code, reason) => { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(server); this._emit("close", { code, reason }); } };
      queueMicrotask(() => { this.readyState = 1; this._emit("open", {}); });
    }
    _emit(t, ev) { this["on" + t]?.(ev); for (const f of this._l.get(t) ?? []) f(ev); }
    addEventListener(t, f) { (this._l.get(t) ?? this._l.set(t, new Set()).get(t)).add(f); }
    send(d) { if (this.readyState === 1) { const b = typeof d === "string" ? d : new Uint8Array(d).slice(); queueMicrotask(() => doSpace.webSocketMessage(this._s, b)); } }
    close() { if (this.readyState !== 3) { this.readyState = 3; queueMicrotask(() => { sockets.delete(this._s); doSpace.webSocketClose(this._s); }); } } // after what was sent before it, as a WebSocket's close comes
  }
  const mod = await loadModule();
  const node = await Node.open({ volume: new MemoryVolume(), module: mod, WebSocket: BridgeWS, log: () => {} });
  node.join(spaceId, { key: relayPub, url: "ws://relay.local" });
  for (let i = 0; i < 3000 && dials.length < 6; i++) await new Promise((r) => setTimeout(r, 10));
  await node.close();
  const gaps = dials.slice(1).map((t, i) => Math.round(t - dials[i]));
  // Each gap is HANDSHAKE_MS waited, then about a second, WAITED_REDIAL, and no sooner: a relay that lets it go at once has
  // it dial no faster than that. Counted failures, the first gaps would be shorter (0.7 to 1.1 s) and the last far
  // longer. Less 50 ms below: the node and the relay time by Date.now(), in whole milliseconds that may step, and the
  // gaps are measured by performance.now().
  assert(dials.length >= 6 && gaps.every((g) => g >= HANDSHAKE_MS + 950 && g < HANDSHAKE_MS + 2500), `dialled ${dials.length} times, at gaps of ${gaps.join(", ")} ms`);
  console.log(`ok   a web device waiting at a relay for a roster neither has dials again soon (${gaps.join(", ")} ms)`);
} finally { rmSync(tmp7, { recursive: true, force: true }); }
