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
  credential?: string | Uint8Array;
  /** Where node.wasm is, if not beside this script. */
  wasm?: string;
}

/** What a tab tells its worker. */
export type Command = { open: Options } | { connect: MessagePort } | { ask: number; op: Op; args: unknown[] };

/** What a device can be asked to do, by whichever tab. */
export type Op = "identity" | "join" | "adopt" | "member" | "create" | "scope" | "admit" | "revoke" | "subject" | "admin" | "owner" | "relay" | "members";

/** What a worker tells its tab. */
export type Report = { answer: number; value?: unknown; error?: string } | { failed: string };

// Between workers, on the store's channel.
type Shout =
  | { leader: true } // a worker has opened the store: whatever was carried to another is broken
  | { open: string } // a pipe, on the channel of that name
  | { ask: string; op: Op; args: unknown[] }
  | { answer: string; value?: unknown; error?: string };

/** On a pipe: from its client's end, data and credit; from the node's, data. Either may close it. */
export type Say = { data: Uint8Array } | { credit: number } | { close: true };

let device: Node | undefined;
let channel: BroadcastChannel;
const carried = new Set<() => void>(); // pipes carried to the leader: how to break each
const waiting = new Map<string, (answer: { value?: unknown; error?: string }) => void>();
const unheard = new Map<string, Shout>(); // said to the leader, and not yet answered

self.onmessage = async (e: MessageEvent<Command>) => {
  const c = e.data;
  if ("open" in c) open(c.open);
  else if ("connect" in c) connect(c.connect);
  else if ("ask" in c) self.postMessage({ answer: c.ask, ...(await ask(c.op, c.args)) } satisfies Report);
};

function open(o: Options): void {
  channel = new BroadcastChannel("zsp:" + o.name);
  channel.onmessage = (e: MessageEvent<Shout>) => heard(e.data);
  // Whoever holds this runs the node, for as long as its tab lives.
  void navigator.locks.request("zsp:" + o.name, async () => {
    try {
      const volume = await OpfsVolume.at("zsp/" + o.name);
      const module = await loadModule(o.wasm ? new URL(o.wasm, self.location.href) : undefined);
      device = await Node.open({ volume, module, full: o.full, credential: o.credential });
      device.onFailure = (error) => self.postMessage({ failed: error.message } satisfies Report);
    } catch (error) {
      self.postMessage({ failed: String(error) } satisfies Report);
      return;
    }
    breakCarried();
    channel.postMessage({ leader: true } satisfies Shout);
    // What this worker itself was waiting to hear, it now answers.
    for (const [id, s] of unheard) if ("ask" in s) heard({ answer: id, ...answer(s.op, s.args) });
    await new Promise(() => {}); // held until the worker is gone
  });
}

function breakCarried(): void {
  for (const breakOff of [...carried]) breakOff();
}

// ---------------------------------------------------------------- the device, for any tab

async function ask(op: Op, args: unknown[]): Promise<{ value?: unknown; error?: string }> {
  if (device) return answer(op, args);
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
        return { value: d.space };
      case "adopt":
        return { value: d.adopt(args[0] as Uint8Array) };
      case "member":
        return { value: d.member };
      case "create":
        return { value: d.create() };
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
    }
  } catch (e) {
    return { error: e instanceof Error ? e.message : String(e) };
  }
}

// Says something to the leader, and again to every new one until it is answered: one opening its store hears nothing.
function shout(id: string, s: Shout): void {
  unheard.set(id, s);
  channel.postMessage(s);
}

function heard(s: Shout): void {
  if ("leader" in s) {
    breakCarried(); // to one that is gone
    for (const u of unheard.values()) if (!("open" in u)) channel.postMessage(u);
  } else if ("answer" in s) {
    const done = waiting.get(s.answer);
    unheard.delete(s.answer);
    waiting.delete(s.answer);
    done?.({ value: s.value, error: s.error });
  } else if (device && "ask" in s) {
    channel.postMessage({ answer: s.ask, ...answer(s.op, s.args) } satisfies Shout);
  } else if (device && "open" in s) {
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
  // The leader may not be listening on the pipe's own channel until it says so: until then what the tab says waits here.
  const name = channel.name + ":" + crypto.randomUUID();
  const far = new BroadcastChannel(name);
  let heardBack = false;
  const early: Say[] = [];
  let open = true;
  // Held for as long as the pipe is: the leader waits for it, and so learns when this end has gone, tab and all.
  let letGo!: () => void;
  const held = new Promise<void>((done) => (letGo = done));
  const breakOff = () => {
    if (!open) return;
    open = false;
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
      unheard.delete(name);
      for (const s of early.splice(0)) far.postMessage(s);
    }
    if ("close" in say) breakOff();
    else if ("data" in say) toTab(say);
  };
  void navigator.locks.request(name, () => {
    if (open) shout(name, { open: name });
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
