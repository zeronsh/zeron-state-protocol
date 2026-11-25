// Holds ask.ts to ask.luau: seeded questions of every kind of condition, order and total are written by both, and must
// come out the same byte for byte. node web/test/ask.ts [questions] [seed]

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { where, write, type Columns, type Match, type Question, type Total, type Value, type Where } from "../src/ask.ts";
import * as codec from "../src/codec.ts";
import { sha256 } from "../src/sha256.ts";
import { random } from "./random.ts";

const COUNT = Number(process.argv[2] ?? 3000);
const r = random(Number(process.argv[3] ?? 1));
const here = dirname(fileURLToPath(import.meta.url));

const tables: { [name: string]: Columns } = {
  track: {
    name: { slot: 16, is: "string" },
    body: { slot: 17, is: "text" },
    stars: { slot: 18, is: "number" },
    liked: { slot: 19, is: "boolean" },
    album: { slot: 20, is: "id" },
    who: { slot: 21, is: "author" },
    meta: { slot: 255, is: "string" },
  },
  album: { title: { slot: 16, is: "string" }, year: { slot: 17, is: "number" }, owner: { slot: 18, is: "id" }, info: { slot: 30, is: "text" } },
};

// ---------------------------------------------------------------- questions, as both can read them

// A value: a number as its eight bytes, text, a row's id, bytes, or none; or as JSON has it, a boolean or a whole number.
type V = { n: string } | { s: string } | { id: string } | { b: string } | { nil: 1 } | boolean | number;
type C =
  | ["all" | "any", ...C[]]
  | ["none", C]
  | ["is" | "exactly" | "over" | "under", string, V]
  | ["between", string, V, V]
  | ["among", string, V[]]
  | ["begins" | "contains", string, V]
  | ["has", string]
  | ["matches", string, string, Match]
  | ["list", string]
  | ["ids", string[]]
  | ["refers", string, number, C, string]
  | ["referred", number, string, C, V, V, string];
type Q = { scope: number; table: string; where?: C; order?: string[]; offset?: number; limit?: number; fromEnd?: boolean; totals?: { [name: string]: Total } };

type Kind = "text" | "number" | "boolean" | "id" | "author";
// Columns of each table by what their values are: names, and names into JSON.
const COLUMNS: { [table: string]: { [kind in Kind]: string[] } } = {
  track: {
    text: ["name", "body", "meta.tags", "meta.ünï.code", "meta.s:string", "meta.t:text"],
    number: ["stars", "meta.size:number", "@created", "@modified"],
    boolean: ["liked", "meta.flag:boolean"],
    id: ["album", "meta.ref:id", "meta.ref:row"],
    author: ["who"],
  },
  album: { text: ["title", "info"], number: ["year", "info.x:number", "@created"], boolean: ["info.b:boolean"], id: ["owner"], author: [] },
};
const REFS: { [table: string]: string[] } = { track: ["album", "meta.ref:id"], album: ["owner"] };

const pick = <T>(list: readonly T[]): T => list[r.int(0, list.length - 1)];
const WORDS = ["a", "quick", "Brown", "fox", "ünïcödé", "日本語", "😀", "", " ", "x".repeat(130)];

function number(): V {
  const choices = [0, -0, 1, -1, 0.5, 3.75, 1e300, -1e-300, 2 ** 53, Number.MAX_VALUE, Number.MIN_VALUE, Infinity, -Infinity, NaN];
  const v = r.int(1, 3) === 1 ? pick(choices) : (r.int(0, 1e9) - 5e8) / pick([1, 7, 1000]);
  const w = codec.writer(8);
  codec.putF64(w, v);
  return { n: codec.hex(codec.written(w)) };
}
function id(): string {
  let s = "";
  for (let i = 0; i < 16; i++) s += String.fromCharCode(r.int(0, 255));
  return codec.hex(s);
}
function text(): V {
  if (r.int(1, 6) === 1) return { b: codec.hex(codec.bytesOf(String.fromCharCode(r.int(0, 255), r.int(0, 255), 0))) };
  return { s: pick(WORDS) };
}
function valueFor(kind: Kind): V {
  if (kind === "number") return number();
  if (kind === "boolean") return r.int(0, 1) === 1;
  if (kind === "id") return { id: id() };
  return text();
}

function column(table: string, kinds: readonly Kind[] = ["text", "number", "boolean", "id", "author"]): [string, Kind] {
  for (;;) {
    const kind = pick(kinds);
    const names = COLUMNS[table][kind];
    if (names.length > 0) return [pick(names), kind];
  }
}

function condition(table: string, depth: number): C {
  const op = r.int(1, depth > 3 ? 13 : 17);
  if (op <= 2) {
    const [c, kind] = column(table);
    return [pick(["is", "exactly"] as const), c, valueFor(kind)];
  } else if (op === 3) {
    const [c, kind] = column(table, ["number", "text", "id"]);
    return [pick(["over", "under"] as const), c, valueFor(kind)];
  } else if (op === 4) {
    const [c, kind] = column(table, ["number", "text", "id"]);
    const none: V = { nil: 1 };
    const lo = r.int(1, 4) === 1 ? none : valueFor(kind);
    const hi = lo !== none && r.int(1, 4) === 1 ? none : valueFor(kind);
    return ["between", c, lo, hi];
  } else if (op === 5) {
    const [c, kind] = column(table);
    return ["among", c, Array.from({ length: r.int(0, 4) }, () => valueFor(kind))];
  } else if (op === 6) {
    const [c] = column(table, ["text", "author"]);
    return [pick(["begins", "contains"] as const), c, text()];
  } else if (op === 7) {
    return ["has", column(table)[0]];
  } else if (op === 8) {
    const how: { -readonly [k in keyof Match]: Match[k] } = {};
    if (r.int(0, 1)) how.any = r.int(0, 1) === 1;
    if (r.int(0, 1)) how.phrase = r.int(0, 1) === 1;
    if (r.int(0, 1)) how.prefix = r.int(0, 1) === 1;
    if (r.int(0, 1)) how.inside = r.int(0, 1) === 1;
    if (r.int(0, 1)) how.typos = pick([0, 1, 2, 3] as const);
    return ["matches", column(table, ["text"])[0], Array.from({ length: r.int(1, 3) }, () => pick(WORDS)).join(" "), how];
  } else if (op === 9) {
    return ["list", pick(["tracks", "favourites", "ünï", ""])];
  } else if (op === 10) {
    return ["ids", Array.from({ length: r.int(0, 3) }, id)];
  } else if (op === 11) {
    return ["none", condition(table, depth + 1)];
  } else if (op <= 13) {
    const of: C[] = Array.from({ length: r.int(0, 3) }, () => condition(table, depth + 1));
    return [pick(["all", "any"] as const), ...of];
  } else if (op <= 15) {
    // Refers to an album, or to whatever else a column of ids points to.
    const other = table === "track" ? "album" : "track";
    return ["refers", pick(REFS[table]), r.int(1, 2 ** 32 - 2), condition(other, depth + 1), other];
  } else {
    const other = table === "track" ? "album" : "track";
    const least: V = r.int(0, 1) ? { nil: 1 } : r.int(0, 5);
    const most: V = r.int(0, 2) === 0 ? { nil: 1 } : r.int(0, 1) ? r.int(5, 1e6) : 2 ** 60;
    return ["referred", r.int(1, 2 ** 32 - 2), pick(REFS[other]), condition(other, depth + 1), least, most, other];
  }
}

const ORDERS = ["best", "newest", "oldest", "@list:tracks", "-@list:ünï"];
const TOTAL_NAMES = ["a", "b", "z", "A", "ä", "￯", "😀", "count", "sum of stars", "日本"];

function question(): Q {
  const table = pick(["track", "album"]);
  const q: Q = { scope: r.int(1, 2 ** 32 - 2), table };
  if (r.int(1, 8) > 1) q.where = condition(table, 0);
  if (r.int(0, 1)) {
    q.order = Array.from({ length: r.int(0, 8) }, () => {
      if (r.int(0, 2) === 0) return pick(ORDERS);
      const c = column(table)[0];
      return r.int(0, 1) ? "-" + c : c;
    });
  }
  if (r.int(0, 1)) q.offset = r.int(0, 3) === 0 ? r.int(0, 2 ** 40) : r.int(0, 300);
  if (r.int(0, 1)) q.limit = r.int(0, 2000);
  if (r.int(0, 1)) q.fromEnd = r.int(0, 1) === 1;
  if (r.int(0, 1)) {
    q.totals = {};
    for (let n = r.int(0, 6); n > 0; n--) {
      const fn = pick(["sum", "min", "max", "count", "facet"] as const);
      const [c] = fn === "sum" ? column(table, ["number"]) : column(table);
      q.totals[pick(TOTAL_NAMES)] = r.int(0, 1) ? [fn, c, r.int(0, 1500)] : [fn, c];
    }
  }
  return q;
}

// What neither can write.
const FAULTY: Q[] = [
  { scope: 1, table: "track", where: ["is", "nothing", { s: "x" }] },
  { scope: 1, table: "track", where: ["is", "meta.size:float", { s: "x" }] },
  { scope: 1, table: "track", where: ["is", "nothing.at.all", { s: "x" }] },
  { scope: 1, table: "track", totals: { x: ["median" as "sum", "stars"] } },
  { scope: 1, table: "track", order: ["-nothing"] },
  { scope: 1, table: "track", where: ["is", "stars", { s: "five" }] },
  { scope: 1, table: "track", where: ["is", "name", 5] },
];

// ---------------------------------------------------------------- in TypeScript

function tsValue(v: V): Value | undefined {
  if (typeof v === "boolean" || typeof v === "number") return v;
  if ("n" in v) return codec.f64(codec.reader(codec.unhex(v.n)));
  if ("s" in v) return v.s;
  if ("id" in v) return v.id;
  if ("b" in v) return codec.unhex(v.b);
  return undefined;
}

function tsWhere(c: C): Where {
  switch (c[0]) {
    case "all":
    case "any":
      return where[c[0]](...(c.slice(1) as C[]).map(tsWhere));
    case "none":
      return where.none(tsWhere(c[1]));
    case "is":
    case "exactly":
    case "over":
    case "under":
      return where[c[0]](c[1], tsValue(c[2])!);
    case "between":
      return where.between(c[1], tsValue(c[2]), tsValue(c[3]));
    case "among":
      return where.among(c[1], c[2].map((v) => tsValue(v)!));
    case "begins":
    case "contains":
      return where[c[0]](c[1], tsValue(c[2]) as string | Uint8Array);
    case "has":
      return where.has(c[1]);
    case "matches":
      return where.matches(c[1], c[2], c[3]);
    case "list":
      return where.inList(c[1]);
    case "ids":
      return where.ids(c[1]);
    case "refers":
      return where.refers(c[1], c[2], tsWhere(c[3]), tables[c[4]]);
    case "referred":
      return where.referred(c[1], c[2], tsWhere(c[3]), tsValue(c[4]) as number | undefined, tsValue(c[5]) as number | undefined, tables[c[6]]);
  }
}

const KEY = codec.bytesOf("k".repeat(32));
const utf8 = new TextEncoder();
function tag(scope: number, name: string): string {
  const n = utf8.encode(name);
  const both = new Uint8Array(32 + n.length);
  both.set(KEY);
  both.set(n, 32);
  return codec.u32Binary(scope) + codec.binary(sha256(both), 0, 12);
}

function tsWrite(q: Q): string {
  try {
    const question: Question = {
      scope: q.scope,
      table: tables[q.table],
      where: q.where ? tsWhere(q.where) : undefined,
      order: q.order,
      offset: q.offset,
      limit: q.limit,
      fromEnd: q.fromEnd,
      totals: q.totals,
    };
    const [body, told] = write(question, tag);
    return `${codec.hex(body)} ${told.map((t) => codec.hex(utf8.encode(t.name)) + (t.facet ? "*" : "")).join(",")}`;
  } catch (e) {
    if (process.env.VERBOSE) console.error(e);
    return "!";
  }
}

// ---------------------------------------------------------------- side by side

const questions = [...FAULTY, ...Array.from({ length: COUNT }, question)];
const began = performance.now();
const ours = questions.map(tsWrite);
const wrote = performance.now();
const input = JSON.stringify({ tables, questions });
const theirs = execFileSync("lune", ["run", join(here, "ask.luau")], { input, maxBuffer: 1 << 30 }).toString().replace(/\n$/, "").split("\n");
assert.equal(theirs.length, questions.length);
let faulty = 0;
for (const [i, line] of ours.entries()) {
  if (line !== theirs[i]) assert.fail(`question ${i + 1}: ${JSON.stringify(questions[i])}\n  ask.ts   ${line}\n  ask.luau ${theirs[i]}`);
  if (line === "!") faulty++;
}
for (let i = 0; i < FAULTY.length; i++) assert.equal(ours[i], "!", `faulty question ${i + 1}`);

// What totals are read as.
{
  const [, told] = write(
    {
      scope: 1,
      table: tables.track,
      totals: { n: ["min", "stars"], b: ["facet", "liked"], i: ["max", "album"], s: ["facet", "name"], t: ["max", "@created"], w: ["facet", "who"] },
    },
    tag,
  );
  const by = Object.fromEntries(told.map((t) => [t.name, t.read]));
  const f = codec.writer(8);
  codec.putF64(f, -2.5);
  assert.equal(by.n(codec.written(f)), -2.5);
  assert.equal(by.t(codec.written(f)), -2.5);
  assert.equal(by.b(Uint8Array.of(1)), true);
  assert.equal(by.b(Uint8Array.of(0)), false);
  assert.equal(by.i(codec.unhex("00112233445566778899aabbccddeeff")), "00112233445566778899aabbccddeeff");
  assert.equal(by.s(utf8.encode("﻿ünï")), "﻿ünï");
  assert.equal(by.w(utf8.encode("ann")), "ann");
}

console.log(`${questions.length} questions, ${faulty} faulty, alike: ask.ts ${(wrote - began).toFixed(0)} ms`);
console.log("ok");
