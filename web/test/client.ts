// The client against a node made of nothing: what it says, and what it makes of what it is told. The same as
// luau/tests/client.luau, so that the two clients are held to the same.

import assert from "node:assert/strict";
import * as codec from "../src/codec.ts";
import { Client, columns as c, type Answer, type State } from "../src/client.ts";
import * as text from "../src/text.ts";
import * as ask from "../src/ask.ts";
import { where } from "../src/ask.ts";
import * as m from "../src/mirror.ts";

// `./x selftest` sets ZSP_FAIL, to see that ./x test says this failed.
if (process.env.ZSP_FAIL) throw new Error("failing, as ZSP_FAIL asks");

const HELLO = 1, ROSTER = 2, WATCH = 3, CELLS = 7, ACK = 8, SYNCED = 10, ERROR = 13;
const ASK = 32, UNASK = 33, ANSWER = 34, FETCH = 35, CALL = 15, SERVE = 14, AUTHOR = 17, FLOW = 16;

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
    waits: [] as number[], // what each of those waits
    timers: 0, // of those, how many are neither done nor cancelled
    closes: 0,
    connects: 0,
    sizes: [] as number[],
    partial: new Uint8Array(0),
    clock: () => 1800000000000, // what the host says the time is
  };
  const run = () => {
    while (self.deferred.length > 0) self.deferred.shift()!();
  };
  const client = new Client({
    credential: "x",
    now: () => self.clock(),
    random: (n) => Uint8Array.from({ length: n }, () => Math.floor(Math.random() * 256)),
    defer: (f) => self.deferred.push(f),
    after: (ms, f) => {
      let live = true;
      self.timers++;
      self.later.push(() => {
        if (live) (live = false), self.timers--, f();
      });
      self.waits.push(ms);
      return () => {
        if (live) (live = false), self.timers--;
      };
    },
    connect: (receive, closed) => {
      self.connects++;
      self.receive = receive;
      self.closed = closed;
      return {
        send: (data) => {
          // A stream of bytes, in pieces of no more than a mebibyte, and frames whole only once all of each has come.
          assert(data.length <= 1 << 20, `a message of ${data.length} bytes`);
          self.sizes.push(data.length);
          const all = new Uint8Array(self.partial.length + data.length);
          all.set(self.partial);
          all.set(data, self.partial.length);
          let at = 0;
          for (;;) {
            let n = 0, shift = 0, p = at;
            while (p < all.length && all[p] & 128) n += (all[p++] & 127) * 2 ** shift, (shift += 7);
            if (p >= all.length) break;
            n += all[p++] * 2 ** shift;
            if (p + n > all.length) break;
            const body = all.subarray(p, p + n);
            self.said.push({ kind: body[0], body: s(body.subarray(1)) });
            at = p + n;
          }
          self.partial = all.slice(at);
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

function synced(h: ReturnType<typeof harness>, id: number, flags: number, lo: string, hi: string, before = 0, after = 0) {
  const w = codec.writer();
  codec.putVarint(w, id);
  codec.putU8(w, flags);
  codec.putKey(w, lo);
  codec.putKey(w, hi);
  codec.putVarint(w, before);
  codec.putVarint(w, after);
  h.tell(SYNCED, s(codec.written(w)));
}

const tick = () => new Promise<void>((done) => setTimeout(done, 0));

// A cell as a node sends it: of a row first named, or of the row before it if that is "".
function cellOf(row: string, kind: number, slot: number, n: number, body: string): string {
  const w = codec.writer();
  codec.putBinary(w, ch(kind) + row + ch(slot) + rep("\0", 15) + ch(n));
  codec.putBytes(w, b(body));
  return s(codec.written(w));
}

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

// A window begins at the end unless it is said to begin at the start, whatever its list is called.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a/start/b", table: Note }, () => {});
  h.run();
  assert(watchOf(h.last(WATCH)!)[1] & 4, "it began at the start");
  h.client.window({ scope: 1, list: "a/end/b", table: Note, from: "start" }, () => {});
  h.run();
  assert(!(watchOf(h.last(WATCH)!)[1] & 4), "it began at the end");
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

// A page a partial replica answered at once, from what it held, may end sooner once a full replica has said where it ends:
// what the window showed beyond it is not let go of unseen, but asked for again as the page that follows.
{
  const h = harness();
  h.run();
  h.greet();
  let st!: State<typeof Note>;
  h.client.window({ scope: 1, list: "a", table: Note, size: 2 }, (x) => (st = x));
  h.run();
  for (let i = 1; i <= 3; i++) void h.client.write(1, (change) => change.insert(Note, "a", i, { title: `t${i}` }));
  h.run();
  h.tell(ACK, "\x03");
  const [page, , lo, hi] = watchOf(h.last(WATCH)!);
  synced(h, page, 0, lo, hi); // what is held: all three, to the end
  assert.equal(st.rows.length, 3);
  const keys = (Client.internals(h.client) as any).windows.values().next().value.entries.map((e: { key: string }) => e.key);
  const watches = h.self.said.filter((x) => x.kind === WATCH).length;
  synced(h, page, 1, keys[0], keys[2], 0, 1); // as a full replica says: two, and one more after
  const asked = h.self.said.filter((x) => x.kind === WATCH);
  assert.equal(asked.length, watches + 1, "the rest is asked for");
  const [, , from] = watchOf(asked[asked.length - 1]);
  assert.equal(from, keys[2], "from where the page now ends");
}

// A window of all of a list is one page, however long: nothing of it is split, loaded or let go of as it is scrolled.
{
  const h = harness();
  h.run();
  h.greet();
  let st!: State<typeof Note>;
  const all = h.client.window({ scope: 1, list: "all", table: Note, size: 0 }, (x) => (st = x));
  h.run();
  for (let i = 1; i <= 10; i++) void h.client.write(1, (change) => change.insert(Note, "all", i, { title: `t${i}` }));
  h.run();
  h.tell(ACK, "\x0a");
  const [page, , lo, hi] = watchOf(h.last(WATCH)!);
  synced(h, page, 1, lo, hi);
  const watches = h.self.said.filter((x) => x.kind === WATCH).length;
  for (let i = 0; i < 5; i++) all.visible(1, 10), h.run();
  all.visible(1, 3);
  h.run();
  assert.equal(h.self.said.filter((x) => x.kind === WATCH).length, watches, "pages were made of it");
  assert.equal(st.rows.length, 10, "rows were let go of");
}

// Many rows placed at once, while a follower moves or deletes one of them as it hears of it: every row is where it is held
// to be, once, and the one deleted nowhere.
for (const what of ["move", "delete"]) {
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "items", table: Note, size: 100 }, () => {});
  h.run();
  let first = "", heard = 0;
  h.client.follow((id) => {
    if (++heard === 1) first = id;
    else if (heard === 2) void h.client.write(1, (change) => (what === "move" ? change.place(first, "items", 999) : change.delete(first)));
  });
  void h.client.write(1, (change) => {
    for (let i = 1; i <= 70; i++) change.insert(Note, "items", i, { title: `r${i}` });
  });
  h.run();
  const window = (Client.internals(h.client).windows as ReadonlyMap<string, { entries: { key: string; row: { hex: string } }[]; at: Map<unknown, string> }>)
    .values()
    .next().value!;
  const keys = window.entries.map((e) => e.key);
  assert.deepEqual(keys, [...keys].sort(), "out of order");
  assert.equal(window.entries.length, window.at.size, "held where it is not");
  for (const e of window.entries) assert.equal(window.at.get(e.row), e.key, "held where it is not");
  if (what === "move") {
    assert.equal(window.entries.length, 70);
    assert.equal(window.entries[69].row.hex, first, "not moved");
  } else {
    assert.equal(window.entries.length, 69);
    assert(!window.entries.some((e) => e.row.hex === first), "deleted, and still there");
  }
}

// More said at once than a WebSocket of zspd's takes in one message, 8 MiB, goes in pieces, and arrives whole; and so it
// does again on a pipe dialled anew, which would otherwise break every time it was said.
{
  const h = harness();
  h.run();
  h.greet();
  for (let i = 0; i < 12; i++) void h.client.write(1, (change) => change.insert({ v: c.bytes(16) }, "big", i, { v: new Uint8Array(900_000).fill(i) }));
  h.run();
  assert.equal(h.self.said.filter((x) => x.kind === CELLS).length, 12, "every write arrived whole");
  assert(h.self.sizes.reduce((a, b) => a + b, 0) > 10 << 20 && Math.max(...h.self.sizes) <= 1 << 20);
  h.self.closed();
  h.run();
  h.laters();
  h.run();
  h.greet();
  assert.equal(h.self.said.filter((x) => x.kind === CELLS).length, 24, "and again, whole, on the next pipe");
}

// A pipe that breaks as the first piece of a long burst is sent is sent no more of it, and the burst goes, whole, to the
// pipe dialled next.
{
  let sends = 0, connects = 0;
  let closed: () => void = () => {};
  let receive: (d: Uint8Array) => void = () => {};
  const deferred: (() => void)[] = [], later: (() => void)[] = [];
  const run = () => {
    while (deferred.length > 0) deferred.shift()!();
  };
  const client = new Client({
    credential: "x",
    now: () => 1800000000000,
    random: (n) => new Uint8Array(n).fill(7),
    defer: (f) => deferred.push(f),
    after: (_ms, f) => (later.push(f), () => {}),
    connect: (r, c) => {
      connects++;
      receive = r;
      closed = c;
      const first = connects === 1;
      return {
        send: (data) => {
          sends++;
          if (first && data.length === 1 << 20) closed(); // as the pipe breaks, there and then
        },
        close: () => {},
      };
    },
  });
  const greet = () => {
    const w = codec.writer();
    codec.putBytes(w, b(ch(ROSTER) + rep("\0", 8) + "\x01\x07" + rep("k", 32)));
    receive(codec.written(w).slice());
    run();
  };
  run();
  greet();
  void client.write(1, (change) => {
    change.insert({ v: c.bytes(16) }, "big", 1, { v: new Uint8Array(900_000) });
    change.insert({ v: c.bytes(16) }, "big", 2, { v: new Uint8Array(900_000) });
  });
  assert.doesNotThrow(run, "a pipe that broke as it was sent to");
  const before = sends;
  for (const f of later.splice(0)) f();
  run();
  greet();
  assert.equal(connects, 2);
  assert(sends - before >= 2, "the burst went again, to the next pipe");
}

// A text of a row not held, that nobody can say more of than that it is not held here, as a partial replica with nobody
// to ask who can read says: what is typed is kept, and written once it is closed, not held back for ever.
{
  const h = harness();
  h.run();
  h.greet();
  const id = "00000001" + "6a0b1c2d" + "0102030405060708";
  const editor = h.client.text(id, Note.body);
  h.run();
  editor.append("typed offline");
  h.run();
  const fetched = h.last(FETCH);
  assert(fetched, "the row was not asked for once");
  const w = codec.writer();
  codec.putVarint(w, codec.varint(codec.reader(b(fetched.body))));
  codec.putU8(w, 32); // the last, and not settled: what is held, which is nothing
  for (let i = 0; i < 4; i++) codec.putVarint(w, 0);
  h.tell(ANSWER, s(codec.written(w)));
  await tick();
  h.run();
  assert.equal(editor.read(), "typed offline");
  const before = h.self.said.filter((x) => x.kind === CELLS).length;
  editor.close();
  h.run();
  assert(h.self.said.filter((x) => x.kind === CELLS).length > before, "what was typed was never written");
}

// An editor of a row not yet here, closed before it came: what is no place in any text is refused at once; an edit at a
// place the text did not have once it came is not made, and the rest are; and the row is then let go of, and nothing
// is left asked for its sake.
{
  const h = harness();
  h.run();
  h.greet();
  const id = "00000001" + "6b49d200" + "0102030405060708", bin = codec.binaryFromHex(id);
  const editor = h.client.text(id, Note.body);
  h.run();
  assert.throws(() => editor.insert(-5, "x"), RangeError);
  assert.throws(() => editor.delete(0, 1.5), RangeError);
  editor.insert(10, "x");
  editor.append("!");
  editor.close();
  const fetched = codec.varint(codec.reader(b(h.last(FETCH)!.body)));
  h.tell(CELLS, "\0" + cellOf(bin, 3, 17, 2, "hello"));
  const said = h.self.said.length;
  const w = codec.writer();
  codec.putVarint(w, fetched);
  codec.putBinary(w, "\x01\x01\0\x01" + bin + "\0");
  h.tell(ANSWER, s(codec.written(w)));
  await tick();
  h.run();
  const row = h.client.held(id);
  assert(row && row.held.size === 0 && row.asking === undefined, "it is held for ever");
  assert(h.last(UNASK), "and asked for for ever");
  assert.equal(text.read(h.client.heldText(id, 17)!), "hello!", "what was typed is not what was asked");
  assert(h.self.said.slice(said).some((x) => x.kind === CELLS), "and was not written");
}

// Two editors of a row not yet here: what each does waits for it, and is done, in turn, to the text that came.
{
  const h = harness();
  h.run();
  h.greet();
  const id = "00000001" + "6b49d200" + "0102030405060709", bin = codec.binaryFromHex(id);
  const one = h.client.text(id, Note.body), two = h.client.text(id, Note.body);
  h.run();
  for (const [editor, letter] of [[one, "X"], [two, "Y"]] as const) editor.delete(0, 1), editor.insert(2, letter);
  const fetched = codec.varint(codec.reader(b(h.last(FETCH)!.body)));
  h.tell(CELLS, "\0" + cellOf(bin, 3, 17, 2, "HELLO"));
  const w = codec.writer();
  codec.putVarint(w, fetched);
  codec.putBinary(w, "\x01\x01\0\x01" + bin + "\0");
  h.tell(ANSWER, s(codec.written(w)));
  await tick();
  h.run();
  assert.equal(one.read(), "LXYLO");
  assert.equal(two.read(), "LXYLO");
  one.close(), two.close();
}

// What a node refuses for good is refused here, at once, and nothing is said of it: a change bigger than one frame of a
// node's, a text in a slot no text goes in, a value in a slot that is not a whole one, a page of a size that is none, a
// scope that is none, a method of no name or of one too long.
{
  const h = harness();
  h.run();
  h.greet();
  let id = "";
  void h.client.write(1, (change) => (id = change.insert(Note, "a", 1, { title: "t" })));
  h.run();
  const said = h.self.said.length;
  const big = { v: c.bytes(20) };
  assert.throws(
    () =>
      h.client.write(1, (change) => {
        for (let i = 0; i < 5; i++) change.insert(big, "big", i, { v: new Uint8Array(900_000) });
      }),
    /4 MiB/,
  );
  assert.throws(() => h.client.text(id, { ...Note.body, slot: 1 }), RangeError);
  assert.throws(() => h.client.write(1, (change) => change.set(id, { odd: { ...c.string(16), slot: 16.5 } }, { odd: "x" })), /slot 16.5/);
  assert.throws(() => h.client.write(1, (change) => change.edit(id, 17.5, () => {})), RangeError);
  assert.throws(() => h.client.window({ scope: 1, list: "a", table: Note, size: 1.5 }, () => {}), RangeError);
  assert.throws(() => h.client.window({ scope: -1, list: "a", table: Note }, () => {}), RangeError);
  assert.throws(() => h.client.call(codec.hex(rep("d", 32)), 1.5, "m"), RangeError);
  assert.throws(() => h.client.serve(1, "", () => {}), RangeError);
  assert.throws(() => h.client.serve(1, "m".repeat(256), () => {}), RangeError);
  assert.throws(() => h.client.serve(2 ** 32, "m", () => {}), RangeError);
  h.run();
  assert.equal(h.self.said.length, said, "and something was said");
  assert.equal(Client.internals(h.client).rows.size, 1, "and is held");
}

// An editor's pieces are no longer than a live frame a node carries, however much is typed or deleted at once: they are
// sealed as they fill, and what is typed is all there, as typed.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.run();
  let id = "";
  void h.client.write(1, (change) => (id = change.insert(Note, "a", 1, { title: "t" })));
  h.run();
  const editor = h.client.text(id, Note.body);
  for (let i = 0; i < 4000; i++) editor.insert(i % 2 === 0 ? 0 : i >> 1, "ab"[i % 2]), editor.commit(); // spans, many
  editor.append("x".repeat(1 << 20));
  h.run();
  editor.delete(0, 4000 + (1 << 19));
  editor.close();
  h.run();
  assert.equal(editor.read(), "x".repeat(1 << 19));
  let pieces = 0;
  for (const x of h.self.said) {
    if (x.kind === 9) assert(x.body.length - 16 - 1 - 8 - 16 - 3 <= 65536 - 128, `a live frame of ${x.body.length} bytes`);
    if (x.kind !== CELLS) continue;
    const r = codec.reader(b(x.body));
    codec.varint(r);
    while (r.pos < r.len) {
      const tag = codec.u8(r);
      if (tag < 128) codec.take(r, 16);
      codec.take(r, 17);
      const body = codec.bytes(r);
      if ((tag & 63) === 4) pieces++, assert(body.length - 8 <= 65536 - 128, `a piece of ${body.length} bytes`);
    }
  }
  assert(pieces > 4000 + 16, "it was said in too few pieces");
}

// The pieces of a text's slot an editor said, in order: their stamps and bodies.
function piecesOf(h: ReturnType<typeof harness>, slot: number): [stamp: string, body: Uint8Array][] {
  const out: [string, Uint8Array][] = [];
  for (const x of h.self.said) {
    if (x.kind !== CELLS) continue;
    const r = codec.reader(b(x.body));
    codec.varint(r);
    while (r.pos < r.len) {
      const tag = codec.u8(r);
      if (tag < 128) codec.take(r, 16);
      const at = codec.u8(r), stamp = codec.takeBinary(r, 16), body = codec.bytes(r);
      if ((tag & 63) === 4 && at === slot) out.push([stamp, body.slice()]);
    }
  }
  return out;
}

// A piece ends where a character does, wherever what is typed or deleted at once is cut: whoever has the pieces so far
// reads whole characters, and what they type after the last goes after a whole one. Typed in one go, a character at a
// time, and deleted across many spans, with every place a cut can fall in one.
{
  const whole = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });
  const fresh = () => s(Uint8Array.from({ length: 8 }, () => Math.floor(Math.random() * 256)));
  for (const one of ["é", "€", "😀"]) {
    const width = new TextEncoder().encode(one).length;
    for (let p = 0; p < width; p++) {
      const h = harness();
      h.run();
      h.greet();
      h.client.window({ scope: 1, list: "a", table: Note }, () => {});
      h.run();
      let id = "";
      void h.client.write(1, (change) => (id = change.insert(Note, "a", 1, { title: "t" })));
      h.run();
      const editor = h.client.text(id, Note.body);
      const typed = "x".repeat(p) + one.repeat(Math.ceil(140000 / width));
      editor.append(typed);
      editor.commit();
      let left = typed;
      if (p === 0) {
        // And one at a time, each a span of its own, and all of it deleted at once.
        for (let i = 0; i < 8000; i++) editor.insert(0, one);
        editor.delete(0, typed.length + 8000 * one.length);
        left = "";
      }
      editor.close();
      h.run();
      assert.equal(editor.read(), left);
      const pieces = piecesOf(h, 17);
      assert(pieces.length >= (p === 0 ? 6 : 3), `said in ${pieces.length} pieces`);
      const t = text.create();
      let was = "";
      for (const [i, [stamp, body]] of pieces.entries()) {
        text.apply(t, 4, stamp, body);
        const now = whole.decode(text.content(t)); // or a character was cut
        if (i === 0) assert(now.length > 0 && typed.startsWith(now), "the first piece is not what was typed");
        // Who had this piece last, and typed after it, typed after a whole character, as all the rest find it.
        const other = text.create();
        for (const [st, bo] of pieces.slice(0, i + 1)) text.apply(other, 4, st, bo);
        text.insert(other, text.len(other), "X", fresh);
        for (const [st, bo] of pieces.slice(i + 1)) text.apply(other, 4, st, bo);
        whole.decode(text.content(other));
        was = now;
      }
      assert.equal(was, left);
    }
  }
}

// A stretch of a question that cannot be asked for is refused at once, connected or not, and what was asked stands: it
// and every other question are asked again down the next pipe, as they were. One whose asker made it nonsense since is
// faulty, alone, and the rest are asked all the same.
{
  const h = harness();
  h.run();
  let status = "";
  const early = h.client.ask({ scope: 1, table: Note, offset: 3, limit: 5 }, () => {});
  const mine = { scope: 1, table: Note, limit: 4 };
  const spoilt = h.client.ask(mine, (x) => (status = x.status));
  const later = h.client.ask({ scope: 1, table: Note, limit: 6 }, () => {});
  // A list that is no list is refused as it is asked for, before it is said to anyone, as is a window of one.
  for (const name of [undefined, null, 5]) {
    assert.throws(() => h.client.window({ scope: 1, list: name as unknown as string, table: Note }, () => {}), TypeError);
    assert.throws(() => h.client.ask({ scope: 1, table: Note, where: where.inList(name as unknown as string) }, () => {}), TypeError);
  }
  assert.equal(Client.internals(h.client).asked.size, 3);
  assert.equal(Client.internals(h.client).windows.size, 0);
  assert.throws(() => early.move(-1), RangeError);
  assert.throws(() => early.move(1, 2 ** 64), RangeError);
  const asks = (from: number) => {
    const out = new Map<number, string>();
    for (const x of h.self.said.slice(from)) {
      if (x.kind !== ASK) continue;
      const r = codec.reader(b(x.body));
      out.set(codec.varint(r), x.body);
    }
    return out;
  };
  let from = h.self.said.length;
  h.greet();
  h.run();
  const first = asks(from);
  assert.equal(first.size, 3);
  assert(first.get(1)!.endsWith("\x03\x05\0"), "the first is not as it was asked");
  assert.throws(() => early.move(-1), RangeError);
  assert.throws(() => later.move(0.5), RangeError);
  h.run();
  assert.equal(asks(from).size, 3, "and a stretch that cannot be was asked for");
  (mine as { limit: number }).limit = -1;
  h.self.closed();
  h.run();
  h.laters();
  h.run();
  from = h.self.said.length;
  h.greet();
  h.run();
  assert(h.client.ready);
  const again = asks(from);
  assert.equal(again.size, 2, "the rest were not asked again");
  assert.equal(again.get(1), first.get(1));
  assert.equal(again.get(3), first.get(3));
  assert.equal(status, "faulty");
  early.move(4, 6);
  h.run();
  assert(h.last(ASK)!.body.endsWith("\x04\x06\0"));
  assert.throws(() => h.client.ask({ scope: 1, table: Note, where: where.inList(null as unknown as string) }, () => {}), TypeError);
  assert.equal(Client.internals(h.client).asked.size, 3);
  spoilt.stop(), early.stop(), later.stop();
}

// What hears of the pipe hears all of it, whatever one of them does: one that throws does so on a turn of its own, and
// what came after it down the pipe, the questions asked again and the others that hear, are all as they would be.
{
  const h = harness();
  h.run();
  const heard: boolean[] = [];
  h.client.on("status", (up) => {
    if (up) throw new Error("a listener's own");
  });
  h.client.on("status", (up) => heard.push(up));
  h.client.ask({ scope: 1, table: Note }, () => {});
  const frame = (kind: number, body: string) => {
    const w = codec.writer();
    codec.putBytes(w, b(ch(kind) + body));
    return s(codec.written(w));
  };
  const chunk = frame(ROSTER, rep("\0", 8) + "\x01\x07" + rep("k", 32)) + frame(12, rep("d", 32) + "\x03who");
  const from = h.self.said.length;
  h.self.receive(b(chunk)); // the roster and what followed it, at once
  assert(h.client.ready && heard.join() === "false,true", `heard ${heard}`);
  assert.equal(h.client.devices.length, 1, "what came after it was lost");
  assert.equal(h.client.devices[0].subject, "who");
  assert.throws(() => h.run(), /a listener's own/);
  h.run();
  assert(h.self.said.slice(from).some((x) => x.kind === ASK), "the question was not asked again");
  h.self.receive(b(frame(12, "")));
  assert.equal(h.client.devices.length, 0, "the pipe was not read on");
}

// Code told of anything is told after all this client does of its own, each alone: what one throws it throws on a turn of
// its own, and leaves nothing half done, nor anyone else untold. And whatever else is thrown while a frame is read, as by a
// host, the pipe is read on from the frame after, on a turn of its own, rather than losing the rest.
const frameOf = (kind: number, body: string) => {
  const w = codec.writer();
  codec.putBytes(w, b(ch(kind) + body));
  return s(codec.written(w));
};
const syncedOf = (id: number, lo: string, hi: string) => {
  const w = codec.writer();
  codec.putVarint(w, id);
  codec.putU8(w, 1);
  codec.putKey(w, lo);
  codec.putKey(w, hi);
  codec.putVarint(w, 0);
  codec.putVarint(w, 0);
  return frameOf(SYNCED, s(codec.written(w)));
};
// Runs what was put off, and says how many of those threw.
const thrown = (h: ReturnType<typeof harness>, what: RegExp) => {
  let n = 0;
  for (;;) {
    try {
      h.run();
      return n;
    } catch (e) {
      assert.match(String(e), what);
      n++;
    }
  }
};
const DEVICE = "d".repeat(64);
{
  // A follower that throws: every row is put where it goes, and every other follower hears of each, whether the rows came
  // down the pipe or were written here.
  const h = harness();
  h.run();
  h.greet();
  let shown = 0;
  const win = h.client.window({ scope: 1, list: "a", table: Note }, (st) => (shown = st.rows.length));
  h.run();
  const heard: string[] = [];
  h.client.follow(() => {
    throw new Error("a follower's own");
  });
  h.client.follow((id) => heard.push(id));
  const tag = h.client.tag(1, "a");
  const placed = (n: number) => cellOf("\0\0\0\x01" + rep("\x07", 11) + ch(n), 2, 1, n, tag + rep("\0", 7) + ch(n));
  h.self.receive(b(frameOf(CELLS, "\0" + placed(1) + placed(2))));
  assert.equal(win.entries().length, 2, "the rows were not put where they go");
  assert.equal(heard.length, 2, "a follower was not told");
  void h.client.write(1, (change) => change.insert(Note, "a", 9, { title: "w" }));
  assert.equal(win.entries().length, 3);
  assert.equal(heard.length, 3);
  assert.equal(thrown(h, /a follower's own/), 3);
  assert.equal(shown, 3);
}
{
  // A call told it is lost that throws: every other call is told, the windows and questions are stale, "status" is told,
  // and the pipe is dialled again.
  const h = harness();
  h.run();
  h.greet();
  let up = true;
  h.client.on("status", (x) => (up = x));
  let status = "";
  h.client.window({ scope: 1, list: "a", table: Note }, (st) => (status = st.status));
  h.run();
  const [page, , lo, hi] = watchOf(h.last(WATCH)!);
  h.self.receive(b(syncedOf(page, lo, hi)));
  h.run();
  assert.equal(status, "ready");
  const one = h.client.call(DEVICE, 1, "m", "x"), two = h.client.call(DEVICE, 1, "m", "x");
  one.onfault = () => {
    throw new Error("a call's own");
  };
  let fault = "";
  two.onfault = (f) => (fault = f);
  h.run();
  const waits = h.self.waits.length;
  h.self.closed();
  assert(fault === "lost" && !up, `told ${fault} and ${up}`);
  assert.equal(h.self.waits.length, waits + 1, "the pipe was not dialled again");
  assert.equal(thrown(h, /a call's own/), 1);
  assert.equal(status, "stale");
  h.laters();
  h.run();
  assert.equal(h.self.connects, 2);
}
{
  // An observer that throws: every other observer, window and question is told, now and later; and a client closed while
  // one would throw is closed whole, its pipe let go of and what was asked once answered.
  const h = harness();
  h.run();
  h.greet();
  let throwing = false;
  let second = 0, other = 0, answered = 0;
  h.client.window({ scope: 1, list: "a", table: Note }, () => {
    if (throwing) throw new Error("an observer's own");
  });
  h.client.window({ scope: 1, list: "a", table: Note }, () => second++);
  h.client.window({ scope: 1, list: "b", table: Note }, () => other++);
  h.client.ask({ scope: 1, table: Note }, () => answered++);
  h.run();
  const pages = h.self.said.filter((x) => x.kind === WATCH).map(watchOf);
  const askId = codec.varint(codec.reader(b(h.last(ASK)!.body)));
  (second = 0), (other = 0), (answered = 0), (throwing = true);
  const answer = (() => {
    const w = codec.writer();
    codec.putVarint(w, askId);
    codec.putU8(w, 1);
    for (let i = 0; i < 4; i++) codec.putVarint(w, 0);
    return frameOf(ANSWER, s(codec.written(w)));
  })();
  for (let round = 1; round <= 2; round++) {
    h.self.receive(b(pages.map(([id, , lo, hi]) => syncedOf(id, lo, hi)).join("") + answer));
    assert.equal(thrown(h, /an observer's own/), 1);
    assert.deepEqual([second, other, answered], [round, round, round]);
  }
  let fetched = false;
  void h.client.fetch({ scope: 1, table: Note }).then(() => (fetched = true));
  h.run();
  const [id, , lo, hi] = pages[0];
  h.self.receive(b(syncedOf(id, lo, hi)));
  const closes = h.self.closes;
  h.client.close();
  assert.equal(h.self.closes, closes + 1, "the pipe was not let go of");
  assert.equal(h.self.timers, 0, "something was left to be done later");
  await tick();
  assert(fetched, "what was asked once was not answered");
  assert.equal(thrown(h, /an observer's own/), 2); // as it was when closed, and once its pipe was let go of
}
{
  // A reader of a call that throws keeps nothing: what came is credited back, so the call goes on.
  const h = harness();
  h.run();
  h.greet();
  const call = h.client.call(DEVICE, 1, "m", "x");
  call.ondata = () => {
    throw new Error("a reader's own");
  };
  h.run();
  const flow = (kind: number, body: string) => {
    const w = codec.writer();
    codec.putVarint(w, 1 * 2 + 1);
    codec.putU8(w, kind);
    return frameOf(FLOW, s(codec.written(w)) + body);
  };
  const from = h.self.said.length;
  h.self.receive(b(flow(0, rep("x", 1000)) + flow(0, rep("y", 10))));
  assert.equal(thrown(h, /a reader's own/), 2);
  let credited = 0;
  for (const x of h.self.said.slice(from)) {
    if (x.kind !== FLOW) continue;
    const r = codec.reader(b(x.body));
    if (codec.varint(r) === 2 && codec.u8(r) === 4) credited += codec.varint(r);
  }
  assert.equal(credited, 1010, "what came was not credited back");
}
{
  // What a host throws while a frame is read: the pipe is read on from the frame after it.
  const h = harness();
  h.run();
  h.greet();
  let served = 0;
  h.client.serve(1, "m", () => served++);
  const callOf = (id: number) => {
    const w = codec.writer();
    codec.putVarint(w, id);
    codec.putBinary(w, rep("d", 32));
    codec.putVarint(w, 1);
    codec.putBytes(w, b("m"));
    codec.putBytes(w, b(""));
    return frameOf(CALL, s(codec.written(w)) + "x");
  };
  h.self.clock = () => {
    throw new Error("a host's own");
  };
  assert.throws(() => h.self.receive(b(callOf(1) + frameOf(12, rep("d", 32) + "\x03who"))), /a host's own/);
  h.self.clock = () => 1800000000000;
  h.run();
  const devices = () => h.client.devices.length;
  assert.equal(devices(), 1, "what came after it was lost");
  h.self.receive(b(callOf(2) + frameOf(12, "")));
  assert(h.client.ready && devices() === 0 && served === 1 && h.self.closes === 0, "the pipe was not read on");
}
{
  // Nothing is told to what was stopped, cancelled or closed since, even while others are being told, nor told as it was
// once it is otherwise.
{
  // An observer that closes the client: the rest hear of it as it is then, once, and never as it was.
  const h = harness();
  h.run();
  h.greet();
  const log: string[] = [];
  h.client.on("status", (up) => log.push(`status ${up}`));
  let armed = false;
  for (const name of ["one", "two"]) {
    h.client.window({ scope: 1, list: "a", table: Note }, (st) => {
      log.push(`${name} ${st.status}`);
      if (armed && st.status === "ready") (armed = false), h.client.close(), log.push("closed");
    });
  }
  h.client.window({ scope: 1, list: "b", table: Note }, (st) => log.push(`other ${st.status}`));
  h.run();
  const pages = h.self.said.filter((x) => x.kind === WATCH).map(watchOf);
  log.length = 0;
  armed = true;
  h.self.receive(b(pages.map(([id, , lo, hi]) => syncedOf(id, lo, hi)).join("")));
  h.run();
  const closed = log.indexOf("closed");
  assert(closed > 0, log.join());
  for (const line of log.slice(closed)) assert(!line.endsWith("ready") || line === "other ready", `${line} after it closed: ${log}`);
  for (const line of new Set(log)) assert.equal(log.filter((x) => x === line).length, 1, `${line} twice: ${log}`);
  assert(log.includes("two stale") && log.includes("other stale"), log.join());
}
{
  // A listener of "status" that closes the client: the rest are told it is down, not that it is up.
  const h = harness();
  h.run();
  const log: string[] = [];
  h.client.on("status", (up) => {
    log.push(`one ${up}`);
    if (up) h.client.close();
  });
  h.client.on("status", (up) => log.push(`two ${up}`));
  h.greet();
  h.run();
  assert.equal(log.join(), "one false,two false,one true,one false,two false");
}
{
  // Observers, listeners and followers stopped by one told before them are not told; and followers are told nothing more
  // of what a frame says once one of them closes the client.
  const h = harness();
  h.run();
  h.greet();
  let armed = false, second = 0;
  const handles: { stop: () => void }[] = [];
  handles.push(h.client.window({ scope: 1, list: "a", table: Note }, () => armed && handles[1].stop()));
  handles.push(h.client.window({ scope: 1, list: "a", table: Note }, () => armed && second++));
  let heard = 0;
  let off = () => {};
  h.client.on("status", (up) => !up && off());
  off = h.client.on("status", (up) => !up && heard++);
  h.run();
  const [id, , lo, hi] = watchOf(h.last(WATCH)!);
  armed = true;
  h.self.receive(b(syncedOf(id, lo, hi)));
  h.run();
  assert.equal(second, 0, "a stopped observer was told");
  const followed: string[] = [];
  let unfollow = () => {};
  h.client.follow((row) => {
    followed.push(row);
    unfollow();
    if (followed.length === 1) h.client.close();
  });
  unfollow = h.client.follow(() => followed.push("stopped"));
  const tag = h.client.tag(1, "a");
  const placed = (n: number) => cellOf("\0\0\0\x01" + rep("\x07", 11) + ch(n), 2, 1, n, tag + rep("\0", 7) + ch(n));
  h.self.receive(b(frameOf(CELLS, "\0" + placed(1) + placed(2) + placed(3))));
  h.run();
  assert.equal(followed.length, 1, `followed ${followed}`);
  assert.equal(heard, 0, "a listener stopped was told");
}
{
  // A call that could not be made is told so on a turn of its own, unless it is cancelled first; and a client closed
  // first tells it then, as it does every call it had.
  const h = harness();
  h.run();
  const told: string[] = [];
  const one = h.client.call(DEVICE, 1, "m", "x");
  one.onfault = (f) => told.push(`one ${f}`);
  one.cancel();
  const two = h.client.call(DEVICE, 1, "m", "x");
  two.onfault = (f) => told.push(`two ${f}`);
  h.run();
  assert.equal(told.join(), "two unreachable");
  h.self.closed(); // and with no pipe to let go of, as while one is dialled again
  h.run();
  const three = h.client.call(DEVICE, 1, "m", "x");
  three.onfault = (f) => told.push(`three ${f}`);
  h.client.close();
  assert.equal(told.join(), "two unreachable,three unreachable", "it was not told as the client closed");
  h.run();
  assert.equal(told.length, 2, "it was told again");
}
{
  // Nor is a call that is lost told so once cancelled by another told first.
  const h = harness();
  h.run();
  h.greet();
  const told: string[] = [];
  const one = h.client.call(DEVICE, 1, "m", "x"), two = h.client.call(DEVICE, 1, "m", "x");
  one.onfault = (f) => (told.push(`one ${f}`), two.cancel());
  two.onfault = (f) => told.push(`two ${f}`);
  h.run();
  h.self.closed();
  h.run();
  assert.equal(told.join(), "one lost");
}
{
  // A window stopped, and let go of, asks for nothing more of what it was stopped on.
  const h = harness();
  h.run();
  h.greet();
  const win = h.client.window({ scope: 1, list: "a", table: Note, size: 2 }, () => {});
  h.run();
  const [id, , lo, hi] = watchOf(h.last(WATCH)!);
  const w = codec.writer();
  codec.putVarint(w, id);
  codec.putU8(w, 1);
  codec.putKey(w, lo);
  codec.putKey(w, hi);
  codec.putVarint(w, 5);
  codec.putVarint(w, 5);
  h.self.receive(b(frameOf(SYNCED, s(codec.written(w)))));
  h.run();
  win.stop();
  h.laters();
  h.run();
  const from = h.self.said.length;
  win.loadAfter();
  win.loadBefore();
  win.visible(0, 1);
  h.run();
  assert.deepEqual(h.self.said.slice(from).map((x) => x.kind), [], "a window let go of asked for more");
}
// Questions asked meanwhile, as by code that waited for one asked once, are asked once each.
  const h = harness();
  h.run();
  for (let i = 0; i < 5; i++) h.client.ask({ scope: 1, table: Note }, () => {});
  for (let i = 0; i < 5; i++) {
    void h.client.fetch({ scope: 99, table: Note }).then(() => {
      for (let j = 0; j < 10; j++) h.client.ask({ scope: 1, table: Note }, () => {});
    });
  }
  const from = h.self.said.length;
  h.greet();
  await tick();
  h.run();
  const counts = new Map<number, number>();
  for (const x of h.self.said.slice(from)) {
    if (x.kind !== ASK) continue;
    const id = codec.varint(codec.reader(b(x.body)));
    counts.set(id, (counts.get(id) ?? 0) + 1);
  }
  assert.equal(counts.size, 55);
  for (const [id, n] of counts) assert.equal(n, 1, `question ${id} was asked ${n} times`);
}
{
  // Nor is one asked meanwhile by this client itself, as for an editor's row that nothing shows once its question is
  // denied on the pipe come up.
  const h = harness();
  h.run();
  const roster = (...scopes: number[]) => rep("\0", 8) + scopes.map((n) => ch(n) + "\x07" + rep("k", 32)).join("");
  h.tell(ROSTER, roster(1, 2));
  h.client.ask({ scope: 2, table: Note }, () => {});
  h.run();
  const row = "\0\0\0\x01" + rep("\x07", 12);
  const w = codec.writer();
  codec.putVarint(w, codec.varint(codec.reader(b(h.last(ASK)!.body))));
  codec.putU8(w, 1);
  codec.putVarint(w, 1);
  codec.putVarint(w, 0);
  codec.putVarint(w, 1);
  codec.putBinary(w, row);
  codec.putVarint(w, 0);
  h.tell(ANSWER, s(codec.written(w)));
  const editor = h.client.text(codec.hex(b(row)), Note.body);
  h.run();
  h.self.closed();
  h.run();
  h.laters();
  h.run();
  const from = h.self.said.length;
  h.tell(ROSTER, roster(1));
  const counts = new Map<number, number>();
  for (const x of h.self.said.slice(from)) {
    if (x.kind !== ASK) continue;
    const id = codec.varint(codec.reader(b(x.body)));
    counts.set(id, (counts.get(id) ?? 0) + 1);
  }
  assert.equal(counts.size, 1, "the editor's row was not asked for");
  for (const [id, n] of counts) assert.equal(n, 1, `question ${id} was asked ${n} times`);
  editor.close();
}

// A row an editor has open that moves within its window, or from one window to another, is never without one to show
// it: no question is asked for it, as one would be once nothing shows it.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.client.window({ scope: 1, list: "b", table: Note }, () => {});
  h.run();
  let id = "";
  void h.client.write(1, (change) => (id = change.insert(Note, "a", 10, { title: "t" })));
  h.run();
  const editor = h.client.text(id, Note.body);
  h.run();
  const from = h.self.said.length;
  void h.client.write(1, (change) => change.place(id, "a", 20));
  h.run();
  void h.client.write(1, (change) => change.place(id, "b", 1));
  h.run();
  for (const x of h.self.said.slice(from)) assert(x.kind !== ASK && x.kind !== FETCH, `said ${x.kind}`);
  assert.equal(Client.internals(h.client).asked.size, 0);
  // And one that goes from every window is asked for, while it is open.
  void h.client.write(1, (change) => change.place(id, "c", 1));
  h.run();
  assert(h.last(ASK) && Client.internals(h.client).asked.size === 1);
  editor.close();
  h.run();
  assert(h.last(UNASK));
}

// An editor of a row held for nothing but what this client wrote in another of its columns waits, as for one not held at
// all, for the row: what it does is done to the text the row has.
{
  const h = harness();
  h.run();
  h.greet();
  const id = "00000001" + "6b49d200" + "0102030405060a0b", bin = codec.binaryFromHex(id);
  void h.client.write(1, (change) => change.set(id, Note, { title: "t" }));
  h.run();
  const editor = h.client.text(id, Note.body);
  h.run();
  editor.delete(0, 5);
  editor.insert(0, "HELLO!");
  const fetched = codec.varint(codec.reader(b(h.last(FETCH)!.body)));
  h.tell(CELLS, "\0" + cellOf(bin, 3, 17, 2, "hello"));
  const w = codec.writer();
  codec.putVarint(w, fetched);
  codec.putBinary(w, "\x01\x01\0\x01" + bin + "\0");
  h.tell(ANSWER, s(codec.written(w)));
  await tick();
  h.run();
  assert.equal(editor.read(), "HELLO!");
  editor.close();
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

// Nonsense from the pipe ends the pipe and nothing else: a length longer than any frame's, a frame of nothing, a frame cut
// short, a varint of more bytes than any. And it is as lost as any pipe: dialled again, and all is as it was.
for (const nonsense of [rep("\x80", 310) + "\0", "\0", "\x03\x02\0\0", "\x0c\x08" + rep("\x81", 10) + "\x01"]) {
  const h = harness();
  h.run();
  h.greet();
  h.self.receive(b(nonsense));
  assert.equal(h.self.closes, 1, "the pipe was not let go of");
  assert(!h.client.ready, "and it is not connected");
  h.laters();
  h.run();
  assert.equal(h.self.connects, 2, "dialled again");
  h.greet();
  assert(h.client.ready);
  const call = h.client.call(codec.hex(rep("d", 32)), 1, "m", "");
  assert.throws(() => call.send(new Uint8Array(262145)), "a message too big for any window is refused at once");
}

// What a pipe says after it was let go of, as by whoever was told of an error, is not heard: a client that was closed is
// not connected again by a roster that followed.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.on("error", () => h.client.close());
  const frame = (kind: number, body: string) => {
    const w = codec.writer();
    codec.putBytes(w, b(ch(kind) + body));
    return s(codec.written(w));
  };
  h.self.receive(b(frame(ERROR, "\x04") + frame(ROSTER, rep("\0", 8) + "\x01\x07" + rep("k", 32))));
  h.run();
  assert(!h.client.ready, "connected by what was said after it was closed");
}

// What anyone may write cannot break what everyone reads: a value that does not read is no value, and a bundle cut short
// is what its entries before the cut say.
{
  const h = harness();
  h.run();
  h.greet();
  const Doc = { meta: c.json<{ n: number }>(16), title: c.string(18), body: c.text(17) };
  let seen!: State<typeof Doc>;
  const shown = () => seen;
  h.client.window({ scope: 1, list: "a", table: Doc }, (x) => (seen = x));
  h.run();
  const cell = (row: string, kind: number, slot: number, n: number, body: string) => {
    const w = codec.writer();
    codec.putBinary(w, ch(kind) + row + ch(slot) + rep("\0", 15) + ch(n));
    codec.putBytes(w, b(body));
    return s(codec.written(w));
  };
  const one = "\0\0\0\x01" + rep("1", 12), two = "\0\0\0\x01" + rep("2", 12);
  const place = (row: string) => cell(row, 2, 1, 1, h.client.tag(1, "a") + codec.u64(1));
  // Two entries, each typing a letter, the second cut short.
  const entry = (k: number, letter: string) => rep("\0", 15) + ch(k) + codec.u64(k) + ch(5) + "\x01\0\0\x01" + letter;
  const bundle = "\0\0\0\x02" + rep("\0", 15) + ch(4) + rep("\0", 15) + ch(5) + entry(4, "a") + entry(5, "b").slice(0, 20);
  h.tell(CELLS, "\0" + place(one) + cell(one, 3, 16, 2, "{not json") + cell(one, 3, 18, 3, "ok") + cell(one, 5, 17, 9, bundle));
  h.tell(CELLS, "\0" + place(two) + cell(two, 3, 16, 2, "") + cell(two, 3, 18, 3, "also"));
  assert.equal(shown().rows.length, 2);
  const [first, second] = shown().rows;
  assert.equal(first.meta, undefined);
  assert.equal(first.title, "ok");
  assert.equal(first.body, "a");
  assert.equal(second.meta, undefined);
  assert.equal(second.title, "also");
}

// A cell no node could have sent is nonsense, and ends the pipe rather than be looked through: a bundle that says it holds
// more stamps than it has, or is too short to say how many; a placement too short to say where; a value where only
// placements go. What came before it is shown, as it is held.
for (const bad of [
  (row: string) => cellOf(row, 4, 17, 2, rep("p", 8)) + cellOf("", 5 + 128, 17, 3, "\x80\0\0\0"),
  (row: string) => cellOf(row, 5, 17, 3, "ab"),
  (row: string) => cellOf(row, 2, 1, 3, rep("t", 10)),
  (row: string) => cellOf(row, 3, 3, 3, "x"),
]) {
  const h = harness();
  h.run();
  h.greet();
  let seen!: State<typeof Note>;
  h.client.window({ scope: 1, list: "a", table: Note }, (x) => (seen = x));
  h.run();
  const one = "\0\0\0\x01" + rep("1", 12), two = "\0\0\0\x01" + rep("2", 12);
  h.tell(CELLS, "\0" + cellOf(one, 2, 1, 1, h.client.tag(1, "a") + codec.u64(1)) + bad(two));
  assert.equal(h.self.closes, 1, "the pipe was not let go of");
  assert.equal((seen as State<typeof Note>).rows.length, 1, "what came before it was not shown");
}

// Positions in a text are where they are shown, whatever its bytes: one that is not UTF-8 shows as one character.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.run();
  const one = "\0\0\0\x01" + rep("1", 12);
  const cell = (kind: number, slot: number, n: number, body: string) => {
    const w = codec.writer();
    codec.putBinary(w, ch(kind) + one + ch(slot) + rep("\0", 15) + ch(n));
    codec.putBytes(w, b(body));
    return s(codec.written(w));
  };
  h.tell(CELLS, "\0" + cell(2, 1, 1, h.client.tag(1, "a") + codec.u64(1)) + cell(3, 17, 2, "\xffabc"));
  const editor = h.client.text(codec.hex(one), Note.body);
  assert.equal(editor.read(), "\ufffdabc");
  editor.delete(1, 1);
  assert.equal(editor.read(), "\ufffdbc");
  editor.insert(1, "x");
  assert.equal(editor.read(), "\ufffdxbc");
  editor.close();
}

// A change that throws is as if it had never been: nothing of it is shown, held or said.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.run();
  let id = "";
  void h.client.write(1, (change) => (id = change.insert(Note, "a", 1, { title: "kept", body: "typed" })));
  h.run();
  h.tell(ACK, "\x01");
  const said = h.self.said.length;
  const rows = Client.internals(h.client).rows.size;
  assert.throws(
    () =>
      h.client.write(1, (change) => {
        change.set(id, Note, { title: "gone" }); // over what was there, which it would kill
        change.insert(Note, "a", 2, { title: "never" });
        change.edit(id, Note.body.slot, (t, fresh) => text.insert(t, 0, "x", fresh));
        change.delete(id);
        throw new Error("changed my mind");
      }),
    /changed my mind/,
  );
  h.run();
  assert.equal(h.self.said.length, said, "nothing was said");
  assert.equal(Client.internals(h.client).rows.size, rows, "nothing new is held");
  // The row as it is held: not deleted, its title what it was, its text what it was.
  const row = h.client.held(id)!;
  assert(!row.dead, "the deletion stands");
  const titles = [...row.slots.get(16)!.values()].map((cell) => new TextDecoder().decode(cell.body));
  assert.deepEqual(titles, ["kept"], "what the new title killed is not back");
  assert.equal(text.read(h.client.heldText(id, Note.body.slot)!), "typed");
}

// A change that edits a row not held, and fails, leaves nothing held of it; and one that writes over what an editor has
// typed and not sealed writes over it here as at the node, where what the editor typed comes first.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.run();
  const unheld = "00000001" + "6b49d200" + "756e68656c642121";
  assert.throws(() =>
    h.client.write(1, (change) => {
      change.edit(unheld, 17, (t, fresh) => text.insert(t, 0, "x", fresh));
      throw new Error("not after all");
    }),
  );
  assert.equal(h.client.held(unheld), undefined, "what failed left a row held");
  let id = "";
  void h.client.write(1, (change) => (id = change.insert(Note, "a", 1, { title: "t", body: "start" })));
  h.run();
  const editor = h.client.text(id, Note.body);
  editor.append(" typed");
  void h.client.write(1, (change) => change.set(id, Note, { body: "over" }));
  h.run();
  assert.equal(editor.read(), "over", "what was written over");
  assert.deepEqual([...h.client.held(id)!.slots.get(17)!.values()].map((c) => c.kind), [3], "what was typed outlived what was written over it");
  editor.close();
}

// What is asked of it is checked before anything is done: ids, devices and slots of the wrong size, and typos that are not
// a whole number; and text is what was written, a byte order mark and all.
{
  const h = harness();
  h.run();
  h.greet();
  let seen!: State<typeof Note>;
  h.client.window({ scope: 1, list: "a", table: Note }, (x) => (seen = x));
  h.run();
  let id = "";
  void h.client.write(1, (change) => (id = change.insert(Note, "a", 1, { title: "\ufeffmarked" })));
  h.run();
  assert.equal(seen.rows[0].title, "\ufeffmarked");
  const said = h.self.said.length;
  assert.throws(() => h.client.call("abcd", 1, "m", "x"), RangeError);
  assert.equal(h.self.said.length, said, "nothing was said of it");
  assert.throws(() => h.client.write(1, (change) => change.place(id, "b", 1, 0)), RangeError);
  assert.throws(() => h.client.write(1, (change) => change.place(id, "b", 1, 16)), RangeError);
  assert.throws(() => h.client.text("abcd", Note.body), RangeError);
  assert.throws(() => h.client.held("zz"), RangeError);
  const tag = () => rep("\0", 16);
  const typos = (n: number) => s(ask.write({ scope: 1, table: Note, where: where.matches("title", "x", { typos: n as 1 }) }, tag)[0]);
  assert.equal(typos(1.5), typos(1));
}

// What a node would refuse, and end the pipe for, never leaves the client, and throws where it is asked for: a row of
// another scope, whatever this client may do there; one made later than any clock may yet say; a cell where a column made
// by hand puts one that no node takes. Nothing of the change is done.
{
  const h = harness();
  h.run();
  h.tell(ROSTER, rep("\0", 8) + "\x01\x07" + rep("k", 32) + "\x02\x01" + rep("k", 32) + "\x03\x07" + rep("k", 32));
  h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.run();
  let mine = "";
  void h.client.write(1, (change) => (mine = change.insert(Note, "a", 1, { title: "t" })));
  h.run();
  const theirs = "00000002" + "6b49d200" + "0102030405060708", other = "00000003" + "6b49d200" + "0102030405060708";
  const said = h.self.said.length;
  // What is held of the rows, cell by cell.
  const held = () =>
    [mine, theirs, other]
      .flatMap((id) => {
        const row = h.client.held(id);
        return row ? ["row", ...[...row.slots].flatMap(([slot, cells]) => [...cells.keys()].map((stamp) => `${slot}:${codec.hex(stamp)}`))] : ["none"];
      })
      .sort()
      .join();
  for (const [scope, id] of [[1, theirs], [1, other], [3, mine]] as const) {
    const before = held();
    assert.throws(() => h.client.write(scope, (change) => change.set(id, Note, { title: "x" })), /another scope/);
    assert.throws(() => h.client.write(scope, (change) => change.place(id, "a", 2)), /another scope/);
    assert.throws(() => h.client.write(scope, (change) => change.delete(id)), /another scope/);
    assert.throws(() => h.client.write(scope, (change) => change.edit(id, 17, (t, fresh) => text.insert(t, 0, "x", fresh))), /another scope/);
    assert.equal(held(), before, "something of it was done");
  }
  const later = "00000001" + codec.hex(codec.u32Binary(1800000000 + 15 * 60 + 1)) + "0102030405060708";
  assert.throws(() => h.client.write(1, (change) => change.set(later, Note, { title: "x" })), /made later/);
  assert.throws(() => h.client.write(1, (change) => change.set(mine, { odd: { ...c.string(16), slot: 3 } }, { odd: "x" })), /slot 3/);
  const editor = h.client.text(theirs, Note.body);
  assert.throws(() => editor.append("x"), /may not write/);
  editor.close();
  h.run();
  assert(!h.self.said.slice(said).some((x) => x.kind === CELLS), "and something was written");
  assert(!h.client.held(later), "and is held");
  // A row made a little later than this client's clock, as by a device whose clock runs ahead, is written at a stamp
  // no earlier than it was made.
  const soon = "00000001" + codec.hex(codec.u32Binary(1800000060)) + "0102030405060708";
  void h.client.write(1, (change) => change.set(soon, Note, { title: "x" }));
  h.run();
  const written = b(h.last(CELLS)!.body);
  assert(codec.fromU64(s(written.subarray(19, 27))) >= 1800000060000 * 65536, "it was written before it was made");
}

// What was written where this client may no longer write, since it was written, is not said again to the next pipe:
// a node would refuse it, and this client with it, for good.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.run();
  h.self.closed();
  h.run();
  void h.client.write(1, (change) => change.insert(Note, "a", 1, { title: "offline" }));
  h.run();
  h.laters();
  h.run();
  const said = h.self.said.length;
  h.tell(ROSTER, rep("\0", 8) + "\x01\x05" + rep("k", 32)); // read and call, and no more
  assert(!h.self.said.slice(said).some((x) => x.kind === CELLS), "it was said");
  h.self.closed();
  h.run();
  h.laters();
  h.run();
  h.greet();
  assert(!h.self.said.slice(said).some((x) => x.kind === CELLS), "it was said once it might be");
}

// A pipe the node found fault with is dialled again later and later, as what this client says it would say again; one
// that was well, soon.
{
  const h = harness();
  h.run();
  const waits: number[] = [];
  for (let i = 0; i < 5; i++) {
    h.greet();
    h.tell(ERROR, "\x01");
    h.self.closed();
    h.run();
    waits.push(h.self.waits[h.self.waits.length - 1]);
    h.laters();
    h.run();
  }
  assert.deepEqual(waits, [100, 200, 400, 800, 1600], "it was dialled again at once");
  h.greet();
  h.self.closed();
  h.run();
  assert.equal(h.self.waits[h.self.waits.length - 1], 100, "and was slow to after a pipe that was well");
}

// A change that throws in the middle of an edit leaves nothing of the edit to be sent later; and what an editor had typed
// and not yet sealed, in a slot such a change touched, stands, here as at the node.
{
  const h = harness();
  h.run();
  h.greet();
  h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.run();
  let id = "";
  void h.client.write(1, (change) => (id = change.insert(Note, "a", 1, { title: "t", body: "start" })));
  h.run();
  h.tell(ACK, "\x01");
  const pieces = () =>
    h.self.said
      .filter((x) => x.kind === CELLS)
      .map((x) => x.body)
      .join("");
  assert.throws(
    () =>
      h.client.write(1, (change) =>
        change.edit(id, Note.body.slot, (t, fresh) => {
          text.insert(t, 0, "boom", fresh);
          throw new Error("no");
        }),
      ),
    /no/,
  );
  const editor = h.client.text(id, Note.body);
  assert.equal(editor.read(), "start");
  editor.append(" more");
  editor.commit();
  h.run();
  assert(!pieces().includes("boom"), "what was undone was sent");
  // Typing, not yet sealed; then a change that writes the slot over, and throws.
  editor.append(" typed");
  h.run();
  assert.throws(
    () =>
      h.client.write(1, (change) => {
        change.set(id, Note, { body: "over" });
        throw new Error("no");
      }),
    /no/,
  );
  h.run();
  assert.equal(editor.read(), "start more typed", "the editor's typing was lost here");
  assert(pieces().includes(" typed"), "and said to the node");
  // And so when the change touched another slot of the row first.
  editor.append(" more");
  h.run();
  assert.throws(
    () =>
      h.client.write(1, (change) => {
        change.set(id, Note, { title: "other" });
        change.set(id, Note, { body: "over" });
        throw new Error("no");
      }),
    /no/,
  );
  h.run();
  assert.equal(editor.read(), "start more typed more", "the editor's typing was lost when another slot was touched first");
  assert.equal(pieces().split(" more").length, 3, "and said to the node");
  editor.close();
}

// A client that is closed is not connected, says so, and what it was calling is lost.
{
  const h = harness();
  h.run();
  h.greet();
  const told: boolean[] = [];
  h.client.on("status", (up) => told.push(up));
  const call = h.client.call(codec.hex(rep("d", 32)), 1, "m", "x");
  let fault = "";
  call.onfault = (f) => (fault = f);
  let rejected = "";
  void h.client.request(codec.hex(rep("d", 32)), 1, "m", "y").catch((e) => (rejected = e.fault));
  h.run();
  h.client.close();
  h.run();
  await tick();
  assert(!h.client.ready, "it is not connected");
  assert.deepEqual(told, [true, false], "and says so");
  assert.equal(fault, "lost");
  assert.equal(rejected, "lost");
  h.laters();
  h.run();
  assert.equal(h.self.connects, 1, "and does not dial again");
}

// A client that is closed leaves nothing to be done later, whatever was to be: a window to let go of, a piece to seal,
// live text to give up on. What an editor had typed is said first, sealed.
{
  const h = harness();
  h.run();
  h.greet();
  const list = h.client.window({ scope: 1, list: "a", table: Note }, () => {});
  h.run();
  let id = "";
  void h.client.write(1, (change) => (id = change.insert(Note, "a", 1, { title: "t" })));
  h.run();
  const editor = h.client.text(id, Note.body);
  editor.append("typed");
  h.run();
  const w = codec.writer();
  codec.putBinary(w, codec.binaryFromHex(id));
  codec.putU8(w, 17);
  codec.putBinary(w, rep("v", 8));
  codec.putVarint(w, 0);
  codec.putBinary(w, rep("\0", 16));
  codec.putBinary(w, "\x01\0\0\x02hi");
  h.tell(9, s(codec.written(w))); // live text, which is given up on if never sealed
  list.stop();
  assert(h.self.timers >= 3, `${h.self.timers} things to do`);
  const cells = h.self.said.filter((x) => x.kind === CELLS).length;
  h.client.close();
  assert.equal(h.self.timers, 0, "something was left to be done");
  assert.equal(h.self.said.filter((x) => x.kind === CELLS).length, cells + 1, "what was typed was not said");
}

// A node that refuses this client, or speaks another language, closes it: questions asked once are answered as far as
// they got, and nothing is left to be done later, nor dialled again.
for (const code of [2, 3]) {
  const h = harness();
  h.run();
  h.greet();
  let got: Answer<typeof Note> | undefined;
  void h.client.fetch({ scope: 1, table: Note }).then((x) => (got = x));
  h.run();
  h.tell(ERROR, ch(code));
  await tick();
  assert.equal(got?.status, "loading", "what was asked once was never answered");
  assert(!h.client.ready && h.self.timers === 0, "something was left to be done");
  h.laters();
  h.run();
  assert.equal(h.self.connects, 1, "and it was dialled again");
}

// A call made before the node has said what this client may do cannot be made, and is told so as it was when it was
// made, though the node says it before the call is told.
{
  const h = harness();
  h.run();
  const call = h.client.call(codec.hex(rep("d", 32)), 1, "m", "");
  let fault = "";
  call.onfault = (f) => (fault = f);
  h.greet();
  assert.equal(fault, "unreachable");
}

// One function that observes, hears or follows twice is two that do: stopping one leaves the other.
{
  const h = harness();
  h.run();
  h.greet();
  let heard = 0, seen = 0, followed = 0;
  const hear = () => void heard++, see = () => void seen++, follow = () => void followed++;
  const stopHearing = h.client.on("error", hear);
  h.client.on("error", hear);
  const one = h.client.window({ scope: 1, list: "a", table: Note }, see);
  h.client.window({ scope: 1, list: "a", table: Note }, see);
  const stopFollowing = h.client.follow(follow);
  h.client.follow(follow);
  h.run();
  stopHearing();
  one.stop();
  stopFollowing();
  heard = seen = followed = 0;
  void h.client.write(1, (change) => change.insert(Note, "a", 1, { title: "t" }));
  h.tell(ERROR, "\x04");
  h.run();
  assert.deepEqual([heard, seen, followed], [1, 1, 1], "heard, seen, followed");
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
  // And in a document: whose its title and its text are, by name, not what is in them.
  const doc = m.open(h.client, {
    scope: 2,
    name: "signed",
    schema: m.map({ title: c.string(16), by: c.author(16), body: c.text(17), writers: c.authors(17) }),
  });
  h.run();
  void doc.set({ title: "t", body: "typed" });
  h.run();
  const st = doc.state;
  assert(st.title === "t" && st.body === "typed");
  assert(st.by === "me", `the title is mine, not ${st.by}`);
  assert(st.writers.length === 1 && st.writers[0] === "me", "and the text");
  doc.close();
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
  assert(h.last(CALL)!.body.slice(-9) === "\x01m\0\x03hello", "and for whom is not for it to say; its urgency is 3 unless said");
  assert(h.last(SERVE));
  // An urgency, of 0 to 7, is the call's own; a call to it carries none.
  void h.client.request(codec.hex(rep("e", 32)), 2, "m", "hi", { urgency: 1 });
  h.run();
  assert(h.last(CALL)!.body.slice(-6) === "\x01m\0\x01hi", "a call says how urgent it is");
  h.client.call(codec.hex(rep("e", 32)), 2, "m", "", { urgency: 0 });
  h.client.call(codec.hex(rep("e", 32)), 2, "m", "", { urgency: 7 });
  h.run();
  const urgencies = h.self.said.filter((x) => x.kind === CALL).slice(-2).map((x) => x.body.slice(-1));
  assert.deepEqual(urgencies, ["\0", "\x07"], "from the most urgent to the least");
  const quiet = h.self.said.length;
  for (const urgency of [8, -1, 1.5, NaN]) {
    assert.throws(() => h.client.call(codec.hex(rep("e", 32)), 2, "m", "", { urgency }), RangeError);
    await assert.rejects(h.client.request(codec.hex(rep("e", 32)), 2, "m", "", { urgency }), RangeError);
  }
  h.run();
  assert.equal(h.self.said.length, quiet, "and none other is said");
}

// What a change types in a text, in a scope that says whose things are, is this client's at once, as what it sets is.
{
  const Signed = { title: c.string(16), by: c.author(16), body: c.text(17), writers: c.authors(17) };
  const h = harness();
  h.run();
  h.tell(ROSTER, rep("\0", 8) + "\x02\x87" + rep("k", 32));
  h.tell(AUTHOR, "\0" + rep("d", 32) + "\x02me");
  let seen!: State<typeof Signed>;
  h.client.window({ scope: 2, list: "a", table: Signed }, (x) => (seen = x));
  h.run();
  void h.client.write(2, (change) => {
    const id = change.insert(Signed, "a", 1, { title: "t" });
    change.edit(id, Signed.body.slot, (t, fresh) => text.insert(t, 0, "typed", fresh));
  });
  h.run();
  const row = (seen as State<typeof Signed>).rows[0];
  assert(row.body === "typed" && row.by === "me");
  assert.deepEqual(row.writers, ["me"], "what was typed is nobody's until the node says");
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
    let names = "";
    parts.forEach((p, i) => {
      names += rep("\0", 15) + ch(n + i + 1);
      out += rep("\0", 15) + ch(n + i + 1) + codec.u64(n + i + 1) + ch(4 + p.length) + "\x01\0\0" + ch(p.length) + p;
    });
    return "\0\0\0" + ch(parts.length) + names + out;
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
