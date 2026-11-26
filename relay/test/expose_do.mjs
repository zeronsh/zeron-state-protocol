// What a device exposes through the relay's Durable Object, run in Node with the real index.js and relay.wasm and a
// real zspd device: through a node's eviction, a device that comes back before its last connection is known to be
// gone, and a space that is full. Needs build/zspd and relay/src/relay.wasm: run by ./x test.
import assert from "node:assert/strict";
import { execFileSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { DatabaseSync } from "node:sqlite";

const REPO = resolve(".");
const ZSPD = resolve("./build/zspd" + (process.platform === "win32" ? ".exe" : ""));

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

// The platform's parts: a Response of 101, and WebSockets of a pair, each end told what the other says.
const NativeResponse = globalThis.Response;
globalThis.Response = class extends NativeResponse {
  constructor(body, init) {
    super(init?.status === 101 ? null : body, init?.status === 101 ? { status: 200 } : init);
    if (init?.status === 101) (this.webSocket = init.webSocket), (this.switched = true);
  }
};
class Ws {
  attachment = null;
  closed = false;
  serializeAttachment(v) { this.attachment = structuredClone(v); }
  deserializeAttachment() { return this.attachment && structuredClone(this.attachment); }
  send(data) { this.onsend?.(data); }
  close() {
    if (!this.closed) (this.closed = true), this.onclose?.();
  }
}
globalThis.WebSocketRequestResponsePair = class {};
globalThis.WebSocketPair = class {
  constructor() {
    this[0] = new Ws();
    this[1] = new Ws();
  }
};

// SQLite as the object has it, which can be made to be full.
function sql() {
  const db = new DatabaseSync(":memory:");
  const s = {
    full: false,
    get databaseSize() { return 0; },
    exec(query, ...args) {
      if (s.full && /^\s*(CREATE|INSERT|REPLACE|UPDATE)/i.test(query)) throw new Full("database or disk is full: SQLITE_FULL");
      const st = db.prepare(query);
      let rows = [];
      if (/^\s*(SELECT|PRAGMA)/i.test(query))
        rows = st.all(...args).map((r) => Object.fromEntries(Object.entries(r).map(([k, v]) => [k, v instanceof Uint8Array ? v.slice().buffer : v])));
      else st.run(...args.map((a) => (a instanceof ArrayBuffer ? new Uint8Array(a) : a)));
      return { toArray: () => rows, one: () => rows[0], rowsRead: rows.length, rowsWritten: rows.length ? 0 : 1 };
    },
  };
  return s;
}

const { Space, publicKey } = await import("../src/index.js");
const { Full } = await import("../src/storage.js");
const SECRET = "11".repeat(32);
const later = (ms) => new Promise((done) => setTimeout(done, ms));

// A space's object, a WebSocket server in front of it as the Worker would be, and what reaches it from devices. A
// connection whose TCP goes may be left as the object last knew it, as when the platform has yet to notice.
function relay(env = {}, seed = () => {}) {
  const sockets = new Set();
  const store = sql();
  seed(store);
  const ctx = {
    storage: { sql: store, sync: () => Promise.resolve() },
    setWebSocketAutoResponse() {},
    acceptWebSocket: (ws) => void sockets.add(ws),
    getWebSockets: () => [...sockets].filter((w) => !w.closed),
    waitUntil: (p) => void Promise.resolve(p).catch(() => {}),
  };
  const space = new Space(ctx, { RELAY_SECRET: SECRET, EXPOSE_DOMAIN: "expose.test", STATS: "1", ...env });
  const r = { space, store, stale: false, ends: [], conns: [] };
  r.server = createServer((_, res) => res.writeHead(426).end());
  r.server.on("upgrade", (req, socket) => {
    const accept = createHash("sha1").update(req.headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    const res = space.fetch(new Request("http://relay" + req.url, { headers: { Upgrade: "websocket" } }));
    if (!res.switched) return void socket.destroy();
    const ws = [...sockets].pop();
    // What a connection says may be held, and its end too, to be had later: as what is still on its way.
    const conn = { ws, hold: false, held: [], heldEnd: null };
    r.conns.push(conn);
    ws.onsend = (data) => frame(socket, Buffer.from(data));
    ws.onclose = () => (sockets.delete(ws), socket.destroy());
    const end = () => {
      if (ws.closed) return;
      ws.closed = true;
      sockets.delete(ws);
      space.webSocketClose(ws);
    };
    let buf = Buffer.alloc(0);
    socket.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      for (;;) {
        let n = buf.length >= 2 ? buf[1] & 127 : -1, at = 2;
        if (n === 126) (n = buf.length >= 4 ? buf.readUInt16BE(2) : -1), (at = 4);
        else if (n === 127) (n = buf.length >= 10 ? Number(buf.readBigUInt64BE(2)) : -1), (at = 10);
        if (n < 0 || buf.length < at + 4 + n) return;
        const mask = buf.subarray(at, at + 4), data = Buffer.from(buf.subarray(at + 4, at + 4 + n));
        for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
        const op = buf[0] & 15;
        buf = buf.subarray(at + 4 + n);
        if (op === 8) return void (socket.end(), end());
        const message = data.buffer.slice(data.byteOffset, data.byteOffset + data.length);
        if (op === 2) conn.hold ? conn.held.push(message) : space.webSocketMessage(ws, message);
      }
    });
    socket.on("error", () => {});
    socket.on("close", () => (conn.hold ? (conn.heldEnd = end) : r.stale ? r.ends.push(end) : end()));
  });
  return r;
}

function frame(socket, data) {
  const head = data.length < 126 ? Buffer.from([0x82, data.length]) : data.length < 65536 ? Buffer.from([0x82, 126, data.length >> 8, data.length & 255]) : Buffer.concat([Buffer.from([0x82, 127]), Buffer.from(new BigUint64Array([BigInt(data.length)]).buffer).reverse()]);
  if (!socket.destroyed) socket.write(Buffer.concat([head, data]));
}

function device(dir) {
  const p = spawn(ZSPD, ["run", dir, "--no-udp", "--dns=127.0.0.1:0", "--catch=127.0.0.1:0", "--no-proxy"], { stdio: ["ignore", "pipe", "ignore"] });
  return new Promise((done, fail) => {
    let out = "";
    const t = setTimeout(() => fail(new Error("zspd did not start: " + out)), 10000);
    p.stdout.on("data", (d) => (out += d) && out.includes("listening on") && (clearTimeout(t), done(p)));
  });
}

async function eventually(what, f, ms = 10000) {
  for (const until = Date.now() + ms; Date.now() < until; await later(50)) if (await f()) return;
  throw new Error("never: " + what);
}

const z = (...args) => execFileSync(ZSPD, args, { encoding: "utf8" }).trim();
const get = (r, label, path) => r.space.fetch(new Request(`https://${label}.expose.test${path}`, { headers: { "x-zsp-label": label } }));

const dir = mkdtempSync(join(tmpdir(), "zsp-expose-do-"));
const r = relay();
await new Promise((done) => r.server.listen(0, "127.0.0.1", done));
let slow, slowGone = false, arrived;
const backend = createServer((req, res) => {
  if (req.url === "/fast") return void res.writeHead(200, { "content-length": 65536 }).end(Buffer.alloc(65536, 65));
  slow = res;
  req.socket.on("close", () => (slowGone ||= !res.writableEnded));
  arrived?.();
});
backend.httpAllowHalfOpen = true; // the device says the request is over, as the public did, and waits for the answer
await new Promise((done) => backend.listen(0, "127.0.0.1", done));
const procs = [];
let failed = false;
try {
  const space = z("create", dir);
  z("relay", dir, publicKey(SECRET), `ws://127.0.0.1:${r.server.address().port}`);
  procs.push(await device(dir));
  z("expose", dir, String(backend.address().port), "name=app");
  let label = "";
  await eventually("exposed", () => (label = /https:\/\/([a-z0-9-]+)\.expose\.test/.exec(z("exposures", dir))?.[1] ?? ""));

  // An answer whose call is over before its body is read, then a node evicted and woken: another's call there,
  // which may have the same number, is nothing of the first's, whatever becomes of the first's body.
  const first = await get(r, label, "/fast");
  assert.equal(first.status, 200);
  await later(200);
  assert.equal((await r.space.fetch(new Request(`http://relay/${space}?evict`))).status, 200);
  const reached = new Promise((done) => (arrived = done));
  const second = get(r, label, "/slow");
  await reached;
  await first.body.cancel();
  await later(200);
  slow.writeHead(200, { "content-length": 2 }).end("ok");
  const answered = await Promise.race([second.then((res) => res.text()), later(3000).then(() => "never")]);
  if (slowGone || answered !== "ok") (failed = true), console.log(`FAIL another node's call: cut off ${slowGone}, answered ${answered}`);

  // The device comes back on a new connection while the relay still has its last: what it exposes is its own, not
  // taken, and stays when the last is found gone.
  r.stale = true;
  procs.shift().kill("SIGKILL");
  procs.push(await device(dir));
  await eventually("exposed again", () => z("exposures", dir).includes(`https://${label}.expose.test`));
  if (z("exposures", dir).includes("taken")) (failed = true), console.log("FAIL its own label taken: " + z("exposures", dir));
  // Reached on the new connection meanwhile, not on the last, which may be gone.
  const meanwhile = await Promise.race([get(r, label, "/fast"), later(3000).then(() => ({ status: "nothing" }))]);
  if (meanwhile.status !== 200) (failed = true), console.log(`FAIL reached while its last connection stays: ${meanwhile.status}`);
  else await meanwhile.arrayBuffer();
  r.stale = false;
  for (const end of r.ends.splice(0)) end();
  const after = await get(r, label, "/fast");
  if (after.status !== 200) (failed = true), console.log(`FAIL after its last connection went: ${after.status} ${await after.text()}`);
  else await after.arrayBuffer();

  // What a device said on its last connection, still on its way when it comes back on another: when it comes, it does
  // not undo what the device says on its newest, nor does the last one's going then take its labels.
  const last = r.conns.at(-1);
  last.hold = true;
  z("expose", dir, String(backend.address().port + 1), "name=two");
  await eventually("said on the last", () => last.held.length > 0);
  procs.shift().kill("SIGKILL");
  procs.push(await device(dir));
  await eventually("exposed on the newest", () => (z("exposures", dir).match(/https:\/\//g) ?? []).length === 2);
  await eventually("the last one's end on its way", () => last.heldEnd !== null);
  for (const message of last.held.splice(0)) r.space.webSocketMessage(last.ws, message);
  last.hold = false;
  last.heldEnd();
  const late = await get(r, label, "/fast");
  if (late.status !== 200) (failed = true), console.log(`FAIL after what was late on its last connection: ${late.status} ${await late.text()}`);
  else await late.arrayBuffer();

  // A node evicted while a call is under way: the device hears that its calls are over (its connection goes, and it
  // comes back), and lets go of its end of them, rather than keep them for ever, and meet a later call by the number
  // of one it still has open.
  // The device writes down each public connection as it ends: that this one has is how it is seen let go.
  const closes = () => {
    try {
      return readFileSync(join(dir, space, "audit.log"), "utf8").split("\n").filter((l) => l.includes('"service":"public"') && l.includes('"event":"close"')).length;
    } catch {
      return 0;
    }
  };
  const held = new Promise((done) => (arrived = done));
  const pending = get(r, label, "/slow");
  await held;
  await later(300);
  const before = closes();
  assert.equal((await r.space.fetch(new Request(`http://relay/${space}?evict`))).status, 200);
  await pending.then((res) => res.arrayBuffer()).catch(() => {});
  try {
    await eventually("its end of the call let go", () => closes() > before, 5000);
  } catch {
    (failed = true), console.log("FAIL a call under way when the node was evicted: the device kept its end of it");
  }
  await eventually("reached again", async () => {
    const res = await get(r, label, "/fast");
    await res.arrayBuffer();
    return res.status === 200;
  });

  // Full: nobody is let in for a while, and the public neither, nor does the public wake the node to be full again.
  // A space kept here before, whose storage is now full: as it wakes, it finds so.
  const said = [];
  const log = console.log;
  console.log = (...a) => said.push(a.join(" "));
  const f = relay({ FULL_WAIT: "600" }, (store) => {
    store.exec("CREATE TABLE kept (name TEXT PRIMARY KEY, data BLOB) STRICT");
    store.exec("CREATE TABLE log (off INTEGER PRIMARY KEY, data BLOB) STRICT");
    store.exec("INSERT INTO kept (name, data) VALUES ('space', ?)", Buffer.from(space, "hex"));
    store.full = true;
  });
  console.log = log;
  await new Promise((done) => f.server.listen(0, "127.0.0.1", done));
  try {
    let refused;
    console.log = (...a) => said.push(a.join(" "));
    try {
      const first = f.space.fetch(new Request(`http://relay/${space}`, { headers: { Upgrade: "websocket" } }));
      assert(!first.switched && first.status === 507, `let in while full: ${first.status}`);
      await later(200);
      refused = (await get(f, label, "/fast")).status;
    } finally {
      console.log = log;
    }
    const failures = said.filter((s) => s.includes("can keep no more")).length;
    if (refused !== 507 || failures !== 1) (failed = true), console.log(`FAIL the public while full: ${refused}, failed ${failures} times`);
    f.store.full = false;
    await later(450); // past the while begun when it was first found full, though not past one begun again
    const back = f.space.fetch(new Request(`http://relay/${space}`, { headers: { Upgrade: "websocket" } }));
    if (!back.switched) (failed = true), console.log(`FAIL let in again once the while is over: ${back.status}`);
  } finally {
    f.server.close();
  }
} finally {
  for (const p of procs) p.kill("SIGKILL");
  r.server.close();
  backend.close();
  rmSync(dir, { recursive: true, force: true });
}
if (failed) process.exit(1);
console.log("ok   relay/test/expose_do.mjs");
process.exit(0);
