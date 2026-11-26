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
const F_DATA = 0, F_END = 1, F_FAULT = 2, F_CANCEL = 3, F_CREDIT = 4;
const CALL_WINDOW = 262144;
const MAX_OPEN = 1048576 - 192;
const ZERO16 = "\0".repeat(16);
const ZERO24 = "\0".repeat(24);
const ZERO40 = "\0".repeat(40);

const PIECE_BYTES = 4096; // a piece is sealed at this size,
const PIECE_MS = 1000; // or this long after it began,
const LIVE_MS = 10000; // and live text unconfirmed for this long is dropped

const utf8 = new TextEncoder();
const fromUtf8 = new TextDecoder();
const toBytes = (data: Uint8Array | string): Uint8Array => (typeof data === "string" ? utf8.encode(data) : data);

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
export type Is = "string" | "number" | "boolean" | "id" | "text" | "author";

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

export const columns = Object.freeze({
  /** Text, as UTF-8. */
  string: (slot: number): Column<string> => column(slot, "string", (v: string) => utf8.encode(v), (b) => fromUtf8.decode(b)),
  /** Bytes as they are. */
  bytes: (slot: number): Column<Uint8Array> => column<Uint8Array>(slot, "string", (v) => v, (b) => b.slice()),
  number: (slot: number): Column<number> =>
    column(
      slot,
      "number",
      (v: number) => {
        const b = new Uint8Array(8);
        new DataView(b.buffer).setFloat64(0, v);
        return b;
      },
      (b) => (b.length === 8 ? new DataView(b.buffer, b.byteOffset, 8).getFloat64(0) : NaN),
    ),
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
  send(data: Uint8Array | string): void;
  /** No more will be sent. */
  finish(): void;
  cancel(): void;
  ondata?: (data: Uint8Array) => void;
  onend?: () => void;
  onfault?: (fault: Fault) => void;
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
  /** Makes what has been written durable now rather than shortly. */
  commit(): void;
  close(): void;
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

export interface Cell {
  kind: number;
  stamp: string;
  body: Uint8Array;
  author?: Device;
}

/** A row as it is held: its cells by slot and stamp. Not to be changed. */
export interface Stored {
  readonly id: string;
  readonly hex: string;
  slots: Map<number, Map<string, Cell>>;
  dead: boolean;
  pages: number; // that hold it
  texts: Map<number, text.Text>;
  held: Map<number, number>; // open editors, by slot
  asking?: () => void; // for the sake of those, while nothing else shows it: ends that
  awaited: (() => void)[]; // by those, until it is here
  lives: Map<number, number>; // when live text was last heard, by slot
  views: Map<Table, Row<any>>; // by table, until the row changes
  dirty: Set<number>; // slots with live text to send
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
  stale?: Said; // while being sent afresh: rows, and which cells of each are there still
}

interface Win {
  key: string;
  scope: number;
  list: string;
  schema: Table;
  size: number;
  pages: Page[];
  entries: Entry[]; // in order
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

interface LiveCall {
  call: Call;
  side: number;
  finishing: boolean; // no more will be sent,
  mineEnded: boolean; // and the other side has been told so
  theirsEnded: boolean;
  credit: number;
  queue: Uint8Array[]; // awaiting credit
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
  body: Uint8Array;
  rows: string[];
  done: () => void;
}

// ---------------------------------------------------------------- merging

function bundleHas(body: Uint8Array, stamp: string): boolean {
  const n = ((body[0] << 24) | (body[1] << 16) | (body[2] << 8) | body[3]) >>> 0;
  let lo = 0, hi = n;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    const s = codec.binary(body, 4 + mid * 16, 20 + mid * 16);
    if (s === stamp) return true;
    if (s < stamp) lo = mid + 1;
    else hi = mid;
  }
  return false;
}

// The merge rule. Returns whether the cell was news.
function merge(row: Stored, slot: number, kind: number, stamp: string, body: Uint8Array, author?: Device): boolean {
  if (row.dead) return false;
  if (kind === GRAVE) {
    row.dead = true;
    row.slots = new Map();
    return true;
  }
  let cells = row.slots.get(slot);
  if (!cells) row.slots.set(slot, (cells = new Map()));
  if (cells.has(stamp)) return false;
  for (const [s, c] of cells) {
    if ((c.kind === PLACE || c.kind === VALUE) && stamp <= s) return false;
    if (c.kind === BUNDLE && (kind === PIECE || kind === BUNDLE) && bundleHas(c.body, stamp)) return false;
  }
  if (kind === PLACE || kind === VALUE) {
    for (const s of [...cells.keys()]) if (s < stamp) cells.delete(s);
  } else if (kind === BUNDLE) {
    for (const [s, c] of [...cells]) if ((c.kind === PIECE || c.kind === BUNDLE) && bundleHas(body, s)) cells.delete(s);
  }
  cells.set(stamp, { kind, stamp, body, author });
  return true;
}

function equalBytes(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
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

function placeKey(c: Cell, id: string): string {
  return codec.binary(c.body, 0, 24) + id;
}

// The offset in bytes of UTF-16 index `index` of a string.
function byteIndex(s: string, index: number): number {
  if (index < 0 || index > s.length) throw new RangeError("no such position");
  const c = s.charCodeAt(index - 1);
  if (index > 0 && index < s.length && c >= 0xd800 && c < 0xdc00) throw new RangeError("that is inside a character");
  return codec.utf8Length(index === s.length ? s : s.slice(0, index));
}

// ---------------------------------------------------------------- the client

export class Client {
  #host: Lent;
  #wire?: Wire;
  #ready = false;
  #closed = false;
  #failures = 0;
  #input = new Uint8Array(0);
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
  #unacked = new Map<string, number>(); // rows in pending, and how often
  #out = codec.writer();
  #flushing = false;
  #calls = new Map<number, LiveCall>(); // ours
  #answers = new Map<number, LiveCall>(); // of others
  #nextCall = 0;
  #handlers = new Map<string, (call: Call, data: Uint8Array) => void>();
  #followers = new Set<(id: string) => void>();
  #typing = new Set<Stored>(); // rows with live text to send
  #tags = new Map<string, string>(); // of lists, by their scope, its key and their name
  #bulk?: Map<Win, Entry[]>; // rows to add to windows, all at once

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
    this.#dial();
  }

  // ---------------------------------------------------------------- the pipe

  #dial(): void {
    if (this.#closed || this.#wire) return;
    let over = false;
    const closed = () => {
      if (over) return;
      over = true;
      this.#lost();
    };
    this.#input = new Uint8Array(0);
    this.#out = codec.writer();
    const wire = this.#host.connect((data) => {
      if (!over) this.#receive(data);
    }, closed);
    if (!wire) {
      closed();
      return;
    }
    this.#wire = wire;
    const w = codec.writer();
    codec.putU8(w, 1);
    codec.putU8(w, 4); // telling who wrote what
    codec.putBinary(w, ZERO16 + ZERO16);
    codec.putVarint(w, 0);
    codec.putBytes(w, this.#host.credential);
    this.#frame(HELLO, w);
  }

  #lost(): void {
    this.#wire = undefined;
    this.#ready = false;
    this.#authors.clear();
    for (const set of [this.#calls, this.#answers]) {
      for (const [id, c] of [...set]) {
        set.delete(id);
        c.call.onfault?.("lost");
      }
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
    this.#tell("status", false);
    if (!this.#closed) {
      const wait = Math.min(100 * 2 ** this.#failures, 10000);
      this.#failures++;
      this.#host.after(wait, () => this.#dial());
    }
  }

  /** Lets go of the pipe, saying first whatever is still to be said. Questions asked once are answered as far as they got. */
  close(): void {
    this.#closed = true;
    this.#flush();
    this.#wire?.close();
    for (const a of [...this.#asked.values()]) this.#fetched(a);
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
    for (const row of typing) if (row.dirty.size > 0) this.#sendLive(row);
    const out = this.#out;
    if (out.pos > 0 && this.#wire) {
      const sized = codec.written(out).slice();
      out.pos = 0;
      this.#wire.send(sized);
    }
    for (const window of this.#windows.values()) if (window.changed) this.#publish(window);
    for (const a of [...this.#asked.values()]) {
      if (a.changed && !a.stopped) {
        a.changed = false;
        a.observer(this.#answer(a));
      }
    }
  }

  #receive(data: Uint8Array): void {
    let s = data;
    if (this.#input.length > 0) {
      s = new Uint8Array(this.#input.length + data.length);
      s.set(this.#input);
      s.set(data, this.#input.length);
    }
    let at = 0;
    while (at < s.length) {
      // A frame's length, if it is all there.
      let n = 0, scale = 1, p = at;
      for (;;) {
        if (p >= s.length) {
          this.#input = s.slice(at);
          return;
        }
        const b = s[p++];
        if (p - at > 5) {
          // no frame is so long
          this.#input = new Uint8Array(0);
          this.#wire?.close();
          return;
        }
        n += (b & 127) * scale;
        if (b < 128) break;
        scale *= 128;
      }
      if (p + n > s.length) {
        this.#input = s.slice(at);
        return;
      }
      const r = codec.reader(s.subarray(p, p + n));
      at = p + n;
      try {
        this.#handle(codec.u8(r), r);
      } catch (e) {
        if (!(e instanceof codec.Malformed)) throw e;
        // Nonsense from the pipe ends the pipe and nothing else.
        this.#input = new Uint8Array(0);
        this.#wire?.close();
        return;
      }
    }
    this.#input = new Uint8Array(0);
    this.#later();
  }

  #handle(kind: number, r: codec.Reader): void {
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
        this.#closed = code === 2 || code === 3; // refused, or speaking another language: trying again is no use
        this.#tell("error", code);
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
      // Rights have changed: windows waiting for this one open.
      for (const window of this.#windows.values()) {
        if (window.denied && this.#scopes.has(window.scope)) {
          for (const page of window.pages) this.#watch(page);
          if (window.pages.length === 0) this.#open(window);
          window.denied = false;
          this.#touch(window);
        }
      }
      for (const a of this.#asked.values()) if (a.status === "denied" && !a.stopped) this.#ask(a);
      this.#tell("status", true);
      return;
    }
    this.#ready = true;
    this.#failures = 0;
    // Say again whatever the last pipe was told: what is served, unacknowledged and watched.
    for (const key of this.#handlers.keys()) this.#serve(key, true);
    for (const p of this.#pending) {
      const w = codec.writer();
      codec.putVarint(w, p.seq);
      codec.put(w, p.body);
      this.#frame(CELLS, w);
    }
    for (const window of this.#windows.values()) {
      if (window.pages.length === 0) this.#open(window);
      else for (const page of window.pages) this.#watch(page);
    }
    for (const a of this.#asked.values()) this.#ask(a);
    this.#tell("status", true);
  }

  // ---------------------------------------------------------------- observing things that are not windows

  #tell<E extends Event>(what: E, value: Told[E]): void {
    const set = this.#watchers.get(what);
    if (set) for (const f of [...set]) f(value);
  }

  /**
   * Hears of "status" (connected or not), "devices" (those reachable, this one first), "self" (this device, and whom this
   * client goes by) or "error" (a code from the node). Told at once of what is known. Returns a way to stop.
   */
  on<E extends Event>(what: E, f: (value: Told[E]) => void): () => void {
    let set = this.#watchers.get(what);
    if (!set) this.#watchers.set(what, (set = new Set()));
    set.add(f);
    if (what === "status") (f as (v: boolean) => void)(this.#ready);
    else if (what === "devices") (f as (v: readonly Device[]) => void)(this.#devices);
    else if (what === "self" && this.#authors.has(0)) (f as (v: Device) => void)(this.#authors.get(0)!);
    return () => void set.delete(f);
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
    const key = `${query.scope}/${from}/${size}/${shape}/${query.bare === true}/${query.list}`;
    let window = this.#windows.get(key);
    if (!window) {
      window = {
        key,
        scope: query.scope,
        list: query.list,
        schema: query.table,
        size,
        pages: [],
        entries: [],
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
    own(win.bare ? (undefined as unknown as State<T>) : this.#state(win));
    let stopped = false;
    return Object.freeze({
      visible: (first: number, last: number) => this.#visible(win, first, last),
      loadBefore: () => this.#loadBefore(win),
      loadAfter: () => this.#loadAfter(win),
      entries: () => win.entries,
      stop: () => {
        if (stopped) return;
        stopped = true;
        win.observers.delete(own);
        win.watching--;
        if (win.watching === 0) {
          // Whoever comes back soon finds it still warm.
          win.linger = this.#host.after(this.#host.linger, () => this.#forget(win));
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
    this.#watch(page, window.size, !window.key.includes("/start/"));
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
    for (const e of page.window.entries) if (e.key >= page.lo && e.key < page.hi) stale.set(e.row.id, new Set());
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
    // Where a full replica says the page ends, what lay past it was never known to be whole.
    this.#trim(window);
  }

  // A range was said over again and this row was not in it: it was moved away, or deleted, while this client was not
  // listening. Only its place there is known to be wrong. Where else it is, and what is being typed in it, stand.
  #unplace(row: Stored, lo: string, hi: string): void {
    for (let slot = 1; slot <= 15; slot++) {
      const cells = row.slots.get(slot);
      if (!cells) continue;
      for (const [stamp, c] of [...cells]) {
        const key = placeKey(c, row.id);
        if (key >= lo && key < hi) cells.delete(stamp);
      }
    }
    this.#place(row);
  }

  // A row was said over again, whole: what was not said is there no longer, and nothing has said that it went. What is
  // yet to be acknowledged may not have been there to say.
  #prune(row: Stored, said: Set<string>): void {
    if (this.#isPending(row.id)) return;
    let some = false;
    for (const [slot, cells] of row.slots) {
      let gone = false;
      for (const stamp of [...cells.keys()]) {
        if (!said.has(stamp)) {
          cells.delete(stamp);
          gone = true;
        }
      }
      if (gone) {
        some = true;
        this.#rebuild(row, slot);
      }
    }
    if (some) {
      row.views.clear();
      this.#place(row);
    }
  }

  #isPending(id: string): boolean {
    return this.#unacked.has(id);
  }

  #loadBefore(window: Win): void {
    const first = window.pages[0];
    if (!first || first.open || !first.settled || first.before === 0 || !this.#ready) return;
    const tag = first.lo.slice(0, 16);
    const page = this.#page(window, tag + ZERO24, first.lo);
    window.pages.unshift(page);
    this.#watch(page, window.size, true);
    this.#touch(window);
  }

  #loadAfter(window: Win): void {
    const last = window.pages[window.pages.length - 1];
    if (!last || last.open || !last.settled || last.after === 0 || !this.#ready) return;
    const page = this.#page(window, last.hi, codec.after(last.lo.slice(0, 16)));
    window.pages.push(page);
    this.#watch(page, window.size, false);
    this.#touch(window);
  }

  #visible(window: Win, first: number, last: number): void {
    if (window.pages.length === 0 || !this.#ready) return;
    const near = Math.floor(window.size / 2);
    if (first <= near) this.#loadBefore(window);
    if (last > window.entries.length - near) this.#loadAfter(window);
    // A page that has grown far past its size is two pages.
    for (let i = 0; i < window.pages.length; i++) {
      const page = window.pages[i];
      const [lo, hi] = this.#span(window, page);
      if (!page.open && hi - lo > window.size * 2) {
        const middle = window.entries[Math.floor((lo + hi) / 2) - 1].key;
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
      const count = window.entries.length - lo + 1;
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
    const entries = window.entries;
    let lo = 0, hi = entries.length;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (entries[mid].key < key) lo = mid + 1;
      else hi = mid;
    }
    return lo + 1;
  }

  #trim(window: Win): void {
    const lo = window.pages[0].lo, hi = window.pages[window.pages.length - 1].hi;
    const kept: Entry[] = [];
    window.at.clear();
    for (const e of window.entries) {
      if (e.key >= lo && e.key < hi) {
        kept.push(e);
        window.at.set(e.row, e.key);
      } else {
        this.#release(e.row);
      }
    }
    window.entries = kept;
    this.#touch(window);
  }

  #forget(window: Win): void {
    this.#windows.delete(window.key);
    for (const page of window.pages) this.#dropPage(page);
    for (const e of window.entries) this.#release(e.row);
  }

  #release(row: Stored): void {
    row.pages--;
    if (row.pages === 0 && !row.asking && !row.dead) this.#keep(row);
    if (row.pages === 0 && row.held.size === 0 && !this.#isPending(row.id)) this.#rows.delete(row.id);
  }

  // Has a row that is being edited shown, if nothing else shows it, so that what others write in it is heard of too. Calls
  // back once it is here, or known not to be anywhere.
  #keep(row: Stored, here?: () => void): void {
    if (row.pages > 0 || row.held.size === 0) {
      here?.();
      return;
    }
    if (here) row.awaited.push(here);
    if (row.asking) return;
    const hear = (answer: Answer<any>) => {
      if (answer.rows.length > 0 || answer.status === "ready" || answer.status === "denied") {
        const awaited = row.awaited;
        row.awaited = [];
        for (const f of awaited) f();
      }
    };
    const asked = this.ask({ scope: codec.u32Of(row.id), table: {}, where: ask.where.ids([row.hex]), limit: 1 }, hear);
    if (row.held.size > 0) row.asking = asked.stop;
    else asked.stop();
  }

  #touch(window: Win): void {
    window.changed = true;
    window.state = undefined;
    this.#later();
  }

  #state(window: Win): State<any> {
    if (window.state) return window.state;
    const rows = window.entries.map((e) => this.#view(e.row, window.schema, e.key));
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
    for (const f of [...window.observers]) f(state);
  }

  // A row as the application sees it: one frozen object, the same one until something in it changes.
  #view(row: Stored, schema: Table, key: string): Row<any> {
    const view = row.views.get(schema);
    const order = codec.fromU64(key, 16);
    if (view && view.order === order) return view;
    const made: Record<string, unknown> = { id: row.hex, order };
    for (const name in schema) {
      const c = schema[name];
      if (c.who) {
        let latest: Cell | undefined;
        const names = new Set<string>();
        for (const cell of row.slots.get(c.slot)?.values() ?? []) {
          if (!latest || cell.stamp > latest.stamp) latest = cell;
          if (cell.author && cell.author.subject !== "") names.add(cell.author.subject);
        }
        if (c.who === "all") made[name] = Object.freeze([...names].sort());
        else if (latest?.author && latest.author.subject !== "") made[name] = latest.author.subject;
      } else if (c.text) {
        made[name] = text.read(this.#text(row, c.slot));
      } else {
        const slot = row.slots.get(c.slot);
        if (slot) for (const cell of slot.values()) if (cell.kind === VALUE) made[name] = c.decode(cell.body);
      }
    }
    Object.freeze(made);
    row.views.set(schema, made as Row<any>);
    return made as Row<any>;
  }

  // ---------------------------------------------------------------- rows

  #row(id: string): Stored {
    let row = this.#rows.get(id);
    if (!row) {
      row = {
        id,
        hex: codec.hex(id),
        slots: new Map(),
        dead: false,
        pages: 0,
        texts: new Map(),
        held: new Map(),
        awaited: [],
        lives: new Map(),
        views: new Map(),
        dirty: new Set(),
      };
      this.#rows.set(id, row);
    }
    return row;
  }

  #onCells(r: codec.Reader): void {
    codec.varint(r);
    let id = "";
    const touched = new Set<Stored>();
    while (r.pos < r.len) {
      const tag = codec.u8(r);
      if (tag < 128) id = codec.takeBinary(r, 16);
      if (id === "") throw new codec.Malformed();
      const slot = codec.u8(r);
      const stamp = codec.takeBinary(r, 16);
      const body = codec.bytes(r).slice();
      this.#heard(stamp);
      const row = this.#row(id);
      touched.add(row);
      for (const page of this.#pages.values()) page.stale?.get(id)?.add(stamp);
      for (const a of this.#asked.values()) a.said?.get(id)?.add(stamp);
      const author = tag & 64 ? this.#authors.get(codec.varint(r)) : undefined;
      this.#accept(row, slot, tag % 64, stamp, body, author);
    }
    this.#placeAll(touched);
  }

  #accept(row: Stored, slot: number, kind: number, stamp: string, body: Uint8Array, author?: Device): boolean {
    if (!merge(row, slot, kind, stamp, body, author)) {
      // Known already; but perhaps not whose it is, or by what name they go now.
      const cell = row.slots.get(slot)?.get(stamp);
      if (cell && author) {
        if (!cell.author || cell.author.subject !== author.subject) row.views.clear();
        cell.author = author;
      }
      if (cell && !equalBytes(cell.body, body)) {
        cell.body = body; // less of it, since its author may no longer have written the rest
        this.#rebuild(row, slot);
      }
      return false;
    }
    const t = row.texts.get(slot);
    if (t && kind >= VALUE) {
      if (text.apply(t, kind, stamp, body) === "rebuild") this.#rebuild(row, slot);
    }
    row.views.clear();
    return true;
  }

  // The text in a slot, made from its cells when first wanted.
  #text(row: Stored, slot: number): text.Text {
    let t = row.texts.get(slot);
    if (!t) {
      t = text.create();
      row.texts.set(slot, t);
      const cells = row.slots.get(slot);
      if (cells) {
        const sorted = [...cells.values()].sort((a, b) => (a.stamp < b.stamp ? -1 : a.stamp > b.stamp ? 1 : 0));
        for (const c of sorted) text.apply(t, c.kind, c.stamp, c.body);
      }
    }
    return t;
  }

  #rebuild(row: Stored, slot: number): void {
    const old = row.texts.get(slot);
    if (old && old.open !== "") this.#seal(row, slot); // nothing typed here may be lost with it
    row.texts.delete(slot);
    row.lives.delete(slot);
    row.views.clear();
  }

  // Puts a row where its placements say, in every window, and takes it from where they do not.
  #place(row: Stored): void {
    for (const f of this.#followers) f(row.hex);
    const keys: string[] = [];
    if (!row.dead) {
      for (let slot = 1; slot <= 15; slot++) {
        const cells = row.slots.get(slot);
        if (cells) for (const c of cells.values()) keys.push(placeKey(c, row.id));
      }
    }
    for (const window of this.#windows.values()) {
      if (window.pages.length === 0) continue;
      const lo = window.pages[0].lo, hi = window.pages[window.pages.length - 1].hi;
      let want: string | undefined;
      for (const key of keys) if (key >= lo && key < hi && (want === undefined || key < want)) want = key;
      const entries = window.entries;
      // Where it is now, found by where it was: keys are in order, and each is a row's own.
      const was = window.at.get(row);
      let have: number | undefined = was !== undefined ? this.#find(window, was) - 1 : undefined;
      if (have !== undefined && (want === undefined || entries[have].key !== want)) {
        entries.splice(have, 1);
        window.at.delete(row);
        row.pages--;
        if (row.pages === 0 && !row.asking && !row.dead) this.#keep(row);
        this.#touch(window);
        have = undefined;
      }
      if (want !== undefined && have === undefined) {
        const e: Entry = { key: want, row };
        const bulk = this.#bulk;
        if (bulk) {
          let add = bulk.get(window);
          if (!add) bulk.set(window, (add = []));
          add.push(e);
        } else {
          entries.splice(this.#find(window, want) - 1, 0, e);
        }
        window.at.set(row, want);
        row.pages++;
        this.#touch(window);
      } else if (want !== undefined) {
        this.#touch(window);
      }
    }
    this.#touchAsked(row);
    if (row.pages <= 0 && row.held.size === 0 && (row.dead || !this.#isPending(row.id))) {
      if (this.#asked.size > 0 && !row.dead) this.#loose.add(row.id);
      else this.#rows.delete(row.id);
    }
  }

  // Places rows, each once. Many at once go into windows at once: sorted together, rather than each moving all after it.
  #placeAll(rows: Set<Stored>): void {
    if (rows.size > 64) this.#bulk = new Map();
    for (const row of rows) this.#place(row);
    const bulk = this.#bulk;
    this.#bulk = undefined;
    if (bulk) {
      for (const [window, add] of bulk) {
        window.entries.push(...add);
        window.entries.sort((x, y) => (x.key < y.key ? -1 : x.key > y.key ? 1 : 0));
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
    observer(this.#answer(a) as Answer<T>);
    return Object.freeze({
      move: (offset: number, limit?: number) => {
        a.question = { ...a.question, offset, limit: limit ?? a.question.limit };
        if (this.#ready && !a.stopped) this.#ask(a);
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

  #ask(a: Asked): void {
    let may = this.#scopes.has(a.question.scope);
    const [body, totals] = ask.write(a.question, (scope, name) => {
      if (this.#scopes.has(scope)) return this.tag(scope, name);
      may = false;
      return ZERO16;
    });
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
      if (row && row.pages <= 0 && row.held.size === 0 && !this.#isPending(id)) this.#rows.delete(id);
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
          const c = row.slots.get(slot)?.values().next().value;
          if (c) {
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
      row.views.clear();
      this.#place(row);
      if (!row.lives.has(slot)) this.#expire(row, slot);
      row.lives.set(slot, this.#host.now());
    }
  }

  // Live text whose writer vanished before sealing it is not text.
  #expire(row: Stored, slot: number): void {
    this.#host.after(LIVE_MS, () => {
      const last = row.lives.get(slot);
      const t = row.texts.get(slot);
      if (last === undefined || !t) return;
      if (!text.provisional(t)) row.lives.delete(slot);
      else if (this.#host.now() - last >= LIVE_MS) {
        this.#rebuild(row, slot);
        this.#place(row);
      } else {
        this.#expire(row, slot);
      }
    });
  }

  #sendLive(row: Stored): void {
    for (const slot of [...row.dirty]) {
      row.dirty.delete(slot);
      const t = row.texts.get(slot);
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
        if (t.size >= PIECE_BYTES) this.#seal(row, slot);
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

  #seal(row: Stored, slot: number): void {
    const t = row.texts.get(slot);
    if (!t || t.open === "") return;
    const stamp = this.#stamp();
    const body = text.close(t, stamp);
    if (body) {
      merge(row, slot, PIECE, stamp, body, this.#mine(codec.u32Of(row.id)));
      row.views.clear();
      this.#sendCells([{ row: row.id, slot, kind: PIECE, stamp, body }]);
    }
  }

  /** An editor for a text column. Edits show here at once, reach everyone watching as they are made, and become durable a piece at a time. */
  text(id: string, col: Column<string>): Editor {
    if (!col.text) throw new Error("not a text column");
    const slot = col.slot;
    const bin = codec.binary(codec.unhex(id));
    let early: (() => void)[] | undefined = this.#rows.has(bin) ? undefined : []; // what is done before there is a row to do it to
    const row = this.#row(bin);
    row.held.set(slot, (row.held.get(slot) ?? 0) + 1);
    let closed = false, ended = false;
    const fresh = () => codec.binary(this.#host.random(8));
    const edited = () => {
      row.dirty.add(slot);
      this.#typing.add(row);
      row.views.clear();
      this.#place(row);
      this.#later();
    };
    let timer: (() => void) | undefined;
    const schedule = () => {
      if (!timer) {
        timer = this.#host.after(PIECE_MS, () => {
          timer = undefined;
          this.#seal(row, slot);
        });
      }
    };
    const edit = (f: (t: text.Text) => void) => {
      if (closed || row.dead) throw new Error("the text is closed");
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
      const n = row.held.get(slot)! - 1;
      if (n === 0) row.held.delete(slot);
      else row.held.set(slot, n);
      const asking = row.asking;
      if (asking && row.held.size === 0) {
        row.asking = undefined;
        asking();
      }
      this.#place(row);
    };
    this.#keep(row, () => {
      const todo = early;
      early = undefined;
      if (todo && todo.length > 0 && !row.dead) {
        for (const f of todo) f();
        edited();
        schedule();
      }
      if (closed) finish();
    });
    // Where a UTF-16 index of what is shown falls in its bytes.
    const at = (t: text.Text, index: number) => byteIndex(text.read(t), index);
    return Object.freeze({
      read: () => text.read(this.#text(row, slot)),
      insert: (index: number, s: string) =>
        edit((t) => {
          text.insert(t, at(t, index), utf8.encode(s), fresh);
        }),
      append: (s: string) =>
        edit((t) => {
          text.insert(t, text.len(t), utf8.encode(s), fresh);
        }),
      delete: (index: number, count: number) =>
        edit((t) => {
          const shown = text.read(t);
          const from = byteIndex(shown, index);
          text.erase(t, from, byteIndex(shown, index + count) - from, fresh);
        }),
      commit: () => this.#seal(row, slot),
      close: () => {
        if (closed) return;
        closed = true;
        finish();
      },
    });
  }

  // ---------------------------------------------------------------- for what is built on the client

  /** Hears of every row that changes, here or anywhere, by its id. Returns a way to stop. */
  follow(f: (id: string) => void): () => void {
    this.#followers.add(f);
    return () => void this.#followers.delete(f);
  }

  /** A row as it is held: its cells by slot and stamp, or undefined. Not to be changed. */
  held(id: string): Stored | undefined {
    return this.#rows.get(codec.binary(codec.unhex(id)));
  }

  /** A text column of a held row, as it is; undefined if the row is not held. */
  heldText(id: string, slot: number): text.Text | undefined {
    const row = this.held(id);
    return row ? this.#text(row, slot) : undefined;
  }

  /** The key of a scope, of which its lists' tags are made, once it is known; undefined until then. Not to be changed. */
  scopeKey(scope: number): Uint8Array | undefined {
    return this.#scopes.get(scope)?.key;
  }

  /** What is held, for tests: rows, questions, windows and pages, by what this client and its node call them. */
  static internals(c: Client): { rows: ReadonlyMap<string, Stored>; asked: ReadonlyMap<number, unknown>; windows: ReadonlyMap<string, unknown>; pages: ReadonlyMap<number, unknown> } {
    return { rows: c.#rows, asked: c.#asked, windows: c.#windows, pages: c.#pages };
  }

  // ---------------------------------------------------------------- writing

  #heard(stamp: string): void {
    const [ms, n] = codec.clock(stamp);
    if (ms > this.#clockMs || (ms === this.#clockMs && n > this.#clockN)) (this.#clockMs = ms), (this.#clockN = n);
  }

  #stamp(): string {
    const ms = Math.floor(this.#host.now());
    if (ms > this.#clockMs) (this.#clockMs = ms), (this.#clockN = 0);
    else if (this.#clockN < 65535) this.#clockN++;
    else (this.#clockMs++, (this.#clockN = 0));
    return stampTime(this.#clockMs, this.#clockN) + codec.binary(this.#host.random(8));
  }

  #sendCells(cells: Written[], done?: () => void): void {
    const w = codec.writer();
    let last = "";
    const rows: string[] = [];
    for (const c of cells) {
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
    this.#pending.push({ seq, body, rows, done: done ?? (() => {}) });
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
      for (const id of p.rows) {
        const n = this.#unacked.get(id)! - 1;
        if (n > 0) this.#unacked.set(id, n);
        else this.#unacked.delete(id);
        const row = this.#rows.get(id);
        if (n === 0 && row && row.pages === 0 && row.held.size === 0) this.#rows.delete(id);
      }
      p.done();
    }
  }

  /**
   * Applies several changes as one: all visible in the same turn, all durable together or not at all. Resolves when they
   * are durable on this device.
   */
  write(scope: number, f: (change: Change) => void): Promise<void> {
    const s = this.#scopes.get(scope);
    if (!s || !(s.rights & 2)) throw new Error("this client may not write there");
    const cells: Written[] = [];
    const fresh = new Set<string>(); // rows made here
    const rows = new Set<string>();
    const put = (row: string, slot: number, kind: number, body: Uint8Array) => {
      if (body.length > MAX_OPEN) throw new RangeError("a value may be 1 MiB at most, less 192 bytes");
      const stamp = this.#stamp();
      rows.add(row);
      cells.push({ row, slot, kind, stamp, body });
      this.#accept(this.#row(row), slot, kind, stamp, body, this.#mine(scope));
    };
    const set = (bin: string, schema: Table, values: Record<string, unknown>) => {
      for (const name in values) {
        const value = values[name];
        const c = schema[name];
        if (!c || c.who) throw new Error(`no column ${name} to write`);
        if (value === undefined) continue;
        // Empty text is what a text is before anything is written: it need only be said to clear one.
        const row = this.#rows.get(bin);
        if (value !== "" || !c.text || (row && row.slots.has(c.slot)) || !fresh.has(bin)) put(bin, c.slot, VALUE, c.encode(value));
      }
    };
    const place = (bin: string, list: string, order: number, slot?: number) => {
      if (!Number.isSafeInteger(order) || order < 0) throw new RangeError("an order is a whole number from 0 to 2^53");
      const tag = this.tag(scope, list);
      put(bin, slot ?? 1, PLACE, codec.bytesOf(tag + codec.u64(order)));
    };
    const idOf = (id: string) => {
      const bin = codec.binary(codec.unhex(id));
      if (bin.length !== 16) throw new Error("a row's id is 32 hex digits");
      return bin;
    };
    // Done here, so that what is refused throws here.
    let resolve!: () => void;
    const result = new Promise<void>((done) => (resolve = done));
    {
      f({
        insert: (schema, list, order, values) => {
          // As late as anything heard of: later, then, than any right that is known to have ended.
          const ms = Math.floor(this.#host.now());
          if (ms > this.#clockMs) (this.#clockMs = ms), (this.#clockN = 0);
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
          const row = this.#row(bin);
          if (row.texts.get(slot)?.open) this.#seal(row, slot); // what an editor has open goes first
          const t = this.#text(row, slot);
          f(t, () => codec.binary(this.#host.random(8)));
          const stamp = this.#stamp();
          const body = text.close(t, stamp);
          if (body) {
            if (body.length > MAX_OPEN) throw new RangeError("an edit may be 1 MiB at most, less 192 bytes");
            rows.add(bin);
            cells.push({ row: bin, slot, kind: PIECE, stamp, body });
            merge(row, slot, PIECE, stamp, body);
            row.views.clear();
          }
        },
      });
      if (cells.length > 0) this.#sendCells(cells, resolve);
      else this.#host.defer(resolve);
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
      send: (data) => {
        const bytes = toBytes(data);
        if (bytes.length > CALL_WINDOW) throw new RangeError("a message may be 256 KiB at most");
        if (!over() && !live.finishing) {
          live.queue.push(bytes);
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
        if (!over()) {
          set.delete(id);
          this.#flow(id, side, F_CANCEL);
        }
      },
    };
    const live: LiveCall = { call, side, finishing: false, mineEnded: false, theirsEnded: false, credit: CALL_WINDOW, queue: [] };
    set.set(id, live);
    return live;
  }

  // Sends what the other side has room for, and then, if there is no more, says so.
  #drain(id: number, live: LiveCall): void {
    while (live.queue.length > 0 && live.credit >= live.queue[0].length) {
      const data = live.queue.shift()!;
      live.credit -= data.length;
      this.#flow(id, live.side, F_DATA, data);
    }
    if (live.finishing && live.queue.length === 0 && !live.mineEnded) {
      live.mineEnded = true;
      this.#flow(id, live.side, F_END);
      if (live.theirsEnded) (live.side === 0 ? this.#calls : this.#answers).delete(id);
    }
  }

  /** Calls a method on a device, by its id. Set ondata, onend and onfault on the result before the turn is out. */
  call(device: string, scope: number, method: string, data: Uint8Array | string = new Uint8Array()): Call {
    const id = ++this.#nextCall;
    const live = this.#call(id, 0, device, method);
    const first = toBytes(data);
    if (!this.#ready || first.length > CALL_WINDOW) {
      this.#calls.delete(id);
      const fault: Fault = this.#ready ? "overrun" : "unreachable";
      this.#host.defer(() => live.call.onfault?.(fault));
      return live.call;
    }
    live.credit -= first.length;
    const w = codec.writer();
    codec.putVarint(w, id);
    codec.put(w, codec.unhex(device));
    codec.putVarint(w, scope);
    codec.putBytes(w, utf8.encode(method));
    codec.putBytes(w, new Uint8Array()); // for whom is for the node to say
    codec.put(w, first);
    this.#frame(CALL, w);
    return live.call;
  }

  /** One question, one answer. Rejects with the fault, as a CallFault, if there is one. */
  request(device: string, scope: number, method: string, data: Uint8Array | string = new Uint8Array()): Promise<Uint8Array> {
    return new Promise((resolve, reject) => {
      const parts: Uint8Array[] = [];
      const call = this.call(device, scope, method, data);
      call.ondata = (d) => parts.push(d);
      call.onend = () => resolve(concat(parts));
      call.onfault = (f) => reject(new CallFault(f));
      call.finish();
    });
  }

  /** Answers a method within a scope. The handler gets the call and its first message. Returns a way to stop. */
  serve(scope: number, method: string, handler: (call: Call, data: Uint8Array) => void): () => void {
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
    const w = codec.writer();
    codec.putVarint(w, data.length);
    this.#flow(id, 1, F_CREDIT, codec.written(w));
    handler(live.call, data);
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
      const w = codec.writer();
      codec.putVarint(w, data.length);
      this.#flow(id, live.side, F_CREDIT, codec.written(w));
      call.ondata?.(data);
    } else if (kind === F_CREDIT) {
      live.credit += codec.varint(r);
      this.#drain(id, live);
    } else if (kind === F_END) {
      live.theirsEnded = true;
      if (live.mineEnded) set.delete(id);
      call.onend?.();
    } else {
      set.delete(id);
      const code = kind === F_FAULT && r.pos < r.len ? codec.u8(r) : 0;
      call.onfault?.(FAULTS[code] ?? "cancelled");
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
