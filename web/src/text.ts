// The text column of SPEC.md 5, operation for operation, as luau/zsp/text.luau has it. See zsp/text.odin for the reasoning.
//
// Positions and elements are bytes of UTF-8. Piece ids, stamps and element names are binary strings (see codec.ts); what
// is typed is bytes, or a string to be typed as UTF-8. A text may keep views of what it is given rather than copies, so a
// body passed to apply or live must not be changed afterwards.

import * as codec from "./codec.ts";

// Elements of one piece, one after another both there and in the document. Its bytes are its piece's, from its offset.
type Span = {
  piece: string;
  home: Piece; // that piece
  offset: number;
  len: number;
  dead: boolean;
  label: number; // greater than that of any span before it: so where two elements are is found in a few steps
};

// Elements made at once: the first hangs beneath what its operation says, and each of the rest beneath the one before.
type Run = {
  piece: string;
  offset: number; // of its first element; it lasts until the piece's next run
  ppiece: string; // what the first hangs beneath: "" for the start of the document
  poffset: number;
  right: boolean;
  depth: number;
  hops: number;
  up: Run | null;
  jump: Run | null;
};

type Piece = {
  count: number;
  rpiece: string; // the last insertion's right neighbour
  roffset: number;
  fed: number;
  stamp: string; // "" while only live
  shown: Uint8Array[]; // what was consumed while only live, to hold the sealed piece to
  runs: Run[];
  spans: Span[]; // its spans, by offset
  data: Uint8Array; // its bytes, by offset: what arrived itself while it came in one go, and a copy once it did not
  owned: boolean; // data is a copy, which may grow in place
};

type Waiting = { piece: string; rest: Uint8Array; at: number };

export type Text = {
  spans: Span[];
  pieces: Map<string, Piece>;
  waiting: Waiting[];
  base: string;
  hint: number;
  open: string; // the piece being written here, or ""
  ops: codec.Writer; // its id and then its operations
  size: number; // bytes of operations
  flushed: number;
  cache: string | null;
  content: Uint8Array<ArrayBuffer> | null; // the bytes that are there, once asked for
  visible: number; // how many
  before: number[]; // visible bytes before each span, as far as known: to `known`, and not past what changed since
  known: number;
  version: number; // counts changes, that whoever reads it may know whether to again
};

export type Result = "same" | "changed" | "waiting" | "rebuild";

// What has been written since the last flush.
export type Flushed = [piece: string, offset: number, bytes: Uint8Array<ArrayBuffer>];

const INSERT = 1;
const EXTEND = 2;
const DELETE = 3;
const NOBODY = "\0".repeat(8);
const ONE = "\0".repeat(7) + "\x01";
const EMPTY: Uint8Array<ArrayBuffer> = new Uint8Array(0);
const utf8 = new TextDecoder("utf-8", { ignoreBOM: true });

export function create(): Text {
  return {
    spans: [],
    pieces: new Map(),
    waiting: [],
    base: "",
    hint: 0,
    open: "",
    ops: codec.writer(0),
    size: 0,
    flushed: 0,
    cache: null,
    content: null,
    visible: 0,
    before: [],
    known: -1,
    version: 0,
  };
}

function touch(t: Text): void {
  t.cache = null;
  t.content = null;
  t.version++;
}

function pieceOf(t: Text, id: string): Piece {
  let p = t.pieces.get(id);
  if (p === undefined) {
    p = { count: 0, rpiece: "", roffset: 0, fed: 0, stamp: "", shown: [], runs: [], spans: [], data: EMPTY, owned: false };
    t.pieces.set(id, p);
  }
  return p;
}

function present(t: Text, piece: string, offset: number, n: number): boolean {
  if (piece === "") return true;
  const p = t.pieces.get(piece);
  return p !== undefined && offset + n <= p.count;
}

// Takes a piece's next bytes. Its first are kept as they came; after that, its bytes are copied into room of its own.
function hold(p: Piece, bytes: Uint8Array): void {
  const at = p.count;
  const n = bytes.length;
  if (at === 0) {
    p.data = bytes;
    p.owned = false;
    return;
  }
  if (!p.owned || at + n > p.data.length) {
    const grown = new Uint8Array(Math.max(2 * (at + n), 16));
    grown.set(p.data.subarray(0, at));
    p.data = grown;
    p.owned = true;
  }
  copy(p.data, at, bytes, 0, n);
}

// Copies n bytes from one place to another. A few are quicker by hand than by set.
function copy(to: Uint8Array, at: number, from: Uint8Array, start: number, n: number): void {
  if (n > 32) to.set(from.subarray(start, start + n), at);
  else for (let k = 0; k < n; k++) to[at + k] = from[start + k];
}

// Where the span holding an element is among its piece's; if none does, ~ where the search for it ended.
function seat(p: Piece, offset: number): number {
  const list = p.spans;
  let lo = 0;
  let hi = list.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const s = list[mid];
    if (offset < s.offset) hi = mid - 1;
    else if (offset >= s.offset + s.len) lo = mid + 1;
    else return mid;
  }
  return ~lo;
}

// A piece's span holding an element, or null.
function spanOf(p: Piece | undefined, offset: number): Span | null {
  if (p === undefined) return null;
  const at = seat(p, offset);
  return at >= 0 ? p.spans[at] : null;
}

// Where a span is in the document: by its label, the spans' labels going up along it.
function indexOf(t: Text, s: Span): number {
  const spans = t.spans;
  const label = s.label;
  let lo = 0;
  let hi = spans.length - 1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    const l = spans[mid].label;
    if (l < label) lo = mid + 1;
    else if (l > label) hi = mid - 1;
    else return mid;
  }
  throw new Error("a span is not where its label says");
}

function find(t: Text, piece: string, offset: number): number {
  const spans = t.spans;
  const last = Math.min(t.hint + 2, spans.length - 1);
  for (let i = Math.max(t.hint - 2, 0); i <= last; i++) {
    const s = spans[i];
    if (s.piece === piece && offset >= s.offset && offset < s.offset + s.len) return i;
  }
  // By the piece's spans, and the label of the one found; text.luau looks at every span instead, which comes to the same.
  const p = t.pieces.get(piece);
  const s = spanOf(p, offset);
  if (s !== null) {
    const i = indexOf(t, s);
    t.hint = i;
    return i;
  }
  // Not there only if the piece's spans are out of order, which typing nothing with `after` brings about: as text.luau
  // does, it is looked for along the whole document.
  for (let i = 0; i < spans.length; i++) {
    const s = spans[i];
    if (s.piece === piece && offset >= s.offset && offset < s.offset + s.len) {
      t.hint = i;
      return i;
    }
  }
  throw new Error("a reference that was checked is missing");
}

// Labels go up along the document, with room between them; when there is none, they are made again.
const GAP = 2 ** 20;
function label(t: Text, i: number): void {
  const spans = t.spans;
  const lo = i > 0 ? spans[i - 1].label : 0;
  if (i === spans.length - 1) {
    spans[i].label = lo + GAP;
    return;
  }
  const hi = spans[i + 1].label;
  const l = (lo + hi) / 2;
  if (!(l > lo && l < hi)) {
    for (let k = 0; k < spans.length; k++) spans[k].label = (k + 1) * GAP;
    return;
  }
  spans[i].label = l;
}

// What is known of how much is visible before each span holds no further than a span that changed.
function changed(t: Text, i: number): void {
  if (i < t.known) t.known = i;
}

// The first span at or after which the visible bytes reach pos (from 1), or one past the last: found by halving what is
// known of how much is visible before each, and counting only what changed since. So typing in one place, or at the
// end, counts a span or two, however long the text.
function seek(t: Text, pos: number): number {
  const spans = t.spans, before = t.before;
  const n = spans.length;
  let known = t.known;
  if (known < 0) (before[0] = 0), (known = 0);
  while (known < n) {
    const s = spans[known];
    const reach = before[known] + (s.dead ? 0 : s.len);
    if (reach >= pos) break;
    before[++known] = reach;
  }
  t.known = known;
  if (known >= n) return n;
  let lo = 0, hi = known;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    const s = spans[mid];
    if (before[mid] + (s.dead ? 0 : s.len) >= pos) hi = mid;
    else lo = mid + 1;
  }
  return lo;
}

function split(t: Text, i: number, n: number): void {
  const s = t.spans[i];
  if (n === 0 || n >= s.len) return;
  const tail: Span = { piece: s.piece, home: s.home, offset: s.offset + n, len: s.len - n, dead: s.dead, label: 0 };
  t.spans.splice(i + 1, 0, tail);
  s.len = n;
  changed(t, i);
  label(t, i + 1);
  const p = s.home;
  const at = seat(p, s.offset);
  p.spans.splice((at >= 0 ? at : ~at) + 1, 0, tail); // as text.luau has it, should the piece's spans be out of order
}

// Index of the span ending with the element; -1 for the document's start.
function leftOf(t: Text, piece: string, offset: number): number {
  if (piece === "") return -1;
  const i = find(t, piece, offset);
  split(t, i, offset - t.spans[i].offset + 1);
  return i;
}

// Index of the span beginning with the element; one past the last for the document's end.
function rightOf(t: Text, piece: string, offset: number): number {
  if (piece === "") return t.spans.length;
  const i = find(t, piece, offset);
  const n = offset - t.spans[i].offset;
  if (n > 0) {
    split(t, i, n);
    return i + 1;
  }
  return i;
}

// ---------------------------------------------------------------- the tree

function runOf(t: Text, piece: string, offset: number): Run {
  const runs = t.pieces.get(piece)!.runs;
  let lo = 0;
  let hi = runs.length - 1;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (runs[mid].offset <= offset) lo = mid;
    else hi = mid - 1;
  }
  return runs[lo];
}

function depthOf(t: Text, piece: string, offset: number): number {
  if (piece === "") return 0;
  const r = runOf(t, piece, offset);
  return r.depth + offset - r.offset;
}

let taken = 0; // steps taken in finding places, which tests count

// What an element hangs beneath at a depth no greater than its own, in a few steps however deep: its piece, and
// ancestorOffset its offset.
let ancestorOffset = 0;
function ancestor(t: Text, piece: string, offset: number, depth: number): string {
  if (depth === 0) {
    ancestorOffset = 0;
    return "";
  }
  let r = runOf(t, piece, offset);
  while (r.depth > depth) {
    taken++;
    const j = r.jump;
    r = j !== null && j.depth > depth ? j : r.up!;
  }
  ancestorOffset = r.offset + depth - r.depth;
  return r.piece;
}

// Whether one element hangs beneath another; everything beneath the start, and nothing beneath the end.
function below(t: Text, xp: string, xo: number, ap: string, ao: number): boolean {
  if (xp === "") return false;
  if (ap === "") return true;
  const dx = depthOf(t, xp, xo);
  const da = depthOf(t, ap, ao);
  if (dx <= da) return false;
  return ancestor(t, xp, xo, da) === ap && ancestorOffset === ao;
}

// Siblings go by piece and then by number.
function keyLess(ap: string, ao: number, bp: string, bo: number): boolean {
  return ap < bp || (ap === bp && ao < bo);
}

type Probe = { piece: string; offset: number; depth: number; kpiece: string; koffset: number; right: boolean };

// Whether a span hangs beneath the parent, beneath a sibling before what is inserted on the right, or after it on the
// left. Going away from the parent such spans come first, and then none.
function probe(t: Text, i: number, q: Probe): boolean {
  taken++;
  const s = t.spans[i];
  if (!below(t, s.piece, s.offset, q.piece, q.offset)) return false;
  const cp = ancestor(t, s.piece, s.offset, q.depth + 1);
  const co = ancestorOffset;
  if (q.right) return keyLess(cp, co, q.kpiece, q.koffset);
  return keyLess(q.kpiece, q.koffset, cp, co);
}

// The first index from i on of which the probe is false (or one past the last), by doubling and halving.
function seekForward(t: Text, i: number, q: Probe): number {
  const n = t.spans.length;
  if (i >= n || !probe(t, i, q)) return i;
  let lo = i;
  let step = 1;
  while (lo + step < n && probe(t, lo + step, q)) {
    lo += step;
    step *= 2;
  }
  let hi = Math.min(lo + step, n);
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (probe(t, mid, q)) lo = mid;
    else hi = mid;
  }
  return hi;
}

// The last index from i back of which the probe is false, or -1.
function seekBack(t: Text, i: number, q: Probe): number {
  if (i < 0 || !probe(t, i, q)) return i;
  let hi = i;
  let step = 1;
  while (hi - step >= 0 && probe(t, hi - step, q)) {
    hi -= step;
    step *= 2;
  }
  let lo = Math.max(hi - step, -1);
  while (hi - lo > 1) {
    const mid = (lo + hi) >> 1;
    if (probe(t, mid, q)) hi = mid;
    else lo = mid;
  }
  return lo;
}

function insertRun(t: Text, id: string, bytes: Uint8Array, lpiece: string, loffset: number, rpiece: string, roffset: number): void {
  touch(t);
  const p = pieceOf(t, id);
  const offset = p.count;
  hold(p, bytes);
  p.count += bytes.length;
  p.rpiece = rpiece;
  p.roffset = roffset;

  // Beneath the right neighbour if that is beneath the left, and otherwise beneath the left.
  const under = below(t, rpiece, roffset, lpiece, loffset);
  const ppiece = under ? rpiece : lpiece;
  const poffset = under ? roffset : loffset;
  const chain = !under && ppiece === id && poffset === offset - 1;
  if (!chain) {
    const up = ppiece !== "" ? runOf(t, ppiece, poffset) : null;
    const run: Run = { piece: id, offset, ppiece, poffset, right: !under, depth: depthOf(t, ppiece, poffset) + 1, hops: 1, up, jump: up };
    if (up !== null) {
      run.hops = up.hops + 1;
      const j = up.jump;
      if (j !== null) {
        const jj = j.jump;
        if (up.hops - j.hops === j.hops - (jj !== null ? jj.hops : 0)) run.jump = jj;
      }
    }
    p.runs.push(run);
  }

  // Among its siblings, each with all beneath it: on the right, after the parent; on the left, before it.
  const q: Probe = { piece: ppiece, offset: poffset, depth: depthOf(t, ppiece, poffset), kpiece: id, koffset: offset, right: !under };
  const at = under ? seekBack(t, rightOf(t, ppiece, poffset) - 1, q) + 1 : seekForward(t, leftOf(t, ppiece, poffset) + 1, q);
  const spans = t.spans;
  if (at > 0 && chain) {
    const b = spans[at - 1];
    if (b.piece === id && b.offset + b.len === offset && !b.dead) {
      b.len += bytes.length;
      t.visible += bytes.length;
      changed(t, at - 1);
      t.hint = at - 1;
      return;
    }
  }
  const made: Span = { piece: id, home: p, offset, len: bytes.length, dead: false, label: 0 };
  spans.splice(at, 0, made);
  t.visible += bytes.length;
  changed(t, at);
  label(t, at);
  p.spans.push(made); // the newest of its piece, so the last
  t.hint = at;
}

function kill(t: Text, piece: string, offset: number, count: number): void {
  touch(t);
  while (count > 0) {
    const i = rightOf(t, piece, offset);
    split(t, i, count);
    const s = t.spans[i];
    if (!s.dead) (t.visible -= s.len), changed(t, i);
    s.dead = true;
    offset += s.len;
    count -= s.len;
  }
}

// No offset or count is so large: what says one is nonsense, as zsp/text.odin has it.
const MOST = 2 ** 30;

// A reference: its piece, and refOffset its offset.
let refOffset = 0;
function readRef(r: codec.Reader, id: string): string {
  const tag = codec.u8(r);
  if (tag === 0) {
    refOffset = 0;
    return "";
  }
  let piece = id;
  if (tag === 2) piece = codec.takeBinary(r, 8);
  else if (tag !== 1) throw new codec.Malformed("bad reference");
  refOffset = codec.varint(r);
  if (piece === NOBODY || refOffset > MOST) throw new codec.Malformed("bad reference");
  return piece;
}

// One operation: the reader is left after it, or false is returned if it refers to what is not here. What is not an
// operation at all throws Malformed.
function applyOp(t: Text, id: string, r: codec.Reader): boolean {
  const op = codec.u8(r);
  if (op === INSERT) {
    const lp = readRef(r, id);
    const lo = refOffset;
    const rp = readRef(r, id);
    const ro = refOffset;
    const bytes = codec.bytes(r);
    if (!present(t, lp, lo, 1) || !present(t, rp, ro, 1)) return false;
    if (bytes.length > 0) insertRun(t, id, bytes, lp, lo, rp, ro);
  } else if (op === EXTEND) {
    const bytes = codec.bytes(r);
    const p = pieceOf(t, id);
    if (p.count === 0) throw new codec.Malformed("nothing to extend"); // what it would extend comes before it, or never
    if (bytes.length > 0) insertRun(t, id, bytes, id, p.count - 1, p.rpiece, p.roffset);
  } else if (op === DELETE) {
    const fp = readRef(r, id);
    const fo = refOffset;
    const count = codec.varint(r);
    if (fp === "" || count > MOST) throw new codec.Malformed("bad deletion");
    if (!present(t, fp, fo, count)) return false;
    kill(t, fp, fo, count);
  } else {
    throw new codec.Malformed("no such operation");
  }
  return true;
}

// Whether the last applyOps stopped at what does not read as an operation: the rest of its piece is nothing, and waits
// for nothing, since nothing that comes could make it read.
let malformed = false;

function applyOps(t: Text, id: string, ops: Uint8Array): number {
  const r = codec.reader(ops);
  let done = 0;
  malformed = false;
  while (r.pos < r.len) {
    let applied: boolean;
    try {
      applied = applyOp(t, id, r);
    } catch (e) {
      if (!(e instanceof codec.Malformed)) throw e;
      malformed = true;
      break;
    }
    if (!applied) break;
    const p = pieceOf(t, id);
    if (p.stamp === "" && id !== t.open) p.shown.push(ops.subarray(done, r.pos));
    p.fed += r.pos - done;
    done = r.pos;
  }
  return done;
}

function retry(t: Text): void {
  let i = 0;
  while (i < t.waiting.length) {
    const w = t.waiting[i];
    const n = applyOps(t, w.piece, w.rest.subarray(w.at));
    w.at += n;
    // Done, or the rest is nothing: what was after it is looked at next, rather than passed over until the next time.
    if (w.at === w.rest.length || malformed) t.waiting.splice(i, 1);
    else if (n === 0) i++;
    if (n > 0) i = 0;
  }
}

// Whether what was shown of a piece is where its operations begin.
function shownIs(p: Piece, ops: Uint8Array): boolean {
  let at = 0;
  for (const part of p.shown) {
    for (let k = 0; k < part.length; k++) if (part[k] !== ops[at + k]) return false;
    at += part.length;
  }
  return at === p.fed;
}

function applyPiece(t: Text, name: string, stamp: string, ops: Uint8Array): Result {
  let id = name;
  if (id === NOBODY) return "same"; // the edge of the document is nobody's piece
  const p = t.pieces.get(id);
  if (p !== undefined && p.stamp === stamp) return "same";
  if (p !== undefined && p.stamp !== "") {
    if (stamp < p.stamp) return "rebuild";
    id = stamp.slice(8);
    if (id === NOBODY || t.pieces.has(id)) return "same";
  }
  const piece = pieceOf(t, id);
  if (piece.fed > ops.length || !shownIs(piece, ops)) return "rebuild";
  piece.shown = [];
  piece.stamp = stamp;
  const at = piece.fed + applyOps(t, id, ops.subarray(piece.fed));
  if (at < ops.length && !malformed) t.waiting.push({ piece: id, rest: ops.subarray(at), at: 0 }); // only what refers to what is not here waits
  retry(t);
  for (const w of t.waiting) if (w.piece === id) return "waiting";
  return "changed";
}

// Applies the body of a cell in this text's slot. Kinds are the protocol's: 3 value, 4 piece, 5 bundle.
export function apply(t: Text, kind: number, stamp: string, body: Uint8Array): Result {
  if (stamp <= t.base) return "same";
  if (kind === 3) {
    if (t.pieces.size > 0) return "rebuild";
    t.base = stamp;
    let id = stamp.slice(8);
    if (id === NOBODY) id = ONE;
    pieceOf(t, id).stamp = stamp;
    if (body.length > 0) insertRun(t, id, body, "", 0, "", 0);
    return "changed";
  } else if (kind === 4) {
    if (body.length < 8) return "same";
    return applyPiece(t, codec.binary(body, 0, 8), stamp, body.subarray(8));
  } else if (kind === 5) {
    // Its entries, in order, up to the first that does not say all it should: the rest is nothing, the same for everyone.
    if (body.length < 4) return "same";
    const r = codec.reader(body);
    const n = codec.u32(r);
    r.pos = 4 + n * 16;
    let out: Result = "same";
    while (r.pos < r.len) {
      let inner: string, id: string, ops: Uint8Array;
      try {
        inner = codec.takeBinary(r, 16);
        id = codec.takeBinary(r, 8);
        ops = codec.bytes(r);
      } catch (e) {
        if (e instanceof codec.Malformed) break;
        throw e;
      }
      if (inner > t.base) {
        const result = applyPiece(t, id, inner, ops);
        if (result === "rebuild") return "rebuild";
        else if (result === "changed" || (result === "waiting" && out === "same")) out = result;
      }
    }
    return out;
  }
  return "same";
}

// Operations of a piece still being written, from a byte offset in its stream (SPEC.md 11).
export function live(t: Text, piece: string, offset: number, bytes: Uint8Array): Result {
  const p = t.pieces.get(piece);
  const fed = p !== undefined ? p.fed : 0;
  if ((p !== undefined && p.stamp !== "") || piece === t.open || piece === NOBODY || offset > fed || offset + bytes.length <= fed) return "same";
  if (applyOps(t, piece, bytes.subarray(fed - offset)) === 0) return "same";
  retry(t);
  return "changed";
}

// Whether anything here rests on frames no cell has confirmed.
export function provisional(t: Text): boolean {
  for (const [id, p] of t.pieces) if (p.stamp === "" && id !== t.open && p.fed > 0) return true;
  return false;
}

// The bytes that are there, in order: a view kept until the text changes, not to be written to.
export function content(t: Text): Uint8Array<ArrayBuffer> {
  if (t.content !== null) return t.content;
  const out = new Uint8Array(len(t));
  const spans = t.spans;
  let at = 0;
  for (let i = 0; i < spans.length; i++) {
    const s = spans[i];
    if (s.dead) continue;
    const data = s.home.data;
    const n = s.len;
    if (n > 32) out.set(data.subarray(s.offset, s.offset + n), at);
    else for (let k = 0, o = s.offset; k < n; k++) out[at + k] = data[o + k];
    at += n;
  }
  t.content = out;
  return out;
}

// The text, decoded once until it changes. Bytes that are not UTF-8 read as U+FFFD; content has them as they are.
export function read(t: Text): string {
  if (t.cache !== null) return t.cache;
  const s = utf8.decode(content(t));
  t.cache = s;
  return s;
}

// How many bytes are there.
export function len(t: Text): number {
  return t.visible;
}

function begin(t: Text, fresh: () => string): void {
  if (t.open === "") {
    const id = fresh();
    if (id.length !== 8) throw new Error("a piece's id is eight bytes");
    t.open = id;
    pieceOf(t, id);
    t.ops = codec.writer(64);
    codec.putBinary(t.ops, id);
  }
}

function putRef(w: codec.Writer, id: string, piece: string, offset: number): void {
  if (piece === "") {
    codec.putU8(w, 0);
  } else if (piece === id) {
    codec.putU8(w, 1);
    codec.putVarint(w, offset);
  } else {
    codec.putU8(w, 2);
    codec.putBinary(w, piece);
    codec.putVarint(w, offset);
  }
}

// Writes an insertion of bytes between two elements, and yields the bytes as written, which the text then holds: so
// nothing the caller has can change it.
function recordInsert(t: Text, bytes: Uint8Array | string, lp: string, lo: number, rp: string, ro: number): Uint8Array {
  const id = t.open;
  const p = pieceOf(t, id);
  const w = t.ops;
  const from = w.pos;
  if (p.count > 0 && lp === id && lo === p.count - 1 && rp === p.rpiece && ro === p.roffset) {
    codec.putU8(w, EXTEND);
  } else {
    codec.putU8(w, INSERT);
    putRef(w, id, lp, lo);
    putRef(w, id, rp, ro);
  }
  let n = bytes.length;
  if (typeof bytes === "string") n = codec.putUtf8(w, bytes);
  else codec.putBytes(w, bytes);
  t.size += w.pos - from;
  return w.buf.subarray(w.pos - n, w.pos);
}

function recordDelete(t: Text, s: Span): void {
  const w = t.ops;
  const from = w.pos;
  codec.putU8(w, DELETE);
  putRef(w, t.open, s.piece, s.offset);
  codec.putVarint(w, s.len);
  t.size += w.pos - from;
}

// Types bytes, or a string as UTF-8, before the visible byte at `pos` (zero-based). `fresh` draws eight random bytes.
export function insert(t: Text, pos: number, bytes: Uint8Array | string, fresh: () => string): void {
  if (bytes.length === 0) return;
  begin(t, fresh);
  const spans = t.spans;
  let lp = "";
  let lo = 0;
  let rp = "";
  let ro = 0;
  let i = 0;
  if (pos > 0) {
    // The span the byte before it is in; past the end, it is put between the start and the end.
    i = seek(t, pos);
    if (i < spans.length) {
      split(t, i, pos - t.before[i]);
      const s = spans[i];
      lp = s.piece;
      lo = s.offset + s.len - 1;
      i++;
    }
  }
  if (i < spans.length) {
    rp = spans[i].piece;
    ro = spans[i].offset;
  }
  const held = recordInsert(t, bytes, lp, lo, rp, ro);
  insertRun(t, t.open, held, lp, lo, rp, ro);
}

export function erase(t: Text, pos: number, count: number, fresh: () => string): void {
  if (count <= 0) return;
  begin(t, fresh);
  touch(t);
  const spans = t.spans;
  // From the span the first byte is in.
  let i = seek(t, pos + 1);
  if (i < spans.length) pos -= t.before[i];
  while (i < spans.length && count > 0) {
    let s = spans[i];
    if (s.dead) {
      i++;
    } else if (pos >= s.len) {
      pos -= s.len;
      i++;
    } else if (pos > 0) {
      split(t, i, pos);
      pos = 0;
      i++;
    } else {
      split(t, i, count);
      s = spans[i];
      s.dead = true;
      t.visible -= s.len;
      changed(t, i);
      recordDelete(t, s);
      count -= s.len;
      i++;
    }
  }
}

// ---------------------------------------------------------------- elements by name

// An element's name: its piece, and its offset in it.
function eid(piece: string, offset: number): string {
  return piece + codec.u32Binary(offset);
}

// The elements that are there, in order: one name for each visible byte.
export function ids(t: Text): string[] {
  const out: string[] = [];
  for (const s of t.spans) {
    if (s.dead) continue;
    for (let k = 0; k < s.len; k++) out.push(eid(s.piece, s.offset + k));
  }
  return out;
}

// Where every element is, deleted or not, by name, counting from 1: what was inserted next to one stays next to it.
export function order(t: Text): Map<string, number> {
  const out = new Map<string, number>();
  let n = 0;
  for (const s of t.spans) {
    for (let k = 0; k < s.len; k++) out.set(eid(s.piece, s.offset + k), ++n);
  }
  return out;
}

// Types bytes just after an element, deleted or not ("" for the start), and says what the first is called.
export function after(t: Text, after: string, bytes: Uint8Array | string, fresh: () => string): string {
  if (bytes.length === 0) return ""; // nothing is put, and nothing named
  begin(t, fresh);
  let lp = "";
  let lo = 0;
  let i = 0;
  if (after !== "") {
    lp = after.slice(0, 8);
    lo = codec.u32Of(after, 8);
    i = leftOf(t, lp, lo) + 1;
  }
  let rp = "";
  let ro = 0;
  if (i < t.spans.length) {
    rp = t.spans[i].piece;
    ro = t.spans[i].offset;
  }
  const id = t.open;
  const first = pieceOf(t, id).count;
  const held = recordInsert(t, bytes, lp, lo, rp, ro);
  insertRun(t, id, held, lp, lo, rp, ro);
  return eid(id, first);
}

// Deletes elements by name: so many from one on, of one piece, those still there.
export function remove(t: Text, id: string, count: number, fresh: () => string): void {
  begin(t, fresh);
  touch(t);
  const piece = id.slice(0, 8);
  let offset = codec.u32Of(id, 8);
  while (count > 0) {
    const i = rightOf(t, piece, offset);
    split(t, i, count);
    const s = t.spans[i];
    if (!s.dead) {
      s.dead = true;
      t.visible -= s.len;
      changed(t, i);
      recordDelete(t, s);
    }
    offset += s.len;
    count -= s.len;
  }
}

// Where an element is, deleted or not, as two numbers to compare in order; null if it is not here.
export function position(t: Text, id: string): [label: number, offset: number] | null {
  const p = t.pieces.get(id.slice(0, 8));
  if (p === undefined) return null;
  const offset = codec.u32Of(id, 8);
  const s = spanOf(p, offset);
  if (s === null) return null;
  return [s.label, offset];
}

// Whether an element is here, and not deleted.
export function standing(t: Text, id: string): boolean {
  const p = t.pieces.get(id.slice(0, 8));
  const s = spanOf(p, codec.u32Of(id, 8));
  return s !== null && !s.dead;
}

// Whether an element is here, deleted or not.
export function has(t: Text, id: string): boolean {
  return present(t, id.slice(0, 8), codec.u32Of(id, 8), 1);
}

// What has been written since the last call: piece, offset, bytes. The bytes are a view that stays true.
export function flush(t: Text): Flushed {
  if (t.open === "") return ["", 0, EMPTY];
  const from = t.flushed;
  t.flushed = t.size;
  return [t.open, from, t.ops.buf.subarray(8 + from, 8 + t.size)];
}

// Ends the open piece and yields its cell's body, or null if nothing is open.
export function close(t: Text, stamp: string): Uint8Array<ArrayBuffer> | null {
  if (t.open === "") return null;
  const p = pieceOf(t, t.open);
  p.stamp = stamp;
  p.fed = t.size;
  const out = codec.written(t.ops);
  t.open = "";
  t.ops = codec.writer(0);
  t.size = 0;
  t.flushed = 0;
  return out;
}

// Steps taken so far in finding places: for tests.
export function steps(): number {
  return taken;
}
