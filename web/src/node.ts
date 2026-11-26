// A device's node, which is ../wasm compiled to WebAssembly, with the device's key and store. This file is plumbing between
// the node and the platform: files, WebSockets, a clock and entropy go in; bytes to send, and when next to wake, come out.
// Nothing runs unless something happened: an idle device sets no timer but the one that pings its relays.

import { Store } from "./store.ts";
import type { Volume } from "./volume.ts";

/** A pipe to a node: what a client sends and is sent. */
export interface Wire {
  send(data: Uint8Array): void;
  close(): void;
}

/** A pipe whose other end is elsewhere, which says itself when it has taken what was sent it. */
export interface FarWire extends Wire {
  /** So many bytes of what was received have been dealt with: the node may send that much more. */
  credit(bytes: number): void;
}

/** Opens a pipe: `receive` is called for every message and `closed` once. */
export type Connect = (receive: (data: Uint8Array) => void, closed: () => void) => Wire | undefined;

export type Level = "debug" | "info" | "warning" | "error";

export interface NodeOptions {
  /** Where it keeps what it holds. */
  volume: Volume;
  /** The node, compiled: see ./wasm.ts for where it comes from. */
  module: WebAssembly.Module;
  /** Replicate everything, rather than what clients here watch and ask about: the default, as for zspd. */
  full?: boolean;
  /** Presented to relays, whose hosts decide by it whom they serve. */
  credential?: string | Uint8Array;
  /** By default the platform's own. */
  WebSocket?: typeof WebSocket;
  /**
   * Milliseconds a connection to a relay may be quiet before it is pinged, 45,000, and then has to answer, 15,000: for
   * networks that forget sooner.
   */
  keepalive?: { idle: number; wait: number };
  log?: (level: Level, text: string) => void;
}

interface Exports {
  memory: WebAssembly.Memory;
  buffer(size: number): number;
  data(): number;
  identity(secret: number, into: number): void;
  start(full: number): number;
  member(): number;
  adopt(size: number): number;
  relay(size: number): void;
  stop(): void;
  client(): number;
  input(id: number, size: number): void;
  heard(id: number): void;
  opened(id: number): void;
  closed(id: number): void;
  tick(): number;
  keepalive(idle: number, wait: number): void;
  segment(): number;
  create(): number;
  govern(op: number, size: number): number;
  members(): number;
}

/** What a device may be granted in a scope, beyond reading, which every grant includes. */
export interface Rights {
  write?: boolean;
  call?: boolean;
  /** To be believed about for whom it writes and calls. */
  vouch?: boolean;
}

/** A member of the space, as its roster says. */
export interface Member {
  /** Its key, as `key` gives it: device and signer. */
  readonly key: string;
  readonly id: string;
  readonly owner: boolean;
  readonly admin: boolean;
  /** Whether anything is in force for it. */
  readonly active: boolean;
  /** Whose it is. */
  readonly subject: string;
  /** Its rights in force, by scope. */
  readonly grants: ReadonlyMap<number, Required<Rights> & { read: boolean }>;
}

const GOVERN = { scope: 1, admit: 2, revoke: 3, subject: 4, admin: 5, owner: 6, relay: 7 } as const;
const REFUSED: Record<number, string> = {
  [-1]: "this device is of no space yet",
  [-2]: "no such member, or no sense",
  [-3]: "this device is not an admin of the space",
  [-4]: "only an owner can do that, or an admin who may read every scope",
  [-5]: "that would make an unsound roster: only signed scopes may have readers who do not write",
  [-6]: "the roster was not taken",
};

const HIGH = 256 << 10; // bytes in flight to a pipe before the node waits for it
const PIECE = 64 << 10; // of what a client says, handed to the node at a time
const DRAIN_POLL = 4; // ms between looks at a WebSocket's backlog, while it has one: nothing says when it drains
const LEVELS: Level[] = ["debug", "info", "warning", "error", "error"];

const hex = (bytes: Uint8Array): string => Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
const unhex = (s: string): Uint8Array => Uint8Array.from(s.match(/../g) ?? [], (b) => parseInt(b, 16));
const utf8 = new TextEncoder();

type Conn =
  | { kind: "client"; receive: (data: Uint8Array) => void; closed: () => void; inflight: number; open: boolean; far: boolean }
  | { kind: "socket"; ws: WebSocket };

/** Where a relay keeps a space: its base URL with the space after it, a query the relay's proxy wants staying at the end. */
export function spaceUrl(url: string, space: string): string {
  const q = url.indexOf("?");
  const [base, query] = q >= 0 ? [url.slice(0, q), url.slice(q)] : [url, ""];
  return base.replace(/\/+$/, "") + "/" + space + query;
}

export class Node {
  #id = "";
  #key = "";
  #store!: Store;
  #options: NodeOptions;
  #secret!: Uint8Array;
  #wasm?: Exports;
  #instance?: WebAssembly.Instance;
  #conns = new Map<number, Conn>();
  #space?: string;
  #scheduled = false;
  #timer?: ReturnType<typeof setTimeout>;
  #draining?: ReturnType<typeof setTimeout>;
  #deliveries: [Conn & { kind: "client" }, Uint8Array][] = [];
  #ticking = false;
  #stopped = false;
  #failure?: Error;
  #waiting: (() => void)[] = [];
  /** Told once if the node stops of itself: storage has failed, and nothing more can be made durable. */
  onFailure?: (error: Error) => void;

  private constructor(options: NodeOptions) {
    this.#options = options;
    const wasm = this.#instantiate();
    if (options.keepalive) wasm.keepalive(options.keepalive.idle, options.keepalive.wait);
  }

  /** Opens the device kept in a volume, making it if there is none; and its node, if it belongs to a space. */
  static async open(options: NodeOptions): Promise<Node> {
    const d = new Node(options);
    const wasm = d.#wasm!;
    const store = (d.#store = await Store.open(options.volume, wasm.segment()));
    let secret = store.kept("device").latest;
    if (secret?.length !== 32) {
      secret = crypto.getRandomValues(new Uint8Array(32));
      store.keep("device", secret);
    }
    d.#secret = secret;
    const at = wasm.buffer(96);
    d.#bytes(at, 32).set(secret);
    wasm.identity(at, at + 32);
    const identity = d.#bytes(at + 32, 64).slice();
    d.#id = hex(identity.subarray(0, 32));
    d.#key = hex(identity);
    store.onSettled = () => d.#kick();
    const space = store.kept("space").latest;
    if (space && space.length >= 32) d.#start(space);
    return d;
  }

  /** This device's key, which peers know it by. */
  get id(): string {
    return this.#id;
  }

  /** What an admin needs to admit it: its key and its signer's. */
  get key(): string {
    return this.#key;
  }

  /** Bytes of memory the node has, all of which it may be using. */
  get memory(): number {
    return this.#wasm?.memory.buffer.byteLength ?? 0;
  }

  /** Where it keeps what it holds. */
  get store(): Store {
    return this.#store;
  }

  /** The space this device is of, as 64 hex digits, once it has joined one. */
  get space(): string | undefined {
    return this.#space;
  }

  /** Whether the roster it holds lets it do anything at all. */
  get member(): boolean {
    return this.#wasm !== undefined && this.#space !== undefined && this.#wasm.member() !== 0;
  }

  /**
   * Becomes a device of a space that has admitted it, or will: by a relay, which it then keeps going back to, whatever
   * the roster says of relays. `url` is the relay's, as `zspd relay` is given it, and the space is put after it.
   */
  join(space: string, relay: { key: string; url: string }): void {
    if (this.#space !== undefined) throw new Error("this device is of a space already");
    if (!/^[0-9a-f]{64}$/.test(space) || !/^[0-9a-f]{64}$/.test(relay.key)) throw new Error("a space and a relay's key are 64 hex digits");
    const url = utf8.encode(spaceUrl(relay.url, space));
    const kept = new Uint8Array(64 + url.length);
    kept.set(unhex(space));
    kept.set(unhex(relay.key), 32);
    kept.set(url, 64);
    this.store.keep("space", kept);
    this.#start(kept);
  }

  /** Becomes a device of a space by its roster alone, as `zspd peer` does; for there is no relay, or none yet. */
  adopt(roster: Uint8Array): boolean {
    if (this.#space === undefined) {
      if (roster.length < 38) return false;
      this.store.keep("space", roster.slice(6, 38));
      this.#start(roster.slice(6, 38));
    }
    const wasm = this.#wasm!;
    this.#bytes(wasm.buffer(roster.length), roster.length).set(roster);
    const ok = wasm.adopt(roster.length) !== 0;
    this.#kick();
    return ok;
  }

  /** Makes a space this device owns, as `zspd create` does, and becomes its first device. Returns its name. */
  create(): string {
    if (this.#space !== undefined) throw new Error("this device is of a space already");
    const wasm = this.#wasm!;
    this.#bytes(wasm.buffer(32), 32).set(this.#secret);
    const n = wasm.create();
    if (n < 32) throw new Error("could not make a space");
    const made = this.#bytes(wasm.data(), n).slice();
    this.store.keep("space", made.subarray(0, 32));
    this.#start(made.subarray(0, 32));
    if (!this.adopt(made.subarray(32))) throw new Error("could not take the space's first roster");
    return this.#space!;
  }

  /** Adds a scope, signed or not: what one key opens. Returns its number. */
  scope(signed = false): number {
    return this.#govern(GOVERN.scope, Uint8Array.of(signed ? 1 : 0));
  }

  /** Lets a device, by the key it says, read a scope, and unless said otherwise write and call there. */
  admit(key: string, scope: number, rights: Rights = { write: true, call: true }): void {
    const b = new Uint8Array(69);
    b.set(Node.#parseKey(key, 64));
    new DataView(b.buffer).setUint32(64, scope, true);
    b[68] = 1 | (rights.write ? 2 : 0) | (rights.call ? 4 : 0) | (rights.vouch ? 8 : 0);
    this.#govern(GOVERN.admit, b);
  }

  /** Ends a device's grants, by its key or id, in a scope or every scope; the scope's key changes, so that it can read nothing written after. */
  revoke(key: string, scope = 0): void {
    const b = new Uint8Array(36);
    b.set(Node.#device(key));
    new DataView(b.buffer).setUint32(32, scope, true);
    this.#govern(GOVERN.revoke, b);
  }

  /** Says whose a device is, by its key or id: an account, a name, as you know them. */
  subject(key: string, subject: string): void {
    const name = utf8.encode(subject);
    const b = new Uint8Array(32 + name.length);
    b.set(Node.#device(key));
    b.set(name, 32);
    this.#govern(GOVERN.subject, b);
  }

  /** Lets a device govern the space but for making admins and owners, or no longer. */
  admin(key: string, on = true): void {
    const b = new Uint8Array(65);
    b.set(Node.#parseKey(key, 64));
    b[64] = on ? 1 : 0;
    this.#govern(GOVERN.admin, b);
  }

  /** Makes a device an owner too, for good. */
  owner(key: string): void {
    this.#govern(GOVERN.owner, Node.#parseKey(key, 64));
  }

  /** Names a relay for the space's devices to meet at, by its key and URL, the space being put after it. */
  relay(key: string, url: string): void {
    const at = utf8.encode(spaceUrl(url, this.#space ?? ""));
    const b = new Uint8Array(32 + at.length);
    b.set(Node.#parseKey(key, 32));
    b.set(at, 32);
    this.#govern(GOVERN.relay, b);
  }

  /** Who is in the space, by the roster this device holds. */
  members(): Member[] {
    const wasm = this.#wasm!;
    const n = wasm.members();
    const b = this.#bytes(wasm.data(), n).slice();
    const v = new DataView(b.buffer);
    const out: Member[] = [];
    const decoder = new TextDecoder();
    for (let at = 0; at < n; ) {
      const key = hex(b.subarray(at, at + 64));
      const flags = b[at + 64];
      const sl = v.getUint32(at + 65, true);
      const subject = decoder.decode(b.subarray(at + 69, at + 69 + sl));
      at += 69 + sl;
      const grants = new Map<number, Required<Rights> & { read: boolean }>();
      for (let k = v.getUint32(at, true), p = at + 4; k > 0; k--, p += 5) {
        const r = b[p + 4];
        grants.set(v.getUint32(p, true), { read: (r & 1) !== 0, write: (r & 2) !== 0, call: (r & 4) !== 0, vouch: (r & 8) !== 0 });
      }
      at += 4 + grants.size * 5;
      out.push(Object.freeze({ key, id: key.slice(0, 64), owner: (flags & 1) !== 0, admin: (flags & 2) !== 0, active: (flags & 4) !== 0, subject, grants }));
    }
    return out;
  }

  // A device by its key, or by its id: the key's first half.
  static #device(key: string): Uint8Array {
    return Node.#parseKey(key.length === 128 ? key.slice(0, 64) : key, 32);
  }

  static #parseKey(key: string, bytes: number): Uint8Array {
    if (!new RegExp(`^[0-9a-f]{${bytes * 2}}$`).test(key)) {
      throw new Error(bytes === 64 ? "a device's key is 128 hex digits, as `key` gives it" : "a key is 64 hex digits");
    }
    return unhex(key);
  }

  #govern(op: number, payload: Uint8Array): number {
    const wasm = this.#wasm!;
    this.#bytes(wasm.buffer(payload.length), payload.length).set(payload);
    const r = wasm.govern(op, payload.length);
    this.#kick();
    if (r < 0) throw new Error(REFUSED[r] ?? "the roster could not be changed");
    return r;
  }

  /** Opens a pipe to the node for a client. Undefined until the device is of a space. */
  readonly connect: Connect = (receive, closed) => this.#open(receive, closed, false);

  /**
   * Opens a pipe for a client elsewhere, as in another thread: what is sent it counts against its room until it says, by
   * `credit`, that it has dealt with it.
   */
  attach(receive: (data: Uint8Array) => void, closed: () => void): FarWire | undefined {
    return this.#open(receive, closed, true);
  }

  #open(receive: (data: Uint8Array) => void, closed: () => void, far: boolean): FarWire | undefined {
    const wasm = this.#wasm;
    if (!wasm || this.#space === undefined || this.#stopped) return undefined;
    const id = wasm.client();
    const c: Conn & { kind: "client" } = { kind: "client", receive, closed, inflight: 0, open: true, far };
    this.#conns.set(id, c);
    this.#kick();
    return {
      send: (data) => {
        if (!c.open || this.#stopped) return;
        // A piece at a time, so that the node never holds more than a piece of what was said at once.
        for (let at = 0; at < data.length && c.open; at += PIECE) {
          const piece = data.subarray(at, at + PIECE);
          this.#put(piece);
          wasm.input(id, piece.length);
        }
        this.#kick();
      },
      close: () => {
        if (!c.open) return;
        c.open = false;
        this.#conns.delete(id);
        if (!this.#stopped) wasm.closed(id), this.#kick();
      },
      credit: (bytes) => {
        const before = c.inflight;
        c.inflight = Math.max(0, c.inflight - bytes);
        if (c.open && before >= HIGH / 2 && c.inflight < HIGH / 2) this.#soon();
      },
    };
  }

  /** Resolves once the node is idle: everything said, everything durable, nothing waiting for a file. */
  async settled(): Promise<void> {
    while (this.#scheduled || this.#ticking || !this.store.settled || this.#deliveries.length > 0) {
      await new Promise<void>((done) => this.#waiting.push(done));
    }
  }

  /** Stops at once, as a machine does that loses its power: nothing more is written, synced or said. For tests. */
  abandon(): void {
    this.#stopped = true;
    clearTimeout(this.#timer);
    clearTimeout(this.#draining);
    for (const [, c] of this.#conns) if (c.kind === "socket") (c.ws.onclose = c.ws.onerror = c.ws.onmessage = null), c.ws.close();
    this.#conns.clear();
    this.#store.abandon();
  }

  /** Stops the node, makes what it was given durable, and closes the store. */
  async close(): Promise<void> {
    if (this.#stopped) return;
    this.#stopped = true;
    clearTimeout(this.#timer);
    clearTimeout(this.#draining);
    for (const [, c] of this.#conns) {
      if (c.kind === "socket") c.ws.close();
      else if (c.open) (c.open = false), c.closed();
    }
    this.#conns.clear();
    this.#wasm?.stop();
    await this.store.close();
  }

  // ---------------------------------------------------------------- the module

  #bytes(ptr: number, len: number): Uint8Array<ArrayBuffer> {
    return new Uint8Array(this.#wasm!.memory.buffer, ptr, len);
  }

  #put(data: Uint8Array): void {
    this.#bytes(this.#wasm!.buffer(data.length), data.length).set(data);
  }

  #instantiate(): Exports {
    const view = (ptr: number, len: number) => this.#bytes(ptr, len);
    const log = (level: Level, text: string) => {
      if (this.#options.log) this.#options.log(level, text);
      else if (level !== "debug") console[level === "warning" ? "warn" : level === "info" ? "log" : "error"]("zsp:", text);
    };
    const guard = <T>(f: () => T, otherwise: T): T => {
      try {
        return f();
      } catch (e) {
        log("error", String(e));
        return otherwise;
      }
    };
    const decoder = new TextDecoder();
    const host = {
      log_write: (off: number, ptr: number, len: number) => guard(() => this.#store.logWrite(off, view(ptr, len)), false),
      log_read: (off: number, ptr: number, len: number) => guard(() => this.#store.logRead(off, view(ptr, len)), false),
      log_end: () => this.#store.logEnd(),
      log_drop: (segment: number) => guard(() => this.#store.logDrop(segment), undefined),
      log_truncate: (off: number) => guard(() => this.#store.logTruncate(off), undefined),
      log_sync: () => this.#store.logSync(),
      page_read: (no: number, ptr: number) => guard(() => this.#store.pageRead(no, view(ptr, 4096)), false),
      page_write: (no: number, ptr: number, len: number) => guard(() => this.#store.pageWrite(no, view(ptr, len)), false),
      page_sync: () => this.#store.pageSync(),
      find_read: (no: number, ptr: number) => guard(() => this.#store.findRead(no, view(ptr, 4096)), false),
      find_write: (no: number, ptr: number, len: number) => guard(() => this.#store.findWrite(no, view(ptr, len)), false),
      find_sync: () => this.#store.findSync(),
      keep: (what: number, ptr: number, len: number) => guard(() => (this.#store.keep(what === 0 ? "keys" : "roster", view(ptr, len).slice()), true), false),
      now: () => Date.now(),
      dial: (id: number, ptr: number, len: number) => this.#dial(id, decoder.decode(view(ptr, len))),
      send: (id: number, ptr: number, len: number) => this.#send(id, view(ptr, len)),
      room: (id: number) => this.#room(id),
      ping: (id: number) => {
        const c = this.#conns.get(id);
        if (c?.kind === "socket" && c.ws.readyState === 1) c.ws.send("ping");
      },
      hangup: (id: number) => {
        const c = this.#conns.get(id);
        this.#conns.delete(id);
        if (c?.kind === "socket") c.ws.close();
        else if (c?.kind === "client" && c.open) (c.open = false), this.#deliveries.push([c, new Uint8Array(0)]);
      },
      say: (level: number, ptr: number, len: number) => log(LEVELS[Math.min(4, Math.floor(level / 10))], decoder.decode(view(ptr, len))),
    };
    const odin_env = {
      rand_bytes: (ptr: number, len: number) => crypto.getRandomValues(view(ptr, len)),
      write: (_fd: number, ptr: number, len: number) => log("info", decoder.decode(view(ptr, len))),
      tick_now: () => performance.now(),
      time_now: () => BigInt(Date.now()) * 1000000n,
      ln: Math.log,
    };
    this.#instance = new WebAssembly.Instance(this.#options.module, { host, odin_env } as unknown as WebAssembly.Imports);
    this.#wasm = this.#instance.exports as unknown as Exports;
    return this.#wasm;
  }

  #start(space: Uint8Array): void {
    const wasm = this.#wasm!;
    const credential =
      typeof this.#options.credential === "string" ? utf8.encode(this.#options.credential) : (this.#options.credential ?? new Uint8Array());
    const keys = this.store.kept("keys").latest ?? new Uint8Array();
    const { latest: roster = new Uint8Array(), before = new Uint8Array() } = this.store.kept("roster");
    const parts = [credential, keys, roster, before];
    const size = 64 + parts.reduce((n, p) => n + 4 + p.length, 0);
    const at = wasm.buffer(size);
    const b = this.#bytes(at, size);
    b.set(this.#secret);
    b.set(space.subarray(0, 32), 32);
    let p = 64;
    for (const part of parts) {
      new DataView(b.buffer, b.byteOffset + p, 4).setUint32(0, part.length, true);
      b.set(part, p + 4);
      p += 4 + part.length;
    }
    if (!wasm.start(this.#options.full === false ? 0 : 1)) throw new Error("could not open the store");
    this.#space = hex(space.subarray(0, 32));
    if (space.length > 64) {
      const relay = space.subarray(32);
      this.#bytes(wasm.buffer(relay.length), relay.length).set(relay);
      wasm.relay(relay.length);
    }
    this.#kick();
  }

  // ---------------------------------------------------------------- connections

  #dial(id: number, url: string): void {
    const Socket = this.#options.WebSocket ?? globalThis.WebSocket;
    let ws: WebSocket;
    try {
      ws = new Socket(url);
    } catch {
      queueMicrotask(() => this.#lost(id));
      return;
    }
    ws.binaryType = "arraybuffer";
    this.#conns.set(id, { kind: "socket", ws });
    ws.onopen = () => {
      if (this.#conns.get(id)?.kind !== "socket") return;
      this.#wasm!.opened(id);
      this.#kick();
    };
    ws.onmessage = (e: MessageEvent) => {
      if (this.#conns.get(id)?.kind !== "socket") return;
      if (typeof e.data === "string") {
        this.#wasm!.heard(id); // "pong", or nothing it need understand
        return;
      }
      const data = new Uint8Array(e.data as ArrayBuffer);
      this.#put(data);
      this.#wasm!.input(id, data.length);
      this.#kick();
    };
    ws.onclose = ws.onerror = () => this.#lost(id);
  }

  #lost(id: number): void {
    const c = this.#conns.get(id);
    if (!c || this.#stopped) return;
    this.#conns.delete(id);
    if (c.kind === "socket") c.ws.onclose = c.ws.onerror = c.ws.onmessage = c.ws.onopen = null;
    this.#wasm!.closed(id);
    this.#kick();
  }

  #send(id: number, bytes: Uint8Array): void {
    const c = this.#conns.get(id);
    if (!c) return;
    if (c.kind === "socket") {
      if (c.ws.readyState === 1) c.ws.send(bytes.slice());
      return;
    }
    if (!c.open) return;
    c.inflight += bytes.length;
    this.#deliveries.push([c, bytes.slice()]);
  }

  #room(id: number): number {
    const c = this.#conns.get(id);
    if (!c) return 0;
    if (c.kind === "client") return c.open ? HIGH - c.inflight : 0;
    if (c.ws.readyState !== 1) return 0;
    const room = HIGH - c.ws.bufferedAmount;
    if (room <= 0) this.#drain();
    return room;
  }

  // A WebSocket says nothing when its backlog clears, so while there is one it is looked at now and then.
  #drain(): void {
    if (this.#draining !== undefined) return;
    this.#draining = setTimeout(() => {
      this.#draining = undefined;
      this.#kick();
    }, DRAIN_POLL);
  }

  // ---------------------------------------------------------------- running

  // Something happened: the node hears of it once the current work is done, however many things happened.
  #kick(): void {
    if (this.#scheduled || this.#stopped) return;
    this.#scheduled = true;
    queueMicrotask(() => this.#tick());
  }

  #tick(): void {
    this.#scheduled = false;
    if (this.#stopped || !this.#wasm || this.#space === undefined) return;
    this.#ticking = true;
    clearTimeout(this.#timer);
    const wait = this.#wasm.tick();
    this.#ticking = false;
    if (wait === -2) {
      this.#fail(new Error("storage failed: the node has stopped rather than lose what it said was durable"));
      return;
    }
    if (wait >= 0) this.#timer = setTimeout(() => this.#kick(), wait);
    // Said only now, so that no client is told anything while the node is in the middle of something.
    for (const [c, data] of this.#deliveries.splice(0)) {
      if (data.length === 0) {
        c.closed();
        continue;
      }
      c.receive(data);
      if (c.far) continue; // it says when it has dealt with it
      c.inflight -= data.length;
      if (c.open && c.inflight + data.length > HIGH / 2) this.#soon(); // it was waiting for room: let others have a turn first
    }
    if (!this.#scheduled) for (const done of this.#waiting.splice(0)) done();
  }

  // Again, but after whatever else is waiting to happen, rather than before.
  #soon(): void {
    if (this.#scheduled || this.#stopped) return;
    this.#scheduled = true;
    setTimeout(() => this.#tick(), 0);
  }

  #fail(error: Error): void {
    if (this.#failure) return;
    this.#failure = error;
    void this.close();
    this.onFailure?.(error);
  }
}
