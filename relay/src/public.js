import { DurableObject } from "cloudflare:workers";

// The public's way in to what a device exposes, on a Durable Object (SPEC §17): an HTTP request, or a WebSocket, as
// the bytes of HTTP/1.1 in a zsp.public call to the device, and its answer back as a Response. Nothing is kept but
// what is in flight: the request's body is read only as the device grants room for it, and the device is granted
// room only as the answer is taken. Cloudflare terminates TLS, so the relay sees what passes, as any reverse proxy
// that holds the certificate must.

const enc = new TextEncoder();
const dec = new TextDecoder();
const HOP = new Set(["connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer", "proxy-authorization", "proxy-authenticate", "host", "content-length"]);
const HEAD_MAX = 64 << 10;
const WS_QUEUE = 1 << 20; // a WebSocket's messages may wait this much for room, and no more: the platform says nothing of its own
const WS_MESSAGE_MAX = 1 << 20; // a message from the device, as the platform takes no larger

const cat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) out.set(p, at), (at += p.length);
  return out;
};

/** A zsp.public call, as the bytes the device says in it and the room it gives. `pipe` is the space's wasm. */
export class Call {
  constructor(pipe, id) {
    this.pipe = pipe;
    this.id = id;
    this.queue = []; // what the device said, not yet taken
    this.ended = false; // the device has said all
    this.fault = null;
    this.status = null; // the device's first word: connected, or why not
    this.waiting = []; // readers and those waiting for room
    this.owed = 0; // room to give back, once out of the node's own turn
  }

  // Gives room back: never from within the node, which is speaking when it tells of flow.
  give(n) {
    if (n <= 0) return;
    if (!this.owed) queueMicrotask(() => {
      const n = this.owed;
      this.owed = 0;
      if (!this.fault) this.pipe.credit(this.id, n);
    });
    this.owed += n;
  }

  // What the device says: kind 0 Data, 1 End, 2 Fault, 3 Cancel, 4 Credit.
  flow(kind, bytes) {
    if (kind === 0) {
      if (this.status === null) {
        this.status = bytes[0] ?? 255;
        this.give(1);
        bytes = bytes.subarray(1);
        if (!bytes.length) return this.wake();
      }
      this.queue.push({ bytes, given: false });
    } else if (kind === 1) this.ended = true;
    else if (kind === 2 || kind === 3) this.fault = kind === 2 ? `fault ${bytes[0]}` : "cancelled";
    this.wake();
  }

  wake() {
    const waiting = this.waiting;
    this.waiting = [];
    for (const w of waiting) w();
  }

  next() {
    return new Promise((resolve) => this.waiting.push(resolve));
  }

  /** Whether the device connected. */
  async connected() {
    while (this.status === null && !this.fault && !this.ended) await this.next();
    return this.status === 0;
  }

  /** The next bytes the device says, or null once it has said all; room is given back as they are taken. */
  async read() {
    while (!this.queue.length) {
      if (this.ended || this.fault) return null;
      await this.next();
    }
    const { bytes, given } = this.queue.shift();
    if (!given) this.give(bytes.length);
    return bytes;
  }

  /** Puts bytes back, as when more was read than a head: their room was given already. */
  unread(bytes) {
    if (bytes.length) this.queue.unshift({ bytes, given: true });
  }

  /** Says bytes to the device, waiting for room as it must. False if the call is over. */
  async write(bytes) {
    for (let at = 0; at < bytes.length; ) {
      if (this.fault) return false;
      const room = this.pipe.room(this.id);
      if (room <= 0) {
        await this.next();
        continue;
      }
      const n = Math.min(room, bytes.length - at, 60 << 10);
      if (!this.pipe.send(this.id, bytes.subarray(at, at + n))) return false;
      at += n;
    }
    return true;
  }

  end() {
    if (this.fault !== null || this.endedOut) return; // cancelled, or said: nothing more of it
    this.endedOut = true;
    this.pipe.say(this.id, 1);
  }

  /** Over, both ways. */
  get done() {
    return this.fault !== null || (this.ended && this.endedOut);
  }

  cancel() {
    if (this.fault) return; // over already: nothing to say
    this.pipe.say(this.id, 3);
    this.fault = "cancelled";
    this.wake(); // whoever waits to read or write hears it is over
  }
}

// Reads a response's head: status, headers, and the rest of what was read.
async function readHead(call) {
  let got = new Uint8Array(0);
  for (;;) {
    const end = findHeadEnd(got);
    if (end >= 0) {
      const lines = dec.decode(got.subarray(0, end)).split("\r\n");
      const [, code, ...reason] = lines[0].split(" ");
      const headers = [];
      for (const line of lines.slice(1)) {
        const colon = line.indexOf(":");
        if (colon > 0) headers.push([line.slice(0, colon).trim(), line.slice(colon + 1).trim()]);
      }
      call.unread(got.subarray(end + 4));
      return { status: Number(code), reason: reason.join(" "), headers };
    }
    if (got.length > HEAD_MAX) return null;
    const more = await call.read();
    if (!more) return null;
    got = cat(got, more);
  }
}

function findHeadEnd(b) {
  for (let i = 3; i < b.length; i++) if (b[i] === 10 && b[i - 1] === 13 && b[i - 2] === 10 && b[i - 3] === 13) return i - 3;
  return -1;
}

// The body of a response, as a stream that pulls from the device only as it is read.
function body(call, framing, length) {
  let left = length, chunk = 0, buf = new Uint8Array(0);
  // The whole of it has come: the call goes too, whether or not the port, asked to close, does.
  const done = (controller) => {
    controller.close();
    call.cancel();
  };
  // Nothing sensible came, or not all of it: the call goes too, as an error does not cancel the stream's source.
  const fail = (controller, why) => {
    call.cancel();
    controller.error(new Error(why));
  };
  const more = async () => {
    const b = await call.read();
    if (!b) return false;
    buf = cat(buf, b);
    return true;
  };
  return new ReadableStream(
    {
      async pull(controller) {
        if (framing === "length") {
          if (left === 0) return done(controller);
          if (!buf.length && !(await more())) return fail(controller, "the device ended short");
          const n = Math.min(left, buf.length);
          controller.enqueue(buf.subarray(0, n));
          buf = buf.subarray(n);
          left -= n;
          if (left === 0) done(controller);
        } else if (framing === "chunked") {
          for (;;) {
            if (chunk > 0) {
              if (!buf.length && !(await more())) return fail(controller, "the device ended short");
              const n = Math.min(chunk, buf.length);
              controller.enqueue(buf.subarray(0, n));
              buf = buf.subarray(n);
              chunk -= n;
              if (chunk === 0) chunk = -2; // its CRLF to come
              return;
            }
            const eol = buf.indexOf(10);
            if (eol < 0) {
              if (buf.length > 4096 || !(await more())) return fail(controller, "a chunk makes no sense");
              continue;
            }
            const line = dec.decode(buf.subarray(0, eol)).replace(/\r$/, "");
            buf = buf.subarray(eol + 1);
            if (chunk === -2) {
              if (line !== "") return fail(controller, "a chunk makes no sense"); // its CRLF, and nothing else
              chunk = 0;
              continue;
            }
            // Hex digits, then extensions if any: nothing else is a size (not "-2", not "5GARBAGE").
            const sizeText = line.split(";")[0].trim();
            if (!/^[0-9a-fA-F]{1,15}$/.test(sizeText)) return fail(controller, "a chunk makes no sense");
            const size = parseInt(sizeText, 16);
            if (size === 0) return done(controller); // trailers, if any, go unread
            chunk = size;
          }
        } else {
          if (buf.length) {
            controller.enqueue(buf);
            buf = new Uint8Array(0);
            return;
          }
          const b = await call.read();
          if (b) controller.enqueue(b);
          else if (call.fault) fail(controller, "the device was lost"); // an end that is not one: the body is cut short
          else done(controller);
        }
      },
      cancel() {
        call.cancel();
      },
    },
    { highWaterMark: 0 },
  );
}

function requestHead(request, url, extra) {
  let head = `${request.method} ${url.pathname}${url.search} HTTP/1.1\r\nHost: ${url.host}\r\n`;
  for (const [name, value] of request.headers) {
    const lower = name.toLowerCase();
    if (!HOP.has(lower) && !lower.startsWith("cf-") && !lower.startsWith("sec-websocket-") && !lower.startsWith("x-zsp-")) head += `${name}: ${value}\r\n`;
  }
  return head + extra + "\r\n";
}

/**
 * Answers a request from the public with what the device that exposes `label` says to it. `open` makes the call:
 * open(label, address) gives a Call, or null if the label is nobody's here.
 */
export async function serve(request, label, open) {
  const url = new URL(request.headers.get("x-zsp-url") ?? request.url); // as the public asked it
  const ip = request.headers.get("cf-connecting-ip") ?? "";
  const call = open(label, ip);
  if (!call) return new Response("nothing is exposed here\n", { status: 404 });
  try {
    if (!(await call.connected())) {
      call.cancel();
      return new Response("what is exposed here is not answering\n", { status: 502 });
    }
    if (request.headers.get("upgrade")?.toLowerCase() === "websocket") return await socket(request, url, call);
    const length = request.headers.get("content-length");
    const hasBody = request.body && !["GET", "HEAD"].includes(request.method);
    // A request with no body says so where it could have one (a POST, a PUT), as servers ask of HTTP/1.1.
    const framing = hasBody ? (length !== null ? `Content-Length: ${length}\r\n` : "Transfer-Encoding: chunked\r\n") : ["GET", "HEAD"].includes(request.method) ? "" : "Content-Length: 0\r\n";
    if (!(await call.write(enc.encode(requestHead(request, url, framing + "Connection: close\r\n"))))) throw new Error("lost");
    if (hasBody) {
      const reader = request.body.getReader();
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        if (length === null) {
          if (value.length && !(await call.write(cat(enc.encode(value.length.toString(16) + "\r\n"), value, enc.encode("\r\n"))))) throw new Error("lost");
        } else if (!(await call.write(value))) throw new Error("lost");
      }
      if (length === null && !(await call.write(enc.encode("0\r\n\r\n")))) throw new Error("lost");
    }
    call.end();
    let head = await readHead(call);
    while (head && head.status >= 100 && head.status < 200 && head.status !== 101) head = await readHead(call); // interim: 100 Continue, 103
    const nonsense = () => {
      call.cancel();
      return new Response("what is exposed here said nothing sensible\n", { status: 502 });
    };
    if (!head || !(head.status >= 200 && head.status <= 599)) return nonsense(); // 101 too: nobody asked it to switch
    const headers = new Headers();
    let framingOut = "close", left = 0, said = null;
    for (const [name, value] of head.headers) {
      const lower = name.toLowerCase();
      if (lower === "transfer-encoding" && value.toLowerCase().includes("chunked")) framingOut = "chunked";
      else if (lower === "content-length") {
        // Digits, and the same each time it is said: else nobody can say where the answer ends.
        if (!/^\d{1,15}$/.test(value) || (said !== null && said !== Number(value))) return nonsense();
        said = Number(value);
      }
      if (!HOP.has(lower)) headers.append(name, value);
    }
    if (framingOut !== "chunked" && said !== null) (framingOut = "length"), (left = said);
    const empty = request.method === "HEAD" || [204, 205, 304].includes(head.status); // as fetch has them: no body
    if (empty) call.cancel();
    return new Response(empty ? null : body(call, framingOut, left), { status: head.status, statusText: head.reason, headers });
  } catch (e) {
    call.cancel();
    return new Response("what is exposed here was lost\n", { status: 502 });
  }
}

// A WebSocket from the public, as one with the device: the upgrade is asked of it, and frames are said again either way.
async function socket(request, url, call) {
  const key = btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(16))));
  let extra = `Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ${key}\r\n`;
  const protocol = request.headers.get("sec-websocket-protocol");
  if (protocol) extra += `Sec-WebSocket-Protocol: ${protocol}\r\n`;
  if (!(await call.write(enc.encode(requestHead(request, url, extra))))) throw new Error("lost");
  let head = await readHead(call);
  while (head && head.status >= 100 && head.status < 200 && head.status !== 101) head = await readHead(call);
  if (!head || head.status !== 101) {
    call.cancel();
    return new Response("what is exposed here would not take a WebSocket\n", { status: 502 });
  }
  const { 0: client, 1: server } = new WebSocketPair();
  server.accept();
  let queued = 0, chain = Promise.resolve(), closed = false;
  const say = (opcode, payload) => {
    const frame = wsFrame(opcode, payload);
    queued += frame.length;
    if (queued > WS_QUEUE) {
      closed = true; // and nothing more is said of it, when the close comes
      try {
        server.close(1009, "too much at once");
      } catch {}
      return call.cancel();
    }
    chain = chain.then(async () => {
      await call.write(frame);
      queued -= frame.length;
    });
  };
  server.addEventListener("message", (e) => say(typeof e.data === "string" ? 1 : 2, typeof e.data === "string" ? enc.encode(e.data) : new Uint8Array(e.data)));
  server.addEventListener("close", (e) => {
    if (closed) return;
    closed = true;
    // A status only if it is one a Close frame may carry: else none, as for one that said none (1005) or vanished (1006).
    const code = e.code;
    say(8, sayable(code) ? cat(new Uint8Array([code >> 8, code & 255]), enc.encode(e.reason ?? "")) : new Uint8Array(0));
    chain.then(() => call.end());
  });
  (async () => {
    let buf = new Uint8Array(0), parts = [], first = 0;
    for (;;) {
      const b = await call.read();
      if (!b) break;
      buf = cat(buf, b);
      for (;;) {
        const f = wsTake(buf);
        const held = parts.reduce((n, p) => n + p.length, 0);
        if (f?.bad || (!f && buf.length > WS_MESSAGE_MAX + 14) || (f && held + f.payload.length > WS_MESSAGE_MAX)) {
          // Larger than the platform would carry: said so, and over, rather than held without end.
          closed = true;
          try {
            server.close(1009, "too large a message");
          } catch {}
          call.cancel();
          return;
        }
        if (!f) break;
        buf = buf.subarray(f.used);
        if (f.opcode === 9) say(10, f.payload); // ping: pong
        else if (f.opcode === 8) {
          closed = true;
          // Its status and reason if the public may be told them; else that it is over, plainly. Closed, either way.
          const code = f.payload.length >= 2 ? (f.payload[0] << 8) | f.payload[1] : 1000;
          let reason = "";
          try {
            reason = new TextDecoder("utf-8", { fatal: true }).decode(f.payload.subarray(2));
          } catch {}
          try {
            server.close(sayable(code) ? code : 1000, reason);
          } catch {
            try {
              server.close(1000);
            } catch {}
          }
          call.end();
          return;
        } else if (f.opcode === 0 || f.opcode === 1 || f.opcode === 2) {
          if (f.opcode) first = f.opcode;
          parts.push(f.payload);
          if (f.fin) {
            const whole = cat(...parts);
            parts = [];
            try {
              server.send(first === 1 ? dec.decode(whole) : whole);
            } catch {
              closed = true; // the public has gone meanwhile
              call.cancel();
              return;
            }
          }
        }
      }
    }
    if (!closed) {
      closed = true;
      try {
        server.close(1011, "what is exposed here was lost");
      } catch {}
    }
    call.cancel(); // the port has gone: the call goes with it, whatever was said of it
  })();
  const headers = new Headers();
  for (const [name, value] of head.headers) if (name.toLowerCase() === "sec-websocket-protocol") headers.set(name, value);
  return new Response(null, { status: 101, webSocket: client, headers });
}

// A frame as a client says it: masked.
function wsFrame(opcode, payload) {
  const n = payload.length;
  const head = n < 126 ? [0x80 | opcode, 0x80 | n] : n < 65536 ? [0x80 | opcode, 0x80 | 126, n >> 8, n & 255] : [0x80 | opcode, 0x80 | 127, 0, 0, 0, 0, (n >>> 24) & 255, (n >> 16) & 255, (n >> 8) & 255, n & 255];
  const mask = crypto.getRandomValues(new Uint8Array(4));
  const out = new Uint8Array(head.length + 4 + n);
  out.set(head);
  out.set(mask, head.length);
  for (let i = 0; i < n; i++) out[head.length + 4 + i] = payload[i] ^ mask[i & 3];
  return out;
}

// A frame as a server says it, if all of it is here.
/** Whether a Close frame may carry a status (RFC 6455 §7.4): not 1004 to 1006, nor 1015, nor what is no status at all. */
function sayable(code) {
  return (code >= 1000 && code <= 1014 && code !== 1004 && code !== 1005 && code !== 1006) || (code >= 3000 && code <= 4999);
}

function wsTake(b) {
  if (b.length < 2) return null;
  let n = b[1] & 127, at = 2;
  if (n === 126) {
    if (b.length < 4) return null;
    (n = (b[2] << 8) | b[3]), (at = 4);
  } else if (n === 127) {
    if (b.length < 10) return null;
    if (b[2] | b[3] | b[4] | b[5]) return { bad: true }; // 4 GiB or more: nothing that size is carried
    (n = b[6] * 2 ** 24 + ((b[7] << 16) | (b[8] << 8) | b[9])), (at = 10);
  }
  const masked = b[1] & 128;
  const mask = masked ? b.subarray(at, at + 4) : null;
  if (masked) at += 4;
  if ((b[0] & 8) && (n > 125 || !(b[0] & 128))) return { bad: true }; // a control frame is short and whole
  if (b.length < at + n) return null;
  let payload = b.subarray(at, at + n);
  if (mask) payload = payload.map((x, i) => x ^ mask[i & 3]);
  return { fin: !!(b[0] & 128), opcode: b[0] & 15, payload, used: at + n };
}

/**
 * An address as the platform says it (cf-connecting-ip), as 16 bytes: IPv4 mapped into IPv6. All zeros, nobody's, if
 * it is not an address.
 */
export function ipBytes(ip) {
  const out = new Uint8Array(16);
  const v4 = (text) => {
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(text);
    const b = m && m.slice(1).map(Number);
    return b && b.every((x) => x <= 255) ? b : null;
  };
  const four = v4(ip);
  if (four) {
    out.set([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 255, 255, ...four]);
    return out;
  }
  if (!/^[0-9a-fA-F:.]+$/.test(ip) || ip.split("::").length > 2) return new Uint8Array(16);
  let text = ip, tail4 = null;
  const last = text.lastIndexOf(":");
  if (text.includes(".")) {
    tail4 = v4(text.slice(last + 1));
    if (!tail4) return new Uint8Array(16);
    text = text.slice(0, last + 1) + "0:0"; // two words, filled in below
  }
  const [h, t] = text.includes("::") ? text.split("::") : [text, null];
  const head = h ? h.split(":") : [], tail = t ? t.split(":") : [];
  const words = t === null ? head : [...head, ...Array(Math.max(0, 8 - head.length - tail.length)).fill("0"), ...tail];
  if (words.length !== 8 || (t !== null && head.length + tail.length > 7) || !words.every((w) => /^[0-9a-fA-F]{1,4}$/.test(w))) return new Uint8Array(16);
  words.forEach((w, i) => out.set([parseInt(w, 16) >> 8, parseInt(w, 16) & 255], i * 2));
  if (tail4) out.set(tail4, 12);
  return out;
}

/** The label a host names, if it is under the domain the public reaches devices at. */
export function labelOf(host, domain) {
  if (!domain || !host) return null;
  const name = host.toLowerCase().replace(/:\d+$/, "").replace(/\.$/, "");
  if (!name.endsWith("." + domain.toLowerCase())) return null;
  const label = name.slice(0, -domain.length - 1);
  return /^[a-z0-9-]{1,63}$/.test(label) ? label : null;
}

/** Where a label leads: the space whose device exposes it, kept for as long as that lasts. */
export class Label extends DurableObject {
  async fetch(request) {
    const url = new URL(request.url);
    const storage = this.ctx.storage;
    if (url.pathname === "/claim" || url.pathname === "/release") {
      // Only from a space's own object, which works the label out from the space and the device's proven key: nobody
      // else can name another's label, and a request from the public never comes here by this path.
      const space = url.searchParams.get("space");
      const had = await storage.get("space");
      if (url.pathname === "/claim") {
        if (had && had !== space) return new Response("taken\n", { status: 409 });
        await storage.put("space", space);
      } else if (had === space) await storage.delete("space");
      return new Response("ok\n");
    }
    const space = await storage.get("space");
    if (!space) return new Response("nothing is exposed here\n", { status: 404 });
    return this.env.SPACE.get(this.env.SPACE.idFromName(space)).fetch(new Request(new URL(`/${space}`, request.url), request));
  }
}
