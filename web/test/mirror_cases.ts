// What structured state is held to in its tests: a document of every kind of thing, changes of every kind to it, and
// cells from someone who minds nothing. As luau/tests/mirror_model.luau has them, which web/test/mirror_interop.luau does too.

import * as codec from "../src/codec.ts";
import { sha256 } from "../src/sha256.ts";
import { Client, columns as c, type Cell, type Column, type Stored } from "../src/client.ts";
import * as m from "../src/mirror.ts";
import { KEY } from "./peers.ts";
import type { Random } from "./random.ts";

const utf8 = new TextEncoder();

export const document = "board";
export function derive(...parts: string[]): string {
  const input = codec.bytesOf(KEY + "zsp-mirror\0" + document + "\0" + parts.join("\0"));
  return codec.u32Binary(1) + codec.u32Binary(0) + codec.binary(sha256(input), 0, 8);
}

export const rows = (client: Client) => Client.internals(client).rows;

export function latest(row: Stored, slot: number): Cell | undefined {
  let best: Cell | undefined;
  for (const cell of row.slots.get(slot)?.values() ?? []) if (cell.kind === 3 && (!best || cell.stamp > best.stamp)) best = cell;
  return best;
}

// ---------------------------------------------------------------- changes of every kind

// A board, with numbers as said: as the client has them, unless one that reads only what is eight bytes is wanted. Its
// tasks have steps and a plan, as luau/tests/mirror_model.luau's do, unless said: web/test/mirror_interop.luau's do not.
export function board(number: (slot: number) => Column<number> = c.number, steps = true) {
  const Step = m.map({ name: c.string(16) });
  const fields = { title: c.string(16), done: c.boolean(17), notes: c.text(18), tags: m.list(19, c.string(16)) };
  const Task = m.map({ ...fields, steps: m.list(20, Step), plan: m.map({ due: number(16) }) });
  const Person = m.map({ role: c.string(16), bio: c.text(17), pets: m.list(18, m.map({ name: c.string(16) })) });
  const Outline = m.map({ name: c.string(16), body: c.text(17), marks: m.list(18, number(16)) });
  return m.map({
    title: c.string(16),
    count: number(17),
    meta: m.map({ owner: c.string(16), size: number(17), more: m.map({ deep: c.boolean(16) }) }),
    tasks: m.list(18, steps ? Task : (m.map(fields) as unknown as typeof Task)),
    scores: m.record(number(16)),
    people: m.record(Person),
    outline: m.tree(19, Outline),
    numbers: m.list(20, number(16)),
  });
}
export type Board = ReturnType<typeof board>;
type Node = m.Draft<Board>["outline"][number];
type Task = m.Draft<Board>["tasks"][number];

export const words = ["alpha", "beta", "gamma", "delta", "eps", "zeta"];

export function mutate(d: m.Draft<Board>, rng: Random, steps = true): void {
  const R = (n: number) => rng.int(1, n); // as Luau's math.random(n)
  const RR = (lo: number, hi: number) => rng.int(lo, hi);
  const word = () => words[R(words.length) - 1];
  for (let times = RR(1, 5); times > 0; times--) {
    const r = R(16);
    if (r === 1) {
      const t = { title: word(), done: R(2) === 1, tags: [word()] };
      d.tasks.splice(RR(1, d.tasks.length + 1) - 1, 0, steps ? { ...t, steps: [{ name: word() }], plan: { due: R(9) } } : (t as Task));
    } else if (r === 2 && d.tasks.length > 0) {
      d.tasks.splice(R(d.tasks.length) - 1, 1);
    } else if (r === 3 && d.tasks.length > 1) {
      const [t] = d.tasks.splice(R(d.tasks.length) - 1, 1);
      d.tasks.splice(RR(1, d.tasks.length + 1) - 1, 0, t);
    } else if (r === 4 && d.tasks.length > 0) {
      const t = d.tasks[R(d.tasks.length) - 1];
      t.title = word();
      const n = t.notes ?? "";
      const at = RR(0, n.length);
      t.notes = n.slice(0, at) + word() + n.slice(at + RR(0, 2));
      t.tags.splice(RR(1, t.tags.length + 1) - 1, 0, word());
      if (t.tags.length > 2 && R(2) === 1) t.tags.shift();
      if (!steps) continue;
      t.plan.due = R(4) === 1 ? undefined : R(9);
      if (R(2) === 1) {
        t.steps.splice(RR(1, t.steps.length + 1) - 1, 0, { name: word() });
      } else if (t.steps.length > 0) {
        const [x] = t.steps.splice(R(t.steps.length) - 1, 1);
        if (R(2) === 1) {
          x.name = word();
          t.steps.splice(RR(1, t.steps.length + 1) - 1, 0, x);
        }
      }
    } else if (r === 5) {
      const k = word();
      if (R(3) === 1) delete d.scores[k];
      else d.scores[k] = R(100);
    } else if (r === 6) {
      const k = word();
      if (R(3) === 1) {
        delete d.people[k];
      } else if (d.people[k]) {
        d.people[k].role = word();
        d.people[k].pets.push({ name: word() });
        d.people[k].bio = (d.people[k].bio ?? "") + word();
      } else {
        d.people[k] = { role: word(), bio: word(), pets: [{ name: word() }] };
      }
    } else if (r <= 9) {
      // A node, new or moved, anywhere; or deleted, with all beneath it.
      const collect = (level: Node[], into: Node[]): Node[] => {
        for (const n of level) {
          into.push(n);
          collect(n.children ?? [], into);
        }
        return into;
      };
      const all = collect(d.outline, []);
      const take = (level: Node[], target: Node): Node | undefined => {
        for (let i = 0; i < level.length; i++) {
          if (level[i] === target) return level.splice(i, 1)[0];
          const found = take(level[i].children ?? [], target);
          if (found) return found;
        }
        return undefined;
      };
      if (all.length > 0 && r === 7) {
        const node = take(d.outline, all[R(all.length) - 1])!;
        const rest = collect(d.outline, []);
        if (rest.length > 0 && R(3) > 1) {
          const into = rest[R(rest.length) - 1];
          into.children ??= [];
          into.children.splice(RR(1, into.children.length + 1) - 1, 0, node);
        } else {
          d.outline.splice(RR(1, d.outline.length + 1) - 1, 0, node);
        }
      } else if (all.length > 0 && r === 8) {
        take(d.outline, all[R(all.length) - 1]);
      } else if (all.length > 0 && R(2) === 1) {
        const n = all[R(all.length) - 1];
        n.name = word();
        n.body = (n.body ?? "") + word();
        n.marks.push(R(100));
      } else {
        const into = all.length > 0 && R(2) === 1 ? all[R(all.length) - 1].children : d.outline;
        into.splice(RR(1, into.length + 1) - 1, 0, { name: word(), children: [], marks: [1, 2] });
      }
    } else if (r === 10) {
      d.count = R(4) === 1 ? undefined : R(1000);
      d.title = word();
    } else if (r === 11) {
      d.meta.owner = word();
      d.meta.more.deep = R(2) === 1;
    } else if (r === 12) {
      d.numbers.splice(RR(1, d.numbers.length + 1) - 1, 0, R(50));
    } else if (r === 13 && d.numbers.length > 0) {
      d.numbers.splice(R(d.numbers.length) - 1, 1);
    } else if (r === 14 && d.numbers.length > 1) {
      d.numbers[R(d.numbers.length) - 1] = R(50);
    } else if (r === 15 && d.tasks.length > 0) {
      d.tasks[R(d.tasks.length) - 1].tags = [];
    } else if (r === 16) {
      // A whole new list, some of it the old.
      const keep = d.tasks.filter(() => R(2) === 1);
      keep.push(steps ? { title: word(), tags: [], steps: [], plan: {} } : ({ title: word(), tags: [] } as unknown as Task));
      d.tasks = keep;
    }
  }
}

// ---------------------------------------------------------------- someone who minds nothing

// Cells as a writer who may write there could send them, saying anything at all: rows that claim to be in any part of
// the document, records with keys that are not theirs, values of any length in any slot, markers that are no one's, and
// pieces of order that refer to what they like.
// What is written in a value, unless said, is any byte; `text` has it printable, as what is read as text is then the same
// to every client, however each reads what is not.
const rep = (n: number, count: number) => String.fromCharCode(n).repeat(count);
export function hostile(client: Client, rng: Random, clock: number, count: number, text = false): Uint8Array {
  const R = (n: number) => rng.int(1, n);
  const RR = (lo: number, hi: number) => rng.int(lo, hi);
  const fields = ["tasks", "scores", "people", "outline", "numbers", "meta", "pets", "marks", "tags", "x"];
  const ids: string[] = [], markers: string[] = [];
  for (const [id, row] of rows(client)) {
    if (row.dead) continue;
    ids.push(id);
    const cell = latest(row, 255);
    if (cell && cell.body.length >= 28) markers.push(codec.binary(cell.body, cell.body.length - 12));
  }
  const anyId = (): string => {
    if (R(3) === 1) return derive(""); // most of what there is hangs from the top
    if (ids.length > 0 && R(4) > 1) return ids[R(ids.length) - 1];
    return codec.u32Binary(1) + codec.u32Binary(RR(0, 3)) + rep(RR(0, 255), 8);
  };
  const anyMarker = (): string => (markers.length > 0 && R(3) > 1 ? markers[R(markers.length) - 1] : rep(RR(0, 255), 12));
  const w = codec.writer();
  for (let times = RR(1, 4); times > 0; times--) {
    const ms = Math.floor(clock * 1000);
    const stamp = codec.u32Binary(Math.floor(ms / 65536)) + String.fromCharCode((ms % 65536) >> 8, ms % 256, (count % 65536) >> 8, count % 256) + rep(RR(0, 255), 8);
    const r = R(5);
    let row: string, slot: number, kind: number, body: Uint8Array;
    if (r <= 2) {
      // A row anywhere, saying it is in anything.
      row = codec.u32Binary(1) + codec.u32Binary(Math.floor(clock)) + rep(RR(0, 255), 8);
      codec.putU8(w, 2);
      codec.putBinary(w, row);
      codec.putU8(w, 1);
      codec.putBinary(w, stamp);
      codec.putBytes(w, codec.bytesOf(client.tag(1, "mirror/" + document) + "\0".repeat(8)));
      slot = 255;
      kind = 3;
      const where = codec.writer();
      codec.putBinary(where, anyId());
      codec.putBytes(where, utf8.encode(R(2) === 1 ? ["scores", "people", "tasks", "outline"][R(4) - 1] : fields[R(fields.length) - 1]));
      const k = RR(0, 4);
      codec.putU8(where, k);
      if (k === 1) codec.putBinary(where, anyMarker());
      else if (k === 2) codec.putBinary(where, String.fromCharCode(RR(0, 1)) + words[R(words.length) - 1]);
      else if (k === 3) codec.putBinary(where, anyId() + anyMarker() + anyId() + anyMarker());
      else codec.putBinary(where, "?".repeat(RR(0, 3)));
      body = codec.written(where);
    } else if (r === 3) {
      // A value of any length in any slot of what there is.
      row = anyId();
      slot = R(3) > 1 ? RR(16, 20) : RR(16, 255);
      kind = 3;
      body = codec.bytesOf(rep(text ? RR(32, 126) : RR(0, 255), RR(0, 9)));
    } else {
      // A piece of order, of any order.
      row = anyId();
      slot = [18, 19, 20][R(3) - 1];
      kind = 4;
      const p = codec.writer();
      codec.putBinary(p, rep(RR(1, 255), 8));
      codec.putU8(p, 1);
      for (let k = 0; k < 2; k++) {
        if (R(3) === 1) {
          codec.putU8(p, 0);
        } else {
          codec.putU8(p, 2);
          const mk = anyMarker();
          codec.putBinary(p, mk.slice(0, 8));
          codec.putVarint(p, codec.u32Of(mk, 8) % 4);
        }
      }
      codec.putBytes(p, new Uint8Array(RR(1, 3)));
      body = codec.written(p);
    }
    codec.putU8(w, kind);
    codec.putBinary(w, row);
    codec.putU8(w, slot);
    codec.putBinary(w, stamp);
    codec.putBytes(w, body);
  }
  return codec.written(w).slice();
}
