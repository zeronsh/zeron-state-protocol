// What structured state costs on a client, without a network, as luau/tests/mirror_bench.luau measures it.
// node web/test/mirror_bench.ts [rows...]: 2,000 and 20,000 unless said.

import { columns as c } from "../src/client.ts";
import * as m from "../src/mirror.ts";
import * as codec from "../src/codec.ts";
import { hear, peer, run } from "./peers.ts";
import { random } from "./random.ts";

const rng = random(1);
const R = (n: number) => rng.int(1, n);
const sizes = process.argv.length > 2 ? process.argv.slice(2).map(Number) : [2000, 20000];
const Big = m.map({ items: m.list(18, m.map({ n: c.number(16), label: c.string(17) })) });

for (const N of sizes) {
  const p = peer((n) => Uint8Array.from({ length: n }, () => rng.int(0, 255)), () => 1800000000000);
  const doc = m.open(p.client, { scope: 1, name: "big", schema: Big });
  const items = Array.from({ length: N }, (_, i) => ({ n: i + 1, label: `item ${i + 1}` }));
  const each = (what: string, times: number, f: () => void) => {
    const t = performance.now();
    for (let k = 0; k < times; k++) {
      f();
      run(p);
    }
    console.log(`  ${what.padEnd(58)} ${((performance.now() - t) / times).toFixed(2).padStart(8)} ms`);
  };
  console.log(`${N} rows, each a map in one list`);
  each("made, all at once", 1, () => void doc.set({ items }));
  if (doc.state.items.length !== N) throw new Error("not all of it was made");
  {
    const q = peer((n) => Uint8Array.from({ length: n }, () => rng.int(0, 255)), () => 1800000000000);
    const other = m.open(q.client, { scope: 1, name: "big", schema: Big });
    run(q);
    const sent = codec.writer();
    for (const cells of p.out) codec.put(sent, cells);
    const ms = hear(q, codec.written(sent));
    console.log(`  ${"opened by another, from what a node sends".padEnd(58)} ${ms.toFixed(2).padStart(8)} ms`);
    if (other.state.items.length !== N) throw new Error("the other has not all of it");
    other.close();
  }
  each("one changed, by set, sharing what did not change", 50, () => {
    const now = doc.state;
    const list = [...now.items];
    const i = R(list.length) - 1;
    list[i] = { ...list[i], n: (list[i].n ?? 0) + 1 };
    void doc.set({ ...now, items: list });
  });
  each("one changed, by update", 50, () => {
    void doc.update((d) => {
      const item = d.items[R(d.items.length) - 1];
      item.n = (item.n ?? 0) + 1;
    });
  });
  each("one moved, by set", 50, () => {
    const now = doc.state;
    const list = [...now.items];
    const [x] = list.splice(R(list.length) - 1, 1);
    list.splice(R(list.length + 1) - 1, 0, x);
    void doc.set({ ...now, items: list });
  });
  each("one moved, by update", 50, () => {
    void doc.update((d) => {
      const [x] = d.items.splice(R(d.items.length) - 1, 1);
      d.items.splice(R(d.items.length + 1) - 1, 0, x);
    });
  });
  if (doc.state.items.length !== N) throw new Error("something was lost");
  doc.close();
}
console.log("ok");
