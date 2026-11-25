// Real processes on real sockets: relays, zspd devices, and web devices, which are this very process's. Each way devices
// can meet runs test/live.ts: the TypeScript client against zspd as the Luau client is, and web devices against zspd
// devices through a relay of zspd's and through the Durable Object. `node test/end_to_end.ts [names...]`

import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "../src/client.ts";
import type { Connect, Wire } from "../src/node.ts";
import { open } from "../src/nodejs.ts";
import { live } from "./live.ts";

const ROOT = new URL("../../", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const BIN = process.env.ZSPD ?? join(ROOT, "build", process.platform === "win32" ? "zspd.exe" : "zspd");
const TMP = mkdtempSync(join(tmpdir(), "zsp-web-"));
const procs: ChildProcess[] = [];

const zspd = (...args: string[]) => execFileSync(BIN, args, { encoding: "utf8" }).trim();

interface Started {
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

function node(mode: "run" | "serve", dir: string, ...options: string[]): Promise<Started> {
  return started(spawn(BIN, [mode, dir, "--listen=127.0.0.1:0", "--no-udp", ...options], log(dir)), dir);
}

function cloud(env: Record<string, string> = {}): Promise<Started> {
  return started(spawn("node", [join(ROOT, "relay", "dev.mjs")], { ...log("cloud"), env: { ...process.env, ...env } }), "cloud");
}

// Pipes that can be broken, as a crash of the pipe breaks them.
class Pipes {
  #open = new Set<{ wire: Wire; closed: () => void }>();

  wrap(connect: Connect): Connect {
    return (receive, closed) => {
      const wire = connect(receive, closed);
      if (!wire) return undefined;
      const entry = { wire, closed };
      this.#open.add(entry);
      return {
        send: (data) => wire.send(data),
        close: () => {
          this.#open.delete(entry);
          wire.close();
        },
      };
    };
  }

  break(): void {
    for (const e of [...this.#open]) {
      this.#open.delete(e);
      e.wire.close();
      e.closed();
    }
  }
}

// A local client of zspd, over a WebSocket, as the Luau client is.
function zspdConnect(address: string): Connect {
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

const token = (dir: string) => readFileSync(join(dir, "token"), "utf8");
const exists = (path: string) => {
  try {
    readFileSync(path);
    return true;
  } catch {
    return false;
  }
};

async function eventually(what: string, f: () => boolean | Promise<boolean>, ms = 10000): Promise<void> {
  const until = Date.now() + ms;
  while (Date.now() < until) {
    if (await f()) return;
    await new Promise((done) => setTimeout(done, 20));
  }
  throw new Error("never: " + what);
}

// A space as live.ts wants it: scope 1, and scope 2 signed, in which b may vouch; a goes by "ann" and b by "bob".
async function space(name: string, relay: { key: string; url: string }, sides: ("zspd" | "web")[], options: string[] = [], relayCredential?: string) {
  const owner = join(TMP, name + "-owner");
  const sid = zspd("create", owner);
  zspd("relay", owner, relay.key, relay.url);
  expectEqual(zspd("scope", owner, "signed"), "2");
  const pipes = new Pipes();
  const clients: Client[] = [];
  const closers: (() => Promise<void>)[] = [];
  if (sides[0] === "web") {
    // The owner is zspd's, and runs only to tell the others who belongs.
    const n = await node("run", owner, ...options);
    closers.push(async () => void n.p.kill());
  }
  for (const [i, kind] of sides.entries()) {
    const subject = i === 0 ? "ann" : "bob";
    let key: string, connect: Connect, credential = "";
    if (kind === "zspd") {
      const dir = i === 0 ? owner : join(TMP, `${name}-${i}`);
      if (i > 0) {
        key = zspd("key", dir);
        zspd("admit", owner, key, "1");
        zspd("join", dir, sid, relay.key, relay.url);
      } else key = zspd("key", owner);
      const n = await node("run", dir, ...options);
      await eventually("it hears who belongs", () => exists(join(dir, sid, "roster")));
      connect = zspdConnect(n.address);
      credential = token(dir);
    } else {
      const d = await open({ dir: join(TMP, `${name}-${i}`), credential: relayCredential, log: (l, t) => l !== "debug" && console.error(`[web ${i}] ${l}: ${t}`) });
      key = d.key;
      zspd("admit", owner, key, "1");
      await d.join(sid, relay);
      connect = d.connect;
      closers.push(() => d.close());
    }
    if (i === 1) zspd("admit", owner, key, "2", "vouch");
    else if (kind === "web") zspd("admit", owner, key, "2");
    zspd("subject", owner, key, subject);
    clients.push(new Client({ connect: pipes.wrap(connect), credential, linger: 200 }));
  }
  return { a: clients[0], b: clients[1], breakPipes: () => pipes.break(), close: () => Promise.all(closers.map((f) => f())) };
}

function expectEqual(a: unknown, b: unknown): void {
  if (a !== b) throw new Error(`${a} is not ${b}`);
}

const tests: Record<string, () => Promise<void>> = {
  // The TypeScript client, of zspd, as the Luau client is: the same suite, the same answers.
  async zspd_clients() {
    const relay = await node("serve", join(TMP, "z-relay"));
    const s = await space("z", relay, ["zspd", "zspd"]);
    await live(s);
    await s.close();
  },
  // A web device reads what a zspd device writes, through zspd's relay.
  async web_reads() {
    const relay = await node("serve", join(TMP, "r-relay"));
    const s = await space("r", relay, ["zspd", "web"]);
    await live(s);
    await s.close();
  },
  // A web device writes what a zspd device reads, through the Durable Object.
  async web_writes_cloud() {
    const relay = await cloud({ ACCESS_TOKEN: "sesame" });
    const s = await space("c", relay, ["web", "zspd"], ["--credential=sesame"], "sesame");
    await live(s);
    await s.close();
  },
  // Two web devices, and nothing else but a relay.
  async web_and_web() {
    const relay = await node("serve", join(TMP, "w-relay"));
    const s = await space("w", relay, ["web", "web"]);
    await live(s);
    await s.close();
  },
};

async function main(): Promise<void> {
  const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : Object.keys(tests);
  let failed = 0;
  for (const name of names) {
    const start = performance.now();
    try {
      await tests[name]();
      console.log(`ok   ${name} ${((performance.now() - start) / 1000).toFixed(2)}s`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${e instanceof Error ? e.stack : e}\n     in ${TMP}`);
    } finally {
      for (const p of procs.splice(0)) p.kill();
    }
  }
  if (!failed) rmSync(TMP, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}

await main();
