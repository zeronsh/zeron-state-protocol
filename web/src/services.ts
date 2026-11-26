// Streams and services (SPEC.md §16): what a device's host lets others do on it, by methods of its own whose names begin
// "zsp.". Its shares, listed and set; commands run and terminals opened; TCP connections made there; files listed,
// fetched and sent, any size, resumed after a break from where they stopped, and checked chunk by chunk and whole.
//
// Each is a call (§12), and what comes in one is credited only as it is taken: by a reader, a socket or a disk. So a slow
// end slows the other, and nothing piles up between them. What is sent goes only as the other side has room for it.
//
// The other end is host/services.odin, host/exec.odin, host/bridge.odin and host/files.odin; a transfer here does what
// host/transfer.odin does, keeping a file being fetched beside where it is going, as `<name>.zsp-part`, with what is known
// of it in `<name>.zsp-part.meta`.

import * as codec from "./codec.ts";
import { Sha256 } from "./sha256.ts";
import type { Call, Client, Fault } from "./client.ts";
import type { FileInfo, Folder, OpenFile } from "./folder.ts";

export const CHUNK = 1 << 20; // a file is hashed in chunks of this
const FILE_READ = 64 << 10; // at most, in one message of a file
const PIECE = 64 << 10; // of what is written to a process or a connection, at most, in one message
export const PART = ".zsp-part"; // what a file being received is called until it is whole
export const META = ".meta"; // and what is known of it, after that

const utf8 = new TextEncoder();
const fromUtf8 = new TextDecoder();
const EMPTY = new Uint8Array(0);

// ---------------------------------------------------------------- what is said

/** Why a device would not, or a transfer could not: as the status that begins every answer says. */
export type Refusal = "denied" | "not offered" | "refused" | "unreachable" | "timed out" | "not found" | "failed" | "changed" | "exists" | "malformed";
const REFUSALS: Refusal[] = ["denied", "not offered", "refused", "unreachable", "timed out", "not found", "failed", "changed", "exists", "malformed"];
const CODES = new Map<Refusal, number>(REFUSALS.map((r, i) => [r, i + 1]));

/** A service refused, or a call to one failed. */
export class ServiceError extends Error {
  /** What went wrong, there or here. */
  readonly status: Refusal;
  /** In words, from whoever said so: empty if nobody said. */
  readonly reason: string;
  /** The call's fault, if that is what it was. */
  readonly fault?: Fault;

  constructor(status: Refusal, reason = "", fault?: Fault) {
    super(reason ? `${status}: ${reason}` : status);
    this.status = status;
    this.reason = reason;
    this.fault = fault;
  }

  /** As a transfer takes a call's fault: denied and unreachable as they are, and anything else as a failure. */
  static of(fault: Fault): ServiceError {
    return new ServiceError(fault === "denied" ? "denied" : fault === "unreachable" ? "unreachable" : "failed", fault, fault);
  }
}

/** What a device offers in a scope, as zsp.services lists it. */
export type Service =
  | { readonly kind: "shell"; readonly terminal: boolean; readonly commands: boolean }
  | { readonly kind: "files"; readonly name: string; readonly read: boolean; readonly write: boolean }
  | { readonly kind: "tcp"; readonly port: number; readonly host: string; readonly name: string };

/** What a folder holds, as zsp.list lists it. */
export interface Entry {
  readonly name: string;
  readonly kind: "file" | "folder" | "other";
  readonly size: number;
  /** When it was last written, in ms since 1970. */
  readonly modified: number;
}

/** How a process ended: its exit code, or the signal that ended it (POSIX numbers; Windows says codes only). */
export interface Exit {
  readonly code: number;
  readonly signal: number;
}

/** What may be said to a process, by name or by its POSIX number. */
export type Signal = "hangup" | "interrupt" | "quit" | "kill" | "terminate" | "continue" | "stop";
const SIGNALS: Record<Signal, number> = { hangup: 1, interrupt: 2, quit: 3, kill: 9, terminate: 15, continue: 18, stop: 19 };

/** Environment entries over the device's own: a value, or null to remove one. */
export type Environment = Readonly<Record<string, string | null>>;

const KINDS: Entry["kind"][] = ["file", "folder", "other"];

function putText(w: codec.Writer, s: string): void {
  codec.putBytes(w, utf8.encode(s));
}

function putStrings(w: codec.Writer, list: readonly string[]): void {
  codec.putVarint(w, list.length);
  for (const s of list) putText(w, s);
}

function entries(env: Environment = {}): string[] {
  return Object.entries(env).map(([name, value]) => {
    if (name === "" || name.includes("=")) throw new RangeError(`no environment variable is called ${JSON.stringify(name)}`);
    return value === null ? name : `${name}=${value}`;
  });
}

function u16(n: number, what: string): number {
  if (!Number.isInteger(n) || n < 0 || n > 65535) throw new RangeError(`${what} is a whole number from 0 to 65535`);
  return n;
}

/** zsp.tcp's first message: a port, and where, or nothing for the device's own loopback. */
export function tcpRequest(port: number, host = ""): Uint8Array {
  if (u16(port, "a port") === 0) throw new RangeError("a port is 1 to 65535");
  const name = utf8.encode(host);
  const out = new Uint8Array(2 + name.length);
  out[0] = port >> 8;
  out[1] = port & 255;
  out.set(name, 2);
  return out;
}

/** zsp.exec's: no flags, the program and its arguments, the environment, and the folder to start in, or its home. */
export function execRequest(argv: readonly string[], env?: Environment, cwd = ""): Uint8Array {
  if (argv.length === 0) throw new RangeError("a command has a program to run");
  const w = codec.writer();
  codec.putU8(w, 0);
  putStrings(w, argv);
  putStrings(w, entries(env));
  putText(w, cwd);
  return codec.written(w).slice();
}

/** zsp.pty's: the terminal's size and kind, then as zsp.exec's after its flags, but with no arguments: the user's shell. */
export function ptyRequest(rows: number, cols: number, term: string, env?: Environment, cwd = ""): Uint8Array {
  const w = codec.writer();
  for (const v of [u16(rows, "rows"), u16(cols, "columns")]) codec.putU8(w, v >> 8), codec.putU8(w, v & 255);
  putText(w, term);
  putStrings(w, []);
  putStrings(w, entries(env));
  putText(w, cwd);
  return codec.written(w).slice();
}

/** zsp.list's: a share's name and the path within it, or nothing for the shares themselves. */
export function listRequest(path: string): Uint8Array {
  const w = codec.writer();
  putText(w, path);
  return codec.written(w).slice();
}

/** zsp.get's: the path, and where a transfer broke off, of a file that was then as its identity says. */
export function getRequest(path: string, offset: number, identity: Uint8Array): Uint8Array {
  const w = codec.writer();
  putText(w, path);
  codec.putVarint(w, offset);
  codec.putBytes(w, identity);
  return codec.written(w).slice();
}

/** zsp.put's: the path, the file's size, time and identity here, and whether to replace one there and make folders on the way. */
export function putRequest(path: string, size: number, modified: number, identity: Uint8Array, flags: { replace?: boolean; folders?: boolean }): Uint8Array {
  const w = codec.writer();
  putText(w, path);
  codec.putVarint(w, size);
  codec.putVarint(w, modified);
  codec.putBytes(w, identity);
  codec.putU8(w, (flags.replace ? 1 : 0) | (flags.folders ? 2 : 0));
  return codec.written(w).slice();
}

/** Input to a process. */
export function inputMessage(bytes: Uint8Array): Uint8Array {
  const out = new Uint8Array(1 + bytes.length);
  out.set(bytes, 1);
  return out;
}

export function signalMessage(signal: Signal | number): Uint8Array {
  const n = typeof signal === "number" ? signal : SIGNALS[signal];
  if (!Number.isInteger(n) || n < 1 || n > 255) throw new RangeError(`no signal ${signal}`);
  return Uint8Array.of(1, n);
}

export function resizeMessage(rows: number, cols: number): Uint8Array {
  return Uint8Array.of(2, u16(rows, "rows") >> 8, rows & 255, u16(cols, "columns") >> 8, cols & 255);
}

/** A chunk's hash, after its bytes. */
export function chunkMessage(hash: Uint8Array): Uint8Array {
  const out = new Uint8Array(33);
  out[0] = 2;
  out.set(hash, 1);
  return out;
}

/** What follows a file's last bytes: the last chunk's hash, then the end and the file's hash. */
const TRAIL = 1 + 32 + (2 + 32);

/** The end of a file sent: how it went, and the file's hash. */
export function endMessage(status: Refusal | "ok", hash?: Uint8Array): Uint8Array {
  const out = new Uint8Array(2 + (hash ? 32 : 0));
  out[0] = 3;
  out[1] = status === "ok" ? 0 : CODES.get(status)!;
  if (hash) out.set(hash, 2);
  return out;
}

/** The status that begins an answer: "ok" and what follows, or why not and in what words. */
export function readStatus(bytes: Uint8Array): { status: Refusal | "ok"; reason: string; rest: Uint8Array } {
  if (bytes.length === 0) throw new codec.Malformed("no status");
  const code = bytes[0];
  if (code === 0) return { status: "ok", reason: "", rest: bytes.subarray(1) };
  const reason = fromUtf8.decode(bytes.subarray(1));
  return { status: REFUSALS[code - 1] ?? "failed", reason: REFUSALS[code - 1] ? reason : `status ${code}${reason ? ": " + reason : ""}`, rest: EMPTY };
}

/** What zsp.services lists, after its status. */
export function readServices(bytes: Uint8Array): Service[] {
  const r = codec.reader(bytes);
  const out: Service[] = [];
  while (r.pos < r.len) {
    const kind = codec.u8(r);
    if (kind === 1) {
      const flags = codec.u8(r);
      out.push({ kind: "shell", terminal: (flags & 1) !== 0, commands: (flags & 2) !== 0 });
    } else if (kind === 2) {
      const flags = codec.u8(r);
      out.push({ kind: "files", name: fromUtf8.decode(codec.bytes(r)), read: (flags & 1) !== 0, write: (flags & 2) !== 0 });
    } else if (kind === 3) {
      const port = (codec.u8(r) << 8) | codec.u8(r);
      const host = fromUtf8.decode(codec.bytes(r));
      out.push({ kind: "tcp", port, host, name: fromUtf8.decode(codec.bytes(r)) });
    } else throw new codec.Malformed("a service of no kind known"); // whose length cannot be told, nor what follows it
  }
  return out;
}

/** Entries of a folder, as zsp.list says them in its messages. */
export function readEntries(bytes: Uint8Array): Entry[] {
  const r = codec.reader(bytes);
  const out: Entry[] = [];
  while (r.pos < r.len) {
    const kind = KINDS[codec.u8(r) - 1] ?? "other";
    const name = fromUtf8.decode(codec.bytes(r));
    out.push({ name, kind, size: codec.varint(r), modified: codec.varint(r) });
  }
  return out;
}

/** zsp.get's answer, after its status: the file's size, time and identity there, and where it begins. */
export function readGot(bytes: Uint8Array): { size: number; modified: number; identity: Uint8Array; from: number } {
  const r = codec.reader(bytes);
  const size = codec.varint(r);
  const modified = codec.varint(r);
  const identity = codec.bytes(r).slice();
  return { size, modified, identity, from: codec.varint(r) };
}

/** zsp.put's, after its status: where to begin. */
export function readFrom(bytes: Uint8Array): number {
  return codec.varint(codec.reader(bytes));
}

/** A message from a process: its output, its errors, or how it ended. */
export function readOutput(bytes: Uint8Array): { kind: "output" | "errors"; data: Uint8Array } | { kind: "exit"; exit: Exit } | undefined {
  if (bytes[0] === 1 || bytes[0] === 2) return { kind: bytes[0] === 1 ? "output" : "errors", data: bytes.subarray(1) };
  if (bytes[0] !== 3) return undefined;
  const r = codec.reader(bytes);
  r.pos = 1;
  const code = codec.varint(r);
  return { kind: "exit", exit: { code, signal: codec.u8(r) } };
}

// ---------------------------------------------------------------- hashing

/** A file hashed as §16 says: each chunk of a MiB by SHA-256, and the file by SHA-256 of its chunks' hashes in order. */
export class Hashing {
  #chunk = new Sha256();
  #file = new Sha256();
  /** Bytes of the chunk under way. */
  filled = 0;

  /** Takes bytes, as many as there are before the chunk under way ends; says how many, and whether it ended. */
  feed(bytes: Uint8Array): { taken: number; ended: boolean } {
    const taken = Math.min(bytes.length, CHUNK - this.filled);
    this.#chunk.update(bytes.subarray(0, taken));
    this.filled += taken;
    return { taken, ended: this.filled === CHUNK };
  }

  /** Ends the chunk under way: its hash, which goes into the file's. */
  chunk(): Uint8Array {
    const hash = this.#chunk.digest();
    this.#file.update(hash);
    this.#chunk = new Sha256();
    this.filled = 0;
    return hash;
  }

  /** A chunk's hash, known from before, into the file's. */
  known(hash: Uint8Array): void {
    this.#file.update(hash);
  }

  /** The file's, once every chunk has ended. */
  file(): Uint8Array {
    return this.#file.digest();
  }
}

function equal(a: Uint8Array, b: Uint8Array | undefined): boolean {
  return b !== undefined && a.length === b.length && a.every((x, i) => x === b[i]);
}

function concat(parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let at = 0;
  for (const p of parts) out.set(p, at), (at += p.length);
  return out;
}

const bytesOf = (data: Uint8Array | string): Uint8Array => (typeof data === "string" ? utf8.encode(data) : data);

// ---------------------------------------------------------------- what is outstanding

interface Deferred<T> {
  promise: Promise<T>;
  resolve: (value: T) => void;
  reject: (error: Error) => void;
  settled: boolean;
}

// A promise and its ends. A failure nobody waits for is nobody's to hear of: whoever awaits it hears, and nothing else does.
function deferred<T>(): Deferred<T> {
  const d = { settled: false } as Deferred<T>;
  d.promise = new Promise<T>((resolve, reject) => {
    d.resolve = (v) => {
      if (!d.settled) (d.settled = true), resolve(v);
    };
    d.reject = (e) => {
      if (!d.settled) (d.settled = true), reject(e);
    };
  });
  d.promise.catch(() => {});
  return d;
}

/** Bytes that come, to be read. Each is held against its sender's credit until it is taken. */
export interface Reading extends AsyncIterable<Uint8Array> {
  /** The next bytes, once they come; undefined once there will be no more. Rejects if they were cut off. */
  read(): Promise<Uint8Array | undefined>;
  /** Bytes come and not yet taken. */
  readonly buffered: number;
}

type Listener = (data: Uint8Array) => boolean | void;

// What came and is not yet taken: read, or told to a listener as it comes. A listener that returns false keeps it from
// the sender's credit until its owner says it is consumed.
class Inbox implements Reading {
  #queue: { data: Uint8Array; cost: number }[] = [];
  #buffered = 0;
  #over = false;
  #error?: Error;
  #readers: Deferred<Uint8Array | undefined>[] = [];
  #listener?: Listener;
  #credit: (n: number) => void;

  constructor(credit: (n: number) => void) {
    this.#credit = credit;
  }

  get buffered(): number {
    return this.#buffered;
  }

  get listener(): Listener | undefined {
    return this.#listener;
  }

  // Bytes that came, costing so much credit: their message, tag and all.
  push(data: Uint8Array, cost: number): void {
    if (this.#listener) {
      if (this.#listener(data) !== false) this.#credit(cost);
      else this.#credit(cost - data.length); // only what the listener keeps is kept
    } else if (this.#readers.length > 0) {
      this.#readers.shift()!.resolve(data);
      this.#credit(cost);
    } else {
      this.#queue.push({ data, cost });
      this.#buffered += data.length;
    }
  }

  end(): void {
    this.#over = true;
    for (const r of this.#readers.splice(0)) r.resolve(undefined);
  }

  fail(error: Error): void {
    if (this.#over) return;
    this.#over = true;
    this.#error = error;
    for (const r of this.#readers.splice(0)) r.reject(error);
  }

  listen(f: Listener | undefined): void {
    this.#listener = f;
    while (this.#listener && this.#queue.length > 0) {
      const { data, cost } = this.#queue.shift()!;
      this.#buffered -= data.length;
      this.push(data, cost);
    }
  }

  read(): Promise<Uint8Array | undefined> {
    const next = this.#queue.shift();
    if (next) {
      this.#buffered -= next.data.length;
      this.#credit(next.cost);
      return Promise.resolve(next.data);
    }
    if (this.#error) return Promise.reject(this.#error);
    if (this.#over) return Promise.resolve(undefined);
    const d = deferred<Uint8Array | undefined>();
    this.#readers.push(d);
    return d.promise;
  }

  [Symbol.asyncIterator](): AsyncIterator<Uint8Array> {
    return {
      next: async () => {
        const value = await this.read();
        return value === undefined ? { done: true, value: undefined } : { done: false, value };
      },
    };
  }
}

// What is to be sent, each message going only once the other side has room for it, so that a writer who waits for its
// writes holds nothing more than one of them here.
class Outbox {
  #call: Call;
  #queue: { bytes: Uint8Array; done: (sent: boolean) => void }[] = [];
  #queued = 0;
  #finishing = false;
  #over = false;
  #finished?: () => void;

  constructor(call: Call) {
    this.#call = call;
  }

  get queued(): number {
    return this.#queued;
  }

  get open(): boolean {
    return !this.#over && !this.#finishing;
  }

  send(bytes: Uint8Array): Promise<boolean> {
    if (!this.open) return Promise.resolve(false);
    return new Promise((done) => {
      this.#queue.push({ bytes, done });
      this.#queued += bytes.length;
      this.pump();
    });
  }

  pump(): void {
    while (!this.#over && this.#queue.length > 0 && this.#call.room >= this.#queue[0].bytes.length) {
      const m = this.#queue.shift()!;
      this.#queued -= m.bytes.length;
      this.#call.send(m.bytes);
      m.done(true);
    }
    if (this.#finishing && !this.#over && this.#queue.length === 0) {
      this.#over = true;
      this.#call.finish();
      this.#finished?.();
    }
  }

  // No more: the call is told once what waits has gone, and then `finished`.
  finish(finished?: () => void): void {
    if (!this.open) return;
    this.#finishing = true;
    this.#finished = finished;
    this.pump();
  }

  // Over: what waits will never go.
  drop(): void {
    this.#over = true;
    for (const m of this.#queue.splice(0)) m.done(false);
    this.#queued = 0;
  }
}

// Bytes in messages no longer than a piece, each made by `wrap`.
function pieces(data: Uint8Array, wrap: (piece: Uint8Array) => Uint8Array): Uint8Array[] {
  const out: Uint8Array[] = [];
  for (let at = 0; at < data.length; at += PIECE) out.push(wrap(data.subarray(at, at + PIECE)));
  return out;
}

// ---------------------------------------------------------------- processes

/** Of a process or a terminal. */
export interface Started {
  /** Environment entries over the device's own: a value, or null to remove one. */
  env?: Environment;
  /** Where to start: the user's home there unless said. */
  cwd?: string;
}

export type ExecOptions = Started;

export interface TerminalOptions extends Started {
  rows?: number;
  cols?: number;
  /** What kind of terminal it is, as TERM says: xterm-256color unless said. */
  term?: string;
}

// A process run on a device, and what is said with it: status, then tagged messages each way, as host/exec.odin says.
class Running {
  protected readonly call: Call;
  readonly #started = deferred<void>();
  readonly #exit = deferred<Exit>();
  protected readonly out: Inbox;
  protected readonly err: Inbox;
  protected readonly outbox: Outbox;
  #begun = false;
  #exited = false;
  #failed = false;
  /** Told how it ended, once it has. */
  onExit?: (exit: Exit) => void;

  constructor(call: Call, merged: boolean) {
    this.call = call;
    const credit = (n: number) => call.consumed(n);
    this.out = new Inbox(credit);
    this.err = merged ? this.out : new Inbox(credit);
    this.outbox = new Outbox(call);
    call.ondata = (d) => this.#take(d);
    call.onend = () => this.#ended();
    call.onfault = (f) => this.#fail(ServiceError.of(f));
    call.onroom = () => this.outbox.pump();
  }

  /** Resolves once the device has started it; rejects, with a ServiceError, if it did not. */
  get started(): Promise<void> {
    return this.#started.promise;
  }

  /** Resolves with how it ended; rejects if it was not started, or the call failed first. */
  get exit(): Promise<Exit> {
    return this.#exit.promise;
  }

  /** What it says, to be read; what is not taken holds it up, once as much as the call's window is waiting. */
  get output(): Reading {
    return this.out;
  }

  /**
   * Told what it says as it comes, instead of its being read. Return false to keep it from the device's credit until
   * consumed says it is done with: so a terminal that is slow to draw holds up what it draws.
   */
  get onOutput(): Listener | undefined {
    return this.out.listener;
  }

  set onOutput(f: Listener | undefined) {
    this.out.listen(f);
  }

  /** Says that bytes a listener kept are done with. */
  consumed(n: number): void {
    this.call.consumed(n);
  }

  /** Bytes written and waiting for room to go. */
  get queued(): number {
    return this.outbox.queued;
  }

  /** Gives it input. Resolves once it has gone, as fast as the process takes it; or with false if it never will. */
  write(data: Uint8Array | string): Promise<boolean> {
    const sent = pieces(bytesOf(data), inputMessage).map((m) => this.outbox.send(m));
    return Promise.all(sent).then((all) => all.every(Boolean));
  }

  /** Says a signal to it and all it started, ahead of input that waits. */
  signal(signal: Signal | number): void {
    if (this.outbox.open) this.call.send(signalMessage(signal));
  }

  /** Lets it go at once: it is killed, with all it started, and nothing more is told. */
  cancel(): void {
    this.call.cancel();
    this.#fail(new ServiceError("failed", "cancelled"));
  }

  #take(d: Uint8Array): boolean | void {
    if (!this.#begun) {
      this.#begun = true;
      let s: ReturnType<typeof readStatus>;
      try {
        s = readStatus(d);
      } catch {
        this.call.cancel();
        return this.#fail(new ServiceError("malformed", "the answer makes no sense"));
      }
      if (s.status !== "ok") return this.#fail(new ServiceError(s.status, s.reason));
      this.#started.resolve();
      return;
    }
    let m: ReturnType<typeof readOutput>;
    try {
      m = readOutput(d);
    } catch {
      return; // an exit that does not read is no exit: the call's end says it is over
    }
    if (!m || this.#exited) return;
    if (m.kind === "exit") {
      this.#exited = true;
      this.out.end();
      this.err.end();
      this.#exit.resolve(m.exit);
      this.onExit?.(m.exit);
      return;
    }
    (m.kind === "output" ? this.out : this.err).push(m.data, d.length);
    return false; // the inbox credits it as it is taken
  }

  // They will say no more: neither need this side, whose input, if it waits, the process will never take.
  #ended(): void {
    if (!this.#exited) this.#fail(new ServiceError("failed", "it ended without saying how"));
    this.outbox.drop();
    this.call.finish();
  }

  #fail(e: ServiceError): void {
    if (this.#failed || this.#exited) return;
    this.#failed = true;
    this.#started.reject(e);
    this.#exit.reject(e);
    this.out.fail(e);
    this.err.fail(e);
    this.outbox.drop();
  }
}

/** A command run on a device: its own program and arguments, never a shell's. */
export class Process extends Running {
  constructor(call: Call) {
    super(call, false);
  }

  /** What it says to its errors, to be read as its output is. */
  get errors(): Reading {
    return this.err;
  }

  /** Told what it says to its errors as it comes, as onOutput is told its output. */
  get onErrors(): Listener | undefined {
    return this.err.listener;
  }

  set onErrors(f: Listener | undefined) {
    this.err.listen(f);
  }

  /** No more input: it is told once what was written has gone. Nothing more can be said to it then but cancel. */
  closeInput(): void {
    this.outbox.finish();
  }

  /** Kills it, and all it started: by signal 9, as its exit then says; or, once its input is closed, by cancelling. */
  kill(): void {
    if (this.outbox.open) this.signal("kill");
    else this.cancel();
  }
}

/** A terminal on a device: the user's shell there, as a terminal's, which says everything as output. */
export class Terminal extends Running {
  constructor(call: Call) {
    super(call, true);
  }

  resize(rows: number, cols: number): void {
    if (this.outbox.open) this.call.send(resizeMessage(rows, cols));
  }

  /** Lets it go: the shell, and all it started, killed. */
  close(): void {
    this.cancel();
  }
}

/** What a command said, and how it ended. */
export interface Ran extends Exit {
  readonly stdout: string;
  readonly stderr: string;
}

export interface RunOptions extends ExecOptions {
  /** Its input, all of it; none unless said. */
  input?: Uint8Array | string;
}

export function exec(client: Client, device: string, scope: number, argv: readonly string[], options: ExecOptions = {}): Process {
  return new Process(client.call(device, scope, "zsp.exec", execRequest(argv, options.env, options.cwd)));
}

export async function run(client: Client, device: string, scope: number, argv: readonly string[], options: RunOptions = {}): Promise<Ran> {
  const p = exec(client, device, scope, argv, options);
  const out: Uint8Array[] = [];
  const err: Uint8Array[] = [];
  p.onOutput = (d) => void out.push(d);
  p.onErrors = (d) => void err.push(d);
  if (options.input !== undefined) void p.write(options.input).then(() => p.closeInput());
  else p.closeInput();
  const exit = await p.exit;
  return { code: exit.code, signal: exit.signal, stdout: fromUtf8.decode(concat(out)), stderr: fromUtf8.decode(concat(err)) };
}

export function terminal(client: Client, device: string, scope: number, options: TerminalOptions = {}): Terminal {
  const first = ptyRequest(options.rows ?? 24, options.cols ?? 80, options.term ?? "xterm-256color", options.env, options.cwd);
  return new Terminal(client.call(device, scope, "zsp.pty", first));
}

// ---------------------------------------------------------------- connections

/** A TCP connection made by a device, there or on its network: bytes each way, and each way's end, as a socket's. */
export class Stream implements Reading {
  #call: Call;
  #connected = deferred<void>();
  #closed = deferred<void>();
  #inbox: Inbox;
  #outbox: Outbox;
  #begun = false;
  #theirs = false; // they will send no more
  #mine = false; // nor this side
  /** The other side will send no more: a half-close. */
  onend?: () => void;

  constructor(call: Call) {
    this.#call = call;
    this.#inbox = new Inbox((n) => call.consumed(n));
    this.#outbox = new Outbox(call);
    call.ondata = (d) => this.#take(d);
    call.onend = () => {
      this.#theirs = true;
      if (!this.#begun) this.#fail(new ServiceError("unreachable", "it ended before it said whether it reached the port"));
      if (this.#closed.settled) return call.finish(); // refused, and over but for this side's end
      this.#inbox.end();
      this.onend?.();
      this.#over();
    };
    call.onfault = (f) => this.#fail(ServiceError.of(f));
    call.onroom = () => this.#outbox.pump();
  }

  /** Resolves once the port is reached; rejects, with a ServiceError, if it was not. */
  get connected(): Promise<void> {
    return this.#connected.promise;
  }

  /** Resolves once both ways have ended, or close was said; rejects if it was reset from there, or lost. */
  get closed(): Promise<void> {
    return this.#closed.promise;
  }

  get buffered(): number {
    return this.#inbox.buffered;
  }

  /** Bytes written and waiting for room to go. */
  get queued(): number {
    return this.#outbox.queued;
  }

  read(): Promise<Uint8Array | undefined> {
    return this.#inbox.read();
  }

  [Symbol.asyncIterator](): AsyncIterator<Uint8Array> {
    return this.#inbox[Symbol.asyncIterator]();
  }

  /** Told what comes as it comes, instead of its being read. Return false to keep it from credit until consumed says. */
  get ondata(): Listener | undefined {
    return this.#inbox.listener;
  }

  set ondata(f: Listener | undefined) {
    this.#inbox.listen(f);
  }

  /** Says that bytes a listener kept are done with. */
  consumed(n: number): void {
    this.#call.consumed(n);
  }

  /** Resolves once the bytes have gone, as fast as the far end takes them; or with false if they never will. */
  write(data: Uint8Array | string): Promise<boolean> {
    const sent = pieces(bytesOf(data), (p) => p.slice()).map((m) => this.#outbox.send(m));
    return Promise.all(sent).then((all) => all.every(Boolean));
  }

  /** This side will send no more, once what was written has gone: a half-close. */
  end(): void {
    this.#outbox.finish(() => {
      this.#mine = true;
      this.#over();
    });
  }

  /** Resets it at once, both ways. */
  close(): void {
    if (this.#closed.settled) return;
    this.#call.cancel();
    const e = new ServiceError("failed", "closed");
    this.#connected.reject(e);
    this.#inbox.fail(e);
    this.#outbox.drop();
    this.#closed.resolve();
  }

  #take(d: Uint8Array): boolean | void {
    if (!this.#begun) {
      this.#begun = true;
      let s: ReturnType<typeof readStatus>;
      try {
        s = readStatus(d);
      } catch {
        this.#call.cancel();
        return this.#fail(new ServiceError("malformed", "the answer makes no sense"));
      }
      if (s.status !== "ok") return this.#fail(new ServiceError(s.status, s.reason));
      this.#connected.resolve();
      return;
    }
    if (this.#theirs || d.length === 0) return;
    this.#inbox.push(d, d.length);
    return false; // the inbox credits it as it is taken
  }

  #over(): void {
    if (this.#theirs && this.#mine) this.#closed.resolve();
  }

  #fail(e: ServiceError): void {
    this.#connected.reject(e);
    this.#inbox.fail(e);
    this.#outbox.drop();
    this.#closed.reject(e);
  }
}

export function connect(client: Client, device: string, scope: number, port: number, host = ""): Stream {
  return new Stream(client.call(device, scope, "zsp.tcp", tcpRequest(port, host)));
}

// ---------------------------------------------------------------- asking

// One question, one answer: what follows the status, all of it, once the device has said all it will.
function ask(client: Client, device: string, scope: number, method: string, first: Uint8Array): Promise<Uint8Array> {
  return new Promise((resolve, reject) => {
    const parts: Uint8Array[] = [];
    const call = client.call(device, scope, method, first);
    call.ondata = (d) => void parts.push(d);
    call.onend = () => {
      try {
        const s = readStatus(concat(parts));
        if (s.status === "ok") resolve(s.rest.slice());
        else reject(new ServiceError(s.status, s.reason));
      } catch {
        reject(new ServiceError("malformed", "the answer makes no sense"));
      }
    };
    call.onfault = (f) => reject(ServiceError.of(f));
    call.finish();
  });
}

const sense = <T>(f: () => T): T => {
  try {
    return f();
  } catch (e) {
    if (e instanceof codec.Malformed) throw new ServiceError("malformed", "the answer makes no sense");
    throw e;
  }
};

export async function services(client: Client, device: string, scope: number): Promise<Service[]> {
  const listed = await ask(client, device, scope, "zsp.services", EMPTY);
  return sense(() => readServices(listed));
}

export async function shares(client: Client, device: string, scope: number): Promise<string> {
  return fromUtf8.decode(await ask(client, device, scope, "zsp.share", EMPTY));
}

export async function setShares(client: Client, device: string, scope: number, text: string): Promise<void> {
  await ask(client, device, scope, "zsp.share", utf8.encode(text === "" ? "\n" : text)); // said, as nothing would be asking
}

export async function list(client: Client, device: string, scope: number, path: string): Promise<Entry[]> {
  const listed = await ask(client, device, scope, "zsp.list", listRequest(path));
  return sense(() => readEntries(listed));
}

// ---------------------------------------------------------------- transfers

/** How a file went. */
export interface Transferred {
  /** Of the file. */
  readonly size: number;
  /** Carried this time. */
  readonly bytes: number;
  /** Where it took up from, of what an earlier transfer left. */
  readonly resumed: number;
  /** The file's, by §16's chunks, in hex. */
  readonly hash: string;
  /** When it was last written, in ms since 1970, where it came from. */
  readonly modified: number;
}

export interface TransferOptions {
  /** Where files are kept here, if not where the client keeps them. */
  folder?: Folder;
  /** Gives up when it aborts. What was fetched is kept, to take up from; and so is what was sent, there. */
  signal?: AbortSignal;
  /** Told how much of a file is there or sent, as that grows, and which file by its path on the device. */
  onProgress?: (done: number, size: number, path: string) => void;
}

export interface PutOptions extends TransferOptions {
  /** Replaces a file there by that name: not unless said. */
  replace?: boolean;
  /** Makes the folders on the way there: unless said not to. */
  folders?: boolean;
}

/** A file of a tree, by its path within it, and how it went; undefined if it was there already and passed over. */
export interface TreeFile {
  readonly path: string;
  readonly transferred?: Transferred;
}

async function readWhole(folder: Folder, path: string): Promise<Uint8Array | undefined> {
  const f = await folder.open(path, false);
  if (!f) return undefined;
  try {
    const out = new Uint8Array((await f.info()).size);
    return out.subarray(0, await f.read(out, 0));
  } finally {
    await f.close();
  }
}

// How many of a part's first chunks are what their hashes say, read again here: what was checked as it came may have
// been changed since, and nothing is taken up from that it does not still prove.
async function goodChunks(f: OpenFile, hashes: Uint8Array): Promise<number> {
  const buf = new Uint8Array(FILE_READ);
  for (let i = 0; i < hashes.length / 32; i++) {
    const h = new Sha256();
    for (let at = 0; at < CHUNK; at += FILE_READ) {
      if ((await f.read(buf, i * CHUNK + at)) !== FILE_READ) return i;
      h.update(buf);
    }
    if (!equal(h.digest(), hashes.subarray(i * 32, i * 32 + 32))) return i;
  }
  return hashes.length / 32;
}

const failure = (e: unknown, why: string): ServiceError => (e instanceof ServiceError ? e : new ServiceError("failed", `${why}: ${e instanceof Error ? e.message : e}`));

// A transfer's messages, taken one at a time and in order, each credited once it is done with: written to the disk, or
// found to be the end.
abstract class Transfer {
  protected readonly folder: Folder;
  protected readonly options: TransferOptions;
  protected readonly path: string; // on the device
  protected call!: Call;
  protected readonly hashing = new Hashing();
  protected size = 0;
  protected modified = 0;
  protected at = 0;
  protected from = 0;
  protected begun = false;
  protected finished = false;
  readonly #done = deferred<Transferred>();
  #chain: Promise<void> = Promise.resolve();
  #abort = () => {
    this.call.cancel();
    this.queue(() => this.finish(new ServiceError("failed", "cancelled")), 0);
  };

  constructor(folder: Folder, path: string, options: TransferOptions) {
    this.folder = folder;
    this.path = path;
    this.options = options;
  }

  begin(call: Call): Promise<Transferred> {
    this.call = call;
    call.ondata = (d) => {
      this.queue(() => this.take(d), d.length);
      return false;
    };
    call.onend = () => this.queue(() => this.finish(new ServiceError("failed", "it ended early")), 0);
    call.onfault = (f) => this.queue(() => this.finish(ServiceError.of(f)), 0);
    const signal = this.options.signal;
    if (signal?.aborted) this.#abort();
    else signal?.addEventListener("abort", this.#abort, { once: true });
    return this.#done.promise;
  }

  protected queue(step: () => Promise<void>, n: number): void {
    this.#chain = this.#chain.then(async () => {
      try {
        if (!this.finished) await step();
      } catch (e) {
        this.call.cancel();
        await this.finish(failure(e, "here"));
      }
      if (n > 0) this.call.consumed(n);
    });
  }

  protected abstract take(d: Uint8Array): Promise<void>;
  protected abstract let(): Promise<void>; // lets go of the files

  protected progress(): void {
    this.options.onProgress?.(this.at, this.size, this.path);
  }

  // How it went: told once, the files let go of first.
  protected async finish(outcome: Transferred | ServiceError): Promise<void> {
    if (this.finished) return;
    this.finished = true;
    this.options.signal?.removeEventListener("abort", this.#abort);
    try {
      await this.let();
    } catch (e) {
      if (!(outcome instanceof ServiceError)) outcome = failure(e, "the file could not be let go of");
    }
    if (outcome instanceof ServiceError) this.#done.reject(outcome);
    else this.#done.resolve(outcome);
  }

  protected result(hash: Uint8Array): Transferred {
    return { size: this.size, bytes: this.at - this.from, resumed: this.from, hash: codec.hex(hash), modified: this.modified };
  }
}

// A file fetched: kept as a part, with the hashes of its chunks beside it, until it is whole and put in place.
class Fetch extends Transfer {
  readonly #local: string;
  readonly #part: string;
  readonly #meta: string;
  readonly #expected: number; // where it asked to take up from
  #f?: OpenFile;
  #record?: OpenFile;
  #recorded = 0; // the record's length
  #pending?: Uint8Array; // the hash of the chunk just ended, awaiting the sender's
  #awaiting = false;

  constructor(folder: Folder, remote: string, local: string, expected: number, options: TransferOptions) {
    super(folder, remote, options);
    this.#local = local;
    this.#part = local + PART;
    this.#meta = this.#part + META;
    this.#expected = expected;
  }

  protected async take(d: Uint8Array): Promise<void> {
    if (d.length === 0) return;
    if (!this.begun) {
      this.begun = true;
      const s = readStatus(d);
      if (s.status !== "ok") {
        this.call.finish();
        return this.finish(new ServiceError(s.status, s.reason));
      }
      const got = sense(() => readGot(s.rest));
      if (got.from > got.size || got.from % CHUNK !== 0 || (got.from !== 0 && got.from !== this.#expected)) return this.#fail("malformed");
      this.size = got.size;
      this.modified = got.modified;
      try {
        await this.#open(got.identity, got.from);
      } catch (e) {
        this.call.cancel();
        return this.finish(failure(e, "cannot write the file"));
      }
      return this.progress();
    }
    const payload = d.subarray(1);
    switch (d[0]) {
      case 1: {
        if (this.#awaiting || this.at + payload.length > this.size) return this.#fail("malformed");
        let rest = payload;
        while (rest.length > 0) {
          const { taken, ended } = this.hashing.feed(rest);
          await this.#f!.write(rest.subarray(0, taken), this.at);
          this.at += taken;
          rest = rest.subarray(taken);
          if (ended || this.at === this.size) {
            this.#pending = this.hashing.chunk();
            this.#awaiting = true;
            if (rest.length > 0) return this.#fail("malformed"); // a chunk's hash comes between its bytes and the next chunk's
          }
        }
        return this.progress();
      }
      case 2:
        if (!this.#awaiting || !equal(payload, this.#pending)) return this.#fail("changed");
        this.#awaiting = false;
        await this.#record!.write(payload, this.#recorded); // taken, and known good
        this.#recorded += 32;
        return;
      case 3: {
        if (payload.length < 1 || payload[0] !== 0) return this.#fail(payload.length > 0 ? (REFUSALS[payload[0] - 1] ?? "failed") : "malformed");
        if (this.#awaiting || this.at !== this.size) return this.#fail("malformed");
        const hash = this.hashing.file();
        // From the start, the file's hash comes and must agree; taken up later, every chunk's has, kept or come.
        if ((this.from === 0 && payload.length !== 33) || (payload.length === 33 && !equal(payload.subarray(1), hash))) return this.#fail("changed");
        return this.#commit(hash);
      }
      default:
        return this.#fail("malformed");
    }
  }

  // The part, taken up where it was if the file there is the one it was, or begun afresh.
  async #open(identity: Uint8Array, from: number): Promise<void> {
    const f = (this.#f = (await this.folder.open(this.#part, true))!);
    if (from === 0) {
      await f.truncate(0);
      const record = (this.#record = (await this.folder.open(this.#meta, true))!);
      await record.truncate(0);
      const w = codec.writer();
      codec.putBytes(w, identity);
      await record.write(codec.written(w), 0);
      this.#recorded = w.pos;
    } else {
      const kept = await readWhole(this.folder, this.#meta);
      if (!kept) throw new Error("what was taken before is not on record");
      const r = codec.reader(kept);
      codec.bytes(r);
      const chunks = from / CHUNK;
      if (kept.length < r.pos + chunks * 32) throw new Error("what was taken before is not on record");
      for (let i = 0; i < chunks; i++) this.hashing.known(kept.subarray(r.pos + i * 32, r.pos + i * 32 + 32));
      this.#record = (await this.folder.open(this.#meta, true))!;
      this.#recorded = r.pos + chunks * 32;
      await this.#record.truncate(this.#recorded);
      await f.truncate(from);
    }
    this.from = this.at = from;
  }

  // Whole and checked: made durable, given the sender's time, put in place, its record let go of.
  async #commit(hash: Uint8Array): Promise<void> {
    const f = this.#f!;
    this.#f = undefined;
    await f.flush();
    await f.close();
    const record = this.#record!;
    this.#record = undefined;
    await record.close();
    await this.folder.setModified(this.#part, this.modified);
    try {
      await this.folder.rename(this.#part, this.#local);
    } catch (e) {
      return this.finish(failure(e, "cannot put the file in place"));
    }
    await this.folder.remove(this.#meta);
    this.call.finish();
    return this.finish(this.result(hash));
  }

  // Failed here: what came cannot be trusted to take up from, if it changed or made no sense.
  async #fail(status: Refusal): Promise<void> {
    if ((status === "changed" || status === "malformed") && this.#record) await this.#record.truncate(0);
    this.call.cancel();
    return this.finish(new ServiceError(status));
  }

  // What came is kept, made durable, to take up from.
  protected async let(): Promise<void> {
    const f = this.#f, record = this.#record;
    this.#f = this.#record = undefined;
    if (f) await f.flush(), await f.close();
    if (record) await record.flush(), await record.close();
  }
}

// A file sent: as much as there is room for, each chunk followed by its hash, then the end; and then the verdict.
class Send extends Transfer {
  readonly #f: OpenFile;
  readonly #info: FileInfo;
  #ready = false; // the file's hash has what the other side had already
  #pumping = false;
  #sentAll = false;
  #hash?: Uint8Array; // the file's, once all is sent
  #closed = false;

  constructor(folder: Folder, remote: string, f: OpenFile, info: FileInfo, options: TransferOptions) {
    super(folder, remote, options);
    this.#f = f;
    this.#info = info;
    this.size = info.size;
    this.modified = info.modified;
  }

  override begin(call: Call): Promise<Transferred> {
    call.onroom = () => void this.#pump();
    return super.begin(call);
  }

  protected async take(d: Uint8Array): Promise<void> {
    if (d.length === 0) return;
    if (!this.begun) {
      this.begun = true;
      const s = readStatus(d);
      if (s.status !== "ok") {
        this.call.finish();
        return this.finish(new ServiceError(s.status, s.reason));
      }
      const from = sense(() => readFrom(s.rest));
      if (from % CHUNK !== 0 || from > this.size) {
        this.call.cancel();
        return this.finish(new ServiceError("malformed"));
      }
      // What the other end has, it has checked; its hashes, here, are made again, for the file's.
      const buf = new Uint8Array(FILE_READ);
      for (let at = 0; at < from; ) {
        const n = Math.min(FILE_READ, from - at, CHUNK - this.hashing.filled);
        if ((await this.#f.read(buf.subarray(0, n), at)) !== n) {
          this.call.cancel();
          return this.finish(new ServiceError("failed", "cannot read the file"));
        }
        if (this.hashing.feed(buf.subarray(0, n)).ended) this.hashing.chunk();
        at += n;
      }
      this.from = this.at = from;
      this.#ready = true;
      this.progress();
      void this.#pump();
      return;
    }
    // The verdict: once all is sent, or before, if it failed there.
    const s = readStatus(d);
    if (!this.#sentAll) this.call.finish();
    if (s.status !== "ok" || !this.#sentAll) return this.finish(new ServiceError(s.status === "ok" ? "malformed" : s.status, s.reason));
    return this.finish(this.result(this.#hash!));
  }

  // Sends as much of the file as there is room for; then the end.
  async #pump(): Promise<void> {
    if (!this.#ready || this.finished || this.#sentAll || this.#pumping) return;
    this.#pumping = true;
    try {
      for (;;) {
        // Credit for what follows the last bytes is kept back from them, so that it can always go when they have.
        const room = this.call.room;
        if (this.finished || room < (this.at < this.size ? 1 + 1 + TRAIL : TRAIL)) return; // onroom says when to go on
        if (this.at < this.size) {
          const n = Math.min(room - 1 - TRAIL, FILE_READ, this.size - this.at, CHUNK - this.hashing.filled);
          const buf = new Uint8Array(1 + n);
          const got = await this.#f.read(buf.subarray(1), this.at);
          if (this.finished) return;
          if (got === 0) {
            this.call.cancel();
            await this.finish(new ServiceError("changed", "it shrank here"));
            return;
          }
          buf[0] = 1;
          this.call.send(buf.subarray(0, 1 + got));
          this.hashing.feed(buf.subarray(1, 1 + got));
          this.at += got;
          this.progress();
          if (this.hashing.filled < CHUNK && this.at < this.size) continue;
        }
        if (this.hashing.filled > 0) this.call.send(chunkMessage(this.hashing.chunk()));
        if (this.at === this.size) {
          // Still the file it was, all the while?
          const now = await this.#f.info();
          if (this.finished) return;
          this.#hash = this.hashing.file();
          this.call.send(endMessage(equal(now.identity, this.#info.identity) ? "ok" : "changed", this.#hash));
          this.#sentAll = true;
          this.call.finish();
          return;
        }
      }
    } catch (e) {
      this.call.cancel();
      await this.finish(failure(e, "cannot read the file"));
    } finally {
      this.#pumping = false;
    }
  }

  protected async let(): Promise<void> {
    if (this.#closed) return;
    this.#closed = true;
    await this.#f.close();
  }
}

function folderOf(options: TransferOptions): Folder {
  if (!options.folder) throw new Error("no folder to keep files in: give the client one, or the transfer");
  return options.folder;
}

export async function get(client: Client, device: string, scope: number, remote: string, local: string, options: TransferOptions = {}): Promise<Transferred> {
  const folder = folderOf(options);
  // What was taken before, if anything was, and is still what its record says.
  let known: Uint8Array | undefined;
  let from = 0;
  const kept = await readWhole(folder, local + PART + META);
  if (kept) {
    try {
      const r = codec.reader(kept);
      const identity = codec.bytes(r).slice();
      const chunks = Math.floor((kept.length - r.pos) / 32);
      const part = await folder.info(local + PART);
      const f = part?.kind === "file" && chunks * CHUNK <= part.size ? await folder.open(local + PART, false) : undefined;
      if (f) {
        try {
          from = (await goodChunks(f, kept.subarray(r.pos, r.pos + chunks * 32))) * CHUNK;
        } finally {
          await f.close();
        }
        known = identity;
      }
    } catch (e) {
      if (!(e instanceof codec.Malformed)) throw e;
    }
  }
  const fetch = new Fetch(folder, remote, local, from, options);
  return fetch.begin(client.call(device, scope, "zsp.get", getRequest(remote, known ? from : 0, known ?? EMPTY)));
}

export async function put(client: Client, device: string, scope: number, local: string, remote: string, options: PutOptions = {}): Promise<Transferred> {
  const folder = folderOf(options);
  const f = await folder.open(local, false);
  if (!f) throw new ServiceError("not found", `no file ${local} here`);
  const info = await f.info();
  if (info.kind !== "file") {
    await f.close();
    throw new ServiceError("not found", `${local} is no file`);
  }
  const send = new Send(folder, remote, f, info, options);
  const first = putRequest(remote, info.size, info.modified, info.identity, { replace: options.replace, folders: options.folders ?? true });
  return send.begin(client.call(device, scope, "zsp.put", first));
}

const within = (base: string, rel: string, separators: RegExp): string => (rel === "" ? base : base === "" ? rel : base.replace(separators, "") + "/" + rel);
const there = (base: string, rel: string) => within(base, rel, /\/+$/);
const here = (base: string, rel: string) => within(base, rel, /[\\/]+$/);
const isPart = (name: string) => name.endsWith(PART) || name.endsWith(PART + META);

function stopped(options: TransferOptions): void {
  if (options.signal?.aborted) throw new ServiceError("failed", "cancelled");
}

/**
 * Fetches a folder and all in it, a file at a time. A file here already, of the size and time listed there, is taken to be
 * it and passed over, and a file fetched before in part is taken up where it stopped: so a tree fetched again after a
 * break carries only the rest. Times need a folder that keeps them, as a browser's does not.
 */
export async function getTree(client: Client, device: string, scope: number, remote: string, local: string, options: TransferOptions = {}): Promise<TreeFile[]> {
  const folder = folderOf(options);
  const out: TreeFile[] = [];
  const walk = async (rel: string, depth: number): Promise<void> => {
    await folder.make(here(local, rel));
    for (const e of await list(client, device, scope, there(remote, rel))) {
      stopped(options);
      // A name is one name, within the folder it is in: nothing that leads out of it, nor any deeper than a folder
      // can sensibly be.
      if (!nameSound(e.name) || depth >= MAX_DEPTH) throw new ServiceError("malformed", "the listing makes no sense: " + e.name);
      const path = rel === "" ? e.name : rel + "/" + e.name;
      if (e.kind === "folder") await walk(path, depth + 1);
      if (e.kind !== "file" || isPart(e.name)) continue;
      const mine = await folder.info(here(local, path));
      if (mine?.kind === "file" && mine.size === e.size && mine.modified === e.modified) out.push({ path });
      else out.push({ path, transferred: await get(client, device, scope, there(remote, path), here(local, path), options) });
    }
  };
  await walk("", 0);
  return out;
}

/** How deep a folder is fetched, at most. */
const MAX_DEPTH = 64;

/** Whether a listed name is one name: not one that would lead elsewhere, on any system, were it joined to a path. */
function nameSound(name: string): boolean {
  return name !== "" && name !== "." && name !== ".." && !/[/\\:\0]/.test(name);
}

/**
 * Sends a folder and all the files in it, a file at a time, making the folders they are in there; but not folders with
 * no files in, which no message makes. A file there already, of the size and time it has here, is passed over, and one
 * sent before in part is taken up where it stopped.
 */
export async function putTree(client: Client, device: string, scope: number, local: string, remote: string, options: PutOptions = {}): Promise<TreeFile[]> {
  const folder = folderOf(options);
  const out: TreeFile[] = [];
  const walk = async (rel: string): Promise<void> => {
    const theirs = new Map<string, Entry>();
    try {
      for (const e of await list(client, device, scope, there(remote, rel))) theirs.set(e.name, e);
    } catch (e) {
      if (!(e instanceof ServiceError && e.status === "not found")) throw e; // and if it is not there, nothing in it is
    }
    for (const e of await folder.list(here(local, rel))) {
      stopped(options);
      const path = rel === "" ? e.name : rel + "/" + e.name;
      if (e.kind === "folder") await walk(path);
      if (e.kind !== "file" || isPart(e.name)) continue;
      const t = theirs.get(e.name);
      if (t?.kind === "file" && t.size === e.size && t.modified === e.modified) out.push({ path });
      else out.push({ path, transferred: await put(client, device, scope, here(local, path), there(remote, path), options) });
    }
  };
  await walk("");
  return out;
}
