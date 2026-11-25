// Holds text.ts to text.luau: seeded writers type, delete, name elements, stream, seal, bundle and receive, here, and
// text.luau does exactly the same; every step's outcome, the bodies sealed, and where every element ends up must be the
// same byte for byte. node web/test/text.ts [seeds] [first]

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { dirname, join, relative, sep } from "node:path";
import { fileURLToPath } from "node:url";

import * as codec from "../src/codec.ts";
import * as text from "../src/text.ts";
import { random, type Random } from "./random.ts";

const SEEDS = Number(process.argv[2] ?? 300);
const FIRST = Number(process.argv[3] ?? 1);
const STEPS = 250;

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "../..");

type Op =
  | { o: "insert"; w: number; pos: number; bytes: string; fresh: string; str?: 1 }
  | { o: "delete"; w: number; pos: number; count: number; fresh: string }
  | { o: "after"; w: number; name: string; bytes: string; fresh: string; str?: 1 }
  | { o: "remove"; w: number; name: string; count: number; fresh: string }
  | { o: "flush"; w: number }
  | { o: "live"; w: number; f: number; a: number; b: number }
  | { o: "close"; w: number; stamp: string }
  | { o: "apply"; w: number; c: number; cut?: number }
  | { o: "cell"; w: number; kind: number; stamp: string; body: string };

type Cell = { kind: number; stamp: string; body: Uint8Array };

// The same as text.luau's replay: one world of three writers, what each step yields, and where everything ends up.
class World {
  writers = [text.create(), text.create(), text.create()];
  had: number[][] = [[], [], []];
  cells: Cell[] = [];
  flushes: text.Flushed[] = [];
  out: string[] = [];

  apply(w: number, c: number, body?: Uint8Array): string {
    const cell = this.cells[c];
    const result = text.apply(this.writers[w], cell.kind, cell.stamp, body ?? cell.body);
    if (body === undefined) this.had[w].push(c);
    if (result === "rebuild") {
      const t = text.create();
      for (const k of this.had[w]) text.apply(t, this.cells[k].kind, this.cells[k].stamp, this.cells[k].body);
      this.writers[w] = t;
    }
    return result;
  }

  step(op: Op): void {
    const t = this.writers[op.w];
    let ret: string;
    try {
      ret = this.run(t, op);
    } catch (e) {
      if (process.env.VERBOSE) console.error(e);
      ret = "!";
    }
    if (op.o === "cell") {
      this.out.push(ret);
      return;
    }
    const now = this.writers[op.w];
    let line = `${ret}|${text.len(now)}|${now.version}|${text.provisional(now) ? 1 : 0}|${now.waiting.length}`;
    if (this.out.length % 8 === 7) line += "|" + codec.hex(text.content(now));
    assert.equal(text.read(now), new TextDecoder("utf-8", { ignoreBOM: true }).decode(text.content(now)));
    this.out.push(line);
  }

  run(t: text.Text, op: Op): string {
    switch (op.o) {
      case "insert": {
        const fresh = (): string => codec.binaryFromHex(op.fresh);
        text.insert(t, op.pos, op.str ? Buffer.from(op.bytes, "hex").toString("utf8") : codec.unhex(op.bytes), fresh);
        return "";
      }
      case "delete":
        text.erase(t, op.pos, op.count, () => codec.binaryFromHex(op.fresh));
        return "";
      case "after": {
        const bytes = op.str ? Buffer.from(op.bytes, "hex").toString("utf8") : codec.unhex(op.bytes);
        return codec.hex(text.after(t, codec.binaryFromHex(op.name), bytes, () => codec.binaryFromHex(op.fresh)));
      }
      case "remove":
        text.remove(t, codec.binaryFromHex(op.name), op.count, () => codec.binaryFromHex(op.fresh));
        return "";
      case "flush": {
        const f = text.flush(t);
        this.flushes.push(f);
        return `${codec.hex(f[0])},${f[1]},${codec.hex(f[2])}`;
      }
      case "live": {
        const [piece, offset, bytes] = this.flushes[op.f];
        return text.live(t, piece, offset + op.a, bytes.subarray(op.a, op.b));
      }
      case "close": {
        const stamp = codec.binaryFromHex(op.stamp);
        const body = text.close(t, stamp);
        if (body === null) return "nil";
        this.cells.push({ kind: 4, stamp, body });
        this.had[op.w].push(this.cells.length - 1);
        return codec.hex(body);
      }
      case "apply":
        return this.apply(op.w, op.c, op.cut !== undefined ? this.cells[op.c].body.subarray(0, op.cut) : undefined);
      case "cell":
        this.cells.push({ kind: op.kind, stamp: codec.binaryFromHex(op.stamp), body: codec.unhex(op.body) });
        return "cell";
    }
  }

  end(): void {
    const f64 = (v: number): string => {
      const w = codec.writer(8);
      codec.putF64(w, v);
      return codec.hex(codec.written(w));
    };
    for (const [i, t] of this.writers.entries()) {
      const parts: string[] = [];
      for (const name of text.order(t).keys()) {
        const [label, offset] = text.position(t, name)!;
        parts.push(`${codec.hex(name)}:${f64(label)}:${offset}:${text.standing(t, name) ? 1 : 0}`);
      }
      this.out.push(`writer ${i + 1}: ${codec.hex(text.content(t))} ${parts.join(",")} ${text.ids(t).length}`);
    }
    this.out.push(`steps ${text.steps()}`);
  }
}

// ---------------------------------------------------------------- what is done

const utf8 = new TextEncoder();
const LETTERS = ["a", "b", "c", "d", "e", "x", "y", "z", "é", "ß", "中", "😀", "﻿"];

function generate(r: Random): { ops: Op[]; world: World } {
  const world = new World();
  const ops: Op[] = [];
  const used: string[] = [];
  let clock = 0;
  const salt = (): string => codec.u32Binary(r.int(0, 0xffffffff)) + codec.u32Binary(r.int(0, 0xffffffff));
  const fresh = (): string => {
    // Now and then an id already used, as by two writers that were once one virtual machine.
    const id = used.length > 0 && r.int(1, 40) === 1 ? used[r.int(0, used.length - 1)] : salt();
    used.push(id);
    return codec.hex(id);
  };
  const stamp = (): string => codec.u64(++clock * 65536) + (r.int(1, 30) === 1 ? "\0".repeat(8) : salt());
  const typed = (most: number): { bytes: string; str?: 1 } => {
    let s = "";
    for (let n = r.int(1, most); n > 0; n--) s += LETTERS[r.int(0, r.int(1, 3) === 1 ? LETTERS.length - 1 : 5)];
    const bytes = codec.hex(utf8.encode(s));
    return r.int(1, 2) === 1 ? { bytes, str: 1 } : { bytes };
  };
  const pieceCount = (t: text.Text, piece: string): number => t.pieces.get(piece)?.count ?? 0;

  for (let k = 0; k < STEPS; k++) {
    const w = r.int(0, 2);
    const t = world.writers[w];
    const n = text.len(t);
    const pick = r.int(1, 100);
    let op: Op | null = null;
    if (pick <= 30) {
      op = { o: "insert", w, pos: r.int(1, 25) === 1 ? n + r.int(1, 3) : r.int(0, n), ...typed(4), fresh: fresh() };
    } else if (pick <= 38) {
      if (n > 0) op = { o: "delete", w, pos: r.int(0, n - 1), count: r.int(1, 6), fresh: fresh() };
    } else if (pick <= 46) {
      const names = [...text.order(t).keys()];
      const name = names.length === 0 || r.int(1, 6) === 1 ? "" : codec.hex(names[r.int(0, names.length - 1)]);
      const what = r.int(1, 60) === 1 ? { bytes: "" } : typed(3);
      op = { o: "after", w, name, ...what, fresh: fresh() };
    } else if (pick <= 52) {
      const names = [...text.order(t).keys()];
      if (names.length > 0) {
        const name = names[r.int(0, names.length - 1)];
        const left = pieceCount(t, name.slice(0, 8)) - codec.u32Of(name, 8);
        op = { o: "remove", w, name: codec.hex(name), count: r.int(1, Math.min(left, 4)), fresh: fresh() };
      }
    } else if (pick <= 60) {
      op = { o: "flush", w };
    } else if (pick <= 70) {
      if (world.flushes.length > 0) {
        const f = r.int(1, 3) === 1 ? r.int(0, world.flushes.length - 1) : world.flushes.length - 1;
        const size = world.flushes[f][2].length;
        const whole = r.int(1, 4) > 1;
        const a = whole ? 0 : r.int(0, size);
        op = { o: "live", w, f, a, b: whole ? size : r.int(a, size) };
      }
    } else if (pick <= 77) {
      op = { o: "close", w, stamp: codec.hex(stamp()) };
    } else if (pick <= 94) {
      if (world.cells.length > 0) {
        const c = r.int(0, world.cells.length - 1);
        op = r.int(1, 50) === 1 ? { o: "apply", w, c, cut: r.int(0, world.cells[c].body.length) } : { o: "apply", w, c };
      }
    } else if (pick <= 98) {
      // A bundle of pieces, as whoever wrote them may make at any time.
      const pieces = world.cells.filter((c) => c.kind === 4);
      if (pieces.length > 0) {
        const chosen = new Map<string, Cell>();
        for (let m = r.int(1, 5); m > 0; m--) {
          const c = pieces[r.int(0, pieces.length - 1)];
          chosen.set(c.stamp, c);
        }
        const inner = [...chosen.values()].sort((x, y) => (x.stamp < y.stamp ? -1 : 1));
        const b = codec.writer();
        codec.putU32(b, inner.length);
        for (const c of inner) codec.putBinary(b, c.stamp);
        for (const c of inner) {
          codec.putBinary(b, c.stamp);
          codec.put(b, c.body.subarray(0, 8));
          codec.putBytes(b, c.body.subarray(8));
        }
        op = { o: "cell", w, kind: 5, stamp: codec.hex(stamp()), body: codec.hex(codec.written(b)) };
      }
    } else {
      op = { o: "cell", w, kind: 3, stamp: codec.hex(stamp()), body: typed(8).bytes };
    }
    if (op === null) continue;
    ops.push(op);
    world.step(op);
  }
  // Everyone seals, and has everything.
  for (let w = 0; w < 3; w++) {
    const op: Op = { o: "close", w, stamp: codec.hex(stamp()) };
    ops.push(op);
    world.step(op);
  }
  const count = world.cells.length;
  for (let w = 0; w < 3; w++) {
    const order = Array.from({ length: count }, (_, c) => c);
    r.shuffle(order);
    for (const c of order) {
      const op: Op = { o: "apply", w, c };
      ops.push(op);
      world.step(op);
    }
  }
  world.end();
  return { ops, world };
}

// ---------------------------------------------------------------- side by side

const began = performance.now();
const seeds: { seed: number; ops: Op[]; out: string[] }[] = [];
for (let seed = FIRST; seed < FIRST + SEEDS; seed++) {
  const { ops, world } = generate(random(seed));
  seeds.push({ seed, ops, out: world.out });
}
const ran = performance.now();

const input = JSON.stringify({ seeds: seeds.map((s) => ({ ops: s.ops.map((op) => ({ ...op, w: op.w + 1, ...(op.o === "apply" || op.o === "live" ? lua(op) : {}) })) })) });
const luau = relative(here, join(root, "luau/zsp/text")).split(sep).join("/"); // as require takes it, on Windows too
const theirs = execFileSync("lune", ["run", join(here, "text.luau"), luau], { input, maxBuffer: 1 << 30 }).toString().replace(/\n$/, "").split("\n");
const replayed = performance.now();

// Luau counts from one.
function lua(op: Op): object {
  if (op.o === "apply") return { c: op.c + 1 };
  if (op.o === "live") return { f: op.f + 1 };
  return {};
}

let at = 0;
let ops = 0;
let steps = 0;
let threw = 0;
for (const s of seeds) {
  for (const [k, ours] of s.out.entries()) {
    const other = theirs[at++];
    if (ours !== other) {
      const op = k < s.ops.length ? JSON.stringify(s.ops[k]) : "the end";
      assert.fail(`seed ${s.seed}, step ${k + 1} (${op}):\n  text.ts   ${ours}\n  text.luau ${other}`);
    }
  }
  ops += s.ops.length;
  threw += s.out.filter((line) => line.startsWith("!")).length;
  steps = Number(s.out[s.out.length - 1].slice(6));
}
assert.equal(at, theirs.length);
console.log(
  `${SEEDS} seeds, ${ops} steps (${threw} throwing in both), ${steps} steps in finding places: text.ts ${(ran - began).toFixed(0)} ms, ` +
    `text.luau ${(replayed - ran).toFixed(0)} ms`,
);
console.log("ok");
