// Structured state at its edges: before a client knows its scope, texts not given, and values changed in place.

import assert from "node:assert/strict";
import { Client, columns as c } from "../src/client.ts";
import * as m from "../src/mirror.ts";
import { hear, peer, run, type Peer } from "./peers.ts";

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

console.log("ok");
