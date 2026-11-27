// A browser's device runs here, in a dedicated worker, for only there may files be read and written synchronously. Each
// tab of an origin has a worker of its own, but a store has one node: the worker that holds the store's lock runs it, and
// the others carry their tabs' pipes to it. When its tab goes, the lock goes with it; the next worker in line opens the
// store and says so, every pipe carried to the one before is broken, and every client dials again, as it does whenever a
// pipe breaks.

/// <reference lib="webworker" />

import { Node, type FarWire, type Rights } from "./node.ts";
import { OpfsVolume } from "./volume-opfs.ts";
import { loadModule } from "./wasm.ts";

declare const self: DedicatedWorkerGlobalScope;

export interface Options {
  /** Which store: a directory of the origin's private file system, under zsp/. */
  name: string;
  full?: boolean;
  keep?: { days?: number; bytes?: number } | false;
  credential?: string | Uint8Array;
  /** When the tab gave it, by Date.now(): what a tab gave later is presented rather than what it gave before. */
  credentialAt?: number;
  /** That the tab gave it before, to a worker it has since started again in this one's place. */
  credentialAgain?: boolean;
  /** Where node.wasm is, if not beside this script. */
  wasm?: string;
}

/**
 * What a tab tells its worker: to open the store, a pipe, a question; and to say when so many milliseconds are up, or no
 * longer, for a tab's timers are held back while it is hidden and a worker's are not.
 */
export type Command =
  | { open: Options }
  | { connect: MessagePort }
  | { ask: number; op: Op; args: unknown[] }
  | { after: number; ms: number }
  | { cancel: number };

/** What a device can be asked to do, by whichever tab. */
export type Op =
  | "identity"
  | "join"
  | "adopt"
  | "member"
  | "create"
  | "scope"
  | "admit"
  | "revoke"
  | "subject"
  | "admin"
  | "owner"
  | "relay"
  | "members"
  | "usage"
  | "credential"
  | "close";

/**
 * What a worker tells its tab: an answer; that the node has stopped, its storage having failed; the space it is of; or
 * that a time asked for is up. Never a credential: the tab that gave one has it, and no other tab is given it.
 */
export type Report = { answer: number; value?: unknown; error?: string } | { failed: string } | { space: string | undefined } | { due: number };

// Between workers, on the store's channel.
type Shout =
  | { leader: true } // a worker has opened the store: whatever was carried to another is broken
  | { failed: string } // its storage has failed: it has stopped, and lets another try
  | { space: string | undefined } // the space the device is of, now
  | { open: string } // a pipe, on the channel of that name
  | { ask: string; op: Op; args: unknown[] }
  | { taking: string } // an ask the leader is doing now, which it may have done should it go before it answers
  | { answer: string; value?: unknown; error?: string }
  | Given // a credential a tab has given, for whichever worker runs the node now and later
  | { credentials: true }; // a worker that has just begun, asking to be told the newest given before it

// What may be asked again of the next leader, as having been done or not it is the same: anything else, asked of one that
// went as it did it, may have been done, and is said to have failed rather than be done twice.
const AGAIN = new Set<Op>(["identity", "member", "members", "usage"]);

// The credential to present to relays: whichever a tab gave last, of those this worker has heard of. Every worker hears
// of every one given while it lives, and asks those there before it for the newest they know as it begins: so whichever
// runs the node next has the newest there is. `at` orders them, a clock of the machine's own and of what was given before:
// what is given anew is given no earlier than the time, nor than anything its worker has heard of, set back though the
// machine's clock may be; `by` breaks ties. What is said again, `old`, as a worker answers one that has just begun or as a
// tab starts its worker again, was given before: what a tab gave anew stays newer than any such, which its worker hears of
// only after, and is given again as newer still should it be said to be older.
type Given = { credential: string | Uint8Array; at: number; by: string; old?: boolean };
let newest: Given | undefined;
let mine: Given | undefined; // what this worker's tab gave anew, while it is the newest given
const me = crypto.randomUUID();

/** How long a pipe carried to the leader waits to hear from it, before it is broken off and its client dials again. */
const HEARD_WITHIN = 3000;

/** On a pipe: from its client's end, data and credit; from the node's, data. Either may close it. */
export type Say = { data: Uint8Array } | { credit: number } | { close: true };

let device: Node | undefined;
let channel: BroadcastChannel;
const carried = new Set<() => void>(); // pipes carried to the leader: how to break each
const waiting = new Map<string, (answer: { value?: unknown; error?: string }) => void>();
const unheard = new Map<string, Shout>(); // said to the leader, and not yet answered

const taken = new Set<string>(); // asks of this worker's that the leader said it was doing
const timers = new Map<number, ReturnType<typeof setTimeout>>(); // the tab's

self.onmessage = async (e: MessageEvent<Command>) => {
  const c = e.data;
  if ("open" in c) open(c.open);
  else if ("connect" in c) connect(c.connect);
  else if ("after" in c) {
    const id = c.after;
    timers.set(id, setTimeout(() => (timers.delete(id), self.postMessage({ due: id } satisfies Report)), c.ms));
  } else if ("cancel" in c) clearTimeout(timers.get(c.cancel)), timers.delete(c.cancel);
  else if ("ask" in c) self.postMessage({ answer: c.ask, ...(await ask(c.op, c.args)) } satisfies Report);
};

let options: Options;
let contending = false; // in line for the store, or running it

function open(o: Options): void {
  options = o;
  channel = new BroadcastChannel("zsp:" + o.name);
  channel.onmessage = (e: MessageEvent<Shout>) => heard(e.data);
  channel.postMessage({ credentials: true } satisfies Shout);
  if (o.credential !== undefined) give(o.credential, o.credentialAt ?? Date.now(), o.credentialAgain !== true);
  contend();
}

// This tab's credential: to the node, if it runs here, and to every other worker. Given anew, it is the newest; given again,
// it is as it was given, and only if it is the newest still. Returns when it is said to have been given.
function give(credential: string | Uint8Array, at: number, anew: boolean): number {
  const given: Given = anew ? { credential, at: Math.max(at, (newest?.at ?? 0) + 1), by: me } : { credential, at, by: me, old: true };
  if (!anew && !newer(given)) return given.at;
  newest = given;
  mine = anew ? given : undefined;
  present();
  channel.postMessage(given satisfies Shout);
  return given.at;
}

function newer(g: Given): boolean {
  return !newest || g.at > newest.at || (g.at === newest.at && g.by > newest.by);
}

// To the node running here, if it is: one that has stopped presents nothing, and the next is opened with the newest.
function present(): void {
  try {
    device?.setCredential(newest!.credential);
  } catch {
    // stopped, and so about to be let go of
  }
}

// Another tab's: taken if it is newer than any this worker knows of, unless it was given before what this worker's own tab
// gave anew, which is then given again as newer. Anything on the channel is of this origin, which may open the device and
// do as it likes with it anyway; but what is not a credential is not taken as one, nor one said to have been given further
// ahead of any this worker knows of, or of its time, than any clock could be: what is given after it would be later still,
// and at last too late to be counted. Judged by what it knows as much as by its clock, which may have been set back since
// the others gave what they did: what is given here after it is given later anyway.
function heardGiven(g: Given): void {
  if (!(typeof g.credential === "string" || g.credential instanceof Uint8Array) || typeof g.at !== "number" || typeof g.by !== "string") return;
  if (!(g.at > 0 && g.at <= Math.max(Date.now(), newest?.at ?? 0) + AHEAD) || !newer(g)) return;
  if (g.old === true && mine && mine === newest) {
    give(mine.credential, g.at + 1, true); // what this tab gave since stays the newest
    return;
  }
  newest = { credential: g.credential, at: g.at, by: g.by };
  if (g.old !== true) mine = undefined; // given since, by another
  present();
}

const AHEAD = 2 ** 40; // ms, some thirty years: more than any clock is wrong by, and less than counting can be thrown out by

// Gets in line for the store. Whoever holds its lock runs the node, for as long as its tab lives; one whose node stopped,
// or never started, gets in line again when it is next wanted, by its tab asking or dialling, and tries again then: so a
// store whose storage failed is run again once it can be, and one that cannot be is tried no more often than its clients
// dial, which they do less and less often while they cannot.
function contend(): void {
  if (contending) return;
  contending = true;
  const o = options;
  void navigator.locks.request("zsp:" + o.name, async () => {
    let failed: Promise<Error>;
    try {
      const volume = await OpfsVolume.at("zsp/" + o.name);
      const module = await loadModule(o.wasm ? new URL(o.wasm, self.location.href) : undefined);
      // Partial unless told otherwise: a browser holds what its tabs watch and ask about, not the whole space.
      const given = newest;
      const node = await Node.open({ volume, module, full: o.full === true, keep: o.keep, credential: given?.credential });
      failed = new Promise((done) => (node.onFailure = done));
      if (newest !== given) node.setCredential(newest!.credential); // given while it opened
      device = node;
    } catch (error) {
      contending = false;
      fail(error instanceof Error ? error.message : String(error));
      return;
    }
    breakCarried();
    channel.postMessage({ leader: true } satisfies Shout);
    tellSpace();
    // What this worker itself was waiting to hear, it now answers: but what the one before may have done already, it says
    // may have been.
    for (const [id, s] of unheard) if ("ask" in s) heard({ answer: id, ...(gone(id, s.op) ?? answer(s.op, s.args)) });
    // Held until the worker is gone with its tab, or until the node stops of itself: then every tab is told, and another
    // worker may have the store, and try.
    const error = await failed;
    device = undefined;
    contending = false;
    fail(error.message);
  });
}

// Every tab hears that the node has stopped, its storage having failed; this one too, which hears nothing it says.
function fail(message: string): void {
  failedAsks(message);
  breakCarried(); // to one that is gone, or none: every client dials again, and so this worker is wanted, and tries again
  self.postMessage({ failed: message } satisfies Report);
  channel.postMessage({ failed: message } satisfies Shout);
}

// Every tab hears what space the device is of, whichever tab changed it.
function tellSpace(): void {
  const space = device?.space;
  self.postMessage({ space } satisfies Report);
  channel.postMessage({ space } satisfies Shout);
}

function breakCarried(): void {
  for (const breakOff of [...carried]) breakOff();
}

// ---------------------------------------------------------------- the device, for any tab

async function ask(op: Op, args: unknown[]): Promise<{ value?: unknown; error?: string }> {
  if (op === "credential") {
    const c = args[0];
    const at = args[1];
    if (!(typeof c === "string" || c instanceof Uint8Array) || typeof at !== "number") return { error: "a credential is a string or bytes" };
    return { value: give(c, at, true) }; // given now, and so after any this worker knows of
  }
  if (op === "close") {
    // This tab's device goes: if this worker runs the node, it is stopped as it should be, what it holds written down,
    // before the worker goes with the lock and another takes it. Another's node is not this tab's to stop.
    if (device) {
      const d = device;
      device = undefined;
      await d.close().catch(() => {});
    }
    return {};
  }
  if (device) return answer(op, args);
  contend();
  const id = crypto.randomUUID();
  return new Promise((done) => {
    waiting.set(id, done);
    shout(id, { ask: id, op, args });
  });
}

function answer(op: Op, args: unknown[]): { value?: unknown; error?: string } {
  const d = device!;
  try {
    switch (op) {
      case "identity":
        return { value: { id: d.id, key: d.key, space: d.space } };
      case "join":
        d.join(args[0] as string, args[1] as { key: string; url: string });
        tellSpace();
        return { value: d.space };
      case "adopt": {
        const taken = d.adopt(args[0] as Uint8Array);
        tellSpace();
        return { value: taken };
      }
      case "member":
        return { value: d.member };
      case "create": {
        const space = d.create();
        tellSpace();
        return { value: space };
      }
      case "scope":
        return { value: d.scope(args[0] as boolean | undefined) };
      case "admit":
        return { value: d.admit(args[0] as string, args[1] as number, args[2] as Rights | undefined) };
      case "revoke":
        return { value: d.revoke(args[0] as string, args[1] as number | undefined) };
      case "subject":
        return { value: d.subject(args[0] as string, args[1] as string) };
      case "admin":
        return { value: d.admin(args[0] as string, args[1] as boolean | undefined) };
      case "owner":
        return { value: d.owner(args[0] as string) };
      case "relay":
        return { value: d.relay(args[0] as string, args[1] as string) };
      case "members":
        return { value: d.members() };
      case "usage":
        return { value: { held: d.held, memory: d.memory } };
      case "close":
      case "credential":
        return {}; // see ask
    }
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e) };
  }
}

// Whatever was asked of a node that stopped, or of one that never came to be, and not answered, was not done, and the tab
// is told it failed: it is not to be done by the next, either.
function failedAsks(message: string): void {
  for (const [id, done] of waiting) unheard.delete(id), taken.delete(id), done({ error: message });
  waiting.clear();
}

// What a leader that has gone was doing as it went, and may have done: unless it may be done again, it is said to have
// failed, rather than be done twice.
function gone(id: string, op: Op): { error: string } | undefined {
  if (!taken.delete(id) || AGAIN.has(op)) return undefined;
  return { error: "the tab running the device went as it did this, which may or may not have been done" };
}

// Says something to the leader, and again to every new one until it is answered: one opening its store hears nothing.
function shout(id: string, s: Shout): void {
  unheard.set(id, s);
  channel.postMessage(s);
}

// Anything on the channel is of this origin; but what is not as a worker says it is ignored, rather than thrown at.
function heard(s: Shout): void {
  if (typeof s !== "object" || s === null) return;
  if ("failed" in s) {
    if (typeof s.failed !== "string") return;
    failedAsks(s.failed);
    breakCarried();
    self.postMessage({ failed: s.failed } satisfies Report);
  } else if ("space" in s) {
    if (s.space !== undefined && typeof s.space !== "string") return;
    self.postMessage({ space: s.space } satisfies Report);
  } else if ("leader" in s) {
    breakCarried(); // to one that is gone
    for (const [id, u] of [...unheard]) {
      if ("open" in u) continue;
      const lost = "ask" in u ? gone(id, u.op) : undefined;
      if (lost) heard({ answer: id, ...lost });
      else channel.postMessage(u);
    }
  } else if ("by" in s) {
    heardGiven(s);
  } else if ("credentials" in s) {
    if (newest) channel.postMessage({ ...newest, old: true } satisfies Shout); // to one that has just begun, and so to all
  } else if ("taking" in s) {
    if (typeof s.taking === "string" && waiting.has(s.taking)) taken.add(s.taking);
  } else if ("answer" in s) {
    if (typeof s.answer !== "string") return;
    const done = waiting.get(s.answer);
    unheard.delete(s.answer);
    waiting.delete(s.answer);
    taken.delete(s.answer);
    done?.({ value: s.value, error: s.error });
  } else if (device && "ask" in s) {
    if (typeof s.ask !== "string" || typeof s.op !== "string" || !Array.isArray(s.args)) return;
    // Said before it is done, so that should this worker go as it does it, the asker knows it may have been.
    if (!AGAIN.has(s.op)) channel.postMessage({ taking: s.ask } satisfies Shout);
    channel.postMessage({ answer: s.ask, ...answer(s.op, s.args) } satisfies Shout);
  } else if (device && "open" in s) {
    if (typeof s.open !== "string" || !s.open.startsWith(channel.name + ":")) return;
    serve(new BroadcastChannel(s.open));
  }
}

// ---------------------------------------------------------------- pipes

// A tab's client wants a pipe: to the node here, or carried to the leader.
function connect(port: MessagePort): void {
  const toTab = (say: Say) => ("data" in say ? port.postMessage(say, [say.data.buffer as ArrayBuffer]) : port.postMessage(say));
  if (device) {
    const wire = attach(toTab, () => port.close());
    port.onmessage = (e: MessageEvent<Say>) => (wire ? onSay(wire, e.data) : undefined);
    return;
  }
  contend();
  // The leader may not be listening on the pipe's own channel until it says so: until then what the tab says waits here.
  const name = channel.name + ":" + crypto.randomUUID();
  const far = new BroadcastChannel(name);
  let heardBack = false;
  const early: Say[] = [];
  let open = true;
  // Should the leader not hear of it, or not answer, as one opening the store, closing it or frozen does not, the client
  // is told it is broken: it dials again, and this worker, in line for the store, may by then have it.
  let unanswered: ReturnType<typeof setTimeout> | undefined;
  // Held for as long as the pipe is: the leader waits for it, and so learns when this end has gone, tab and all.
  let letGo!: () => void;
  const held = new Promise<void>((done) => (letGo = done));
  const breakOff = () => {
    if (!open) return;
    open = false;
    clearTimeout(unanswered);
    carried.delete(breakOff);
    unheard.delete(name);
    far.postMessage({ close: true } satisfies Say);
    far.close();
    toTab({ close: true });
    port.close();
    letGo();
  };
  carried.add(breakOff);
  port.onmessage = (e: MessageEvent<Say>) => {
    const say = e.data;
    if ("close" in say) breakOff();
    else if (heardBack) far.postMessage(say);
    else early.push(say);
  };
  far.onmessage = (e: MessageEvent<Say>) => {
    const say = e.data;
    if (!heardBack) {
      heardBack = true;
      clearTimeout(unanswered);
      unheard.delete(name);
      for (const s of early.splice(0)) far.postMessage(s);
    }
    if ("close" in say) breakOff();
    else if ("data" in say) toTab(say);
  };
  void navigator.locks.request(name, () => {
    if (open) {
      shout(name, { open: name });
      unanswered = setTimeout(breakOff, HEARD_WITHIN);
    }
    return held;
  });
}

// A pipe from another tab's worker, on a channel of its own, for as long as that worker holds the pipe's lock: once it lets
// go, by breaking the pipe off or by being gone with its tab, the lock is had here, and the pipe is closed. Said again, it
// is the same pipe.
const served = new Set<string>();
function serve(c: BroadcastChannel): void {
  const name = c.name;
  if (served.has(name)) return c.close();
  served.add(name);
  const wire = attach(
    (say) => c.postMessage(say),
    () => c.close(),
  );
  if (!wire) return void served.delete(name);
  c.postMessage({ credit: 0 } satisfies Say); // that it is heard
  c.onmessage = (e: MessageEvent<Say>) => onSay(wire, e.data);
  void navigator.locks.request(name, () => {
    served.delete(name);
    onSay(wire, { close: true });
  });
}

// Joins a pipe to the node. What is sent it counts against its room until its client's end says it has dealt with it.
function attach(post: (say: Say) => void, release: () => void): FarWire | undefined {
  let open = true;
  const close = () => {
    if (!open) return;
    open = false;
    post({ close: true });
    release();
  };
  const wire = device!.attach((data) => post({ data }), close);
  if (!wire) close();
  else closers.set(wire, close);
  return wire;
}

const closers = new WeakMap<FarWire, () => void>();

function onSay(wire: FarWire, say: Say): void {
  if ("close" in say) {
    wire.close();
    closers.get(wire)?.();
  } else if ("data" in say) wire.send(say.data);
  else wire.credit(say.credit);
}
