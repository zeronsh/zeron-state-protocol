// What a test page has, for test/browsers.ts to drive: devices of this origin, and the live suite.

import { open, Client, columns, type Device, type State } from "../src/browser.ts";
import type { Connect, Wire } from "../src/node.ts";
import { live } from "./live.ts";

const devices = new Map<string, Device>();
const failures: string[] = []; // what this tab was told of nodes that stopped
const asked: string[] = []; // what came of what was asked and not waited for

// Pipes that can be broken, as a crash of the pipe breaks them.
const pipes = new Set<{ wire: Wire; closed: () => void }>();
function breakable(connect: Connect): Connect {
  return (receive, closed) => {
    const wire = connect(receive, closed);
    if (!wire) return undefined;
    const entry = { wire, closed };
    pipes.add(entry);
    return {
      send: (data) => wire.send(data),
      close: () => {
        pipes.delete(entry);
        wire.close();
      },
    };
  };
}

// A local client of a zspd device, through what test/browsers.ts puts between: zspd hears from no web page.
function bridged(url: string): Connect {
  return (receive, closed) => {
    const ws = new WebSocket(url);
    ws.binaryType = "arraybuffer";
    const early: Uint8Array[] = [];
    let gone = false;
    ws.onopen = () => {
      for (const d of early.splice(0)) ws.send(d.slice());
    };
    ws.onmessage = (e) => receive(new Uint8Array(e.data as ArrayBuffer));
    ws.onclose = ws.onerror = () => {
      if (!gone) (gone = true), closed();
    };
    return { send: (data) => (ws.readyState === 1 ? ws.send(data.slice()) : early.push(data.slice())), close: () => ws.close() };
  };
}

export type Side = { device: string } | { bridge: string; token: string };

const Note = { title: columns.string(16) };
const clients = new Map<string, Client>();
const clientOf = (name: string) => {
  let c = clients.get(name);
  if (!c) clients.set(name, (c = new Client({ connect: devices.get(name)!.connect, linger: 200 })));
  return c;
};
const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));
const windows = new Map<string, { state?: State<typeof Note>; stop: () => void }>();

const zsp = {
  /** Opens this origin's device of a name; says its key. */
  async device(name: string, credential?: string, full?: boolean): Promise<{ id: string; key: string; space?: string }> {
    const d = await open({ name, credential, full, onFailure: (e) => failures.push(e.message) });
    devices.set(name, d);
    return { id: d.id, key: d.key, space: d.space };
  },
  /** The same, with its node found at that URL, should this tab's worker come to run it. */
  async deviceWith(name: string, wasm: string): Promise<void> {
    devices.set(name, await open({ name, wasm: new URL(wasm, location.href), onFailure: (e) => failures.push(e.message) }));
  },
  async join(name: string, space: string, relay: { key: string; url: string }): Promise<void> {
    await devices.get(name)!.join(space, relay);
  },
  async member(name: string): Promise<boolean> {
    return devices.get(name)!.member();
  },
  async close(name: string): Promise<void> {
    clients.get(name)?.close();
    clients.delete(name);
    await devices.get(name)?.close();
    devices.delete(name);
  },
  /** Answers a method of scope 1 with a word, through this tab's client of a device. */
  async serve(name: string, method: string, word: string): Promise<void> {
    const c = clientOf(name);
    for (let i = 0; i < 1000 && !c.may(1, "call"); i++) await sleep(10);
    c.serve(1, method, (call) => (call.send(word), call.finish()));
    await sleep(100); // said to the node
  },
  /** Calls a method of scope 1 on this very device: its answer, "fault …", or "nothing" if there was none in time. */
  async request(name: string, method: string, ms: number): Promise<string> {
    const c = clientOf(name);
    for (let i = 0; i < 1000 && !(c.may(1, "call") && c.me()); i++) await sleep(10);
    const answer = c.request(c.me()!.id, 1, method).then(
      (b) => new TextDecoder().decode(b),
      (e: { fault: string }) => "fault " + e.fault,
    );
    return Promise.race([answer, sleep(ms).then(() => "nothing")]);
  },
  /** What this tab has been told of nodes that stopped. */
  async failures(): Promise<string[]> {
    return failures;
  },
  /** Whether the device is a member, or what went wrong in asking. */
  async memberOrError(name: string): Promise<string> {
    return devices.get(name)!.member().then(String, (e: Error) => "error: " + e.message);
  },
  /** The space this tab's device says it is of, as it knows it now. */
  async spaceOf(name: string): Promise<string | undefined> {
    return devices.get(name)!.space;
  },
  async adopt(name: string, roster: number[]): Promise<boolean> {
    return devices.get(name)!.adopt(Uint8Array.from(roster));
  },
  /** Adds a scope: its number, or what went wrong. */
  async scopeOrError(name: string): Promise<string> {
    return devices.get(name)!.scope().then(String, (e: Error) => "error: " + e.message);
  },
  /** Asks for a scope and does not wait: what came of it is kept, to be had by `asked`. */
  async scopeLater(name: string): Promise<void> {
    void devices.get(name)!.scope().then(
      (n) => asked.push(String(n)),
      (e: Error) => asked.push("error: " + e.message),
    );
  },
  async asked(): Promise<string[]> {
    return asked;
  },
  async create(name: string): Promise<string> {
    return devices.get(name)!.create();
  },
  /** Writes a note of so many bytes; its durability is not waited for. */
  async putLarge(name: string, list: string, size: number): Promise<void> {
    const c = clientOf(name);
    void c.write(1, (change) => change.insert({ v: columns.bytes(16) }, list, Date.now(), { v: new Uint8Array(size).fill(7) }));
  },
  /** Sends a hello down a pipe of one's own as a view of a larger buffer, as a caller may: whether that buffer is intact. */
  async sendView(name: string): Promise<string> {
    const big = new ArrayBuffer(1024);
    const hello = new Uint8Array(big, 100, 38);
    hello.set([37, 1, 1, 4]);
    let closed = false;
    const wire = devices.get(name)!.connect(() => {}, () => (closed = true))!;
    try {
      wire.send(hello);
    } catch (e) {
      return "threw: " + (e as Error).message;
    }
    await sleep(50);
    wire.close();
    return big.byteLength === 1024 && !closed ? "intact" : "detached";
  },
  /** Opens a window on a list of scope 1, of so many at its end, or its start, and keeps it until `unwatch`. */
  async watch(name: string, list: string, size: number, from?: "start"): Promise<void> {
    const w = { state: undefined as State<typeof Note> | undefined, stop: () => {} };
    w.stop = clientOf(name).window({ scope: 1, list, table: Note, size, from }, (s) => (w.state = s)).stop;
    windows.set(`${name}/${list}/${from ?? ""}`, w);
  },
  /** What such a window shows now. */
  async seen(name: string, list: string, from?: "start"): Promise<{ titles: string[]; status: string; before: number; after: number } | undefined> {
    const st = windows.get(`${name}/${list}/${from ?? ""}`)?.state;
    return st && { titles: st.rows.map((r) => r.title ?? ""), status: st.status, before: st.before, after: st.after };
  },
  async unwatch(name: string, list: string, from?: "start"): Promise<void> {
    windows.get(`${name}/${list}/${from ?? ""}`)?.stop();
    windows.delete(`${name}/${list}/${from ?? ""}`);
  },
  async held(name: string): Promise<number> {
    return devices.get(name)!.held();
  },
  /** Writes notes to a list of scope 1, and resolves once they are durable on the device. */
  async put(name: string, list: string, titles: string[]): Promise<void> {
    const c = clientOf(name);
    for (let i = 0; i < 1000 && !c.may(1, "write"); i++) await sleep(10);
    await c.write(1, (change) => titles.forEach((title, i) => change.insert(Note, list, Date.now() * 1000 + i, { title })));
  },
  /** The titles of a list of scope 1 once there are at least so many, in order; or what there are after a while. */
  async titles(name: string, list: string, least: number): Promise<string[]> {
    let state: State<typeof Note> | undefined;
    const w = clientOf(name).window({ scope: 1, list, table: Note, size: 1000 }, (s) => (state = s));
    for (let i = 0; i < 1000 && !(state && state.status !== "loading" && state.rows.length >= least); i++) await sleep(10);
    w.stop();
    return state ? state.rows.map((r) => r.title ?? "") : [];
  },
  /** What a device costs here: each figure the median of many. Its owner admits it, by `admit`, between the two halves. */
  async benchOpen(name: string): Promise<{ key: string; opened: number }> {
    const t = performance.now();
    const d = await open({ name });
    devices.set(name, d);
    return { key: d.key, opened: performance.now() - t };
  },
  async benchRun(name: string, rows: number, other?: string): Promise<Record<string, number>> {
    const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
    const M = { author: columns.string(16), body: columns.text(17), stars: columns.number(18) };
    const c = clientOf(name);
    for (let i = 0; i < 2000 && !c.may(1, "write"); i++) await sleep(5);
    const writes: number[] = [];
    for (let i = 0; i < 100; i++) {
      const t = performance.now();
      await c.write(1, (ch) => ch.insert(M, "chat", i, { author: "wing", stars: i }));
      writes.push(performance.now() - t);
    }
    let t = performance.now();
    const all: Promise<void>[] = [];
    for (let i = 0; i < rows; i += 1000)
      all.push(c.write(1, (ch) => {
        for (let k = i; k < i + 1000 && k < rows; k++) ch.insert(M, "big", k, { author: "author " + (k % 100), stars: k, body: "the quick brown fox " + k });
      }));
    await Promise.all(all);
    const bulk = performance.now() - t;
    const pages: number[] = [];
    for (let i = 0; i < 20; i++) {
      const fresh = new Client({ connect: devices.get(name)!.connect });
      while (!fresh.ready) await sleep(0);
      t = performance.now();
      await new Promise<void>((done) => {
        const w = fresh.window({ scope: 1, list: "big", table: M, size: 50 }, (st) => {
          if (st.status === "ready" && st.rows.length === 50) (pages.push(performance.now() - t), w.stop(), done());
        });
      });
      fresh.close();
    }
    let id = "";
    await c.write(1, (ch) => (id = ch.insert(M, "tokens", 1, {})));
    const reader = new Client({ connect: devices.get(name)!.connect });
    const far = other ? new Client({ connect: devices.get(other)!.connect }) : undefined;
    let there = "";
    far?.window({ scope: 1, list: "tokens", table: M }, (st) => (there = st.rows[0]?.body ?? ""));
    let shown = "";
    reader.window({ scope: 1, list: "tokens", table: M }, (st) => (shown = st.rows[0]?.body ?? ""));
    for (let i = 0; i < 2000 && !reader.ready; i++) await sleep(1);
    await sleep(100);
    const editor = c.text(id, M.body);
    const tokens: number[] = [];
    let said = "";
    const turn = () => new Promise<void>((done) => { const ch = new MessageChannel(); ch.port1.onmessage = () => done(); ch.port2.postMessage(0); });
    for (let i = 0; i < 200; i++) {
      said += `token${i} `;
      t = performance.now();
      editor.append(`token${i} `);
      while (shown !== said) await turn();
      tokens.push(performance.now() - t);
    }
    const across: number[] = [];
    if (far) {
      for (let i = 0; i < 2000 && there !== said; i++) await sleep(5);
      for (let i = 0; i < 200; i++) {
        said += `far${i} `;
        t = performance.now();
        editor.append(`far${i} `);
        while (there !== said) await turn();
        across.push(performance.now() - t);
      }
      far.close();
    }
    editor.close();
    reader.close();
    return { write: median(writes), bulk, page: median(pages), token: median(tokens), across: far ? median(across) : NaN };
  },
  /** Runs the live suite with a and b as said. */
  async live(a: Side, b: Side): Promise<string> {
    const lines: string[] = [];
    const client = (s: Side) =>
      "device" in s
        ? new Client({ connect: breakable(devices.get(s.device)!.connect), linger: 200 })
        : new Client({ connect: breakable(bridged(s.bridge)), credential: s.token, linger: 200 });
    const ca = client(a), cb = client(b);
    try {
      await live({
        a: ca,
        b: cb,
        breakPipes: () => {
          for (const e of [...pipes]) pipes.delete(e), e.wire.close(), e.closed();
        },
        say: (line) => lines.push(line),
      });
    } finally {
      ca.close();
      cb.close();
    }
    return lines.join("\n");
  },
};

declare global {
  interface Window {
    zsp: typeof zsp;
  }
}
window.zsp = zsp;
