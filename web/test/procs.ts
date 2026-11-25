// Processes for the tests: zspd devices and relays, and the Durable Object under workerd.

import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Connect } from "../src/node.ts";

export const ROOT = new URL("../../", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
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

export function cloud(env: Record<string, string> = {}): Promise<Started> {
  return started(spawn("node", [join(ROOT, "relay", "dev.mjs")], { ...log("cloud"), env: { ...process.env, ...env } }), "cloud");
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

