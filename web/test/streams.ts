// Calls' credit, both ways, against a node made of nothing: what the client says, byte for byte, and what it makes of what
// it is told. Credit goes back only as what came is taken, and what is sent goes only as there is room, in order, its end
// after it. Faults and cancelling end a call for good; and a call it answers is held to the same. `node test/streams.ts`

import assert from "node:assert/strict";
import * as codec from "../src/codec.ts";
import { CallFault, Client, type Call, type Fault } from "../src/client.ts";

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
  // The calls it made, as a local client says them: an urgency after for whom, then the first message.
  const calls = () =>
    said.filter((s) => s.kind === CALL).map((s) => {
      const r = codec.reader(s.body);
      const id = codec.varint(r);
      const device = codec.hex(codec.take(r, 32));
      const scope = codec.varint(r);
      const method = text(codec.bytes(r));
      const forWhom = text(codec.bytes(r));
      const urgency = codec.u8(r);
      return { id, device, scope, method, forWhom, urgency, first: codec.rest(r).slice() };
    });
  const flows = (): Flow[] =>
    said.filter((s) => s.kind === FLOW).map((s) => {
      const r = codec.reader(s.body);
      const tag = codec.varint(r);
      return { id: Math.floor(tag / 2), side: tag % 2, kind: codec.u8(r), payload: codec.rest(r).slice() };
    });
  // What one side of a call says to the client: the callee (1) in a call it made, the caller (0) in one it answers.
  const flow = async (id: number, side: number, kind: number, payload: Uint8Array = new Uint8Array()) => {
    const w = codec.writer();
    codec.putVarint(w, id * 2 + side);
    codec.putU8(w, kind);
    codec.put(w, payload);
    tell(FLOW, codec.written(w).slice());
    await tick();
  };
  const answer = (id: number, kind: number, payload?: Uint8Array) => flow(id, 1, kind, payload);
  const caller = (id: number, kind: number, payload?: Uint8Array) => flow(id, 0, kind, payload);
  // A call to the client, as the node says it: no urgency, which is the caller's to say to its own node.
  const incoming = async (id: number, scope: number, method: string, subject: string, first: Uint8Array) => {
    const w = codec.writer();
    codec.putVarint(w, id);
    codec.put(w, codec.unhex(DEVICE));
    codec.putVarint(w, scope);
    codec.putBytes(w, bytes(method));
    codec.putBytes(w, bytes(subject));
    codec.put(w, first);
    tell(CALL, codec.written(w).slice());
    await tick();
  };
  const credit = (n: number) => {
    const w = codec.writer();
    codec.putVarint(w, n);
    return codec.written(w).slice();
  };
  // What the client says in a call: in one it made (side 0), or one it answers (side 1).
  const of = (id: number, side = 0) => flows().filter((f) => f.id === id && f.side === side);
  const credited = (id: number, side = 0) => of(id, side).filter((f) => f.kind === F_CREDIT).reduce((n, f) => n + codec.varint(codec.reader(f.payload)), 0);
  const sent = (id: number, side = 0) => of(id, side).filter((f) => f.kind === F_DATA);
  return { client, said, calls, flows, of, answer, caller, incoming, credit, credited, sent };
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

// A call as it is said: its urgency, 3 unless said, and its first message, which the window counts. Then what is sent goes
// in order as there is room, its end only after all of it, and nothing after its end; and once both sides have ended, the
// call is over, and nothing more of it is heard.
{
  const h = await harness();
  const plain = h.client.call(DEVICE, 1, "plain", "");
  const call = h.client.call(DEVICE, 1, "copy", "first", { urgency: 6 });
  await tick();
  const [p, c] = h.calls();
  assert.deepEqual([p.method, p.urgency, p.scope, p.device, p.forWhom], ["plain", 3, 1, DEVICE, ""]);
  assert.deepEqual([c.method, c.urgency, text(c.first)], ["copy", 6, "first"]);
  assert.equal(plain.room, WINDOW);
  assert.equal(call.room, WINDOW - 5, "the first message is sent from the window too");
  call.send(new Uint8Array(200000).fill(1));
  call.send(new Uint8Array(100000).fill(2));
  call.send("third");
  call.finish();
  call.send("too late");
  await tick();
  assert.deepEqual(h.sent(c.id).map((f) => f.payload.length), [200000], "as much as there is room for");
  assert.ok(!h.of(c.id).some((f) => f.kind === F_END), "and its end waits for what waits before it");
  let roomy = 0;
  call.onroom = () => roomy++;
  await h.answer(c.id, F_CREDIT, h.credit(30000));
  assert.equal(h.sent(c.id).length, 1, "a message goes whole or not at all");
  await h.answer(c.id, F_CREDIT, h.credit(30000));
  const said = h.of(c.id).map((f) => (f.kind === F_DATA ? text(f.payload).slice(0, 5) : f.kind));
  assert.deepEqual(said, ["\x01".repeat(5), "\x02".repeat(5), "third", F_END], "in order, and then its end, and nothing sent after it");
  assert.equal(roomy, 1);
  // The other side's answer, and its end.
  const heard: string[] = [];
  let ended = 0;
  call.ondata = (d) => void heard.push(text(d));
  call.onend = () => ended++;
  await h.answer(c.id, F_DATA, bytes("done"));
  await h.answer(c.id, F_END);
  assert.deepEqual([heard, ended], [["done"], 1]);
  await h.answer(c.id, F_DATA, bytes("stray"));
  assert.deepEqual(heard, ["done"], "a call both sides have ended is over");
  assert.equal(call.room, 0);
  assert.equal(h.credited(c.id), 4, "and what came before was credited");
  // One whose other side ends first goes on sending until it ends too.
  plain.onend = () => ended++;
  await h.answer(p.id, F_END);
  assert.equal(ended, 2);
  plain.send("after their end");
  plain.finish();
  await tick();
  assert.deepEqual(h.of(p.id).map((f) => f.kind), [F_DATA, F_END]);
}

// Faults: each, as the other side says it, ends the call; whatever waits is dropped, and nothing more goes.
{
  const h = await harness();
  const faults: [number, Fault][] = [[1, "denied"], [2, "unreachable"], [3, "unserved"], [4, "lost"], [5, "overrun"], [6, "busy"], [0, "cancelled"]];
  for (const [code, fault] of faults) {
    const call = h.client.call(DEVICE, 1, "m", "");
    const told: Fault[] = [];
    call.onfault = (f) => void told.push(f);
    call.send(new Uint8Array(WINDOW));
    call.send("waits");
    await tick();
    const id = h.calls().at(-1)!.id;
    await h.answer(id, F_FAULT, Uint8Array.of(code));
    assert.deepEqual(told, [fault], `fault ${code}`);
    assert.equal(call.room, 0);
    await h.answer(id, F_CREDIT, h.credit(WINDOW));
    call.send("more");
    call.finish();
    await tick();
    assert.deepEqual(h.of(id).map((f) => f.kind), [F_DATA], "nothing more goes of a call that is over");
  }
  // And cancelled by the other side, a request is rejected with it.
  const asked = h.client.request(DEVICE, 1, "m", "q", { urgency: 2 });
  await tick();
  const id = h.calls().at(-1)!.id;
  assert.equal(h.calls().at(-1)!.urgency, 2, "a request says its urgency as a call does");
  assert.ok(h.of(id).some((f) => f.kind === F_END), "a request's end goes at once");
  const rejected = assert.rejects(asked, (e: unknown) => e instanceof CallFault && e.fault === "cancelled");
  await h.answer(id, F_CANCEL);
  await rejected;
  // And one that is answered resolves to all of what came.
  const answered = h.client.request(DEVICE, 1, "m", "q");
  await tick();
  const next = h.calls().at(-1)!.id;
  await h.answer(next, F_DATA, bytes("an "));
  await h.answer(next, F_DATA, bytes("answer"));
  await h.answer(next, F_END);
  assert.equal(text(await answered), "an answer");
}

// Cancelled here: the other side is told, and from then on nothing is said or heard of it.
{
  const h = await harness();
  const call = h.client.call(DEVICE, 1, "m", "");
  const heard: string[] = [];
  call.ondata = (d) => void heard.push(text(d));
  call.onfault = () => heard.push("fault");
  call.send(new Uint8Array(WINDOW));
  call.send("waits");
  await tick();
  const id = h.calls()[0].id;
  call.cancel();
  await tick();
  assert.deepEqual(h.of(id).map((f) => f.kind), [F_DATA, F_CANCEL]);
  call.send("more");
  call.finish();
  call.consumed(100);
  call.cancel();
  await h.answer(id, F_CREDIT, h.credit(WINDOW));
  await h.answer(id, F_DATA, bytes("late"));
  await h.answer(id, F_END);
  assert.deepEqual(h.of(id).map((f) => f.kind), [F_DATA, F_CANCEL], "nothing more is said of it");
  assert.deepEqual(heard, [], "nor heard");
}

// A call it answers: told who calls, its first message credited at once, and what comes after as it is taken; what is sent
// back goes as the caller has room for it, and its end after; and a method not served is said to be so.
{
  const h = await harness();
  let served!: Call;
  let first = "";
  const stop = h.client.serve(1, "work", (call, data) => {
    served = call;
    first = text(data);
  });
  await tick();
  const big = new Uint8Array(1000).fill(65);
  await h.incoming(5, 1, "work", "zoe", big);
  assert.equal(first.length, 1000);
  assert.deepEqual([served.device, served.method, served.subject], [DEVICE, "work", "zoe"]);
  assert.equal(h.credited(5, 1), 1000, "the first message is always taken");
  served.ondata = () => false;
  await h.caller(5, F_DATA, new Uint8Array(3000));
  assert.equal(h.credited(5, 1), 1000, "what the answerer keeps is not credited");
  served.consumed(3000);
  await tick();
  assert.equal(h.credited(5, 1), 4000, "until it is consumed");
  // Sending back: as much as the caller has room for.
  assert.equal(served.room, WINDOW);
  served.send(new Uint8Array(WINDOW));
  served.send("rest");
  served.finish();
  await tick();
  assert.deepEqual(h.of(5, 1).filter((f) => f.kind !== F_CREDIT).map((f) => f.kind), [F_DATA], "the rest waits, and its end with it");
  await h.caller(5, F_CREDIT, h.credit(4));
  assert.deepEqual(h.of(5, 1).filter((f) => f.kind !== F_CREDIT).map((f) => [f.kind, f.payload.length]), [[F_DATA, WINDOW], [F_DATA, 4], [F_END, 0]]);
  let ended = false;
  served.onend = () => (ended = true);
  await h.caller(5, F_END);
  assert.ok(ended, "and once the caller ends too, it is over");
  assert.equal((served as Call).room, 0, "and has no room");
  // A call the caller faults: told so.
  let fault: Fault | undefined;
  await h.incoming(6, 1, "work", "", new Uint8Array());
  served.onfault = (f) => (fault = f);
  await h.caller(6, F_CANCEL);
  assert.equal(fault, "cancelled");
  // A method not served, in that scope or at all, or no longer.
  await h.incoming(7, 2, "work", "", new Uint8Array());
  await h.incoming(8, 1, "play", "", new Uint8Array());
  stop();
  await tick();
  await h.incoming(9, 1, "work", "", new Uint8Array());
  for (const id of [7, 8, 9]) assert.deepEqual(h.of(id, 1).map((f) => [f.kind, ...f.payload]), [[F_FAULT, 3]], `call ${id} is unserved`);
}

console.log("ok");
