// Structured state at its edges: before a client knows its scope, texts not given, and values changed in place; and what
// is asked about, at its edges too.

import assert from "node:assert/strict";
import { where } from "../src/ask.ts";
import { Client, columns as c } from "../src/client.ts";
import * as m from "../src/mirror.ts";
import { admit, hear, peer, run, type Peer } from "./peers.ts";

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

console.log("ok");
