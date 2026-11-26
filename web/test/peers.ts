// Clients that hear only each other, through a node made of nothing: what one writes is kept, as a node keeps it, and
// told to another as a node would tell it; and what one asks is answered, as SPEC.md 15 says, of what its node holds. As
// luau/tests/mirror_model.luau has them, for the mirror's tests.

import * as codec from "../src/codec.ts";
import { Client } from "../src/client.ts";

const ROSTER = 2, CELLS = 7, ASK = 32, UNASK = 33, ANSWER = 34, FETCH = 35;
export const KEY = "k".repeat(32);

export interface Peer {
  client: Client;
  receive: (data: Uint8Array) => void;
  deferred: (() => void)[];
  /** What it has written, as another would be sent it. */
  out: Uint8Array[];
  /** What its node holds: whole rows, and of each that is deleted, by what. */
  rows: Map<string, Map<string, Uint8Array>>;
  dead: Map<string, string>;
  /** What it has asked, by its number, and what was last said of each. */
  asked: Map<number, Question>;
  said: Map<number, string>;
  /** Rows its own writing put in the list, which the node then sends whole. */
  entered: Set<string>;
}

/**
 * A client of scope 1, which it may read, write and call in, with KEY for its key; random gives bytes, now the time. It is
 * told so at once, unless said: then when it is admitted.
 */
export function peer(random: (n: number) => Uint8Array, now: () => number, told = true): Peer {
  const self: Peer = {
    client: undefined as unknown as Client,
    receive: () => {},
    deferred: [],
    out: [],
    rows: new Map(),
    dead: new Map(),
    asked: new Map(),
    said: new Map(),
    entered: new Set(),
  };
  self.client = new Client({
    credential: "x",
    now,
    random,
    defer: (f) => void self.deferred.push(f),
    after: () => () => {},
    connect: (receive) => {
      self.receive = receive;
      return {
        send: (data) => {
          const r = codec.reader(data);
          while (r.pos < r.len) {
            const body = codec.bytes(r);
            const f = codec.reader(body.subarray(1));
            if (body[0] === CELLS) {
              // What it writes, as another would be sent it; and its own node has it.
              codec.varint(f);
              const cells = codec.rest(f).slice();
              self.out.push(cells);
              for (const id of store(self, cells)) self.entered.add(id);
            } else if (body[0] === ASK || body[0] === FETCH) {
              const id = codec.varint(f);
              self.asked.set(id, parseQuestion(codec.rest(f)));
              self.said.delete(id);
            } else if (body[0] === UNASK) {
              const id = codec.varint(f);
              self.asked.delete(id);
              self.said.delete(id);
            }
          }
        },
        close: () => {},
      };
    },
  });
  if (told) admit(self);
  return self;
}

/** Tells a client what it may do: read, write and call in scope 1. */
export function admit(p: Peer): void {
  const w = codec.writer();
  codec.putU8(w, ROSTER);
  codec.putBinary(w, "\0".repeat(8) + "\x01\x07" + KEY);
  tell(p, codec.written(w));
}

function tell(p: Peer, body: Uint8Array): void {
  const framed = codec.writer(body.length + 8);
  codec.putBytes(framed, body);
  p.receive(codec.written(framed).slice());
}

/** What the client itself defers, and nothing a node sends back. */
export function drain(p: Peer): void {
  while (p.deferred.length > 0) p.deferred.shift()!();
}

/** What the client defers, and what its node then sends: rows it put in the list, and answers. */
export function run(p: Peer): void {
  do drain(p);
  while (enter(p) || answer(p));
}

/** Keeps cells as a node does: whole rows, and nothing of a row it holds deleted, but a later deletion. Says which rows they touched. */
export function store(p: Peer, cells: Uint8Array): Set<string> {
  const touched = new Set<string>();
  const r = codec.reader(cells);
  let id = "";
  while (r.pos < r.len) {
    const tag = codec.u8(r);
    if (tag < 128) id = codec.takeBinary(r, 16);
    const slot = codec.u8(r);
    const stamp = codec.takeBinary(r, 16);
    const body = codec.bytes(r);
    const kind = tag % 64;
    const w = codec.writer(body.length + 40);
    codec.putU8(w, kind);
    codec.putBinary(w, id);
    codec.putU8(w, slot);
    codec.putBinary(w, stamp);
    codec.putBytes(w, body);
    const cell = codec.written(w).slice();
    const dead = p.dead.get(id);
    if (kind === 1) {
      if (dead === undefined || stamp > dead) {
        p.dead.set(id, stamp);
        p.rows.set(id, new Map([["grave", cell]]));
        touched.add(id);
      }
    } else if (dead === undefined) {
      let row = p.rows.get(id);
      if (!row) p.rows.set(id, (row = new Map()));
      row.set(String.fromCharCode(slot, kind) + stamp, cell);
      touched.add(id);
    }
  }
  return touched;
}

/** Whole rows, as a node sends them, of those it holds that have a place. */
export function rowsOf(p: Peer, ids: Iterable<string>): Uint8Array {
  const out = codec.writer();
  for (const t of ids) {
    const row = p.rows.get(t);
    if (!row) continue;
    let placed = row.has("grave");
    for (const k of row.keys()) placed ||= k.charCodeAt(1) === 2;
    if (placed) for (const c of row.values()) codec.put(out, c);
  }
  return codec.written(out).slice();
}

/** Sends cells, as a node does. */
export function sendCells(p: Peer, cells: Uint8Array): void {
  const w = codec.writer(cells.length + 8);
  codec.putU8(w, CELLS);
  codec.putVarint(w, 0);
  codec.put(w, cells);
  tell(p, codec.written(w));
}

// A row the client's own writing gives a place, or keeps in one, is sent whole, as a node sends what comes into what is
// watched: with what others wrote in it that was nowhere until then.
function enter(p: Peer): boolean {
  if (p.entered.size === 0) return false;
  const ids = p.entered;
  p.entered = new Set();
  sendCells(p, rowsOf(p, ids));
  return true;
}

/**
 * Cells as a node would send them: whole rows, of what it holds; and nothing of a row it holds deleted, but a later
 * deletion. Only what is in the list, as a watch of it is sent: a row with no place yet is nowhere until it has one.
 * Says how many milliseconds of it were the client's own.
 */
export function hear(p: Peer, cells: Uint8Array): number {
  const touched = store(p, cells);
  const t = performance.now();
  sendCells(p, rowsOf(p, touched));
  run(p);
  return performance.now() - t;
}

// ---------------------------------------------------------------- a node that answers questions (SPEC 15), of what it holds

type Col = { kind: number; slot: number; path: string; list: string };
type Cond =
  | { op: 0 }
  | { op: 1 | 2; of: Cond[] }
  | { op: 3; of: Cond }
  | { op: 4; column: Col; flags: number; lo: string | undefined; hi: string | undefined }
  | { op: 5; column: Col; set: string[] }
  | { op: 6 | 7; column: Col; bytes: string }
  | { op: 8; column: Col }
  | { op: 9; list: string }
  | { op: 11; ids: Set<string> };
export interface Question {
  scope: number;
  where: Cond;
  order: { how: number; desc: boolean; column: Col | undefined }[];
  fromEnd: boolean;
  offset: number;
  limit: number;
}

function parseQuestion(body: Uint8Array): Question {
  const r = codec.reader(body);
  const column = (): Col => {
    const kind = codec.u8(r);
    if (kind === 7 || kind === 8) return { kind, slot: 0, path: "", list: "" };
    if (kind === 9) return { kind, slot: 0, path: "", list: codec.takeBinary(r, 16) };
    if (kind === 10) return { kind, slot: codec.u8(r), path: "", list: "" };
    return { kind, slot: codec.u8(r), path: codec.binary(codec.bytes(r)), list: "" };
  };
  const condition = (): Cond => {
    const op = codec.u8(r);
    if (op === 0) return { op };
    if (op === 1 || op === 2) {
      const of: Cond[] = [];
      for (let n = codec.varint(r); n > 0; n--) of.push(condition());
      return { op, of };
    }
    if (op === 3) return { op, of: condition() };
    if (op === 4) {
      const c = column();
      const flags = codec.u8(r);
      const lo = flags & 1 ? codec.binary(codec.bytes(r)) : undefined;
      const hi = flags & 2 ? codec.binary(codec.bytes(r)) : undefined;
      return { op, column: c, flags, lo, hi };
    }
    if (op === 5) {
      const c = column();
      const set: string[] = [];
      for (let n = codec.varint(r); n > 0; n--) set.push(codec.binary(codec.bytes(r)));
      return { op, column: c, set };
    }
    if (op === 6 || op === 7) return { op, column: column(), bytes: codec.binary(codec.bytes(r)) };
    if (op === 8) return { op, column: column() };
    if (op === 9) return { op, list: codec.takeBinary(r, 16) };
    if (op === 11) {
      const ids = new Set<string>();
      for (let n = codec.varint(r); n > 0; n--) ids.add(codec.takeBinary(r, 16));
      return { op, ids };
    }
    throw new Error(`the harness's node does not know condition ${op}`);
  };
  const scope = codec.varint(r);
  const where = condition();
  const order: Question["order"] = [];
  for (let n = codec.varint(r); n > 0; n--) {
    const how = codec.u8(r);
    const desc = codec.u8(r) === 1;
    order.push({ how, desc, column: how === 0 ? column() : undefined });
  }
  const fromEnd = codec.u8(r) === 1;
  const offset = codec.varint(r);
  const limit = Math.min(codec.varint(r), 1000);
  if (codec.varint(r) !== 0) throw new Error("the harness's node gives no totals");
  return { scope, where, order, fromEnd, offset, limit };
}

type Held = { kind: number; slot: number; stamp: string; body: string };

// A row's cells, read from how the node keeps them.
function cellsOf(row: Map<string, Uint8Array>): Held[] {
  const out: Held[] = [];
  for (const c of row.values()) {
    const r = codec.reader(c);
    const kind = codec.u8(r);
    codec.take(r, 16);
    out.push({ kind, slot: codec.u8(r), stamp: codec.takeBinary(r, 16), body: codec.binary(codec.bytes(r)) });
  }
  return out;
}

// As Luau's string.lower: of ASCII alone.
const fold = (s: string): string => s.replace(/[A-Z]/g, (c) => c.toLowerCase());

function number(body: string): number {
  return codec.f64(codec.reader(codec.bytesOf(body)));
}

// A column's value in a row, as the kind says it is compared; undefined if it has none. Bytes are binary strings, which
// compare as bytes do.
function valueOf(cells: Held[], c: Col): string | number | undefined {
  if (c.kind === 7 || c.kind === 8) return undefined; // not asked here
  let best: Held | undefined;
  for (const cell of cells) if (cell.kind === 3 && cell.slot === c.slot && (!best || cell.stamp > best.stamp)) best = cell;
  if (!best || best.body === "") return undefined;
  const body = best.body;
  if (c.kind === 1) return body;
  if (c.kind === 2) return fold(body);
  if (c.kind === 3) return body.length === 8 ? number(body) : undefined;
  if (c.kind === 4) return body.length === 1 ? body.charCodeAt(0) : undefined;
  if (c.kind === 5) return body.length >= 16 ? body.slice(0, 16) : undefined;
  return undefined;
}

function bound(c: Col, b: string): string | number {
  if (c.kind === 2) return fold(b);
  if (c.kind === 3) return number(b);
  if (c.kind === 4) return b.charCodeAt(0);
  return b;
}

function holds(cond: Cond, id: string, cells: Held[]): boolean {
  switch (cond.op) {
    case 0:
      return true;
    case 1:
      return cond.of.every((x) => holds(x, id, cells));
    case 2:
      return cond.of.some((x) => holds(x, id, cells));
    case 3:
      return !holds(cond.of, id, cells);
    case 4: {
      const v = valueOf(cells, cond.column);
      if (v === undefined) return false;
      if (cond.lo !== undefined) {
        const lo = bound(cond.column, cond.lo);
        if (v < lo || (v === lo && !(cond.flags & 4))) return false;
      }
      if (cond.hi !== undefined) {
        const hi = bound(cond.column, cond.hi);
        if (v > hi || (v === hi && !(cond.flags & 8))) return false;
      }
      return true;
    }
    case 5: {
      const v = valueOf(cells, cond.column);
      return v !== undefined && cond.set.some((b) => v === bound(cond.column, b));
    }
    case 6:
    case 7: {
      const v = valueOf(cells, cond.column);
      const b = cond.column.kind === 2 ? fold(cond.bytes) : cond.bytes;
      if (typeof v !== "string") return false;
      return cond.op === 6 ? v.startsWith(b) : v.includes(b);
    }
    case 8:
      return valueOf(cells, cond.column) !== undefined;
    case 9:
      return cells.some((cell) => cell.kind === 2 && cell.body.slice(0, 16) === cond.list);
    case 11:
      return cond.ids.has(id);
  }
}

/** What answers a question, in its order, of the rows a node holds: the stretch asked for, and how many in all. */
export function evaluate(p: Peer, q: Question): [ids: string[], total: number] {
  const found: { id: string; cells: Held[] }[] = [];
  for (const [id, row] of p.rows) {
    if (row.has("grave")) continue;
    const cells = cellsOf(row);
    if (cells.some((c) => c.kind === 2) && holds(q.where, id, cells)) found.push({ id, cells });
  }
  found.sort((x, y) => {
    for (const o of q.order) {
      let a: string | number | undefined, b: string | number | undefined;
      if (o.how === 0) [a, b] = [valueOf(x.cells, o.column!), valueOf(y.cells, o.column!)];
      else if (o.how === 2) [a, b] = [x.id, y.id]; // when made, and then by the rest of the id
      if (a !== b) {
        if (a === undefined) return 1;
        if (b === undefined) return -1;
        return (o.desc ? a > b : a < b) ? -1 : 1;
      }
    }
    return x.id < y.id ? -1 : x.id > y.id ? 1 : 0;
  });
  const ids: string[] = [];
  for (let k = q.offset; k < Math.min(found.length, q.offset + q.limit); k++) ids.push(found[q.fromEnd ? found.length - 1 - k : k].id);
  return [ids, found.length];
}

// Answers anything asked whose answer is not what was last said: rows first, then which. Whether anything was said.
function answer(p: Peer): boolean {
  let said = false;
  for (const [id, q] of p.asked) {
    const [ids, total] = evaluate(p, q);
    // What would be said, and the rows themselves as they are now.
    const rows = rowsOf(p, ids);
    const w = codec.writer();
    codec.putVarint(w, total);
    codec.putVarint(w, q.offset);
    codec.putVarint(w, ids.length);
    for (const rid of ids) codec.putBinary(w, rid);
    codec.putVarint(w, 0);
    const head = codec.written(w).slice();
    const now = codec.binary(head) + codec.binary(rows);
    if (p.said.get(id) === now) continue;
    p.said.set(id, now);
    said = true;
    sendCells(p, rows);
    const a = codec.writer();
    codec.putU8(a, ANSWER);
    codec.putVarint(a, id);
    codec.putU8(a, 1);
    codec.put(a, head);
    tell(p, codec.written(a));
  }
  return said;
}
