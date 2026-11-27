// Processes for the tests: zspd devices and relays, and the Durable Object under workerd.

import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Connect } from "../src/node.ts";

export const ROOT = fileURLToPath(new URL("../../", import.meta.url));
export const BIN = process.env.ZSPD ?? join(ROOT, "build", process.platform === "win32" ? "zspd.exe" : "zspd");
export const TMP = mkdtempSync(join(tmpdir(), "zsp-web-"));
export const procs: ChildProcess[] = [];

export const zspd = (...args: string[]) => execFileSync(BIN, args, { encoding: "utf8" }).trim();

export interface Started {
  key: string;
  address: string;
  url: string;
  p: ChildProcess;
}

function started(p: ChildProcess, name: string): Promise<Started> {
  procs.push(p);
  return new Promise((resolve, reject) => {
    let out = "";
    p.stdout!.on("data", (d) => {
      out += d;
      const m = /(\w{64}) listening on ws:\/\/(\S+)/.exec(out);
      if (m) resolve({ key: m[1], address: m[2], url: "ws://127.0.0.1:" + m[2].split(":").pop(), p });
    });
    p.on("exit", (code) => reject(new Error(`${name} exited with ${code}`)));
  });
}

const log = (name: string) => ({ stdio: ["ignore", "pipe", "ignore"] as ["ignore", "pipe", "ignore"], name });

export function node(mode: "run" | "serve", dir: string, ...options: string[]): Promise<Started> {
  return started(spawn(BIN, [mode, dir, "--listen=127.0.0.1:0", "--no-udp", ...options], log(dir)), dir);
}

// The Durable Object under workerd here; or, with CLOUD=wss://…, one deployed, which every test that asks for one shares
// (each makes a space of its own). What the test asks to be set is set here, and cannot be there.
export async function cloud(env: Record<string, string> = {}): Promise<Started> {
  const remote = process.env.CLOUD;
  if (remote) {
    if (Object.keys(env).length > 0) throw new Error(`a relay deployed at ${remote} cannot be run with ${Object.keys(env).join(", ")} set`);
    const at = new URL(remote.replace(/^ws/, "http"));
    const key = (await (await fetch(at)).text()).trim();
    if (!/^[0-9a-f]{64}$/.test(key)) throw new Error(`${remote} says it is ${JSON.stringify(key.slice(0, 80))}, not a relay's key`);
    const p = spawn(process.execPath, ["-e", "setInterval(() => {}, 1 << 30)"], { stdio: "ignore" }); // stands for it: stopped as a relay here would be
    procs.push(p);
    return { key, address: at.host, url: remote.replace(/\/$/, ""), p };
  }
  return started(spawn(process.execPath, [join(ROOT, "relay", "dev.mjs")], { ...log("cloud"), env: { ...process.env, ...env } }), "cloud");
}

export const token = (dir: string) => readFileSync(join(dir, "token"), "utf8");
export const exists = (path: string) => {
  try {
    readFileSync(path);
    return true;
  } catch {
    return false;
  }
};

export async function eventually(what: string, f: () => boolean | Promise<boolean>, ms = 10000): Promise<void> {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    if (await f()) return;
    await new Promise((done) => setTimeout(done, 20));
  }
  throw new Error("never: " + what);
}

export function expectEqual(a: unknown, b: unknown): void {
  if (a !== b) throw new Error(`${a} is not ${b}`);
}

// A local client of zspd, over a WebSocket, as the Luau client is.
export function zspdConnect(address: string): Connect {
  return (receive, closed) => {
    const ws = new WebSocket("ws://" + address + "/");
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
    return {
      send: (data) => (ws.readyState === 1 ? ws.send(data.slice()) : early.push(data.slice())),
      close: () => ws.close(),
    };
  };
}


/** A TCP proxy to a relay, which counts connections and can swallow whatever is said on those it has, saying nothing. */
/**
 * A proxy to a relay, which can swallow what its connections say, cut them and refuse more until mended, and carry no more
 * than so many bytes a second each way, each after so many milliseconds, as a slow network does.
 */
export async function proxy(
  to: string,
  slow?: { bytesPerSecond: number; latency: number },
): Promise<{ url: string; connections: () => number; live: () => number; swallow: () => void; cut: () => void; mend: () => void }> {
  const { createServer, connect } = await import("node:net");
  const target = new URL(to.replace(/^ws/, "http"));
  // To a relay over TLS, as a deployed one is: what comes here plain goes there sealed, and says it is for that host.
  const secure = target.protocol === "https:";
  const { connect: connectTls } = await import("node:tls");
  const dial = () =>
    secure ? connectTls({ host: target.hostname, port: Number(target.port || 443), servername: target.hostname }) : connect(Number(target.port), target.hostname);
  const live = new Set<{ swallowed: boolean; end: () => void }>();
  let count = 0;
  let down = false;
  // Each way of each connection is a line: what is sent goes once all before it has, at the rate allowed, and arrives later.
  // And, as TCP's window does, so much at most is on its way at once: the sender waits while it is, rather than having
  // all it has to say taken from it at once, and held here.
  const WINDOW = 1 << 20;
  const carry = (from: import("node:net").Socket, into: import("node:net").Socket, state: { swallowed: boolean }) => {
    let held = 0;
    const sent = (n: number) => {
      held -= n;
      if (held <= WINDOW && from.isPaused()) from.resume();
    };
    const holding = (n: number) => {
      held += n;
      if (held > WINDOW) from.pause();
    };
    if (!slow)
      return (d: Buffer) => {
        if (state.swallowed) return;
        holding(d.length);
        into.write(d, () => sent(d.length));
      };
    let free = 0;
    return (d: Buffer) => {
      const now = performance.now();
      free = Math.max(free, now) + (d.length / slow.bytesPerSecond) * 1000;
      holding(d.length);
      setTimeout(() => (state.swallowed || into.destroyed ? sent(d.length) : into.write(d, () => sent(d.length))), free - now + slow.latency);
    };
  };
  const server = createServer((from) => {
    if (down) return void from.destroy();
    // Counted if it asks for a WebSocket: something on the machine may look at any port that opens, as some do.
    from.once("data", (d) => /^GET [^\r]*\r\n(?:[^\r]*\r\n)*upgrade: *websocket/im.test(d.subarray(0, 2048).toString("latin1")) && count++);
    const there = dial();
    const state = { swallowed: false, end: () => {} };
    const end = () => (live.delete(state), from.destroy(), there.destroy());
    state.end = end;
    live.add(state);
    const toThere = carry(from, there, state);
    let head: Buffer | undefined = secure ? Buffer.alloc(0) : undefined; // the request, until it has all come
    from.on("data", (d: Buffer) => {
      if (head) {
        head = Buffer.concat([head, d]);
        const end = head.indexOf("\r\n\r\n");
        if (end < 0) return;
        const said = head.subarray(0, end).toString("latin1").replace(/^host:.*$/im, `Host: ${target.host}`);
        (d = Buffer.concat([Buffer.from(said, "latin1"), head.subarray(end)])), (head = undefined);
      }
      toThere(d);
    });
    there.on("data", carry(there, from, state));
    from.on("close", end).on("error", end);
    there.on("close", end).on("error", end);
  });
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  const port = (server.address() as { port: number }).port;
  return {
    url: `ws://127.0.0.1:${port}`,
    connections: () => count,
    live: () => live.size,
    swallow: () => live.forEach((s) => (s.swallowed = true)),
    cut: () => ((down = true), [...live].forEach((s) => s.end())),
    mend: () => void (down = false),
  };
}

/** Stops every process started, once each has gone. */
export async function stopAll(): Promise<void> {
  const going = procs.splice(0).map((p) => (p.exitCode !== null || p.signalCode !== null ? Promise.resolve() : new Promise<void>((done) => (p.once("exit", () => done()), p.kill()))));
  await Promise.all(going);
}

/** Removes what the tests kept, waiting out a system that lets go of files a little after their process has gone, as Windows does. */
export async function cleanUp(): Promise<void> {
  await stopAll();
  rmSync(TMP, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
}
