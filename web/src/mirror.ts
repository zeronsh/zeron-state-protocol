// Structured state as plain objects: maps, lists, records and trees, nested as deep as wanted, and texts in them. What
// an application sets is compared with what there was, and only what differs is written; what others write comes back
// as new objects where something changed and the very same ones where nothing did. See docs/mirror.md.
//
// Nothing here is new to the protocol. A document is the rows of one list. Each row says, in a column of its own,
// what it is in. A list keeps its order, and a tree each node's children's, as a text of markers in a column of the
// row that holds them, so that order merges as text does: whoever inserts where, nothing interleaves and nothing runs
// out of room. A list of values is a text of the values themselves.
//
// A port of luau/zsp/mirror.luau, which says the same in the same order; what one does, the other does, and each reads
// what the other writes. Row ids are hex where an application sees them, and binary strings within, as the client's are.

import { where, type Total, type Where as Condition } from "./ask.ts";
import * as codec from "./codec.ts";
import { sha256 } from "./sha256.ts";
import * as text from "./text.ts";
import type { Answer, Asking, AuthorsColumn, Cell, Change, Client, Column, Stored, Table, TextColumn } from "./client.ts";

const WHERE = 255; // the slot that says what a row is in
const W = "\0where";
const ZERO = "\0".repeat(16);
const MAP = 0, ITEM = 1, ENTRY = 2, NODE = 3;
const MARK = "\0"; // a marker in a list's order
const NOWHERE = "\0".repeat(12); // no marker
const VALUE = 3;
const EMPTY = new Uint8Array(0);
const NONE: readonly never[] = Object.freeze([]); // to read from, never to show
const NOBODY: readonly string[] = Object.freeze([]); // who has written in a row that is not there
const utf8 = new TextEncoder();
const strict = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

const same = (v: Uint8Array): Uint8Array => v;

const WHERE_COLUMN: Column<Uint8Array> = Object.freeze({ slot: WHERE, text: false, is: "string", encode: same, decode: same });
const WINDOW: Table = Object.freeze({ [W]: WHERE_COLUMN }); // one shape, so that all who open a document share its window

// For tests: every shortcut off, so that what is read and written is read and written the long way, to be held to the
// same as the short.
let plain = false;
export function _plain(on: boolean): void {
  plain = on;
}

// ---------------------------------------------------------------- schemas

/** Named columns, and whatever is nested under other names. */
export interface MapSchema<F extends Fields = Fields> {
  readonly kind: "map";
  readonly fields: F;
  /** Its fields' names, in order, */
  readonly names: readonly string[];
  /** and each as it is written down, in UTF-8, as a binary string; */
  readonly keys: readonly string[];
  /** where each name is among them; */
  readonly at: ReadonlyMap<string, number>;
  /** and by place in names, each column, or list, record, map or tree. */
  readonly columns: readonly (Column<any> | undefined)[];
  readonly boxes: readonly (Schema | undefined)[];
  readonly slots: ReadonlySet<number>;
  /** Its columns as they are written: by name, and by "\x01" and name as bytes, to write nothing in. */
  readonly writing: Table;
}

/** Maps or values in an order, which may be moved about; its order is kept in `slot` of the row that holds it. */
export interface ListSchema<O extends Of = Of> {
  readonly kind: "list";
  readonly slot: number;
  readonly of: O;
}

/** Maps or values by keys that are not known beforehand. */
export interface RecordSchema<O extends Of = Of> {
  readonly kind: "record";
  readonly of: O;
}

/** Maps, each with its children; any may be moved under any other. */
export interface TreeSchema<N extends MapSchema<any> = MapSchema> {
  readonly kind: "tree";
  readonly slot: number;
  readonly of: N;
}

export type Schema = MapSchema<any> | ListSchema<any> | RecordSchema<any> | TreeSchema<any>;
/** What a list or a record is of. */
export type Of = Column<any> | MapSchema<any>;
export type Fields = { readonly [name: string]: Column<any> | Schema };

function isSchema(f: Column<any> | Schema): f is Schema {
  return typeof (f as Schema).kind === "string";
}

function isMap(of: Of): of is MapSchema<any> {
  return (of as MapSchema).kind === "map";
}

// A column that writes what it is given as it is: an empty value is no value.
const raws = new Map<number, Column<Uint8Array>>();
function raw(slot: number): Column<Uint8Array> {
  let c = raws.get(slot);
  if (!c) raws.set(slot, (c = Object.freeze({ slot, text: false, is: "string", encode: same, decode: same })));
  return c;
}

/**
 * Named columns, and whatever is nested under other names. Each column has a slot of its own, from 16 to 254, as has
 * each list and tree, which keeps its order there; but one that says whose what is in a slot is (columns.author and
 * columns.authors), which names another's.
 */
export function map<F extends Fields>(fields: F): MapSchema<F> {
  const slots = new Set<number>();
  const claim = (slot: number, name: string) => {
    if (!Number.isInteger(slot) || slot < 16 || slot >= WHERE) throw new RangeError(`${name}: a mirror's slots are 16 to 254`);
    if (slots.has(slot)) throw new Error(`${name}: slot ${slot} is taken`);
    slots.add(slot);
  };
  const names = Object.keys(fields).sort();
  const writing: Record<string, Column<any>> = { [W]: WHERE_COLUMN };
  const columns: (Column<any> | undefined)[] = [];
  const boxes: (Schema | undefined)[] = [];
  for (const name of names) {
    // Plain objects are what documents are, so a field may be named nothing that every object already has.
    if (name === "id" || name === "children" || name in Object.prototype) throw new Error(`${name} is not a name for a field`);
    const f = fields[name];
    if (isSchema(f)) {
      if (f.kind === "list" || f.kind === "tree") claim(f.slot, name);
      boxes.push(f);
      columns.push(undefined);
    } else {
      if (typeof f?.encode !== "function") throw new Error(`${name} is neither a column nor a schema`);
      // Whose what is in a slot is says so of another's slot: it has none of its own.
      if (!f.who) claim(f.slot, name);
      columns.push(f);
      boxes.push(undefined);
      if (!f.who) {
        writing[name] = f;
        writing["\x01" + name] = raw(f.slot);
      }
    }
  }
  return Object.freeze({
    kind: "map",
    fields,
    names: Object.freeze(names),
    keys: Object.freeze(names.map((name) => codec.binary(utf8.encode(name)))),
    at: new Map(names.map((name, i) => [name, i])),
    columns: Object.freeze(columns),
    boxes: Object.freeze(boxes),
    slots,
    writing: Object.freeze(writing),
  });
}

/**
 * Maps or values in an order, which may be moved about; its order is kept in `slot` of the row that holds it. Maps in
 * it have their ids, by which they are known when it is set again; values are kept in that slot themselves.
 */
export function list<O extends Of>(slot: number, of: O): ListSchema<O> {
  if (typeof slot !== "number") throw new Error("a list says which slot keeps its order");
  if (!(isMap(of) || (!isSchema(of) && typeof of?.encode === "function"))) throw new Error("a list is of maps or of values");
  return Object.freeze({ kind: "list", slot, of });
}

/** Maps or values by keys that are not known beforehand. */
export function record<O extends Of>(of: O): RecordSchema<O> {
  if (!(isMap(of) || (!isSchema(of) && typeof of?.encode === "function"))) throw new Error("a record is of maps or of values");
  return Object.freeze({ kind: "record", of });
}

/**
 * Maps, each with its children, in order, kept in `slot` of the row of each node, and of the row that holds the tree;
 * any node may be moved under any other.
 */
export function tree<N extends MapSchema<any>>(slot: number, node: N): TreeSchema<N> {
  if (typeof slot !== "number" || node?.kind !== "map") throw new Error("a tree says which slot keeps its order, and is of maps");
  if (node.slots.has(slot)) throw new Error("a tree's nodes keep their children's order in that slot");
  return Object.freeze({ kind: "tree", slot, of: node });
}

// ---------------------------------------------------------------- what documents are, to TypeScript

type ValueOf<C> = C extends TextColumn ? string : C extends AuthorsColumn ? readonly string[] : C extends Column<infer V> ? V : never;
// Fields that are always there: what holds anything, texts, and who has written.
type Always<F> = { [K in keyof F]: F[K] extends Schema | TextColumn | AuthorsColumn ? K : never }[keyof F];
type Boxes<F> = { [K in keyof F]: F[K] extends Schema ? K : never }[keyof F];
type Flat<T> = { [K in keyof T]: T[K] } & {};

/** A document, or what is in one, as it is read: frozen, and the very same objects wherever nothing changed. */
export type Doc<S> =
  S extends MapSchema<infer F>
    ? MapDoc<F>
    : S extends ListSchema<infer O>
      ? readonly ItemDoc<O>[]
      : S extends RecordSchema<infer O>
        ? Readonly<Record<string, ItemDoc<O>>>
        : S extends TreeSchema<infer N>
          ? readonly NodeDoc<N>[]
          : never;
type ItemDoc<O> = O extends MapSchema<any> ? Doc<O> : ValueOf<O>;
type FieldDoc<X> = X extends Schema ? Doc<X> : ValueOf<X>;
type MapDoc<F> = Flat<
  { readonly id: string } & { readonly [K in Always<F>]: FieldDoc<F[K]> } & { readonly [K in Exclude<keyof F, Always<F>>]?: FieldDoc<F[K]> }
>;
type NodeDoc<N> = N extends MapSchema<infer F> ? Flat<MapDoc<F> & { readonly children: readonly NodeDoc<N>[] }> : never;

/** A document, or what is in one, as it may be set: a map without an id is a new one, as is one whose id is not known. */
export type Input<S> =
  S extends MapSchema<infer F>
    ? MapInput<F>
    : S extends ListSchema<infer O>
      ? readonly ItemInput<O>[]
      : S extends RecordSchema<infer O>
        ? { readonly [key: string]: ItemInput<O> | undefined }
        : S extends TreeSchema<infer N>
          ? readonly NodeInput<N>[]
          : never;
type ItemInput<O> = O extends MapSchema<any> ? Input<O> : ValueOf<O>;
type MapInput<F> = Flat<{ readonly id?: string } & { readonly [K in keyof F]?: F[K] extends Schema ? Input<F[K]> : ValueOf<F[K]> }>;
type NodeInput<N> = N extends MapSchema<infer F> ? Flat<MapInput<F> & { readonly children?: readonly NodeInput<N>[] }> : never;

/** A document, or what is in one, as `update` hands it out: to be changed as plain objects and arrays are. */
export type Draft<S> =
  S extends MapSchema<infer F>
    ? MapDraft<F>
    : S extends ListSchema<infer O>
      ? ItemDraft<O>[]
      : S extends RecordSchema<infer O>
        ? { [key: string]: ItemDraft<O> }
        : S extends TreeSchema<infer N>
          ? NodeDraft<N>[]
          : never;
type ItemDraft<O> = O extends MapSchema<any> ? Draft<O> : ValueOf<O>;
type MapDraft<F> = Flat<{ readonly id?: string } & { [K in Boxes<F>]: Draft<F[K]> } & { [K in Exclude<keyof F, Boxes<F>>]?: ValueOf<F[K]> }>;
type NodeDraft<N> = N extends MapSchema<infer F> ? Flat<MapDraft<F> & { children: NodeDraft<N>[] }> : never;

/** An open document. */
export interface Mirror<S extends MapSchema<any>> {
  /** As it is now. */
  readonly state: Doc<S>;
  readonly status: "loading" | "ready";
  /** Writes a whole new state: what differs from this one. Resolves when that is durable on this device. */
  set(state: Input<S>): Promise<void>;
  /** Hands f a draft of the state, which it changes as it likes, and writes that. */
  update(f: (draft: Draft<S>) => void): Promise<void>;
  close(): void;
}

// What a document holds, whatever its schema says it is.
type Obj = { readonly [name: string]: any };

// Every object a mirror has made for a state: what is one of these is as it was read, and nothing in it is a draft.
const built = new WeakSet<object>();
function frozen<T extends object>(v: T): T {
  built.add(v);
  return Object.freeze(v);
}

// A value read from a column, unchangeable all the way down, so that what is shown cannot be changed in place and differ
// from what is held; for a change is made by setting, or in a draft, which hands out a copy. Bytes cannot be frozen, and
// each reading of them is a copy of its own.
function settled<T>(v: T): T {
  if (typeof v !== "object" || v === null || ArrayBuffer.isView(v) || Object.isFrozen(v)) return v;
  for (const x of Object.values(v)) settled(x);
  return Object.freeze(v);
}

// Whether a column holds the same with these two as it does: the very same, or what is written of them is.
function sameValue(c: Column<any>, a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true;
  if (typeof a !== "object" || a === null || typeof b !== "object" || b === null) return false;
  try {
    return sameBytes(c.encode(a), c.encode(b));
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------- what a row is in

interface Where {
  owner: string;
  field: string;
  kind: number;
  marker: string; // of an item or a node: its place in the order
  present: boolean; // of an entry
  key: string; // of an entry, as written,
  name: string | undefined; // and as read: none if it is not UTF-8
  parent: string; // of a node: ZERO for the top
  from: string; // of a node: what it was moved from,
  back: string; // and its marker there
  body: string;
  stamp: string;
}

function whereEncode(owner: string, field: string, kind: number, extra = ""): Uint8Array {
  const w = codec.writer(16 + 3 + field.length + 1 + extra.length);
  codec.putBinary(w, owner);
  codec.putVarint(w, field.length);
  codec.putBinary(w, field);
  codec.putU8(w, kind);
  codec.putBinary(w, extra);
  return codec.written(w).slice();
}

function whereDecode(body: Uint8Array, stamp: string): Where | undefined {
  let out: Where, rest: string;
  try {
    const r = codec.reader(body);
    out = {
      owner: codec.takeBinary(r, 16),
      field: codec.binary(codec.bytes(r)),
      kind: codec.u8(r),
      marker: "",
      present: false,
      key: "",
      name: undefined,
      parent: ZERO,
      from: ZERO,
      back: "",
      body: codec.binary(body),
      stamp,
    };
    rest = codec.binary(codec.rest(r));
  } catch (e) {
    if (e instanceof codec.Malformed) return undefined;
    throw e;
  }
  if (out.kind === ITEM && rest.length === 12) {
    out.marker = rest;
  } else if (out.kind === ENTRY && rest.length >= 1) {
    out.present = rest.charCodeAt(0) !== 0;
    out.key = rest.slice(1);
    try {
      out.name = strict.decode(codec.bytesOf(out.key));
    } catch {
      out.name = undefined; // a key that is not text is no key a document can have
    }
  } else if (out.kind === NODE && rest.length === 56) {
    out.parent = rest.slice(0, 16);
    out.marker = rest.slice(16, 28);
    out.from = rest.slice(28, 44);
    out.back = rest.slice(44, 56);
  } else if (out.kind !== MAP || rest !== "") {
    return undefined;
  }
  return out;
}

// A marker's name, and the one so many after it in the same piece.
function nextMarker(id: string, by: number): string {
  return id.slice(0, 8) + codec.u32Binary(codec.u32Of(id, 8) + by);
}

// A value's elements: as one run, which is how anyone who minds writes it; or, as a forger may, scattered, each named.
interface Frame {
  value: unknown;
  first: string;
  count: number;
  last: string;
  scattered: string[] | undefined;
}

// The values of a list from its text, with where each is. What does not read as one is not.
function framesOf(c: Column<any>, t: text.Text | undefined): { values: unknown[]; frames: Frame[]; junk: string[] } {
  const values: unknown[] = [], frames: Frame[] = [], junk: string[] = [];
  if (!t) return { values, frames, junk };
  const bytes = text.content(t);
  const ids = text.ids(t);
  let at = 0;
  while (at < bytes.length) {
    let n = -1, used = 0;
    try {
      const r = codec.reader(bytes.subarray(at, Math.min(at + 10, bytes.length)));
      n = codec.varint(r);
      used = r.pos;
    } catch (e) {
      if (!(e instanceof codec.Malformed)) throw e;
    }
    if (n < 0 || at + used + n > bytes.length) {
      for (let k = at; k < bytes.length; k++) junk.push(ids[k]);
      break;
    }
    let v: unknown, fine = true;
    try {
      v = settled(c.decode(bytes.subarray(at + used, at + used + n)));
    } catch {
      fine = false;
    }
    if (fine && v !== undefined) {
      values.push(v);
      const count = used + n;
      let scattered: string[] | undefined;
      for (let k = 1; k < count; k++) {
        if (ids[at + k] !== nextMarker(ids[at], k)) {
          scattered = ids.slice(at, at + count);
          break;
        }
      }
      frames.push({ value: v, first: ids[at], count, last: ids[at + count - 1], scattered });
    } else {
      for (let k = at; k < at + used + n; k++) junk.push(ids[k]);
    }
    at += used + n;
  }
  return { values, frames, junk };
}

// The longest run of a sequence, by places it had before, that is still in order: those stay where they are.
function staying(seq: readonly string[], before: ReadonlyMap<string, number>): Uint8Array {
  const tails: number[] = [];
  const prev = new Int32Array(seq.length);
  for (let i = 0; i < seq.length; i++) {
    const o = before.get(seq[i]);
    if (o === undefined) continue;
    let lo = 0, hi = tails.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (before.get(seq[tails[mid]])! < o) lo = mid + 1;
      else hi = mid;
    }
    tails[lo] = i;
    prev[i] = lo > 0 ? tails[lo - 1] : -1;
  }
  const keep = new Uint8Array(seq.length);
  let at = tails.length > 0 ? tails[tails.length - 1] : -1;
  while (at >= 0) {
    keep[at] = 1;
    at = prev[at];
  }
  return keep;
}

function latest(row: Stored, slot: number): Cell | undefined {
  const cells = row.slots.get(slot);
  if (!cells) return undefined;
  let best: Cell | undefined;
  for (const cell of cells.values()) if (cell.kind === VALUE && (!best || cell.stamp > best.stamp)) best = cell;
  return best;
}

function startsWith(body: Uint8Array, prefix: string): boolean {
  if (body.length < prefix.length) return false;
  for (let i = 0; i < prefix.length; i++) if (body[i] !== prefix.charCodeAt(i)) return false;
  return true;
}

function sameBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

// Ids as the client gives them, as they are kept here: only ever of hex the client, or this, has written.
const NIBBLE = new Uint8Array(128);
for (let i = 0; i < 16; i++) NIBBLE["0123456789abcdef".charCodeAt(i)] = i;
function binaryOf(hex: string): string {
  let s = "";
  for (let i = 0; i < hex.length; i += 2) s += String.fromCharCode((NIBBLE[hex.charCodeAt(i)] << 4) | NIBBLE[hex.charCodeAt(i + 1)]);
  return s;
}

// What a record's key is written as.
const SURROGATE = /[\uD800-\uDFFF]/;
function keyBytes(k: string): string {
  const out = codec.binary(utf8.encode(k));
  if (SURROGATE.test(k) && strict.decode(codec.bytesOf(out)) !== k) throw new Error("a record's keys are strings of whole characters");
  return out;
}

// A copy of an array to change. Not by slice, which of a frozen array makes one that is slow to change in V8: ten times
// what this costs, for twenty thousand items.
function copy<T>(a: readonly T[]): T[] {
  return [...a];
}

function sameList(a: readonly unknown[] | undefined, b: readonly unknown[]): boolean {
  if (!a || a.length !== b.length) return false;
  for (let i = 0; i < b.length; i++) if (!Object.is(a[i], b[i])) return false;
  return true;
}

// Where each is in a list of ids.
function indexOf(ids: readonly string[]): Map<string, number> {
  const out = new Map<string, number>();
  for (let i = 0; i < ids.length; i++) out.set(ids[i], i);
  return out;
}

function own(o: object, k: string): any {
  return Object.hasOwn(o, k) ? (o as Obj)[k] : undefined;
}

// ---------------------------------------------------------------- the document

type BoxState =
  | { kind: "map"; out: Obj }
  | {
      kind: "items";
      out: readonly Obj[];
      ids: string[];
      hidden: Set<string>;
      living: boolean;
      index: Map<string, number> | undefined;
      slot: number;
      dups: Set<string>;
    }
  | { kind: "values"; out: readonly unknown[]; frames: Frame[]; junk: string[] }
  | { kind: "record"; out: Obj; keys: Map<string, string> }
  | {
      kind: "tree";
      out: readonly Obj[];
      kids: Map<string, string[]>;
      up: Map<string, string>;
      sits: Map<string, string>;
      lost: Map<string, string>;
      levels: Map<string, readonly Obj[]>;
      slot: number;
    };
type Items = Extract<BoxState, { kind: "items" }>;

/**
 * Opens a document: the observer hears it at once, and again whenever anything in it changes, at most once a turn, with
 * whatever did not change the very same object as before.
 */
export function open<S extends MapSchema<any>>(client: Client, options: { scope: number; name: string; schema: S }, observer?: (state: Doc<S>) => void): Mirror<S> {
  return opened(client, options, observer, false).mirror;
}

// An open document, and for ask, what it reads with: read again what has changed among the rows held; the ids that are the
// same for everyone; a row to read again; the state as last read. One opened for ask (heldOnly) is read over whatever rows
// the client holds, not over the whole document: what is not held is not known, rather than gone. It is read, not written.
interface Opened<S extends MapSchema<any>> {
  mirror: Mirror<S>;
  refresh: () => void;
  derive: (parts: string) => string;
  mark: (id: string) => void;
  current: () => Obj;
}

function opened<S extends MapSchema<any>>(
  client: Client,
  options: { scope: number; name: string; schema: S },
  observer: ((state: Doc<S>) => void) | undefined,
  heldOnly: boolean,
): Opened<S> {
  const { scope, schema } = options;
  if (schema?.kind !== "map") throw new Error("a document is a map");
  const list = "mirror/" + options.name;

  // Ids that are the same for everyone: of the document, of a map within a map, and of a record's entry, by what makes
  // them, joined by zero bytes.
  const salt = utf8.encode("zsp-mirror\0" + options.name + "\0");
  const derived = new Map<string, string>();
  let derivedFrom: Uint8Array | undefined;
  const derive = (parts: string): string => {
    const key = client.scopeKey(scope);
    if (!key) return ZERO; // not yet known, or not to be read here: there is nothing, until there is
    if (key !== derivedFrom) {
      if (!derivedFrom || !sameBytes(key, derivedFrom)) derived.clear();
      derivedFrom = key;
    }
    let id = derived.get(parts);
    if (id === undefined) {
      const input = new Uint8Array(key.length + salt.length + parts.length);
      input.set(key);
      input.set(salt, key.length);
      for (let i = 0; i < parts.length; i++) input[key.length + salt.length + i] = parts.charCodeAt(i);
      id = codec.u32Binary(scope) + "\0\0\0\0" + codec.binary(sha256(input), 0, 8);
      if (derived.size >= 65536) derived.clear();
      derived.set(parts, id);
    }
    return id;
  };
  const keyOf = (owner: string, field: string): string => owner + field;
  const hex = codec.hex;
  // Rows as the client holds them. While the document is read, nothing changes what is held, so each is asked for once.
  let reading: Map<string, Stored | undefined> | undefined;
  const held = (id: string): Stored | undefined => {
    if (!reading) return client.held(hex(id));
    let row = reading.get(id);
    if (row === undefined && !reading.has(id)) reading.set(id, (row = client.held(hex(id))));
    return row;
  };
  const heldText = (id: string, slot: number): text.Text | undefined => client.heldText(hex(id), slot);

  // What is known of the document's rows, kept as they change.
  const wheres = new Map<string, Where>();
  const members = new Map<string, Set<string>>(); // of each list, record or tree, and map: what says it is in it
  const owned = new Map<string, Set<string>>(); // of each row: the keys of what is in it
  const hangs = new Map<string, Set<string>>(); // of each tree node: what says it hangs from it
  const schemaOf = new Map<string, MapSchema>(); // of each map row, as last read
  const treeUp = new Map<string, string>(); // of each tree node, as last read: the node it hangs from
  const losing = new Set<string>(); // trees with nodes beneath what is not there
  const standingIn = new Map<string, string>(); // of each map within a map: where it is, which its id says, row or no row
  const versions = new Map<string, { t: text.Text | undefined; v: number }>(); // of each text that keeps an order, as last read
  const dirtyRows = new Set<string>();
  const movedIn = new Map<string, Map<string, string | true>>(); // of each list: what came, went or moved, and from which marker
  const garbage = new Map<string, Set<string>>(); // of each list: markers nothing has
  const deadRows = new Set<string>(); // seen to be deleted: what is in them is no longer anywhere
  const emptied = new Set<string>(); // keys let go of: what is put in them meanwhile is not anywhere either
  const dirtyNode = new Set<string>();
  const dirtyBox = new Map<string, boolean>(); // true if what is in it or its order may have changed; false if only its members
  const nodes = new Map<string, Obj>(); // maps, as last read, by id
  const boxes = new Map<string, BoxState>(); // lists, records and trees, as last read
  const tnodes = new Map<string, { node: Obj; out: Obj }>(); // tree nodes with their children
  let current: Obj = undefined as unknown as Obj;
  let stopped = false;
  let tag: string | undefined;
  // What is read of a row is kept with it, among its views, which the client lets go of whenever the row changes.
  const ME: Table = Object.freeze({});

  const ours = (id: string, hexId: string): boolean => {
    if (wheres.has(id)) return true;
    const row = client.held(hexId);
    if (!row) return false;
    if (tag === undefined) {
      if (!client.scopeKey(scope)) return false;
      tag = client.tag(scope, list);
    }
    for (let slot = 1; slot <= 15; slot++) {
      const cells = row.slots.get(slot);
      if (cells) for (const c of cells.values()) if (startsWith(c.body, tag)) return true;
    }
    return false;
  };

  // ------------------------------------------------ what has changed

  const changedIn = new Map<string, Set<string>>(); // of each list and record: members that changed
  const marked = new Set<string>(); // in this pass: passed on to what it is in already
  const markBox = (key: string, structural: boolean, member?: string): void => {
    if (member !== undefined) {
      let set = changedIn.get(key);
      if (!set) changedIn.set(key, (set = new Set()));
      set.add(member);
    }
    if (structural) dirtyBox.set(key, true);
    else if (!dirtyBox.has(key)) dirtyBox.set(key, false);
    markNode(key.slice(0, 16));
  };
  const markNode = (id: string): void => {
    if (id === ZERO || marked.has(id)) return;
    marked.add(id);
    dirtyNode.add(id);
    const up = treeUp.get(id);
    if (up !== undefined && up !== ZERO) markNode(up);
    const w = wheres.get(id);
    const box = w ? keyOf(w.owner, w.field) : undefined;
    if (box !== undefined) markBox(box, false, id);
    // A map within a map is there whether its own row has come or not, and is where its id says.
    const within = standingIn.get(id);
    if (within !== undefined && within !== box) markBox(within, false, id);
  };

  const whereOf = (row: Stored): Where | undefined => {
    const c = latest(row, WHERE);
    return c ? whereDecode(c.body, c.stamp) : undefined;
  };

  // Whether a text that keeps an order has changed since it was last read.
  const remade = new Set<string>(); // texts of order made anew: what was in them may be gone
  const moved = (id: string, slot: number): boolean => {
    const t = heldText(id, slot);
    const k = id + String.fromCharCode(slot);
    const was = versions.get(k);
    const v = t ? t.version : 0;
    if (!was || was.t !== t || was.v !== v) {
      if (!was || was.t !== t) remade.add(k); // a text made again is another, as when a value was written over it
      versions.set(k, { t, v });
      return true;
    }
    return false;
  };

  const absorb = (): void => {
    marked.clear();
    for (const id of dirtyRows) {
      const row = held(id);
      const w = row && !row.dead ? whereOf(row) : undefined;
      const old = wheres.get(id);
      if (old && old.kind === NODE && (!w || w.parent !== old.parent)) hangs.get(old.parent)?.delete(id);
      if (w && w.kind === NODE && w.parent !== ZERO) {
        let set = hangs.get(w.parent);
        if (!set) hangs.set(w.parent, (set = new Set()));
        set.add(id);
      }
      if (old && (!w || old.body !== w.body)) {
        const k = keyOf(old.owner, old.field);
        members.get(k)?.delete(id);
        // Where it was when the list was last read, to find it there: true if it was not in it then.
        let mv = movedIn.get(k);
        if (!mv) movedIn.set(k, (mv = new Map()));
        if (!mv.has(id)) mv.set(id, old.kind === ITEM ? old.marker : true);
        if (old.kind === ITEM && (!w || w.marker !== old.marker)) {
          // A marker no longer anyone's, if it is still there: let go of when the list is next written.
          const box = boxes.get(k);
          const t = box && box.kind === "items" ? heldText(old.owner, box.slot) : undefined;
          if (t && text.standing(t, old.marker)) {
            let g = garbage.get(k);
            if (!g) garbage.set(k, (g = new Set()));
            g.add(old.marker);
          }
        }
        markBox(k, true);
      }
      if (w) wheres.set(id, w);
      else wheres.delete(id);
      if (w && w.kind === ENTRY && !w.present) emptied.add(id);
      else emptied.delete(id);
      if (w && (!old || old.body !== w.body)) {
        const k = keyOf(w.owner, w.field);
        let m = members.get(k);
        if (!m) members.set(k, (m = new Set()));
        m.add(id);
        let o = owned.get(w.owner);
        if (!o) owned.set(w.owner, (o = new Set()));
        o.add(k);
        let mv = movedIn.get(k);
        if (!mv) movedIn.set(k, (mv = new Map()));
        if (!mv.has(id)) mv.set(id, true);
        markBox(k, true);
      }
      markNode(id);
      const s = schemaOf.get(id);
      if (s) {
        for (let i = 0; i < s.names.length; i++) {
          const b = s.boxes[i];
          if (b && (b.kind === "list" || b.kind === "tree") && moved(id, b.slot)) markBox(keyOf(id, s.keys[i]), true);
        }
      }
      if (w && w.kind === NODE) {
        const k = keyOf(w.owner, w.field);
        const t = boxes.get(k);
        if (t && t.kind === "tree" && moved(id, t.slot)) markBox(k, true);
      }
      // What was in a row that is gone is gone with it, wherever it is; and a row that is here is not gone, whatever was
      // seen of it, as when it was let go of from memory while it was elsewhere, and is back. Where only some rows are
      // held, one that is not held is not known to be gone.
      const gone = heldOnly ? row !== undefined && row.dead : !row || row.dead;
      if (old && !w && gone) deadRows.add(id); // deleted, and perhaps let go of from memory already
      else if (row && !row.dead) deadRows.delete(id);
      // What is in a row that comes or goes is there or not with it.
      if ((old === undefined) !== (w === undefined)) {
        const ks = owned.get(id);
        if (ks) for (const k of ks) markBox(k, true);
      }
    }
    dirtyRows.clear();
  };

  // ------------------------------------------------ reading

  // A value as a column holds it: a text is always one, empty or not; otherwise what is empty is nothing. Who wrote it,
  // of a column that says so, is as the client tells it of any row.
  const decode = (c: Column<any>, row: Stored): unknown => {
    if (c.who) {
      let last: Cell | undefined;
      const names = new Set<string>();
      for (const cell of row.slots.get(c.slot)?.values() ?? NONE) {
        if (!last || cell.stamp > last.stamp) last = cell;
        if (cell.author && cell.author.subject !== "") names.add(cell.author.subject);
      }
      if (c.who === "all") return Object.freeze([...names].sort());
      return last?.author && last.author.subject !== "" ? last.author.subject : undefined;
    }
    if (c.text) return text.read(client.heldText(row.hex, c.slot)!);
    const cell = latest(row, c.slot);
    if (!cell || cell.body.length === 0) return undefined;
    try {
      return settled(c.decode(cell.body));
    } catch {
      return undefined; // what does not read as one of its kind is nothing
    }
  };
  // What a column of a map whose row is not here reads as.
  const absent = (c: Column<any> | undefined): unknown => (c?.text ? "" : c?.who === "all" ? NOBODY : undefined);

  const valuesOf = (s: MapSchema, row: Stored): unknown[] => {
    const views = row.views as unknown as Map<Table, Map<MapSchema, unknown[]>>;
    let c = views.get(ME);
    if (!c) views.set(ME, (c = new Map()));
    let v = c.get(s);
    if (!v) {
      v = new Array(s.names.length);
      for (let i = 0; i < s.names.length; i++) {
        const col = s.columns[i];
        if (col) v[i] = decode(col, row);
      }
      c.set(s, v);
    }
    return v;
  };

  const alive = (id: string): Stored | undefined => {
    const row = held(id);
    return row && !row.dead ? row : undefined;
  };

  // The document, and maps within maps, are there for everyone whether their own rows have come or not: what is in
  // them is. Whatever else holds anything holds it only while it is there itself.
  const standing = new Set<string>();
  const holds = (owner: string): boolean => standing.has(owner) || alive(owner) !== undefined;

  // A map: the same object as before if nothing in it is other than it was.
  const buildMap = (s: MapSchema, id: string): Obj => {
    // What was made of the row for another shape of map is not this one, though they share an id: as maps do before the
    // scope's key is known, when there is nothing in any of them.
    const was = schemaOf.get(id) === s ? nodes.get(id) : undefined;
    if (was !== undefined && !dirtyNode.has(id) && !plain) return was;
    dirtyNode.delete(id);
    schemaOf.set(id, s);
    const row = alive(id);
    const vals = row ? valuesOf(s, row) : undefined;
    const n = s.names.length;
    const parts = new Array(n);
    let changed = was === undefined;
    for (let i = 0; i < n; i++) {
      const b = s.boxes[i];
      const v = b ? buildBox(b, id, s.keys[i]) : vals ? vals[i] : absent(s.columns[i]);
      parts[i] = v;
      if (!changed) changed = !Object.is(was![s.names[i]], v);
    }
    if (!changed) return was!;
    const out: Record<string, unknown> = { id: hex(id) };
    for (let i = 0; i < n; i++) if (parts[i] !== undefined) out[s.names[i]] = parts[i];
    frozen(out);
    nodes.set(id, out);
    return out;
  };

  // Items that share a marker with the one before them, which only a writer who minds nothing makes: whoever writes
  // the list next gives each one of its own, so that anything can be put between them.
  const sharing = (ids: readonly string[]): Set<string> => {
    const out = new Set<string>();
    for (let i = 1; i < ids.length; i++) {
      const a = wheres.get(ids[i - 1]), b = wheres.get(ids[i]);
      if (a && b && a.marker === b.marker) out.add(ids[i]);
    }
    return out;
  };

  // A record's entry, or a map or a value as it is in a row, whether that is in anything or not.
  const buildValue = (of: Of, id: string): unknown => {
    if (isMap(of)) return buildMap(of, id);
    const row = alive(id);
    return row ? decode(of, row) : undefined;
  };

  // Which of two items, each with where its marker is, goes first: by place, and then by id.
  const less = (lx: number, ox: number, x: string, ly: number, oy: number, y: string): boolean =>
    lx !== ly ? lx < ly : ox !== oy ? ox < oy : x < y;

  const buildBox = (b: Schema, owner: string, field: string): unknown => {
    const key = keyOf(owner, field);
    const st = boxes.get(key);
    const d = dirtyBox.get(key);
    if (st && d === undefined && !plain) return st.out;
    const structural = d === true || st === undefined || plain;
    dirtyBox.delete(key);
    if (b.kind === "map") {
      const id = derive(owner + "\0" + field);
      standing.add(id);
      standingIn.set(id, key);
      const out = buildMap(b, id);
      boxes.set(key, { kind: "map", out });
      return out;
    } else if (b.kind === "list" && isMap(b.of)) {
      const of: MapSchema = b.of;
      const prior = st as Items | undefined;
      let ids = prior ? prior.ids : [];
      let hidden = prior ? prior.hidden : new Set<string>();
      const living = holds(owner);
      if (structural) {
        const slotKey = owner + String.fromCharCode(b.slot);
        const t = living ? heldText(owner, b.slot) : undefined;
        // The text read, to know later whether it is still the one.
        versions.set(slotKey, { t, v: t ? t.version : 0 });
        // Where an item's marker is, if it is one there is: asked once of each, as nothing moves while it is read.
        const places = new Map<string, [label: number, offset: number] | null>();
        const pos = (id: string): [label: number, offset: number] | null => {
          let p = places.get(id);
          if (p === undefined) {
            const w = wheres.get(id);
            p = t && w && w.kind === ITEM && alive(id) ? text.position(t, w.marker) : null;
            places.set(id, p);
          }
          return p;
        };
        const redo = movedIn.get(key) ?? new Map<string, string | true>();
        movedIn.delete(key);
        const mine = members.get(key) ?? new Set<string>();
        const again = remade.has(slotKey);
        remade.delete(slotKey);
        if (prior && prior.living === living && !again && !plain) {
          // What did not move keeps its order, for the order of what is there never changes; what came, moved, or had
          // nowhere to be yet, is taken out and put in its place, in arrays as they were.
          for (const id of hidden) redo.set(id, true);
          // Each is found where it was, by the marker it had: that still has its place, gone or not.
          let index = prior.index;
          const atOf = (id: string, was: string | true): number | undefined => {
            if (index) return index.get(id);
            if (was === true) return undefined; // it was not in the list as last read
            if (typeof was === "string" && t) {
              const p = text.position(t, was);
              if (p) {
                const [lw, ow] = p;
                let lo = 0, hi = ids.length - 1;
                while (lo <= hi) {
                  const mid = (lo + hi) >> 1;
                  const m = ids[mid];
                  if (m === id) return mid;
                  // In the order as it was: what moved is where it was.
                  const r = redo.get(m);
                  const q = typeof r === "string" ? text.position(t, r) : pos(m);
                  if (q === null) break;
                  if (less(q[0], q[1], m, lw, ow, id)) lo = mid + 1;
                  else hi = mid - 1;
                }
              }
            }
            index = indexOf(ids);
            return index.get(id);
          };
          const gone: number[] = [];
          for (const [id, was] of redo) {
            const at = atOf(id, was);
            if (at !== undefined) gone.push(at);
          }
          let newIds: string[], parts: Obj[];
          if (gone.length === 0) {
            newIds = ids.slice();
            parts = copy(prior.out);
          } else {
            // Taken out all at once, the rest keeping their order.
            const out = new Uint8Array(ids.length);
            for (const at of gone) out[at] = 1;
            newIds = [];
            parts = [];
            for (let i = 0; i < ids.length; i++) {
              if (out[i]) continue;
              newIds.push(ids[i]);
              parts.push(prior.out[i]);
            }
          }
          hidden = new Set();
          // Where each put back is, so long as they are few enough to keep count of as more go in; and past that, all
          // put back at once, in order, between the rest: where each is is the same, the order being whole.
          let put: number[] | undefined = [];
          const back: string[] = [];
          for (const id of redo.keys()) {
            if (mine.has(id) && alive(id)) {
              const p = pos(id);
              if (p && put === undefined) {
                back.push(id);
              } else if (p && put) {
                const [l, o] = p;
                let lo = 0, hi = newIds.length;
                while (lo < hi) {
                  const mid = (lo + hi) >> 1;
                  const m = newIds[mid];
                  const q = pos(m)!;
                  if (less(q[0], q[1], m, l, o, id)) lo = mid + 1;
                  else hi = mid;
                }
                newIds.splice(lo, 0, id);
                parts.splice(lo, 0, buildMap(of, id));
                if (put.length >= 64) {
                  put = undefined;
                } else {
                  for (let i = 0; i < put.length; i++) if (put[i] >= lo) put[i]++;
                  put.push(lo);
                }
              } else {
                hidden.add(id);
              }
            }
          }
          if (back.length > 0) {
            const before = (x: string, y: string): number => {
              const px = pos(x)!, py = pos(y)!;
              return x === y ? 0 : less(px[0], px[1], x, py[0], py[1], y) ? -1 : 1;
            };
            back.sort(before);
            const ids2: string[] = [], parts2: Obj[] = [];
            let i = 0;
            for (const id of back) {
              while (i < newIds.length && before(newIds[i], id) < 0) {
                ids2.push(newIds[i]);
                parts2.push(parts[i++]);
              }
              ids2.push(id);
              parts2.push(buildMap(of, id));
            }
            for (; i < newIds.length; i++) {
              ids2.push(newIds[i]);
              parts2.push(parts[i]);
            }
            newIds = ids2;
            parts = parts2;
          }
          // What changed in place, too; where things are is known again when next it is asked.
          const touched = changedIn.get(key);
          changedIn.delete(key);
          let freshIndex: Map<string, number> | undefined;
          if (touched) {
            for (const id of touched) {
              if (!redo.has(id)) {
                freshIndex ??= indexOf(newIds);
                const at = freshIndex.get(id);
                if (at !== undefined) parts[at] = buildMap(of, id);
              }
            }
          }
          const out = gone.length === 0 && newIds.length === ids.length && sameList(prior.out, parts) ? prior.out : frozen(parts);
          // Sharing a marker is looked for only beside what was put back: what moved is looked at again.
          const dups = new Set(prior.dups);
          for (const id of redo.keys()) dups.delete(id);
          const beside = (i: number): void => {
            for (let j = i; j <= i + 1; j++) {
              const x = newIds[j - 1], y = newIds[j];
              if (x === undefined || y === undefined) continue;
              const wx = wheres.get(x), wy = wheres.get(y);
              if (wx && wy && wx.marker === wy.marker) dups.add(y);
            }
          };
          if (put) for (const i of put) beside(i);
          else for (let i = 0; i < newIds.length; i++) if (redo.has(newIds[i])) beside(i);
          boxes.set(key, { kind: "items", out, ids: newIds, hidden, living, index: freshIndex, slot: b.slot, dups });
          return out;
        }
        hidden = new Set();
        const at: { id: string; l: number; o: number }[] = [];
        for (const id of mine) {
          if (alive(id)) {
            const p = pos(id);
            if (p) at.push({ id, l: p[0], o: p[1] });
            else hidden.add(id);
          }
        }
        at.sort((x, y) => (x.l !== y.l ? x.l - y.l : x.o !== y.o ? x.o - y.o : x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
        ids = at.map((x) => x.id);
      }
      const touched = changedIn.get(key);
      changedIn.delete(key);
      if (!structural && prior) {
        // In the same order: only what changed is read again.
        const index = prior.index ?? indexOf(ids);
        let parts: Obj[] | undefined;
        if (touched) {
          for (const id of touched) {
            const i = index.get(id);
            if (i !== undefined) {
              const v = buildMap(of, id);
              if (v !== prior.out[i]) {
                parts ??= copy(prior.out);
                parts[i] = v;
              }
            }
          }
        }
        const out = parts ? frozen(parts) : prior.out;
        boxes.set(key, { kind: "items", out, ids, hidden, living, index, slot: b.slot, dups: prior.dups });
        return out;
      }
      const parts = ids.map((id) => buildMap(of, id));
      const out = prior && sameList(prior.out, parts) ? prior.out : frozen(parts);
      boxes.set(key, { kind: "items", out, ids, hidden, living, index: undefined, slot: b.slot, dups: sharing(ids) });
      return out;
    } else if (b.kind === "list") {
      const prior = st as Extract<BoxState, { kind: "values" }> | undefined;
      if (!structural && prior) return prior.out;
      const { values, frames, junk } = framesOf(b.of, holds(owner) ? heldText(owner, b.slot) : undefined);
      const out = prior && sameList(prior.out, values) ? prior.out : frozen(values);
      boxes.set(key, { kind: "values", out, frames, junk });
      return out;
    } else if (b.kind === "record") {
      const prior = st as Extract<BoxState, { kind: "record" }> | undefined;
      let keys = prior ? prior.keys : new Map<string, string>();
      if (structural) {
        const found: [string, string][] = [];
        if (holds(owner)) {
          for (const id of members.get(key) ?? NONE) {
            const w = wheres.get(id);
            if (w && w.kind === ENTRY && w.present && w.name !== undefined && alive(id) && id === derive(owner + "\0" + field + "\0" + w.key)) {
              found.push([w.name, id]);
            }
          }
        }
        // In the order of their keys, so that a record is the same everywhere, to the order of its keys.
        found.sort((x, y) => (x[0] < y[0] ? -1 : x[0] > y[0] ? 1 : 0));
        keys = new Map(found);
      }
      const touched = changedIn.get(key);
      changedIn.delete(key);
      if (!structural && prior) {
        let out: Record<string, unknown> | undefined;
        if (touched) {
          for (const id of touched) {
            const w = wheres.get(id);
            if (w && w.name !== undefined && keys.get(w.name) === id) {
              const v = buildValue(b.of, id);
              if (!Object.is(v, prior.out[w.name])) {
                out ??= Object.assign(Object.create(null), prior.out) as Record<string, unknown>;
                if (v === undefined) delete out[w.name];
                else out[w.name] = v;
              }
            }
          }
        }
        const result = out ? frozen(out) : prior.out;
        boxes.set(key, { kind: "record", out: result, keys });
        return result;
      }
      // Without a prototype, so that any key is only a key.
      const out: Record<string, unknown> = Object.create(null);
      let changed = prior === undefined;
      let count = 0;
      for (const [k, id] of keys) {
        const v = buildValue(b.of, id);
        if (v !== undefined) {
          out[k] = v;
          count++;
          changed ||= !Object.is(prior!.out[k], v);
        }
      }
      if (!changed) changed = count !== Object.keys(prior!.out).length;
      const result = changed ? frozen(out) : prior!.out;
      boxes.set(key, { kind: "record", out: result, keys });
      return result;
    } else {
      // A tree. Each node says what it hangs from; where that makes a loop, the node of the loop that moved last goes
      // back to where it came from, and failing that to the top. What hangs from nothing there is, is not.
      const prior = st as Extract<BoxState, { kind: "tree" }> | undefined;
      let kids = prior ? prior.kids : new Map<string, string[]>();
      let up = prior ? prior.up : new Map<string, string>();
      let sits = prior ? prior.sits : new Map<string, string>();
      let lost = prior ? prior.lost : new Map<string, string>(); // of each node not shown: the node, not there, it is beneath
      if (structural) {
        const here = new Map<string, Where>();
        if (holds(owner)) {
          for (const id of members.get(key) ?? NONE) {
            const w = wheres.get(id);
            if (w && w.kind === NODE && alive(id)) here.set(id, w);
          }
        }
        const parent = new Map<string, string>();
        const marker = new Map<string, string>();
        for (const [id, w] of here) {
          parent.set(id, w.parent);
          marker.set(id, w.marker);
        }
        const ids = [...here.keys()].sort();
        const reverted = new Set<string>();
        for (;;) {
          const state = new Map<string, number>(); // 1 on the way up, 2 reaches the top, 3 hangs from nothing
          let loop: string[] | undefined;
          lost = new Map();
          for (const start of ids) {
            const path: string[] = [];
            let at = start;
            let final = 2;
            let missing: string | undefined;
            while (at !== ZERO) {
              const s2 = state.get(at);
              if (s2 === 2 || s2 === 3) {
                final = s2;
                missing = lost.get(at);
                break;
              } else if (s2 === 1) {
                loop = path.slice(path.indexOf(at));
                break;
              } else if (!here.has(at)) {
                final = 3;
                missing = at;
                break;
              }
              state.set(at, 1);
              path.push(at);
              at = parent.get(at)!;
            }
            if (loop) break;
            for (const p of path) {
              state.set(p, final);
              if (missing !== undefined) lost.set(p, missing);
            }
          }
          if (!loop) {
            for (const id of ids) if (state.get(id) !== 2) here.delete(id);
            break;
          }
          let last = loop[0];
          for (const id of loop) if (here.get(id)!.stamp > here.get(last)!.stamp) last = id;
          // Back where it was, by the marker it left there; or, if that will not do either, last at the top.
          parent.set(last, reverted.has(last) ? ZERO : here.get(last)!.from);
          marker.set(last, reverted.has(last) ? "" : here.get(last)!.back);
          reverted.add(last);
        }
        // Children, in the order of their markers in what they hang from.
        const by = new Map<string, { id: string; at: number; off: number }[]>();
        const texts = new Map<string, text.Text | null>();
        for (const id of here.keys()) {
          const p = parent.get(id)!;
          const holder = p === ZERO ? owner : p;
          let t = texts.get(holder);
          if (t === undefined) texts.set(holder, (t = heldText(holder, b.slot) ?? null));
          const m = marker.get(id)!;
          let l: number | undefined, off = 0;
          if (m === "") {
            l = Infinity;
          } else if (t) {
            const q = text.position(t, m);
            if (q) [l, off] = q;
          }
          if (l !== undefined) {
            let items = by.get(p);
            if (!items) by.set(p, (items = []));
            items.push({ id, at: l, off });
          }
        }
        for (const id of up.keys()) treeUp.delete(id);
        kids = new Map();
        up = new Map();
        sits = new Map();
        for (const [p, items] of by) {
          items.sort((x, y) => (x.at !== y.at ? (x.at < y.at ? -1 : 1) : x.off !== y.off ? x.off - y.off : x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
          const order: string[] = [];
          for (const it of items) {
            order.push(it.id);
            up.set(it.id, p);
            treeUp.set(it.id, p);
            sits.set(it.id, marker.get(it.id)!);
          }
          kids.set(p, order);
        }
      }
      const levels = prior ? prior.levels : new Map<string, readonly Obj[]>();
      const freshLevels = new Map<string, readonly Obj[]>();
      const level = (under: string): readonly Obj[] => {
        const parts: Obj[] = [];
        for (const id of kids.get(under) ?? NONE) {
          const was0 = tnodes.get(id);
          if (!structural && was0 && !dirtyNode.has(id)) {
            parts.push(was0.out); // nothing in it, nor beneath it, has changed
            continue;
          }
          const node = buildMap(b.of, id);
          const children = level(id);
          const was = tnodes.get(id);
          if (was && was.node === node && was.out.children === children) {
            parts.push(was.out);
          } else {
            const out = frozen({ ...node, children });
            tnodes.set(id, { node, out });
            parts.push(out);
          }
        }
        const prev = levels.get(under);
        const out = prev && sameList(prev, parts) ? prev : frozen(parts);
        freshLevels.set(under, out);
        return out;
      };
      // Levels not reached again are as they were.
      if (!structural) for (const [under, l] of levels) freshLevels.set(under, l);
      const out = level(ZERO);
      boxes.set(key, { kind: "tree", out, kids, up, sits, lost, levels: freshLevels, slot: b.slot });
      if (lost.size > 0) losing.add(key);
      else losing.delete(key);
      return out;
    }
  };

  const read = (): Obj => {
    reading = new Map();
    try {
      absorb();
      // What is not reached now stays to be read when it is.
      const root = derive("");
      standing.add(root);
      return buildMap(schema, root);
    } finally {
      reading = undefined;
    }
  };

  const refresh = (): void => {
    if (stopped) return;
    const was = current;
    current = read();
    if (observer && was !== current) observer(current as Doc<S>);
  };

  const watching = heldOnly ? undefined : client.window({ scope, list, table: WINDOW, size: 0, from: "start", bare: true }, () => refresh());
  const unfollow = client.follow((id) => {
    if (stopped) return;
    const bin = binaryOf(id);
    if (ours(bin, id)) dirtyRows.add(bin);
  });
  for (const e of watching?.entries() ?? NONE) dirtyRows.add(e.row.id);
  refresh();

  // ------------------------------------------------ writing

  // Writing what a record of values holds, under names of its own: its value, or nothing.
  const valueTables = new WeakMap<Column<any>, Table>();
  const valueTable = (of: Column<any>): Table => {
    let t = valueTables.get(of);
    if (!t) valueTables.set(of, (t = Object.freeze({ [W]: WHERE_COLUMN, v: of, e: raw(of.slot) })));
    return t;
  };

  const set = (state: Input<S>): Promise<void> => {
    if (heldOnly) throw new Error("what is asked about is read, not written");
    if (stopped) throw new Error("the document is closed");
    if (!client.may(scope, "write")) throw new Error("this client may not write there, or does not know yet that it may");
    refresh();
    const done = client.write(scope, (change) => write(change, state));
    refresh();
    return done;
  };

  const write = (change: Change, state: Input<S>): void => {
    // A row and everything in it, wherever that is, shown or not.
    const deleting = new Set<string>();
    const spared = new Set<string>(); // nodes the new state has, wherever they hung before
    const deleteRow = (id: string): void => {
      if (deleting.has(id) || spared.has(id)) return;
      deleting.add(id);
      change.delete(hex(id));
      const ks = owned.get(id);
      if (ks) for (const k of ks) for (const m of members.get(k) ?? NONE) deleteRow(m);
      for (const m of hangs.get(id) ?? NONE) deleteRow(m); // and what hangs from it, as a node of a tree
    };

    const writeValue = (of: Of, old: any, nv: any, id: string, made: boolean, where?: Uint8Array): void => {
      if (isMap(of)) {
        writeMap(of, old, nv, id, made, where);
        return;
      }
      const values: Record<string, unknown> = {};
      let some = false;
      if (!sameValue(of, nv, old) || made) {
        if (nv === undefined) values.e = EMPTY;
        else values.v = nv;
        some = true;
      }
      if (where) {
        values[W] = where;
        some = true;
      }
      if (some) change.set(hex(id), valueTable(of), values);
    };

    const make = (of: Of, value: any, where: Uint8Array): string => {
      if (isMap(of)) {
        const id = binaryOf(change.insert(of.writing, list, 0, { [W]: where }));
        writeMap(of, undefined, value, id, true);
        return id;
      }
      return binaryOf(change.insert(valueTable(of), list, 0, { [W]: where, v: value }));
    };

    // A text column, as edits, so that what others type meanwhile is kept: what is between what is the same at either
    // end is written, never parting a character's bytes.
    const edit = (id: string, slot: number, nv: string): void => {
      change.edit(hex(id), slot, (t, fresh) => {
        const was = text.content(t);
        const now = utf8.encode(nv);
        let a = 0, z = 0;
        while (a < was.length && a < now.length && was[a] === now[a]) a++;
        while (a > 0 && ((a < was.length && (was[a] & 0xc0) === 0x80) || (a < now.length && (now[a] & 0xc0) === 0x80))) a--;
        while (z < was.length - a && z < now.length - a && was[was.length - 1 - z] === now[now.length - 1 - z]) z++;
        while (z > 0 && (was[was.length - z] & 0xc0) === 0x80) z--;
        if (was.length - a - z > 0) text.erase(t, a, was.length - a - z, fresh);
        if (now.length - a - z > 0) text.insert(t, a, now.subarray(a, now.length - z), fresh);
      });
    };

    const writeMap = (s: MapSchema, old: Obj | undefined, nv: Obj | undefined, id: string, made: boolean, where?: Uint8Array): void => {
      if (old === nv && !made && !where && !plain) return; // the very object that was read: nothing in it has changed
      const n: Obj = nv ?? {};
      const values: Record<string, unknown> = {};
      let some = false;
      if (where) {
        values[W] = where;
        some = true;
      }
      for (let i = 0; i < s.names.length; i++) {
        const c = s.columns[i];
        if (!c || c.who) continue;
        const name = s.names[i];
        // A text is always a string, and one not given is empty: written as an edit, so that what others type meanwhile
        // is kept, as for any other.
        const v = c.text && !made && n[name] === undefined ? "" : n[name], ov = old ? old[name] : undefined;
        if (c.text && !made && typeof v === "string") {
          if (v !== ov && !(v === "" && ov === undefined)) edit(id, c.slot, v);
        } else if (!sameValue(c, v, ov) || made) {
          if (v !== undefined) {
            values[name] = v;
            some = true;
          } else if (ov !== undefined || (made && old !== undefined)) {
            values["\x01" + name] = EMPTY;
            some = true;
          }
        }
      }
      if (some) change.set(hex(id), s.writing, values);
      for (let i = 0; i < s.names.length; i++) {
        const b = s.boxes[i];
        if (b) writeBox(b, old ? old[s.names[i]] : undefined, n[s.names[i]], id, s.keys[i]);
      }
    };

    const writeBox = (b: Schema, old: any, nv: any, owner: string, field: string): void => {
      if (old === nv && old !== undefined && !plain) return;
      const key = keyOf(owner, field);
      const st = boxes.get(key);
      if (b.kind === "map") {
        const id = derive(owner + "\0" + field);
        const exists = alive(id) !== undefined && wheres.has(id);
        if (!exists) {
          change.set(hex(id), b.writing, { [W]: whereEncode(owner, field, MAP) });
          change.place(hex(id), list, 0);
        }
        writeMap(b, old, nv, id, !exists);
      } else if (b.kind === "list" && isMap(b.of)) {
        writeItems(b.of, b.slot, old, nv ?? NONE, owner, field, key, st && st.kind === "items" ? st : undefined);
      } else if (b.kind === "list") {
        const nw: readonly unknown[] = nv ?? NONE;
        const od: readonly unknown[] = old ?? NONE;
        const vs = st && st.kind === "values" ? st : undefined;
        const frames = vs ? vs.frames : [];
        let a = 0, z = 0;
        while (a < od.length && a < nw.length && sameValue(b.of, od[a], nw[a])) a++;
        while (z < od.length - a && z < nw.length - a && sameValue(b.of, od[od.length - 1 - z], nw[nw.length - 1 - z])) z++;
        change.edit(hex(owner), b.slot, (t, fresh) => {
          for (const id of vs ? vs.junk : NONE) text.remove(t, id, 1, fresh);
          for (let k = a; k < od.length - z; k++) {
            const f = frames[k];
            if (f.scattered) for (const id of f.scattered) text.remove(t, id, 1, fresh);
            else text.remove(t, f.first, f.count, fresh);
          }
          if (nw.length - a - z > 0) {
            const w = codec.writer();
            for (let k = a; k < nw.length - z; k++) codec.putBytes(w, b.of.encode(nw[k]));
            const prev = a > 0 ? frames[a - 1].last : "";
            text.after(t, prev, codec.written(w), fresh);
          }
        });
      } else if (b.kind === "record") {
        const nw: Obj = nv ?? {};
        const od: Obj = old ?? {};
        const keys = st && st.kind === "record" ? st.keys : new Map<string, string>();
        for (const [k, id] of keys) {
          if (own(nw, k) === undefined) {
            // Gone, and what it held with it, so that it takes no room and comes back as it is set.
            writeValue(b.of, own(od, k), isMap(b.of) ? {} : undefined, id, false, whereEncode(owner, field, ENTRY, "\0" + keyBytes(k)));
          }
        }
        for (const k of Object.keys(nw)) {
          const v = nw[k];
          if (v === undefined) continue;
          const id = keys.get(k);
          if (id !== undefined) {
            writeValue(b.of, own(od, k), v, id, false);
          } else {
            const kb = keyBytes(k);
            const entry = derive(owner + "\0" + field + "\0" + kb);
            const there = alive(entry) !== undefined;
            if (!there) change.place(hex(entry), list, 0);
            // What it held before, if it was once, is written over.
            const stale = there ? buildValue(b.of, entry) : undefined;
            writeValue(b.of, stale, v, entry, true, whereEncode(owner, field, ENTRY, "\x01" + kb));
          }
        }
      } else {
        writeTree(b, old, nv ?? NONE, owner, field, key, st && st.kind === "tree" ? st : undefined);
      }
    };

    const writeItems = (of: MapSchema, slot: number, old: readonly Obj[] | undefined, nw: readonly any[], owner: string, field: string, key: string, st: Items | undefined): void => {
      const oldIds = st ? st.ids : NONE;
      const oldl: readonly Obj[] = old ?? NONE;
      const dups = st ? st.dups : new Set<string>();
      const shared = dups.size > 0;
      const gc = garbage.get(key);
      const dirt = gc !== undefined && gc.size > 0;
      // An old item's id as an application has it.
      const hexAt = (o: number): string => (oldl[o] !== undefined ? oldl[o].id : hex(oldIds[o]));
      // What is the same at either end stays where it is, and is only written if it changed; what is between is
      // compared, and only what moved there moves.
      const sameAt = (n: number, o: number): boolean => {
        const item = nw[n];
        return item === oldl[o] || (typeof item === "object" && item !== null && item.id !== undefined && item.id === hexAt(o));
      };
      // The very same objects first, which is most of them when a state is built from the last.
      const nn = nw.length, no = oldIds.length;
      const least = shared || plain ? 0 : Math.min(nn, no);
      let a = 0, z = 0;
      while (a < least && nw[a] === oldl[a]) a++;
      while (a < least && sameAt(a, a)) {
        a++;
        while (a < least && nw[a] === oldl[a]) a++;
      }
      while (z < least - a && nw[nn - 1 - z] === oldl[no - 1 - z]) z++;
      while (z < least - a && sameAt(nn - 1 - z, no - 1 - z)) {
        z++;
        while (z < least - a && nw[nn - 1 - z] === oldl[no - 1 - z]) z++;
      }
      for (let k = 0; k < a; k++) if (nw[k] !== oldl[k]) writeMap(of, oldl[k], nw[k], oldIds[k], false);
      for (let k = 0; k < z; k++) {
        const n = nn - 1 - k, o = no - 1 - k;
        if (nw[n] !== oldl[o]) writeMap(of, oldl[o], nw[n], oldIds[o], false);
      }
      // One moved from one end of what is between to the other: it alone moves.
      const mid = no - z - a;
      if (mid === nn - z - a && mid >= 2 && !dirt && !shared && !plain) {
        let first = sameAt(a + mid - 1, a); // the first went last
        let last = sameAt(a, a + mid - 1); // the last went first
        for (let k = 1; k < mid && (first || last); k++) {
          first &&= sameAt(a + k - 1, a + k);
          last &&= sameAt(a + k, a + k - 1);
        }
        if (first || last) {
          const o = first ? a : a + mid - 1;
          const n = first ? a + mid - 1 : a;
          const id = oldIds[o];
          let marker = "";
          change.edit(hex(owner), slot, (t, fresh) => {
            text.remove(t, wheres.get(id)!.marker, 1, fresh);
            const after = first ? wheres.get(oldIds[a + mid - 1])!.marker : a > 0 ? wheres.get(oldIds[a - 1])!.marker : "";
            marker = text.after(t, after, MARK, fresh);
          });
          writeMap(of, oldl[o], nw[n], id, false, whereEncode(owner, field, ITEM, marker));
          for (let k = 1; k < mid; k++) {
            const nk = first ? a + k - 1 : a + k, oo = first ? a + k : a + k - 1;
            if (nw[nk] !== oldl[oo]) writeMap(of, oldl[oo], nw[nk], oldIds[oo], false);
          }
          return;
        }
      }
      // By the ids an application has: what was there, its own id, and its place.
      const was = new Map<string, Obj>();
      const ownId = new Map<string, string>();
      const before = new Map<string, number>();
      for (let o = a; o < no - z; o++) {
        const item = oldl[o];
        if (item === undefined) continue;
        was.set(item.id, item);
        ownId.set(item.id, oldIds[o]);
        if (!dups.has(oldIds[o])) before.set(item.id, o);
      }
      const seq: string[] = [];
      const kept = new Set<string>();
      for (let n = a; n < nn - z; n++) {
        const id = nw[n]?.id;
        if (typeof id === "string" && was.has(id) && !kept.has(id)) {
          kept.add(id);
          seq.push(id);
        } else {
          seq.push("\x01" + n);
        }
      }
      if (seq.length === 0 && no - z === a && !dirt) return; // nothing between
      const stay = staying(seq, before);
      const markers = new Map<string, string>();
      change.edit(hex(owner), slot, (t, fresh) => {
        // What is no longer, or is to move, gives up its marker; and markers nothing has are let go.
        if (gc) for (const m of gc) if (text.has(t, m)) text.remove(t, m, 1, fresh);
        garbage.delete(key);
        for (const h of was.keys()) if (!kept.has(h)) text.remove(t, wheres.get(ownId.get(h)!)!.marker, 1, fresh);
        for (let k = 0; k < seq.length; k++) if (!stay[k] && was.has(seq[k])) text.remove(t, wheres.get(ownId.get(seq[k])!)!.marker, 1, fresh);
        let prev = a > 0 ? wheres.get(oldIds[a - 1])!.marker : "";
        let k = 0;
        while (k < seq.length) {
          if (stay[k]) {
            prev = wheres.get(ownId.get(seq[k])!)!.marker;
            k++;
          } else {
            let j = k;
            while (j < seq.length && !stay[j]) j++;
            const first = text.after(t, prev, MARK.repeat(j - k), fresh);
            for (let m = k; m < j; m++) markers.set(seq[m], nextMarker(first, m - k));
            prev = markers.get(seq[j - 1])!;
            k = j;
          }
        }
      });
      for (const h of was.keys()) if (!kept.has(h)) deleteRow(ownId.get(h)!);
      for (let k = 0; k < seq.length; k++) {
        const h = seq[k];
        const item = nw[a + k];
        const m = markers.get(h);
        const where = m !== undefined ? whereEncode(owner, field, ITEM, m) : undefined;
        if (!was.has(h)) make(of, item, where!);
        else writeMap(of, was.get(h), item, ownId.get(h)!, false, where);
      }
    };

    // A tree: every node where the new one has it, those not in it gone with all in them, and new ones made.
    const writeTree = (
      b: TreeSchema,
      old: readonly Obj[] | undefined,
      nw: readonly any[],
      owner: string,
      field: string,
      key: string,
      st: Extract<BoxState, { kind: "tree" }> | undefined,
    ): void => {
      const kids = st ? st.kids : new Map<string, string[]>();
      const up = st ? st.up : new Map<string, string>();
      const sits = st ? st.sits : new Map<string, string>();
      // What was there, by its own id; and the ids an application has, for the same.
      const was = new Map<string, Obj>();
      const byHex = new Map<string, string>();
      const walk = (level: readonly Obj[] | undefined): void => {
        for (const n of level ?? NONE) {
          const id = binaryOf(n.id);
          byHex.set(n.id, id);
          was.set(id, n);
          walk(n.children);
        }
      };
      walk(old);
      const idOf = (n: any): string | undefined => (typeof n === "object" && n !== null && typeof n.id === "string" ? byHex.get(n.id) : undefined);
      const kept = new Set<string>();
      const mark = (level: readonly any[] | undefined): void => {
        for (const n of level ?? NONE) {
          const id = idOf(n);
          if (id !== undefined) kept.add(id);
          if (typeof n === "object" && n !== null) mark(n.children);
        }
      };
      mark(nw);
      for (const id of kept) spared.add(id);
      const gone = new Map<string, string[]>(); // markers to let go, by the row whose order they are in
      const letGo = (parent: string, marker: string): void => {
        const row = parent === ZERO ? owner : parent;
        let g = gone.get(row);
        if (!g) gone.set(row, (g = []));
        g.push(marker);
      };
      for (const id of members.get(key) ?? NONE) {
        const w = wheres.get(id);
        if (!kept.has(id) && w && (was.has(id) || deadRows.has(w.parent))) {
          const u = up.get(id);
          if (u !== undefined && sits.get(id) !== "" && alive(u === ZERO ? owner : u)) letGo(u, sits.get(id)!);
          deleteRow(id);
        }
      }
      // Where each kept node is to be, to see which move.
      const target = new Map<string, string>();
      const aim = (level: readonly any[] | undefined, parent: string): void => {
        for (const n of level ?? NONE) {
          const id = idOf(n);
          const k = id !== undefined && kept.has(id);
          if (k) target.set(id, parent);
          aim(n?.children, k ? id : "\x01");
        }
      };
      aim(nw, ZERO);
      for (const [id, p] of target) {
        const u = up.get(id), s = sits.get(id);
        if (u !== undefined && u !== p && s !== undefined && s !== "") letGo(u, s);
      }
      const placed = new Set<string>();
      const place = (level: readonly any[] | undefined, parent: string): void => {
        const row = parent === ZERO ? owner : parent;
        const lv = level ?? NONE;
        const seq: string[] = [];
        const before = new Map<string, number>();
        const siblings = kids.get(parent) ?? NONE;
        for (let i = 0; i < siblings.length; i++) {
          // One without a marker of its own, or sharing one, is given one.
          const s = sits.get(siblings[i]);
          if (s !== "" && !(i > 0 && sits.get(siblings[i - 1]) === s)) before.set(siblings[i], i);
        }
        for (let i = 0; i < lv.length; i++) {
          const id = idOf(lv[i]);
          if (id !== undefined && kept.has(id) && !placed.has(id)) {
            placed.add(id);
            seq.push(id);
          } else {
            seq.push("\x01" + i);
          }
        }
        let same = !plain && !gone.has(row) && seq.length === siblings.length;
        for (let i = 0; same && i < seq.length; i++) same = before.get(seq[i]) === i;
        const markers = new Map<string, string>();
        if (!same) {
          const stay = staying(seq, before);
          change.edit(hex(row), b.slot, (t, fresh) => {
            for (const m of gone.get(row) ?? NONE) text.remove(t, m, 1, fresh);
            gone.delete(row);
            for (let i = 0; i < seq.length; i++) if (!stay[i] && before.has(seq[i])) text.remove(t, sits.get(seq[i])!, 1, fresh);
            let prev = "";
            let i = 0;
            while (i < seq.length) {
              if (stay[i]) {
                prev = sits.get(seq[i])!;
                i++;
              } else {
                let j = i;
                while (j < seq.length && !stay[j]) j++;
                const first = text.after(t, prev, MARK.repeat(j - i), fresh);
                for (let k = i; k < j; k++) markers.set(seq[k], nextMarker(first, k - i));
                prev = markers.get(seq[j - 1])!;
                i = j;
              }
            }
          });
        }
        for (let i = 0; i < seq.length; i++) {
          const id = seq[i];
          const n = lv[i];
          const marker = markers.get(id);
          if (!was.has(id)) {
            const made = make(b.of, n, whereEncode(owner, field, NODE, parent + marker! + ZERO + NOWHERE));
            place(n?.children, made);
          } else {
            let where: Uint8Array | undefined;
            const w = wheres.get(id);
            if (marker === undefined && w && (w.parent !== parent || w.marker !== sits.get(id))) {
              // It shows where it does because a move of it was undone: it is written there, so that it stays there
              // whatever becomes of where it was moved to.
              where = whereEncode(owner, field, NODE, parent + sits.get(id)! + ZERO + NOWHERE);
            }
            if (marker !== undefined) {
              // Where it came from goes with it: should this make a loop, it goes back.
              const u = up.get(id), s = sits.get(id);
              const back = u !== undefined && s !== "" ? s! : NOWHERE;
              where = whereEncode(owner, field, NODE, parent + marker + (u ?? ZERO) + back);
            }
            writeMap(b.of, was.get(id), n, id, false, where);
            place(n.children, id);
          }
        }
      };
      place(nw, ZERO);
      for (const [row, markers] of gone) {
        if (alive(row)) {
          change.edit(hex(row), b.slot, (t, fresh) => {
            for (const m of markers) text.remove(t, m, 1, fresh);
          });
        }
      }
    };

    const root = derive("");
    const exists = alive(root) !== undefined && wheres.has(root);
    if (!exists) {
      change.set(hex(root), schema.writing, { [W]: whereEncode(ZERO, "", MAP) });
      change.place(hex(root), list, 0);
    }
    // What is in the document is there whether its own row is or not, so what is written is what differs from that.
    writeMap(schema, current, state as Obj, root, !exists);
    // What others put in keys that were being let go of meanwhile goes too; but not a map within it, which is that
    // key's for ever, and only emptied.
    const empty = (id: string): void => {
      for (const k of owned.get(id) ?? NONE) {
        for (const m of members.get(k) ?? NONE) {
          const w = wheres.get(m);
          if (w && w.kind === MAP) empty(m);
          else deleteRow(m);
        }
      }
    };
    for (const id of emptied) empty(id);
    // What others put in rows that were being deleted meanwhile is let go of too.
    for (const id of deadRows) {
      for (const k of owned.get(id) ?? NONE) for (const m of members.get(k) ?? NONE) deleteRow(m);
      for (const m of hangs.get(id) ?? NONE) deleteRow(m);
    }
    // And what is beneath a deleted node only where loops are undone, which shows nowhere and never will. What is beneath
    // a node that has not come yet waits for it.
    for (const key of losing) {
      const st = boxes.get(key);
      if (st && st.kind === "tree") for (const [id, missing] of st.lost) if (deadRows.has(missing)) deleteRow(id);
    }
  };

  const mirror: Mirror<S> = Object.freeze({
    get state(): Doc<S> {
      return current as Doc<S>;
    },
    get status(): "loading" | "ready" {
      return client.ready ? "ready" : "loading";
    },
    set,
    update(f: (draft: Draft<S>) => void): Promise<void> {
      // From the state as it is now, with all that has come read: a draft of an older one would write it back.
      if (heldOnly) throw new Error("what is asked about is read, not written");
      if (stopped) throw new Error("the document is closed");
      refresh();
      const drafts = new Drafts();
      const d = drafts.map(schema, current, undefined);
      f(d as unknown as Draft<S>);
      return set(drafts.finishMap(d, schema, undefined) as Input<S>);
    },
    close(): void {
      if (stopped) return;
      stopped = true;
      unfollow();
      watching?.stop();
    },
  });
  return { mirror, refresh, derive, mark: (id) => void dirtyRows.add(id), current: () => current };
}

// ---------------------------------------------------------------- asking

/**
 * The path of a list, record or tree in a document: names of fields; a record's key, or an item's or node's id, after the
 * name of what holds it. As ["tasks"], ["people", "ann", "pets"], ["tasks", id, "steps"].
 */
export type Path<S extends MapSchema<any>> = S extends MapSchema<infer F> ? PathIn<F> : never;
type PathIn<F> = {
  [K in keyof F & string]: F[K] extends MapSchema<infer G>
    ? readonly [K, ...PathIn<G>]
    : F[K] extends { readonly kind: "list" | "record" | "tree"; readonly of: MapSchema<infer G> }
      ? readonly [K] | readonly [K, string, ...PathIn<G>]
      : F[K] extends RecordSchema<any>
        ? readonly [K]
        : never; // a list of values is in one row: it is read, not asked about
}[keyof F & string];

/** What is at a path: the list, record or tree. */
export type At<S extends MapSchema<any>, P> = S extends MapSchema<infer F> ? BoxAt<F, P> : never;
type BoxAt<F, P> = P extends readonly [infer K extends keyof F, ...infer R]
  ? R extends readonly []
    ? F[K]
    : F[K] extends MapSchema<infer G>
      ? BoxAt<G, R>
      : R extends readonly [string, ...infer R2]
        ? F[K] extends { readonly of: MapSchema<infer G> }
          ? BoxAt<G, R2>
          : never
        : never
  : never;

// Fields of rows of their own, which are asked about by their paths rather than given with what holds them.
type OfRows<F> = { [K in keyof F]: F[K] extends RecordSchema<any> | TreeSchema<any> | ListSchema<MapSchema<any>> ? K : never }[keyof F];
type GivenField<X> = X extends MapSchema<infer G> ? GivenMap<G> : FieldDoc<X>;
type GivenMap<F> = Flat<
  { readonly id: string } & { readonly [K in Exclude<Always<F>, OfRows<F>>]: GivenField<F[K]> } & {
    readonly [K in Exclude<keyof F, Always<F>>]?: FieldDoc<F[K]>;
  }
>;
type GivenNode<N> = N extends MapSchema<infer F> ? Flat<GivenMap<F> & { readonly children: readonly GivenNode<N>[] }> : never;

/**
 * What is given of each row that answers: its map, with what is in its own row and in its maps, and a node's children;
 * not its own lists, records and trees of rows. A record of values gives its values.
 */
export type Given<B> =
  B extends ListSchema<infer O>
    ? O extends MapSchema<infer F>
      ? GivenMap<F>
      : never
    : B extends RecordSchema<infer O>
      ? O extends MapSchema<infer F>
        ? GivenMap<F>
        : ValueOf<O>
      : B extends TreeSchema<infer N>
        ? GivenNode<N>
        : never;

/** What is asked of what is at a path. */
export interface Asked {
  /** Conditions on the columns of what is asked about, by their names, or `value` in a record of values: `where`. */
  readonly where?: Condition;
  /** As a question's: "newest" unless said; a column's name, after a minus for the greatest first; "best", "oldest". */
  readonly order?: readonly string[];
  readonly offset?: number;
  /** 50 unless said. */
  readonly limit?: number;
  readonly fromEnd?: boolean;
  readonly totals?: { readonly [name: string]: Total };
}

/** What a node finds, as the document shows it. */
export interface Found<B = Schema> {
  /** What answers, in the order asked for: each as the document shows it. */
  readonly rows: readonly Given<B>[];
  /** Of a record: whose each row is, by its key. */
  readonly keys: B extends RecordSchema<any> ? readonly string[] : undefined;
  readonly status: Answer["status"];
  /** What a node counts, given or not, */
  readonly total: number;
  /** and how many of those come before these. */
  readonly first: number;
  readonly totals: Answer["totals"];
}

// What is at a path, and how it is reached.
interface Place {
  owner: string; // the row that holds it
  field: string;
  box: ListSchema | RecordSchema | TreeSchema;
  chain: string[]; // the rows on the way to it, the document's first
  trees: { owner: string; field: string }[]; // trees on the way, or it, all of whose nodes are needed to know which are there
}

const ID = /^[0-9a-f]{32}$/;

function placeOf(schema: MapSchema, path: readonly string[], derive: (parts: string) => string): Place {
  if (!Array.isArray(path) || path.length === 0) throw new Error("a path names what is asked about");
  let s = schema;
  let owner = derive("");
  const chain = [owner], trees: Place["trees"] = [];
  for (let i = 0; ; ) {
    const name = path[i];
    const at = typeof name === "string" ? s.at.get(name) : undefined;
    const b = at !== undefined ? s.boxes[at] : undefined;
    if (at === undefined || !b) throw new Error(`there is no ${String(name)} to ask about`);
    const field = s.keys[at];
    if (b.kind === "map") {
      if (i === path.length - 1) throw new Error("a map is not asked about, but what is in it");
      owner = derive(owner + "\0" + field);
      chain.push(owner);
      s = b;
      i++;
    } else if (i === path.length - 1) {
      if (b.kind === "list" && !isMap(b.of)) throw new Error("a list of values is in one row: it is read, not asked about");
      if (b.kind === "tree") trees.push({ owner, field });
      return { owner, field, box: b, chain, trees };
    } else {
      if (!isMap(b.of)) throw new Error(`what is in ${name} holds nothing`);
      const k = path[i + 1];
      if (typeof k !== "string") throw new Error(`${name} is followed by a key or an id`);
      // An item or a node by its id, in hex, as the document has it.
      if (b.kind !== "record" && !ID.test(k)) throw new Error(`${k} is no id of what is in ${name}`);
      const id = b.kind === "record" ? derive(owner + "\0" + field + "\0" + keyBytes(k)) : binaryOf(k);
      if (b.kind === "tree") trees.push({ owner, field });
      chain.push(id);
      owner = id;
      s = b.of;
      i += 2;
    }
  }
}

// What a path comes to in a state: the list, record or tree, if it is there.
function atPath(schema: MapSchema, state: Obj, path: readonly string[]): unknown {
  const find = (level: readonly Obj[] | undefined, id: string): Obj | undefined => {
    for (const n of level ?? NONE) {
      if (n.id === id) return n;
      const inside = n.children ? find(n.children, id) : undefined;
      if (inside) return inside;
    }
    return undefined;
  };
  let s = schema;
  let v: any = state;
  let i = 0;
  while (v !== undefined && i < path.length) {
    const name = path[i];
    const b = s.boxes[s.at.get(name)!]!;
    v = v[name];
    if (b.kind === "map") {
      s = b;
      i++;
    } else if (i === path.length - 1) {
      return v;
    } else {
      const k = path[i + 1];
      v = v === undefined ? undefined : b.kind === "record" ? own(v, k) : find(v, k);
      s = b.of as MapSchema;
      i += 2;
    }
  }
  return v;
}

const BYTES_COLUMN: Column<Uint8Array> = Object.freeze({ slot: WHERE, text: false, is: "bytes", encode: same, decode: same });
const BY_WHERE: Table = Object.freeze({ [W]: BYTES_COLUMN });

// Whether what is under a name is of rows of its own, which are asked about by their path rather than given with what holds them.
function ofRows(b: Schema): boolean {
  return b.kind === "record" || b.kind === "tree" || (b.kind === "list" && isMap(b.of));
}

// The ids of the maps within a map, and within those, made from its id.
function mapsWithin(s: MapSchema, id: string, derive: (parts: string) => string, into: string[]): void {
  for (let i = 0; i < s.names.length; i++) {
    const b = s.boxes[i];
    if (b && b.kind === "map") {
      const inner = derive(id + "\0" + s.keys[i]);
      into.push(inner);
      mapsWithin(b, inner, derive, into);
    }
  }
}

const KIND_OF = { list: ITEM, record: ENTRY, tree: NODE } as const;
const LOADING: Found<any> = Object.freeze({ rows: NONE, keys: undefined, status: "loading", total: 0, first: 0, totals: Object.freeze({}) });

/**
 * What is in a list, record or tree of a document, as a node finds it: the rows that answer, as the maps (or values) the
 * document shows, in the order asked for, and kept up as they change. Nothing needs to be open, nor is anything more held
 * than the rows on the way and those that answer, and for a tree all its nodes. A list's items are found by what their
 * rows say they are in; whether they are, the rows on the way say, as they do when the document is open: what a node
 * finds that the document would not show (rows written by one who minds nothing, or in what was deleted and not yet let
 * go of) is not given, though a node counts it in `total` and `totals`. For a record, `keys` says whose each is.
 *
 * The observer hears at once, and again whenever what is given, or what is counted, changes. Returns ways to look at
 * another stretch of it, and to stop.
 */
export function ask<S extends MapSchema<any>, const P extends Path<S>>(
  client: Client,
  options: { scope: number; name: string; schema: S },
  path: P,
  asking: Asked,
  observer: (found: Found<At<S, P>>) => void,
): Asking {
  const { scope, schema } = options;
  if (schema?.kind !== "map") throw new Error("a document is a map");
  const steps: readonly string[] = path;
  const kind = placeOf(schema, steps, () => ZERO).box.kind; // or an error, here rather than later
  const list = "mirror/" + options.name;
  const doc = opened(client, options, undefined, true);
  const say = observer as (found: Found<any>) => void;
  let stopped = false;
  // What is given of a map: what is in its own row and its maps, its children if it is a node; not its lists, records and
  // trees of rows. The same object for the same map.
  const given = new WeakMap<Obj, Obj>();
  const give = (s: MapSchema, v: Obj, tree: TreeSchema | undefined): Obj => {
    let out = given.get(v);
    if (out) return out;
    const made: Record<string, unknown> = {};
    for (const k of Object.keys(v)) {
      const at = s.at.get(k);
      const b = at !== undefined ? s.boxes[at] : undefined;
      if (k === "children" && tree) made.children = Object.freeze((v.children as readonly Obj[]).map((n) => give(tree.of, n, tree)));
      else if (b && b.kind === "map") made[k] = give(b, v[k], undefined);
      else if (!(b && ofRows(b))) made[k] = v[k];
    }
    out = Object.freeze(made);
    given.set(v, out);
    return out;
  };
  const questions: Asking[] = []; // what is asked, to be stopped
  const answers = new Map<string, Answer<any>>(); // the latest of each: what answers, the rows on the way, all of a tree's nodes, the maps within
  let place: Place | undefined;
  let last: Found<any> = kind === "record" ? Object.freeze({ ...LOADING, keys: NOBODY }) : LOADING;
  let wasNamed = new Set<string>();

  const tell = (): void => {
    if (stopped || !place) return;
    const p = place;
    // What the answers name is read again, come or gone: a row held already is not necessarily sent again.
    const named = new Set<string>();
    for (const a of answers.values()) {
      for (const r of a.rows) {
        const id = binaryOf(r.id);
        named.add(id);
        doc.mark(id);
      }
    }
    for (const id of wasNamed) if (!named.has(id)) doc.mark(id);
    wasNamed = named;
    doc.refresh();
    const found = answers.get("found");
    // What the document shows there, by row id.
    const shown = new Map<string, unknown>();
    const keyOf = new Map<string, string>();
    const box = atPath(schema, doc.current(), steps);
    if (p.box.kind === "record") {
      for (const k of Object.keys((box as Obj | undefined) ?? {})) {
        const id = codec.hex(doc.derive(p.owner + "\0" + p.field + "\0" + keyBytes(k)));
        shown.set(id, (box as Obj)[k]);
        keyOf.set(id, k);
      }
    } else {
      const walk = (level: readonly Obj[] | undefined): void => {
        for (const n of level ?? NONE) {
          shown.set(n.id, n);
          if (n.children) walk(n.children);
        }
      };
      walk(box as readonly Obj[] | undefined);
    }
    const of = p.box.of;
    const tree = p.box.kind === "tree" ? p.box : undefined;
    // And the maps within each map given, which are there whether their rows are or not, but say what they hold: of each
    // that answers, and of a tree's, of every node beneath it, for those are given with it.
    if (isMap(of)) {
      const ids: string[] = [];
      const within = (id: string): void => {
        mapsWithin(of, binaryOf(id), doc.derive, ids);
        const n = tree && (shown.get(id) as Obj | undefined);
        for (const c of n ? ((n.children as readonly Obj[] | undefined) ?? NONE) : NONE) within(c.id);
      };
      for (const r of found ? found.rows : NONE) within(r.id);
      withinMaps(ids); // which may tell, before this goes on with what it then is
    }
    let status: Found["status"] = found ? found.status : "loading";
    for (const a of answers.values()) {
      if (a.status !== "ready" && status === "ready") status = a.status === "denied" || a.status === "faulty" ? a.status : "loading";
    }
    const rows: unknown[] = [], keys: string[] = [];
    for (const r of found ? found.rows : NONE) {
      const v = shown.get(r.id);
      if (v !== undefined) {
        rows.push(isMap(of) ? give(of, v as Obj, tree) : v);
        const k = keyOf.get(r.id);
        if (k !== undefined) keys.push(k);
      }
    }
    const answer: Found<any> = Object.freeze({
      rows: Object.freeze(rows),
      keys: p.box.kind === "record" ? Object.freeze(keys) : undefined,
      status,
      total: found ? found.total : 0,
      first: found ? found.first : 0,
      totals: found ? found.totals : LOADING.totals,
    });
    if (
      last.status === answer.status &&
      last.total === answer.total &&
      last.first === answer.first &&
      (last.totals === answer.totals || (Object.keys(last.totals).length === 0 && Object.keys(answer.totals).length === 0)) &&
      sameList(last.rows, answer.rows) &&
      (last.keys === answer.keys || sameList(last.keys, answer.keys!))
    ) {
      return;
    }
    last = answer;
    say(answer);
  };

  // Rows asked for by id, a thousand to a question, asked again only when they change.
  let byId: Asking[] = [];
  let byIdOf = "";
  const withinMaps = (ids: string[]): void => {
    ids.sort();
    const now = ids.join("");
    if (now === byIdOf) return;
    byIdOf = now;
    for (const q of byId) q.stop();
    byId = [];
    for (const k of [...answers.keys()]) if (k.startsWith("maps ")) answers.delete(k);
    for (let n = 0; n * 1000 < ids.length; n++) {
      const part = ids.slice(n * 1000, (n + 1) * 1000).map((id) => codec.hex(id));
      byId.push(
        client.ask({ scope, table: BY_WHERE, where: where.ids(part), limit: 1000 }, (a) => {
          answers.set(`maps ${n}`, a);
          tell();
        }),
      );
    }
  };

  let found: Asking | undefined;
  let stretch = { offset: asking.offset, limit: asking.limit }; // as last moved to, which is asked once it can be
  const start = (): boolean => {
    if (place || stopped) return true;
    if (!client.scopeKey(scope)) return false;
    const p = placeOf(schema, steps, doc.derive);
    place = p;
    const b = p.box;
    const columns: Record<string, Column<any>> = { [W]: BYTES_COLUMN };
    if (isMap(b.of)) {
      for (let i = 0; i < b.of.names.length; i++) {
        const c = b.of.columns[i];
        if (c) columns[b.of.names[i]] = c;
      }
    } else {
      columns.value = b.of;
    }
    const within = whereEncode(p.owner, p.field, KIND_OF[b.kind], b.kind === "record" ? "\x01" : "");
    found = client.ask(
      {
        scope,
        table: columns,
        where: where.all(where.inList(list), where.begins(W, within), asking.where ?? where.all()),
        order: asking.order,
        offset: stretch.offset,
        limit: stretch.limit,
        fromEnd: asking.fromEnd,
        totals: asking.totals,
      },
      (a) => {
        answers.set("found", a);
        tell();
      },
    );
    questions.push(found);
    // The rows on the way: whether what answers is there is theirs to say.
    questions.push(
      client.ask({ scope, table: BY_WHERE, where: where.ids(p.chain.map((id) => codec.hex(id))), limit: 1000 }, (a) => {
        answers.set("chain", a);
        tell();
      }),
    );
    // Every node of a tree on the way: which are there, and where, is known only from all of them.
    p.trees.forEach((t, i) => {
      const pages = new Set<number>();
      const page = (n: number): void => {
        pages.add(n);
        questions.push(
          client.ask(
            {
              scope,
              table: BY_WHERE,
              where: where.all(where.inList(list), where.begins(W, whereEncode(t.owner, t.field, NODE))),
              offset: n * 1000,
              limit: 1000,
            },
            (a) => {
              answers.set(`tree ${i} ${n}`, a);
              for (let k = n + 1; k * 1000 < a.total; k++) if (!pages.has(k)) page(k);
              tell();
            },
          ),
        );
      };
      page(0);
    });
    return true;
  };

  // Ids are made with the scope's key: what is on the way is known once that is.
  say(last);
  let unwait: (() => void) | undefined;
  if (!start()) {
    let started = false;
    const off = client.on("status", () => {
      if (started || !start()) return;
      started = true;
      unwait?.();
      unwait = undefined;
    });
    if (!started) unwait = off;
    else off();
  }

  return Object.freeze({
    // Another stretch of what answers.
    move(offset: number, limit?: number): void {
      stretch = { offset, limit: limit ?? stretch.limit };
      found?.move(offset, limit);
    },
    stop(): void {
      if (stopped) return;
      stopped = true;
      unwait?.();
      unwait = undefined;
      for (const q of questions) q.stop();
      for (const q of byId) q.stop();
      doc.mirror.close();
    },
  });
}

// ---------------------------------------------------------------- drafts

// A draft is the state as it is, until something in it is changed: then that, and what leads to it, is copied. So what
// was not changed is the very same object, and costs nothing to write. Lists are drafted as they are used: what reads
// an item copies nothing, and what changes a list copies the array, not what is in it.

const STATE = Symbol("draft");
const DELETED: unique symbol = Symbol("deleted");

interface MapDraftState {
  kind: "map";
  drafts: Drafts;
  orig: Obj;
  schema: MapSchema;
  tree: TreeSchema | undefined; // of a node: its children are of this
  writes: Map<string, unknown> | undefined; // what has been done to it
  kids: Map<string, object> | undefined; // drafts of what is in it, as they were read
  done: Obj | undefined;
}

interface ListDraftState {
  kind: "list";
  drafts: Drafts;
  orig: readonly unknown[];
  elem: MapSchema | undefined; // of maps, or of nodes; or of values
  tree: TreeSchema | undefined;
  target: unknown[]; // once changed, what it is: what was there as it was, and whatever has been put in it
  copied: boolean;
  touched: Set<number> | undefined; // until then, the items read
  was?: Set<unknown>; // of values, what it held that may be changed in place
}

interface RecordDraftState {
  kind: "record";
  drafts: Drafts;
  orig: Obj;
  of: Of;
  writes: Map<string, unknown> | undefined;
  touched: Set<string> | undefined;
}

type DraftState = MapDraftState | ListDraftState | RecordDraftState;

function stateOf(v: unknown): DraftState | undefined {
  return typeof v === "object" && v !== null ? ((v as { [STATE]?: DraftState })[STATE] ?? undefined) : undefined;
}

// A string that names an item of an array, as a number; -1 if it names none.
function indexOfKey(key: string): number {
  const n = key.length;
  if (n === 0 || n > 10) return -1;
  const c = key.charCodeAt(0);
  if (c < 48 || c > 57 || (c === 48 && n > 1)) return -1;
  let v = 0;
  for (let i = 0; i < n; i++) {
    const d = key.charCodeAt(i) - 48;
    if (d < 0 || d > 9) return -1;
    v = v * 10 + d;
  }
  return v < 4294967295 ? v : -1;
}

const field = (value: unknown): PropertyDescriptor => ({ value, writable: true, enumerable: true, configurable: true });

const mapHandler: ProxyHandler<{ [STATE]: MapDraftState }> = {
  get(target, key, receiver) {
    const st = target[STATE];
    if (typeof key !== "string") return key === STATE ? st : Reflect.get(target, key, receiver);
    return st.drafts.mapGet(st, key);
  },
  set(target, key, value) {
    if (typeof key !== "string") return Reflect.set(target, key, value);
    const st = target[STATE];
    (st.writes ??= new Map()).set(key, value);
    return true;
  },
  defineProperty(target, key, desc) {
    if (typeof key !== "string" || !("value" in desc)) return Reflect.defineProperty(target, key, desc);
    const st = target[STATE];
    (st.writes ??= new Map()).set(key, desc.value);
    return true;
  },
  deleteProperty(target, key) {
    if (typeof key !== "string") return Reflect.deleteProperty(target, key);
    const st = target[STATE];
    (st.writes ??= new Map()).set(key, DELETED);
    return true;
  },
  has(target, key) {
    if (typeof key !== "string") return key !== STATE && Reflect.has(target, key);
    const st = target[STATE];
    const w = st.writes?.get(key);
    return w !== undefined ? w !== DELETED : st.writes?.has(key) ? false : key in st.orig;
  },
  ownKeys(target) {
    const st = target[STATE];
    const keys = new Set(Object.keys(st.orig));
    if (st.writes) for (const [k, w] of st.writes) w === DELETED || w === undefined ? keys.delete(k) : keys.add(k);
    return [...keys];
  },
  getOwnPropertyDescriptor(target, key) {
    if (typeof key !== "string") return key === STATE ? undefined : Reflect.getOwnPropertyDescriptor(target, key);
    const st = target[STATE];
    const v = st.drafts.mapGet(st, key);
    return v !== undefined || Object.hasOwn(st.orig, key) || st.writes?.has(key) ? field(v) : undefined;
  },
};

const recordHandler: ProxyHandler<{ [STATE]: RecordDraftState }> = {
  get(target, key) {
    const st = target[STATE];
    if (typeof key !== "string") return key === STATE ? st : undefined;
    return st.drafts.recordGet(st, key);
  },
  set(target, key, value) {
    if (typeof key !== "string") return false;
    const st = target[STATE];
    (st.writes ??= new Map()).set(key, value);
    return true;
  },
  defineProperty(target, key, desc) {
    if (typeof key !== "string" || !("value" in desc)) return false;
    const st = target[STATE];
    (st.writes ??= new Map()).set(key, desc.value);
    return true;
  },
  deleteProperty(target, key) {
    if (typeof key !== "string") return true;
    const st = target[STATE];
    (st.writes ??= new Map()).set(key, DELETED);
    return true;
  },
  has(target, key) {
    if (typeof key !== "string") return false;
    return target[STATE].drafts.recordGet(target[STATE], key) !== undefined;
  },
  ownKeys(target) {
    const st = target[STATE];
    const keys = new Set(Object.keys(st.orig));
    if (st.writes) for (const [k, w] of st.writes) w === DELETED || w === undefined ? keys.delete(k) : keys.add(k);
    return [...keys];
  },
  getOwnPropertyDescriptor(target, key) {
    if (typeof key !== "string") return undefined;
    const v = target[STATE].drafts.recordGet(target[STATE], key);
    return v !== undefined ? field(v) : undefined;
  },
};

// What changes a list, done to the array it then is: at once, rather than an item at a time through the proxy.
type Listy = { [STATE]: ListDraftState };
function changed(self: Listy): unknown[] {
  const st = self[STATE];
  if (!st.copied) {
    st.copied = true;
    st.touched = undefined;
    for (const x of st.orig) st.target.push(x);
  }
  return st.target;
}
const LIST_METHODS: { readonly [name: string]: Function } = Object.assign(Object.create(null), {
  push(this: Listy, ...items: unknown[]) {
    return changed(this).push(...items);
  },
  pop(this: Listy) {
    const st = this[STATE];
    return st.drafts.item(st, changed(this).pop());
  },
  shift(this: Listy) {
    const st = this[STATE];
    return st.drafts.item(st, changed(this).shift());
  },
  unshift(this: Listy, ...items: unknown[]) {
    return changed(this).unshift(...items);
  },
  splice(this: Listy, ...args: [number, number, ...unknown[]]) {
    const st = this[STATE];
    return changed(this)
      .splice(...args)
      .map((x) => st.drafts.item(st, x));
  },
  sort(this: Listy, compare?: (x: unknown, y: unknown) => number) {
    const st = this[STATE];
    const t = changed(this);
    if (compare) t.sort((x, y) => compare(st.drafts.item(st, x), st.drafts.item(st, y)));
    else t.sort();
    return this;
  },
  reverse(this: Listy) {
    changed(this).reverse();
    return this;
  },
  fill(this: Listy, value: unknown, start?: number, end?: number) {
    changed(this).fill(value, start, end);
    return this;
  },
  copyWithin(this: Listy, at: number, start: number, end?: number) {
    changed(this).copyWithin(at, start, end);
    return this;
  },
});

const listHandler: ProxyHandler<unknown[] & Listy> = {
  get(target, key, receiver) {
    const st = target[STATE];
    if (typeof key === "string") {
      const i = indexOfKey(key);
      if (i >= 0) return st.drafts.listGet(st, i);
      if (key === "length") return st.copied ? target.length : st.orig.length;
      const m = LIST_METHODS[key];
      if (m) return m;
    } else if (key === STATE) {
      return st;
    }
    return Reflect.get(target, key, receiver);
  },
  set(target, key, value) {
    if (typeof key === "string") changed(target);
    return Reflect.set(target, key, value);
  },
  defineProperty(target, key, desc) {
    if (typeof key === "string") changed(target);
    return Reflect.defineProperty(target, key, desc);
  },
  deleteProperty(target, key) {
    if (typeof key === "string") changed(target);
    return Reflect.deleteProperty(target, key);
  },
  has(target, key) {
    const st = target[STATE];
    if (typeof key === "string" && !st.copied) {
      const i = indexOfKey(key);
      if (i >= 0) return i < st.orig.length;
    }
    return key !== STATE && Reflect.has(target, key);
  },
  ownKeys(target) {
    const st = target[STATE];
    if (st.copied) return Reflect.ownKeys(target).filter((k) => k !== STATE);
    const keys: string[] = [];
    for (let i = 0; i < st.orig.length; i++) keys.push(String(i));
    keys.push("length");
    return keys;
  },
  getOwnPropertyDescriptor(target, key) {
    const st = target[STATE];
    if (key === STATE) return undefined;
    if (typeof key === "string" && !st.copied) {
      const i = indexOfKey(key);
      if (i >= 0) return i < st.orig.length ? field(st.drafts.listGet(st, i)) : undefined;
      if (key === "length") return { value: st.orig.length, writable: true, enumerable: false, configurable: false };
    }
    const d = Reflect.getOwnPropertyDescriptor(target, key);
    if (d && typeof key === "string" && indexOfKey(key) >= 0) d.value = st.drafts.listGet(st, indexOfKey(key));
    return d;
  },
};

// The drafts of one update, and what each comes to.
class Drafts {
  // Drafts of the items of lists and records, by what each is a draft of: so an item read twice, or moved, is one draft.
  #of = new Map<object, object>();

  map(s: MapSchema, orig: Obj, tree: TreeSchema | undefined): object {
    const st: MapDraftState = { kind: "map", drafts: this, orig, schema: s, tree, writes: undefined, kids: undefined, done: undefined };
    return new Proxy({ [STATE]: st }, mapHandler);
  }

  #box(b: Schema, v: object): object {
    if (b.kind === "map") return this.map(b, v as Obj, undefined);
    if (b.kind === "record") {
      const st: RecordDraftState = { kind: "record", drafts: this, orig: v as Obj, of: b.of, writes: undefined, touched: undefined };
      return new Proxy({ [STATE]: st }, recordHandler);
    }
    const elem = b.kind === "tree" ? b.of : isMap(b.of) ? b.of : undefined;
    const target = [] as unknown as unknown[] & Listy;
    target[STATE] = { kind: "list", drafts: this, orig: v as unknown[], elem, tree: b.kind === "tree" ? b : undefined, target, copied: false, touched: undefined };
    return new Proxy(target, listHandler);
  }

  // An item as a draft hands it out: one that was there is drafted, and anything else is as it was put there.
  item(st: ListDraftState, x: unknown): unknown {
    if (!st.elem || typeof x !== "object" || x === null || !built.has(x)) return x;
    let d = this.#of.get(x);
    if (!d) this.#of.set(x, (d = this.map(st.elem, x as Obj, st.tree)));
    return d;
  }

  mapGet(st: MapDraftState, key: string): unknown {
    const w = st.writes?.get(key);
    if (w !== undefined || st.writes?.has(key)) return w === DELETED ? undefined : w;
    const v = st.orig[key];
    const i = st.schema.at.get(key);
    const b = i !== undefined ? st.schema.boxes[i] : key === "children" ? st.tree : undefined;
    if (!b && i !== undefined && typeof v === "object" && v !== null && st.schema.columns[i]) {
      // What a column holds, JSON or bytes, may be changed in place in a draft: so it is a copy, which counts as written,
      // and is written if what it comes to is other than what it was.
      const copy = structuredClone(v);
      (st.writes ??= new Map()).set(key, copy);
      return copy;
    }
    if (!b || typeof v !== "object" || v === null || !built.has(v)) return v;
    let d = st.kids?.get(key);
    if (!d) (st.kids ??= new Map()).set(key, (d = this.#box(b, v)));
    return d;
  }

  listGet(st: ListDraftState, i: number): unknown {
    if (!st.elem) {
      // A value, JSON or bytes, that was there is handed out as a copy, as a map's are, for it may be changed in place:
      // the list is then the list with that copy in it, and is written if what it comes to is other than what it was.
      const x = st.copied ? st.target[i] : st.orig[i];
      if (typeof x !== "object" || x === null || !this.#was(st).has(x)) return x;
      const copy = structuredClone(x);
      changed(st.target as unknown as Listy)[i] = copy;
      return copy;
    }
    if (st.copied) return this.item(st, st.target[i]);
    const x = st.orig[i];
    if (typeof x === "object" && x !== null) (st.touched ??= new Set()).add(i);
    return this.item(st, x);
  }

  // What a list of values held, of which whatever is read is a copy.
  #was(st: ListDraftState): Set<unknown> {
    return (st.was ??= new Set(st.orig.filter((x) => typeof x === "object" && x !== null)));
  }

  recordGet(st: RecordDraftState, key: string): unknown {
    const w = st.writes?.get(key);
    if (w !== undefined || st.writes?.has(key)) return w === DELETED ? undefined : w;
    const v = own(st.orig, key);
    if (!isMap(st.of) && typeof v === "object" && v !== null) {
      // As a map's: a copy, which counts as written, and is written if what it comes to is other than what it was.
      const copy = structuredClone(v);
      (st.writes ??= new Map()).set(key, copy);
      return copy;
    }
    if (!isMap(st.of) || typeof v !== "object" || v === null || !built.has(v)) return v;
    (st.touched ??= new Set()).add(key);
    let d = this.#of.get(v);
    if (!d) this.#of.set(v, (d = this.map(st.of, v, undefined)));
    return d;
  }

  // ------------------------------------------------ what a draft comes to

  #finishDraft(st: MapDraftState): Obj {
    if (st.done) return st.done;
    const { orig, schema: s, tree, writes, kids } = st;
    if (!writes && !kids) return orig;
    const value = (name: string, b: Schema | undefined): unknown => {
      if (writes?.has(name)) {
        const w = writes.get(name);
        return w === DELETED ? undefined : b ? this.finish(w, b) : w;
      }
      const k = kids?.get(name);
      return k !== undefined ? this.finish(k, b!) : orig[name];
    };
    const n = s.names.length;
    const parts = new Array(n);
    let whole = true;
    for (let i = 0; i < n; i++) {
      parts[i] = value(s.names[i], s.boxes[i]);
      whole &&= Object.is(parts[i], orig[s.names[i]]);
    }
    const children = tree ? value("children", tree) : undefined;
    if (tree) whole &&= children === orig.children;
    if (whole) return (st.done = orig);
    const out: Record<string, unknown> = { id: orig.id };
    for (let i = 0; i < n; i++) if (parts[i] !== undefined) out[s.names[i]] = parts[i];
    if (children !== undefined) out.children = children;
    return (st.done = out);
  }

  // A map as it is to be written: a draft as it comes to, one made anew with what is in it come to too, and one that
  // was there as it was.
  finishMap(v: unknown, s: MapSchema, tree: TreeSchema | undefined): unknown {
    if (typeof v !== "object" || v === null) return v;
    const st = stateOf(v);
    if (st) return st.kind === "map" ? this.#finishDraft(st) : st.kind === "list" ? this.#finishList(st) : this.#finishRecord(st);
    const d = this.#of.get(v);
    if (d) return this.#finishDraft(stateOf(d) as MapDraftState);
    if (built.has(v)) return v;
    // Made anew; but what is in it may be drafts, moved there.
    let out: Record<string, unknown> | undefined;
    const o = v as Obj;
    for (let i = 0; i < s.names.length; i++) {
      const b = s.boxes[i];
      const x = b ? o[s.names[i]] : undefined;
      if (x === undefined) continue;
      const y = this.finish(x, b!);
      if (y !== x) (out ??= { ...o })[s.names[i]] = y;
    }
    if (tree && o.children !== undefined) {
      const y = this.finish(o.children, tree);
      if (y !== o.children) (out ??= { ...o }).children = y;
    }
    return out ?? v;
  }

  finish(v: unknown, b: Schema): unknown {
    if (b.kind === "map") return this.finishMap(v, b, undefined);
    if (typeof v !== "object" || v === null) return v;
    const st = stateOf(v);
    if (st?.kind === "list") return this.#finishList(st);
    if (st?.kind === "record") return this.#finishRecord(st);
    if (st?.kind === "map" || built.has(v)) return st ? this.#finishDraft(st) : v;
    if (b.kind === "record") {
      // Made anew: the same, unless what is in it was drafts.
      if (!isMap(b.of)) return v;
      let out: Record<string, unknown> | undefined;
      const o = v as Obj;
      for (const k of Object.keys(o)) {
        const y = this.finishMap(o[k], b.of, undefined);
        if (y !== o[k]) (out ??= Object.assign(Object.create(null), o) as Record<string, unknown>)[k] = y;
      }
      return out ?? v;
    }
    const elem = b.kind === "tree" ? b.of : isMap(b.of) ? b.of : undefined;
    if (!elem) return v;
    const tree = b.kind === "tree" ? b : undefined;
    const a = v as readonly unknown[];
    let out: unknown[] | undefined;
    for (let i = 0; i < a.length; i++) {
      const y = this.finishMap(a[i], elem, tree);
      if (y !== a[i]) (out ??= copy(a))[i] = y;
    }
    return out ?? v;
  }

  #finishList(st: ListDraftState): readonly unknown[] {
    const { orig, elem, tree } = st;
    if (!st.copied) {
      let out: unknown[] | undefined;
      for (const i of st.touched ?? NONE) {
        const y = this.finishMap(orig[i], elem!, tree);
        if (y !== orig[i]) (out ??= copy(orig))[i] = y;
      }
      return out ?? orig;
    }
    const work = st.target;
    const out = new Array(work.length);
    let whole = work.length === orig.length;
    for (let i = 0; i < work.length; i++) {
      const y = elem ? this.finishMap(work[i], elem, tree) : work[i];
      out[i] = y;
      whole &&= Object.is(y, orig[i]);
    }
    return whole ? orig : out;
  }

  #finishRecord(st: RecordDraftState): Obj {
    const { orig, of, writes, touched } = st;
    const ofMap = isMap(of) ? of : undefined;
    if (!writes) {
      let out: Record<string, unknown> | undefined;
      if (ofMap) {
        for (const k of touched ?? NONE) {
          const y = this.finishMap(orig[k], ofMap, undefined);
          if (y !== orig[k]) (out ??= Object.assign(Object.create(null), orig) as Record<string, unknown>)[k] = y;
        }
      }
      return out ?? orig;
    }
    const out: Record<string, unknown> = Object.create(null);
    let whole = true;
    for (const k of Object.keys(orig)) {
      if (writes.has(k)) continue;
      const y = ofMap ? this.finishMap(orig[k], ofMap, undefined) : orig[k];
      out[k] = y;
      whole &&= Object.is(y, orig[k]);
    }
    for (const [k, w] of writes) {
      if (w === DELETED || w === undefined) {
        whole &&= orig[k] === undefined;
        continue;
      }
      const y = ofMap ? this.finishMap(w, ofMap, undefined) : w;
      out[k] = y;
      whole &&= Object.is(y, orig[k]);
    }
    return whole ? orig : out;
  }
}
