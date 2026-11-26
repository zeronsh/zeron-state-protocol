// The public's way in at the Durable Object relay (relay/src/public.js), held to what its port and its device say:
// `node relay/test/public.mjs`. The platform's own parts are stood in for: a Durable Object, WebSocketPair, and a
// Response of 101.
import { registerHooks } from "node:module";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier === "cloudflare:workers") return { url: "data:text/javascript,export class DurableObject {}", shortCircuit: true };
    return next(specifier, context);
  },
});
const { Call, serve } = await import("../src/public.js");

class Socket {
  listeners = new Map();
  closedWith = null;
  accept() {}
  addEventListener(type, f) {
    this.listeners.set(type, [...(this.listeners.get(type) ?? []), f]);
  }
  emit(type, e) {
    for (const f of this.listeners.get(type) ?? []) f(e);
  }
  send() {}
  close(code, reason) {
    this.closedWith = { code, reason };
  }
}
let lastServer = null; // the relay's end of the last pair made
globalThis.WebSocketPair = class {
  constructor() {
    this[0] = new Socket();
    this[1] = lastServer = new Socket();
  }
};
const RealResponse = globalThis.Response;
globalThis.Response = class extends RealResponse {
  constructor(body, init) {
    super(init?.status === 101 ? null : body, init?.status === 101 ? { status: 200, headers: init.headers } : init);
    if (init?.status === 101) (this.webSocket = init.webSocket), (this.switched = true);
  }
};

const enc = new TextEncoder();
const later = (ms) => new Promise((done) => setTimeout(done, ms));
let failed = false;
const check = (what, ok, detail = "") => {
  if (!ok) (failed = true), console.log(`FAIL ${what} ${detail}`);
};

// A call as the space's object keeps it: what the relay says of it, and whether it would still be kept.
function pipe() {
  const p = { said: [], sent: [], kept: true };
  p.room = () => 262144;
  p.send = (_, bytes) => (p.sent.push(new Uint8Array(bytes)), true);
  p.say = (_, kind) => {
    p.said.push(kind);
    if (kind === 3) p.kept = false;
  };
  p.credit = () => {};
  return p;
}

// A port that switches to a WebSocket and then ends without a Close frame: the call goes with it.
{
  const p = pipe();
  const call = new Call(p, 1);
  setTimeout(() => {
    call.flow(0, new Uint8Array([0]));
    call.flow(0, enc.encode("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"));
    setTimeout(() => call.flow(1, new Uint8Array()), 20);
  }, 10);
  const res = await serve(new Request("https://app.example.test/ws", { headers: { upgrade: "websocket" } }), "app", () => call);
  await later(100);
  check("a WebSocket whose port ended without a word", res.switched && (call.done || !p.kept), JSON.stringify(p.said));
}

// A body that runs to the connection's end, cut off by the device's going: an error, not a whole answer.
{
  const call = new Call(pipe(), 1);
  setTimeout(() => {
    call.flow(0, new Uint8Array([0]));
    call.flow(0, enc.encode("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\npartial-"));
    setTimeout(() => call.flow(2, new Uint8Array([4])), 20);
  }, 10);
  const res = await serve(new Request("https://app.example.test/stream"), "app", () => call);
  let errored = false;
  try {
    await res.text();
  } catch {
    errored = true;
  }
  check("a body cut off by a fault", errored);
}

// A POST with no body says its length, nothing, as HTTP/1.1 servers ask.
{
  const p = pipe();
  const call = new Call(p, 1);
  setTimeout(() => {
    call.flow(0, new Uint8Array([0]));
    call.flow(0, enc.encode("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok"));
    call.flow(1, new Uint8Array());
  }, 10);
  const res = await serve(new Request("https://app.example.test/action", { method: "POST", headers: { "content-length": "0" } }), "app", () => call);
  await res.text();
  const said = new TextDecoder().decode(Buffer.concat(p.sent));
  check("an empty POST", /^content-length: 0\r$/im.test(said), JSON.stringify(said));
}

// A WebSocket switched to, and the call that carries it, as a port says so.
async function switched(p) {
  const call = new Call(p, 1);
  setTimeout(() => {
    call.flow(0, new Uint8Array([0]));
    call.flow(0, enc.encode("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"));
  }, 5);
  await serve(new Request("https://app.example.test/ws", { headers: { upgrade: "websocket" } }), "app", () => call);
  return [call, lastServer];
}

// The public's end closes with no status, or with none at all: the port is told so as WebSocket says it may be (a Close
// frame with no status), never with the codes that only say so where nothing was said (1005, 1006).
for (const code of [1005, 1006, undefined]) {
  const p = pipe();
  const [, server] = await switched(p);
  p.sent.length = 0;
  server.emit("close", { code, reason: "" });
  await later(20);
  const f = p.sent[0] ?? new Uint8Array(2);
  check(`a close with ${code}`, (f[0] & 15) === 8 && (f[1] & 127) === 0, JSON.stringify([...f]));
}

// A close that is more than the port will be sent at once ends the call, and that is all it says: no end after it.
{
  const p = pipe();
  let first = true;
  p.room = () => (first ? ((first = false), 262144) : 0);
  const [, server] = await switched(p);
  server.emit("message", { data: new Uint8Array((1 << 20) - 20) });
  server.emit("close", { code: 1000, reason: "and more than that" });
  await later(20);
  check("a close past what is held", p.said.includes(3) && !p.said.includes(1), JSON.stringify(p.said));
}

if (failed) process.exit(1);
console.log("ok   relay/test/public.mjs");
