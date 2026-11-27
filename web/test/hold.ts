// A store's directory is one node's at a time, whoever's it is: a Node device's in this process or another, or zspd's.
// Whoever comes second is told the store is in use and touches nothing; the kernel lets go of it when its holder's
// process ends, however it ends. And a store on a file system shared with other machines is refused. See host/hold.odin.

import assert from "node:assert/strict";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { open } from "../src/nodejs.ts";
import { BIN, ROOT, node as zspdNode, procs, zspd } from "./procs.ts";

const TMP = mkdtempSync(join(tmpdir(), "zsp-hold-"));
const quiet = { udp: false as const, log: () => {} };
const IN_USE = /this store is in use by another process/;

// A Node device in a process of its own, holding a directory until killed: what it said of opening it.
function holder(dir: string): Promise<{ p: ChildProcess; said: string }> {
  const code = `import { open } from ${JSON.stringify(pathToFileURL(join(ROOT, "web/src/nodejs.ts")).href)};
try { await open({ dir: process.argv[1], udp: false, log: () => {} }); console.log("held"); }
catch (e) { console.log("refused: " + e.message); process.exit(3); }
setInterval(() => {}, 1 << 30);`;
  const p = spawn(process.execPath, ["--input-type=module", "-e", code, dir], { stdio: ["ignore", "pipe", "inherit"] });
  procs.push(p);
  return new Promise((done) => {
    let out = "";
    p.stdout!.on("data", (d) => {
      out += d;
      if (out.includes("\n")) done({ p, said: out.trim() });
    });
  });
}

const killed = (p: ChildProcess) => new Promise<void>((done) => (p.exitCode !== null || p.signalCode !== null ? done() : (p.once("exit", () => done()), p.kill("SIGKILL"))));

// In one process: a second device on the directory is refused, and the first goes on; once it is closed, another may.
{
  const dir = join(TMP, "one");
  const a = await open({ dir, ...quiet });
  await assert.rejects(open({ dir, ...quiet }), IN_USE);
  await a.create();
  assert.equal(a.space?.length, 64, "the first goes on");
  const key = a.key;
  await a.close();
  const b = await open({ dir, ...quiet });
  assert.equal(b.key, key, "the same device, as it was");
  await b.close();
  if (process.platform !== "win32") {
    assert.equal(statSync(join(dir, "lock")).mode & 0o777, 0o600, "the lock file can be held by others, and so the store kept from its own");
  }
}

// In another: refused while this one holds it; and holding it until killed, after which this one may at once.
{
  const dir = join(TMP, "two");
  const a = await open({ dir, ...quiet });
  const refused = await holder(dir);
  assert.match(refused.said, IN_USE);
  await a.close();
  const other = await holder(dir);
  assert.equal(other.said, "held");
  await assert.rejects(open({ dir, ...quiet }), IN_USE);
  await killed(other.p); // never politely
  const again = await open({ dir, ...quiet });
  await again.close();
}

// Beside zspd: neither opens a directory the other holds, nor a space's directory within zspd's, where its store is.
{
  const dir = join(TMP, "zspd");
  const space = zspd("create", dir);
  const running = await zspdNode("run", dir);
  await assert.rejects(open({ dir, ...quiet }), IN_USE);
  await assert.rejects(open({ dir: join(dir, space), ...quiet }), IN_USE);
  const address = readFileSync(join(dir, "address"), "utf8");
  await killed(running.p);
  const d = await open({ dir: join(TMP, "node"), ...quiet });
  const p = spawnSync(BIN, ["run", join(TMP, "node"), "--listen=127.0.0.1:0", "--no-udp"], { encoding: "utf8", timeout: 30000 });
  assert.equal(p.status, 1, p.stderr);
  assert.match(p.stderr, IN_USE);
  assert(!existsSync(join(TMP, "node", "address")), "zspd said where it listens in a directory it was refused");
  await d.close();
  assert.equal(readFileSync(join(dir, "address"), "utf8"), address);
}

// A directory on a file system shared with other machines: refused, with nothing made there.
if (process.platform === "win32") {
  // This machine's own drive, through its own share of it, as another machine's share would be.
  const share = `\\\\localhost\\${TMP[0]}$${TMP.slice(2)}\\shared`;
  assert(existsSync(share.slice(0, share.lastIndexOf("\\"))), `${share} cannot be reached`);
  await assert.rejects(open({ dir: share, ...quiet }), /shared with other machines \(a network share\)/);
  assert(!existsSync(share), "something was made there");
} else if (process.platform === "darwin") {
  // What the automounter keeps, which the system does not call local, as it calls NFS, SMB and AFP not.
  await assert.rejects(open({ dir: "/System/Volumes/Data/home/zsp-hold", ...quiet }), /shared with other machines \(autofs\)/);
}

rmSync(TMP, { recursive: true, force: true });
for (const p of procs) p.kill();
console.log("hold: ok");
