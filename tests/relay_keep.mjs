// The relay's Durable Object, run in Node with the real relay.wasm, storage.js and index.js, and two web devices: what
// it keeps of each connection, for waking after hibernation. Not after every message, which cost a fifth of what the
// object could pass on: once a burst begins, what was kept is let go of, so that waking in its midst reconnects rather
// than resumes from what is out of date; once it is quiet, all of it is kept again, and waking resumes as though nothing
// happened. Needs build/zspd, relay/src/relay.wasm and web/src/node.wasm: run by ./x test.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { pathToFileURL } from "node:url";

const REPO = resolve(".");
const ZSPD = resolve("./build/zspd" + (process.platform === "win32" ? ".exe" : ""));

class Sql {
  constructor() { this.db = new DatabaseSync(":memory:"); }
  get databaseSize() { return this.db.prepare("PRAGMA page_count").get().page_count * this.db.prepare("PRAGMA page_size").get().page_size; }
  exec(query, ...args) {
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

const { Space, publicKey } = await import(pathToFileURL(join(REPO, "relay/src/index.js")).href);
const { Node } = await import(pathToFileURL(join(REPO, "web/src/node.ts")).href);
const { Store } = await import(pathToFileURL(join(REPO, "web/src/store.ts")).href);
const { Client, columns } = await import(pathToFileURL(join(REPO, "web/src/client.ts")).href);
const { MemoryVolume } = await import(pathToFileURL(join(REPO, "web/src/volume.ts")).href);
const { loadModule } = await import(pathToFileURL(join(REPO, "web/src/wasm.ts")).href);

// A relay, as one Durable Object in Node, and `count` web devices of a space at it, each watching one list.
async function relayWith(count, env = {}) {
  const tmp = mkdtempSync(join(tmpdir(), "zsp-keep-"));
  const spaceId = execFileSync(ZSPD, ["create", tmp], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sql = new Sql(), sockets = new Set(), serverSockets = [];
  env = { RELAY_SECRET: relaySecret, ...env };
  const ctx = { storage: { sql, sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const r = { tmp, spaceId, ctx, env, sockets, serverSockets, doSpace: new Space(ctx, env), nodes: [], clients: [], states: [] };

  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      r.doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server; serverSockets.push(server);
      pair.onMsg = (b) => { if (this.readyState === 1) this._emit("message", { data: b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength) }); };
      pair.onClose = (code, reason) => { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(server); this._emit("close", { code, reason }); } };
      queueMicrotask(() => { this.readyState = 1; this._emit("open", {}); });
    }
    _emit(t, ev) { this["on" + t]?.(ev); for (const f of this._l.get(t) ?? []) f(ev); }
    addEventListener(t, f) { (this._l.get(t) ?? this._l.set(t, new Set()).get(t)).add(f); }
    send(d) { if (this.readyState === 1) { const b = typeof d === "string" ? d : new Uint8Array(d).slice(); queueMicrotask(() => r.doSpace.webSocketMessage(this._s, b)); } }
    close() { if (this.readyState !== 3) { this.readyState = 3; queueMicrotask(() => { sockets.delete(this._s); r.doSpace.webSocketClose(this._s); }); } } // after what was sent before it, as a WebSocket's close comes
  }

  const mod = await loadModule();
  const volA = new MemoryVolume();
  const stA = await Store.open(volA, 16 << 20);
  stA.keep("device", readFileSync(join(tmp, "device.key")));
  await stA.close();
  r.nodes.push(await Node.open({ volume: volA, module: mod, WebSocket: BridgeWS, log: () => {} }));
  for (let i = 1; i < count; i++) r.nodes.push(await Node.open({ volume: new MemoryVolume(), module: mod, WebSocket: BridgeWS, log: () => {} }));
  execFileSync(ZSPD, ["relay", tmp, relayPub, "ws://relay.local"]);
  for (const n of r.nodes.slice(1)) execFileSync(ZSPD, ["admit", tmp, n.key, "1"]);
  const roster = readFileSync(join(tmp, spaceId, "roster"));
  for (const n of r.nodes) assert(n.adopt(roster));
  for (const [i, n] of r.nodes.entries()) {
    const c = new Client({ connect: n.connect.bind(n) });
    r.clients.push(c);
    r.states.push({ rows: [] });
    if (i > 0) c.window({ scope: 1, list: "items", table: schema, size: 1000, from: "start" }, (st) => (r.states[i] = st));
    await new Promise((go) => setTimeout(go, 100));
  }
  await new Promise((go) => setTimeout(go, 400));
  r.close = async () => {
    for (const c of r.clients) c.close();
    for (const n of r.nodes) await n.close();
    rmSync(tmp, { recursive: true, force: true });
  };
  return r;
}

const schema = { body: columns.bytes(16) };
const kept = (ws) => ws.attachments.at(-1)?.state !== undefined;
const until = async (f) => { for (let i = 0; i < 2000 && !f(); i++) await new Promise((go) => setImmediate(go)); return f(); };

{
  const r = await relayWith(2);
  try {
    const [wsA, wsB] = r.serverSockets, [clientA] = r.clients;
    assert(kept(wsA) && kept(wsB), "quiet before the burst, both are kept");

    // A burst: many messages each way, and only a few attachments for them.
    const messagesBefore = wsA.sent.length + wsB.sent.length, attachmentsBefore = wsA.attachments.length + wsB.attachments.length;
    const ROWS = 300;
    // Right after any message, nothing is kept: whatever was is out of date. It is kept again only between messages.
    const afterEach = [];
    const handle = r.doSpace.webSocketMessage.bind(r.doSpace);
    r.doSpace.webSocketMessage = (ws, m) => (handle(ws, m), afterEach.push(kept(wsA) || kept(wsB)));
    const writes = [];
    for (let i = 1; i <= ROWS; i++) writes.push(clientA.write(1, (ch) => ch.insert(schema, "items", i, { body: new Uint8Array(4000).fill(i & 0xff) })));
    await Promise.all(writes);
    assert(await until(() => r.states[1].rows.length === ROWS));
    const messages = wsA.sent.length + wsB.sent.length - messagesBefore, attachments = wsA.attachments.length + wsB.attachments.length - attachmentsBefore;
    assert(messages >= 20, `a burst of ${messages} messages only`);
    assert(attachments <= messages / 4, `${attachments} attachments kept for ${messages} messages`);
    assert(afterEach.length >= 10 && !afterEach.includes(true), "after a message, what was kept is let go of: waking then reconnects");
    delete r.doSpace.webSocketMessage;

    // Quiet again: all of it is kept, and an object woken from it resumes both connections without a word.
    await new Promise((go) => setTimeout(go, 500));
    assert(kept(wsA) && kept(wsB), "quiet after the burst, both are kept again");
    const closed = [wsA.closed, wsB.closed];
    r.doSpace = new Space(r.ctx, r.env); // as after hibernation: the sockets, their attachments and storage, and nothing else
    assert.deepEqual([wsA.closed, wsB.closed], closed, "woken, it resumed both");
    await clientA.write(1, (ch) => ch.insert(schema, "items", ROWS + 1, { body: new Uint8Array(64).fill(7) }));
    assert(await until(() => r.states[1].rows.length === ROWS + 1), "and what is said after waking reaches the other");
    console.log(`ok   a relay keeps its connections for hibernation once a burst is over: ${attachments} attachments for ${messages} messages`);
  } finally { await r.close(); }
}

// Review, round 1. A connection whose socket throws, on send and on close, as one already broken may: what the
// others were sent before it is still let go of from what was kept, else waking would resume one of them from a
// count it has already sent under, and seal again under a nonce it had used. Nor does the throw escape.
{
  const r = await relayWith(3);
  try {
    const [wsA, wsB, wsC] = r.serverSockets, [clientA] = r.clients;
    assert(kept(wsA) && kept(wsB) && kept(wsC), "all kept while quiet");
    wsC.send = () => { throw new Error("socket already closed"); };
    wsC.close = () => { throw new Error("socket already closed"); };
    const thrown = [], after = [];
    const handle = r.doSpace.webSocketMessage.bind(r.doSpace);
    r.doSpace.webSocketMessage = (ws, m) => {
      const sentB = wsB.sent.length;
      try { handle(ws, m); } catch (e) { thrown.push(e.message); }
      if (wsB.sent.length > sentB) after.push(kept(wsB));
    };
    await clientA.write(1, (ch) => ch.insert(schema, "items", 1, { body: new Uint8Array(64).fill(1) }));
    assert(await until(() => r.states[1].rows.length === 1));
    delete r.doSpace.webSocketMessage;
    assert.deepEqual(thrown, [], "nothing thrown out of the object");
    assert(after.length > 0 && !after.includes(true), "what B was sent outran nothing kept of it");
    console.log("ok   a relay lets go of what was kept before anything is sent, though a socket throws");
  } finally { await r.close(); }
}

// Review, round 1. Evicted while keeping is due, and woken at once: the object woken keeps its connections once quiet,
// though the one before it had a timer still running.
{
  const r = await relayWith(2, { STATS: "1" });
  try {
    const [clientA] = r.clients;
    await clientA.write(1, (ch) => ch.insert(schema, "items", 1, { body: new Uint8Array(64).fill(1) }));
    await r.doSpace.fetch(new Request(`http://relay.local/${r.spaceId}?evict`));
    await new Promise((go) => setTimeout(go, 400));
    const live = r.ctx.getWebSockets();
    assert(live.length === 2 && live.every(kept), `quiet after an eviction, ${live.filter(kept).length} of ${live.length} kept`);
    console.log("ok   a relay evicted while keeping was due keeps its connections once quiet");
  } finally { await r.close(); }
}

// With PR #5's checkpoint once writing stops: the burst is over, the checkpoint taken when quiet, and only then are
// the connections kept, as they are after it; an object woken from that resumes both, and goes on.
{
  const r = await relayWith(2, { STATS: "1", QUIET_MS: "150", QUIET_TAIL: "1" });
  try {
    const [wsA, wsB] = r.serverSockets, [clientA] = r.clients;
    const checkpoints = async () => JSON.parse(await (await r.doSpace.fetch(new Request(`http://relay.local/${r.spaceId}?stats`))).text()).node.checkpoints;
    const before = await checkpoints();
    const writes = [];
    for (let i = 1; i <= 40; i++) writes.push(clientA.write(1, (ch) => ch.insert(schema, "items", i, { body: new Uint8Array(4000).fill(i) })));
    await Promise.all(writes);
    assert(await until(() => r.states[1].rows.length === 40));
    await new Promise((go) => setTimeout(go, 800));
    assert((await checkpoints()) > before, "a checkpoint once writing stopped");
    assert(kept(wsA) && kept(wsB), "and both kept after it");
    const closed = [wsA.closed, wsB.closed];
    r.doSpace = new Space(r.ctx, r.env);
    assert.deepEqual([wsA.closed, wsB.closed], closed, "woken, it resumed both");
    await clientA.write(1, (ch) => ch.insert(schema, "items", 41, { body: new Uint8Array(64).fill(7) }));
    assert(await until(() => r.states[1].rows.length === 41), "and what is said after waking reaches the other");
    console.log("ok   a relay that checkpoints once quiet keeps its connections after the checkpoint, and resumes them");
  } finally { await r.close(); }
}

// Review of the strip, round 1. What a relay kept before this one, which began with how many exposures the connection
// had, is not resumed as though it were this one's: that connection is told to reconnect, and the others resume.
{
  const r = await relayWith(2);
  try {
    const [wsA, wsB] = r.serverSockets, [clientA] = r.clients;
    await new Promise((go) => setTimeout(go, 300));
    assert(kept(wsA) && kept(wsB), "both kept while quiet");
    const state = wsB._att.state;
    wsB._att = { ...wsB._att, state: Uint8Array.from([0, ...state.subarray(1)]) }; // no exposures, as the old relay said it
    const closedA = wsA.closed;
    r.doSpace = new Space(r.ctx, r.env);
    assert.deepEqual(wsA.closed, closedA, "woken, it resumed the one it kept");
    assert.equal(wsB.closed?.code, 1012, "and told the other, kept by another relay, to reconnect");
    await clientA.write(1, (ch) => ch.insert(schema, "items", 1, { body: new Uint8Array(64).fill(1) }));
    for (let i = 0; i < 200 && r.states[1].rows.length !== 1; i++) await new Promise((go) => setTimeout(go, 50)); // it reconnects in its own time
    assert.equal(r.states[1].rows.length, 1, "which it does, and hears what is said");
    console.log("ok   a relay resumes only connections it kept itself");
  } finally { await r.close(); }
}

// Bug hunt. Woken with connections it did not keep, which it tells to reconnect, one of them already closed: telling
// that one throws, and nothing else is the worse for it; and no connection that comes next is given the number of one
// told to go, whose close, and whatever it was still sending, the runtime may yet hand over. Those are let go of; the
// one with its number is not.
{
  const r = await relayWith(3);
  try {
    const [wsA, wsB, wsC] = r.serverSockets, [clientA] = r.clients;
    await new Promise((go) => setTimeout(go, 300));
    assert(kept(wsA) && kept(wsB) && kept(wsC), "all kept while quiet");
    for (const ws of [wsB, wsC]) ws._att = { id: ws._att.id, space: ws._att.space }; // not kept, as when opened in the burst before
    wsC.close = () => { throw new Error("socket already closed"); };
    const closedA = wsA.closed;
    r.doSpace = new Space(r.ctx, r.env);
    assert.deepEqual(wsA.closed, closedA, "woken, it resumed the one it kept");
    assert.equal(wsB.closed?.code, 1012, "and told the other to reconnect");
    for (let i = 0; i < 200 && r.serverSockets.length < 4; i++) await new Promise((go) => setTimeout(go, 50)); // in its own time
    const wsB2 = r.serverSockets[3];
    assert(wsB2, "it reconnected");
    for (let i = 0; i < 100 && !kept(wsB2); i++) await new Promise((go) => setTimeout(go, 20)); // and is level
    r.doSpace.webSocketMessage(wsB, new Uint8Array(64)); // what the one told to go was still sending
    assert.equal(wsB2.closed, null, "the one that reconnected was let go of for what the other sent");
    r.doSpace.webSocketClose(wsB); // and its close, heard of at last
    r.doSpace.webSocketClose(wsC);
    await clientA.write(1, (ch) => ch.insert(schema, "items", 1, { body: new Uint8Array(64).fill(1) }));
    for (let i = 0; i < 100 && r.states[1].rows.length !== 1; i++) await new Promise((go) => setTimeout(go, 20));
    assert.equal(r.states[1].rows.length, 1, "what is said after reaches the one that reconnected");
    assert.equal(wsB2.closed, null);
    assert.equal(r.serverSockets.length, 4, "without its reconnecting again");
    console.log("ok   a relay woken never gives a connection the number of one it told to go");
  } finally { await r.close(); }
}

// Bug hunt. A connection whose attachment cannot be let go of when another connects is let go of itself: and the others
// hear that it went at once, not when something next happens, and so are kept again once quiet.
{
  const r = await relayWith(2);
  try {
    const [wsA, wsB] = r.serverSockets;
    await new Promise((go) => setTimeout(go, 300));
    assert(kept(wsA) && kept(wsB), "both kept while quiet");
    wsA.serializeAttachment = () => { throw new Error("socket already closed"); };
    wsA._onClose = () => {}; // nor does its device hear of it, and reconnect: nothing else happens
    const sentB = wsB.sent.length;
    r.doSpace.fetch(new Request(`http://relay.local/${r.spaceId}`)); // another connects
    assert.equal(wsA.closed?.code, 1008, "the one that could not be let go of was");
    assert(wsB.sent.length > sentB, "the other heard nothing of it");
    await new Promise((go) => setTimeout(go, 300));
    assert(kept(wsB), "and was not kept again once quiet");
    console.log("ok   a relay that lets a connection go as another connects tells the rest at once");
  } finally { await r.close(); }
}
