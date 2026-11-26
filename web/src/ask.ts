// Questions, as values to be composed, and as the bytes a node reads: SPEC.md 15.
//
// A value is a number, a boolean, a string or bytes. A string is written as UTF-8, but for a column of row ids, where it
// is a row's id in hex, written as its 16 bytes; bytes are written as they are.

import * as codec from "./codec.ts";

const BYTES = 1, FOLD = 2, NUMBER = 3, BOOL = 4, ID = 5, WORDS = 6, CREATED = 7, MODIFIED = 8, ORDER = 9, AUTHOR = 10;
const SUM = 1, MIN = 2, MAX = 3, COUNT = 4, FACET = 5;

export type Is = "string" | "text" | "number" | "boolean" | "id" | "author";
export type Columns = { readonly [name: string]: { readonly slot: number; readonly is: Is } };

export type Value = number | boolean | string | Uint8Array;

export type Match = {
  readonly any?: boolean; // one of the words will do
  readonly phrase?: boolean; // in a row
  readonly prefix?: boolean; // the last may be only begun
  readonly inside?: boolean; // they may be parts of words
  readonly typos?: 0 | 1 | 2 | 3; // letters that may be wrong in each
};

// A condition: made by the functions of `where`, and put together with all, any and none.
export type Where =
  | { readonly op: "all" | "any"; readonly of: readonly Where[] }
  | { readonly op: "none"; readonly where: Where }
  | { readonly op: "is" | "exactly" | "over" | "under"; readonly column: string; readonly value: Value }
  | { readonly op: "between"; readonly column: string; readonly lo: Value | undefined; readonly hi: Value | undefined }
  | { readonly op: "among"; readonly column: string; readonly values: readonly Value[] }
  | { readonly op: "begins" | "contains"; readonly column: string; readonly text: string | Uint8Array }
  | { readonly op: "has"; readonly column: string }
  | { readonly op: "matches"; readonly column: string; readonly text: string; readonly how: Match }
  | { readonly op: "list"; readonly name: string }
  | { readonly op: "ids"; readonly ids: readonly string[] }
  | { readonly op: "refers"; readonly column: string; readonly scope: number; readonly to: Where; readonly columns: Columns | undefined }
  | {
      readonly op: "referred";
      readonly column: string;
      readonly scope: number;
      readonly by: Where;
      readonly least: number;
      readonly most: number;
      readonly columns: Columns | undefined;
    };

export type TotalFunction = "sum" | "min" | "max" | "count" | "facet";
// ["sum", column], or min, max, count; or ["facet", column, how many: 100].
export type Total = readonly [fn: TotalFunction, column: string, top?: number];

export type Question = {
  readonly scope: number;
  readonly table: Columns;
  readonly where?: Where;
  // "best", "newest", "oldest", a column, "@list:" and a list's name, or one after a minus for the greatest first: in
  // order of weight.
  readonly order?: readonly string[];
  readonly offset?: number;
  readonly limit?: number; // 50
  readonly fromEnd?: boolean; // offset and limit count back from the end
  readonly totals?: { readonly [name: string]: Total };
};

// What a total is, in the order they will be answered in, and how to read its values.
export type Told = { readonly name: string; readonly facet: boolean; readonly read: (value: Uint8Array) => number | boolean | string };

// A list's tag in a scope, 16 bytes as a binary string.
export type Tag = (scope: number, list: string) => string;

// ---------------------------------------------------------------- conditions

function all(...of: Where[]): Where {
  return Object.freeze({ op: "all", of: Object.freeze(of) });
}
function any(...of: Where[]): Where {
  return Object.freeze({ op: "any", of: Object.freeze(of) });
}
function none(where: Where): Where {
  return Object.freeze({ op: "none", where });
}
// A value that is this, whatever the case of text; and one of these.
function is(column: string, value: Value): Where {
  return Object.freeze({ op: "is", column, value });
}
function among(column: string, values: readonly Value[]): Where {
  return Object.freeze({ op: "among", column, values: Object.freeze([...values]) });
}
// Byte for byte.
function exactly(column: string, value: Value): Where {
  return Object.freeze({ op: "exactly", column, value });
}
// From one to the other, both included. Either may be undefined.
function between(column: string, lo: Value | undefined, hi: Value | undefined): Where {
  return Object.freeze({ op: "between", column, lo, hi });
}
function over(column: string, than: Value): Where {
  return Object.freeze({ op: "over", column, value: than });
}
function under(column: string, than: Value): Where {
  return Object.freeze({ op: "under", column, value: than });
}
function begins(column: string, with_: string | Uint8Array): Where {
  return Object.freeze({ op: "begins", column, text: with_ });
}
function contains(column: string, what: string | Uint8Array): Where {
  return Object.freeze({ op: "contains", column, text: what });
}
function has(column: string): Where {
  return Object.freeze({ op: "has", column });
}
function matches(column: string, text: string, how: Match = {}): Where {
  return Object.freeze({ op: "matches", column, text, how: Object.freeze({ ...how }) });
}
function inList(name: string): Where {
  return Object.freeze({ op: "list", name });
}
// Rows by id, in hex.
function ids(of: readonly string[]): Where {
  return Object.freeze({ op: "ids", ids: Object.freeze([...of]) });
}
// That refers to a row of a scope that …, by a column of row ids; and that is referred to by so many that ….
function refers(column: string, scope: number, to: Where, columns?: Columns): Where {
  return Object.freeze({ op: "refers", column, scope, to, columns });
}
function referred(scope: number, column: string, by: Where, least = 1, most = Infinity, columns?: Columns): Where {
  return Object.freeze({ op: "referred", column, scope, by, least, most, columns });
}

export const where = Object.freeze({ all, any, none, is, among, exactly, between, over, under, begins, contains, has, matches, inList, ids, refers, referred });

// ---------------------------------------------------------------- as bytes

type Writing = { w: codec.Writer; columns: Columns; tag: (list: string) => string; scopeTag: Tag };

const KINDS: { readonly [is: string]: number } = { string: FOLD, text: FOLD, number: NUMBER, boolean: BOOL, id: ID, row: ID };

// A column, by its name in the table, "@created" and "@modified", or name.path into JSON, with what is wanted of it after
// a colon, as in meta.size:number, where no value says: its slot, path, and what it is.
type Found = { slot: number; path: string; is: string | undefined };

function find(x: Writing, name: string): Found {
  if (name === "@created") return { slot: -1, path: "", is: "created" };
  if (name === "@modified") return { slot: -1, path: "", is: "modified" };
  let c = Object.hasOwn(x.columns, name) ? x.columns[name] : undefined;
  if (c !== undefined) return { slot: c.slot, path: "", is: c.is };
  const dot = name.indexOf(".");
  const head = dot >= 0 ? name.slice(0, dot) : name;
  c = Object.hasOwn(x.columns, head) ? x.columns[head] : undefined;
  if (c === undefined || dot < 0) throw new Error(`no column ${name}`);
  let path = name.slice(dot + 1);
  let is: string | undefined;
  const colon = path.indexOf(":");
  if (colon >= 0) {
    is = path.slice(colon + 1);
    path = path.slice(0, colon);
    if (!Object.hasOwn(KINDS, is)) throw new Error(`no kind ${is}`);
  }
  return { slot: c.slot, path, is };
}

function kindOf(is: string | undefined, value: Value | undefined): number {
  if (is !== undefined && Object.hasOwn(KINDS, is)) return KINDS[is];
  return typeof value === "number" ? NUMBER : typeof value === "boolean" ? BOOL : FOLD;
}

// A column as written, read as a kind of value: which, and whether its values are row ids.
type Written = { kind: number; ids: boolean };

function column(x: Writing, name: string, value: Value | undefined, want?: number): Written {
  const { slot, path, is } = find(x, name);
  if (is === "created" || is === "modified") {
    const kind = is === "created" ? CREATED : MODIFIED;
    codec.putU8(x.w, kind);
    return { kind, ids: false };
  } else if (is === "author") {
    codec.putU8(x.w, AUTHOR);
    codec.putU8(x.w, slot);
    return { kind: AUTHOR, ids: false };
  }
  const kind = want ?? kindOf(is, value);
  codec.putU8(x.w, kind);
  codec.putU8(x.w, slot);
  codec.putUtf8(x.w, path);
  return { kind, ids: is === "id" || is === "row" };
}

// A row's id, 32 hex digits, as its 16 bytes.
function rowId(id: string): string {
  if (!/^[0-9a-f]{32}$/.test(id)) throw new Error(`${id} is no row id`);
  return codec.binaryFromHex(id);
}

function putText(x: Writing, value: Value, ids: boolean): void {
  if (value instanceof Uint8Array) codec.putBytes(x.w, value);
  else if (typeof value !== "string") throw new TypeError(`${value} is not text`);
  else if (ids) {
    codec.putVarint(x.w, 16);
    codec.putBinary(x.w, rowId(value));
  } else codec.putUtf8(x.w, value);
}

function putValue(x: Writing, c: Written, value: Value): void {
  const kind = c.kind;
  if (kind === NUMBER || kind === CREATED || kind === MODIFIED) {
    if (typeof value !== "number") throw new TypeError(`${String(value)} is not a number`);
    codec.putVarint(x.w, 8);
    codec.putF64(x.w, value);
  } else if (kind === BOOL) {
    codec.putVarint(x.w, 1);
    codec.putU8(x.w, value === false ? 0 : 1); // as Luau has it: anything but false is true
  } else {
    putText(x, value, c.ids);
  }
}

function putRange(x: Writing, name: string, lo: Value | undefined, hi: Value | undefined, loIn: boolean, hiIn: boolean, want?: number): void {
  codec.putU8(x.w, 4);
  const c = column(x, name, lo !== undefined ? lo : hi, want);
  codec.putU8(x.w, (lo !== undefined ? 1 : 0) + (hi !== undefined ? 2 : 0) + (loIn ? 4 : 0) + (hiIn ? 8 : 0));
  if (lo !== undefined) putValue(x, c, lo);
  if (hi !== undefined) putValue(x, c, hi);
}

function putMany(x: Writing, op: number, of: readonly Where[]): void {
  codec.putU8(x.w, op);
  codec.putVarint(x.w, of.length);
  for (const c of of) putWhere(x, c);
}

const MOST = codec.unhex("ffffffffffffffffff01"); // 2^64 − 1: no most at all

function putWhere(x: Writing, c: Where): void {
  const w = x.w;
  switch (c.op) {
    case "all":
      if (c.of.length === 0) codec.putU8(w, 0);
      else putMany(x, 1, c.of);
      break;
    case "any":
      putMany(x, 2, c.of);
      break;
    case "none":
      codec.putU8(w, 3);
      putWhere(x, c.where);
      break;
    case "is":
      putRange(x, c.column, c.value, c.value, true, true);
      break;
    case "exactly":
      putRange(x, c.column, c.value, c.value, true, true, typeof c.value === "string" || c.value instanceof Uint8Array ? BYTES : undefined);
      break;
    case "between":
      putRange(x, c.column, c.lo, c.hi, true, true);
      break;
    case "over":
      putRange(x, c.column, c.value, undefined, false, true);
      break;
    case "under":
      putRange(x, c.column, undefined, c.value, true, false);
      break;
    case "among": {
      codec.putU8(w, 5);
      const col = column(x, c.column, c.values[0]);
      codec.putVarint(w, c.values.length);
      for (const v of c.values) putValue(x, col, v);
      break;
    }
    case "begins":
    case "contains": {
      codec.putU8(w, c.op === "begins" ? 6 : 7);
      const col = column(x, c.column, c.text, FOLD);
      putText(x, c.text, col.ids);
      break;
    }
    case "has":
      codec.putU8(w, 8);
      column(x, c.column, undefined);
      break;
    case "list":
      codec.putU8(w, 9);
      codec.putBinary(w, x.tag(c.name));
      break;
    case "matches": {
      const how = c.how;
      codec.putU8(w, 10);
      column(x, c.column, c.text, WORDS);
      codec.putU8(w, how.phrase ? 2 : how.any ? 1 : 0);
      codec.putU8(w, (how.prefix ? 1 : 0) + (how.inside ? 2 : 0) + Math.min(Math.max(Math.trunc(how.typos ?? 0), 0), 3) * 4);
      codec.putUtf8(w, c.text);
      break;
    }
    case "ids":
      codec.putU8(w, 11);
      codec.putVarint(w, c.ids.length);
      for (const id of c.ids) codec.putBinary(w, rowId(id));
      break;
    case "refers":
    case "referred": {
      const scope = c.scope;
      const inner: Writing = { w, columns: c.columns ?? x.columns, scopeTag: x.scopeTag, tag: (name) => x.scopeTag(scope, name) };
      codec.putU8(w, c.op === "refers" ? 12 : 13);
      column(c.op === "refers" ? x : inner, c.column, undefined, ID);
      codec.putVarint(w, scope);
      if (c.op === "referred") {
        codec.putVarint(w, c.least);
        if (c.most >= 2 ** 53) codec.put(w, MOST);
        else codec.putVarint(w, c.most);
        putWhere(inner, c.by);
      } else {
        putWhere(inner, c.to);
      }
      break;
    }
    default:
      throw new Error(`${(c as { op: unknown }).op} is no condition`);
  }
}

const decoder = new TextDecoder("utf-8", { ignoreBOM: true });

function readText(v: Uint8Array): string {
  return decoder.decode(v);
}
function readNumber(v: Uint8Array): number {
  return codec.f64(codec.reader(v));
}
function readBool(v: Uint8Array): boolean {
  return v.length === 1 && v[0] === 1;
}
function readId(v: Uint8Array): string {
  return codec.hex(v);
}

const READ: { readonly [kind: number]: (v: Uint8Array) => number | boolean | string } = {
  [NUMBER]: readNumber,
  [CREATED]: readNumber,
  [MODIFIED]: readNumber,
  [BOOL]: readBool,
  [ID]: readId,
};

const FN: { readonly [fn: string]: number } = { sum: SUM, min: MIN, max: MAX, count: COUNT, facet: FACET };

// Strings in order of their UTF-8, which is that of their code points, as Luau sorts them.
function utf8Less(a: string, b: string): number {
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    const x = a.codePointAt(i)!;
    const y = b.codePointAt(i)!;
    if (x !== y) return x < y ? -1 : 1;
    if (x > 0xffff) i++;
  }
  return a.length - b.length;
}

// The question, and its totals in the order they will be answered in.
export function write(q: Question, scopeTag: Tag): [question: Uint8Array<ArrayBuffer>, totals: Told[]] {
  const w = codec.writer();
  const x: Writing = { w, columns: q.table, scopeTag, tag: (name) => scopeTag(q.scope, name) };
  codec.putVarint(w, q.scope);
  putWhere(x, q.where ?? all());
  const order = q.order ?? ["newest"];
  codec.putVarint(w, order.length);
  for (const name of order) {
    const desc = name.startsWith("-");
    if (name === "best") {
      codec.putU8(w, 1);
      codec.putU8(w, 0);
    } else if (name === "newest" || name === "oldest") {
      codec.putU8(w, 2);
      codec.putU8(w, name === "newest" ? 1 : 0);
    } else if (name.startsWith("@list:") || name.startsWith("-@list:")) {
      codec.putU8(w, 0);
      codec.putU8(w, desc ? 1 : 0);
      codec.putU8(w, ORDER);
      codec.putBinary(w, x.tag(name.slice(desc ? 7 : 6)));
    } else {
      codec.putU8(w, 0);
      codec.putU8(w, desc ? 1 : 0);
      column(x, desc ? name.slice(1) : name, undefined);
    }
  }
  codec.putU8(w, q.fromEnd ? 1 : 0);
  codec.putVarint(w, q.offset ?? 0);
  codec.putVarint(w, q.limit ?? 50);
  const totals = q.totals ?? {};
  const names = Object.keys(totals).sort(utf8Less);
  codec.putVarint(w, names.length);
  const told: Told[] = [];
  for (const name of names) {
    const t = totals[name];
    const fn = Object.hasOwn(FN, t[0]) ? FN[t[0]] : undefined;
    if (fn === undefined) throw new Error("no such total");
    codec.putU8(w, fn);
    const { kind } = column(x, t[1], undefined, t[0] === "sum" ? NUMBER : undefined);
    told.push(Object.freeze({ name, facet: t[0] === "facet", read: READ[kind] ?? readText }));
    codec.putVarint(w, t[2] ?? (t[0] === "facet" ? 100 : 0));
  }
  return [codec.written(w), told];
}
