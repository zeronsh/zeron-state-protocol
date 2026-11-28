// A device in a browser. Its node runs in a worker, where its store, a directory of the origin's private file system,
// may be read and written synchronously; tabs of one origin share it, whichever of them happens to run it (./worker.ts).

import { Client, madeOn, sealNow, unacknowledged, Undelivered } from "./client.ts";

// A device's close, settled however it goes: rejected, should anything its clients wrote never be delivered, but never
// thrown at whoever does not wait for it.
const handledClose = (f: () => Promise<void>): Promise<void> => {
  const p = f();
  p.catch(() => {});
  return p;
};
import type { Device, Relay } from "./index.ts";
import type { Connect, Member, Rights } from "./node.ts";
import { storePath } from "./volume-opfs.ts";
import { StoreLocked, Uncertain } from "./volume.ts";
import type { Command, Op, Report, Say } from "./worker.ts";

export * from "./index.ts";

// What the worker said went wrong, as the error it was.
const errorOf = (message: string, name?: string): Error =>
  name === "StoreLocked" ? new StoreLocked(message) : name === "Uncertain" ? new Uncertain(message) : new Error(message);

export interface OpenOptions {
  /**
   * Which store: one device each, shared by the origin's tabs. "default" unless said. A path of the origin's file system,
   * under zsp/, whose empty parts are none: "app", "app/" and "/app" are one store. One of no parts, or of "." or "..", is a
   * RangeError.
   */
  name?: string;
  /**
   * Replicate everything, rather than what clients here watch and ask about. Not by default: a browser's device is a
   * partial replica, which has what it needs at once however big the space, and keeps no more than `keep` says of what
   * it no longer watches. A space needs a full replica somewhere that can read, to answer questions about all of it: a
   * zspd device, or a browser's opened with `full: true`. A store may be opened either way, and lose nothing.
   */
  full?: boolean;
  /** What a partial replica keeps of what it no longer watches: see NodeOptions. */
  keep?: { days?: number; bytes?: number } | false;
  /** Presented to relays, whose hosts decide by it whom they serve. */
  credential?: string | Uint8Array;
  /** Where the worker's script is, if not worker.js beside this one. */
  worker?: string | URL;
  /** Where node.wasm is, if not beside the worker's script. */
  wasm?: string | URL;
  /** Told if the node stops of itself, as when storage fails. */
  onFailure?: (error: Error) => void;
}

/** Opens this origin's device of that name, making it if there is none. */
export async function open(options: OpenOptions = {}): Promise<Device> {
  const name = storePath(options.name ?? "default");
  // The newest credential this tab has given, and when, which a worker it starts again is told: so that what it gave is
  // never taken for newer than what another tab gave since. By the clock workers judge it by.
  let credential = options.credential;
  let credentialAt = Date.now();
  let taken = false; // by a worker this tab started: given again to the next as it was, rather than anew
  // The worker: none while the tab is frozen or put away in the back/forward cache, for a frozen worker holds the store,
  // and every tab of the origin would wait for this one to come back. It is stopped as the tab is, for it cannot stop
  // itself in time, and that lets go of the store as a closed tab does; and it is started again when the tab is back.
  // Told first, it closes the store's files itself, having made durable what it holds, before it lets go of the store's
  // lock: Chrome runs what was sent a worker before it stops it, as it did every time this was measured, the tab frozen,
  // left, closed or reloaded, the worker busy or not, while a worker that is not stopped is frozen in the midst of whatever
  // it was doing, the store held. Stopped as it did it, the browser closes the files, and the next to open the store waits
  // for it to have (./volume-opfs.ts).
  let worker: Worker | undefined;
  let state: "running" | "away" | "closed" = "running";
  let asked = 0;
  const answers = new Map<number, { op: Op; args: unknown[]; resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  const pipes = new Map<() => void, () => void>(); // how to break each of this tab's pipes, and how to close it, saying so
  const ports: MessagePort[] = []; // pipes asked for while away
  let ticks = 0;
  const timers = new Map<number, { f: () => void; due: number }>(); // the tab's clients', kept by the worker
  let space: string | undefined;
  let closing: Promise<void> | undefined;
  let stopping = false; // nothing is due any more: the device's clients have delivered what they wrote, and it is closing
  // Its clients, every one made on its connect, device.client() or not: sealed as the tab is hidden or put away, and
  // closed, what they wrote delivered, as the device is. Held no longer than whoever made them holds them.
  const clients = new Set<WeakRef<Client>>();
  const each = (f: (c: Client) => void) => {
    for (const ref of [...clients]) {
      const c = ref.deref();
      if (c) f(c);
      else clients.delete(ref);
    }
  };

  // Of the worker as it is now: its storage failed, or the store is locked, as it last said, and it has answered nothing
  // since; and the worker that could not be started, or threw, which answers nothing it is asked. A worker started anew is
  // neither.
  let failed = false;
  let dead: Worker | undefined;
  let quitting: AbortController | undefined; // as the device closes: gives up on what its clients have still to deliver
  // Told that the node has stopped: whatever it was asked, its worker has answered already, before saying so; but a worker
  // that could not be started, or threw, answers nothing, and what was asked of it is said to have failed here: not done,
  // if it never started; but one that had may have been doing it, which is Uncertain, unless it may be asked again.
  const fail = (error: Error, threw = false, started = false) => {
    failed = true;
    quitting?.abort(); // what the device's clients deliver, as it closes, may never be: they give up on it, saying so
    if (threw) {
      const uncertain = new Uncertain(`${error.message}, as this was asked: it may or may not have been done`);
      for (const a of answers.values()) a.reject(started && !again.has(a.op) ? uncertain : error);
      answers.clear();
    }
    options.onFailure?.(error);
  };
  const start = () => {
    const w = (worker = new Worker(options.worker ?? new URL("./worker.js", import.meta.url), { type: "module", name: "zsp" }));
    failed = false;
    w.onerror = (e) => w === worker && ((dead = w), fail(new Error(e.message || "the worker could not be started"), true, heard));
    const giving = credential;
    let heard = false;
    w.onmessage = (e: MessageEvent<Report>) => {
      if (w !== worker) return; // one stopped as the tab went away: what was on its way from it is not so now
      // Anything it says, it says having been opened, and so having taken what it was given, if it is the tab's still.
      if (!heard) (heard = true), giving !== undefined && credential === giving && (taken = true);
      const r = e.data;
      if ("failed" in r) return fail(errorOf(r.failed, r.name));
      if ("space" in r) return void (space = r.space);
      if ("credentialAt" in r) return void (taken && (credentialAt = r.credentialAt)); // what this tab gave, given again as newer
      if ("due" in r) {
        const t = timers.get(r.due);
        timers.delete(r.due);
        return t?.f();
      }
      const a = answers.get(r.answer);
      answers.delete(r.answer);
      if (r.error !== undefined) a?.reject(errorOf(r.error, r.name));
      else {
        if (a && a.op !== "credential") failed = false; // done by a node: the store has come back, whatever failed before
        a?.resolve(r.value);
      }
    };
    w.postMessage({ open: { name, full: options.full, keep: options.keep, credential, credentialAt, credentialAgain: taken, wasm: options.wasm?.toString() } } satisfies Command);
    for (const [id, a] of answers) w.postMessage({ ask: id, op: a.op, args: a.args } satisfies Command);
    for (const port of ports.splice(0)) w.postMessage({ connect: port } satisfies Command, [port]);
    for (const [id, t] of timers) w.postMessage({ after: id, ms: Math.max(0, t.due - Date.now()) } satisfies Command);
  };
  const ask = <T>(op: Op, ...args: unknown[]): Promise<T> =>
    new Promise((resolve, reject) => {
      if (state === "closed") return reject(new Error("the device is closed"));
      answers.set(++asked, { op, args, resolve: resolve as (v: unknown) => void, reject });
      worker?.postMessage({ ask: asked, op, args } satisfies Command); // or once it is started again
    });
  // What may be asked again of the next worker, as having been done or not it is the same; anything else may have been
  // done, and is not done twice.
  const again = new Set<Op>(["identity", "member", "members", "usage"]);
  // Told to go, the worker is stopped then and there, unless something sent it is still to be had: then each pipe has been
  // closed, behind what it carried, and the worker goes itself once it has had all of that, made durable, every pipe closed;
  // for a worker stopped drops what is still on its way to it.
  const stop = (w = worker, drain = false) => {
    if (w === worker) worker = undefined;
    w?.postMessage({ away: true, ...(drain ? { drain: true as const } : {}) } satisfies Command);
    if (!drain) w?.terminate();
  };
  const away = () => {
    if (state !== "running") return;
    state = "away";
    quitting?.abort(); // closing, it can deliver nothing more now
    // Let go of first, before anything a client does as it is told its pipe is broken: a pipe dialled then waits for the
    // worker started once the tab is back, rather than reach this one, which would wait for it to be closed for ever.
    const w = worker;
    worker = undefined;
    // What editors have typed is sealed and sent now, whatever else is listening, for nothing after this is sure to be
    // run: each client keeps it till it is acknowledged, and says it again to the worker started when the tab is back.
    each((c) => c[sealNow]());
    let owed = false;
    each((c) => (owed ||= c[unacknowledged]()));
    if (owed) for (const close of [...pipes.values()]) close();
    stop(w, owed);
    for (const [id, a] of answers) {
      if (a.op === "close") answers.delete(id), a.resolve(undefined); // stopped, as a closed tab's is
      else if (a.op === "credential") answers.delete(id), a.resolve(undefined); // given anew by the next worker, not taken by this
      else if (!again.has(a.op)) answers.delete(id), a.reject(new Uncertain("the tab was put away as this was asked, which may or may not have been done"));
    }
    for (const breakOff of [...pipes.keys()]) breakOff(); // every client here dials again, once the tab is back
  };
  const back = () => {
    if (state !== "away") return;
    state = "running";
    start();
    void ask<{ space?: string }>("identity").then((i) => (space = i.space), () => {}); // what it may have become meanwhile
  };
  const hidden = () => away();
  const shown = (e: PageTransitionEvent) => e.persisted && back();
  // Hidden, a page may be frozen or thrown away later, unasked, with time now to make sure of what it has: what editors
  // have typed is sealed and sent, and the worker makes it durable, while the tab is still running.
  const unseen = () => {
    if (document.visibilityState === "hidden") each((c) => c[sealNow]());
  };
  const listening = typeof document !== "undefined" && typeof addEventListener === "function";
  const unlisten = () => {
    if (!listening) return;
    document.removeEventListener("freeze", hidden);
    document.removeEventListener("visibilitychange", unseen);
    document.removeEventListener("resume", back);
    removeEventListener("pagehide", hidden);
    removeEventListener("pageshow", shown);
  };
  if (listening) {
    document.addEventListener("freeze", hidden);
    document.addEventListener("visibilitychange", unseen);
    document.addEventListener("resume", back);
    addEventListener("pagehide", hidden);
    addEventListener("pageshow", shown);
  }
  start();
  let identity: { id: string; key: string; space?: string };
  try {
    identity = await ask("identity");
  } catch (e) {
    // Nobody has a device to close: the worker, and with it any lock or file it holds, is let go of here.
    unlisten();
    state = "closed";
    stop();
    throw e;
  }
  space ??= identity.space;

  // Timers kept by the worker, which a browser does not hold back while the tab is hidden as it holds back the tab's own:
  // a client here that seals what it types, or dials again, does so when it should though nobody is looking.
  const after = (ms: number, f: () => void): (() => void) => {
    if (stopping) return () => {}; // nothing is due on a device closing
    const id = ++ticks;
    timers.set(id, { f, due: Date.now() + ms });
    worker?.postMessage({ after: id, ms } satisfies Command);
    return () => {
      if (timers.delete(id)) worker?.postMessage({ cancel: id } satisfies Command);
    };
  };

  const connect: Connect & { [madeOn]?: (c: Client) => void } = (receive, closed) => {
    if (state === "closed") return undefined;
    const { port1, port2 } = new MessageChannel();
    let open = true;
    const end = () => {
      open = false;
      pipes.delete(breakOff);
      port1.close();
    };
    const breakOff = () => {
      if (!open) return;
      end();
      closed();
    };
    // Closed from this end, saying so to the worker behind all that was sent: its client told it is broken, all the same.
    const closeSaying = () => {
      if (!open) return;
      port1.postMessage({ close: true } satisfies Say);
      breakOff();
    };
    pipes.set(breakOff, closeSaying);
    port1.onmessage = (e: MessageEvent<Say>) => {
      const say = e.data;
      if (!open) return;
      if ("close" in say) breakOff();
      else if ("data" in say) {
        try {
          receive(say.data);
        } finally {
          port1.postMessage({ credit: say.data.length } satisfies Say); // dealt with, however it went
        }
      }
    };
    if (worker) worker.postMessage({ connect: port2 } satisfies Command, [port2]);
    else ports.push(port2);
    return {
      send: (data) => {
        // A copy, of its own, is handed over: what was given may be a view of something its giver goes on using.
        if (!open) return;
        const own = data.slice();
        port1.postMessage({ data: own } satisfies Say, [own.buffer]);
      },
      close: () => {
        if (!open) return;
        port1.postMessage({ close: true } satisfies Say);
        end();
      },
    };
  };

  connect[madeOn] = (c) => void clients.add(new WeakRef(c)); // every client made on it is this device's to see to

  return {
    id: identity.id,
    key: identity.key,
    get space() {
      return space;
    },
    join: async (s: string, relay: Relay) => {
      space = await ask<string>("join", s, relay);
    },
    adopt: async (roster: Uint8Array) => {
      const adopted = await ask<{ taken: boolean; space?: string }>("adopt", roster); // and the space it is of, with it
      space = adopted.space;
      return adopted.taken;
    },
    member: () => ask<boolean>("member"),
    create: async () => (space = await ask<string>("create")),
    scope: (signed?: boolean) => ask<number>("scope", signed),
    admit: (key: string, scope: number, rights?: Rights) => ask<void>("admit", key, scope, rights),
    revoke: (key: string, scope?: number) => ask<void>("revoke", key, scope),
    subject: (key: string, subject: string) => ask<void>("subject", key, subject),
    admin: (key: string, on?: boolean) => ask<void>("admin", key, on),
    owner: (key: string) => ask<void>("owner", key),
    relay: (key: string, url: string) => ask<void>("relay", key, url),
    members: () => ask<Member[]>("members"),
    usage: () => ask<{ held: number; memory: number }>("usage"),
    setCredential: async (c: string | Uint8Array) => {
      credential = c; // for whichever worker this tab starts next
      credentialAt = Date.now();
      taken = false;
      const at = await ask<number | undefined>("credential", c, credentialAt);
      if (at !== undefined && credential === c) (credentialAt = at), (taken = true); // as given: no earlier than any it knew of
    },
    connect,
    client: (host = {}) => new Client({ after, ...host, connect }),
    // Once, however often asked: its node stopped as it should be, and then its worker let go of.
    close: () =>
      (closing ??= handledClose(async () => {
        // Its clients first, what they wrote and their editors typed delivered, and durable, before the node is stopped. That
        // is given up on, each client saying how much it never delivered, should it be put away or fail meanwhile, or be
        // away, failed or of no space already, when nothing can be delivered.
        const quit = (quitting = new AbortController());
        if (state !== "running" || !worker || failed || space === undefined) quit.abort();
        const delivered: Promise<void>[] = [];
        each((c) => delivered.push(c.close({ signal: quit.signal })));
        const settled = await Promise.allSettled(delivered);
        // Nothing is due any more, though its worker said so before it heard: a client told so would dial again, or the
        // like, on a device going.
        stopping = true;
        timers.clear();
        // Listened for until it is closed: a tab frozen or left as its worker closes the store stops the worker then, as
        // ever, which would else be frozen holding it.
        const w = worker;
        if (w && state === "running" && w !== dead) await ask<void>("close").catch(() => {});
        unlisten();
        state = "closed";
        w?.terminate();
        worker = undefined;
        for (const breakOff of [...pipes.keys()]) breakOff(); // its clients told, as the worker that carried their pipes is gone
        for (const port of ports.splice(0)) port.close(); // dialled while away, for a worker that will never be
        // What was asked as it closed, and not answered, may have been done: Uncertain, but what may be asked again either way.
        for (const a of answers.values()) a.reject(again.has(a.op) ? new Error("the device is closed") : new Uncertain("the device was closed as this was asked, which may or may not have been done"));
        answers.clear();
        // Closed all the same: but what its clients never delivered is said, all of it, rather than nothing.
        const lost = settled.flatMap((r) => (r.status === "rejected" ? [r.reason as Error] : []));
        if (lost.length === 0) return;
        if (lost.every((e) => e instanceof Undelivered)) {
          const all = lost as Undelivered[];
          throw new Undelivered(all.reduce((n, e) => n + e.rows, 0), all.reduce((n, e) => n + e.cells, 0), all.reduce((n, e) => n + e.bytes, 0), true);
        }
        throw lost.find((e) => !(e instanceof Undelivered)) ?? lost[0];
      })),
  };
}
