// Streams and services (SPEC.md §16) against real zspd devices through a relay of zspd's: files fetched and sent, whole,
// checked, and taken up where they stopped; what is refused, and why; what a device offers; commands, terminals and
// connections; and a reader that never reads, which holds up its sender rather than piling up. A web device owns the
// space, for only it can grant Shell and Files; it and zspd devices use what a zspd device shares. `node test/services.ts [names...]`

import { spawn } from "node:child_process";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, realpathSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { createServer, connect as dial, type AddressInfo } from "node:net";
import { availableParallelism } from "node:os";
import { basename, join } from "node:path";
import { Client } from "../src/client.ts";
import { bridge, NodeFolder, open } from "../src/nodejs.ts";
import { CHUNK, getRequest, PART, ServiceError, type Refusal } from "../src/services.ts";
import { cleanUp, eventually, exists, expectEqual, node, stopAll, TMP, token, zspd, zspdConnect } from "./procs.ts";

// What zspd devices inherit from this process, for a command there to show, or not when told to remove it.
process.env.ZSP_INHERITED = "inherited";

const ALL = { write: true, call: true, shell: true, files: true };
const NODE = process.execPath;
const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));
const text = (b: Uint8Array) => new TextDecoder().decode(b);
const sha = (b: Uint8Array) => createHash("sha256").update(b).digest("hex");
// When a file was written, in ms, as NodeFolder reads it: a time set in seconds, as a double, falls short by less than a µs.
const ms = (path: string) => Number((statSync(path, { bigint: true }).mtimeNs + 1000n) / 1_000_000n);

function check(ok: boolean, what: string): void {
  if (!ok) throw new Error("not so: " + what);
}

// Rejects as it should: with a ServiceError of one of these statuses.
async function refused(p: Promise<unknown>, ...statuses: Refusal[]): Promise<ServiceError> {
  const e = await p.then(
    () => undefined,
    (e: unknown) => e,
  );
  if (!(e instanceof ServiceError)) throw new Error(`expected ${statuses.join(" or ")}, and it ${e === undefined ? "succeeded" : "failed so: " + e}`);
  if (!statuses.includes(e.status)) throw new Error(`expected ${statuses.join(" or ")}, not ${e.message}`);
  return e;
}

// A space a web device owns, with a zspd device, B, that shares; in scope 1 the web device may use what B shares, and in
// scope 2 may call but neither run commands nor reach files. With `alsoZspd`, another zspd device, A, as the web one may.
async function world(name: string, alsoZspd = false) {
  const relay = await node("serve", join(TMP, name + "-relay"));
  const w = await open({ dir: join(TMP, name + "-web"), udp: false, log: () => {} });
  const sid = await w.create();
  await w.relay(relay.key, relay.url);
  await w.admit(w.key, 1, ALL);
  expectEqual(await w.scope(), 2);
  const zspds: { dir: string; key: string }[] = [];
  for (const which of alsoZspd ? ["b", "a"] : ["b"]) {
    const dir = join(TMP, `${name}-${which}`);
    const key = zspd("key", dir);
    await w.admit(key, 1, ALL);
    await w.admit(key, 2, { write: true, call: true });
    zspd("join", dir, sid, relay.key, relay.url);
    zspds.push({ dir, key });
  }
  const clients: Client[] = [];
  for (const z of zspds) {
    const n = await node("run", z.dir);
    await eventually("it hears who belongs", () => exists(join(z.dir, sid, "roster")));
    clients.push(new Client({ connect: zspdConnect(n.address), credential: token(z.dir), folder: new NodeFolder(join(TMP, name + "-a-files")) }));
  }
  const mine = join(TMP, name + "-mine");
  const shared = join(TMP, name + "-shared");
  const readOnly = join(TMP, name + "-read-only");
  for (const d of [mine, shared, readOnly, join(TMP, name + "-a-files")]) mkdirSync(d, { recursive: true });
  const cw = w.client({ folder: new NodeFolder(mine) });
  const [cb, ca] = clients;
  await eventually("all may call", () => cw.may(1, "call") && clients.every((c) => c.may(1, "call")));
  // As the host writes them back.
  const shares = `files 1 docs write ${shared}\nfiles 1 ro read ${readOnly}\nfiles 2 docs write ${shared}\nshell 1 terminal commands\n`;
  await cb.setShares(shares);
  const b = zspds[0].key.slice(0, 64);
  await eventually("b is reached", async () => (await cw.services(b, 1).catch(() => [])).length > 0, 15000);
  const close = async () => {
    for (const c of [cw, ...clients]) c.close();
    await w.close();
  };
  return { w, cw, cb, ca, b, mine, shared, readOnly, shares, close };
}

const tests: Record<string, () => Promise<void>> = {
  // A file goes to B and comes back, whole and checked, with its time; through folders made on the way. Without leave to
  // replace it, it is not; empty files go as well as any; folders are listed; and trees go both ways, and again with nothing
  // to carry.
  async files_round_trip() {
    const s = await world("f");
    const sent = randomBytes(5 * CHUNK + 12345);
    writeFileSync(join(s.mine, "x.bin"), sent);
    let progress = 0;
    const put = await s.cw.put(s.b, 1, "x.bin", "docs/sub/x.bin", { onProgress: (done) => (progress = done) });
    check(put.size === sent.length && put.bytes === sent.length && put.resumed === 0 && progress === sent.length, "it is sent whole");
    check(sha(readFileSync(join(s.shared, "sub", "x.bin"))) === sha(sent), "and is there as it was");
    expectEqual(ms(join(s.shared, "sub", "x.bin")), ms(join(s.mine, "x.bin")));
    await refused(s.cw.put(s.b, 1, "x.bin", "docs/sub/x.bin"), "exists");
    const again = await s.cw.put(s.b, 1, "x.bin", "docs/sub/x.bin", { replace: true });
    check(again.hash === put.hash, "replaced, when told to");
    const got = await s.cw.get(s.b, 1, "docs/sub/x.bin", "y.bin");
    check(sha(readFileSync(join(s.mine, "y.bin"))) === sha(sent) && got.hash === put.hash && got.size === sent.length, "and it comes back");
    expectEqual(ms(join(s.mine, "y.bin")), ms(join(s.shared, "sub", "x.bin")));
    check(!existsSync(join(s.mine, "y.bin" + PART)) && !existsSync(join(s.mine, "y.bin" + PART + ".meta")), "leaving nothing behind");
    check(!existsSync(join(s.shared, "sub", "x.bin" + PART)), "there either");
    // Empty files, both ways.
    writeFileSync(join(s.shared, "empty"), "");
    const none = await s.cw.get(s.b, 1, "docs/empty", "empty");
    check(none.size === 0 && none.hash === "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" && readFileSync(join(s.mine, "empty")).length === 0, "an empty file comes");
    await s.cw.put(s.b, 1, "empty", "docs/empty2");
    check(readFileSync(join(s.shared, "empty2")).length === 0, "and goes");
    // Listed.
    const shares = await s.cw.list(s.b, 1, "");
    check(JSON.stringify(shares.map((e) => [e.name, e.kind]).sort()) === JSON.stringify([["docs", "folder"], ["ro", "folder"]]), "the shares of files are the folders of the path ''");
    const docs = await s.cw.list(s.b, 1, "docs");
    check(docs.some((e) => e.name === "sub" && e.kind === "folder") && docs.some((e) => e.name === "empty" && e.kind === "file" && e.size === 0), "a folder is listed");
    const sub = await s.cw.list(s.b, 1, "docs/sub");
    check(sub.length === 1 && sub[0].name === "x.bin" && sub[0].size === sent.length && sub[0].modified === ms(join(s.mine, "x.bin")), "with sizes and times");
    // Trees.
    mkdirSync(join(s.shared, "sub", "deeper"));
    writeFileSync(join(s.shared, "sub", "deeper", "z.txt"), "zed");
    const fetched = await s.cw.getTree(s.b, 1, "docs/sub", "tree");
    check(fetched.length === 2 && fetched.every((f) => f.transferred !== undefined), "a tree is fetched");
    check(readFileSync(join(s.mine, "tree", "deeper", "z.txt"), "utf8") === "zed" && sha(readFileSync(join(s.mine, "tree", "x.bin"))) === sha(sent), "all of it");
    check((await s.cw.getTree(s.b, 1, "docs/sub", "tree")).every((f) => f.transferred === undefined), "and again, with nothing to carry");
    const sentTree = await s.cw.putTree(s.b, 1, "tree", "docs/copy");
    check(sentTree.length === 2 && readFileSync(join(s.shared, "copy", "deeper", "z.txt"), "utf8") === "zed", "a tree is sent");
    check((await s.cw.putTree(s.b, 1, "tree", "docs/copy")).every((f) => f.transferred === undefined), "and again, with nothing to carry");
    await s.close();
  },

  // A transfer cut off midway takes up where it stopped, both ways, carrying only the rest; one whose file there changed
  // since begins again, and what comes is the new file.
  async files_resume() {
    const s = await world("r");
    const size = 12 * CHUNK + 777;
    const data = randomBytes(size);
    writeFileSync(join(s.shared, "big"), data);
    const cut = (at: number) => {
      const stop = new AbortController();
      return { signal: stop.signal, onProgress: (done: number) => done >= at && stop.abort() };
    };
    await refused(s.cw.get(s.b, 1, "docs/big", "big", cut(4 * CHUNK)), "failed");
    check(existsSync(join(s.mine, "big" + PART)) && existsSync(join(s.mine, "big" + PART + ".meta")), "what came is kept");
    const fetched = await s.cw.get(s.b, 1, "docs/big", "big");
    check(fetched.resumed > 0 && fetched.resumed % CHUNK === 0 && fetched.bytes === size - fetched.resumed, `taken up from ${fetched.resumed}`);
    check(sha(readFileSync(join(s.mine, "big"))) === sha(data), "and whole");
    // Sent, and cut off.
    const mine = randomBytes(size);
    writeFileSync(join(s.mine, "out"), mine);
    await refused(s.cw.put(s.b, 1, "out", "docs/out", cut(5 * CHUNK)), "failed");
    await eventually("what came is kept there", () => existsSync(join(s.shared, "out" + PART)));
    const sent = await s.cw.put(s.b, 1, "out", "docs/out");
    check(sent.resumed >= CHUNK && sent.bytes === size - sent.resumed, `sent from ${sent.resumed}`);
    check(sha(readFileSync(join(s.shared, "out"))) === sha(mine), "and whole there");
    // Cut off, and the file there changed since.
    await refused(s.cw.get(s.b, 1, "docs/big", "again", cut(3 * CHUNK)), "failed");
    const changed = randomBytes(6 * CHUNK);
    writeFileSync(join(s.shared, "big"), changed);
    const fresh = await s.cw.get(s.b, 1, "docs/big", "again");
    check(fresh.resumed === 0 && fresh.bytes === changed.length, "begun again");
    check(sha(readFileSync(join(s.mine, "again"))) === sha(changed), "with the new file");
    await s.close();
  },

  // What is not shared, what lies outside a share by '..' or by a link, what may only be read, what is not there, and what
  // the roster gives no right to: each refused as what it is.
  async files_refused() {
    const s = await world("x");
    writeFileSync(join(s.readOnly, "ok"), "fine");
    writeFileSync(join(s.mine, "x"), "x");
    mkdirSync(join(s.shared, "..", "x-secret"), { recursive: true });
    writeFileSync(join(s.shared, "..", "x-secret", "key"), "hush");
    writeFileSync(join(s.shared, "there"), "there");
    await refused(s.cw.get(s.b, 1, "nope/ok", "got"), "not offered");
    await refused(s.cw.get(s.b, 1, "docs/../x-secret/key", "got"), "denied");
    await refused(s.cw.put(s.b, 1, "x", "ro/x"), "denied");
    await refused(s.cw.get(s.b, 1, "docs/missing", "got"), "not found");
    await refused(s.cw.put(s.b, 1, "x", "docs"), "malformed"); // a share is no file
    await refused(s.cw.put(s.b, 1, "not-here", "docs/x"), "not found");
    await refused(s.cw.get(s.b, 2, "docs/there", "got"), "denied"); // shared there, but without the Files right
    await refused(s.cw.list(s.b, 2, "docs"), "denied");
    await refused(s.cw.get(s.b, 3, "docs/there", "got"), "denied", "unreachable"); // no such scope: the call itself is refused
    if (process.platform !== "win32") {
      symlinkSync(join(s.shared, "..", "x-secret", "key"), join(s.shared, "link"));
      await refused(s.cw.get(s.b, 1, "docs/link", "got"), "denied");
    }
    check(!existsSync(join(s.mine, "got")), "nothing came");
    check((await s.cw.get(s.b, 1, "ro/ok", "got")).size === 4, "and what may be read, is");
    await s.close();
  },

  // What a device offers, as its rights let a caller use it; all of it, to its own clients, who alone may see and set its
  // shares. Shares withdrawn end what used them, at once.
  async services_listed() {
    const s = await world("s");
    const offered = await s.cw.services(s.b, 1);
    expectEqual(
      JSON.stringify(offered),
      JSON.stringify([
        { kind: "files", name: "docs", read: true, write: true },
        { kind: "files", name: "ro", read: true, write: false },
        { kind: "shell", terminal: true, commands: true },
      ]),
    );
    expectEqual(JSON.stringify(await s.cw.services(s.b, 2)), "[]"); // no Files right there
    expectEqual(JSON.stringify(await s.cb.services(s.b, 2)), JSON.stringify([{ kind: "files", name: "docs", read: true, write: true }]));
    expectEqual(await s.cb.shares(), s.shares);
    await refused(s.cb.setShares("files 1 docs nonsense"), "malformed");
    expectEqual(await s.cb.shares(), s.shares);
    // Withdrawn while a file is being fetched.
    writeFileSync(join(s.shared, "big"), randomBytes(64 * CHUNK));
    let started = false;
    const going = s.cw.get(s.b, 1, "docs/big", "big", { onProgress: (done) => (started ||= done > 0) });
    await eventually("it is under way", () => started);
    await s.cb.setShares("shell 1");
    await refused(going, "denied");
    expectEqual(JSON.stringify(await s.cw.services(s.b, 1)), JSON.stringify([{ kind: "shell", terminal: true, commands: true }]));
    await s.cb.setShares("");
    expectEqual(await s.cb.shares(), "");
    expectEqual(JSON.stringify(await s.cw.services(s.b, 1)), "[]");
    await s.close();
  },

  // A zspd device's client uses what another zspd device shares, as a web device's does.
  async zspd_to_zspd() {
    const s = await world("z", true);
    const data = randomBytes(3 * CHUNK + 5);
    writeFileSync(join(s.shared, "file"), data);
    const got = await s.ca!.get(s.b, 1, "docs/file", "file");
    check(got.size === data.length && sha(readFileSync(join(TMP, "z-a-files", "file"))) === sha(data), "a zspd device fetches from another");
    check((await s.ca!.list(s.b, 1, "docs")).some((e) => e.name === "file"), "and lists what it shares");
    await s.close();
  },

  // A reader that never reads holds up its sender: no more comes than the call's window, however much there is; and all of
  // it comes once it reads, as fast as it does.
  async bounded() {
    const s = await world("b");
    const size = 32 * CHUNK;
    writeFileSync(join(s.shared, "huge"), randomBytes(size));
    let came = 0, kept = 0, reading = false, ended = false;
    const call = s.cw.call(s.b, 1, "zsp.get", getRequest("docs/huge", 0, new Uint8Array()));
    call.ondata = (d) => {
      came += d.length;
      if (reading) return true;
      kept += d.length;
      return false;
    };
    call.onend = () => (ended = true);
    await eventually("something comes", () => came > 0);
    await sleep(1500);
    check(came <= 262144, `no more than a window comes to a reader that reads nothing: ${came}`);
    reading = true;
    call.consumed(kept);
    await eventually("it all comes once read", () => ended, 30000);
    check(came > size, "all of it");
    call.finish();
    await s.close();
  },

  // No port is permitted through zspd, which has nobody yet to say which may be: a connection is refused, as denied, or as
  // not offered once something says what is. And a stream, bridged to a socket here, carries both ways, ends each way, and
  // holds up a socket that sends more than the far end takes.
  async tcp() {
    const s = await world("t");
    const echo = createServer({ allowHalfOpen: true }, (c) => c.pipe(c));
    await new Promise<void>((done) => echo.listen(0, "127.0.0.1", done));
    const port = (echo.address() as AddressInfo).port;
    const stream = s.cw.connect(s.b, 1, port);
    await refused(stream.connected, "denied", "not offered");
    await refused(stream.closed, "denied", "not offered");
    check(!(await s.cw.services(s.b, 1)).some((x) => x.kind === "tcp"), "and none is listed");
    // Bridged: refused, the socket is reset.
    const here = createServer({ allowHalfOpen: true }, (sock) => void bridge(s.cw.connect(s.b, 1, port), sock));
    await new Promise<void>((done) => here.listen(0, "127.0.0.1", done));
    const reset = await new Promise<string>((done) => {
      const sock = dial((here.address() as AddressInfo).port, "127.0.0.1");
      sock.on("error", (e: NodeJS.ErrnoException) => done(e.code ?? "error"));
      sock.on("close", () => done("closed"));
    });
    check(reset === "ECONNRESET" || reset === "closed", `the socket is let go of: ${reset}`);
    echo.close();
    here.close();
    await s.close();
  },

  // Commands: their output, errors and exit; their environment over the device's, and folder; input, as fast as they take
  // it; signals; kill; a program that is not there; and output nobody reads, which holds the command up.
  async exec() {
    const s = await world("e");
    const ran = await s.cw.run(s.b, 1, [NODE, "-e", "process.stdout.write('out'); process.stderr.write('err'); process.exitCode = 3"]);
    expectEqual(JSON.stringify(ran), JSON.stringify({ code: 3, signal: 0, stdout: "out", stderr: "err" }));
    const where = await s.cw.run(s.b, 1, [NODE, "-e", "console.log(process.env.ZSP_MARK, process.env.ZSP_INHERITED, process.cwd())"], { env: { ZSP_MARK: "marked" }, cwd: s.shared });
    check(where.stdout.startsWith("marked inherited ") && where.stdout.includes(basename(realpathSync(s.shared))), `its environment, over the device's, and its folder: ${where.stdout}`);
    const removed = await s.cw.run(s.b, 1, [NODE, "-e", "console.log(String(process.env.ZSP_INHERITED))"], { env: { ZSP_INHERITED: null } });
    expectEqual(removed.stdout.trim(), "undefined");
    const fed = await s.cw.run(s.b, 1, [NODE, "-e", "process.stdin.pipe(process.stdout)"], { input: "x".repeat(3 << 20) });
    check(fed.code === 0 && fed.stdout.length === 3 << 20, "input, more than any window, all taken");
    // As a process: read as it comes, written to, ended.
    const cat = s.cw.exec(s.b, 1, [NODE, "-e", "process.stdin.pipe(process.stdout)"]);
    await cat.started;
    void cat.write("hello ");
    void cat.write("there");
    cat.closeInput();
    let heard = "";
    for await (const d of cat.output) heard += text(d);
    expectEqual(heard, "hello there");
    expectEqual((await cat.exit).code, 0);
    // Killed.
    const forever = s.cw.exec(s.b, 1, [NODE, "-e", "setInterval(() => {}, 1000)"]);
    await forever.started;
    forever.kill();
    const killed = await forever.exit;
    if (process.platform === "win32") check(killed.code !== 0 && killed.signal === 0, `ended, as Windows says: ${JSON.stringify(killed)}`);
    else expectEqual(killed.signal, 9);
    // Interrupted: Windows has no signals to give a process of its own, and so no test of one here.
    if (process.platform !== "win32") {
      const waiting = s.cw.exec(s.b, 1, [NODE, "-e", "process.on('SIGINT', () => { console.log('interrupted'); process.exit(0) }); console.log('ready'); setInterval(() => {}, 1000)"]);
      let said = "";
      waiting.onOutput = (d) => void (said += text(d));
      await eventually("it is ready", () => said.includes("ready"));
      waiting.signal("interrupt");
      expectEqual((await waiting.exit).code, 0);
      check(said.includes("interrupted"), "and was told");
    }
    await refused(s.cw.run(s.b, 1, ["zsp-there-is-no-such-program"]), "not found");
    await refused(s.cw.run(s.b, 2, [NODE, "-e", ""]), "not offered");
    // Nobody reads: the command waits at its own pipe, and nothing piles up.
    const loud = s.cw.exec(s.b, 1, [NODE, "-e", "const b = Buffer.alloc(1 << 20, 120); let n = 32; (function more() { while (n > 0) { n--; if (!process.stdout.write(b)) return process.stdout.once('drain', more); } })()"]);
    await loud.started;
    await eventually("output comes", () => loud.output.buffered > 0);
    await sleep(1500);
    check(loud.output.buffered <= 262144, `no more than a window waits to be read: ${loud.output.buffered}`);
    let total = 0;
    for await (const d of loud.output) total += d.length;
    expectEqual(total, 32 << 20);
    expectEqual((await loud.exit).code, 0);
    await s.close();
  },

  // A terminal: the user's shell there, with the environment and size it is given, resized, and ended as a user ends it.
  async terminal() {
    const s = await world("p");
    const windows = process.platform === "win32";
    const t = s.cw.terminal(s.b, 1, { rows: 24, cols: 80, env: { ZSP_MARK: "marked-by-zsp" }, cwd: s.shared });
    let seen = "";
    let told: unknown;
    t.onOutput = (d) => void (seen += text(d));
    t.onExit = (exit) => (told = exit);
    await t.started;
    // cmd and PowerShell each say one of these, and the other as it was typed; a POSIX shell says the first.
    void t.write(windows ? "echo %ZSP_MARK%\r\necho $env:ZSP_MARK\r\n" : "echo $ZSP_MARK\r");
    await eventually("its environment is as given", () => seen.includes("marked-by-zsp"));
    if (!windows) {
      t.resize(50, 132);
      void t.write("stty size\r");
      await eventually("its size is as said", () => seen.includes("50 132"));
    }
    void t.write(windows ? "exit\r\n" : "exit\r");
    const exit = await t.exit;
    expectEqual(exit.code, 0);
    check(told === exit, "and it is told so");
    await s.close();
  },
};

async function main(): Promise<void> {
  const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : Object.keys(tests);
  if (names.length > 1) {
    // Side by side, each in a process of its own, as test/end_to_end.ts runs; no more at once than half the machine has
    // cores for.
    const room = Math.max(2, Math.floor(availableParallelism() / 2));
    const run = (name: string) =>
      new Promise<[string, number]>((done) => {
        const p = spawn(process.execPath, [process.argv[1], name], { stdio: ["ignore", "pipe", "pipe"] });
        let out = "";
        p.stdout.on("data", (d) => (out += d));
        p.stderr.on("data", (d) => (out += d));
        p.on("exit", (code) => done([out, code ?? 1]));
      });
    const results: Promise<[string, number]>[] = [];
    const running = new Set<Promise<unknown>>();
    for (const name of names) {
      while (running.size >= room) await Promise.race(running);
      const r = run(name);
      results.push(r);
      const held: Promise<boolean> = r.then(() => running.delete(held));
      running.add(held);
    }
    let failed = false;
    for (const [out, code] of await Promise.all(results)) {
      process.stdout.write(out);
      failed ||= code !== 0;
    }
    await cleanUp();
    process.exit(failed ? 1 : 0);
  }
  const name = names[0];
  const start = performance.now();
  let failed = false;
  try {
    if (!tests[name]) throw new Error(`no test ${name}`);
    await tests[name]();
    console.log(`ok   services ${name} ${((performance.now() - start) / 1000).toFixed(2)}s`);
  } catch (e) {
    failed = true;
    console.log(`FAIL services ${name}: ${e instanceof Error ? e.stack : e}\n     in ${TMP}`);
  } finally {
    await stopAll();
  }
  if (!failed) await cleanUp();
  process.exit(failed ? 1 : 0);
}

await main();
