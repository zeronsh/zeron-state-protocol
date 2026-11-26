// Structured state, held to what it should be: clients that hear each other's writing in any order and any number of
// times, each of whose documents is at every step what a reading of its rows from nothing says it is; that come to the
// same; and in which each change reads back as what was set. The same as luau/tests/mirror_model.luau.
//
// node web/test/mirror_model.ts [seeds] [quick|plain|both] [first]: with the shortcuts, with every one of them off, or, as
// unless said, both side by side. Each seed is gone over from the same start, so that any one can be gone back to alone.

import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import * as codec from "../src/codec.ts";
import * as text from "../src/text.ts";
import { type Client, type Column, type Stored } from "../src/client.ts";
import * as m from "../src/mirror.ts";
import { board, derive, document, hostile, latest, mutate, rows } from "./mirror_cases.ts";
import { hear, peer, run, type Peer } from "./peers.ts";
import { random, type Random } from "./random.ts";

const SEEDS = Number(process.argv[2] ?? 40);
const MODE = process.argv[3] ?? "both";
const FIRST = Number(process.argv[4] ?? 1);
if (!["quick", "plain", "both"].includes(MODE)) throw new Error("the mode is quick, plain or both");
// And with every shortcut off, held to the same.
if (MODE === "plain") m._plain(true);

let rng: Random = random(1);
const R = (n: number) => rng.int(1, n); // as Luau's math.random(n)
const RR = (lo: number, hi: number) => rng.int(lo, hi);
const bytes = (n: number) => Uint8Array.from({ length: n }, () => rng.int(0, 255));
let clock = 0;

const utf8 = new TextEncoder();
const strict = new TextDecoder("utf-8", { fatal: true });
const ZERO = "\0".repeat(16);
const hex = codec.hex;

// ---------------------------------------------------------------- what a document should be, from nothing

const name = (s: string) => codec.binary(utf8.encode(s));


interface Said {
  owner: string;
  field: string;
  kind: number;
  stamp: string;
  marker: string;
  present: boolean;
  key: string;
  parent: string;
  from: string;
  back: string;
}

// Every row's word on what it is in, read plainly.
function wheres(client: Client): Map<string, Said> {
  const out = new Map<string, Said>();
  for (const [id, row] of rows(client)) {
    if (row.dead) continue;
    const cell = latest(row, 255);
    if (!cell) continue;
    try {
      const r = codec.reader(cell.body);
      const w: Said = { owner: codec.takeBinary(r, 16), field: codec.binary(codec.bytes(r)), kind: codec.u8(r), stamp: cell.stamp, marker: "", present: false, key: "", parent: "", from: "", back: "" };
      const rest = codec.binary(codec.rest(r));
      if (w.kind === 1) {
        w.marker = rest;
      } else if (w.kind === 2) {
        w.present = rest.length > 0 && rest.charCodeAt(0) !== 0;
        w.key = rest.slice(1);
      } else if (w.kind === 3) {
        [w.parent, w.marker, w.from, w.back] = [rest.slice(0, 16), rest.slice(16, 28), rest.slice(28, 44), rest.slice(44, 56)];
      }
      out.set(id, w);
    } catch (e) {
      if (!(e instanceof codec.Malformed)) throw e;
    }
  }
  return out;
}

type Any = any;

function model(client: Client, schema: m.MapSchema): Any {
  const ws = wheres(client);
  const row = (id: string): Stored | undefined => {
    const r = rows(client).get(id);
    return r && !r.dead ? r : undefined;
  };
  const value = (col: Column<any>, r: Stored): unknown => {
    if (col.text) {
      let t = r.texts.get(col.slot);
      if (!t) {
        t = text.create();
        const cells = [...(r.slots.get(col.slot)?.values() ?? [])].sort((a, b) => (a.stamp < b.stamp ? -1 : a.stamp > b.stamp ? 1 : 0));
        for (const cell of cells) text.apply(t, cell.kind, cell.stamp, cell.body);
      }
      return text.read(t);
    }
    const cell = latest(r, col.slot);
    if (!cell || cell.body.length === 0) return undefined;
    try {
      return col.decode(cell.body); // what does not read as one of its kind is nothing
    } catch {
      return undefined;
    }
  };
  const seq = (id: string, slot: number): text.Text | undefined => (row(id) ? client.heldText(hex(id), slot) : undefined);
  const standing = new Set([derive("")]); // there for everyone, come or not
  const box = (b: m.Schema, owner: string, field: string): Any => {
    if (b.kind === "map") {
      standing.add(derive(owner, name(field)));
      return map(b, derive(owner, name(field)));
    }
    if (!row(owner) && !standing.has(owner)) return b.kind === "record" ? {} : [];
    if (b.kind === "list" && !("kind" in b.of)) {
      const t = seq(owner, b.slot);
      const out: unknown[] = [];
      if (t) {
        const all = text.content(t);
        let at = 0;
        while (at < all.length) {
          const r = codec.reader(all.subarray(at));
          let n: number;
          try {
            n = codec.varint(r);
          } catch {
            break;
          }
          if (at + r.pos + n > all.length) break;
          try {
            const v = b.of.decode(all.subarray(at + r.pos, at + r.pos + n));
            if (v !== undefined) out.push(v);
          } catch {}
          at += r.pos + n;
        }
      }
      return out;
    } else if (b.kind === "list") {
      const t = seq(owner, b.slot);
      const order = t ? text.order(t) : new Map<string, number>();
      const items: { id: string; at: number }[] = [];
      for (const [id, w] of ws) if (w.owner === owner && w.field === name(field) && w.kind === 1 && order.has(w.marker)) items.push({ id, at: order.get(w.marker)! });
      items.sort((x, y) => x.at - y.at || (x.id < y.id ? -1 : 1));
      return items.map((it) => map(b.of, it.id));
    } else if (b.kind === "record") {
      const out: Record<string, unknown> = {};
      for (const [id, w] of ws) {
        if (w.owner === owner && w.field === name(field) && w.kind === 2 && w.present && id === derive(owner, name(field), w.key)) {
          let key: string;
          try {
            key = strict.decode(codec.bytesOf(w.key));
          } catch {
            continue;
          }
          if ("kind" in b.of) out[key] = map(b.of, id);
          else {
            const v = value(b.of, row(id)!);
            if (v !== undefined) out[key] = v;
          }
        }
      }
      return out;
    } else {
      // Undo, one at a time, the latest move of each loop, until there is none.
      const nodes = new Map<string, Said>(), parent = new Map<string, string>(), marker = new Map<string, string>();
      for (const [id, w] of ws) {
        if (w.owner === owner && w.field === name(field) && w.kind === 3 && w.back.length === 12) {
          nodes.set(id, w);
          parent.set(id, w.parent);
          marker.set(id, w.marker);
        }
      }
      const undone = new Set<string>();
      const loop = (): string[] | undefined => {
        for (const start of [...nodes.keys()].sort()) {
          const seen = new Map<string, number>(), path: string[] = [];
          let at = start;
          while (at !== ZERO && nodes.has(at) && !seen.has(at)) {
            seen.set(at, path.length);
            path.push(at);
            at = parent.get(at)!;
          }
          if (at !== ZERO && nodes.has(at) && seen.has(at)) return path.slice(seen.get(at));
        }
        return undefined;
      };
      for (let l = loop(); l; l = loop()) {
        let last = l[0];
        for (const id of l) if (nodes.get(id)!.stamp > nodes.get(last)!.stamp) last = id;
        parent.set(last, undone.has(last) ? ZERO : nodes.get(last)!.from);
        marker.set(last, undone.has(last) ? "" : nodes.get(last)!.back);
        undone.add(last);
      }
      const reaches = (id: string): boolean => {
        for (let n = 0; id !== ZERO; n++) {
          if (!nodes.has(id) || n > 10000) return false;
          id = parent.get(id)!;
        }
        return true;
      };
      const level = (under: string): Any[] => {
        const t = seq(under === ZERO ? owner : under, b.slot);
        const order = t ? text.order(t) : new Map<string, number>();
        const items: { id: string; at: number }[] = [];
        for (const id of nodes.keys()) {
          const at = order.get(marker.get(id)!) ?? (marker.get(id) === "" ? Infinity : undefined);
          if (parent.get(id) === under && reaches(id) && at !== undefined) items.push({ id, at });
        }
        items.sort((x, y) => (x.at !== y.at ? (x.at < y.at ? -1 : 1) : x.id < y.id ? -1 : 1));
        return items.map((it) => ({ ...map(b.of, it.id), children: level(it.id) }));
      };
      return level(ZERO);
    }
  };
  const map = (s: m.MapSchema, id: string): Any => {
    const r = row(id);
    const out: Record<string, unknown> = { id: hex(id) };
    for (const [field, f] of Object.entries(s.fields)) {
      if ("kind" in f) out[field] = box(f, id, field);
      else if (r) out[field] = value(f, r);
    }
    return out;
  };
  return map(schema, derive(""));
}

// An empty string is no value, and no text is an empty one.
function equal(a: unknown, b: unknown, ids = true): boolean {
  if (a === "") a = undefined;
  if (b === "") b = undefined;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return Object.is(a, b);
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  for (const k of Object.keys(x)) if ((ids || k !== "id") && !equal(x[k], y[k], ids)) return false;
  for (const k of Object.keys(y)) if ((ids || k !== "id") && !equal(x[k], y[k], ids)) return false;
  return true;
}

// Where two differ first.
function differ(a: unknown, b: unknown, path: string): string | undefined {
  if (equal(a, b)) return undefined;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return `${path}: ${String(a)} / ${String(b)}`;
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) {
    const d = differ(x[k], y[k], `${path}.${k}`);
    if (d) return d;
  }
  return path;
}

function show(v: unknown): string {
  if (typeof v !== "object" || v === null) return String(v);
  const parts = Object.keys(v)
    .filter((k) => k !== "id")
    .map((k) => `${k}=${show((v as Record<string, unknown>)[k])}`)
    .sort();
  return "{" + parts.join(", ") + "}";
}

// A copy as plain objects, as a draft is once it is done with.
function plain(v: unknown): unknown {
  if (typeof v !== "object" || v === null) return v;
  if (Array.isArray(v)) return v.map(plain);
  const out: Record<string, unknown> = {};
  for (const k of Object.keys(v)) out[k] = plain((v as Record<string, unknown>)[k]);
  return out;
}

// ---------------------------------------------------------------- held to it

class Failed extends Error {}

const Board = board();
let hostileClock = 0;

// Both, side by side, each in a process of its own.
async function both(): Promise<void> {
  const self = fileURLToPath(import.meta.url);
  const results = await Promise.all(
    ["quick", "plain"].map(
      (mode) =>
        new Promise<{ code: number | null; out: string }>((done) => {
          const p = spawn(process.execPath, [self, String(SEEDS), mode, String(FIRST)], { stdio: ["ignore", "pipe", "pipe"] });
          let out = "";
          p.stdout.on("data", (d) => (out += d));
          p.stderr.on("data", (d) => (out += d));
          p.on("close", (code) => done({ code, out }));
        }),
    ),
  );
  for (const r of results) process.stdout.write(r.out.replace(/^ok\n/m, ""));
  if (results.some((r) => r.code !== 0)) process.exit(1);
  console.log("ok");
}

function quick(): void {
  const began = performance.now();
  for (let seed = FIRST; seed < FIRST + SEEDS; seed++) {
    rng = random(seed);
    clock = 1800000000;
    hostileClock = 0;
    const n = 2 + (seed % 2);
    const peers: Peer[] = [], docs: m.Mirror<typeof Board>[] = [], others: m.Mirror<typeof Board>[] = [];
    for (let i = 0; i < n; i++) {
      peers[i] = peer(bytes, () => clock * 1000);
      docs[i] = m.open(peers[i].client, { scope: 1, name: "board", schema: Board });
      others[i] = m.open(peers[i].client, { scope: 1, name: "another", schema: Board });
    }
    const log: Uint8Array[] = []; // every write, in the order written
    const check = (i: number, what: string) => {
      const want = model(peers[i].client, Board);
      if (!equal(docs[i].state, want)) {
        const ids = (list: readonly Any[]) => list.map((t) => t.id.slice(-4) + ":" + t.title).join(" ");
        throw new Failed(`seed ${seed}, client ${i + 1}, ${what}: ${differ(docs[i].state, want, "")}\n  mirror ${ids(docs[i].state.tasks)}\n  model  ${ids(want.tasks)}`);
      }
    };
    for (let step = 1; step <= 30; step++) {
      clock += (rng.int(0, 2 ** 30) / 2 ** 30) * 3;
      // Some write; each change reads back as what was set.
      for (let i = 0; i < n; i++) {
        if (R(3) === 1) continue;
        const before = peers[i].out.length;
        if (R(3) === 1) {
          // Another document, of the same shape, in the same scope: nothing of it is in this one.
          void others[i].update((d) => mutate(d, rng));
          run(peers[i]);
        }
        let draft: unknown;
        void docs[i].update((d) => {
          mutate(d, rng);
          draft = plain(d);
        });
        run(peers[i]);
        if (!equal(docs[i].state, draft, false)) {
          throw new Failed(`seed ${seed} step ${step}, client ${i + 1}: what was set is not what is read: ${differ(draft, docs[i].state, "")}\n  set  ${show(draft)}\n  read ${show(docs[i].state)}`);
        }
        check(i, `step ${step}, after writing`);
        for (let k = before; k < peers[i].out.length; k++) log.push(peers[i].out[k]);
      }
      if (seed % 3 === 0 && R(3) === 1) log.push(hostile(peers[0].client, rng, clock, ++hostileClock));
      // Some of what was written reaches some, in any order, some of it twice.
      for (let i = 0; i < n; i++) {
        for (let times = RR(0, 4); times > 0; times--) {
          if (log.length === 0) continue;
          hear(peers[i], log[R(log.length) - 1]);
          check(i, `step ${step}, after hearing`);
        }
      }
    }
    // Then all of it, everywhere: one document.
    for (let i = 0; i < n; i++) {
      const order = log.map((_, k) => k);
      rng.shuffle(order);
      for (const k of order) hear(peers[i], log[k]);
      check(i, "at the end");
    }
    // Each writes once more, which lets go of what nothing shows; and once that is everywhere, nothing is kept that is not
    // shown, but keys that were let go of, which hold nothing.
    if (seed % 3 !== 0) {
      const before = peers.map((p) => p.out.length);
      for (let i = 0; i < n; i++) {
        void docs[i].update(() => {});
        run(peers[i]);
      }
      for (let i = 0; i < n; i++) for (let k = before[i]; k < peers[i].out.length; k++) for (let j = 0; j < n; j++) hear(peers[j], peers[i].out[k]);
      for (let i = 0; i < n; i++) {
        check(i, "after letting go");
        const shown = new Map<string, Any>();
        const walk = (v: unknown) => {
          if (typeof v !== "object" || v === null) return;
          if (typeof (v as Any).id === "string") shown.set((v as Any).id, v);
          for (const x of Object.values(v)) walk(x);
        };
        walk(docs[i].state);
        const tag = peers[i].client.tag(1, "mirror/" + document);
        for (const [id, w] of wheres(peers[i].client)) {
          const row = rows(peers[i].client).get(id)!;
          let here = false;
          for (const cell of row.slots.get(1)?.values() ?? []) here ||= codec.binary(cell.body, 0, 16) === tag;
          let empty = true; // a key that holds nothing, however it came to: as a deleted one is
          for (const slot of row.slots.keys()) {
            if (slot >= 16 && slot < 255) {
              const cell = latest(row, slot);
              empty &&= cell === undefined || cell.body.length === 0;
            }
          }
          const owner = shown.get(hex(w.owner));
          let key: string | undefined;
          try {
            key = strict.decode(codec.bytesOf(w.key));
          } catch {}
          const holder = owner?.[w.field];
          const held = w.kind === 2 && typeof holder === "object" && holder !== null && key !== undefined && holder[key] !== undefined;
          const fine = !here || shown.has(hex(id)) || held || (w.kind === 2 && (!w.present || empty)) || w.kind === 0;
          if (!fine) throw new Failed(`seed ${seed}, client ${i + 1}: a row is kept that nothing shows (kind ${w.kind})`);
        }
      }
    }
    for (let i = 1; i < n; i++) {
      if (!equal(docs[i].state, docs[0].state)) throw new Failed(`seed ${seed}: clients 1 and ${i + 1} differ: ${differ(docs[0].state, docs[i].state, "")}`);
    }
    // No loops, no node twice.
    const seen = new Set<string>();
    const walk = (level: readonly Any[]) => {
      for (const node of level) {
        if (seen.has(node.id)) throw new Failed(`seed ${seed}: a node twice`);
        seen.add(node.id);
        walk(node.children);
      }
    };
    walk(docs[0].state.outline);
  }
  console.log(`${SEEDS} seeds from ${FIRST}${MODE === "plain" ? ", every shortcut off" : ", with the shortcuts"}: ${((performance.now() - began) / 1000).toFixed(2)} s`);
  console.log("ok");
}

if (MODE === "both") await both();
else quick();
