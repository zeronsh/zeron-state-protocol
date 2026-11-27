// A store's directory is one node's at a time, whoever's it is: a Node device's in this process or another, or zspd's.
// Whoever comes second is told the store is in use and touches nothing; the kernel lets go of it when its holder's
// process ends, however it ends. And a store on a file system shared with other machines is refused. See host/hold.odin.

import assert from "node:assert/strict";
import { spawn, spawnSync, type ChildProcess } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { open } from "../src/nodejs.ts";
import { ASIDE, FLOCK } from "../src/volume-node.ts";
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

// zspd's commands that keep what is in a space's directory, with no node running, hold it as its store's holder would:
// not beside a Node device kept there.
{
  const dir = join(TMP, "commands");
  const space = zspd("create", dir);
  const roster = join(TMP, "commands-roster");
  copyFileSync(join(dir, space, "roster"), roster);
  const before = readFileSync(join(dir, space, "roster"));
  const d = await open({ dir: join(dir, space), ...quiet });
  for (const args of [["scope", dir], ["peer", dir, roster]]) {
    const p = spawnSync(BIN, args, { encoding: "utf8", timeout: 30000 });
    assert.equal(p.status, 1, `${args[0]} beside a device holding the space's directory: ${p.stdout}${p.stderr}`);
    assert.match(p.stderr, IN_USE);
  }
  assert.deepEqual(readFileSync(join(dir, space, "roster")), before, "the roster was kept beside the device");
  await d.close();
}

// Held where the system takes its path to be, as zspd holds it: `none/..` passed through, not made; and `..` after a link
// taken from where the link leads, as the system takes it, not from where the link is.
{
  const d = await open({ dir: join(TMP, "none", "..", "roundabout"), ...quiet });
  await d.close();
  assert(existsSync(join(TMP, "roundabout", "lock")) && !existsSync(join(TMP, "none")), "a directory its path only passes through was made");
  if (process.platform !== "win32") {
    mkdirSync(join(TMP, "deep", "inner"), { recursive: true });
    symlinkSync(join(TMP, "deep", "inner"), join(TMP, "link"));
    const linked = join(TMP, "link") + "/../linked";
    zspd("create", linked);
    assert(existsSync(join(TMP, "deep", "linked", "space")), "zspd made it elsewhere");
    const e = await open({ dir: linked, ...quiet });
    const p = spawnSync(BIN, ["run", linked, "--listen=127.0.0.1:0", "--no-udp"], { encoding: "utf8", timeout: 30000 });
    await e.close();
    assert.match(p.stderr, IN_USE, "zspd and a device held the one directory, each where it took it to be");
    assert(!existsSync(join(TMP, "linked")), "held where the link is, not where it leads");
  }
}

// The lock file is a file, never a link followed to wherever it leads, as zspd holds it to; and what is in it is nothing,
// which nothing writes and zspd pays no heed to, and keeps no device from it.
{
  const dir = join(TMP, "linked");
  mkdirSync(dir);
  writeFileSync(join(TMP, "elsewhere"), "");
  let linked = true;
  try {
    symlinkSync(join(TMP, "elsewhere"), join(dir, "lock"));
  } catch (e) {
    // Where this process may make no link, as on Windows unelevated, it is not tried here; CI, elevated, tries it.
    if (process.platform !== "win32" || (e as NodeJS.ErrnoException).code !== "EPERM" || process.env.CI) throw e;
    linked = false;
  }
  if (linked) await assert.rejects(open({ dir, ...quiet }), /is not a file/);
  const filled = join(TMP, "filled");
  zspd("create", filled);
  writeFileSync(join(filled, "lock"), "x".repeat(4096));
  const d = await open({ dir: filled, ...quiet });
  const p = spawnSync(BIN, ["run", filled, "--listen=127.0.0.1:0", "--no-udp"], { encoding: "utf8", timeout: 30000 });
  assert.match(p.stderr, IN_USE, "a device on a lock file with something in it holds nothing");
  await d.close();
}

// What a lock file is made from is no file zspd takes for a save's left behind, which it would remove, and the lock file
// then be made readable by everyone: so it is not removed by zspd clearing the directory, and the lock file is the
// owner's alone.
{
  const dir = join(TMP, "aside");
  mkdirSync(dir);
  assert(!/\.[0-9a-f]{32}\.new$/.test("lock.0123456789abcdef0123456789abcdef.making") && ASIDE.test("lock.0123456789abcdef0123456789abcdef.making"));
  const aside = join(dir, "lock.0123456789abcdef0123456789abcdef.making");
  writeFileSync(aside, "");
  zspd("key", dir); // which clears what saves left behind
  assert(existsSync(aside), "zspd removed what a lock file is being made from");
  rmSync(aside);
  const d = await open({ dir, ...quiet });
  await d.close();
  if (process.platform !== "win32") assert.equal(statSync(join(dir, "lock")).mode & 0o777, 0o600);
  assert.deepEqual(readdirSync(dir).filter((n) => n.startsWith("lock.")), [], "what the lock file was made from was left");
}

// Where Node takes flock's lock is where zspd does, as host/hold_bsd.odin is built.
{
  const built = /^#\+build (.*)$/m.exec(readFileSync(join(ROOT, "host/hold_bsd.odin"), "utf8"))![1].split(",").map((s) => s.trim());
  assert.deepEqual([...FLOCK].sort(), built.sort());
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
