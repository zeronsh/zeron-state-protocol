// What a test page has, for test/browsers.ts to drive: devices of this origin, and the live suite.

import { open, Client, columns, type Device, type State } from "../src/browser.ts";
import type { Connect, Wire } from "../src/node.ts";
import { live } from "./live.ts";

const devices = new Map<string, Device>();

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

const zsp = {
  /** Opens this origin's device of a name; says its key. */
  async device(name: string, credential?: string): Promise<{ id: string; key: string; space?: string }> {
    const d = await open({ name, credential });
    devices.set(name, d);
    return { id: d.id, key: d.key, space: d.space };
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
