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
    connects: 0,
    sizes: [] as number[],
    partial: new Uint8Array(0),
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
  const bundle = "\0\0\0\x01" + rep("\0", 15) + ch(1) + entry(4, "a") + entry(5, "b").slice(0, 20);
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
