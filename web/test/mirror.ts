// Structured state on two devices, whatever the devices are. The same as luau/tests/mirror.luau, so that every client is
// held to the same. `node web/test/mirror.ts` runs it as test/end_to_end.ts does, over two web devices and a relay.

import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { columns as c, type Client } from "../src/client.ts";
import * as m from "../src/mirror.ts";
import { random } from "./random.ts";

export interface Sides {
  a: Client;
  b: Client;
  say?(line: string): void;
}

const sleep = (ms: number) => new Promise<void>((done) => setTimeout(done, ms));

async function eventually(what: string, f: () => boolean): Promise<void> {
  for (let k = 0; k < 500; k++) {
    if (f()) return;
    await sleep(10);
  }
  throw new Error("never: " + what);
}

function check(ok: unknown, what: string): asserts ok {
  if (!ok) throw new Error(what);
}

function equal(a: unknown, b: unknown): boolean {
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return Object.is(a, b);
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  for (const k of Object.keys(x)) if (!equal(x[k], y[k])) return false;
  for (const k of Object.keys(y)) if (!(k in x)) return false;
  return true;
}

function differ(x: unknown, y: unknown, path: string): string | undefined {
  if (equal(x, y)) return undefined;
  if (typeof x !== "object" || typeof y !== "object" || x === null || y === null) return `${path}: ${String(x)} / ${String(y)}`;
  const a = x as Record<string, unknown>, b = y as Record<string, unknown>;
  for (const k of new Set([...Object.keys(a), ...Object.keys(b)])) {
    const d = differ(a[k], b[k], `${path}.${k}`);
    if (d) return d;
  }
  return path;
}

function show(v: unknown): string {
  if (typeof v !== "object" || v === null) return String(v);
  const o = v as Record<string, unknown>;
  return "{" + Object.keys(o).filter((k) => k !== "id").map((k) => `${k}=${show(o[k])}`).sort().join(", ") + "}";
}

const Task = m.map({ title: c.string(16), done: c.boolean(17), notes: c.text(18), tags: m.list(19, c.string(16)) });
const Node = m.map({ name: c.string(16) });
const Board = m.map({
  title: c.string(16),
  count: c.number(17),
  meta: m.map({ owner: c.string(16), created: c.number(17) }),
  tasks: m.list(18, Task),
  scores: m.record(c.number(16)),
  people: m.record(m.map({ role: c.string(16), bio: c.text(17) })),
  outline: m.tree(19, Node),
});
type Outline = m.Draft<typeof Board>["outline"];

export async function mirrorSuite({ a: ca, b: cb, say = console.log }: Sides): Promise<void> {
  // Opened before it is connected, it is empty, and then as it is.
  let early: m.Doc<typeof Board> | undefined;
  const b = m.open(cb, { scope: 1, name: "board", schema: Board }, (state) => (early = state));
  check(early && early.tasks.length === 0 && early.title === undefined, "empty at first");
  await eventually("both connect", () => ca.ready && cb.ready && ca.may(1, "write") && cb.may(1, "write"));
  const a = m.open(ca, { scope: 1, name: "board", schema: Board });
  const level = async (what: string) => {
    for (let k = 0; k < 500; k++) {
      if (equal(a.state, b.state)) return;
      await sleep(10);
    }
    throw new Error(`never: ${what}: ${differ(a.state, b.state, "")}`);
  };

  // What one sets, the other has, as it was set.
  check(a.state.title === undefined && a.state.tasks.length === 0, "nothing yet");
  void a.set({
    title: "Launch",
    count: 3,
    meta: { owner: "ann", created: 1700000000 },
    tasks: [
      { title: "write it", done: true, notes: "the first draft", tags: ["doc", "now"] },
      { title: "test it", done: false, notes: "", tags: [] },
      { title: "ship it", done: false, tags: ["later"] },
    ],
    scores: { ann: 3, bob: 5 },
    people: { ann: { role: "lead", bio: "writes" } },
    outline: [{ name: "plan", children: [{ name: "goals" }, { name: "risks" }] }, { name: "do" }],
  });
  const mine = a.state;
  check(mine.title === "Launch" && mine.tasks.length === 3 && mine.tasks[0].tags[1] === "now" && mine.outline[0].children[1].name === "risks", show(mine));
  check(mine.tasks[0].id && mine.outline[0].id, "what is made has an id");
  await level("the other has it");
  check(early === b.state, "and the one opened early is told");
  check(b.state.scores.bob === 5 && b.state.people.ann.bio === "writes" && b.state.meta.owner === "ann", show(b.state));

  // What did not change is the very same object.
  const before = a.state;
  void a.update((d) => {
    d.tasks[1].done = true;
  });
  const after = a.state;
  check(after.tasks[1].done === true && after.tasks[1] !== before.tasks[1], "what changed is new");
  check(after.tasks[0] === before.tasks[0] && after.tasks[2] === before.tasks[2], "and the rest is not");
  check(after.meta === before.meta && after.outline === before.outline && after.scores === before.scores, "nor anything else");
  await level("a change goes over");

  // Moves, deletions, keys, and a node moved elsewhere in a tree.
  void a.update((d) => {
    d.tasks.unshift(d.tasks.pop()!);
    d.tasks.splice(2, 1);
    delete d.scores.bob;
    d.scores.cy = 1;
    const [risks] = d.outline[0].children.splice(1, 1);
    d.outline[1].children.push(risks);
    d.tasks[0].tags = ["first", "later", "last"];
  });
  const s = a.state;
  check(s.tasks[0].title === "ship it" && s.tasks[1].title === "write it" && s.tasks.length === 2, show(s.tasks));
  check(s.scores.bob === undefined && s.scores.cy === 1 && s.outline[1].children[0].name === "risks" && s.outline[0].children.length === 1, show(s));
  check(s.tasks[0].tags[2] === "last", show(s.tasks[0]));
  await level("moves go over");

  // Both at once, neither having heard of the other.
  void a.update((d) => {
    d.tasks.unshift({ title: "from a", tags: [] });
    d.tasks[2].title = "write it well"; // "write it", now third
    d.scores.cy = 10;
    d.tasks[1].notes = "a: " + (d.tasks[1].notes ?? "");
    const plan = d.outline.shift()!; // plan under do
    d.outline[0].children.push(plan);
  });
  void b.update((d) => {
    d.tasks.unshift({ title: "from b", tags: [] });
    d.tasks[2].done = true; // the same task, by b's reckoning second
    d.scores.cy = 20;
    d.tasks[1].notes = (d.tasks[1].notes ?? "") + " :b";
    const done = d.outline.splice(1, 1)[0]; // do under plan
    d.outline[0].children.push(done);
    delete d.people.ann; // and one deleted that the other edits
  });
  void a.update((d) => {
    if (d.people.ann) d.people.ann.role = "boss";
  });
  await level("both at once come to one");
  const s2 = a.state;
  const titles = new Map(s2.tasks.map((t) => [t.title, t]));
  check(titles.has("from a") && titles.has("from b"), "both are there");
  check(titles.get("write it well")?.done === true, "each change to one task is kept " + show(s2.tasks));
  check(s2.scores.cy === 10 || s2.scores.cy === 20, "one of the two");
  check(s2.people.ann === undefined, "what is gone is gone, whatever was done to it meanwhile");
  let count = 0;
  const walk = (level: m.Doc<typeof Board>["outline"]) => {
    for (const n of level) {
      count++;
      walk(n.children);
    }
  };
  walk(s2.outline);
  check(count === 4, `every node somewhere, and no loop: ${show(s2.outline)}`);
  const notes = titles.get("ship it")!.notes;
  check(notes.includes("a: ") && notes.includes(" :b"), `text kept from both: ${notes}`);

  // One place, written into again and again: room is made, and the order is as it was written.
  const Squeeze = m.map({ items: m.list(17, c.number(16)) });
  const sa = m.open(ca, { scope: 1, name: "squeeze", schema: Squeeze });
  const sb = m.open(cb, { scope: 1, name: "squeeze", schema: Squeeze });
  void sa.set({ items: [0, 1000] });
  const want = [0];
  for (let i = 1; i <= 80; i++) {
    void sa.update((d) => void d.items.splice(i, 0, i));
    want.push(i);
  }
  want.push(1000);
  check(equal(sa.state.items, want), show(sa.state.items));
  await eventually("the other has the same order", () => equal(sb.state.items, want));
  sa.close();
  sb.close();

  // Any changes, by both, at once: one state, and a tree without loops.
  const rng = random(7);
  const R = (n: number) => rng.int(1, n);
  const words = ["alpha", "beta", "gamma", "delta", "eps"];
  const word = () => words[R(words.length) - 1];
  const mutate = (d: m.Draft<typeof Board>) => {
    for (let times = rng.int(1, 4); times > 0; times--) {
      const r = R(9);
      if (r === 1) {
        d.tasks.splice(R(d.tasks.length + 1) - 1, 0, { title: word(), done: R(2) === 1, tags: [word()] });
      } else if (r === 2 && d.tasks.length > 0) {
        d.tasks.splice(R(d.tasks.length) - 1, 1);
      } else if (r === 3 && d.tasks.length > 1) {
        const [t] = d.tasks.splice(R(d.tasks.length) - 1, 1);
        d.tasks.splice(R(d.tasks.length + 1) - 1, 0, t);
      } else if (r === 4 && d.tasks.length > 0) {
        const t = d.tasks[R(d.tasks.length) - 1];
        t.title = word();
        t.notes = (t.notes ?? "") + word();
        t.tags.splice(R(t.tags.length + 1) - 1, 0, word());
      } else if (r === 5) {
        const k = word();
        if (R(3) === 1) delete d.scores[k];
        else d.scores[k] = R(100);
      } else if (r === 6) {
        const k = word();
        if (R(3) === 1) delete d.people[k];
        else d.people[k] = { role: word() };
      } else if (r === 7) {
        // A node, new or moved, anywhere.
        const collect = (level: Outline, into: Outline): Outline => {
          for (const n of level) {
            into.push(n);
            collect(n.children, into);
          }
          return into;
        };
        const all = collect(d.outline, []);
        if (all.length > 0 && R(2) === 1) {
          const target = all[R(all.length) - 1];
          const take = (level: Outline): Outline[number] | undefined => {
            for (let i = 0; i < level.length; i++) {
              if (level[i] === target) return level.splice(i, 1)[0];
              const found = take(level[i].children);
              if (found) return found;
            }
            return undefined;
          };
          const node = take(d.outline)!;
          const rest = collect(d.outline, []);
          if (rest.length > 0 && R(3) > 1) rest[R(rest.length) - 1].children.push(node);
          else d.outline.push(node);
        } else {
          d.outline.push({ name: word(), children: [] });
        }
      } else if (r === 8) {
        d.count = R(1000);
        d.meta.owner = word();
      } else if (r === 9 && d.tasks.length > 0) {
        d.tasks[R(d.tasks.length) - 1].tags = [];
      }
    }
  };
  for (let round = 1; round <= 40; round++) {
    void a.update(mutate);
    void b.update(mutate);
    await level(`round ${round}`);
    const seen = new Set<string>();
    const tree = (level: m.Doc<typeof Board>["outline"]) => {
      for (const n of level) {
        check(!seen.has(n.id), "a node twice");
        seen.add(n.id);
        tree(n.children);
      }
    };
    tree(a.state.outline);
  }

  // A document of thousands: what one change costs, writing and reading.
  const Big = m.map({ items: m.list(18, m.map({ n: c.number(16), label: c.string(17) })) });
  const big = m.open(ca, { scope: 1, name: "big", schema: Big });
  const items = Array.from({ length: 2000 }, (_, i) => ({ n: i + 1, label: `item ${i + 1}` }));
  let t0 = performance.now();
  void big.set({ items });
  const made = performance.now() - t0;
  t0 = performance.now();
  for (let k = 0; k < 20; k++) {
    void big.update((d) => {
      const item = d.items[R(d.items.length) - 1];
      item.n = (item.n ?? 0) + 1;
    });
  }
  const one = (performance.now() - t0) / 20;
  // And as a new state that shares what did not change.
  t0 = performance.now();
  for (let k = 0; k < 20; k++) {
    const now = big.state;
    const list = now.items.slice();
    const i = R(list.length) - 1;
    list[i] = { ...list[i], n: (list[i].n ?? 0) + 1 };
    void big.set({ ...now, items: list });
  }
  const shared = (performance.now() - t0) / 20;
  const other = m.open(cb, { scope: 1, name: "big", schema: Big });
  await eventually("the other has all of it", () => other.state.items.length === 2000);
  check(other.state.items[0].label === "item 1", "and as it was made");
  say(`     2000 rows made in ${made.toFixed(0)} ms; one change among them, written and read again, ${one.toFixed(1)} ms by update, ${shared.toFixed(1)} ms by set`);

  for (const d of [a, b, big, other]) d.close();
}

// Run alone, it is test/end_to_end.ts's, over two web devices through a relay of zspd's.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  execFileSync(process.execPath, [fileURLToPath(new URL("./end_to_end.ts", import.meta.url)), "mirror"], { stdio: "inherit" });
  console.log("ok");
}
