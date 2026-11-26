// Bytes on the wire, big-endian as SPEC.md 2 says. Identifiers, stamps, tags, keys and element names are kept as binary
// strings, one char to a byte: they compare bytewise with <, which is exactly the protocol's order, and serve as Map keys.
// Everything else is a Uint8Array.
//
// Numbers are exact to 2^53. A varint may have ten bytes, and a value up to 2^64 − 1; one beyond 2^53 − 1 is refused as
// Malformed when read, and cannot be written, rather than come out as some other number. Nothing a client reads as a varint
// comes near: lengths, counts, offsets, sequence numbers. Ids, stamps and orders are never varints, and stay binary strings.

export interface Reader {
  buf: Uint8Array;
  pos: number;
  len: number;
}

export interface Writer {
  buf: Uint8Array<ArrayBuffer>;
  pos: number;
}

// What does not decode: read past the end, a varint too long or too large, a key too long.
export class Malformed extends Error {
  override name = "Malformed";
}

export const KEY_MAX = "\xff".repeat(40);

const ZEROS = "\0".repeat(40);
const utf8 = new TextEncoder();
const scratch = new DataView(new ArrayBuffer(8));
const scratchBytes = new Uint8Array(scratch.buffer);

// ---------------------------------------------------------------- binary strings

const CHUNK = 8192; // chars to a String.fromCharCode call, well within any engine's limit on arguments

// The bytes as a binary string.
export function binary(bytes: Uint8Array, from = 0, to = bytes.length): string {
  if (to - from <= CHUNK) return String.fromCharCode.apply(null, bytes.subarray(from, to) as unknown as number[]);
  let s = "";
  for (let at = from; at < to; at += CHUNK) {
    s += String.fromCharCode.apply(null, bytes.subarray(at, Math.min(at + CHUNK, to)) as unknown as number[]);
  }
  return s;
}

// A binary string's bytes.
export function bytesOf(s: string): Uint8Array {
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

const DIGITS = Array.from({ length: 256 }, (_, i) => i.toString(16).padStart(2, "0"));

export function hex(data: string | Uint8Array): string {
  let s = "";
  if (typeof data === "string") {
    for (let i = 0; i < data.length; i++) s += DIGITS[data.charCodeAt(i) & 255];
  } else {
    for (let i = 0; i < data.length; i++) s += DIGITS[data[i]];
  }
  return s;
}

// Hex as a binary string: a row's id as the public API has it, as it is kept.
export function binaryFromHex(s: string): string {
  return binary(unhex(s));
}

// The value of each hex digit by its char code, and 255 for what is none.
const NIBBLE = (() => {
  const t = new Uint8Array(128).fill(255);
  for (let i = 0; i < 16; i++) t["0123456789abcdef".charCodeAt(i)] = t["0123456789ABCDEF".charCodeAt(i)] = i;
  return t;
})();

export function unhex(s: string): Uint8Array {
  if (s.length % 2 !== 0) throw new Malformed("not hex");
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) {
    const hi = NIBBLE[s.charCodeAt(2 * i)] ?? 255, lo = NIBBLE[s.charCodeAt(2 * i + 1)] ?? 255;
    if ((hi | lo) > 15) throw new Malformed("not hex");
    out[i] = (hi << 4) | lo;
  }
  return out;
}

// ---------------------------------------------------------------- reading

export function reader(data: Uint8Array): Reader {
  return { buf: data, pos: 0, len: data.length };
}

function short(): never {
  throw new Malformed("past the end");
}

export function u8(r: Reader): number {
  if (r.pos >= r.len) short();
  return r.buf[r.pos++];
}

export function varint(r: Reader): number {
  const buf = r.buf;
  let pos = r.pos;
  if (pos >= r.len) short();
  let b = buf[pos++];
  if (b < 128) {
    r.pos = pos;
    return b;
  }
  let v = b & 127;
  let scale = 128;
  for (let n = 1; ; n++) {
    if (n === 10) throw new Malformed("a varint of more than ten bytes");
    if (pos >= r.len) short();
    b = buf[pos++];
    v += (b & 127) * scale; // exact while below 2^53, and past it no less than 2^53
    if (b < 128) break;
    scale *= 128;
  }
  if (v > Number.MAX_SAFE_INTEGER) throw new Malformed("a varint beyond 2^53");
  r.pos = pos;
  return v;
}

// The next n bytes, as a view of what is being read: nothing is copied.
export function take(r: Reader, n: number): Uint8Array {
  const at = r.pos;
  if (!(n >= 0 && at + n <= r.len)) short();
  r.pos = at + n;
  return r.buf.subarray(at, at + n);
}

// The next n bytes as a binary string.
export function takeBinary(r: Reader, n: number): string {
  const at = r.pos;
  if (!(n >= 0 && at + n <= r.len)) short();
  r.pos = at + n;
  return binary(r.buf, at, at + n);
}

export function bytes(r: Reader): Uint8Array {
  return take(r, varint(r));
}

export function rest(r: Reader): Uint8Array {
  return take(r, r.len - r.pos);
}

export function key(r: Reader): string {
  const n = u8(r);
  if (n === 255) return KEY_MAX;
  if (n > 40) throw new Malformed("a key of more than 40 bytes");
  return takeBinary(r, n) + ZEROS.slice(n);
}

export function u32(r: Reader): number {
  if (r.pos + 4 > r.len) short();
  const b = r.buf;
  const p = r.pos;
  r.pos = p + 4;
  return ((b[p] << 24) | (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3]) >>> 0;
}

export function f64(r: Reader): number {
  scratchBytes.set(take(r, 8));
  return scratch.getFloat64(0);
}

// ---------------------------------------------------------------- writing

export function writer(size = 128): Writer {
  return { buf: new Uint8Array(size), pos: 0 };
}

// What a writer only ever appends to, it never writes over: so a view of what is written stays true, even once the
// writer has grown into another buffer.
export function room(w: Writer, n: number): void {
  const need = w.pos + n;
  const have = w.buf.length;
  if (need > have) {
    const grown = new Uint8Array(Math.max(have * 2, need));
    grown.set(w.buf.subarray(0, w.pos));
    w.buf = grown;
  }
}

export function putU8(w: Writer, v: number): void {
  room(w, 1);
  w.buf[w.pos++] = v;
}

export function putVarint(w: Writer, v: number): void {
  if (!Number.isSafeInteger(v) || v < 0) throw new RangeError(`no varint for ${v}`);
  room(w, 8); // 7 × 8 bits hold everything below 2^53
  const buf = w.buf;
  let pos = w.pos;
  while (v > 0x7fffffff) {
    buf[pos++] = (v % 128) + 128;
    v = Math.floor(v / 128);
  }
  while (v >= 128) {
    buf[pos++] = (v & 127) | 128;
    v >>>= 7;
  }
  buf[pos++] = v;
  w.pos = pos;
}

export function put(w: Writer, data: Uint8Array): void {
  room(w, data.length);
  w.buf.set(data, w.pos);
  w.pos += data.length;
}

export function putBinary(w: Writer, s: string): void {
  const n = s.length;
  room(w, n);
  const buf = w.buf;
  const pos = w.pos;
  for (let i = 0; i < n; i++) buf[pos + i] = s.charCodeAt(i);
  w.pos = pos + n;
}

export function putBytes(w: Writer, data: Uint8Array): void {
  putVarint(w, data.length);
  put(w, data);
}

// How many bytes a string takes in UTF-8, a lone surrogate being U+FFFD as TextEncoder makes it.
export function utf8Length(s: string): number {
  let n = s.length;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    if (c < 0x80) continue;
    if (c < 0x800) n += 1;
    else if (c >= 0xd800 && c < 0xdc00 && i + 1 < s.length && (s.charCodeAt(i + 1) & 0xfc00) === 0xdc00) n += 2, i++;
    else n += 2;
  }
  return n;
}

// A string as bytes: a varint length and its UTF-8, encoded in place. Says how many bytes the UTF-8 took.
export function putUtf8(w: Writer, s: string): number {
  const n = utf8Length(s);
  putVarint(w, n);
  room(w, n);
  utf8.encodeInto(s, w.buf.subarray(w.pos, w.pos + n));
  w.pos += n;
  return n;
}

export function putKey(w: Writer, key: string): void {
  if (key === KEY_MAX) {
    putU8(w, 255);
    return;
  }
  let n = 40;
  while (n > 0 && key.charCodeAt(n - 1) === 0) n--;
  putU8(w, n);
  putBinary(w, n === 40 ? key : key.slice(0, n));
}

export function putU32(w: Writer, v: number): void {
  room(w, 4);
  const b = w.buf;
  const p = w.pos;
  b[p] = v >>> 24;
  b[p + 1] = v >>> 16;
  b[p + 2] = v >>> 8;
  b[p + 3] = v;
  w.pos = p + 4;
}

export function putF64(w: Writer, v: number): void {
  scratch.setFloat64(0, v);
  put(w, scratchBytes);
}

// What has been written, as a view: nothing is copied, and it stays true (see room).
export function written(w: Writer): Uint8Array<ArrayBuffer> {
  return w.buf.subarray(0, w.pos);
}

// ---------------------------------------------------------------- helpers

// A whole number below 2^53 as eight big-endian bytes.
export function u64(v: number): string {
  if (!Number.isSafeInteger(v) || v < 0) throw new RangeError(`no u64 for ${v}`);
  return u64HiLo(Math.floor(v / 4294967296), v % 4294967296);
}

// Eight big-endian bytes from `at` as a number: exact below 2^53, and the nearest double above, as in Luau. fromU64Big
// is exact.
export function fromU64(s: string, at = 0): number {
  return u32Of(s, at) * 4294967296 + u32Of(s, at + 4);
}

export function u64Big(v: bigint): string {
  if (v < 0n || v >= 1n << 64n) throw new RangeError(`no u64 for ${v}`);
  return u64HiLo(Number(v >> 32n), Number(v & 0xffffffffn));
}

export function fromU64Big(s: string, at = 0): bigint {
  return (BigInt(u32Of(s, at)) << 32n) | BigInt(u32Of(s, at + 4));
}

function u64HiLo(hi: number, lo: number): string {
  return String.fromCharCode(hi >>> 24, (hi >>> 16) & 255, (hi >>> 8) & 255, hi & 255, lo >>> 24, (lo >>> 16) & 255, (lo >>> 8) & 255, lo & 255);
}

// Four big-endian bytes of a binary string from `at`.
export function u32Of(s: string, at = 0): number {
  return ((s.charCodeAt(at) << 24) | (s.charCodeAt(at + 1) << 16) | (s.charCodeAt(at + 2) << 8) | s.charCodeAt(at + 3)) >>> 0;
}

export function u32Binary(v: number): string {
  return String.fromCharCode(v >>> 24, (v >>> 16) & 255, (v >>> 8) & 255, v & 255);
}

// A stamp's time: milliseconds and counter.
export function clock(stamp: string): [ms: number, n: number] {
  return [u32Of(stamp, 0) * 65536 + ((stamp.charCodeAt(4) << 8) | stamp.charCodeAt(5)), (stamp.charCodeAt(6) << 8) | stamp.charCodeAt(7)];
}

// The least key above every key beginning with the prefix.
export function after(prefix: string): string {
  let n = prefix.length;
  while (n > 0 && prefix.charCodeAt(n - 1) === 255) n--;
  if (n === 0) return KEY_MAX;
  return prefix.slice(0, n - 1) + String.fromCharCode(prefix.charCodeAt(n - 1) + 1) + ZEROS.slice(n);
}
