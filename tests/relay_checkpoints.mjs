// When the relay's Durable Object checkpoints, run in Node with the real relay.wasm, storage.js and index.js and a web
// device: not while writing goes on, until the log it would replay on waking is long; once writing stops, if it has
// more than a little to replay; and not at all for a little. Needs build/zspd, relay/src/relay.wasm and
// web/src/node.wasm: run by ./x test.
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



// A relay of its own, with a web device to write through it.
async function world(extra) {
  const tmp = mkdtempSync(join(tmpdir(), "zsp-ckpt-"));
  const spaceId = execFileSync(ZSPD, ["create", tmp], { encoding: "utf8" }).trim();
  const relaySecret = "11".repeat(32), relayPub = publicKey(relaySecret);
  const sql = new Sql(), sockets = new Set(), servers = [];
  const env = { RELAY_SECRET: relaySecret, STATS: "1", QUIET_MS: "100", ...extra };
  const ctx = { storage: { sql, sync: async () => {} }, setWebSocketAutoResponse() {}, getWebSockets: () => [...sockets], acceptWebSocket: (w) => sockets.add(w), waitUntil() {} };
  const doSpace = new Space(ctx, env);
  class BridgeWS {
    static OPEN = 1; static CLOSED = 3;
    constructor(url) {
      this.readyState = 0; this.binaryType = "arraybuffer"; this.bufferedAmount = 0; this._l = new Map();
      doSpace.fetch(new Request(url.replace(/^ws/, "http")));
      const { server, pair } = nextPair; this._s = server; servers.push(server);
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
  const vol = new MemoryVolume();
  const st = await Store.open(vol, 64 << 20);
  st.keep("device", readFileSync(join(tmp, "device.key")));
  await st.close();
  const node = await Node.open({ volume: vol, module: mod, WebSocket: BridgeWS, log: () => {} });
  execFileSync(ZSPD, ["relay", tmp, relayPub, "ws://relay.local"]);
  assert(node.adopt(readFileSync(join(tmp, spaceId, "roster"))));
  const client = new Client({ connect: node.connect.bind(node) });
  await new Promise((r) => setTimeout(r, 100));
  const stats = async () => JSON.parse(await (await doSpace.fetch(new Request("http://relay.local/" + spaceId + "?stats"))).text()).node;
  const end = async () => {
    client.close();
    await node.close();
    rmSync(tmp, { recursive: true, force: true });
  };
  return { client, stats, servers, end };
}

const schema = { body: columns.bytes(16) };

{
  const { client, stats, end } = await world({});
  try {
    const s0 = await stats();
    // Writing on, some 600 KiB of it, written as fast as it is taken: no checkpoint until it stops.
    let order = 1;
    for (let i = 0; i < 40; i++) {
      await client.write(1, (ch) => ch.insert(schema, "items", order++, { body: new Uint8Array(16000).fill(i) }));
    }
    const s1 = await stats();
    assert.equal(s1.checkpoints - s0.checkpoints, 0, `${s1.checkpoints - s0.checkpoints} checkpoints while writing went on`);
    assert.ok(s1.tail - s1.checkpoint > 500_000, `only ${s1.tail - s1.checkpoint} to replay`);
    // Stopped: once quiet, it checkpoints, and waking would replay next to nothing.
    await new Promise((r) => setTimeout(r, 600));
    const s2 = await stats();
    assert.equal(s2.checkpoints - s1.checkpoints, 1, `${s2.checkpoints - s1.checkpoints} checkpoints once quiet`);
    assert.ok(s2.tail - s2.checkpoint < 1000, `${s2.tail - s2.checkpoint} left to replay`);
    // A little more, and quiet again: too little to be worth a checkpoint.
    await client.write(1, (ch) => ch.insert(schema, "items", order++, { body: new Uint8Array(2000) }));
    await new Promise((r) => setTimeout(r, 600));
    const s3 = await stats();
    assert.equal(s3.checkpoints, s2.checkpoints, "a checkpoint for a little");
    console.log("ok   a relay checkpoints when writing stops, not while it goes on");
  } finally {
    await end();
  }
}

{
  // A relay that fills, with a checkpoint waiting for quiet: once it has let everyone go, nothing of it is left waiting.
  const armed = new Set(), set = globalThis.setTimeout, clear = globalThis.clearTimeout;
  globalThis.setTimeout = (f, ms, ...a) => {
    const id = set(() => (armed.delete(id), f(...a)), ms);
    if (ms === 60000) armed.add(id);
    return id;
  };
  globalThis.clearTimeout = (id) => (armed.delete(id), clear(id));
  const { client, servers, end } = await world({ STORAGE_LIMIT: "600000", QUIET_MS: "60000" });
  try {
    let order = 1;
    for (let i = 0; i < 40 && !servers.some((w) => w.closed); i++) {
      await Promise.race([client.write(1, (ch) => ch.insert(schema, "items", order++, { body: new Uint8Array(30000).fill(i) })), new Promise((r) => setTimeout(r, 300))]);
    }
    assert.ok(servers.some((w) => w.closed?.code === 1011), "it never filled");
    assert.equal(armed.size, 0, `${armed.size} checkpoint(s) still waiting for quiet once it failed`);
    console.log("ok   a relay that fails leaves nothing waiting");
  } finally {
    for (const id of armed) clear(id);
    globalThis.setTimeout = set;
    globalThis.clearTimeout = clear;
    await end();
  }
}
