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

const tmp = mkdtempSync(join(tmpdir(), "zsp-keep-"));
try {
  const spaceId = execFileSync(ZSPD, ["create", tmp], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sql = new Sql(), sockets = new Set(), serverSockets = [];
  const env = { RELAY_SECRET: relaySecret };
  const ctx = { storage: { sql, sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  let doSpace = new Space(ctx, env);

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
    close() { if (this.readyState !== 3) { this.readyState = 3; sockets.delete(this._s); doSpace.webSocketClose(this._s); } }
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
  clientB.window({ scope: 1, list: "items", table: schema, size: 1000, from: "start" }, (s) => (stateB = s));
  await new Promise((r) => setTimeout(r, 500));
  const [wsA, wsB] = serverSockets;
  const kept = (ws) => ws.attachments.at(-1)?.state !== undefined;
  assert(kept(wsA) && kept(wsB), "quiet before the burst, both are kept");

  // A burst: many messages each way, and only a few attachments for them.
  const messagesBefore = wsA.sent.length + wsB.sent.length, attachmentsBefore = wsA.attachments.length + wsB.attachments.length;
  const ROWS = 300;
  // Right after any message, nothing is kept: whatever was is out of date. It is kept again only between messages.
  const afterEach = [];
  const handle = doSpace.webSocketMessage.bind(doSpace);
  doSpace.webSocketMessage = (ws, m) => (handle(ws, m), afterEach.push(kept(wsA) || kept(wsB)));
  const writes = [];
  for (let i = 1; i <= ROWS; i++) writes.push(clientA.write(1, (ch) => ch.insert(schema, "items", i, { body: new Uint8Array(4000).fill(i & 0xff) })));
  await Promise.all(writes);
  for (let i = 0; i < 2000 && stateB.rows.length < ROWS; i++) await new Promise((r) => setImmediate(r));
  assert.equal(stateB.rows.length, ROWS);
  const messages = wsA.sent.length + wsB.sent.length - messagesBefore, attachments = wsA.attachments.length + wsB.attachments.length - attachmentsBefore;
  assert(messages >= 20, `a burst of ${messages} messages only`);
  assert(attachments <= messages / 4, `${attachments} attachments kept for ${messages} messages`);
  assert(afterEach.length >= 10 && !afterEach.includes(true), "after a message, what was kept is let go of: waking then reconnects");
  delete doSpace.webSocketMessage;

  // Quiet again: all of it is kept, and an object woken from it resumes both connections without a word.
  await new Promise((r) => setTimeout(r, 500));
  assert(kept(wsA) && kept(wsB), "quiet after the burst, both are kept again");
  const closed = [wsA.closed, wsB.closed];
  doSpace = new Space(ctx, env); // as after hibernation: the sockets, their attachments and storage, and nothing else
  assert.deepEqual([wsA.closed, wsB.closed], closed, "woken, it resumed both");
  await clientA.write(1, (ch) => ch.insert(schema, "items", ROWS + 1, { body: new Uint8Array(64).fill(7) }));
  for (let i = 0; i < 2000 && stateB.rows.length < ROWS + 1; i++) await new Promise((r) => setImmediate(r));
  assert.equal(stateB.rows.length, ROWS + 1, "and what is said after waking reaches the other");
  clientA.close(); clientB.close(); await nodeA.close(); await nodeB.close();
  console.log(`ok   a relay keeps its connections for hibernation once a burst is over: ${attachments} attachments for ${messages} messages`);
} finally { rmSync(tmp, { recursive: true, force: true }); }
