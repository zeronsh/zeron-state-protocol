// Structured state at its edges: before a client knows its scope, texts not given, and values changed in place; and what
// is asked about, at its edges too.

import assert from "node:assert/strict";
import { where } from "../src/ask.ts";
import { Client, columns as c } from "../src/client.ts";
import * as m from "../src/mirror.ts";
import * as codec from "../src/codec.ts";
import { admit, drain, hear, KEY, peer, run, type Peer } from "./peers.ts";

let clock = 1800000000000;
const random = (n: number) => crypto.getRandomValues(new Uint8Array(n));
const now = () => clock;
// Every peer's node hears all that every peer has written since last time, its own writing as well as the others'.
const told = new Map<Peer, number>();
const share = (...peers: Peer[]) => {
  for (const from of peers) {
    for (let k = told.get(from) ?? 0; k < from.out.length; k++) for (const to of peers) hear(to, from.out[k]);
    told.set(from, from.out.length);
  }
};

// Opened before its client knows the scope, every map is of the one id that is nothing's; but one map is not another.
{
  const client = new Client({ connect: () => ({ send() {}, close() {} }), defer: () => {}, after: () => () => {} });
  const Doc = m.map({ a: m.map({ x: c.string(16) }), b: m.map({ y: c.number(17) }) });
  const d = m.open(client, { scope: 1, name: "d", schema: Doc });
  assert.notEqual(d.state.a, d.state.b, "two maps are one");
  d.close();
}

// A text not given in what is set is empty, as a text always is, and is written as an edit: what another types in it
// meanwhile is kept, as it is when "" is set.
{
  const Doc = m.map({ n: c.number(16), body: c.text(17) });
  const a = peer(random, now), b = peer(random, now);
  const da = m.open(a.client, { scope: 1, name: "t", schema: Doc });
  const db = m.open(b.client, { scope: 1, name: "t", schema: Doc });
  void da.set({ n: 1, body: "" });
  run(a);
  share(a, b);
  clock++;
  void db.update((d) => void (d.body = "theirs"));
  run(b);
  clock++;
  void da.set({ n: 3 } as m.Input<typeof Doc>); // body not given, and "" to a, which has not heard
  run(a);
  share(a, b);
  assert.equal(da.state.n, 3);
  assert.equal(da.state.body, "theirs", "what b typed was undone by what a did not say");
  assert.equal(db.state.body, "theirs");
}

// What a column holds, JSON or bytes, is changed in a draft as it would be anywhere, and that change is written; what is
// shown cannot be changed in place.
{
  const Doc = m.map({ meta: c.json<{ count: number; tags: string[] }>(16), raw: c.bytes(18) });
  const a = peer(random, now), b = peer(random, now);
  const da = m.open(a.client, { scope: 1, name: "j", schema: Doc });
  const db = m.open(b.client, { scope: 1, name: "j", schema: Doc });
  void da.set({ meta: { count: 1, tags: ["x"] }, raw: Uint8Array.of(1, 2, 3) });
  run(a);
  share(a, b);
  assert.throws(() => ((da.state.meta as { count: number }).count = 5), TypeError, "what is shown changed in place");
  assert.equal(da.state.meta?.count, 1);
  const before = a.out.length;
  void da.update((d) => void d.meta); // read, and nothing else
  run(a);
  assert.equal(a.out.length, before, "what was only read was written");
  clock++;
  void da.update((d) => {
    d.meta!.count = 2;
    d.meta!.tags.push("y");
    d.raw![0] = 9;
  });
  run(a);
  share(a, b);
  assert.deepEqual(db.state.meta, { count: 2, tags: ["x", "y"] });
  assert.deepEqual([...db.state.raw!], [9, 2, 3]);
}

// And so it is in lists and records of them: what is read in a draft is a copy, written if it was changed, and nothing is
// written if nothing was, nor for what is put there anew that is what was there.
{
  const Doc = m.map({ metas: m.list(16, c.json<{ count: number; tags: string[] }>(16)), raws: m.list(17, c.bytes(16)), named: m.record(c.json<{ count: number }>(16)), blobs: m.record(c.bytes(16)) });
  const a = peer(random, now), b = peer(random, now);
  const da = m.open(a.client, { scope: 1, name: "jl", schema: Doc });
  const db = m.open(b.client, { scope: 1, name: "jl", schema: Doc });
  void da.set({ metas: [{ count: 1, tags: ["x"] }, { count: 7, tags: [] }], raws: [Uint8Array.of(1, 2), Uint8Array.of(3)], named: { k: { count: 1 } }, blobs: { k: Uint8Array.of(4, 5) } });
  run(a);
  share(a, b);
  assert.throws(() => ((da.state.metas[0] as { count: number }).count = 5), TypeError, "what is shown changed in place");
  assert.throws(() => ((da.state.named.k as { count: number }).count = 5), TypeError, "what is shown changed in place");
  const before = a.out.length;
  void da.update((d) => void [d.metas[0], d.raws[0], d.named.k, d.blobs.k]); // read, and nothing else
  run(a);
  assert.equal(a.out.length, before, "what was only read was written");
  void da.update((d) => {
    d.metas = d.metas.map((x) => ({ ...x }));
    d.raws = d.raws.map((x) => x.slice());
    d.named = { k: { count: 1 } };
    d.blobs = { k: Uint8Array.of(4, 5) };
  });
  run(a);
  assert.equal(a.out.length, before, "what is what was there was written again");
  clock++;
  void da.update((d) => {
    d.metas[0].count = 2;
    d.metas[0].tags.push("y");
    d.raws[1][0] = 9;
    d.named.k.count = 3;
    d.blobs.k[1] = 6;
  });
  run(a);
  share(a, b);
  assert.deepEqual(db.state.metas, [{ count: 2, tags: ["x", "y"] }, { count: 7, tags: [] }]);
  assert.deepEqual(db.state.raws.map((x) => [...x]), [[1, 2], [9]]);
  assert.deepEqual({ ...db.state.named }, { k: { count: 3 } });
  assert.deepEqual([...db.state.blobs.k], [4, 6]);
  assert.deepEqual(da.state.metas, db.state.metas);
}

// ---------------------------------------------------------------- asking

const Item = m.map({ n: c.number(16), label: c.string(17), more: m.map({ note: c.string(16) }), parts: m.list(18, m.map({ x: c.number(16) })) });
const Shelf = m.map({ a: m.list(16, Item), A: m.list(17, Item), keys: m.record(c.number(16)), tree: m.tree(18, m.map({ name: c.string(16) })) });

// What is in a list is found by the bytes its rows say they are in, byte for byte: "a" is not "A", whatever case is to text.
{
  const p = peer(random, now);
  const d = m.open(p.client, { scope: 1, name: "shelf", schema: Shelf });
  void d.set({ a: [{ n: 1 }, { n: 2 }], A: [{ n: 3 }, { n: 4 }, { n: 5 }] });
  run(p);
  share(p);
  let got!: m.Found<m.At<typeof Shelf, readonly ["a"]>>;
  const asked = m.ask(p.client, { scope: 1, name: "shelf", schema: Shelf }, ["a"], { order: ["n"] }, (x) => (got = x));
  run(p);
  assert.equal(got.status, "ready");
  assert.deepEqual(
    got.rows.map((r) => r.n),
    [1, 2],
  );
  assert.equal(got.total, 2, "what is in A is counted as in a");
  asked.stop();
  d.close();
}

// Asked before its client knows the scope: loading at once, and answered once it does. What is given is frozen, the same
// object while nothing in it changes, with its maps and without its lists of rows; and it can be moved along, and stopped.
{
  const p = peer(random, now, false);
  const doc = { scope: 1, name: "early", schema: Shelf };
  const heard: m.Found<m.At<typeof Shelf, readonly ["a"]>>[] = [];
  const asked = m.ask(p.client, doc, ["a"], { order: ["n"], limit: 2 }, (x) => void heard.push(x));
  assert.equal(heard.length, 1);
  assert.equal(heard[0].status, "loading");
  assert(Object.isFrozen(heard[0]) && Object.isFrozen(heard[0].rows));
  run(p);
  assert.equal(heard.length, 1, "nothing to tell while nothing is known");
  admit(p);
  const d = m.open(p.client, doc);
  void d.set({ a: [{ n: 1, label: "one", more: { note: "first" }, parts: [{ x: 1 }] }, { n: 2 }, { n: 3 }] });
  run(p);
  share(p);
  let last = heard[heard.length - 1];
  assert.equal(last.status, "ready");
  assert.equal(last.total, 3);
  assert.deepEqual(
    last.rows.map((r) => r.n),
    [1, 2],
  );
  const one = last.rows[0];
  assert(Object.isFrozen(one) && Object.isFrozen(one.more));
  assert.equal(one.id, d.state.a[0].id);
  assert.equal(one.more.note, "first", "its maps are given with it");
  assert(!("parts" in one), "its lists of rows are not");
  // Another row changes: what did not is the very same.
  void d.update((x) => void (x.a[1].label = "two"));
  run(p);
  share(p);
  last = heard[heard.length - 1];
  assert.equal(last.rows[1].label, "two");
  assert.equal(last.rows[0], one, "what did not change is the very same");
  asked.move(2, 2);
  run(p);
  last = heard[heard.length - 1];
  assert.equal(last.first, 2);
  assert.deepEqual(
    last.rows.map((r) => r.n),
    [3],
  );
  const told = heard.length;
  asked.stop();
  void d.update((x) => void x.a.push({ n: 4, more: {}, parts: [] }));
  run(p);
  share(p);
  assert.equal(heard.length, told, "told after it was stopped");
  assert.equal(p.asked.size, 0, "and all it asked is stopped");
  d.close();
}

// Moved before its client knows the scope, it is asked where it was moved to.
{
  const p = peer(random, now, false);
  const doc = { scope: 1, name: "moved", schema: Shelf };
  let last!: m.Found<m.At<typeof Shelf, readonly ["a"]>>;
  const asked = m.ask(p.client, doc, ["a"], { order: ["n"], limit: 2 }, (x) => (last = x));
  asked.move(1);
  admit(p);
  const d = m.open(p.client, doc);
  void d.set({ a: [{ n: 1 }, { n: 2 }, { n: 3 }, { n: 4 }] });
  run(p);
  share(p);
  assert.equal(last.status, "ready");
  assert.equal(last.first, 1, "moved before it was asked, and asked from the start");
  assert.deepEqual(
    last.rows.map((r) => r.n),
    [2, 3],
  );
  asked.stop();
  d.close();
}

// Of a tree, every node beneath one that answers is given with it, and so are the maps within each, which are asked for
// too: by another, which holds none of them.
{
  const Plan = m.map({ tree: m.tree(16, m.map({ name: c.string(17), more: m.map({ note: c.string(16) }) })) });
  const a = peer(random, now), b = peer(random, now);
  const doc = { scope: 1, name: "plan", schema: Plan };
  const d = m.open(a.client, doc);
  void d.set({ tree: [{ name: "top", more: { note: "up" }, children: [{ name: "mid", more: { note: "middle" }, children: [{ name: "low", more: { note: "down" } }] }] }] });
  run(a);
  share(a, b);
  let got!: m.Found<m.At<typeof Plan, readonly ["tree"]>>;
  const asked = m.ask(b.client, doc, ["tree"], { where: where.is("name", "top") }, (x) => (got = x));
  for (let i = 0; i < 4; i++) run(b);
  assert.equal(got.status, "ready");
  const top = got.rows[0];
  assert.equal(top.more.note, "up");
  assert.equal(top.children[0].name, "mid");
  assert.equal(top.children[0].more.note, "middle", "the maps within a node beneath were not asked for");
  assert.equal(top.children[0].children[0].more.note, "down");
  asked.stop();
  d.close();
}

// Records, of values and of maps, and trees, at any depth; and whose each is. A path says where, or it is no path.
{
  const p = peer(random, now);
  const doc = { scope: 1, name: "deep", schema: Shelf };
  const d = m.open(p.client, doc);
  void d.set({ keys: { x: 3, y: 1, z: 2 }, tree: [{ name: "top", children: [{ name: "low" }] }], a: [{ n: 1, parts: [{ x: 5 }, { x: 6 }] }] });
  run(p);
  share(p);
  let keys!: m.Found<m.At<typeof Shelf, readonly ["keys"]>>;
  let tree!: m.Found<m.At<typeof Shelf, readonly ["tree"]>>;
  let parts!: m.Found<m.At<typeof Shelf, readonly ["a", string, "parts"]>>;
  const asked = [
    m.ask(p.client, doc, ["keys"], { where: where.over("value", 1), order: ["value"] }, (x) => (keys = x)),
    m.ask(p.client, doc, ["tree"], { where: where.is("name", "low") }, (x) => (tree = x)),
    m.ask(p.client, doc, ["a", d.state.a[0].id, "parts"], { order: ["-x"] }, (x) => (parts = x)),
  ];
  run(p);
  assert.deepEqual([...keys.rows], [2, 3]);
  assert.deepEqual([...keys.keys], ["z", "x"]);
  assert.equal(tree.rows.length, 1);
  assert.equal(tree.rows[0].name, "low");
  assert.deepEqual([...tree.rows[0].children], []);
  assert.deepEqual(
    parts.rows.map((r) => r.x),
    [6, 5],
  );
  for (const q of asked) q.stop();
  const bad = (path: readonly string[], why: RegExp) => assert.throws(() => m.ask(p.client, doc, path as m.Path<typeof Shelf>, {}, () => {}), why);
  bad([], /names what is asked about/);
  bad(["nothing"], /no nothing/);
  bad(["a", "not an id", "parts"], /no id/);
  bad(["keys", "x", "y"], /holds nothing/);
  const Values = m.map({ v: m.list(16, c.number(16)), inner: m.map({ x: c.string(16) }) });
  assert.throws(() => m.ask(p.client, { scope: 1, name: "v", schema: Values }, ["v"] as never, {}, () => {}), /read, not asked about/);
  assert.throws(() => m.ask(p.client, { scope: 1, name: "v", schema: Values }, ["inner"] as never, {}, () => {}), /a map is not asked about/);
  d.close();
}

// A text not given where the document has not come yet is not written: an empty one over it, newer, would wipe what
// another typed in it meanwhile.
{
  const Doc = m.map({ title: c.string(16), notes: c.text(17) });
  const a = peer(random, now), b = peer(random, now);
  const da = m.open(a.client, { scope: 1, name: "unheard", schema: Doc });
  const db = m.open(b.client, { scope: 1, name: "unheard", schema: Doc });
  run(a);
  run(b);
  void da.set({ notes: "what a typed" } as m.Input<typeof Doc>);
  run(a);
  clock++;
  void db.set({ title: "hello" } as m.Input<typeof Doc>); // b has heard nothing of the document
  run(b);
  share(a, b);
  assert.equal(da.state.title, "hello");
  assert.equal(da.state.notes, "what a typed", "what a typed was wiped by what b did not say");
  assert.equal(db.state.notes, "what a typed");
}

// A key of a record within a key let go of is let go of as a key is, not deleted, which would be for ever: so that it can
// be set again, in the change that sets its key again or any after.
{
  const Doc = m.map({ title: c.string(16), outer: m.record(m.map({ inner: m.record(c.number(17)) })) });
  const a = peer(random, now);
  const d = m.open(a.client, { scope: 1, name: "keys", schema: Doc });
  for (const [title, outer] of [
    ["1", { x: { inner: { k: 1 } } }],
    ["2", {}],
    ["3", { x: { inner: { k: 42 } } }],
    ["4", { x: { inner: { k: 99 } } }],
  ] as const) {
    clock++;
    void d.set({ title, outer } as m.Input<typeof Doc>);
    run(a);
    assert.equal(d.state.outer.x?.inner.k, (outer as { x?: { inner: { k: number } } }).x?.inner.k, `set ${title}`);
  }
  d.close();
}
// And one another put in it while it was let go of here, let go of by what this writes next, is too.
{
  const Doc = m.map({ groups: m.record(m.map({ members: m.record(c.string(16)) })) });
  const a = peer(random, now), b = peer(random, now);
  const da = m.open(a.client, { scope: 1, name: "groups", schema: Doc });
  const db = m.open(b.client, { scope: 1, name: "groups", schema: Doc });
  void da.set({ groups: { team: { members: { alice: "lead" } } } });
  run(a);
  share(a, b);
  clock++;
  void da.set({ groups: {} });
  run(a);
  void db.set({ groups: { team: { members: { alice: "lead", bob: "eng" } } } });
  run(b);
  share(a, b);
  clock++;
  void da.set({ groups: { other: { members: {} } } }); // and so bob, in team let go of, is let go of too
  run(a);
  share(a, b);
  assert.deepEqual(Object.keys(da.state.groups), ["other"], "team is let go of");
  clock++;
  void db.set({ groups: { ...db.state.groups, team: { members: { bob: "back" } } } });
  run(b);
  share(a, b);
  assert.equal(da.state.groups.team?.members.bob, "back", "bob can never be set again");
  assert.equal(db.state.groups.team?.members.bob, "back");
}

// And the key set again with it, here, has it as it is set: what is set again is not let go of after.
{
  const Doc = m.map({ groups: m.record(m.map({ members: m.record(c.string(16)) })) });
  const a = peer(random, now), b = peer(random, now);
  const da = m.open(a.client, { scope: 1, name: "again", schema: Doc });
  const db = m.open(b.client, { scope: 1, name: "again", schema: Doc });
  void da.set({ groups: { team: { members: { alice: "lead" } } } });
  run(a);
  share(a, b);
  void db.set({ groups: { team: { members: { alice: "lead", bob: "eng" } } } });
  run(b);
  clock++;
  void da.set({ groups: {} });
  run(a);
  share(a, b);
  clock++;
  void da.set({ groups: { team: { members: { bob: "mine" } } } });
  run(a);
  share(a, b);
  assert.equal(da.state.groups.team?.members.bob, "mine", "what was set again was let go of after");
  assert.equal(db.state.groups.team?.members.bob, "mine");
}

// Concurrent edits of a character of more than one byte are of whole characters: what they make is UTF-8 still.
{
  const Doc = m.map({ body: c.text(16) });
  const a = peer(random, now), b = peer(random, now);
  const da = m.open(a.client, { scope: 1, name: "utf8", schema: Doc });
  const db = m.open(b.client, { scope: 1, name: "utf8", schema: Doc });
  void da.set({ body: "café" });
  run(a);
  share(a, b);
  clock++;
  void da.set({ body: "cafè" });
  run(a);
  void db.set({ body: "cafê" });
  run(b);
  share(a, b);
  assert.equal(da.state.body, db.state.body);
  assert(["cafèê", "cafêè"].includes(da.state.body), `what they made is ${JSON.stringify(da.state.body)}`);
}

// What is asked of a scope this client may not read says so, as a question of its own does, rather than load for ever.
{
  const a = peer(random, now);
  const Doc = m.map({ items: m.list(18, m.map({ name: c.string(16) })) });
  let mine = "", theirs = "";
  const own = a.client.ask({ scope: 99, table: { name: c.string(16) } }, (x) => (mine = x.status));
  const q = m.ask(a.client, { scope: 99, name: "doc", schema: Doc }, ["items"], {}, (f) => (theirs = f.status));
  run(a);
  assert.equal(mine, "denied");
  assert.equal(theirs, "denied", "it loads for ever");
  own.stop();
  q.stop();
}

// What answers at once, as a record asked about does once what this client may do is known, is said after loading and
// not before it: so what is said last is what answers, with its keys.
{
  const a = peer(random, now);
  const Doc = m.map({ tags: m.record(c.string(16)) });
  const said: m.Found<any>[] = [];
  const q = m.ask(a.client, { scope: 1, name: "tagged", schema: Doc }, ["tags"], {}, (f) => said.push(f));
  run(a);
  assert(said[0].status === "loading" && said[0].keys !== undefined, "loading is said first, as of a record");
  assert(said[said.length - 1].keys !== undefined, "what answered was said over by loading, with no keys");
  q.stop();
}

// Each key let go of is let go of once, however many keys let go of it is within: no row is written twice in one place by
// one change.
{
  const Doc = m.map({ a: m.record(m.map({ b: m.record(m.map({ c: m.record(c.string(16)) })) })) });
  const p1 = peer(random, now), p2 = peer(random, now);
  const d1 = m.open(p1.client, { scope: 1, name: "deep", schema: Doc });
  const d2 = m.open(p2.client, { scope: 1, name: "deep", schema: Doc });
  void d1.set({ a: { k1: { b: { k2: { c: { x: "1" } } } } } });
  run(p1);
  share(p1, p2);
  void d2.set({ a: { k1: { b: { k2: { c: { x: "1", k4: "v" } } } } } });
  run(p2);
  clock++;
  void d1.set({ a: {} });
  run(p1);
  share(p1, p2);
  const since = p1.out.length;
  clock++;
  void d1.set({ a: { other: { b: {} } } }); // and so k4, in k2 in k1, both let go of, is let go of too
  run(p1);
  for (const cells of p1.out.slice(since)) {
    const r = codec.reader(cells);
    const seen = new Set<string>();
    let id = "";
    while (r.pos < r.len) {
      const tag = codec.u8(r);
      if (tag < 128) id = codec.binary(codec.take(r, 16));
      const slot = codec.u8(r);
      codec.take(r, 16);
      codec.bytes(r);
      if (tag & 64) codec.varint(r);
      assert(!seen.has(id + slot), "a row written twice in one place, by one change");
      seen.add(id + slot);
    }
  }
}

// And what is asked of a scope this client comes to be able to read says so, as what answers comes.
{
  const a = peer(random, now);
  const Doc = m.map({ items: m.list(18, m.map({ name: c.string(16) })) });
  const statuses: string[] = [];
  const q = m.ask(a.client, { scope: 99, name: "doc", schema: Doc }, ["items"], {}, (f) => statuses.push(f.status));
  run(a);
  const w = codec.writer();
  codec.putU8(w, 2); // what this client may do: read, write and call in scopes 1 and 99
  codec.putBinary(w, "\0".repeat(8) + "\x01\x07" + KEY + "\x63\x07" + KEY);
  const framed = codec.writer();
  codec.putBytes(framed, codec.written(w));
  a.receive(codec.written(framed).slice());
  drain(a); // and nothing yet that answers
  assert.deepEqual(statuses, ["denied", "loading"], "it stays denied");
  q.stop();
}

// What is taken out of a list of values in a draft, by pop, shift or splice, is as what is read there: a copy, to change.
{
  const Doc = m.map({ items: m.list(16, c.json<{ count: number }>(16)) });
  const a = peer(random, now);
  const d = m.open(a.client, { scope: 1, name: "taken", schema: Doc });
  void d.set({ items: [{ count: 1 }, { count: 2 }, { count: 3 }, { count: 4 }] });
  run(a);
  for (const take of [(l: { count: number }[]) => l.pop(), (l: { count: number }[]) => l.shift(), (l: { count: number }[]) => l.splice(0, 1)[0]]) {
    clock++;
    let failed: unknown;
    try {
      d.update((draft) => {
        const x = take(draft.items as { count: number }[])!;
        x.count = 99; // as an item read there can be
      }).catch((e) => (failed = e));
    } catch (e) {
      failed = e;
    }
    run(a);
    assert.equal(failed, undefined, "what was taken out could not be changed");
  }
  assert.deepEqual(d.state.items, [{ count: 3 }]);
}

// What is asked about and stopped by what answers at once, as it is asked, is stopped: every question with it.
{
  const a = peer(random, now, false);
  let made = 0, stopped = 0;
  const ask = a.client.ask.bind(a.client);
  (a.client as { ask: Client["ask"] }).ask = ((q: Parameters<Client["ask"]>[0], f: Parameters<Client["ask"]>[1]) => {
    made++;
    const h = ask(q, f);
    return { move: h.move, stop: () => (stopped++, h.stop()) };
  }) as Client["ask"];
  const Doc = m.map({ items: m.list(16, m.map({ title: c.string(16), ref: c.bytes(17) })) });
  const statuses: string[] = [];
  const q: { stop(): void } = m.ask(a.client, { scope: 1, name: "leak", schema: Doc }, ["items"], { where: where.refers("ref", 99, where.inList("other")) }, (f) => {
    statuses.push(f.status);
    if (f.status === "denied") q.stop();
  });
  admit(a); // and so it is asked, and denied at once
  run(a);
  assert(statuses.includes("denied"), `said ${statuses}`);
  assert(made > 0 && stopped === made, `${made} asked and ${stopped} stopped`);
}

console.log("ok");
