// A client of a node: it keeps what is on screen, live, and nothing else. Windows over ordered lists that grow in either
// direction, shared between whoever observes them and let go when nobody does; questions, answered and kept true; texts
// typed into by many at once; calls between devices. Writes show at once and survive reconnection. It speaks SPEC.md §8
// for local clients over whatever pipe its host gives it: to a node in this very process, or to zspd on this machine.
//
// A port of luau/zsp/client.luau, which says the same in the same order; what one does, the other does.

import * as ask from "./ask.ts";
import * as codec from "./codec.ts";
import { sha256 } from "./sha256.ts";
import * as text from "./text.ts";
import type { Connect, Wire } from "./node.ts";

const HELLO = 1, ROSTER = 2, WATCH = 3, UNWATCH = 4, CELLS = 7, ACK = 8;
const ASK = 32, UNASK = 33, ANSWER = 34, FETCH = 35;
const LIVE = 9, SYNCED = 10, PRESENCE = 12, ERROR = 13, SERVE = 14, CALL = 15, FLOW = 16, AUTHOR = 17;
const GRAVE = 1, PLACE = 2, VALUE = 3, PIECE = 4, BUNDLE = 5;
const W_DATA = 1, W_LIVE = 2, W_BACK = 4, W_ADOPT = 8, W_COUNTS = 32;
const MESSAGE_MOST = 1 << 20; // bytes sent down the pipe at a time
const MAX_FRAME = 4 << 20; // the most a node reads as one frame
const F_DATA = 0, F_END = 1, F_FAULT = 2, F_CANCEL = 3, F_CREDIT = 4;
const CALL_WINDOW = 262144;
const WINDOW_MOST = 16 * CALL_WINDOW; // what the protocol lets a receiver credit ahead
const WINDOW_QUICK = 250; // ms: a window used up within this grows
const MAX_OPEN = 1048576 - 192;
const ZERO16 = "\0".repeat(16);
const ZERO24 = "\0".repeat(24);
const ZERO40 = "\0".repeat(40);

const PIECE_BYTES = 4096; // a piece is sealed at this size,
const PIECE_MOST = 65536 - 128; // and is never more, as no live frame a node carries is;
const INSERT_MOST = 1 + 2 * (1 + 8 + 5) + 5; // what an insertion's operation is besides its bytes, at most
const PIECE_MS = 1000; // or this long after it began,
const LIVE_MS = 10000; // and live text unconfirmed for this long is dropped
const LEAP_MS = 15 * 60 * 1000; // a node refuses a stamp further ahead of its clock than this

const utf8 = new TextEncoder();
const fromUtf8 = new TextDecoder("utf-8", { ignoreBOM: true }); // a byte order mark, if one was written, is read
const ROW_ID = /^[0-9a-fA-F]{32}$/, DEVICE_ID = /^[0-9a-fA-F]{64}$/;

// A row's id, as the protocol keeps it.
function rowId(id: string): string {
  if (!ROW_ID.test(id)) throw new RangeError("a row's id is 32 hex digits");
  return codec.binary(codec.unhex(id));
}
const toBytes = (data: Uint8Array | string): Uint8Array => (typeof data === "string" ? utf8.encode(data) : data);

// A scope's number, as one is: else it is refused here, rather than said, and refused for good, later.
function whole(scope: number): void {
  if (!Number.isInteger(scope) || scope < 0 || scope > 0xffffffff) throw new RangeError("a scope is a whole number below 2^32");
}

// ---------------------------------------------------------------- what the host lends

export interface Host {
  /** Opens a pipe to the node. */
  connect: Connect;
  /** Presented to the node, whose host decides by it whether to serve this client and as whom. */
  credential?: string | Uint8Array;
  /** Milliseconds a window nobody observes stays warm: 5000. */
  linger?: number;
  /** Cryptographic randomness: crypto.getRandomValues by default. */
  random?: (bytes: number) => Uint8Array;
  /** Milliseconds since 1970: Date.now by default. */
  now?: () => number;
  /** Runs f soon, once the current work is done: queueMicrotask by default. */
  defer?: (f: () => void) => void;
  /** Runs f later, and returns a way to cancel it: setTimeout by default. */
  after?: (ms: number, f: () => void) => () => void;
}

interface Lent {
  connect: Connect;
  credential: Uint8Array;
  linger: number;
  random: (bytes: number) => Uint8Array;
  now: () => number;
  defer: (f: () => void) => void;
  after: (ms: number, f: () => void) => () => void;
}

// ---------------------------------------------------------------- columns

/** What a column can be asked about as. */
export type Is = "string" | "number" | "boolean" | "id" | "text" | "author" | "bytes";

/** A column of a table: a data slot, and how what is in it is written and read. */
export interface Column<T = unknown> {
  readonly slot: number;
  readonly text: boolean;
  readonly is: Is;
  readonly encode: (value: T) => Uint8Array;
  readonly decode: (bytes: Uint8Array) => T;
  /** Not what is in the slot, but who wrote it. */
  readonly who?: "last" | "all";
}

export type Table = { readonly [name: string]: Column<any> };

declare const textBrand: unique symbol;
declare const allBrand: unique symbol;
/** A column of collaborative text, always a string, empty when nothing is in it. */
export type TextColumn = Column<string> & { readonly [textBrand]: true };
/** Everyone who has written in a slot, by the names they go by. */
export type AuthorsColumn = Column<readonly string[]> & { readonly [allBrand]: true };

/** A row as the application sees it: one frozen object, the very same one until something in it changes. */
export type Row<T extends Table = Table> = {
  readonly id: string;
  readonly order: number;
} & {
  readonly [K in keyof T]: T[K] extends TextColumn ? string : T[K] extends AuthorsColumn ? readonly string[] : T[K] extends Column<infer V> ? V | undefined : never;
};

function column<T>(slot: number, is: Is, encode: (v: T) => Uint8Array, decode: (b: Uint8Array) => T, who?: "last" | "all"): Column<T> {
  if (!Number.isInteger(slot) || slot < 16 || slot > 255) throw new RangeError("data slots are 16 to 255");
  return Object.freeze({ slot, text: is === "text", is, encode, decode, who });
}

const unwritable = (): never => {
  throw new Error("whose a row is cannot be written");
};

// How the columns that are not made up write and read, one function each, by which what reads cells knows them.
const encodeString = (v: string): Uint8Array => utf8.encode(v);
const decodeString = (b: Uint8Array): string => fromUtf8.decode(b);
const encodeNumber = (v: number): Uint8Array => {
  const b = new Uint8Array(8);
  new DataView(b.buffer).setFloat64(0, v);
  return b;
};
// As Luau reads it: eight bytes or more, the first eight; fewer, nothing.
const decodeNumber = (b: Uint8Array): number => (b.length >= 8 ? new DataView(b.buffer, b.byteOffset, 8).getFloat64(0) : (undefined as unknown as number));

export const columns = Object.freeze({
  /** Text, as UTF-8. */
  string: (slot: number): Column<string> => column(slot, "string", encodeString, decodeString),
  /** Bytes as they are, and asked about byte for byte. */
  bytes: (slot: number): Column<Uint8Array> => column<Uint8Array>(slot, "bytes", (v) => v, (b) => b.slice()),
  number: (slot: number): Column<number> => column(slot, "number", encodeNumber, decodeNumber),
  boolean: (slot: number): Column<boolean> => column(slot, "boolean", (v: boolean) => Uint8Array.of(v ? 1 : 0), (b) => b.length === 1 && b[0] === 1),
  /** Another row, by its id. */
  row: (slot: number): Column<string> => column(slot, "id", (v: string) => codec.unhex(v), (b) => codec.hex(b)),
  /** Anything, given a way to write it down. What is written as JSON can be asked about by path. */
  custom: <T>(slot: number, encode: (v: T) => Uint8Array, decode: (b: Uint8Array) => T): Column<T> => column(slot, "string", encode, decode),
  /** Anything JSON can say, which can then be asked about by path. */
  json: <T = unknown>(slot: number): Column<T> =>
    column(slot, "string", (v: T) => utf8.encode(JSON.stringify(v)), (b) => JSON.parse(fromUtf8.decode(b)) as T),
  /** Whose what is in a slot is: whom the last to write there goes by, where the scope says. */
  author: (slot: number): Column<string> => column(slot, "author", unwritable, (b) => fromUtf8.decode(b), "last"),
  /** And everyone who has written there, in order of their names, for texts. */
  authors: (slot: number): AuthorsColumn => column<readonly string[]>(slot, "author", unwritable, () => [], "all") as unknown as AuthorsColumn,
  /** Collaborative, streamable text. */
  text: (slot: number): TextColumn => column(slot, "text", (v: string) => utf8.encode(v), (b) => fromUtf8.decode(b)) as TextColumn,
});

// ---------------------------------------------------------------- what is told

export type Status = "loading" | "stale" | "ready" | "denied";

export interface State<T extends Table = Table> {
  readonly rows: readonly Row<T>[];
  readonly status: Status;
  /** Rows of the list that lie before these, */
  readonly before: number;
  /** and after. */
  readonly after: number;
}

export interface Answer<T extends Table = Table> {
  readonly rows: readonly Row<T>[];
  readonly status: "loading" | "indexing" | "ready" | "stale" | "denied" | "faulty";
  /** Of indexing, from 0 to 1. */
  readonly progress: number;
  /** Rows there are in all, */
  readonly total: number;
  /** and how many come before these. */
  readonly first: number;
  /** As named: numbers, or lists of { value, count }. */
  readonly totals: { readonly [name: string]: unknown };
}

/** A device, and whom it, or this client, goes by. */
export interface Device {
  readonly id: string;
  readonly subject: string;
}

export type Fault = "denied" | "unreachable" | "unserved" | "lost" | "overrun" | "busy" | "cancelled";
const FAULTS: Fault[] = ["cancelled", "denied", "unreachable", "unserved", "lost", "overrun", "busy"];

export interface Call {
  readonly device: string;
  readonly method: string;
  /** Of one that is answered: whom whoever calls goes by. */
  readonly subject?: string;
  /** Bytes that may be sent now and go at once, beyond what waits already: what the other side has room for. */
  readonly room: number;
  /** Sends a message, at once if the other side has room for it, and otherwise when it has. */
  send(data: Uint8Array | string): void;
  /** No more will be sent. */
  finish(): void;
  cancel(): void;
  /** Says that bytes kept from ondata are done with: the other side may send as many more. */
  consumed(n: number): void;
  /**
   * A message. It is done with when this returns, unless this returns false: then it is kept from the other side's credit
   * until consumed says so, and a reader that is slow so slows whoever sends, with nothing piling up between them.
   */
  ondata?: (data: Uint8Array) => boolean | void;
  onend?: () => void;
  onfault?: (fault: Fault) => void;
  /** More may be sent: room grew, and nothing waits for it. */
  onroom?: () => void;
}

export interface CallOptions {
  /**
   * How urgent the call is, from 0, the most, to 7, the least: 3 unless said. It is the urgency of the stream between
   * devices that carries it, so what is interactive, as keystrokes, goes ahead of what is bulk, as a copy (1 and 6, say).
   */
  urgency?: number;
}

export interface Query<T extends Table = Table> {
  scope: number;
  list: string;
  table: T;
  /** Rows to a page: 50; 0 for all of them. */
  size?: number;
  /** Where to begin: the end. */
  from?: "start" | "end";
  /** Observers are only told that it changed, as what is built on the client wants. */
  bare?: boolean;
}

export interface Window {
  /** The rows now on screen, by position from 1. Loads what is near, lets go of what is far. */
  visible(first: number, last: number): void;
  loadBefore(): void;
  loadAfter(): void;
  /** The rows as they are held, in order: for what is built on the client, such as a mirror. */
  entries(): readonly Entry[];
  stop(): void;
}

export interface Asking {
  /** Another stretch of it. */
  move(offset: number, limit?: number): void;
  stop(): void;
}

export interface Editor {
  read(): string;
  /** Positions count UTF-16 code units, as a string's indices do, and never fall inside a character. */
  insert(index: number, s: string): void;
  append(s: string): void;
  delete(index: number, count: number): void;
  /**
   * Makes what has been written durable now rather than shortly. Resolves once it is acknowledged, durable on the node this
   * client speaks to, and all this client wrote before it; rejects only should that never be (Client.close).
   */
  commit(): Promise<void>;
  /** Ends the editor, sealing what was typed: resolves, or rejects, as commit does. */
  close(): Promise<void>;
}

export interface Change {
  /** Makes a row in a list, at an order, with these values; returns its id. */
  insert<T extends Table>(table: T, list: string, order: number, values: Partial<Values<T>>): string;
  set<T extends Table>(id: string, table: T, values: Partial<Values<T>>): void;
  /** Puts a row in a list, or moves it there; slot 1 unless said, for a row may be in fifteen lists at once. */
  place(id: string, list: string, order: number, slot?: number): void;
  delete(id: string): void;
  /** Edits a text column as one piece of this change: f is given the text, and a way to name pieces. */
  edit(id: string, slot: number, f: (t: text.Text, fresh: () => string) => void): void;
}

export type Values<T extends Table> = { [K in keyof T]: T[K] extends Column<infer V> ? V : never };

export type Event = "status" | "devices" | "self" | "error";
type Told = { status: boolean; devices: readonly Device[]; self: Device; error: number };

// ---------------------------------------------------------------- what is held

/** A cell, read plainly: what cells(row, slot) gives. */
export interface Cell {
  kind: number;
  stamp: string;
  body: Uint8Array;
  author?: Device;
}

/**
 * A cell as it is held: one binary string, its kind (1 byte), its stamp (16) and its body, the rest. One string rather than
 * an object, a string and bytes, which is a fraction of the memory and of the work, and made from what came in one go.
 */
type Held = string;
/** What a slot holds: its one cell, which is what almost every slot holds; or, of a text's pieces, several, by stamp. */
type Cells = Held | Map<string, Held>;

/**
 * A row as it is held: its cells, by slot, as pairs in one array (slot, cells, slot, cells, …). Not to be changed. Its
 * fields are all there from the first, so that every row has the same shape; what only some rows need is undefined until
 * they need it.
 */
export interface Stored {
  readonly id: string;
  hex: string | undefined; // its id as an application sees it, once that has been asked for
  slots: (number | Cells | undefined)[];
  pages: number; // that hold it
  version: number; // counts changes to what it holds, that whoever reads it may know whether to again
  dead: boolean;
  authors: Map<string, Device> | undefined; // who wrote each cell, by its slot (a char) and stamp, where that is known
  texts: Map<number, text.Text> | undefined;
  held: Map<number, number> | undefined; // open editors, by slot
  asking: (() => void) | undefined; // for the sake of those, while nothing else shows it: ends that
  awaited: (() => void)[] | undefined; // by those, until it is here
  lives: Map<number, number> | undefined; // when live text was last heard, by slot
  views: Map<Table, Row<any>> | undefined; // by table, until the row changes
  dirty: Set<number> | undefined; // slots with live text to send
}

export interface Entry {
  readonly key: string;
  readonly row: Stored;
}

type Said = Map<string, Set<string>>;

interface Page {
  id: number;
  window: Win;
  lo: string;
  hi: string;
  open: boolean; // still owed its first sync
  settled: boolean;
  before: number;
  after: number;
  limit: number; // as first asked for, until the node says what the page spans
  back: boolean;
  keeps?: boolean; // asked for to have again what the window showed beyond the page next to it
  stale?: Said; // while being sent afresh: rows, and which cells of each are there still
}

interface Win {
  key: string;
  scope: number;
  list: string;
  schema: Table;
  size: number;
  back: boolean; // it begins at the end
  pages: Page[];
  keys: string[]; // of the rows it holds, in order,
  held: Stored[]; // and the rows, each where its key is
  at: Map<Stored, string>; // where each of them is among them
  bare: boolean; // its observers want to know when it changes, not how it is
  observers: Set<(state: State<any>) => void>;
  watching: number;
  state?: State<any>;
  changed: boolean;
  denied: boolean;
  linger?: () => void;
}

interface Asked {
  id: number;
  question: ask.Question;
  schema: Table;
  totalsOf: ask.Told[];
  observer: (answer: Answer<any>) => void;
  ids: string[];
  said?: Said; // while being sent afresh
  shown: Set<string>;
  once?: (answer: Answer<any>) => void; // it is to be answered once, and this told
  stopped: boolean; // though the node may not know yet, and count on its rows being held
  answer?: Answer<any>;
  status: Answer["status"];
  progress: number;
  total: number;
  first: number;
  totals: { readonly [name: string]: unknown };
  changed: boolean;
}

interface Follower {
  readonly f: (row: Stored) => void;
  on: boolean; // until it is stopped, even while the rest are being told
}

interface LiveCall {
  call: Call;
  side: number;
  finishing: boolean; // no more will be sent,
  mineEnded: boolean; // and the other side has been told so
  theirsEnded: boolean;
  credit: number;
  queue: Uint8Array[]; // awaiting credit
  queued: number; // bytes of it
  window: number; // what the other side may have outstanding with us
  used: number; // of it, consumed since the window last grew
  since: number; // when it last grew, or was used up
}

interface Written {
  row: string;
  slot: number;
  kind: number;
  stamp: string;
  body: Uint8Array;
}

interface Pending {
  seq: number;
  scope: number;
  body: Uint8Array;
  rows: string[];
  cells: number;
  texts: string[]; // editors' texts sealed in it, by row and slot: told why, should it never be durable
  done: () => void;
  fail: (e: Error) => void; // should it never be durable
}

// Whoever waits for everything written up to a sequence number: told once each is acknowledged, or that one never will be.
interface Barrier {
  seq: number;
  failed?: Error;
  resolve: () => void;
  reject: (e: Error) => void;
}

const handled = <T>(p: Promise<T>): Promise<T> => (p.catch(() => {}), p); // whoever does not wait for it is not thrown at

/**
 * Seals what every editor of a client has typed and sends it, there and then: for a browser's device, as its tab is put
 * away, which leaves no time for anything to wait. Not for applications, which close or commit.
 */
export const sealNow = Symbol("seal now");

/** Whether a client has written what is not yet acknowledged: for a browser's device, as its tab is put away. */
export const unacknowledged = Symbol("unacknowledged");

/**
 * On a host's connect: called with every client made on it, as a browser's device keeps those of its own, to seal what they
 * typed as its tab is put away and deliver what they wrote before it closes.
 */
export const madeOn = Symbol("made on");

/** What a client had written, and not seen acknowledged, when whoever waited for it gave up: never to be delivered by a client closed. */
export class Undelivered extends Error {
  /** Rows written to, of cells... */
  readonly rows: number;
  /** ...cells... */
  readonly cells: number;
  /** ...and bytes, as they were said. */
  readonly bytes: number;
  constructor(rows: number, cells: number, bytes: number, closed: boolean) {
    super(`${closed ? "the client was closed and gave up on" : "gave up waiting for"} ${cells} cells of ${rows} rows, ${bytes} bytes, not yet acknowledged`);
    this.name = "Undelivered";
    this.rows = rows;
    this.cells = cells;
    this.bytes = bytes;
  }
}

// ---------------------------------------------------------------- what is held, and merging

// Versions of rows, of every client here: no two states of any rows have the same, so that one is known again only as
// itself, though the row be let go of and come again.
let versions = 0;

function newRow(id: string): Stored {
  return {
    id,
    hex: undefined,
    slots: new Array(8), // room for four
    pages: 0,
    version: ++versions,
    dead: false,
    authors: undefined,
    texts: undefined,
    held: undefined,
    asking: undefined,
    awaited: undefined,
    lives: undefined,
    views: undefined,
    dirty: undefined,
  };
}

/** A row's id as an application sees it. */
export function hexOf(row: Stored): string {
  return (row.hex ??= codec.hex(row.id));
}

/** What a slot of a row holds. */
function slotOf(row: Stored, slot: number): Cells | undefined {
  const a = row.slots;
  for (let i = 0; i < a.length; i += 2) {
    const s = a[i];
    if (s === slot) return a[i + 1] as Cells;
    if (s === undefined) return undefined;
  }
  return undefined;
}

/** Puts what a slot holds, or with undefined takes it away. */
function setSlot(row: Stored, slot: number, v: Cells | undefined): void {
  const a = row.slots;
  let i = 0;
  for (; i < a.length && a[i] !== undefined; i += 2) {
    if (a[i] !== slot) continue;
    if (v !== undefined) {
      a[i + 1] = v;
      return;
    }
    // The last pair takes its place.
    let last = i;
    while (last + 2 < a.length && a[last + 2] !== undefined) last += 2;
    a[i] = a[last];
    a[i + 1] = a[last + 1];
    a[last] = a[last + 1] = undefined;
    return;
  }
  if (v === undefined) return;
  a[i] = slot;
  a[i + 1] = v;
}

/** The slots a row has something in, and what. */
function eachSlot(row: Stored, f: (slot: number, v: Cells) => void): void {
  const a = row.slots;
  for (let i = 0; i < a.length && a[i] !== undefined; i += 2) f(a[i] as number, a[i + 1] as Cells);
}

/** The slots a row has something in: for what reads cells plainly, as tests do. */
export function slotsHeld(row: Stored): number[] {
  return slotsOf(row);
}

function slotsOf(row: Stored): number[] {
  const out: number[] = [];
  eachSlot(row, (slot) => out.push(slot));
  return out;
}

const kindOf = (c: Held): number => c.charCodeAt(0);
// A cell's stamp, as a string of its own. Cut from the cell, it would be a slice of it, which V8 compares with others
// only through its runtime, slowly: as a Map does its keys, when a set of cells is copied.
const stampOf = (c: Held): string =>
  String.fromCharCode(
    c.charCodeAt(1), c.charCodeAt(2), c.charCodeAt(3), c.charCodeAt(4), c.charCodeAt(5), c.charCodeAt(6), c.charCodeAt(7), c.charCodeAt(8),
    c.charCodeAt(9), c.charCodeAt(10), c.charCodeAt(11), c.charCodeAt(12), c.charCodeAt(13), c.charCodeAt(14), c.charCodeAt(15), c.charCodeAt(16),
  );
// How sixteen characters of one string compare with sixteen of another, read where they are: less than 0, 0, or more.
function cmp16(a: string, at: number, b: string, bt: number): number {
  for (let i = 0; i < 16; i++) {
    const d = a.charCodeAt(at + i) - b.charCodeAt(bt + i);
    if (d !== 0) return d;
  }
  return 0;
}
// A cell's body for its text, which keeps it as long as the text is: cut from a slab shared with others, so that each is
// only a view, with no buffer of its own. (A text only reads what it is given; where it would add to it, it copies.) A
// slab is kept while any body cut from it is, so it is small, and a body of more than a quarter of one has its own.
const SLAB = 1024;
// Of the bodies of long cells of texts just heard, kept as the bytes they came in (see Client's heardBodies), the most.
const HEARD_MOST = 1 << 24;
let slab = new Uint8Array(0);
let slabAt = 0;
function textBody(c: Held, heard: Map<Held, Uint8Array>): Uint8Array {
  const n = c.length - 17;
  if (n > SLAB / 4) return heard.get(c) ?? bodyOf(c);
  if (slabAt + n > slab.length) (slab = new Uint8Array(SLAB)), (slabAt = 0);
  const out = slab.subarray(slabAt, slabAt + n);
  slabAt += n;
  for (let i = 0; i < n; i++) out[i] = c.charCodeAt(17 + i);
  return out;
}
function bodyOf(c: Held): Uint8Array {
  const out = new Uint8Array(c.length - 17);
  for (let i = 0; i < out.length; i++) out[i] = c.charCodeAt(17 + i);
  return out;
}
const cellOf = (kind: number, stamp: string, body: Uint8Array): Held => String.fromCharCode(kind) + stamp + codec.binary(body);

/** The latest value in a slot, if any. */
export function latest(row: Stored, slot: number): Held | undefined {
  const v = slotOf(row, slot);
  if (typeof v === "string") return v.charCodeAt(0) === VALUE ? v : undefined;
  if (v === undefined) return undefined;
  let best: Held | undefined;
  for (const c of v.values()) if (c.charCodeAt(0) === VALUE && (best === undefined || c > best)) best = c; // of one kind, the stamp decides
  return best;
}

/** Each cell of a slot, read plainly: for what reads cells as they are, as tests do. */
export function cells(row: Stored, slot: number): Cell[] {
  const v = slotOf(row, slot);
  const all = typeof v === "string" ? [v] : v === undefined ? [] : [...v.values()];
  return all.map((c) => {
    const stamp = stampOf(c);
    const author = row.authors?.get(String.fromCharCode(slot) + stamp);
    return author ? { kind: kindOf(c), stamp, body: bodyOf(c), author } : { kind: kindOf(c), stamp, body: bodyOf(c) };
  });
}

/** Whose what is in a slot is: whom the last to write there goes by; or, `all`, everyone who has, in order of their names. */
export function whose(row: Stored, slot: number, all: boolean): string | readonly string[] | undefined {
  const v = slotOf(row, slot);
  const authors = row.authors;
  let last: Held | undefined;
  const names = new Set<string>();
  const see = (c: Held) => {
    if (last === undefined || cmp16(c, 1, last, 1) > 0) last = c;
    const who = authors?.get(String.fromCharCode(slot) + stampOf(c));
    if (who && who.subject !== "") names.add(who.subject);
  };
  if (typeof v === "string") see(v);
  else if (v !== undefined) for (const c of v.values()) see(c);
  if (all) return Object.freeze([...names].sort());
  const who = last !== undefined ? authors?.get(String.fromCharCode(slot) + stampOf(last)) : undefined;
  return who && who.subject !== "" ? who.subject : undefined;
}

function forgetAuthor(row: Stored, slot: number, stamp: string): void {
  const authors = row.authors;
  if (authors) {
    authors.delete(String.fromCharCode(slot) + stamp);
    if (authors.size === 0) row.authors = undefined;
  }
}

// A slot's cells as compact as they go: one held as itself, none not at all.
function compact(row: Stored, slot: number): void {
  const v = slotOf(row, slot);
  if (v === undefined || typeof v === "string") return;
  if (v.size === 0) setSlot(row, slot, undefined);
  else if (v.size === 1) setSlot(row, slot, v.values().next().value!);
}

// That it holds something other than it did: what was read of it is to be read again.
function unview(row: Stored): void {
  row.version = ++versions;
  row.views = undefined;
}

const MAX_CELL = 1048576;
const u32At = (s: string, at: number): number =>
  ((s.charCodeAt(at) << 24) | (s.charCodeAt(at + 1) << 16) | (s.charCodeAt(at + 2) << 8) | s.charCodeAt(at + 3)) >>> 0;

// Whether a cell has the shape a node keeps (SPEC.md 1, as zsp/types.odin's cell_valid has it): a kind there is, in a slot
// for it, with all of its clear prefix, and a bundle whose stamps are in order and before its own. What has not is passed
// over, as a node would pass it over; whether whoever wrote it might is for the node to say.
function shaped(id: string, slot: number, c: Held): boolean {
  const n = c.length - 17;
  if (n > MAX_CELL || c.charCodeAt(1) >= 128) return false; // a body too long, or a time of 2^63 or more
  const kind = c.charCodeAt(0);
  if (kind === GRAVE) return slot === 0;
  if (kind === PLACE) {
    if (slot < 1 || slot > 15 || n < 24 || u32At(c, 17) !== u32At(id, 0)) return false;
    return u32At(c, 21) !== 0 || u32At(c, 25) !== 0 || u32At(c, 29) !== 0; // not the scope's graveyard
  }
  if (kind === VALUE || kind === PIECE) return slot >= 16;
  if (kind === BUNDLE) {
    if (slot < 16 || n < 4) return false;
    const count = u32At(c, 17);
    if (count === 0 || count > MAX_CELL / 16 || n < 4 + count * 16) return false;
    for (let i = 1; i < count; i++) if (cmp16(c, 21 + i * 16, c, 5 + i * 16) <= 0) return false;
    return cmp16(c, 5 + count * 16, c, 1) < 0;
  }
  return false;
}

// Whether a place's body, at pos in what came, is of the row's scope and not the scope's graveyard, as a node keeps it.
function placeFine(buf: Uint8Array, pos: number, size: number, id: string): boolean {
  if (size < 24 || ((buf[pos] << 24) | (buf[pos + 1] << 16) | (buf[pos + 2] << 8) | buf[pos + 3]) >>> 0 !== u32At(id, 0)) return false;
  for (let i = 4; i < 16; i++) if (buf[pos + i] !== 0) return true;
  return false;
}

// Whether a held cell's body is the size bytes at pos in what came.
function sameBody(held: Held, buf: Uint8Array, pos: number, size: number): boolean {
  for (let i = 0; i < size; i++) if (held.charCodeAt(17 + i) !== buf[pos + i]) return false;
  return true;
}

// Whether a bundle (a cell, its body from char 17) holds a piece of the stamp in s at at. One too short to say holds none.
function bundleHas(c: Held, s: string, at: number): boolean {
  if (c.length < 21) return false;
  const n = ((c.charCodeAt(17) << 24) | (c.charCodeAt(18) << 16) | (c.charCodeAt(19) << 8) | c.charCodeAt(20)) >>> 0;
  let lo = 0, hi = n;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    const d = cmp16(c, 21 + mid * 16, s, at);
    if (d === 0) return true;
    if (d < 0) lo = mid + 1;
    else hi = mid;
  }
  return false;
}

// The merge rule, for a cell. Returns whether it was news.
function merge(row: Stored, slot: number, c: Held, author?: Device): boolean {
  if (row.dead) return false;
  const kind = c.charCodeAt(0);
  if (kind === GRAVE) {
    row.dead = true;
    row.slots = [];
    row.authors = undefined;
    return true;
  }
  const v = slotOf(row, slot);
  // Stamps are compared where they are in the cells, and made strings of their own only to be kept as keys.
  if (v === undefined) {
    setSlot(row, slot, c);
  } else if (typeof v === "string") {
    const d = cmp16(c, 1, v, 1); // this stamp against the one held
    if (d === 0) return false;
    const k = v.charCodeAt(0);
    if ((k === PLACE || k === VALUE) && d < 0) return false;
    if (k === BUNDLE && (kind === PIECE || kind === BUNDLE) && bundleHas(v, c, 1)) return false;
    let drop = false;
    if (kind === PLACE || kind === VALUE) drop = d > 0;
    else if (kind === BUNDLE) drop = (k === PIECE || k === BUNDLE) && bundleHas(c, v, 1);
    if (drop) {
      forgetAuthor(row, slot, stampOf(v));
      setSlot(row, slot, c);
    } else {
      setSlot(
        row,
        slot,
        new Map([
          [stampOf(v), v],
          [stampOf(c), c],
        ]),
      );
    }
  } else {
    const stamp = stampOf(c);
    if (v.has(stamp)) return false;
    for (const x of v.values()) {
      const k = x.charCodeAt(0);
      if ((k === PLACE || k === VALUE) && cmp16(c, 1, x, 1) <= 0) return false;
      if (k === BUNDLE && (kind === PIECE || kind === BUNDLE) && bundleHas(x, c, 1)) return false;
    }
    if (kind === PLACE || kind === VALUE) {
      for (const [s, x] of [...v]) {
        if (cmp16(x, 1, c, 1) < 0) {
          v.delete(s);
          forgetAuthor(row, slot, s);
        }
      }
    } else if (kind === BUNDLE) {
      for (const [s, x] of [...v]) {
        const k = x.charCodeAt(0);
        if ((k === PIECE || k === BUNDLE) && bundleHas(c, x, 1)) {
          v.delete(s);
          forgetAuthor(row, slot, s);
        }
      }
    }
    v.set(stamp, c);
    compact(row, slot);
  }
  if (author) (row.authors ??= new Map()).set(String.fromCharCode(slot) + stampOf(c), author);
  return true;
}

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) out.set(p, at), (at += p.length);
  return out;
}

// A stamp's time, ms × 2^16 + counter, as eight bytes.
function stampTime(ms: number, n: number): string {
  return codec.u32Binary(Math.floor(ms / 65536)) + String.fromCharCode((ms % 65536) >> 8, ms % 256, n >> 8, n & 255);
}

// A place's key: the first 24 bytes of its body, and the row's id.
function placeKey(c: Held, id: string): string {
  return c.slice(17, 41) + id;
}

// Where a row is to be in a window: the least of its places in what the window spans.
function wanted(row: Stored, lo: string, hi: string): string | undefined {
  if (row.dead) return undefined;
  let want: string | undefined;
  const a = row.slots;
  for (let i = 0; i < a.length && a[i] !== undefined; i += 2) {
    if ((a[i] as number) > 15 || a[i] === 0) continue; // places are in slots 1 to 15
    const v = a[i + 1] as Cells;
    if (typeof v === "string") {
      const key = placeKey(v, row.id);
      if (key >= lo && key < hi && (want === undefined || key < want)) want = key;
    } else {
      for (const c of v.values()) {
        const key = placeKey(c, row.id);
        if (key >= lo && key < hi && (want === undefined || key < want)) want = key;
      }
    }
  }
  return want;
}

// Where cells are made from what came, one at a time, to be made one string each: their kind, stamp and body side by side.
let scratch = new Uint8Array(4096);

// ---------------------------------------------------------------- the client

export class Client {
  #host: Lent;
  #wire?: Wire;
  #hangUp: () => void = () => {};
  #ready = false;
  #closed = false;
  #failures = 0; // pipes in a row that never came up, or that the node found fault with
  #faulted = false; // this pipe has: the node said so, or said nonsense
  // Of a frame not yet all here, what has come: in the pieces it came in, joined once it has all come, and not each
  // time another comes, which, of a frame of a large text coming a little at a time, would be the text over and over.
  #input: Uint8Array[] = [];
  #inputBytes = 0;
  #inputWants = 0; // so many bytes at least, before a frame is whole
  // The bodies of long cells of texts just heard, as the bytes they came in: what a text made before what was heard is
  // shown is made of, rather than of each character of the cell, read again one at a time. Let go of once it is shown.
  #heardBodies = new Map<Held, Uint8Array>();
  #heardBytes = 0;
  #clockMs = 0;
  #clockN = 0;
  #scopes = new Map<number, { rights: number; key: Uint8Array }>();
  #authors = new Map<number, Device>(); // by what this pipe calls them: 0 is this client
  #devices: readonly Device[] = Object.freeze([]);
  #watchers = new Map<Event, Set<(value: any) => void>>();
  #rows = new Map<string, Stored>();
  #windows = new Map<string, Win>();
  #pages = new Map<number, Page>();
  #nextPage = 0;
  #asked = new Map<number, Asked>();
  #nextAsk = 0;
  #loose = new Set<string>(); // rows sent for an answer still to come
  #shapes = new WeakMap<Table, number>();
  #nextShape = 0;
  #seq = 0;
  #pending: Pending[] = [];
  #barriers: Barrier[] = []; // by sequence number
  #closing: Promise<void> | undefined; // once closed: until all it wrote is acknowledged
  #early = new Set<Promise<void>>(); // editors' typing before their rows were here: until it is typed in them
  // Given up on, or refused for good: nothing more is delivered, nor dialled for, and why.
  #abandoned: Error | undefined;
  #givenUp: Pending[] = []; // what it was given up on with, to be counted with anything sealed after
  #owed: Error | undefined; // what was never to be delivered, with nobody waiting to be told: the next to wait is told
  #neverDelivered: Error | undefined; // anything it wrote that never will be delivered, as its close says
  #refusedTexts = new Map<string, Error>(); // editors' texts, by row and slot, sealed where it may no longer write
  #unacked = new Map<string, number>(); // rows in pending, and how often
  #out = codec.writer();
  #flushing = false;
  #tells = new Map<Event, number>(); // what was told of each, so far: one told again within another is told afresh
  #faults = new Map<LiveCall, Fault>(); // calls to be told of their end, unless cancelled first
  #calls = new Map<number, LiveCall>(); // ours
  #answers = new Map<number, LiveCall>(); // of others
  #nextCall = 0;
  #handlers = new Map<string, (call: Call, data: Uint8Array) => void>();
  #followers: readonly Follower[] = []; // made anew as they change: what is being told stays as it was
  #typing = new Set<Stored>(); // rows with live text to send
  #tags = new Map<string, string>(); // of lists, by their scope, its key and their name
  #bulk?: Map<Win, Stored[]>; // rows to add to windows, all at once
  #timers = new Set<() => void>(); // what is to be done later, by the ways to cancel each

  constructor(host: Host) {
    const credential = host.credential ?? new Uint8Array();
    this.#host = {
      connect: host.connect,
      credential: typeof credential === "string" ? utf8.encode(credential) : credential,
      linger: host.linger ?? 5000,
      random: host.random ?? ((n) => crypto.getRandomValues(new Uint8Array(n))),
      now: host.now ?? (() => Date.now()),
      defer: host.defer ?? ((f) => queueMicrotask(f)),
      after:
        host.after ??
        ((ms, f) => {
          const t = setTimeout(f, ms);
          return () => clearTimeout(t);
        }),
    };
    (host.connect as { [madeOn]?: (client: Client) => void })[madeOn]?.(this);
    this.#dial();
  }

  // ---------------------------------------------------------------- the pipe

  #dial(): void {
    if (this.#wire || this.#abandoned || (this.#closed && this.#pending.length === 0)) return; // a client closed dials only to deliver what it wrote
    let over = false;
    const closed = () => {
      if (over) return;
      over = true;
      this.#lost();
    };
    this.#hold();
    this.#out = codec.writer();
    this.#faulted = false;
    const wire = this.#host.connect((data) => {
      if (!over) this.#receive(data);
    }, closed);
    if (!wire) {
      // No node to hand it to: what a client closed wrote can never be delivered, and it is told so, not dropped unsaid.
      if (this.#closed) this.#giveUp(new Error("the client was closed with no node to deliver what it wrote to"));
      closed();
      return;
    }
    this.#wire = wire;
    // A pipe let go of from this end is as lost as one that broke: nothing says so but this.
    this.#hangUp = () => {
      wire.close();
      closed();
    };
    const w = codec.writer();
    codec.putU8(w, 1);
    codec.putU8(w, 4); // telling who wrote what
    codec.putBinary(w, ZERO16 + ZERO16);
    codec.putVarint(w, 0);
    codec.putBytes(w, this.#host.credential);
    this.#frame(HELLO, w);
  }

  #lost(): void {
    const well = this.#ready && !this.#faulted;
    this.#forgetHeard();
    this.#wire = undefined;
    this.#ready = false;
    this.#authors.clear();
    // All of this client's own first, the next pipe asked for too: then those told of it, whatever they do.
    for (const set of [this.#calls, this.#answers]) {
      for (const live of set.values()) this.#faults.set(live, "lost");
      set.clear();
    }
    for (const window of this.#windows.values()) {
      for (const page of window.pages) page.settled = false;
      this.#touch(window);
    }
    for (const a of [...this.#asked.values()]) {
      if (a.stopped) this.#unasked(a);
      else if (a.status === "ready") {
        a.status = "stale";
        this.#touchAnswer(a);
      }
    }
    this.#sweep();
    if (!this.#closed || this.#pending.length > 0) {
      // Soon after a pipe that was well; later and later after each that never came up, or that the node found fault
      // with, since what this client says it would say again.
      if (well) this.#failures = 0;
      const wait = Math.min(100 * 2 ** this.#failures, 10000);
      this.#failures++;
      this.#after(wait, () => this.#dial());
    }
    for (const live of [...this.#faults.keys()]) this.#fault(live);
    this.#tell("status", false);
  }

  /**
   * Ends the client, saying first whatever is still to be said: what editors have typed is sealed, pipe or none, and nothing
   * it wrote is dropped. The pipe is let go of once all of that is acknowledged, durable on the node this client speaks to,
   * at once when nothing waits; until then the client dials again should the pipe be lost, as an open one does, and does
   * nothing else. Resolves then. Rejects only should what it wrote never be durable: no node to dial, one that refuses this
   * client for good, or a scope it may no longer write in; or should `signal` give up on it, when the client dials no more,
   * and the error, Undelivered, says how much was never delivered. A promise that has not settled is the client still
   * trying: nothing is ever dropped unsaid. Questions asked once are answered as far as they got.
   */
  close(options: { signal?: AbortSignal } = {}): Promise<void> {
    const signal = options.signal;
    let forget = () => {};
    if (signal) {
      // Given up on, now or later: what it holds is told it never will be delivered, and it dials no more.
      // Given up on before it was closed, nothing is sealed, sent or dialled for first.
      const giveUp = () => this.#abandon(new Undelivered(0, 0, 0, true));
      if (signal.aborted) giveUp();
      else signal.addEventListener("abort", giveUp, { once: true }), (forget = () => signal.removeEventListener("abort", giveUp));
    }
    if (this.#closing) return void this.#closing.then(forget, forget), this.#closing;
    this.#closed = true;
    const after = () => {
      // Nothing else is left to be done later: a closed client keeps nothing awake but the delivery of what it wrote.
      for (const cancel of [...this.#timers]) cancel();
      for (const a of [...this.#asked.values()]) this.#fetched(a);
      for (const live of [...this.#faults.keys()]) this.#fault(live); // calls never made end here, as those made do
    };
    const deliver = (): Promise<void> => {
      this.#sealAll();
      if (this.#abandoned) {
        // Given up on, or refused, before it got here: what was sealed since is given up too, and said to be, with the rest,
        // never sent, though it was framed.
        this.#out = codec.writer();
        const why = this.#abandon(this.#abandoned);
        this.#hangUp();
        after();
        // Given up on with nothing to give up, nothing is lost: unless something it wrote never was delivered.
        if (why instanceof Undelivered && why.cells === 0) {
          if (this.#owed) this.#take();
          return this.#neverDelivered ? Promise.reject(this.#neverDelivered) : Promise.resolve();
        }
        return Promise.reject(why);
      }
      this.#flush();
      if (this.#pending.length === 0) {
        this.#hangUp();
        after();
        // At once: nothing to deliver; unless something it wrote never will be.
        if (this.#owed) this.#take();
        return this.#neverDelivered ? Promise.reject(this.#neverDelivered) : Promise.resolve();
      }
      after();
      const lost = () => {
        if (this.#neverDelivered) throw this.#neverDelivered; // the rest delivered, but not all
      };
      const delivered = this.#barrier().then(lost);
      const end = () => {
        for (const cancel of [...this.#timers]) cancel();
        if (this.#wire) this.#hangUp();
      };
      delivered.then(end, end);
      if (!this.#wire) this.#dial(); // now, rather than as an open client would have later
      return handled(delivered);
    };
    // Questions are answered as far as they got: so are those for rows editors typed in before they were here, and what
    // they typed is typed in them, to be sealed with the rest.
    const early = [...this.#early];
    if (early.length > 0) after();
    this.#closing = handled(early.length === 0 ? deliver() : Promise.all(early).then(deliver));
    this.#closing.then(forget, forget);
    return this.#closing;
  }

  // Gives up on all it holds, and anything sealed after: why it never will be delivered, Undelivered counting all of it.
  #abandon(why: Error): Error {
    this.#abandoned = why;
    const told = why instanceof Undelivered ? this.#undelivered(true) : why;
    this.#giveUp(told);
    if (why instanceof Undelivered) this.#abandoned = told;
    return told;
  }

  // What was never to be delivered, and nobody was told: told now, once.
  #take(): Error {
    const e = this.#owed!;
    this.#owed = undefined;
    return e;
  }

  // How much is written and not yet acknowledged, as an error to give up on it with: and, closed, what was given up already.
  #undelivered(closed: boolean, upTo = Infinity): Undelivered {
    const rows = new Set<string>();
    let cells = 0, bytes = 0;
    for (const p of closed ? [...this.#givenUp, ...this.#pending] : this.#pending) {
      if (p.seq > upTo) break;
      for (const id of p.rows) rows.add(id);
      cells += p.cells;
      bytes += p.body.length;
    }
    return new Undelivered(rows.size, cells, bytes, closed);
  }

  [unacknowledged](): boolean {
    return this.#pending.length > 0 || this.#early.size > 0;
  }

  [sealNow](): void {
    if (this.#abandoned) return; // nothing more is delivered
    // What editors typed before their rows were here is typed in them now, as held, as it would be were they looked for and
    // not found: there is no time to wait for them, the tab going.
    for (const row of this.#rows.values()) {
      const awaited = row.awaited;
      if (awaited === undefined || awaited.length === 0) continue;
      row.awaited = undefined;
      for (const f of awaited) f();
    }
    this.#sealAll();
    this.#flush();
  }

  // What editors have typed and not yet sealed, sealed, as the client ends or its tab is put away.
  #sealAll(): void {
    for (const row of this.#rows.values()) for (const [slot, t] of row.texts ?? []) if (t.open !== "") this.#seal(row, slot);
  }

  // Resolves once everything written so far is acknowledged; rejects should any of it never be, once the rest is: what was
  // refused never cuts short the delivery of anything else.
  #barrier(): Promise<void> {
    const owed = this.#owed && this.#take(); // something written before it never will be
    const last = this.#pending[this.#pending.length - 1];
    if (!last) return owed ? Promise.reject(owed) : Promise.resolve();
    return new Promise((resolve, reject) => this.#barriers.push({ seq: last.seq, failed: owed, resolve, reject }));
  }

  // Those waiting for what is no longer pending are told: all written before them is acknowledged, or some never will be.
  #unbar(): void {
    const lowest = this.#pending.length > 0 ? this.#pending[0].seq : Infinity;
    while (this.#barriers.length > 0 && this.#barriers[0].seq < lowest) {
      const b = this.#barriers.shift()!;
      if (b.failed) b.reject(b.failed);
      else b.resolve();
    }
  }

  // What was written that can never be durable is pending no more, and whoever waits for it is told so.
  #fail(p: Pending, e: Error): void {
    this.#pending.splice(this.#pending.indexOf(p), 1);
    this.#settle(p);
    let told = false;
    for (const b of this.#barriers) if (b.seq >= p.seq) (b.failed ??= e), (told = true);
    if (!told) this.#owed ??= e; // nobody waits for it yet: whoever next does is told
    this.#neverDelivered ??= e;
    for (const t of p.texts) this.#refusedTexts.set(t, e); // and the editor of each text in it, whoever else is told
    p.fail(e);
    this.#unbar();
  }

  #giveUp(e: Error): void {
    for (const p of [...this.#pending]) this.#givenUp.push(p), this.#fail(p, e);
  }

  // Runs f later, unless the client is closed first, with nothing it wrote still to deliver; returns a way to cancel it.
  #after(ms: number, f: () => void): () => void {
    if (this.#closed && this.#pending.length === 0) return () => {};
    let stop = (): void => {};
    const cancel = (): void => {
      if (this.#timers.delete(cancel)) stop();
    };
    this.#timers.add(cancel);
    stop = this.#host.after(ms, () => {
      this.#timers.delete(cancel);
      f();
    });
    return cancel;
  }

  #frame(kind: number, w?: codec.Writer): void {
    const out = this.#out;
    codec.putVarint(out, 1 + (w ? w.pos : 0));
    codec.putU8(out, kind);
    if (w) codec.put(out, codec.written(w));
    this.#later();
  }

  // Everything said and shown in one turn goes out, and is told to observers, together.
  #later(): void {
    if (!this.#flushing) {
      this.#flushing = true;
      this.#host.defer(() => this.#flush());
    }
  }

  #flush(): void {
    this.#flushing = false;
    // Rows with live text to send: only those, however many rows are held.
    const typing = this.#typing;
    this.#typing = new Set();
    for (const row of typing) if (row.dirty && row.dirty.size > 0) this.#sendLive(row);
    const out = this.#out;
    if (this.#abandoned) out.pos = 0; // a client given up on, or refused for good, sends nothing more
    if (out.pos > 0 && this.#wire) {
      // A piece at a time, for a pipe is a stream of bytes, and its messages may be no bigger than zspd's WebSockets take,
      // 8 MiB: a burst of writes bigger than that, said again every time the pipe is dialled, would break it every time.
      // Emptied first, for sending may break the pipe, or say more, there and then: what is left is for the pipe it was for.
      const written = codec.written(out).slice(); // a piece of its own each, which a pipe may hand on as it is
      out.pos = 0;
      const wire = this.#wire;
      for (let at = 0; at < written.length && this.#wire === wire; at += MESSAGE_MOST) wire.send(written.slice(at, at + MESSAGE_MOST));
    }
    try {
      for (const window of [...this.#windows.values()]) if (window.changed) this.#publish(window);
      for (const a of [...this.#asked.values()]) {
        if (a.changed && !a.stopped) {
          a.changed = false;
          this.#hand(a.observer, this.#answer(a));
        }
      }
    } finally {
      this.#forgetHeard();
    }
  }

  // Keeps what has come of a frame not yet whole, which needs so many bytes at least to be: or, of none, nothing. A copy:
  // what is given may be given again, written over, once taken.
  #hold(rest?: Uint8Array, wants = 0): void {
    this.#input = rest && rest.length > 0 ? [rest.slice()] : [];
    this.#inputBytes = rest?.length ?? 0;
    this.#inputWants = wants;
  }

  // The bodies of long cells just heard are let go of: once what was heard is shown, or the pipe is ended without it being
  // so. (A text made later reads them from their cells.)
  #forgetHeard(): void {
    if (this.#heardBytes > 0) this.#heardBodies.clear(), (this.#heardBytes = 0);
  }

  #receive(data: Uint8Array): void {
    let s = data;
    if (this.#input.length > 0) {
      this.#input.push(data.slice());
      this.#inputBytes += data.length;
      if (this.#inputBytes < this.#inputWants) return;
      s = new Uint8Array(this.#inputBytes);
      let at = 0;
      for (const piece of this.#input) s.set(piece, at), (at += piece.length);
      this.#hold();
    }
    let at = 0;
    while (at < s.length) {
      // A frame's length, if it is all there.
      let n = 0, scale = 1, p = at;
      for (;;) {
        if (p >= s.length) {
          this.#hold(s.subarray(at), s.length - at + 1);
          return;
        }
        const b = s[p++];
        if (p - at > 5) {
          // no frame is so long
          this.#hold();
          this.#faulted = true;
          this.#hangUp();
          return;
        }
        n += (b & 127) * scale;
        if (b < 128) break;
        scale *= 128;
      }
      if (p + n > s.length) {
        this.#hold(s.subarray(at), p + n - at);
        return;
      }
      const r = codec.reader(s.subarray(p, p + n));
      at = p + n;
      const wire = this.#wire;
      try {
        this.#handle(codec.u8(r), r);
      } catch (e) {
        if (!(e instanceof codec.Malformed)) {
          // What is thrown while a frame is read, as by a host, which no code of an application can be: the pipe is read on
          // from the frame after, on a turn of its own, rather than losing the rest and reading on from inside a frame.
          if (this.#wire === wire) {
            this.#hold(s.subarray(at));
            this.#host.defer(() => this.#wire === wire && this.#receive(new Uint8Array(0)));
          }
          throw e;
        }
        // Nonsense from the pipe ends the pipe and nothing else.
        this.#hold();
        this.#faulted = true;
        this.#hangUp();
        return;
      }
      if (this.#wire !== wire) return; // let go of, by what it said or by whoever was told of it: nothing more is read from it
    }
    this.#hold();
    this.#later();
  }

  #handle(kind: number, r: codec.Reader): void {
    if (this.#closed && kind !== ACK && kind !== ROSTER && kind !== ERROR) return; // closed, it only delivers what it wrote
    switch (kind) {
      case CELLS:
        return this.#onCells(r);
      case LIVE:
        return this.#onLive(r);
      case SYNCED:
        return this.#onSynced(r);
      case ANSWER:
        return this.#onAnswer(r);
      case ACK:
        return this.#onAck(codec.varint(r));
      case FLOW:
        return this.#onFlow(r);
      case CALL:
        return this.#onCall(r);
      case AUTHOR: {
        const number = codec.varint(r);
        const id = codec.hex(codec.take(r, 32));
        const who: Device = Object.freeze({ id, subject: fromUtf8.decode(codec.bytes(r)) });
        const was = this.#authors.get(number);
        this.#authors.set(number, who);
        if (number === 0 && !(was && was.id === id && was.subject === who.subject)) this.#tell("self", who);
        return;
      }
      case ROSTER:
        return this.#onScopes(r);
      case PRESENCE: {
        const devices: Device[] = [];
        while (r.pos < r.len) {
          const id = codec.hex(codec.take(r, 32));
          devices.push(Object.freeze({ id, subject: fromUtf8.decode(codec.bytes(r)) }));
        }
        this.#devices = Object.freeze(devices);
        this.#tell("devices", this.#devices);
        return;
      }
      case ERROR: {
        const code = codec.u8(r);
        this.#faulted = true;
        this.#tell("error", code);
        if (code === 2 || code === 3) {
          // Refused, or speaking another language: trying again is no use, and what is pending never will be durable, nor
          // anything it seals as it closes: it dials no more.
          this.#abandon(new Error(code === 2 ? "the node refused this client" : "the node speaks another version"));
          void this.close();
        }
        return;
      }
    }
  }

  #onScopes(r: codec.Reader): void {
    this.#heard(codec.takeBinary(r, 8));
    this.#scopes.clear();
    for (const a of this.#asked.values()) {
      const said: Said = new Map();
      for (const id of a.ids) said.set(id, new Set());
      a.said = said;
    }
    while (r.pos < r.len) {
      const scope = codec.varint(r);
      const rights = codec.u8(r);
      this.#scopes.set(scope, { rights, key: codec.take(r, 32).slice() });
    }
    if (this.#ready) {
      if (this.#closed) return;
      // Rights have changed: windows waiting for this one open.
      for (const window of this.#windows.values()) {
        if (window.denied && this.#scopes.has(window.scope)) {
          for (const page of window.pages) this.#watch(page);
          if (window.pages.length === 0) this.#open(window);
          window.denied = false;
          this.#touch(window);
        }
      }
      for (const a of [...this.#asked.values()]) if (a.status === "denied" && !a.stopped) this.#ask(a, a.question, true);
      this.#tell("status", true);
      return;
    }
    this.#ready = true;
    // Say again whatever the last pipe was told: what is served, unacknowledged and watched. What this client may no
    // longer write in is let go of, never to be durable: a node would refuse it, and this client with it, for good.
    if (!this.#closed) for (const key of this.#handlers.keys()) this.#serve(key, true);
    for (const p of [...this.#pending]) {
      if (!this.may(p.scope, "write")) {
        this.#fail(p, new Error("this client may no longer write there"));
        continue;
      }
      const w = codec.writer();
      codec.putVarint(w, p.seq);
      codec.put(w, p.body);
      this.#frame(CELLS, w);
    }
    if (this.#closed) return; // and nothing more
    for (const window of this.#windows.values()) {
      if (window.pages.length === 0) this.#open(window);
      else for (const page of window.pages) this.#watch(page);
    }
    for (const a of [...this.#asked.values()]) this.#ask(a, a.question, true); // and none asked meanwhile, twice
    this.#tell("status", true);
  }

  // ---------------------------------------------------------------- observing things that are not windows

  // Calls code that is not this client's own, once all that this client does of its own is done: what it throws is its
  // own, thrown on a turn of its own, so that whoever else was to hear does, and nothing of this client is left half done.
  // A call's own callbacks are called on it, as its methods.
  #hand<A>(f: (a: A) => unknown, a: A, that?: unknown): unknown {
    try {
      return f.call(that, a);
    } catch (e) {
      this.#host.defer(() => {
        throw e;
      });
      return undefined;
    }
  }

  // Each hears, whatever another does, if it is hearing still; and once something else is told of the same, as "status" is
  // by close(), the rest hear that, rather than what is no longer so.
  #tell<E extends Event>(what: E, value: Told[E]): void {
    const set = this.#watchers.get(what);
    if (!set) return;
    const told = (this.#tells.get(what) ?? 0) + 1;
    this.#tells.set(what, told);
    for (const f of [...set]) {
      if (this.#tells.get(what) !== told) return;
      if (set.has(f)) this.#hand(f, value);
    }
  }

  /**
   * Hears of "status" (connected or not), "devices" (those reachable, this one first), "self" (this device, and whom this
   * client goes by) or "error" (a code from the node). Told at once of what is known. Returns a way to stop.
   */
  on<E extends Event>(what: E, f: (value: Told[E]) => void): () => void {
    let set = this.#watchers.get(what);
    if (!set) this.#watchers.set(what, (set = new Set()));
    // Each is its own, though the same function hear twice: stopping one stops no other.
    const own = (value: Told[E]) => f(value);
    set.add(own);
    // What is known is told at once, and what that throws is thrown later: the caller has the way to stop it first.
    if (what === "status") this.#hand(f as (v: boolean) => void, this.#ready);
    else if (what === "devices") this.#hand(f as (v: readonly Device[]) => void, this.#devices);
    else if (what === "self" && this.#authors.has(0)) this.#hand(f as (v: Device) => void, this.#authors.get(0)!);
    return () => void set.delete(own);
  }

  /** Whether the pipe is up and the node has said what this client may do. */
  get ready(): boolean {
    return this.#ready;
  }

  /** Those reachable, this device first. */
  get devices(): readonly Device[] {
    return this.#devices;
  }

  // ---------------------------------------------------------------- windows

  /** Whether what is written in a scope may be read here, or written, or its methods called. "status" is told when it changes. */
  may(scope: number, what: "read" | "write" | "call"): boolean {
    const s = this.#scopes.get(scope);
    return s !== undefined && (s.rights & (what === "read" ? 1 : what === "write" ? 2 : 4)) !== 0;
  }

  /** The tag of a list, as a binary string. */
  tag(scope: number, list: string): string {
    const s = this.#scopes.get(scope);
    if (!s) throw new Error("no such scope");
    const k = scope + "/" + codec.binary(s.key) + list;
    let tag = this.#tags.get(k);
    if (tag === undefined) {
      const name = utf8.encode(list);
      const input = new Uint8Array(32 + name.length);
      input.set(s.key);
      input.set(name, 32);
      tag = codec.u32Binary(scope) + codec.binary(sha256(input), 0, 12);
      this.#tags.set(k, tag);
    }
    return tag;
  }

  /** Observes a list. The observer hears the current state at once, and every change after, at most once a turn. */
  window<T extends Table>(query: Query<T>, observer: (state: State<T>) => void): Window {
    const from = query.from ?? "end";
    let shape = this.#shapes.get(query.table);
    if (shape === undefined) this.#shapes.set(query.table, (shape = ++this.#nextShape));
    const size = query.size ?? 50;
    if (!Number.isSafeInteger(size) || size < 0) throw new RangeError("a page's size is a whole number");
    whole(query.scope);
    // A list is named by a string, as its tag is made of one: else it is refused here, not once it is opened, maybe on a
    // pipe come up, where it would stop all that comes after it.
    if (typeof query.list !== "string") throw new TypeError("a list's name is a string");
    const key = `${query.scope}/${from}/${size}/${shape}/${query.bare === true}/${query.list}`;
    let window = this.#windows.get(key);
    if (!window) {
      window = {
        key,
        scope: query.scope,
        list: query.list,
        schema: query.table,
        size,
        back: from !== "start",
        pages: [],
        keys: [],
        held: [],
        at: new Map(),
        bare: query.bare === true,
        observers: new Set(),
        watching: 0,
        changed: false,
        denied: false,
      };
      this.#windows.set(key, window);
      if (this.#ready) this.#open(window);
    }
    const win = window;
    if (win.linger) {
      win.linger();
      win.linger = undefined;
    }
    // Each observer is its own, though the same function observe twice.
    const own = (state: State<any>) => observer(state);
    win.observers.add(own);
    win.watching++;
    this.#hand(own, win.bare ? (undefined as unknown as State<T>) : this.#state(win));
    let stopped = false;
    return Object.freeze({
      // A window stopped is looked at no more by whoever stopped it: what they ask of it then asks for nothing, as it may
      // be let go of already, and a page asked for of it would be watched for good.
      visible: (first: number, last: number) => void (stopped || this.#visible(win, first, last)),
      loadBefore: () => void (stopped || this.#loadBefore(win)),
      loadAfter: () => void (stopped || this.#loadAfter(win)),
      entries: () => win.keys.map((key, i) => ({ key, row: win.held[i] })),
      stop: () => {
        if (stopped) return;
        stopped = true;
        win.observers.delete(own);
        win.watching--;
        if (win.watching === 0) {
          // Whoever comes back soon finds it still warm.
          win.linger = this.#after(this.#host.linger, () => this.#forget(win));
        }
      },
    });
  }

  #open(window: Win): void {
    if (!this.#scopes.has(window.scope)) {
      window.denied = true;
      this.#touch(window);
      return;
    }
    window.denied = false;
    const tag = this.tag(window.scope, window.list);
    const page = this.#page(window, tag + ZERO24, codec.after(tag));
    window.pages.push(page);
    this.#watch(page, window.size, window.back);
  }

  #page(window: Win, lo: string, hi: string): Page {
    const page: Page = { id: ++this.#nextPage, window, lo, hi, open: true, settled: false, before: 0, after: 0, limit: 0, back: false };
    this.#pages.set(page.id, page);
    return page;
  }

  #watch(page: Page, limit?: number, back?: boolean, adopt?: boolean): void {
    if (limit !== undefined) (page.limit = limit), (page.back = back === true);
    const w = codec.writer();
    codec.putVarint(w, page.id);
    codec.putU8(w, W_DATA + W_LIVE + W_COUNTS + (page.back ? W_BACK : 0) + (adopt ? W_ADOPT : 0));
    codec.putKey(w, page.lo);
    codec.putKey(w, page.hi);
    codec.putVarint(w, page.limit);
    if (!adopt) this.#mark(page);
    this.#frame(WATCH, w);
  }

  // What is not mentioned before the next sync is gone.
  #mark(page: Page): void {
    const stale: Said = new Map();
    const { keys, held } = page.window;
    for (let i = 0; i < keys.length; i++) if (keys[i] >= page.lo && keys[i] < page.hi) stale.set(held[i].id, new Set());
    page.stale = stale;
  }

  #dropPage(page: Page): void {
    this.#pages.delete(page.id);
    const w = codec.writer();
    codec.putVarint(w, page.id);
    this.#frame(UNWATCH, w);
  }

  #onSynced(r: codec.Reader): void {
    const page = this.#pages.get(codec.varint(r));
    if (!page) return;
    const window = page.window;
    const flags = codec.u8(r);
    if (flags & 4) {
      window.denied = true;
      this.#touch(window);
      return;
    }
    if (flags & 2) {
      this.#mark(page);
      return;
    }
    const was = [page.lo, page.hi];
    page.lo = codec.key(r);
    page.hi = codec.key(r);
    page.limit = 0; // from here on it is a range, however many are in it
    page.before = codec.varint(r);
    page.after = codec.varint(r);
    page.settled = (flags & 1) !== 0;
    page.open = false;
    const stale = page.stale;
    page.stale = undefined;
    if (stale) {
      for (const [id, said] of stale) {
        const row = this.#rows.get(id);
        if (row && said.size > 0) this.#prune(row, said);
        else if (row && !this.#isPending(id)) this.#unplace(row, page.lo, page.hi);
      }
    }
    // A page at an end of the window may come to end short of where it was first said to, as one a partial replica
    // answered at once from what it held ends where a full one says: what the window showed beyond it is had again by
    // the page that follows, rather than let go of unseen. By that page, and no more: what it was asked for to have
    // again may lie anywhere beyond, and it may itself be answered at once with more from anywhere beyond, and be cut
    // short in turn; a page after it, and after that, would follow what is held a page at a time, as far as it went, the
    // window never settled, and growing all the while, as when a replica is being brought level from the far end of
    // the list.
    const cut = (lo: string, hi: string) => !page.keeps && lo < hi && window.keys.some((key) => key >= lo && key < hi);
    const after = page === window.pages[window.pages.length - 1] && cut(page.hi, was[1]);
    const before = page === window.pages[0] && cut(was[0], page.lo);
    // Where a full replica says the page ends, what lay past it was never known to be whole.
    this.#trim(window);
    if (after) this.#loadAfter(window, true);
    if (before) this.#loadBefore(window, true);
  }

  // A range was said over again and this row was not in it: it was moved away, or deleted, while this client was not
  // listening. Only its place there is known to be wrong. Where else it is, and what is being typed in it, stand.
  #unplace(row: Stored, lo: string, hi: string): void {
    for (const slot of slotsOf(row)) {
      if (slot > 15 || slot === 0) continue;
      const v = slotOf(row, slot)!;
      if (typeof v === "string") {
        const key = placeKey(v, row.id);
        if (key >= lo && key < hi) {
          setSlot(row, slot, undefined);
          forgetAuthor(row, slot, stampOf(v));
        }
      } else {
        for (const [stamp, c] of [...v]) {
          const key = placeKey(c, row.id);
          if (key >= lo && key < hi) {
            v.delete(stamp);
            forgetAuthor(row, slot, stamp);
          }
        }
        compact(row, slot);
      }
    }
    this.#place(row);
  }

  // A row was said over again, whole: what was not said is there no longer, and nothing has said that it went. What is
  // yet to be acknowledged may not have been there to say.
  #prune(row: Stored, said: Set<string>): void {
    if (this.#isPending(row.id)) return;
    // Which slots lost something, first: what is done for each may write in the row.
    const gone: number[] = [];
    eachSlot(row, (slot, v) => {
      if (typeof v === "string" ? !said.has(stampOf(v)) : [...v.keys()].some((stamp) => !said.has(stamp))) gone.push(slot);
    });
    for (const slot of gone) {
      const v = slotOf(row, slot);
      if (typeof v === "string") {
        forgetAuthor(row, slot, stampOf(v));
        setSlot(row, slot, undefined);
      } else if (v !== undefined) {
        for (const stamp of [...v.keys()]) {
          if (!said.has(stamp)) {
            v.delete(stamp);
            forgetAuthor(row, slot, stamp);
          }
        }
        compact(row, slot);
      }
      this.#rebuild(row, slot);
    }
    if (gone.length > 0) {
      unview(row);
      this.#place(row);
    }
  }

  #isPending(id: string): boolean {
    return this.#unacked.has(id);
  }

  #loadBefore(window: Win, keeps = false): void {
    const first = window.pages[0];
    if (!first || first.open || !first.settled || first.before === 0 || !this.#ready) return;
    const tag = first.lo.slice(0, 16);
    const page = this.#page(window, tag + ZERO24, first.lo);
    page.keeps = keeps;
    window.pages.unshift(page);
    this.#watch(page, window.size, true);
    this.#touch(window);
  }

  #loadAfter(window: Win, keeps = false): void {
    const last = window.pages[window.pages.length - 1];
    if (!last || last.open || !last.settled || last.after === 0 || !this.#ready) return;
    const page = this.#page(window, last.hi, codec.after(last.lo.slice(0, 16)));
    page.keeps = keeps;
    window.pages.push(page);
    this.#watch(page, window.size, false);
    this.#touch(window);
  }

  #visible(window: Win, first: number, last: number): void {
    // A window of all of a list is one page, however long it grows, and has nothing beyond it to load.
    if (window.pages.length === 0 || !this.#ready || window.size === 0) return;
    const near = Math.floor(window.size / 2);
    if (first <= near) this.#loadBefore(window);
    if (last > window.keys.length - near) this.#loadAfter(window);
    // A page that has grown far past its size is two pages.
    for (let i = 0; i < window.pages.length; i++) {
      const page = window.pages[i];
      const [lo, hi] = this.#span(window, page);
      if (!page.open && hi - lo > window.size * 2) {
        const middle = window.keys[Math.floor((lo + hi) / 2) - 1];
        const upper = this.#page(window, middle, page.hi);
        upper.open = false;
        upper.settled = page.settled;
        upper.after = page.after;
        page.hi = middle;
        window.pages.splice(i + 1, 0, upper);
        this.#watch(upper, 0, false, true);
        this.#watch(page, 0, false, true);
        break;
      }
    }
    // And pages far from anything visible are let go, outermost first.
    while (window.pages.length > 1) {
      const [, hi] = this.#span(window, window.pages[0]);
      if (window.pages[0].open || hi + window.size * 2 >= first) break;
      const gone = window.pages.shift()!;
      window.pages[0].before = Math.max(window.pages[0].before, gone.before + hi - 1);
      this.#dropPage(gone);
      this.#trim(window);
      first -= hi - 1;
      last -= hi - 1;
    }
    while (window.pages.length > 1) {
      const page = window.pages[window.pages.length - 1];
      const [lo] = this.#span(window, page);
      if (page.open || lo - window.size * 2 <= last) break;
      const count = window.keys.length - lo + 1;
      window.pages.pop();
      const edge = window.pages[window.pages.length - 1];
      edge.after = Math.max(edge.after, page.after + count);
      this.#dropPage(page);
      this.#trim(window);
    }
  }

  // Positions [lo, hi) of a page's entries, from 1.
  #span(window: Win, page: Page): [number, number] {
    return [this.#find(window, page.lo), this.#find(window, page.hi)];
  }

  // Position, from 1, of the first entry at or past a key.
  #find(window: Win, key: string): number {
    const keys = window.keys;
    let lo = 0, hi = keys.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (keys[mid] < key) lo = mid + 1;
      else hi = mid;
    }
    return lo + 1;
  }

  #trim(window: Win): void {
    const lo = window.pages[0].lo, hi = window.pages[window.pages.length - 1].hi;
    const { keys, held } = window;
    // What lies outside is let go of; what is kept stays where it is, and is known where it was.
    let n = 0;
    for (let i = 0; i < keys.length; i++) {
      const key = keys[i], row = held[i];
      if (key >= lo && key < hi) {
        keys[n] = key;
        held[n++] = row;
      } else {
        window.at.delete(row);
        this.#release(row);
      }
    }
    keys.length = held.length = n;
    this.#touch(window);
  }

  #forget(window: Win): void {
    this.#windows.delete(window.key);
    for (const page of window.pages) this.#dropPage(page);
    for (const row of window.held) this.#release(row);
  }

  #release(row: Stored): void {
    row.pages--;
    if (row.pages === 0 && !row.asking && !row.dead) this.#keep(row);
    if (row.pages === 0 && !row.held && !this.#isPending(row.id)) this.#rows.delete(row.id);
  }

  // Has a row that is being edited shown, if nothing else shows it, so that what others write in it is heard of too. Calls
  // back once it is here, or known not to be anywhere.
  #keep(row: Stored, here?: () => void): void {
    if (row.pages > 0 || !row.held) {
      here?.();
      return;
    }
    const question = { scope: codec.u32Of(row.id), table: {}, where: ask.where.ids([hexOf(row)]), limit: 1 };
    const release = () => {
      const awaited = row.awaited;
      row.awaited = undefined;
      for (const f of awaited ?? []) f();
    };
    if (here) {
      const awaited = (row.awaited ??= []);
      awaited.push(here);
      // Once, too: answered by one who holds everything if one can be reached, and otherwise with what is held, as a
      // partial replica with nobody to ask that can read answers it, never "ready". What waits for the row goes on then.
      if (awaited.length === 1) void this.fetch(question).then(release, release);
    }
    if (row.asking) return;
    const hear = (answer: Answer<any>) => {
      if (answer.rows.length > 0 || answer.status === "ready" || answer.status === "denied" || answer.status === "faulty") release();
    };
    const asked = this.ask(question, hear);
    if (row.held) row.asking = asked.stop;
    else asked.stop();
  }

  #touch(window: Win): void {
    window.changed = true;
    window.state = undefined;
    this.#later();
  }

  #state(window: Win): State<any> {
    if (window.state) return window.state;
    const held = window.held;
    const rows = window.keys.map((key, i) => this.#view(held[i], window.schema, key));
    let status: Status = "ready";
    for (const page of window.pages) {
      if (page.open) {
        status = "loading";
        break;
      } else if (!page.settled) status = "stale";
    }
    if (window.pages.length === 0) status = "loading";
    if (window.denied) status = "denied";
    const first = window.pages[0], last = window.pages[window.pages.length - 1];
    const made: State<any> = Object.freeze({
      rows: Object.freeze(rows),
      status,
      before: first ? first.before : 0,
      after: last ? last.after : 0,
    });
    window.state = made;
    return made;
  }

  #publish(window: Win): void {
    window.changed = false;
    const state = window.bare ? (undefined as unknown as State<any>) : this.#state(window);
    // Only to those observing still, and only while it is so: once it changes, the rest are told of it as it is then.
    for (const f of [...window.observers]) {
      if (window.changed) return;
      if (window.observers.has(f)) this.#hand(f, state);
    }
  }

  // A row as the application sees it: one frozen object, the same one until something in it changes.
  #view(row: Stored, schema: Table, key: string): Row<any> {
    const view = row.views?.get(schema);
    const order = codec.fromU64(key, 16);
    if (view && view.order === order) return view;
    const made: Record<string, unknown> = { id: hexOf(row), order };
    for (const name in schema) {
      const c = schema[name];
      if (c.who) {
        const v = whose(row, c.slot, c.who === "all");
        if (v !== undefined) made[name] = v;
      } else if (c.text) {
        made[name] = this.readText(row, c.slot);
      } else {
        const cell = latest(row, c.slot);
        if (cell !== undefined) {
          // What cannot be read is no value: anyone may write anything in a slot.
          let value: unknown;
          try {
            value = c.decode(bodyOf(cell));
          } catch {
            value = undefined;
          }
          if (value !== undefined) made[name] = value;
        }
      }
    }
    Object.freeze(made);
    (row.views ??= new Map()).set(schema, made as Row<any>);
    return made as Row<any>;
  }

  /**
   * What a text column of a held row reads as. One that nothing has been typed in, only set, is what was set: there is no
   * text to make of it until someone types, or reads it as a text. For what is built on the client.
   */
  readText(row: Stored, slot: number): string {
    const t = row.texts?.get(slot);
    if (t) return text.read(t);
    const v = slotOf(row, slot);
    if (v === undefined) return "";
    if (typeof v === "string" && v.charCodeAt(0) === VALUE) return fromUtf8.decode(bodyOf(v));
    return text.read(this.#text(row, slot));
  }

  // ---------------------------------------------------------------- rows

  #row(id: string): Stored {
    let row = this.#rows.get(id);
    if (!row) this.#rows.set(id, (row = newRow(id)));
    return row;
  }

  // Whether anything listens for what is said again, as a page or a question being sent afresh does.
  #saying(): boolean {
    for (const page of this.#pages.values()) if (page.stale) return true;
    for (const a of this.#asked.values()) if (a.said) return true;
    return false;
  }

  #onCells(r: codec.Reader): void {
    // What came before any nonsense in a message is placed, as it is held; and so is let go of what has nothing in it.
    const touched = new Set<Stored>();
    try {
      this.#readCells(r, touched);
    } catch (e) {
      this.#forgetHeard(); // nonsense ends the pipe, and nothing may be shown soon
      throw e;
    } finally {
      this.#placeAll(touched);
    }
  }

  #readCells(r: codec.Reader, touched: Set<Stored>): void {
    codec.varint(r);
    const buf = r.buf, len = r.len;
    let pos = r.pos;
    const rows = this.#rows;
    const saying = this.#saying();
    let id = "";
    // The row, once held: one is made, and is touched, only for a cell that is kept, so that nothing is made or told of
    // for what is nonsense or passed over.
    let row: Stored | undefined;
    let last: Stored | undefined; // touched last
    while (pos < len) {
      const tag = buf[pos++];
      if (tag < 128) {
        if (pos + 16 > len) throw new codec.Malformed();
        id = codec.binary(buf, pos, pos + 16);
        pos += 16;
        row = rows.get(id);
      } else if (id === "") {
        throw new codec.Malformed(); // the same row as no row before it
      }
      if (pos + 17 > len) throw new codec.Malformed();
      const slot = buf[pos];
      const at = pos + 1;
      r.pos = at + 16;
      const size = codec.varint(r);
      pos = r.pos;
      if (pos + size > len) throw new codec.Malformed();
      // What no node could have sent is nonsense, and ends the pipe: a kind there is not, in a slot not its kind's, a place
      // too short to say where, a bundle too short to hold what it says it does. What a node could have sent but would not
      // keep, as a place of another scope, is passed over, as it would be (see shaped).
      const kind = tag % 64;
      if (
        kind === VALUE || kind === PIECE
          ? slot < 16
          : kind === PLACE
            ? slot < 1 || slot > 15 || size < 24
            : kind === GRAVE
              ? slot !== 0
              : kind !== BUNDLE || slot < 16 || size < 4 || 4 + (((buf[pos] << 24) | (buf[pos + 1] << 16) | (buf[pos + 2] << 8) | buf[pos + 3]) >>> 0) * 16 > size
      )
        throw new codec.Malformed();
      // One held already, as a node says whole rows again when any of them changes: known by its stamp and kind, and passed
      // over without anything made of it. Another body for what is held is no news (SPEC.md 4), but of a bundle, which a node
      // may say again with less of it: that is looked at where it is.
      if (!(tag & 64) && row !== undefined && !row.dead) {
        const v = slotOf(row, slot);
        if (v !== undefined) {
          const stamp = codec.binary(buf, at, at + 16);
          const held = typeof v === "string" ? (cmp16(v, 1, stamp, 0) === 0 ? v : undefined) : v.get(stamp);
          // Of the shape a node keeps, as everything heard is looked at first in Luau: of a place, its prefix, the rest held.
          // (Nothing here loops but this loop, each cell once: V8, compiling a loop within it while it runs, would leave
          // that compiled code each time that loop ended, at a cost each time.)
          const fine = size <= MAX_CELL && (tag % 64 !== PLACE || placeFine(buf, pos, size, id));
          if (fine && held !== undefined && held.charCodeAt(0) === tag % 64 && (tag % 64 !== BUNDLE || held.length === 17 + size)) {
            if (tag % 64 !== BUNDLE || sameBody(held, buf, pos, size)) {
              pos += size;
              if (row !== last) touched.add((last = row)); // said again, it is placed again, as where it is may be news
              if (saying) this.#said(id, stamp);
              continue;
            }
          }
        }
      }
      // The cell, one string: its kind, its stamp and its body, put side by side and read as one.
      if (scratch.length < 17 + size) scratch = new Uint8Array(Math.max(scratch.length * 2, 17 + size));
      scratch[0] = tag % 64;
      scratch.set(buf.subarray(at, at + 16), 1);
      scratch.set(buf.subarray(pos, pos + size), 17);
      const c = codec.binary(scratch, 0, 17 + size);
      const from = pos;
      pos += size;
      let author: Device | undefined;
      if (tag & 64) {
        r.pos = pos;
        author = this.#authors.get(codec.varint(r));
        pos = r.pos;
      }
      if (!shaped(id, slot, c)) continue; // what a node would not keep is passed over, as it would be
      if (row === undefined) rows.set(id, (row = newRow(id)));
      if (row !== last) touched.add((last = row));
      if ((tag % 64 === PIECE || tag % 64 === BUNDLE) && size > SLAB / 4 && this.#heardBytes + size <= HEARD_MOST) {
        this.#heardBodies.set(c, buf.slice(from, from + size));
        this.#heardBytes += size;
      }
      // What it says of the time, as late as anything heard of.
      const time = u32At(c, 1) * 65536 + ((c.charCodeAt(5) << 8) | c.charCodeAt(6));
      const n = (c.charCodeAt(7) << 8) | c.charCodeAt(8);
      if (time > this.#clockMs || (time === this.#clockMs && n > this.#clockN)) (this.#clockMs = time), (this.#clockN = n);
      if (saying) this.#said(id, c.slice(1, 17)); // only looked for again, once: so not made a string of its own
      if (author === undefined && !row.dead && !row.texts && tag % 64 !== GRAVE && slotOf(row, slot) === undefined) {
        // What almost every cell of a row heard for the first time is: one where there was none.
        setSlot(row, slot, c);
        row.version = ++versions;
        row.views = undefined;
      } else {
        this.#accept(row, slot, c, author);
      }
    }
    r.pos = pos;
  }

  // A stamp of a row said again, for the pages and questions being sent afresh that listen for what is.
  #said(id: string, stamp: string): void {
    for (const page of this.#pages.values()) page.stale?.get(id)?.add(stamp);
    for (const a of this.#asked.values()) a.said?.get(id)?.add(stamp);
  }

  #accept(row: Stored, slot: number, c: Held, author?: Device): boolean {
    if (!merge(row, slot, c, author)) {
      // Known already; but perhaps not whose it is, or by what name they go now.
      const stamp = stampOf(c);
      const v = slotOf(row, slot);
      const held = typeof v === "string" ? (cmp16(v, 1, c, 1) === 0 ? v : undefined) : v?.get(stamp);
      if (held !== undefined && author) {
        const authors = (row.authors ??= new Map());
        const was = authors.get(String.fromCharCode(slot) + stamp);
        if (!was || was.subject !== author.subject) unview(row);
        authors.set(String.fromCharCode(slot) + stamp, author);
      }
      if (held !== undefined && held.charCodeAt(0) === BUNDLE && c.charCodeAt(0) === BUNDLE && held !== c && held.slice(17) !== c.slice(17)) {
        // A bundle with less of it, since its author may no longer have written the rest (SPEC.md 4): another body for what
        // is held is otherwise no news.
        const less = held.slice(0, 17) + c.slice(17);
        if (typeof v === "string") setSlot(row, slot, less);
        else v!.set(stamp, less);
        this.#rebuild(row, slot);
      }
      return false;
    }
    const kind = c.charCodeAt(0);
    const t = row.texts?.get(slot);
    if (t && kind >= VALUE) {
      if (text.apply(t, kind, stampOf(c), textBody(c, this.#heardBodies)) === "rebuild") this.#rebuild(row, slot);
    }
    unview(row);
    return true;
  }

  // The text in a slot, made from its cells when first wanted.
  #text(row: Stored, slot: number): text.Text {
    let t = row.texts?.get(slot);
    if (!t) {
      t = text.create();
      (row.texts ??= new Map()).set(slot, t);
      const v = slotOf(row, slot);
      const sorted = typeof v === "string" ? [v] : v === undefined ? [] : [...v.values()].sort((a, b) => cmp16(a, 1, b, 1));
      for (const c of sorted) text.apply(t, kindOf(c), stampOf(c), textBody(c, this.#heardBodies));
    }
    return t;
  }

  #rebuild(row: Stored, slot: number): void {
    const old = row.texts?.get(slot);
    if (old && old.open !== "") this.#seal(row, slot); // nothing typed here may be lost with it
    if (row.texts) {
      row.texts.delete(slot);
      if (row.texts.size === 0) row.texts = undefined;
    }
    if (row.lives) {
      row.lives.delete(slot);
      if (row.lives.size === 0) row.lives = undefined;
    }
    unview(row);
  }

  // Puts a row where its placements say, in every window, and takes it from where they do not. Followers hear of it
  // first, unless they have been told already.
  #place(row: Stored, told = false): void {
    if (!told) this.#follow(row);
    let left = false; // some window it was in, which is let go of only once where it now is is known
    for (const window of this.#windows.values()) {
      if (window.pages.length === 0) continue;
      const want = wanted(row, window.pages[0].lo, window.pages[window.pages.length - 1].hi);
      const keys = window.keys;
      // Where it is now, found by where it was: keys are in order, and each is a row's own.
      const was = window.at.get(row);
      let have: number | undefined = was !== undefined ? this.#find(window, was) - 1 : undefined;
      const queued = this.#bulk?.get(window);
      if (have !== undefined && keys[have] !== was && queued) {
        // Not among them yet, but among those to be put in all at once: there it stays, or is taken out.
        if (want !== undefined) {
          window.at.set(row, want);
          continue;
        }
        queued.splice(queued.indexOf(row), 1);
        window.at.delete(row);
        row.pages--;
        left = true;
        continue;
      }
      if (have !== undefined && (want === undefined || keys[have] !== want)) {
        keys.splice(have, 1);
        window.held.splice(have, 1);
        window.at.delete(row);
        row.pages--;
        left = true;
        this.#touch(window);
        have = undefined;
      }
      if (want !== undefined && have === undefined) {
        const bulk = this.#bulk;
        if (bulk) {
          let add = bulk.get(window);
          if (!add) bulk.set(window, (add = []));
          add.push(row);
        } else {
          const at = this.#find(window, want) - 1;
          keys.splice(at, 0, want);
          window.held.splice(at, 0, row);
        }
        window.at.set(row, want);
        row.pages++;
        if (window.state || !window.changed) this.#touch(window);
      } else if (want !== undefined && (window.state || !window.changed)) {
        this.#touch(window);
      }
    }
    // A row moved within a window, or from one to another, never left what shows it: an editor of it needs no question.
    if (left && row.pages === 0 && !row.asking && !row.dead) this.#keep(row);
    this.#touchAsked(row);
    if (row.pages <= 0 && !row.held && (row.dead || !this.#isPending(row.id))) {
      if (this.#asked.size > 0 && !row.dead) this.#loose.add(row.id);
      else this.#rows.delete(row.id);
    }
  }

  // Places rows, each once. Many at once go into windows at once: sorted among themselves, and merged with what was there.
  // Followers hear of them all first, so that whatever they do of it is done before any row is half put, as one held
  // where it goes and not yet among the rows there.
  #placeAll(rows: Set<Stored>): void {
    if (rows.size <= 64 || this.#bulk) {
      for (const row of rows) this.#place(row);
      return;
    }
    for (const row of rows) this.#follow(row);
    this.#bulk = new Map();
    for (const row of rows) this.#place(row, true);
    this.#mergeBulk();
  }

  #mergeBulk(): void {
    const bulk = this.#bulk!;
    this.#bulk = undefined;
    for (const [window, add] of bulk) {
      const at = window.at;
      let keys = add.map((row) => at.get(row)!);
      let placed = add;
      let sorted = true;
      for (let i = 1; i < keys.length && sorted; i++) sorted = keys[i - 1] < keys[i];
      if (!sorted) {
        // By their keys, compared as they are in an array, not looked up for each comparison.
        const order = keys.map((_, i) => i).sort((x, y) => (keys[x] < keys[y] ? -1 : 1));
        placed = order.map((i) => add[i]);
        keys = order.map((i) => keys[i]);
      }
      const oldKeys = window.keys, oldHeld = window.held;
      const n = oldKeys.length, m = keys.length;
      if (n === 0 || (m > 0 && oldKeys[n - 1] < keys[0])) {
        for (let j = 0; j < m; j++) {
          oldKeys.push(keys[j]);
          oldHeld.push(placed[j]);
        }
      } else {
        const outKeys: string[] = new Array(n + m), outHeld: Stored[] = new Array(n + m);
        let i = 0, j = 0, k = 0;
        while (i < n || j < m) {
          if (i < n && (j >= m || oldKeys[i] < keys[j])) (outKeys[k] = oldKeys[i]), (outHeld[k++] = oldHeld[i++]);
          else (outKeys[k] = keys[j]), (outHeld[k++] = placed[j++]);
        }
        window.keys = outKeys;
        window.held = outHeld;
      }
    }
  }

  // ---------------------------------------------------------------- questions

  /**
   * Asks a question, which stays asked: the observer hears the answer, and again whenever it changes, at most once a turn.
   * Returns ways to look at another stretch of it, and to stop.
   */
  ask<T extends Table>(question: ask.Question & { table: T }, observer: (answer: Answer<T>) => void): Asking {
    ask.write(question, () => ZERO16); // or an error, here rather than later
    const a = this.#newAsked(question, observer as (answer: Answer<any>) => void);
    this.#asked.set(a.id, a);
    if (this.#ready) this.#ask(a);
    this.#hand(observer, this.#answer(a) as Answer<T>);
    return Object.freeze({
      // A stretch that cannot be asked for is refused at once, and what was asked stands: else it is said again on every
      // pipe, and refused there.
      move: (offset: number, limit?: number) => {
        const q = { ...a.question, offset, limit: limit ?? a.question.limit };
        if (this.#ready && !a.stopped) this.#ask(a, q);
        else ask.write(q, () => ZERO16), (a.question = q);
      },
      stop: () => {
        if (a.stopped) return;
        a.stopped = true;
        if (!this.#ready) this.#unasked(a);
        else {
          const w = codec.writer();
          codec.putVarint(w, a.id);
          this.#frame(UNASK, w);
        }
      },
    });
  }

  /**
   * Asks a question once, and waits for the answer: for a connection, should there be none, and for the index to be made.
   * Nothing is kept up afterwards, and the rows are as they were.
   */
  fetch<T extends Table>(question: ask.Question & { table: T }): Promise<Answer<T>> {
    ask.write(question, () => ZERO16);
    return new Promise((resolve) => {
      const a = this.#newAsked(question, () => {});
      a.once = resolve as (answer: Answer<any>) => void;
      this.#asked.set(a.id, a);
      if (this.#closed) this.#fetched(a);
      else if (this.#ready) this.#ask(a);
    });
  }

  #newAsked(question: ask.Question, observer: (answer: Answer<any>) => void): Asked {
    return {
      id: ++this.#nextAsk,
      question,
      schema: question.table as Table,
      totalsOf: [],
      observer,
      ids: [],
      shown: new Set(),
      stopped: false,
      status: "loading",
      progress: 0,
      total: 0,
      first: 0,
      totals: Object.freeze({}),
      changed: false,
    };
  }

  // Asks a question, or asks it now as it is to be, which it is only once it can be said. One asked again, for a pipe come
  // up or rights that came, that cannot be said, as one whose asker changed it since, is faulty: it alone, and at once.
  #ask(a: Asked, q = a.question, again = false): void {
    let may = this.#scopes.has(q.scope);
    let said: [Uint8Array, ask.Told[]];
    try {
      said = ask.write(q, (scope, name) => {
        if (this.#scopes.has(scope)) return this.tag(scope, name);
        may = false;
        return ZERO16;
      });
    } catch (e) {
      if (!again) throw e;
      a.status = "faulty";
      this.#show(a, []);
      this.#touchAnswer(a);
      this.#fetched(a);
      return;
    }
    a.question = q;
    const [body, totals] = said;
    if (!may) {
      a.status = "denied";
      this.#show(a, []);
      this.#touchAnswer(a);
      this.#fetched(a);
      return;
    }
    a.totalsOf = totals;
    const w = codec.writer();
    codec.putVarint(w, a.id);
    codec.put(w, body);
    this.#frame(a.once ? FETCH : ASK, w);
  }

  #onAnswer(r: codec.Reader): void {
    const a = this.#asked.get(codec.varint(r));
    if (!a) return;
    const flags = codec.u8(r);
    if (flags & 16) {
      this.#unasked(a);
      return;
    } else if (flags & 14) {
      if (flags & 8) {
        a.status = "indexing";
        a.progress = codec.u8(r) / 100;
      } else {
        a.status = flags & 2 ? "denied" : "faulty";
        this.#show(a, []);
      }
      this.#touchAnswer(a);
      if (a.status !== "indexing") this.#fetched(a);
      return;
    }
    a.status = flags & 1 ? "ready" : "stale";
    a.progress = 1;
    a.total = codec.varint(r);
    a.first = codec.varint(r);
    const ids: string[] = [];
    for (let n = codec.varint(r); n > 0; n--) ids.push(codec.takeBinary(r, 16));
    const again = a.said;
    a.said = undefined;
    this.#show(a, ids);
    for (const id of ids) {
      const row = this.#rows.get(id);
      const said = again?.get(id);
      if (said && said.size > 0 && row) this.#prune(row, said);
    }
    this.#sweep();
    const totals: Record<string, unknown> = {};
    for (let i = 0, m = codec.varint(r); i < m; i++) {
      const some = codec.u8(r) !== 0;
      const number = codec.f64(r);
      const of = a.totalsOf[i];
      const facets: { readonly value: unknown; readonly count: number }[] = [];
      for (let k = codec.varint(r); k > 0; k--) {
        const count = codec.varint(r);
        const raw = codec.bytes(r);
        facets.push(Object.freeze({ value: of ? of.read(raw) : raw.slice(), count }));
      }
      let out: unknown = some ? number : undefined;
      if (of?.facet) out = Object.freeze(facets);
      else if (facets.length > 0) out = facets[0].value; // the least or the most, as it is
      if (of) totals[of.name] = out;
    }
    a.totals = Object.freeze(totals);
    this.#touchAnswer(a);
    this.#fetched(a);
  }

  // What was asked once has been answered, and is of no more concern.
  #fetched(a: Asked): void {
    const once = a.once;
    if (once) {
      a.once = undefined;
      a.stopped = true;
      const answer = this.#answer(a);
      this.#unasked(a);
      once(answer);
    }
  }

  // Holds the rows of an answer, and lets go of those of the last.
  #show(a: Asked, ids: string[]): void {
    const old = a.ids;
    a.ids = ids;
    a.shown = new Set(ids);
    for (const id of ids) this.#row(id).pages++;
    for (const id of old) {
      const row = this.#rows.get(id);
      if (row) this.#release(row);
    }
  }

  // A question is no more, here or at the node.
  #unasked(a: Asked): void {
    this.#asked.delete(a.id);
    this.#show(a, []);
    this.#sweep();
  }

  // Lets go of what was sent for an answer and is not in it.
  #sweep(): void {
    for (const id of this.#loose) {
      const row = this.#rows.get(id);
      if (row && row.pages <= 0 && !row.held && !this.#isPending(id)) this.#rows.delete(id);
    }
    this.#loose.clear();
  }

  #touchAnswer(a: Asked): void {
    a.changed = true;
    a.answer = undefined;
    this.#later();
  }

  #touchAsked(row: Stored): void {
    for (const a of this.#asked.values()) if (!a.changed && a.shown.has(row.id)) this.#touchAnswer(a);
  }

  #answer(a: Asked): Answer<any> {
    if (a.answer) return a.answer;
    const rows: Row<any>[] = [];
    for (const id of a.ids) {
      const row = this.#rows.get(id);
      if (row && !row.dead) {
        // A row's order is that of its first place.
        let key = ZERO40;
        for (let slot = 1; slot <= 15; slot++) {
          const v = slotOf(row, slot);
          const c = typeof v === "string" ? v : v?.values().next().value;
          if (c !== undefined) {
            key = placeKey(c, id);
            break;
          }
        }
        rows.push(this.#view(row, a.schema, key));
      }
    }
    const made: Answer<any> = Object.freeze({
      rows: Object.freeze(rows),
      status: a.status,
      progress: a.progress,
      total: a.total,
      first: a.first,
      totals: a.totals,
    });
    a.answer = made;
    return made;
  }

  // ---------------------------------------------------------------- live text

  #onLive(r: codec.Reader): void {
    const id = codec.takeBinary(r, 16);
    const slot = codec.u8(r);
    const piece = codec.takeBinary(r, 8);
    const offset = codec.varint(r);
    codec.take(r, 16);
    const row = this.#rows.get(id);
    if (!row || row.dead) return;
    const t = this.#text(row, slot);
    if (text.live(t, piece, offset, codec.rest(r).slice()) === "changed") {
      unview(row);
      this.#place(row);
      const lives = (row.lives ??= new Map());
      if (!lives.has(slot)) this.#expire(row, slot);
      lives.set(slot, this.#host.now());
    }
  }

  // Live text whose writer vanished before sealing it is not text.
  #expire(row: Stored, slot: number): void {
    this.#after(LIVE_MS, () => {
      const last = row.lives?.get(slot);
      const t = row.texts?.get(slot);
      if (last === undefined || !t) return;
      if (!text.provisional(t)) {
        row.lives!.delete(slot);
        if (row.lives!.size === 0) row.lives = undefined;
      }
      else if (this.#host.now() - last >= LIVE_MS) {
        this.#rebuild(row, slot);
        this.#place(row);
      } else {
        this.#expire(row, slot);
      }
    });
  }

  #sendLive(row: Stored): void {
    const dirty = row.dirty;
    row.dirty = undefined;
    for (const slot of dirty ?? []) {
      const t = row.texts?.get(slot);
      if (t && t.open !== "") {
        const [piece, offset, bytes] = text.flush(t);
        if (bytes.length > 0 && this.#ready) {
          const w = codec.writer();
          codec.putBinary(w, row.id);
          codec.putU8(w, slot);
          codec.putBinary(w, piece);
          codec.putVarint(w, offset);
          codec.putBinary(w, ZERO16);
          codec.put(w, bytes);
          this.#frame(LIVE, w);
        }
        if (t.size >= PIECE_BYTES) this.#sealShown(row, slot);
      }
    }
  }

  /** This device, and whom this client goes by, once that is known: "self" is told when it changes. */
  me(): Device | undefined {
    return this.#authors.get(0);
  }

  // Whose what is written here is, in a scope that says.
  #mine(scope: number): Device | undefined {
    const s = this.#scopes.get(scope);
    return s && s.rights & 128 ? this.#authors.get(0) : undefined;
  }

  // Seals what is typed, and has it shown: the text is as it was, but whose it is may not be.
  #sealShown(row: Stored, slot: number): void {
    if (this.#seal(row, slot)) this.#place(row);
  }

  #seal(row: Stored, slot: number): boolean {
    const t = row.texts?.get(slot);
    if (!t || t.open === "") return false;
    const stamp = this.#stamp();
    const body = text.close(t, stamp);
    if (body) {
      merge(row, slot, cellOf(PIECE, stamp, body), this.#mine(codec.u32Of(row.id)));
      unview(row);
      this.#sendCells([{ row: row.id, slot, kind: PIECE, stamp, body }]);
      return true;
    }
    return false;
  }

  /** An editor for a text column. Edits show here at once, reach everyone watching as they are made, and become durable a piece at a time. */
  text(id: string, col: Column<string>): Editor {
    if (!col.text) throw new Error("not a text column");
    const slot = col.slot;
    if (!Number.isInteger(slot) || slot < 16 || slot > 255) throw new RangeError("data slots are 16 to 255"); // as a column made by hand may say
    const bin = rowId(id);
    const scope = codec.u32Of(bin);
    // What is done before there is a row to do it to: none is held as the node has it, in a window or an answer, or another
    // editor of it waits for it still. A row held for nothing but what this client wrote to it may have more to it.
    const was = this.#rows.get(bin);
    let early: (() => void)[] | undefined = was === undefined || was.pages === 0 || (was.awaited !== undefined && was.awaited.length > 0) ? [] : undefined;
    const row = this.#row(bin);
    const holding = (row.held ??= new Map());
    holding.set(slot, (holding.get(slot) ?? 0) + 1);
    let closed = false, ended = false;
    let sealed: Promise<void> | undefined; // as it was closed
    // Should what it typed have been sealed where the client may no longer write, that is what any commit and close say.
    const refused = (): Promise<void> | undefined => {
      const e = this.#refusedTexts.get(bin + "/" + slot);
      return e && Promise.reject(e);
    };
    // What is typed before the row is here is typed in it once it is: until then, commit and close wait for it.
    let applied: Promise<void> | undefined, apply = () => {};
    if (early) this.#early.add((applied = new Promise<void>((done) => (apply = done))));
    const fresh = () => codec.binary(this.#host.random(8));
    const edited = () => {
      (row.dirty ??= new Set()).add(slot);
      this.#typing.add(row);
      unview(row);
      this.#place(row);
      this.#later();
    };
    let timer: (() => void) | undefined;
    const schedule = () => {
      if (!timer) {
        timer = this.#after(PIECE_MS, () => {
          timer = undefined;
          this.#sealShown(row, slot);
        });
      }
    };
    const edit = (f: (t: text.Text) => void) => {
      if (closed || row.dead) throw new Error("the text is closed");
      this.#mayWrite(bin, scope);
      if (early) {
        early.push(() => f(this.#text(row, slot)));
        return;
      }
      f(this.#text(row, slot));
      edited();
      schedule();
    };
    const finish = () => {
      if (ended || early) return;
      ended = true;
      timer?.();
      timer = undefined;
      this.#seal(row, slot);
      const holding = row.held!;
      const n = holding.get(slot)! - 1;
      if (n === 0) holding.delete(slot);
      else holding.set(slot, n);
      if (holding.size === 0) row.held = undefined;
      const asking = row.asking;
      if (asking && !row.held) {
        row.asking = undefined;
        asking();
      }
      this.#place(row);
    };
    this.#keep(row, () => {
      const todo = early;
      early = undefined;
      try {
        if (todo && todo.length > 0 && !row.dead) {
          let made = false;
          for (const f of todo) {
            // An edit at a place the text did not have once it came was asked of a text not yet here: it is not made,
            // and those after it are made as if it had not been asked for.
            try {
              f();
              made = true;
            } catch (e) {
              if (!(e instanceof RangeError)) throw e;
            }
          }
          if (made) edited(), schedule();
        }
      } finally {
        if (closed) finish();
        if (applied) this.#early.delete(applied), apply();
      }
    });
    // Where a UTF-16 index of what is shown falls in its bytes, whatever they are.
    const at = (t: text.Text, index: number) => codec.utf8Offset(text.content(t), index);
    // What is no place in any text is refused at once, whether or not the text is here yet.
    const place = (n: number) => {
      if (!Number.isSafeInteger(n) || n < 0) throw new RangeError("no such position");
    };
    // Types bytes in as many pieces as they need, each sealed once full: a live frame says the whole of what an open piece
    // says, and a node passes over one longer than it carries. A piece ends where a character does, and one that has no
    // room for the next is sealed without it: else whoever saw the piece alone would read half a character, and what they
    // typed after it would go between its halves, for good.
    const type = (t: text.Text, from: number, bytes: Uint8Array) => {
      for (let k = 0; k < bytes.length; ) {
        let n = bytes.length - k;
        const room = PIECE_MOST - INSERT_MOST - t.size;
        if (n > room) {
          n = room > 0 ? room : 0;
          for (let back = 0; back < 3 && n > 0 && (bytes[k + n] & 0xc0) === 0x80; back++) n--; // to where it begins
          if (n === 0) {
            this.#seal(row, slot);
            continue;
          }
        }
        text.insert(t, from + k, bytes.subarray(k, k + n), fresh);
        k += n;
      }
    };
    return Object.freeze({
      read: () => text.read(this.#text(row, slot)),
      insert: (index: number, s: string) => {
        place(index);
        edit((t) => type(t, at(t, index), utf8.encode(s)));
      },
      append: (s: string) => edit((t) => type(t, text.len(t), utf8.encode(s))),
      delete: (index: number, count: number) => {
        place(index);
        place(count);
        edit((t) => {
          const from = at(t, index);
          let left = at(t, index + count) - from;
          while ((left = text.erase(t, from, left, fresh, PIECE_MOST)) > 0) this.#seal(row, slot);
        });
      },
      commit: () => {
        if (early) return handled(applied!.then(() => (this.#sealShown(row, slot), refused() ?? this.#barrier())));
        this.#sealShown(row, slot);
        return handled(refused() ?? this.#barrier());
      },
      close: () => {
        if (!closed) {
          closed = true;
          finish();
        }
        // What it typed before its row was here is sealed once the row comes, and waited for from then.
        return (sealed ??= handled(early ? applied!.then(() => refused() ?? this.#barrier()) : (refused() ?? this.#barrier())));
      },
    });
  }

  // ---------------------------------------------------------------- for what is built on the client

  /** Hears of every row that changes, here or anywhere, by its id. Returns a way to stop. */
  follow(f: (id: string) => void): () => void {
    return this.followRows((row) => f(hexOf(row)));
  }

  /** Hears of every row that changes, here or anywhere, as it is held. Returns a way to stop. */
  followRows(f: (row: Stored) => void): () => void {
    const own: Follower = { f, on: true }; // its own, though the same function follow twice
    this.#followers = [...this.#followers, own];
    return () => {
      own.on = false;
      this.#followers = this.#followers.filter((x) => x !== own);
    };
  }

  // Followers hear of a row, those following still, while the client is open: one closed within it tells no more.
  #follow(row: Stored): void {
    for (const x of this.#followers) if (x.on && !this.#closed) this.#hand(x.f, row);
  }

  /** A row as it is held: its cells by slot and stamp, or undefined. Not to be changed. */
  held(id: string): Stored | undefined {
    return this.#rows.get(rowId(id));
  }

  /** The same, by its id as it is held: for what is built on the client. */
  heldRow(id: string): Stored | undefined {
    return this.#rows.get(id);
  }

  /** A text column of a held row, as it is; undefined if the row is not held. */
  heldText(id: string, slot: number): text.Text | undefined {
    const row = this.held(id);
    return row ? this.#text(row, slot) : undefined;
  }

  /** The same, of a row as it is held. */
  textOf(row: Stored, slot: number): text.Text {
    return this.#text(row, slot);
  }

  /** The key of a scope, of which its lists' tags are made, once it is known; undefined until then. Not to be changed. */
  scopeKey(scope: number): Uint8Array | undefined {
    return this.#scopes.get(scope)?.key;
  }

  /** What is held, for tests: rows, questions, windows and pages, by what this client and its node call them. */
  static internals(c: Client): {
    rows: ReadonlyMap<string, Stored>;
    asked: ReadonlyMap<number, unknown>;
    windows: ReadonlyMap<string, unknown>;
    pages: ReadonlyMap<number, unknown>;
    heardBytes: number;
  } {
    return { rows: c.#rows, asked: c.#asked, windows: c.#windows, pages: c.#pages, heardBytes: c.#heardBytes };
  }

  // ---------------------------------------------------------------- writing

  #heard(stamp: string): void {
    const [ms, n] = codec.clock(stamp);
    if (ms > this.#clockMs || (ms === this.#clockMs && n > this.#clockN)) (this.#clockMs = ms), (this.#clockN = n);
  }

  // A stamp, as of now, or of a time read once for many, as a change's are.
  #stamp(now?: number): string {
    const ms = now ?? Math.floor(this.#host.now());
    if (ms > this.#clockMs) (this.#clockMs = ms), (this.#clockN = 0);
    else if (this.#clockN < 65535) this.#clockN++;
    else (this.#clockMs++, (this.#clockN = 0));
    return stampTime(this.#clockMs, this.#clockN) + codec.binary(this.#host.random(8));
  }

  // A row this client may write in now, as far as it knows: what a node refuses, it refuses for good, ending the pipe and
  // this client with it. One made later than a stamp of this client's may be ahead of the clock is never written; one made
  // a little ahead of this client's clock sets it on, as no cell is older than its row.
  #mayWrite(bin: string, scope: number, may = false): void {
    if (codec.u32Of(bin) !== scope) throw new RangeError("that row is of another scope");
    if (!may && this.#ready && !this.may(scope, "write")) throw new Error("this client may not write there");
    const born = codec.u32Of(bin, 4) * 1000;
    if (born > this.#clockMs) {
      if (born > Math.floor(this.#host.now()) + LEAP_MS) throw new RangeError("that row was made later than any clock may yet say");
      (this.#clockMs = born), (this.#clockN = 0);
    }
  }

  #sendCells(cells: Written[], done?: () => void, fail?: (e: Error) => void): void {
    const scope = codec.u32Of(cells[0].row);
    // What this client may no longer write in, since it began, is never said: a node refuses it, and this client with it. It
    // is not delivered, and whoever waits for it is told so, or, should nobody yet, whoever next waits for what was written.
    if (this.#ready && !this.may(scope, "write")) {
      const e = new Error("this client may no longer write there: what it wrote there is not delivered");
      this.#owed ??= e;
      this.#neverDelivered ??= e;
      for (const c of cells) if (c.kind === PIECE) this.#refusedTexts.set(c.row + "/" + c.slot, e);
      fail?.(e);
      return;
    }
    const w = codec.writer();
    let last = "";
    const rows: string[] = [];
    const texts: string[] = [];
    for (const c of cells) {
      if (c.kind === PIECE) texts.push(c.row + "/" + c.slot);
      const again = c.row === last;
      if (!again) {
        rows.push(c.row);
        this.#unacked.set(c.row, (this.#unacked.get(c.row) ?? 0) + 1);
      }
      codec.putU8(w, c.kind + (again ? 128 : 0));
      if (!again) codec.putBinary(w, c.row);
      codec.putU8(w, c.slot);
      codec.putBinary(w, c.stamp);
      codec.putBytes(w, c.body);
      last = c.row;
    }
    const body = codec.written(w).slice();
    const seq = ++this.#seq;
    this.#pending.push({ seq, scope, body, rows, cells: cells.length, texts, done: done ?? (() => {}), fail: fail ?? (() => {}) });
    if (this.#ready) {
      const framed = codec.writer();
      codec.putVarint(framed, seq);
      codec.put(framed, body);
      this.#frame(CELLS, framed);
    }
  }

  #onAck(seq: number): void {
    while (this.#pending.length > 0 && this.#pending[0].seq <= seq) {
      const p = this.#pending.shift()!;
      this.#settle(p);
      p.done();
    }
    if (this.#barriers.length > 0) this.#unbar();
  }

  // What was written is pending no more: its rows are let go of, unless something else holds them.
  #settle(p: Pending): void {
    for (const id of p.rows) {
      const n = this.#unacked.get(id)! - 1;
      if (n > 0) this.#unacked.set(id, n);
      else this.#unacked.delete(id);
      const row = this.#rows.get(id);
      if (n === 0 && row && row.pages === 0 && !row.held) this.#rows.delete(id);
    }
  }

  /**
   * Applies several changes as one: all visible in the same turn, all durable together or not at all. Resolves when they
   * are durable on the node this client speaks to, and all this client wrote before them; a change of nothing is so a
   * barrier, resolving once all written before it is durable. Should they never be, the scope being one it may no longer
   * write in, or the client closed with no node to deliver them to, it does not resolve, as it never did: close() says so.
   * Should `signal` give up on it first, it rejects with Undelivered, saying how much was not yet acknowledged; what it
   * wrote is not given up, but delivered still.
   */
  write(scope: number, f: (change: Change) => void, options: { signal?: AbortSignal } = {}): Promise<void> {
    const s = this.#scopes.get(scope);
    if (!s || !(s.rights & 2)) throw new Error("this client may not write there");
    const cells: Written[] = [];
    const fresh = new Set<string>(); // rows made here
    const rows = new Set<string>();
    // How each row was before this touched it, so that a change that throws leaves nothing behind.
    const before = new Map<
      string,
      { existed: boolean; slots: (number | Cells | undefined)[]; authors: Map<string, Device> | undefined; dead: boolean; texts: Set<number>; sealed: boolean }
    >();
    const mine = this.#mine(scope); // whose what this change writes is, the same throughout,
    const now = Math.floor(this.#host.now()); // and when
    const touch = (id: string, slot: number): Stored => {
      let was = before.get(id);
      // First touched: what is done to a row of another scope is refused, and the whole change with it, by any node.
      if (!was && !fresh.has(id)) this.#mayWrite(id, scope, true); // as was asked of the scope, above
      const existed = this.#rows.get(id);
      const row = existed ?? this.#row(id);
      if (!was) {
        // What editors have open in it goes first, and stands, whatever becomes of this change: so what is put back is
        // as it was with that, and nothing the node has heard is taken back here.
        let sealed = false;
        if (row.texts) for (const [s, t] of row.texts) if (t.open && this.#seal(row, s)) sealed = true;
        const slots = row.slots.map((v) => (v instanceof Map ? new Map(v) : v));
        const authors = row.authors ? new Map(row.authors) : undefined;
        before.set(id, (was = { existed: existed !== undefined, slots, authors, dead: row.dead, texts: new Set(), sealed }));
      }
      was.texts.add(slot);
      return row;
    };
    const undo = () => {
      const back = new Set<Stored>();
      for (const [id, was] of before) {
        const row = this.#rows.get(id);
        if (!row) continue;
        row.slots = was.slots;
        row.authors = was.authors;
        row.dead = was.dead;
        // What was made of the slots' texts is made again from their cells, when wanted: whatever this change typed in
        // them goes with it. (An editor's own typing that was open was sealed before this touched the row, and stands.)
        for (const slot of was.texts) {
          row.texts?.delete(slot);
          row.lives?.delete(slot);
        }
        if (row.texts?.size === 0) row.texts = undefined;
        if (row.lives?.size === 0) row.lives = undefined;
        unview(row);
        if (!was.existed && row.pages === 0 && !row.held && !this.#isPending(id)) this.#rows.delete(id);
        else if (was.sealed) back.add(row);
      }
      // What editors had open in the rows it touched was sealed, and stands: those rows are shown as they now are. The rest
      // are as they were, and were shown so: nothing is told of them.
      this.#placeAll(back);
    };
    const put = (row: string, slot: number, kind: number, body: Uint8Array) => {
      if (body.length > MAX_OPEN) throw new RangeError("a value may be 1 MiB at most, less 192 bytes");
      const stored = touch(row, slot);
      const stamp = this.#stamp(now);
      rows.add(row);
      cells.push({ row, slot, kind, stamp, body });
      this.#accept(stored, slot, cellOf(kind, stamp, body), mine);
    };
    const set = (bin: string, schema: Table, values: Record<string, unknown>) => {
      for (const name in values) {
        const value = values[name];
        const c = schema[name];
        if (!c || c.who) throw new Error(`no column ${name} to write`);
        if (!(Number.isInteger(c.slot) && c.slot >= 16 && c.slot <= 255)) throw new RangeError(`no value goes in slot ${c.slot}`); // as a column made by hand may say
        if (value === undefined) continue;
        // Empty text is what a text is before anything is written: it need only be said to clear one.
        const row = this.#rows.get(bin);
        if (value !== "" || !c.text || (row && slotOf(row, c.slot) !== undefined) || !fresh.has(bin)) put(bin, c.slot, VALUE, c.encode(value));
      }
    };
    const place = (bin: string, list: string, order: number, slot?: number) => {
      if (!Number.isSafeInteger(order) || order < 0) throw new RangeError("an order is a whole number from 0 to 2^53");
      if (slot !== undefined && (!Number.isInteger(slot) || slot < 1 || slot > 15)) throw new RangeError("a row is placed in slots 1 to 15");
      const tag = this.tag(scope, list);
      put(bin, slot ?? 1, PLACE, codec.bytesOf(tag + codec.u64(order)));
    };
    const idOf = rowId;
    // Done here, so that what is refused throws here; and should it throw, as if it had never been.
    let resolve!: () => void, reject!: (e: Error) => void;
    // Rejected only as `signal` gives up on it, which whoever passed it is waiting for.
    const result: Promise<void> = new Promise<void>((done, failed) => ((resolve = done), (reject = (e) => (handled(result), failed(e)))));
    try {
      f({
        insert: (schema, list, order, values) => {
          // As late as anything heard of: later, then, than any right that is known to have ended.
          if (now > this.#clockMs) (this.#clockMs = now), (this.#clockN = 0);
          const bin = codec.u32Binary(scope) + codec.u32Binary(Math.floor(this.#clockMs / 1000)) + codec.binary(this.#host.random(8));
          fresh.add(bin);
          place(bin, list, order);
          set(bin, schema, values as Record<string, unknown>);
          return codec.hex(bin);
        },
        set: (id, schema, values) => set(idOf(id), schema, values as Record<string, unknown>),
        place: (id, list, order, slot) => place(idOf(id), list, order, slot),
        delete: (id) => put(idOf(id), 0, GRAVE, new Uint8Array()),
        edit: (id, slot, f) => {
          if (!Number.isInteger(slot) || slot < 16 || slot > 255) throw new RangeError("data slots are 16 to 255");
          const bin = idOf(id);
          const row = touch(bin, slot); // and what an editor has open in it goes first, and stands
          rows.add(bin); // and it is shown as it is, though nothing be edited, or let go of if there is nothing
          const t = this.#text(row, slot);
          f(t, () => codec.binary(this.#host.random(8)));
          const stamp = this.#stamp(now);
          const body = text.close(t, stamp);
          if (body) {
            if (body.length > MAX_OPEN) throw new RangeError("an edit may be 1 MiB at most, less 192 bytes");
            rows.add(bin);
            cells.push({ row: bin, slot, kind: PIECE, stamp, body });
            merge(row, slot, cellOf(PIECE, stamp, body), mine);
            unview(row);
          }
        },
      });
      // A change is said in one frame, which a node applies whole or not at all: one bigger than a node reads is refused here.
      let size = 1 + 10;
      for (const c of cells) size += 1 + 16 + 1 + 16 + 5 + c.body.length;
      if (size > MAX_FRAME) throw new RangeError("a change may be 4 MiB at most, as it is said");
    } catch (e) {
      undo();
      throw e;
    }
    if (cells.length > 0) this.#sendCells(cells, resolve);
    else this.#barrier().then(resolve, reject); // something written before it never will be
    const signal = options.signal;
    if (signal) {
      const upTo = this.#seq;
      const giveUp = () => reject(this.#undelivered(false, upTo));
      if (signal.aborted) queueMicrotask(giveUp);
      else signal.addEventListener("abort", giveUp, { once: true });
      const forget = () => signal.removeEventListener("abort", giveUp);
      void result.then(forget, forget);
    }
    const placing = new Set<Stored>();
    for (const id of rows) {
      const row = this.#rows.get(id);
      if (row) placing.add(row);
    }
    this.#placeAll(placing);
    return result;
  }

  // ---------------------------------------------------------------- calls

  #flow(id: number, side: number, kind: number, payload?: Uint8Array): void {
    const w = codec.writer();
    codec.putVarint(w, id * 2 + side);
    codec.putU8(w, kind);
    if (payload) codec.put(w, payload);
    this.#frame(FLOW, w);
  }

  #call(id: number, side: number, device: string, method: string, subject?: string): LiveCall {
    const set = side === 0 ? this.#calls : this.#answers;
    const over = () => set.get(id) !== live;
    const call: Call = {
      device,
      method,
      subject,
      get room() {
        return over() ? 0 : Math.max(0, live.credit - live.queued);
      },
      send: (data) => {
        const bytes = toBytes(data);
        if (bytes.length > CALL_WINDOW) throw new RangeError("a message may be 256 KiB at most");
        if (!over() && !live.finishing) {
          live.queue.push(bytes);
          live.queued += bytes.length;
          this.#drain(id, live);
        }
      },
      finish: () => {
        if (!over() && !live.finishing) {
          live.finishing = true;
          this.#drain(id, live);
        }
      },
      cancel: () => {
        if (this.#faults.delete(live)) return; // ended already, and not yet told: it is not told now
        if (!over()) {
          set.delete(id);
          this.#flow(id, side, F_CANCEL);
        }
      },
      consumed: (n) => {
        if (!over()) this.#consumed(id, live, n);
      },
    };
    const live: LiveCall = {
      call,
      side,
      finishing: false,
      mineEnded: false,
      theirsEnded: false,
      credit: CALL_WINDOW,
      queue: [],
      queued: 0,
      window: CALL_WINDOW,
      used: 0,
      since: this.#host.now(),
    };
    set.set(id, live);
    return live;
  }

  // Tells a call of its end, if it is to be told still.
  #fault(live: LiveCall): void {
    const fault = this.#faults.get(live);
    if (fault === undefined) return;
    this.#faults.delete(live);
    if (live.call.onfault) this.#hand(live.call.onfault, fault, live.call);
  }

  // Credits what was taken: the other side may send as much more. A reader that keeps up gets a longer window, as the host
  // gives one (host/calls.odin), so that a long path is kept full; one that does not keep up never gets one.
  #consumed(id: number, live: LiveCall, n: number): void {
    if (n <= 0 || live.theirsEnded) return;
    let credit = n;
    live.used += n;
    if (live.used >= live.window) {
      const now = this.#host.now();
      if (now - live.since < WINDOW_QUICK && live.window < WINDOW_MOST) {
        credit += live.window;
        live.window *= 2;
      }
      live.used = 0;
      live.since = now;
    }
    const w = codec.writer();
    codec.putVarint(w, credit);
    this.#flow(id, live.side, F_CREDIT, codec.written(w));
  }

  // Sends what the other side has room for, and then, if there is no more, says so.
  #drain(id: number, live: LiveCall): void {
    while (live.queue.length > 0 && live.credit >= live.queue[0].length) {
      const data = live.queue.shift()!;
      live.credit -= data.length;
      live.queued -= data.length;
      this.#flow(id, live.side, F_DATA, data);
    }
    if (live.finishing && live.queue.length === 0 && !live.mineEnded) {
      live.mineEnded = true;
      this.#flow(id, live.side, F_END);
      if (live.theirsEnded) (live.side === 0 ? this.#calls : this.#answers).delete(id);
    }
  }

  /** Calls a method on a device, by its id. Set ondata, onend and onfault on the result before the turn is out. */
  call(device: string, scope: number, method: string, data: Uint8Array | string = new Uint8Array(), options: CallOptions = {}): Call {
    if (!DEVICE_ID.test(device)) throw new RangeError("a device's id is 64 hex digits");
    const urgency = options.urgency ?? 3;
    if (!Number.isInteger(urgency) || urgency < 0 || urgency > 7) throw new RangeError("an urgency is a whole number from 0 to 7");
    whole(scope);
    const id = ++this.#nextCall;
    const live = this.#call(id, 0, device, method);
    const first = toBytes(data);
    if (!this.#ready || first.length > CALL_WINDOW) {
      this.#calls.delete(id);
      // Told on a turn of its own, once it can have been given its callbacks: unless it is cancelled first, or the client
      // is closed, which tells it at once.
      this.#faults.set(live, this.#ready ? "overrun" : "unreachable");
      this.#host.defer(() => this.#fault(live));
      return live.call;
    }
    live.credit -= first.length;
    const w = codec.writer();
    codec.putVarint(w, id);
    codec.put(w, codec.unhex(device));
    codec.putVarint(w, scope);
    codec.putBytes(w, utf8.encode(method));
    codec.putBytes(w, new Uint8Array()); // for whom is for the node to say
    codec.putU8(w, urgency);
    codec.put(w, first);
    this.#frame(CALL, w);
    return live.call;
  }

  /** One question, one answer. Rejects with the fault, as a CallFault, if there is one. */
  request(device: string, scope: number, method: string, data: Uint8Array | string = new Uint8Array(), options: CallOptions = {}): Promise<Uint8Array> {
    return new Promise((resolve, reject) => {
      const parts: Uint8Array[] = [];
      const call = this.call(device, scope, method, data, options);
      call.ondata = (d) => void parts.push(d);
      call.onend = () => resolve(concat(parts));
      call.onfault = (f) => reject(new CallFault(f));
      call.finish();
    });
  }

  /** Answers a method within a scope. The handler gets the call and its first message. Returns a way to stop. */
  serve(scope: number, method: string, handler: (call: Call, data: Uint8Array) => void): () => void {
    whole(scope);
    // A node refuses a method of no name, or of a longer one, for good: so here, at once.
    const n = codec.utf8Length(method);
    if (n === 0 || n > 255) throw new RangeError("a method's name is 1 to 255 bytes");
    const key = `${scope}/${method}`;
    this.#handlers.set(key, handler);
    if (this.#ready) this.#serve(key, true);
    return () => {
      if (this.#handlers.get(key) === handler) {
        this.#handlers.delete(key);
        if (this.#ready) this.#serve(key, false);
      }
    };
  }

  #serve(key: string, on: boolean): void {
    const slash = key.indexOf("/");
    const w = codec.writer();
    codec.putVarint(w, Number(key.slice(0, slash)));
    codec.putU8(w, on ? 1 : 0);
    codec.putBytes(w, utf8.encode(key.slice(slash + 1)));
    this.#frame(SERVE, w);
  }

  #onCall(r: codec.Reader): void {
    const id = codec.varint(r);
    const device = codec.hex(codec.take(r, 32));
    const scope = codec.varint(r);
    const method = fromUtf8.decode(codec.bytes(r));
    const subject = fromUtf8.decode(codec.bytes(r));
    const handler = this.#handlers.get(`${scope}/${method}`);
    if (!handler) {
      this.#flow(id, 1, F_FAULT, Uint8Array.of(3));
      return;
    }
    const data = codec.rest(r).slice();
    const live = this.#call(id, 1, device, method, subject);
    this.#consumed(id, live, data.length); // the first message is always taken
    this.#hand((d: Uint8Array) => handler(live.call, d), data);
  }

  #onFlow(r: codec.Reader): void {
    const tag = codec.varint(r);
    const kind = codec.u8(r);
    const id = Math.floor(tag / 2);
    const speaker = tag % 2;
    const set = speaker === 1 ? this.#calls : this.#answers;
    const live = set.get(id);
    if (!live) return;
    const call = live.call;
    if (kind === F_DATA) {
      const data = codec.rest(r).slice();
      // Kept only if the reader says so, and one that threw kept nothing: else what it was sent would never be credited
      // back, and the call would wait for good.
      if ((!call.ondata || this.#hand(call.ondata, data, call) !== false) && set.get(id) === live) this.#consumed(id, live, data.length);
    } else if (kind === F_CREDIT) {
      live.credit += codec.varint(r);
      this.#drain(id, live);
      if (live.queue.length === 0 && set.get(id) === live && call.onroom) this.#hand(call.onroom, undefined, call);
    } else if (kind === F_END) {
      live.theirsEnded = true;
      if (live.mineEnded) set.delete(id);
      if (call.onend) this.#hand(call.onend, undefined, call);
    } else {
      set.delete(id);
      const code = kind === F_FAULT && r.pos < r.len ? codec.u8(r) : 0;
      if (call.onfault) this.#hand(call.onfault, FAULTS[code] ?? "cancelled", call);
    }
  }
}

/** Why a call did not end as it should have. */
export class CallFault extends Error {
  readonly fault: Fault;

  constructor(fault: Fault) {
    super(`the call ended: ${fault}`);
    this.fault = fault;
  }
}
