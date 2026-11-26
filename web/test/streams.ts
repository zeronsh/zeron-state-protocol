// Calls' credit, and processes, terminals and connections, against a node made of nothing: what the client says, byte for
// byte, and what it makes of what it is told. Credit goes back only as what came is taken, and what is sent goes only as
// there is room. A connection bridged to a real socket here carries both ways, half-closes each way, slows a socket that
// sends faster than the far end takes, and is reset when the call is. `node test/streams.ts`

import assert from "node:assert/strict";
import { createServer, connect as dial, type AddressInfo, type Socket } from "node:net";
import * as codec from "../src/codec.ts";
import { Client } from "../src/client.ts";
import { bridge } from "../src/net-node.ts";
import * as services from "../src/services.ts";

const ROSTER = 2, CALL = 15, FLOW = 16;
const F_DATA = 0, F_END = 1, F_FAULT = 2, F_CANCEL = 3, F_CREDIT = 4;
const WINDOW = 262144;
const DEVICE = "d".repeat(64);
const tick = () => new Promise((done) => setImmediate(done));
const bytes = (s: string) => new TextEncoder().encode(s);
const text = (b: Uint8Array) => new TextDecoder().decode(b);

interface Flow {
  id: number;
  side: number;
  kind: number;
  payload: Uint8Array;
}

// A client, and the node it speaks to: what it said, and a way to say things to it.
async function harness() {
  const said: { kind: number; body: Uint8Array }[] = [];
  let receive!: (data: Uint8Array) => void;
  const client = new Client({
    connect: (r) => {
      receive = r;
      return {
        send: (data) => {
          const r = codec.reader(data);
          while (r.pos < r.len) {
            const body = codec.bytes(r);
            said.push({ kind: body[0], body: body.slice(1) });
          }
        },
        close: () => {},
      };
    },
  });
  const tell = (kind: number, body: Uint8Array) => {
    const w = codec.writer();
    const framed = new Uint8Array(1 + body.length);
    framed[0] = kind;
    framed.set(body, 1);
    codec.putBytes(w, framed);
    receive(codec.written(w).slice());
  };
  // Scope 1, in which it may read, write and call.
  tell(ROSTER, Uint8Array.from([...new Uint8Array(8), 1, 7, ...new Uint8Array(32)]));
  await tick();
  assert.ok(client.ready);
  const calls = () =>
    said.filter((s) => s.kind === CALL).map((s) => {
      const r = codec.reader(s.body);
      const id = codec.varint(r);
      codec.take(r, 32);
      codec.varint(r);
      const method = text(codec.bytes(r));
      codec.bytes(r);
      return { id, method, first: codec.rest(r).slice() };
    });
  const flows = (): Flow[] =>
    said.filter((s) => s.kind === FLOW).map((s) => {
      const r = codec.reader(s.body);
      const tag = codec.varint(r);
      return { id: Math.floor(tag / 2), side: tag % 2, kind: codec.u8(r), payload: codec.rest(r).slice() };
    });
  // What the callee says, in the call the client made with this id.
  const answer = async (id: number, kind: number, payload: Uint8Array = new Uint8Array()) => {
    const w = codec.writer();
    codec.putVarint(w, id * 2 + 1);
    codec.putU8(w, kind);
    codec.put(w, payload);
    tell(FLOW, codec.written(w).slice());
    await tick();
  };
  const credit = (n: number) => {
    const w = codec.writer();
    codec.putVarint(w, n);
    return codec.written(w).slice();
  };
  const credited = (id: number) => flows().filter((f) => f.id === id && f.kind === F_CREDIT).reduce((n, f) => n + codec.varint(codec.reader(f.payload)), 0);
  const sent = (id: number) => flows().filter((f) => f.id === id && f.kind === F_DATA);
  return { client, said, calls, flows, answer, credit, credited, sent };
}

// Credit goes back as messages are taken: at once, unless the taker keeps them; and a taker that keeps up is given a longer
// window. Room says what may go now, and onroom when more may.
{
  const h = await harness();
  const call = h.client.call(DEVICE, 1, "m", "x");
  const kept: number[] = [];
  call.ondata = (d) => {
    kept.push(d.length);
    return false;
  };
  await tick();
  const id = h.calls()[0].id;
  await h.answer(id, F_DATA, new Uint8Array(1000));
  await h.answer(id, F_DATA, new Uint8Array(2000));
  assert.equal(h.credited(id), 0, "nothing is credited that is kept");
  call.consumed(1000);
  await tick();
  assert.equal(h.credited(id), 1000, "and what is consumed is");
  call.ondata = () => {};
  await h.answer(id, F_DATA, new Uint8Array(500));
  assert.equal(h.credited(id), 1500, "what is taken at once is credited at once");
  // A window used up quickly grows: credited once more, ahead.
  call.consumed(2000);
  for (let i = 0; i < 4; i++) await h.answer(id, F_DATA, new Uint8Array(65536));
  assert.equal(h.credited(id), 3500 + 4 * 65536 + WINDOW, "a reader that keeps up has a longer window");
  // Sending: as much as there is room for, and the rest when there is.
  assert.equal(call.room, WINDOW - 1);
  call.send(new Uint8Array(WINDOW - 1));
  assert.equal(call.room, 0);
  call.send(new Uint8Array(10));
  await tick();
  assert.equal(h.sent(id).length, 1, "what there is no room for waits");
  let roomy = 0;
  call.onroom = () => roomy++;
  await h.answer(id, F_CREDIT, h.credit(5));
  assert.equal(roomy, 0, "not room enough for what waits");
  await h.answer(id, F_CREDIT, h.credit(100));
  assert.equal(h.sent(id).length, 2, "and it goes once there is");
  assert.equal(roomy, 1, "then onroom says so");
  assert.equal(call.room, 95);
}

// A command: what it is asked, its status, its output and errors held until read, and credited as read; input that goes
// as there is room, in pieces; signals; its end; and its input closed.
{
  const h = await harness();
  const p = services.exec(h.client, DEVICE, 1, ["ls", "-l"], { env: { A: "1", B: null }, cwd: "/srv" });
  await tick();
  const c = h.calls()[0];
  assert.equal(c.method, "zsp.exec");
  assert.deepEqual(c.first, services.execRequest(["ls", "-l"], { A: "1", B: null }, "/srv"));
  await h.answer(c.id, F_DATA, Uint8Array.of(0));
  await p.started;
  await h.answer(c.id, F_DATA, Uint8Array.of(1, ...bytes("out")));
  await h.answer(c.id, F_DATA, Uint8Array.of(2, ...bytes("err!")));
  assert.equal(p.output.buffered, 3);
  assert.equal(p.errors.buffered, 4);
  assert.equal(h.credited(c.id), 1, "the status is credited, and nothing unread");
  assert.equal(text((await p.errors.read())!), "err!");
  await tick();
  assert.equal(h.credited(c.id), 1 + 5, "what is read is credited, tag and all");
  // Input: in pieces of 64 KiB, as there is room.
  const big = new Uint8Array(300000).fill(7);
  let wrote: boolean | undefined;
  void p.write(big).then((ok) => (wrote = ok));
  await tick();
  const pieces = h.sent(c.id).filter((f) => f.payload[0] === 0);
  assert.deepEqual(pieces.map((f) => f.payload.length), [65537, 65537, 65537], "as much as there is room for");
  assert.equal(wrote, undefined, "and the write waits for the rest");
  p.signal("interrupt");
  await tick();
  assert.deepEqual(h.sent(c.id).at(-1)!.payload, Uint8Array.of(1, 2), "a signal goes ahead of input that waits");
  await h.answer(c.id, F_CREDIT, h.credit(200000));
  assert.equal(wrote, true, "once there is room, it has gone");
  assert.equal(h.sent(c.id).filter((f) => f.payload[0] === 0).reduce((n, f) => n + f.payload.length - 1, 0), big.length);
  p.closeInput();
  await tick();
  assert.ok(h.flows().some((f) => f.id === c.id && f.kind === F_END), "its input is closed");
  assert.equal(await p.write("more"), false, "and nothing more goes");
  let told: services.Exit | undefined;
  p.onExit = (e) => (told = e);
  await h.answer(c.id, F_DATA, Uint8Array.of(3, 1, 0));
  assert.deepEqual(await p.exit, { code: 1, signal: 0 });
  assert.deepEqual(told, { code: 1, signal: 0 });
  const rest: string[] = [];
  for await (const d of p.output) rest.push(text(d));
  assert.deepEqual(rest, ["out"], "what was said before it ended is still there to read, and then no more");
  await h.answer(c.id, F_END);

  // Refused: why, and in what words.
  const q = services.exec(h.client, DEVICE, 1, ["nothing"]);
  await tick();
  const qc = h.calls()[1];
  await h.answer(qc.id, F_DATA, Uint8Array.of(6, ...bytes("no such program")));
  await h.answer(qc.id, F_END);
  const e = await q.started.then(() => undefined, (e: unknown) => e);
  assert.ok(e instanceof services.ServiceError && e.status === "not found" && e.reason === "no such program");
  await assert.rejects(q.exit, services.ServiceError);
  assert.ok(h.flows().some((f) => f.id === qc.id && f.kind === F_END), "and this side ends too");

  // Lost before it ended: whatever is read, or waited for, hears so.
  const r = services.exec(h.client, DEVICE, 1, ["sleep"]);
  await tick();
  const rc = h.calls()[2];
  await h.answer(rc.id, F_DATA, Uint8Array.of(0));
  const reading = r.output.read();
  await h.answer(rc.id, F_FAULT, Uint8Array.of(4));
  await assert.rejects(reading, (e: services.ServiceError) => e.fault === "lost");
  await assert.rejects(r.exit, (e: services.ServiceError) => e.status === "failed" && e.fault === "lost");

  // Killed: by signal, while its input is open; by cancelling, once it is not.
  const k = services.exec(h.client, DEVICE, 1, ["sleep"]);
  await tick();
  const kc = h.calls()[3];
  k.kill();
  await tick();
  assert.deepEqual(h.sent(kc.id).at(-1)!.payload, Uint8Array.of(1, 9));
  k.closeInput();
  k.kill();
  await tick();
  assert.ok(h.flows().some((f) => f.id === kc.id && f.kind === F_CANCEL));
}

// A command run to its end, with input; and a terminal, whose listener may keep what it is told until it has drawn it.
{
  const h = await harness();
  const ran = services.run(h.client, DEVICE, 1, ["cat"], { input: "hi" });
  await tick();
  const c = h.calls()[0];
  assert.deepEqual(h.sent(c.id).map((f) => [...f.payload]), [[0, ...bytes("hi")]]);
  assert.ok(h.flows().some((f) => f.id === c.id && f.kind === F_END));
  for (const m of [Uint8Array.of(0), Uint8Array.of(1, ...bytes("h")), Uint8Array.of(2, ...bytes("e")), Uint8Array.of(1, ...bytes("i")), Uint8Array.of(3, 0, 0)]) await h.answer(c.id, F_DATA, m);
  await h.answer(c.id, F_END);
  assert.deepEqual(await ran, { code: 0, signal: 0, stdout: "hi", stderr: "e" });

  const t = services.terminal(h.client, DEVICE, 1, { rows: 24, cols: 80, env: { COLORTERM: "truecolor" } });
  await tick();
  const tc = h.calls()[1];
  assert.equal(tc.method, "zsp.pty");
  assert.deepEqual(tc.first, services.ptyRequest(24, 80, "xterm-256color", { COLORTERM: "truecolor" }));
  let drawn = "";
  t.onOutput = (d) => {
    drawn += text(d);
    return false;
  };
  await h.answer(tc.id, F_DATA, Uint8Array.of(0));
  await h.answer(tc.id, F_DATA, Uint8Array.of(1, ...bytes("$ ")));
  await h.answer(tc.id, F_DATA, Uint8Array.of(2, ...bytes("!"))); // a terminal's is all output
  assert.equal(drawn, "$ !");
  assert.equal(h.credited(tc.id), 1 + 1 + 1, "the status, and the tags; not what the listener keeps");
  t.consumed(3);
  await tick();
  assert.equal(h.credited(tc.id), 6);
  t.resize(50, 132);
  await tick();
  assert.deepEqual(h.sent(tc.id).at(-1)!.payload, services.resizeMessage(50, 132));
  t.close();
  await tick();
  assert.ok(h.flows().some((f) => f.id === tc.id && f.kind === F_CANCEL), "closed, it is let go of, and all it started");
  await assert.rejects(t.exit, services.ServiceError);
}

// A connection, bridged to a socket here: both ways, each way's end, and a socket that sends faster than the far end
// takes held up; then a reset, which resets the socket.
{
  const h = await harness();
  let accepted!: Promise<boolean>;
  const server = createServer({ allowHalfOpen: true }, (sock) => {
    const stream = services.connect(h.client, DEVICE, 1, 8080, "10.0.0.2");
    accepted = bridge(stream, sock);
  });
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const sock: Socket = dial({ port: (server.address() as AddressInfo).port, host: "127.0.0.1", allowHalfOpen: true });
  let heard = "";
  let ended = false;
  sock.on("data", (d) => (heard += d));
  const hearing = () => heard;
  sock.on("end", () => (ended = true));
  await new Promise<void>((done) => sock.once("connect", () => done()));
  for (let i = 0; i < 50 && h.calls().length === 0; i++) await tick();
  const c = h.calls()[0];
  assert.equal(c.method, "zsp.tcp");
  assert.deepEqual(c.first, services.tcpRequest(8080, "10.0.0.2"));
  await h.answer(c.id, F_DATA, Uint8Array.of(0));
  sock.write("ping");
  for (let i = 0; i < 50 && h.sent(c.id).length === 0; i++) await tick();
  assert.equal(text(h.sent(c.id)[0].payload), "ping", "what the socket says goes as it is");
  await h.answer(c.id, F_DATA, bytes("pong"));
  for (let i = 0; i < 50 && heard === ""; i++) await tick();
  assert.equal(heard, "pong", "and what comes is written to it");
  // More than the window: the socket is held up until there is room.
  const before = h.sent(c.id).reduce((n, f) => n + f.payload.length, 0);
  sock.write(new Uint8Array(1 << 20));
  for (let i = 0; i < 200; i++) await tick();
  const gone = h.sent(c.id).reduce((n, f) => n + f.payload.length, 0) - before;
  assert.ok(gone <= WINDOW - 4, `no more goes than there is room for: ${gone}`);
  await h.answer(c.id, F_CREDIT, h.credit(4 << 20));
  for (let i = 0; i < 400 && h.sent(c.id).reduce((n, f) => n + f.payload.length, 0) - before < 1 << 20; i++) await tick();
  assert.equal(h.sent(c.id).reduce((n, f) => n + f.payload.length, 0) - before, 1 << 20, "and the rest once there is");
  // Half-closed, each way.
  sock.end();
  for (let i = 0; i < 50 && !h.flows().some((f) => f.id === c.id && f.kind === F_END); i++) await tick();
  assert.ok(h.flows().some((f) => f.id === c.id && f.kind === F_END), "the socket's end is the stream's");
  await h.answer(c.id, F_DATA, bytes(" and more"));
  await h.answer(c.id, F_END);
  for (let i = 0; i < 50 && !ended; i++) await tick();
  assert.ok(ended && hearing() === "pong and more", "and the stream's, the socket's, after what came before it");
  assert.equal(await accepted, true, "over, as it should be, both ways");

  // Reset.
  const sock2: Socket = dial({ port: (server.address() as AddressInfo).port, host: "127.0.0.1", allowHalfOpen: true });
  const how = new Promise<string>((done) => {
    sock2.on("error", (e: NodeJS.ErrnoException) => done(e.code ?? "error"));
    sock2.on("close", () => done("closed"));
  });
  for (let i = 0; i < 50 && h.calls().length < 2; i++) await tick();
  const c2 = h.calls()[1];
  await h.answer(c2.id, F_DATA, Uint8Array.of(0));
  await h.answer(c2.id, F_FAULT, Uint8Array.of(4));
  assert.equal(await how, "ECONNRESET", "a reset is a reset");
  assert.equal(await accepted, false, "and the bridge says it was");
  server.close();
}

// A connection refused: why, with no socket to speak of.
{
  const h = await harness();
  const s = services.connect(h.client, DEVICE, 1, 22);
  await tick();
  const c = h.calls()[0];
  await h.answer(c.id, F_DATA, Uint8Array.of(3));
  await h.answer(c.id, F_END);
  await assert.rejects(s.connected, (e: services.ServiceError) => e.status === "refused");
  await assert.rejects(s.closed, (e: services.ServiceError) => e.status === "refused");
  assert.ok(h.flows().some((f) => f.id === c.id && f.kind === F_END), "and this side ends too");
}

console.log("ok");
