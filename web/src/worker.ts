// A browser's device runs here, in a dedicated worker, for only there may files be read and written synchronously. Each
// tab of an origin has a worker of its own, but a store has one node: the worker that holds the store's lock runs it, and
// the others carry their tabs' pipes to it. When its tab goes, the lock goes with it; the next worker in line opens the
// store and says so, every pipe carried to the one before is broken, and every client dials again, as it does whenever a
// pipe breaks.

/// <reference lib="webworker" />

import { Node, type FarWire, type Rights } from "./node.ts";
import { OpfsVolume, storePath } from "./volume-opfs.ts";
import { loadModule } from "./wasm.ts";

declare const self: DedicatedWorkerGlobalScope;
const tab = self; // this worker's own scope, by which its tab is told things: had once, as a test runs many in one

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
 * What a tab tells its worker: to open the store, a pipe, a question; to say when so many milliseconds are up, or no
 * longer, for a tab's timers are held back while it is hidden and a worker's are not; and that it is about to be stopped.
 */
export type Command =
  | { open: Options }
  | { away: true }
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
export type Report =
  | { answer: number; value?: unknown; error?: string; name?: string }
  | { failed: string; name?: string }
  | { space: string | undefined }
  | { due: number }
  | { credentialAt: number }; // when what the tab gave is said to have been given: anew, or again as newer, never what it is

// Between workers, on the store's channel.
type Shout =
  | { leader: true } // a worker has opened the store: whatever was carried to another is broken
  | { failed: string; name?: string } // its storage has failed, or could not be opened: it has stopped, and lets another try
  | { space: string | undefined } // the space the device is of, now
  | { open: string } // a pipe, on the channel of that name
  | { ask: string; op: Op; args: unknown[] }
  | { taking: string } // an ask the leader is doing now, which it may have done should it go before it answers
  | { answer: string; value?: unknown; error?: string; name?: string }
  | Given // a credential a tab has given, for whichever worker runs the node now and later
  | { credentials: true } // a worker that has just begun, asking to be told the newest given before it
  | { anyone: true } // a worker whose asks nobody has answered: whoever holds the store says it is there
  | { here: true }; // the worker that holds the store, opening it or running it

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
const waiting = new Map<string, (answer: { value?: unknown; error?: string; name?: string }) => void>();
const unheard = new Map<string, Shout>(); // said to the leader, and not yet answered

const taken = new Set<string>(); // asks of this worker's that the leader said it was doing
const timers = new Map<number, ReturnType<typeof setTimeout>>(); // the tab's

// What this worker says of itself, rather than as it is asked: to its tab, and with tellAll to every other worker too. Once
// it is leaving, nothing: the store is let go of, or is being, which is no failure nor anything else to tell, and its tab
// is going. All a worker leaving still says is that it is there, asked while it holds the store and lets go of it, and
// what credentials its tab gave, which are its tab's to give.
function tell(r: Report): void {
  if (!leaving) tab.postMessage(r);
}
function tellAll(r: Report & Shout): void {
  if (leaving) return;
  tab.postMessage(r);
  channel.postMessage(r);
}

tab.onmessage = async (e: MessageEvent<Command>) => {
  const c = e.data;
  if ("away" in c) away();
  else if ("open" in c) open(c.open);
  else if ("connect" in c) connect(c.connect);
  else if ("after" in c) {
    const id = c.after;
    timers.set(id, setTimeout(() => (timers.delete(id), tab.postMessage({ due: id } satisfies Report)), c.ms));
  } else if ("cancel" in c) clearTimeout(timers.get(c.cancel)), timers.delete(c.cancel);
  else if ("ask" in c) tab.postMessage({ answer: c.ask, ...(await ask(c.op, c.args)) } satisfies Report);
};

let options: Options;
let contending = false; // in line for the store, or running it
let leaving = false; // closed, or about to be stopped: the store is let go of, and never had again
let letGo: (() => void) | undefined; // ends the running of the node here, closed or put away, and so the hold on the store
let line: AbortController | undefined; // gives up this worker's place in line for the store, while it is in line
let held: Promise<void> = Promise.resolve(); // resolves once this worker holds the store no longer, nor is in line for it
let holding = false; // has the store's lock, and is opening it, running it or letting go of it
let opening: OpfsVolume | undefined; // the store's directory, while this worker holds it
let stage = 0; // how far it has got in opening the store, or letting it go: see here()
// What waits on another worker holding the store (see listen): had only while this worker neither holds it nor is leaving.
let silence: ReturnType<typeof setTimeout> | undefined; // until what waits on whoever holds the store is given up on
let holderHeard = false; // whoever holds the store, since this worker last looked
let probeHeard = false; // another worker asking whether it is there, since this one last looked
const awaiting = new Map<string, number>(); // pipes carried to the leader, sent something it has not answered, as of when
let quiets = 0; // times this worker has begun to look whether whoever holds the store is there: when, for `awaiting`

/** What went wrong, as a tab is told it: the error's name too, where it is one an application may tell apart. */
export type Failure = { message: string; name?: string };
const failure = (e: unknown): Failure =>
  e instanceof Error ? { message: e.message, ...(e.name === "StoreLocked" ? { name: e.name } : {}) } : { message: String(e) };

function open(o: Options): void {
  let name: string;
  try {
    name = storePath(o.name); // what its lock, its channel and its directory are all named by
  } catch (e) {
    return void tell({ failed: failure(e).message });
  }
  options = { ...o, name };
  channel = new BroadcastChannel("zsp:" + name);
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
  if (anew) tell({ credentialAt: given.at }); // for its tab to give again, as of then, should it start another worker
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
// the others gave what they did: what is given here after it is given later anyway. (A script of the origin that said one
// further ahead again, eight thousand times over, could count them out at last: as it could give a credential itself, or
// open the device and do as it likes with it. The origin is what a browser trusts its device to.)
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
  if (contending || leaving) return;
  contending = true;
  const o = options;
  // Nothing of the store is let go of, lock and all, while any of its files is open or being opened: the next to have the
  // lock would find it held. Node.open, failing, has let go of every one; and `close` says when they are.
  const giveUp = (line = new AbortController());
  const request = navigator.locks.request("zsp:" + o.name, { signal: giveUp.signal }, async () => {
    if (line === giveUp) line = undefined; // had: nothing to give up now but the store itself
    if (leaving) return;
    holding = true;
    unlisten(); // what waited on whoever held the store waits on this worker now, which answers it or says it failed
    saidStage = -1; // and, holding it anew, it has said nothing of how far it has got
    try {
      await hold(o);
    } finally {
      // Whatever came of it, the lock is let go of now, and this worker says it is there no more: what waits on whoever
      // has it next, as asks made while this one let go of it do, waits as any does.
      holding = false;
      opening = undefined;
      listen();
    }
  });
  held = Promise.all([held, request.catch(() => {})]).then(() => {}); // given up while in line, it is refused
}

// Runs the node, with the store's lock: from opening the store, step by step, each of which counts as getting on (see
// here()), to letting it go once every file is closed. Left as it opens, it opens nothing more, and tells nobody it failed.
async function hold(o: Options): Promise<void> {
  let node: Node;
  let ended: Promise<Error | undefined>; // failed, or closed or put away
  let stopped: Error | undefined;
  try {
    const volume = (opening = await OpfsVolume.at("zsp/" + o.name));
    stage++;
    if (leaving) return volume.close();
    const module = await loadModule(o.wasm ? new URL(o.wasm, tab.location.href) : undefined);
    stage++;
    if (leaving) return volume.close();
    // Partial unless told otherwise: a browser holds what its tabs watch and ask about, not the whole space.
    const given = newest;
    node = await Node.open({ volume, module, full: o.full === true, keep: o.keep, credential: given?.credential });
    stage++;
    ended = new Promise((done) => {
      letGo = () => done(undefined);
      node.onFailure = (e) => done((stopped ??= e)); // at once, should it have failed in its first turn, as it opened
    });
    if (newest !== given && !stopped) node.setCredential(newest!.credential); // given while it opened
  } catch (error) {
    contending = false;
    if (!leaving) fail(failure(error)); // and else let go of as asked, which is no failure
    return;
  }
  if (leaving) stopNow(node), letGo!(); // closed or put away as it opened
  else if (!stopped) {
    device = node;
    breakCarried();
    channel.postMessage({ leader: true } satisfies Shout);
    tellSpace();
    // What this worker itself was waiting to hear, it now answers: but what the one before may have done already, it says
    // may have been.
    for (const [id, s] of unheard) if ("ask" in s) heard({ answer: id, ...(gone(id, s.op) ?? answer(s.op, s.args)) });
  }
  // Held until the worker is gone with its tab, or the node is closed or put away; or until it stops of itself: then
  // every tab is told, at once, and another worker may have the store, and try, once its files are let go of.
  const error = await ended;
  letGo = undefined;
  if (device === node) device = undefined;
  if (error) {
    contending = false;
    fail(failure(error));
  }
  await node.close();
}

// Lets go of the store for good, as the device is closed or its tab is about to stop this worker: the node is stopped, what
// it holds made durable, and every file closed, at once, for nothing after this is sure to be run; what is being opened is
// given up, and what of it is open closed; a place in line is given up; and the lock is let go of once nothing is being
// opened, unless the worker is stopped first, which lets go of it anyway. Resolves once it is. Chrome runs what was sent a
// worker before it stops it, and so this; and whatever any of it throws, the rest is done. Nothing here waits on whoever
// holds the store any more: what this worker asked of it is answered no more, the pipes it carried to it are broken, and
// its tab, going, is told nothing more but what it asks.
function leave(): Promise<void> {
  leaving = true;
  unlisten();
  waiting.clear();
  unheard.clear();
  taken.clear();
  breakCarried();
  line?.abort();
  const d = device;
  device = undefined;
  stopNow(d);
  try {
    opening?.close();
  } finally {
    letGo?.();
  }
  return held;
}

// Stops a node at once, as this worker leaves, whatever stopping it throws: its files are closed all the same
// (Node.closeNow), and the store is let go of once they are, as ever.
function stopNow(node: Node | undefined): void {
  try {
    void node?.closeNow().catch(() => {});
  } catch {
    // stopped all the same
  }
}

const away = () => void leave();

// Every tab hears that the node has stopped, its storage having failed; this one too, which hears nothing it says.
function fail(f: Failure): void {
  failedAsks(f);
  breakCarried(); // to one that is gone, or none: every client dials again, and so this worker is wanted, and tries again
  tellAll({ failed: f.message, name: f.name });
}

// Every tab hears what space the device is of, whichever tab changed it.
function tellSpace(): void {
  tellAll({ space: device?.space });
}

function breakCarried(): void {
  for (const breakOff of [...carried]) breakOff();
}

// ---------------------------------------------------------------- the device, for any tab

async function ask(op: Op, args: unknown[]): Promise<{ value?: unknown; error?: string; name?: string }> {
  if (op === "credential") {
    const c = args[0];
    const at = args[1];
    if (!(typeof c === "string" || c instanceof Uint8Array) || typeof at !== "number") return { error: "a credential is a string or bytes" };
    return { value: give(c, at, true) }; // given now, and so after any this worker knows of
  }
  if (op === "close") {
    // This tab's device goes: if this worker runs the node, or is opening it, it is stopped as it should be, what it holds
    // written down, and the store let go of, before the worker goes and another takes it. Another's node is not this
    // tab's to stop: this worker's place in line for it is given up.
    await leave();
    return {};
  }
  if (device) return answer(op, args);
  if (!channel) return { error: "the device was never opened: its name names no store" };
  if (leaving) return { error: "the device is closed" }; // and nothing waits on whoever holds the store
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
function failedAsks(f: Failure): void {
  for (const [id, done] of waiting) unheard.delete(id), taken.delete(id), done({ error: f.message, name: f.name });
  waiting.clear();
  if (!waitingOnHolder()) clearTimeout(silence), (silence = undefined);
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
  listen();
}

// What waits on whoever holds the store, asks and pipes carried to it, is given up on, said to have failed as the store is
// locked, should nothing that holds it say anything for HEARD_WITHIN, nor when asked whether it is there for as long again:
// for a live one answers at once, or, opening the store, says it is there while it gets on with it. One that answers
// nothing holds it all the same, and this worker would wait in line for ever, as when a tab's renderer has hung, or crashed
// and not been let go of, which Chrome has been seen to do on Linux: its tab is told so, rather than nothing, and every
// pipe carried to it is broken. This worker stays in line, and has the store should it ever be let go of. A pipe that was
// sent something and answered nothing is waited on until the holder is heard from, by the pipe or as asked; with nothing
// waiting, nothing is asked, and no timer is set. Asked by another worker meanwhile, this one need not ask too: what the
// holder says, every worker hears.
//
// Only another worker is waited on so: one holding the store answers what is asked of it, or says it failed, itself, and
// one leaving waits on nobody. So this is done only while this worker neither holds the store nor is leaving, and all of
// it is let go of as it comes to hold it, or leaves: what was waiting on another is not waited on, and told, after.
const waitingOnHolder = () => waiting.size > 0 || awaiting.size > 0;
const listening = () => !holding && !leaving;
function listen(): void {
  if (silence !== undefined || !listening() || !waitingOnHolder()) return;
  let askedHolder = false;
  // Each time it looks, anew: what was sent before, the holder has once it is heard from after.
  const look = () => {
    quiets++;
    holderHeard = probeHeard = false;
    silence = setTimeout(quiet, HEARD_WITHIN);
  };
  const quiet = () => {
    silence = undefined;
    // What was sent it before it was last heard from, it has, being there; what since, it may yet answer.
    if (holderHeard) for (const [n, at] of awaiting) if (at < quiets) awaiting.delete(n);
    if (!waitingOnHolder()) return;
    if (holderHeard || !askedHolder) {
      if (!holderHeard && !probeHeard) channel.postMessage({ anyone: true } satisfies Shout);
      askedHolder = !holderHeard;
      return look();
    }
    const f: Failure = { message: "the store is held by something that does not answer: another tab of this site, hung, or the browser, until it is restarted", name: "StoreLocked" };
    awaiting.clear();
    failedAsks(f);
    breakCarried(); // and so every client dials again, and is told so again should it be so still
    tell({ failed: f.message, name: f.name });
  };
  look();
}

// A pipe carried to the leader has been sent something it has not answered, as of `at`, or now: waited on, if another holds
// the store.
function awaited(name: string, at = quiets): void {
  if (!listening()) return;
  awaiting.set(name, at);
  listen();
}

function unlisten(): void {
  clearTimeout(silence);
  silence = undefined;
  awaiting.clear();
  holderHeard = probeHeard = false;
}

// Asked whether it is there, the worker that holds the store says so if it is running the node, or if it has got on with
// opening the store, or letting it go, since it last said so: one stuck, waiting on a file that never opens, a fetch that
// never ends, is not there for anything that waits on it. Said once a second at most, for every worker hears it. How far
// it has got is counted in part by its volume, had anew each time it comes to hold the store, and so may come to what it
// said as it held it before: what it said then is let go of as it holds it again, and it says it is there when first asked.
let saidStage = -1;
let saidAt = -Infinity;
function here(): void {
  const now = performance.now();
  const got = stage + (opening?.steps ?? 0);
  if ((!device && got === saidStage) || now - saidAt < 1000) return;
  saidStage = got;
  saidAt = now;
  channel.postMessage({ here: true } satisfies Shout);
}

// Anything on the channel is of this origin; but what is not as a worker says it is ignored, rather than thrown at.
function heard(s: Shout): void {
  if (typeof s !== "object" || s === null) return;
  if ("here" in s || "leader" in s || "taking" in s || "answer" in s) holderHeard = true; // whoever holds the store is there
  if ("failed" in s) {
    if (typeof s.failed !== "string") return;
    const f: Failure = { message: s.failed, ...(s.name === "StoreLocked" ? { name: s.name } : {}) };
    failedAsks(f);
    breakCarried();
    tell({ failed: f.message, name: f.name });
  } else if ("space" in s) {
    if (s.space !== undefined && typeof s.space !== "string") return;
    tell({ space: s.space });
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
  } else if ("anyone" in s) {
    probeHeard = true;
    if (holding) here();
  } else if ("taking" in s) {
    if (typeof s.taking === "string" && waiting.has(s.taking)) taken.add(s.taking);
  } else if ("answer" in s) {
    if (typeof s.answer !== "string") return;
    const done = waiting.get(s.answer);
    unheard.delete(s.answer);
    waiting.delete(s.answer);
    taken.delete(s.answer);
    if (!waitingOnHolder()) clearTimeout(silence), (silence = undefined); // nothing more to wait on it for
    done?.({ value: s.value, error: s.error, name: s.name === "StoreLocked" ? s.name : undefined });
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
  if (leaving) return toTab({ close: true }), port.close(); // carried nowhere: the device is closed
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
    awaiting.delete(name);
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
    if ("data" in say && open) awaited(name);
  };
  far.onmessage = (e: MessageEvent<Say>) => {
    const say = e.data;
    holderHeard = true; // the leader, by the pipe
    awaiting.delete(name);
    if (!heardBack) {
      heardBack = true;
      clearTimeout(unanswered);
      unheard.delete(name);
      for (const s of early.splice(0)) {
        far.postMessage(s);
        if ("data" in s) awaited(name); // sent only now, and so not yet answered
      }
    }
    if ("close" in say) breakOff();
    else if ("data" in say) toTab(say);
  };
  void navigator.locks.request(name, () => {
    if (open) {
      awaited(name);
      shout(name, { open: name });
      // Broken off unanswered, it is waited on still, as of when it was sent what it was, until the holder is heard from
      // or given up on: else a client that dials again only now and then would never wait long enough on a holder that
      // answers nothing to be told so.
      unanswered = setTimeout(() => {
        const at = awaiting.get(name);
        breakOff();
        if (at !== undefined) awaited(name, at);
      }, HEARD_WITHIN);
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
