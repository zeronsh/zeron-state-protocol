// A device in a browser. Its node runs in a worker, where its store, a directory of the origin's private file system,
// may be read and written synchronously; tabs of one origin share it, whichever of them happens to run it (./worker.ts).

import { Client } from "./client.ts";
import type { Device, Relay } from "./index.ts";
import type { Connect, Member, Rights } from "./node.ts";
import type { Command, Op, Report, Say } from "./worker.ts";

export * from "./index.ts";

export interface OpenOptions {
  /** Which store: one device each, shared by the origin's tabs. "default" unless said. */
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
  const name = options.name ?? "default";
  // The newest credential this tab has given, and when, which a worker it starts again is told: so that what it gave is
  // never taken for newer than what another tab gave since. By the clock workers judge it by.
  let credential = options.credential;
  let credentialAt = Date.now();
  let taken = false; // by a worker this tab started: given again to the next as it was, rather than anew
  // The worker: none while the tab is frozen or put away in the back/forward cache, for a frozen worker holds the store,
  // and every tab of the origin would wait for this one to come back. It is stopped as the tab is, for it cannot stop
  // itself in time, and that lets go of the store as a closed tab does; and it is started again when the tab is back.
  let worker: Worker | undefined;
  let state: "running" | "away" | "closed" = "running";
  let asked = 0;
  const answers = new Map<number, { op: Op; args: unknown[]; resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  const pipes = new Set<() => void>(); // how to break each of this tab's pipes
  const ports: MessagePort[] = []; // pipes asked for while away
  let ticks = 0;
  const timers = new Map<number, { f: () => void; due: number }>(); // the tab's clients', kept by the worker
  let space: string | undefined;
  let closing: Promise<void> | undefined;

  const fail = (error: Error) => {
    for (const a of answers.values()) a.reject(error);
    answers.clear();
    options.onFailure?.(error);
  };
  const start = () => {
    const w = (worker = new Worker(options.worker ?? new URL("./worker.js", import.meta.url), { type: "module", name: "zsp" }));
    w.onerror = (e) => w === worker && fail(new Error(e.message || "the worker could not be started"));
    const giving = credential;
    let heard = false;
    w.onmessage = (e: MessageEvent<Report>) => {
      if (w !== worker) return; // one stopped as the tab went away: what was on its way from it is not so now
      // Anything it says, it says having been opened, and so having taken what it was given, if it is the tab's still.
      if (!heard) (heard = true), giving !== undefined && credential === giving && (taken = true);
      const r = e.data;
      if ("failed" in r) return fail(new Error(r.failed));
      if ("space" in r) return void (space = r.space);
      if ("credentialAt" in r) return void (taken && (credentialAt = r.credentialAt)); // what this tab gave, given again as newer
      if ("due" in r) {
        const t = timers.get(r.due);
        timers.delete(r.due);
        return t?.f();
      }
      const a = answers.get(r.answer);
      answers.delete(r.answer);
      if (r.error !== undefined) a?.reject(new Error(r.error));
      else a?.resolve(r.value);
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
  const away = () => {
    if (state !== "running") return;
    state = "away";
    worker?.terminate();
    worker = undefined;
    for (const [id, a] of answers) {
      if (a.op === "close") answers.delete(id), a.resolve(undefined); // stopped, as a closed tab's is
      else if (a.op === "credential") answers.delete(id), a.resolve(undefined); // given anew by the next worker, not taken by this
      else if (!again.has(a.op)) answers.delete(id), a.reject(new Error("the tab was put away as this was asked, which may or may not have been done"));
    }
    for (const breakOff of [...pipes]) breakOff(); // every client here dials again, once the tab is back
  };
  const back = () => {
    if (state !== "away") return;
    state = "running";
    start();
    void ask<{ space?: string }>("identity").then((i) => (space = i.space), () => {}); // what it may have become meanwhile
  };
  const hidden = () => away();
  const shown = (e: PageTransitionEvent) => e.persisted && back();
  const listening = typeof document !== "undefined" && typeof addEventListener === "function";
  if (listening) {
    document.addEventListener("freeze", hidden);
    document.addEventListener("resume", back);
    addEventListener("pagehide", hidden);
    addEventListener("pageshow", shown);
  }
  start();
  const identity = await ask<{ id: string; key: string; space?: string }>("identity");
  space ??= identity.space;

  // Timers kept by the worker, which a browser does not hold back while the tab is hidden as it holds back the tab's own:
  // a client here that seals what it types, or dials again, does so when it should though nobody is looking.
  const after = (ms: number, f: () => void): (() => void) => {
    const id = ++ticks;
    timers.set(id, { f, due: Date.now() + ms });
    worker?.postMessage({ after: id, ms } satisfies Command);
    return () => {
      if (timers.delete(id)) worker?.postMessage({ cancel: id } satisfies Command);
    };
  };

  const connect: Connect = (receive, closed) => {
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
    pipes.add(breakOff);
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
      const taken = await ask<boolean>("adopt", roster);
      space = (await ask<{ space?: string }>("identity")).space;
      return taken;
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
      (closing ??= (async () => {
        if (listening) {
          document.removeEventListener("freeze", hidden);
          document.removeEventListener("resume", back);
          removeEventListener("pagehide", hidden);
          removeEventListener("pageshow", shown);
        }
        const w = worker;
        if (w && state === "running") await ask<void>("close").catch(() => {});
        state = "closed";
        w?.terminate();
        worker = undefined;
        for (const breakOff of [...pipes]) breakOff(); // its clients told, as the worker that carried their pipes is gone
        for (const a of answers.values()) a.reject(new Error("the device is closed"));
        answers.clear();
        timers.clear();
      })()),
  };
}
