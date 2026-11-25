// The client against a node made of nothing: what it says, and what it makes of what it is told. The same as
// luau/tests/client.luau, so that the two clients are held to the same.

import assert from "node:assert/strict";
import * as codec from "../src/codec.ts";
import { Client, columns as c, type Answer, type State } from "../src/client.ts";
import { where } from "../src/ask.ts";

const HELLO = 1, ROSTER = 2, WATCH = 3, CELLS = 7, ACK = 8, SYNCED = 10;
const ASK = 32, UNASK = 33, ANSWER = 34, FETCH = 35, CALL = 15, SERVE = 14, AUTHOR = 17;

// Binary strings, one char a byte, as the protocol's identifiers are kept.
const b = (s: string) => codec.bytesOf(s);
const s = (bytes: Uint8Array) => codec.binary(bytes);
const rep = (ch: string, n: number) => ch.repeat(n);
const ch = (...codes: number[]) => String.fromCharCode(...codes);

interface Said {
  kind: number;
  body: string;
}

function harness() {
  const self = {
    said: [] as Said[],
    receive: undefined as unknown as (data: Uint8Array) => void,
    closed: undefined as unknown as () => void,
    deferred: [] as (() => void)[],
    later: [] as (() => void)[],
    closes: 0,
  };
  const run = () => {
    while (self.deferred.length > 0) self.deferred.shift()!();
  };
  const client = new Client({
    credential: "x",
    now: () => 1800000000000,
    random: (n) => Uint8Array.from({ length: n }, () => Math.floor(Math.random() * 256)),
    defer: (f) => self.deferred.push(f),
    after: (_ms, f) => {
      self.later.push(f);
      return () => {};
    },
    connect: (receive, closed) => {
      self.receive = receive;
      self.closed = closed;
      return {
        send: (data) => {
          const r = codec.reader(data);
          while (r.pos < r.len) {
            const body = codec.bytes(r);
            self.said.push({ kind: body[0], body: s(body.subarray(1)) });
          }
        },
        close: () => self.closes++,
      };
    },
  });
  const tell = (kind: number, body: string) => {
    const w = codec.writer();
    codec.putBytes(w, b(ch(kind) + body));
    self.receive(codec.written(w).slice());
    run();
  };
  const greet = () => tell(ROSTER, rep("\0", 8) + "\x01\x07" + rep("k", 32));
  const last = (kind: number): Said | undefined => {
    for (let i = self.said.length - 1; i >= 0; i--) if (self.said[i].kind === kind) return self.said[i];
    return undefined;
  };
  const laters = () => {
    for (const f of self.later.splice(0)) f();
  };
  return { client, self, run, tell, greet, last, laters };
}

const Note = { title: c.string(16), body: c.text(17) };

function watchOf(said: Said): [id: number, flags: number, lo: string, hi: string, limit: number] {
  const r = codec.reader(b(said.body));
  return [codec.varint(r), codec.u8(r), codec.key(r), codec.key(r), codec.varint(r)];
}

function synced(h: ReturnType<typeof harness>, id: number, flags: number, lo: string, hi: string) {
  const w = codec.writer();
  codec.putVarint(w, id);
  codec.putU8(w, flags);
  codec.putKey(w, lo);
  codec.putKey(w, hi);
  codec.putVarint(w, 0);
  codec.putVarint(w, 0);
  h.tell(SYNCED, s(codec.written(w)));
}

const tick = () => new Promise<void>((done) => setTimeout(done, 0));

// A pipe that breaks while a page is still owed is asked for the same page, not for everything.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a", table: Note, size: 50 }, () => {});
  h.run();
  let [, flags, , , limit] = watchOf(h.last(WATCH)!);
  assert(limit === 50 && flags & 4);
  h.self.closed();
  h.run();
  h.laters();
  h.run();
  h.greet();
  [, flags, , , limit] = watchOf(h.last(WATCH)!);
  assert(limit === 50 && flags & 4, `asked for ${limit}`);
}

// A range said over again without a row takes it from that window and no other, and spares what is typed.
{
  const h = harness();
  h.run();
  h.greet();
  let sa!: State<typeof Note>, sb!: State<typeof Note>;
  const a = () => sa, bb = () => sb;
  h.client.window({ scope: 1, list: "a", table: Note }, (st) => (sa = st));
  h.client.window({ scope: 1, list: "b", table: Note }, (st) => (sb = st));
  h.run();
  let id = "";
  void h.client.write(1, (change) => {
    id = change.insert(Note, "a", 1, { title: "t" });
    change.place(id, "b", 1, 2);
  });
  h.run();
  h.tell(ACK, "\x01");
  const editor = h.client.text(id, Note.body);
  editor.append("hello world");
  h.run();
  assert(a().rows.length === 1 && bb().rows.length === 1);
  const first = h.self.said.find((x) => x.kind === WATCH)!;
  const [page, , lo, hi] = watchOf(first);
  synced(h, page, 2, lo, hi);
  synced(h, page, 1, lo, hi);
  assert(a().rows.length === 0, "gone from the one");
  assert(bb().rows.length === 1 && bb().rows[0].body === "hello world", "and not from the other");
  assert(editor.read() === "hello world");
  let mine: State | undefined;
  h.client.window({ scope: 1, list: "b", table: { other: c.string(16) } }, (st) => (mine = st));
  assert(mine, "another shape of row is another window");
}

// Writing nothing is still done; clearing a text says so.
{
  const h = harness();
  h.run();
  h.greet();
  let done = 0;
  void h.client.write(1, () => {}).then(() => done++);
  h.run();
  await tick();
  assert((done as number) === 1);
  let id = "";
  void h.client.write(1, (change) => {
    id = change.insert(Note, "a", 1, { title: "t", body: "x" });
  });
  h.run();
  const before = h.self.said.length;
  void h.client.write(1, (change) => change.set(id, Note, { body: "" }));
  h.run();
  assert(h.self.said.length > before && h.last(CELLS), "said");
  assert.throws(() => h.client.write(1, (change) => change.set(id, Note, { title: rep("x", 1048576) })), "too much is refused before it is written");
}

// Nonsense from the pipe ends the pipe and nothing else.
{
  const h = harness();
  h.run();
  h.greet();
  h.self.receive(b(rep("\x80", 310) + "\0"));
  assert(h.self.closes === 1);
  const call = h.client.call(codec.hex(rep("d", 32)), 1, "m", "");
  assert.throws(() => call.send(new Uint8Array(262145)), "a message too big for any window is refused at once");
}

// What is sent for an answer waits for it, and what another answer shows outlives the one that stops.
{
  const h = harness();
  const held = () => Client.internals(h.client);
  h.run();
  h.greet();
  const row = (id: string, n: number) => {
    const w = codec.writer();
    codec.putU8(w, 3); // a value, and a row first named
    codec.putBinary(w, id);
    codec.putU8(w, 16);
    codec.putBinary(w, rep("\0", 15) + ch(n));
    codec.putBytes(w, b("title " + n));
    return s(codec.written(w));
  };
  const answer = (id: number, ids: string[]) => {
    const w = codec.writer();
    codec.putVarint(w, id);
    codec.putU8(w, 1);
    codec.putVarint(w, ids.length);
    codec.putVarint(w, 0);
    codec.putVarint(w, ids.length);
    codec.putBinary(w, ids.join(""));
    codec.putVarint(w, 0);
    h.tell(ANSWER, s(codec.written(w)));
  };
  const flags = (id: number, f: number) => h.tell(ANSWER, ch(id, f) + (f === 8 ? "\x2a" : ""));
  const one = rep("1", 16), two = rep("2", 16);
  let sa!: Answer<typeof Note>, sb!: Answer<typeof Note>;
  const sa_ = () => sa, sb_ = () => sb;
  const first = h.client.ask({ scope: 1, table: Note }, (x) => (sa = x));
  const second = h.client.ask({ scope: 1, table: Note, where: where.is("title", "x"), limit: 7 }, (x) => (sb = x));
  h.run();
  assert(sa_().status === "loading" && h.last(ASK));
  flags(1, 8);
  assert(sa_().status === "indexing" && sa_().progress === 0.42);
  h.tell(CELLS, "\0" + row(one, 1) + row(two, 2));
  assert(sa_().rows.length === 0);
  answer(1, [one]);
  assert(sa_().status === "ready" && sa_().rows.length === 1 && sa_().rows[0].title === "title 1" && sa_().total === 1);
  assert(!held().rows.has(two), "what no answer shows is not held");
  const was = sa_();
  h.tell(CELLS, "\0" + row(one, 9));
  assert(sa_() !== was && sa_().rows[0].title === "title 9", "and what one does is kept up");
  first.stop();
  h.run();
  assert(h.last(UNASK));
  answer(2, [one]); // the node says this before it knows, so it does not send the row
  assert(sb_().rows[0].title === "title 9");
  flags(1, 16);
  assert(sb_().rows[0].title === "title 9" && held().rows.has(one));
  // Asked again down a new pipe, and over what was.
  h.self.closed();
  h.run();
  assert(sb_().status === "stale" && sb_().rows.length === 1);
  let before = h.self.said.length;
  h.laters();
  h.run();
  h.greet();
  assert.equal(h.self.said.slice(before).filter((x) => x.kind === ASK).length, 1);
  second.move(7);
  h.run();
  const r = codec.reader(b(h.last(ASK)!.body));
  assert(codec.varint(r) === 2 && h.last(ASK)!.body.slice(-3) === "\x07\x07\0");
  flags(2, 2);
  assert(sb_().status === "denied" && sb_().rows.length === 0 && held().rows.size === 0);
  second.stop();
  second.stop();
  flags(2, 16);
  assert(held().asked.size === 0);
  // One that is stopped is not asked again when it might have been.
  const third = h.client.ask({ scope: 1, table: Note }, (x) => (sa = x));
  flags(3, 2);
  third.stop();
  h.run();
  let said = h.self.said.length;
  const scopes = (...ids: number[]) => {
    const w = codec.writer();
    codec.putBinary(w, rep("\0", 8));
    for (const scope of ids) {
      codec.putVarint(w, scope);
      codec.putBinary(w, "\x07" + rep("k", 32));
    }
    h.tell(ROSTER, s(codec.written(w)));
  };
  scopes(1);
  for (const x of h.self.said.slice(said)) assert(x.kind !== ASK);
  flags(3, 17);
  assert(held().asked.size === 0);
  // One that needs to read what cannot be is denied, and asked once it can.
  const joined = h.client.ask({ scope: 1, table: Note, where: where.refers("title", 2, where.inList("inbox"), Note) }, (x) => (sa = x));
  h.run();
  assert(sa_().status === "denied");
  said = h.self.said.length;
  scopes(1, 2);
  h.run();
  assert(h.self.said[h.self.said.length - 1].kind === ASK && h.self.said.length === said + 1);
  joined.stop();
  flags(4, 16);
  // A question that makes no sense here is an error here.
  assert.throws(() => h.client.ask({ scope: 1, table: Note, where: where.is("nothing", 1) }, () => {}));
  assert(held().asked.size === 0);
  // What is asked once is answered once, down whichever pipe, and let go of.
  let gotten: Answer<typeof Note> | undefined;
  const got = () => gotten;
  const fetch = async (scope = 1) => {
    void h.client.fetch({ scope, table: Note }).then((x) => (gotten = x));
    h.run();
    await tick();
  };
  await fetch();
  assert(!got() && h.last(FETCH));
  const id = codec.varint(codec.reader(b(h.last(FETCH)!.body)));
  flags(id, 8);
  await tick();
  assert(!got());
  h.self.closed();
  h.run();
  before = h.self.said.length;
  h.laters();
  h.run();
  h.greet();
  assert(h.self.said[h.self.said.length - 1].kind === FETCH);
  h.tell(CELLS, "\0" + row(one, 4));
  {
    const w = codec.writer();
    codec.putVarint(w, id);
    codec.putBinary(w, "\x21\x01\0\x01" + one + "\0");
    h.tell(ANSWER, s(codec.written(w)));
  }
  await tick();
  assert(got()?.status === "ready" && got()!.rows[0].title === "title 4" && got()!.total === 1);
  assert(!held().rows.has(one) && !held().asked.has(id));
  gotten = undefined;
  await fetch();
  flags(id + 1, 2);
  await tick();
  assert(got()?.status === "denied" && got()!.rows.length === 0);
  gotten = undefined;
  await fetch(5);
  assert(got()?.status === "denied");
  // A scope that cannot be read is known to be.
  h.client.ask({ scope: 5, table: Note }, (x) => (sa = x));
  assert(sa_().status === "denied");
}

// Whose a row is, is shown and can be asked about; and when it is another's after all, or by another name, so shown.
{
  const Signed = { title: c.string(16), by: c.author(16), body: c.text(17), writers: c.authors(17) };
  const h = harness();
  h.run();
  assert(h.self.said[0].kind === HELLO && h.self.said[0].body.slice(0, 2) === "\x01\x04", "it wants to be told");
  h.tell(ROSTER, rep("\0", 8) + "\x01\x07" + rep("k", 32) + "\x02\x87" + rep("k", 32));
  let me: { id: string; subject: string } | undefined;
  h.client.on("self", (who) => (me = who));
  h.tell(AUTHOR, "\0" + rep("d", 32) + "\x02me");
  assert(me && me.subject === "me" && me.id === codec.hex(rep("d", 32)));
  let seen!: State<typeof Signed>, seenPlain!: State<typeof Signed>;
  const shown = () => seen, plain = () => seenPlain;
  h.client.window({ scope: 2, list: "a", table: Signed }, (x) => (seen = x));
  h.client.window({ scope: 1, list: "a", table: Signed }, (x) => (seenPlain = x));
  h.run();
  let mine = "";
  void h.client.write(2, (change) => (mine = change.insert(Signed, "a", 1, { title: "t" })));
  void h.client.write(1, (change) => change.insert(Signed, "a", 1, { title: "t" }));
  h.run();
  assert(shown().rows[0].by === "me" && shown().rows[0].writers.length === 0);
  assert(plain().rows[0].by === undefined, "where nobody is told, neither is this");
  const editor = h.client.text(mine, Signed.body);
  editor.append("typed");
  editor.close();
  h.run();
  assert(shown().rows[0].writers[0] === "me");
  assert.throws(() => h.client.write(2, (change) => change.set(mine, Signed, { by: "you" })));

  const row = "\0\0\0\x02" + rep("r", 12);
  const cell = (kind: number, slot: number, n: number, body: string, author: string) => {
    const w = codec.writer();
    codec.putBinary(w, ch(kind + 64) + row + ch(slot) + rep("\0", 15) + ch(n));
    codec.putBytes(w, b(body));
    codec.putBinary(w, author);
    return s(codec.written(w));
  };
  const send = (x: string, y: string) =>
    h.tell(
      CELLS,
      "\0" +
        cell(2, 1, 1, h.client.tag(2, "a") + codec.u64(2), x) +
        cell(3, 16, 2, "theirs", y) +
        cell(3, 17, 3, "x", x) +
        cell(4, 17, 4, codec.u64(1) + "\x01\0\0\x01y", y),
    );
  h.tell(AUTHOR, "\x01" + rep("e", 32) + "\x03zoe");
  h.tell(AUTHOR, "\x02" + rep("e", 32) + "\x03ann");
  send("\x01", "\x02");
  assert(shown().rows[1].by === "ann" && shown().rows[1].writers.join(" ") === "ann zoe");
  const before = shown().rows[1];
  send("\x01", "\x02");
  assert(shown().rows[1] === before, "nothing has changed");
  h.tell(AUTHOR, "\x03" + rep("e", 32) + "\x09ann smith");
  send("\x01", "\x03");
  assert(shown().rows[1].by === "ann smith" && shown().rows[1].writers.join(" ") === "ann smith zoe");
  h.tell(AUTHOR, "\x04" + rep("f", 32) + "\0");
  send("\x04", "\x04");
  assert(shown().rows[1].by === undefined && shown().rows[1].writers.length === 0, "a device that is nobody's");

  h.client.ask({ scope: 2, table: Signed, where: where.begins("by", "an"), order: ["-by"], totals: { whose: ["facet", "by"] } }, () => {});
  h.run();
  const asked = h.last(ASK)!.body;
  assert(asked.includes("\x06\x0a\x10\x02an") && asked.includes("\0\x01\x0a\x10\0") && asked.includes("\x05\x0a\x10\x64"));

  let caller: string | undefined;
  h.client.serve(2, "m", (call) => (caller = call.subject));
  h.run();
  h.tell(CALL, "\x01" + rep("e", 32) + "\x02\x01m\x03zoehello");
  assert(caller === "zoe");
  h.client.call(codec.hex(rep("e", 32)), 2, "m", "hello");
  h.run();
  assert(h.last(CALL)!.body.slice(-8) === "\x01m\0hello", "and for whom is not for it to say");
  assert(h.last(SERVE));
}

// What a roster has made unlawful goes from the rows it was in, as they are said over again; and no more than that.
{
  const h = harness();
  h.run();
  h.greet();
  let seen!: State<typeof Note>, answered!: Answer<typeof Note>;
  const shown = () => seen, found = () => answered;
  h.client.window({ scope: 1, list: "a", table: Note }, (x) => (seen = x));
  h.client.ask({ scope: 1, table: Note }, (x) => (answered = x));
  h.run();
  const one = "\0\0\0\x01" + rep("1", 12), two = "\0\0\0\x01" + rep("2", 12);
  const cell = (row: string, kind: number, slot: number, n: number, body: string) => {
    const w = codec.writer();
    codec.putBinary(w, ch(kind) + row + ch(slot) + rep("\0", 15) + ch(n));
    codec.putBytes(w, b(body));
    return s(codec.written(w));
  };
  const place = (row: string) => cell(row, 2, 1, 1, h.client.tag(1, "a") + codec.u64(1));
  const piece = (n: number, ...parts: string[]) => {
    let out = "";
    parts.forEach((p, i) => {
      out += rep("\0", 15) + ch(n + i + 1) + codec.u64(n + i + 1) + ch(4 + p.length) + "\x01\0\0" + ch(p.length) + p;
    });
    return "\0\0\0\x01" + rep("\0", 15) + ch(n) + out;
  };
  const answer = (...ids: string[]) => h.tell(ANSWER, "\x01\x01" + ch(ids.length) + "\0" + ch(ids.length) + ids.join("") + "\0");
  h.tell(CELLS, "\0" + place(one) + cell(one, 3, 16, 2, "kept") + cell(one, 3, 17, 3, "gone"));
  h.tell(CELLS, "\0" + place(two) + cell(two, 3, 16, 2, "gone") + cell(two, 5, 17, 9, piece(4, "a", "b")));
  answer(one, two);
  assert(shown().rows.length === 2 && found().rows.length === 2 && shown().rows[0].body === "gone" && shown().rows[1].body.length === 2);
  const [page, , lo, hi] = watchOf(h.last(WATCH)!);
  synced(h, page, 1, lo, hi);
  // A range, from its beginning.
  synced(h, page, 2, lo, hi);
  h.tell(CELLS, "\0" + place(one) + cell(one, 3, 16, 2, "kept"));
  h.tell(CELLS, "\0" + place(two) + cell(two, 3, 16, 2, "gone") + cell(two, 5, 17, 9, piece(4, "a", "b")));
  synced(h, page, 1, lo, hi);
  assert(shown().rows[0].title === "kept" && shown().rows[0].body === "" && shown().rows[1].title === "gone");
  // An answer, when what may be read has changed. One that says nothing over again says nothing of what is gone.
  h.greet();
  answer(one, two);
  assert(found().rows[1].title === "gone");
  h.greet();
  h.tell(CELLS, "\0" + place(two) + cell(two, 5, 17, 9, piece(4, "a")));
  h.tell(CELLS, "\0" + place(one) + cell(one, 3, 16, 2, "kept"));
  answer(one, two);
  assert(found().rows[1].title === undefined && found().rows[1].body === "a" && found().rows[0].title === "kept", "and of some of it, only that");
  h.tell(CELLS, "\0" + cell(one, 3, 17, 8, "new"));
  answer(one, two);
  assert(found().rows[0].title === "kept" && found().rows[0].body === "new", "it is as it was before from then on");
}

console.log("ok");
