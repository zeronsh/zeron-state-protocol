// Tabs as browsers treat them, rather than as a test would like: hidden, frozen, put in the back/forward cache, and held
// back. Headless Chrome, with the origin's device shared by its tabs. `node test/tabs.ts [names...]`

import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { readFileSync } from "node:fs";
import { createServer as http } from "node:http";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { Chrome, findChrome, type Page } from "./chrome.ts";
import { cleanUp, node, procs, ROOT, stopAll, TMP, token, zspd, zspdConnect, type Started } from "./procs.ts";
import { Client, columns } from "../src/client.ts";

// `./x selftest` sets ZSP_FAIL, to see that ./x test says this failed.
if (process.env.ZSP_FAIL) throw new Error("failing, as ZSP_FAIL asks");

if (!findChrome()) {
  if (process.env.CI) throw new Error("no Chrome here: set CHROME to where it is");
  console.log("skip tabs: no Chrome here; set CHROME to where it is");
  process.exit(0);
}

const WEB = join(ROOT, "web");
execFileSync(process.execPath, [join(WEB, "build.ts"), "--test"], { stdio: "inherit" });

const TYPES: Record<string, string> = { ".js": "text/javascript", ".wasm": "application/wasm", ".html": "text/html" };
const site = http((req, res) => {
  const path = new URL(req.url!, "http://x").pathname;
  if (process.env.TRACE) console.log("     GET", path, performance.now().toFixed(0));
  if (path === "/" || path === "/again") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><meta charset="utf-8"><script type="module" src="/test.js"></script>');
    return;
  }
  if (path === "/elsewhere") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><meta charset="utf-8"><p>elsewhere</p>');
    return;
  }
  try {
    const body = readFileSync(join(WEB, "dist", path.slice(1)));
    res.writeHead(200, { "content-type": TYPES[path.slice(path.lastIndexOf("."))] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise<void>((done) => site.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${(site.address() as AddressInfo).port}/`;

let chrome: Chrome | undefined;
const said: string[] = []; // what pages and their workers said
const pages: Page[] = [];
async function page(): Promise<Page> {
  const t = performance.now();
  const p = await chrome!.open(origin, (line) => (said.push(line), console.log("     page: " + line)));
  if (process.env.TRACE) console.log("     opened in", performance.now() - t);
  await p.evaluate("new Promise((done) => { const go = () => window.zsp ? done() : setTimeout(go, 10); go(); })");
  pages.push(p);
  return p;
}
async function gone(p: Page): Promise<void> {
  pages.splice(pages.indexOf(p), 1);
  await p.close();
}

const T0 = performance.now();
const call = <T>(p: Page, f: string, ...args: unknown[]) =>
  (process.env.TRACE && console.log(`     ${((performance.now() - T0) / 1000).toFixed(2)} ${f}`), p.evaluate<T>(`window.zsp.${f}(${args.map((a) => (a === undefined ? "undefined" : JSON.stringify(a))).join(", ")})`));
const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));
// What a promise came to in so long, or "not in time".
const within = <T>(ms: number, p: Promise<T>) => Promise.race([p.then((v) => v as T | string), sleep(ms).then(() => "not in time")]);
async function eventually(f: () => boolean | Promise<boolean>, what = "", ms = 10000): Promise<void> {
  for (const until = Date.now() + ms; Date.now() < until; await sleep(20)) if (await f()) return;
  throw new Error(`not in time: ${what}`);
}
function expectEqual<T>(got: T, want: T, what = ""): void {
  if (JSON.stringify(got) !== JSON.stringify(want)) throw new Error(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`);
}

// What a worker evaluates before its own script, by Page.preamble: it says of every file of the origin's file system it
// opens, closes and finds held by another, as `who`, on a channel every tab of the test page listens to. And it may make the
// platform misbehave as it may: hold every file for `lag` ms from the first opened, as Chromium has been seen to after the
// worker that had them was gone, which with `lag` of Infinity it has been seen to do until the browser is restarted; take so
// many ms more to hand over a file, `slow`, or a segment of the log, `slowLog`, holding it meanwhile; or refuse to cut a file
// short, as a full disk may, `failCut`.
function files(o: { who: string; lag?: number; slow?: number; slowLog?: number; failCut?: boolean }): string {
  return `(() => {
    const o = ${JSON.stringify({ ...o, lag: o.lag === Infinity ? 1e12 : (o.lag ?? 0) })};
    const said = { who: o.who, worker: crypto.randomUUID(), opened: 0, closed: 0, held: 0 };
    const channel = new BroadcastChannel("zsp-files");
    const say = () => channel.postMessage(said);
    const sleep = (ms) => new Promise((done) => setTimeout(done, ms));
    let first;
    const create = FileSystemFileHandle.prototype.createSyncAccessHandle;
    FileSystemFileHandle.prototype.createSyncAccessHandle = async function () {
      first ??= performance.now();
      if (performance.now() - first < o.lag) {
        said.held++, say();
        throw new DOMException("Access Handles cannot be created if there is another open Access Handle or Writable stream associated with the same file.", "NoModificationAllowedError");
      }
      let h;
      try {
        h = await create.call(this);
      } catch (e) {
        if (e.name === "NoModificationAllowedError" || e.name === "InvalidStateError") said.held++, say();
        throw e;
      }
      said.opened++, say();
      const close = h.close;
      let open = true;
      h.close = function () {
        if (open) (open = false), said.closed++, say();
        return close.call(this);
      };
      const slow = this.name.endsWith(".log") ? o.slowLog : o.slow;
      if (slow) await sleep(slow);
      return h;
    };
    if (o.failCut) FileSystemSyncAccessHandle.prototype.truncate = () => { throw new DOMException("the disk is full", "QuotaExceededError"); };
  })()`;
}
const filesSaid = async (p: Page, who: string) => (await call<{ who: string; opened: number; closed: number; held: number }[]>(p, "files")).filter((f) => f.who === who);

// Loads a page again, and waits for it to be the test page anew.
async function reload(p: Page): Promise<void> {
  await p.evaluate("window.__old = 1, 1");
  await p.cdp("Page.reload");
  await eventually(async () => (await p.evaluate("typeof window.zsp === 'object' && window.__old === undefined").catch(() => false)) === true, "loaded again");
}

// Leaves a page for another of the site's, as a link does, and goes back, as the back button does: by CDP, rather than by a
// script evaluated in the page, whose answer the navigation it starts cuts off should it land first ("Inspected target
// navigated or closed"). Each returns once the browser has the navigation in hand, whatever the page is doing.
async function navigate(p: Page, path: string): Promise<void> {
  const r = await p.cdp<{ errorText?: string }>("Page.navigate", { url: new URL(path, origin).href });
  if (r.errorText) throw new Error(`navigating to ${path}: ${r.errorText}`);
}
async function back(p: Page): Promise<void> {
  const { currentIndex, entries } = await p.cdp<{ currentIndex: number; entries: { id: number }[] }>("Page.getNavigationHistory");
  if (currentIndex < 1) throw new Error("nothing to go back to");
  await p.cdp("Page.navigateToHistoryEntry", { entryId: entries[currentIndex - 1].id });
}

// A relay of the Durable Object's, under workerd, that lets in only what presents `token`: started again on the same port,
// with the same key, as a relay whose host has rotated what it accepts.
const RELAY_SECRET = randomBytes(32).toString("hex");
async function relay(token: string, port = 0): Promise<Started> {
  const p = spawn(process.execPath, [join(ROOT, "relay", "dev.mjs"), String(port)], {
    stdio: ["ignore", "pipe", "ignore"],
    env: { ...process.env, ACCESS_TOKEN: token, RELAY_SECRET },
  });
  procs.push(p);
  return new Promise((resolve, reject) => {
    let out = "";
    p.stdout!.on("data", (d) => {
      out += d;
      const m = /(\w{64}) listening on ws:\/\/(\S+)/.exec(out);
      if (m) resolve({ key: m[1], address: m[2], url: "ws://127.0.0.1:" + m[2].split(":").pop(), p });
    });
    p.on("exit", (code) => reject(new Error(`the relay exited with ${code}`)));
  });
}
async function stop(p: ChildProcess): Promise<void> {
  if (p.exitCode !== null) return;
  const exited = new Promise((done) => p.once("exit", done));
  p.kill();
  await exited;
}

const tests: Record<string, () => Promise<void>> = {
  // The tab running the device is frozen, as Chrome freezes a tab hidden for long: another tab goes on, and so does the
  // frozen one once it is back.
  async tab_frozen_leader() {
    const leader = await page();
    await call(leader, "device", "fz");
    await call(leader, "create", "fz");
    const follower = await page(); // and so the leader is hidden
    await call(follower, "device", "fz");
    await call(follower, "put", "fz", "notes", ["one"]);
    await leader.cdp("Page.setWebLifecycleState", { state: "frozen" });
    expectEqual(await within(10000, call(follower, "put", "fz", "notes", ["two"]).then(() => "written")), "written", "written while the leader is frozen");
    await leader.cdp("Page.setWebLifecycleState", { state: "active" });
    await call(leader, "put", "fz", "notes", ["three"]);
    expectEqual((await call<string[]>(follower, "titles", "fz", "notes", 3)).join(), "one,two,three", "and by the leader, thawed");
  },
  // Left for another page, the tab running the device is kept in the back/forward cache: another tab goes on, and so does
  // that one when it is gone back to.
  async tab_cached_leader() {
    const leader = await page();
    await call(leader, "device", "bf");
    await call(leader, "create", "bf");
    const follower = await page();
    await call(follower, "device", "bf");
    await call(follower, "put", "bf", "notes", ["one"]);
    await leader.evaluate(`addEventListener('pagehide', (e) => localStorage.setItem('cached', String(e.persisted)));
      window.__cached = 1; // on this very page, which a page loaded again has not
      1`);
    await navigate(leader, "/elsewhere");
    await eventually(async () => (await follower.evaluate("localStorage.getItem('cached')")) !== null);
    expectEqual(await follower.evaluate("localStorage.getItem('cached')"), "true", "the leader was put in the back/forward cache");
    expectEqual(await within(10000, call(follower, "put", "bf", "notes", ["two"]).then(() => "written")), "written", "written while it is cached");
    await eventually(async () => (await leader.evaluate("location.pathname").catch(() => "")) === "/elsewhere", "it is elsewhere");
    await leader.evaluate("window.__left = 1, 1"); // on the page it went to
    await back(leader);
    // Taken from the cache, as most often; or, as a browser may let go of what it cached whenever it likes, loaded again.
    await eventually(async () => (await leader.evaluate("typeof window.zsp === 'object' && window.__left === undefined").catch(() => false)) === true, "it is back");
    const restored = (await leader.evaluate("window.__cached === 1")) === true;
    console.log(`     back ${restored ? "from the back/forward cache" : "loaded again, the browser having let go of what it cached"}`);
    if (!restored) await call(leader, "device", "bf");
    await call(leader, "put", "bf", "notes", ["three"]);
    expectEqual((await call<string[]>(follower, "titles", "bf", "notes", 3)).join(), "one,two,three", "and by the leader, back");
  },
  // A frozen tab next in line for the store does not come to hold it, frozen: the one after it has it.
  async tab_frozen_next() {
    const leader = await page();
    await call(leader, "device", "fn");
    await call(leader, "create", "fn");
    const frozen = await page();
    await call(frozen, "device", "fn"); // in line
    const last = await page();
    await call(last, "device", "fn");
    await call(last, "put", "fn", "notes", ["one"]);
    await frozen.cdp("Page.setWebLifecycleState", { state: "frozen" });
    await gone(leader);
    expectEqual(await within(10000, call(last, "put", "fn", "notes", ["two"]).then(() => "written")), "written", "written with the next in line frozen");
    await frozen.cdp("Page.setWebLifecycleState", { state: "active" });
    expectEqual((await call<string[]>(frozen, "titles", "fn", "notes", 2)).join(), "one,two", "and the frozen one has it all, thawed");
  },
  // A tab loaded again and again, at times before its device has opened: every time, the worker it had is stopped with its
  // files held, and the next is opened as soon as it has the store's lock, as Chrome hands it over. As it is here, and as
  // it has been seen to be, the files still held a while after the lock is had.
  async tab_reload_storm() {
    const p = await page();
    const watcher = await page(); // which hears what each worker of the other says of its files
    await call(p, "device", "rs");
    await call(p, "create", "rs");
    const put: string[] = [];
    for (const lag of [0, 150]) {
      await p.preamble(files({ who: `lag ${lag}`, lag }));
      for (let i = 0; i < 8; i++) {
        await reload(p);
        if (i % 2 === 1) {
          void call(p, "device", "rs").catch(() => {}); // loaded again as it opens
          continue;
        }
        expectEqual(await call<string>(p, "deviceOrError", "rs"), "ok", `opened, loaded again ${i + 1} times, held ${lag} ms`);
        await call(p, "put", "rs", "notes", [`${lag}/${i}`]);
        put.push(`${lag}/${i}`);
      }
      const said = await filesSaid(watcher, `lag ${lag}`);
      const held = said.reduce((n, f) => n + f.held, 0);
      console.log(`     held ${lag} ms: ${said.length} workers opened ${said.reduce((n, f) => n + f.opened, 0)} files, finding one held ${held} times`);
      if (lag > 0 && held === 0) throw new Error("no file was held, as the test meant it to be");
    }
    await reload(p);
    expectEqual(await call<string>(p, "deviceOrError", "rs"), "ok");
    expectEqual((await call<string[]>(p, "titles", "rs", "notes", put.length)).join(), put.join(), "everything written in the storm");
  },
  // The tab running the device is left for another page, and gone back to: its worker closes every file of the store itself,
  // having made durable what it held, before it is stopped; another tab has the store meanwhile; and the first has it again
  // once the other has gone, the files held a while after, as Chromium has been seen to hold them. The other is busy as it is
  // closed, as a tab may be: Chrome says it has closed it before the tab has heard so, and until it has, its worker runs the
  // store, and answers what the first asks. What each worker says of its files is heard on a channel of its own, after
  // whatever it was asked may have been answered: and so it is waited for.
  async tab_away_back() {
    const leader = await page();
    const follower = await page(); // which hears all the leader's worker says of its files
    await leader.preamble(files({ who: "leader" }));
    await call(leader, "device", "ab");
    await call(leader, "create", "ab");
    await call(leader, "put", "ab", "notes", ["one"]);
    await follower.preamble(files({ who: "follower", lag: 150 }));
    await call(follower, "device", "ab");
    await leader.evaluate(`addEventListener('pagehide', (e) => localStorage.setItem('left', String(e.persisted)));
      window.__here = 1;
      1`);
    await navigate(leader, "/elsewhere");
    await eventually(async () => (await follower.evaluate("localStorage.getItem('left')")) !== null, "it left");
    expectEqual(await within(10000, call(follower, "put", "ab", "notes", ["two"]).then(() => "written")), "written", "written while it is away");
    const closedAll = (f?: { opened: number; closed: number }) => f !== undefined && f.opened > 0 && f.closed === f.opened;
    await eventually(async () => closedAll((await filesSaid(follower, "leader"))[0])).catch(() => {}); // and else said so here
    const [had] = await filesSaid(follower, "leader");
    if (!had || had.opened === 0 || had.closed !== had.opened) throw new Error(`the leader's worker, stopped as its tab left, closed ${had?.closed} of the ${had?.opened} files it opened itself`);
    await eventually(async () => (await leader.evaluate("location.pathname").catch(() => "")) === "/elsewhere", "it is elsewhere");
    await leader.preamble(files({ who: "leader again", lag: 150 }));
    await back(leader);
    await eventually(async () => (await leader.evaluate("typeof window.zsp === 'object' && location.pathname === '/'").catch(() => false)) === true, "it is back");
    const restored = (await leader.evaluate("window.__here === 1")) === true;
    // Most often loaded again, its back/forward cache let go of as its channels were spoken on while it was in it.
    console.log(`     back ${restored ? "from the back/forward cache" : "loaded again"}`);
    if (!restored) await call(leader, "device", "ab");
    await call(leader, "put", "ab", "notes", ["three"]);
    await follower.evaluate("setTimeout(() => { for (const t = performance.now(); performance.now() - t < 500; ); }), 1");
    await gone(follower);
    // Its worker has the store once it has opened a file of it, having found them held first: the first it opens, it finds
    // held, as its preamble has it.
    let again: { opened: number; held: number }[] = [];
    await eventually(async () => (again = await filesSaid(leader, "leader again")).some((f) => f.opened > 0), "the leader has the store again");
    if (!again.some((f) => f.held > 0)) throw new Error("the files were not held after the follower went, as the test meant them to be");
    await call(leader, "put", "ab", "notes", ["four"]);
    expectEqual((await call<string[]>(leader, "titles", "ab", "notes", 4)).join(), "one,two,three,four");
  },
  // A tab's worker is stopped without a word, as a crash stops it, and the device opened again at once: the files are let go
  // of as the browser stops it, and its next worker opens them, though they are held a while after it has the lock. Held
  // for ever, as Chromium has been seen to hold them until it is restarted, the store is said to be locked, in time, and is
  // opened once they are let go of.
  async tab_killed_worker() {
    const p = await page();
    await call(p, "device", "kw");
    await call(p, "create", "kw");
    await call(p, "put", "kw", "notes", ["one"]);
    await p.preamble(files({ who: "held", lag: 150 }));
    await call(p, "killWorker", "kw");
    expectEqual(await call<string>(p, "deviceOrError", "kw"), "ok", "opened again after its worker was killed");
    await call(p, "put", "kw", "notes", ["two"]);
    await call(p, "killWorker", "kw");
    await p.preamble(files({ who: "held for ever", lag: Infinity }));
    const t = performance.now();
    const said = await within(15000, call<string>(p, "deviceOrError", "kw"));
    const took = performance.now() - t;
    if (!said.startsWith("StoreLocked (StoreLocked): ")) throw new Error(`a store whose files are held for ever: ${said}`);
    console.log(`     said to be locked in ${took.toFixed(0)} ms: ${said}`);
    if (took > 6000) throw new Error(`said to be locked only after ${took.toFixed(0)} ms`);
    await p.preamble(undefined);
    expectEqual(await call<string>(p, "deviceOrError", "kw"), "ok", "opened once its files are let go of");
    expectEqual((await call<string[]>(p, "titles", "kw", "notes", 2)).join(), "one,two");
  },
  // A worker that has the store's lock fails to open the node after it has opened the store, its segments still being
  // opened: it lets go of the lock only once it has let go of every file, so the next in line never finds one held.
  async tab_open_fails() {
    const a = await page();
    await a.preamble(files({ who: "failing", slow: 100, slowLog: 2000, failCut: true }));
    const b = await page();
    await b.preamble(files({ who: "next" }));
    const failing = call<string>(a, "deviceOrError", "of");
    // a's worker has the lock once it has opened a file of the store, and opens the rest slowly.
    await eventually(async () => (await filesSaid(b, "failing")).some((f) => f.opened > 0), "the first has the store");
    const next = call<string>(b, "deviceOrError", "of"); // in line
    const failed = await failing;
    if (!/the disk is full/.test(failed)) throw new Error(`opened as it was made to fail: ${failed}`);
    // Told at once that the node it waited for could not be opened, as what is asked of one that never comes to be is: and
    // so it opens the store again, at once, while a's segment is still being opened.
    const first = await next;
    if (first !== "ok") expectEqual(await call<string>(b, "deviceOrError", "of"), "ok", "the next in line opened the store");
    const [f] = await filesSaid(b, "failing");
    const n = await filesSaid(b, "next");
    if (n.length === 0) throw new Error("the next in line opened no file");
    expectEqual(n.reduce((k, x) => k + x.held, 0), 0, "the next in line found a file held: the lock was let go of with a file open or being opened");
    // Eleven files, and the segment being opened as it failed, which it waited for, and closed: before it said it failed,
    // which is when its tab stops it.
    if (!f || f.opened !== 12 || f.closed !== f.opened) throw new Error(`the failing worker closed ${f?.closed} of ${f?.opened} files, of 12: it let go of the store with one being opened`);
    await call(b, "create", "of");
    await call(b, "put", "of", "notes", ["one"]);
  },
  // The tab running the device hangs, its worker answering nothing and holding the store: a tab that opens the device is
  // told the store is locked, in time, rather than waiting for ever; and has it once the other is back.
  async tab_hung_leader() {
    const leader = await page();
    await call(leader, "device", "hl");
    await call(leader, "create", "hl");
    await call(leader, "put", "hl", "notes", ["one"]);
    const worker = leader.workers[leader.workers.length - 1];
    await leader.cdp("Debugger.enable", {}, worker);
    await leader.cdp("Debugger.pause", {}, worker); // at whatever it next does, which is to hear the next tab
    const other = await page();
    const t = performance.now();
    const said = await within(15000, call<string>(other, "deviceOrError", "hl"));
    const took = performance.now() - t;
    console.log(`     said to be locked in ${took.toFixed(0)} ms: ${said}`);
    if (!said.startsWith("StoreLocked (StoreLocked): ")) throw new Error(`a store held by a tab that answers nothing: ${said}`);
    await leader.cdp("Debugger.resume", {}, worker);
    await leader.cdp("Debugger.disable", {}, worker);
    expectEqual(await call<string>(other, "deviceOrError", "hl"), "ok", "opened once the other is back");
    await call(other, "put", "hl", "notes", ["two"]);
    expectEqual((await call<string[]>(other, "titles", "hl", "notes", 2)).join(), "one,two");
  },
  // The renderer of the tab running the device crashes, worker and all: the device is had again by a tab opened after, if
  // the browser lets go of what the renderer held, as it does but on Linux, where Chrome has been seen to leave a crashed
  // renderer, and its lock, as they were; and if it does not, that tab is told the store is locked, rather than nothing.
  async tab_crashed_leader() {
    const p = await page();
    await call(p, "device", "rk");
    await call(p, "create", "rk");
    await call(p, "put", "rk", "notes", ["one", "two"]);
    // The next in line may have a renderer of its own, or share the leader's, as Chrome may put tabs of a site together,
    // and crash with it: a tab opened after has the device either way, run by the one or the other.
    const next = await page();
    await call(next, "device", "rk");
    await call(next, "put", "rk", "notes", ["three"]);
    void p.cdp("Page.crash").catch(() => {});
    const survived = (await within(2000, next.evaluate<number>("1"))) === 1;
    console.log(`     the leader's renderer crashed, ${survived ? "the next in line's renderer another" : "and the next in line's with it"}`);
    const after = await page();
    const crashed = performance.now();
    const opened = await within(15000, call<string>(after, "deviceOrError", "rk"));
    const told = survived ? await within(2000, call<string[]>(next, "failures")) : [];
    console.log(`     a tab opened after was answered ${(performance.now() - crashed).toFixed(0)} ms later; the next in line was told ${JSON.stringify(told)}`);
    if (opened !== "ok") {
      if (!opened.startsWith("StoreLocked (StoreLocked): the store is held by something that does not answer")) throw new Error(`opened once the leader crashed: ${opened}`);
      console.log("     the crashed renderer's lock was never let go of: said to be locked");
      return;
    }
    expectEqual(await within(10000, call(after, "put", "rk", "notes", ["four"]).then(() => "written")), "written", "written once the leader crashed");
    expectEqual((await call<string[]>(after, "titles", "rk", "notes", 4)).join(), "one,two,three,four");
  },
  // The tab running the device is frozen as it closes it, its worker still letting go of a segment being opened: the
  // worker is stopped, as a frozen tab's always is, rather than frozen holding the store; and another tab has it at once.
  async tab_frozen_closing() {
    const leader = await page();
    await leader.preamble(files({ who: "closing", slowLog: 4000 }));
    await call(leader, "device", "zc");
    await call(leader, "create", "zc");
    await leader.evaluate("window.__closed = window.zsp.close('zc'), 1");
    const other = await page();
    await sleep(50);
    await leader.cdp("Page.setWebLifecycleState", { state: "frozen" });
    const t = performance.now();
    const said = await within(15000, call<string>(other, "deviceOrError", "zc"));
    const took = performance.now() - t;
    expectEqual(said, "ok", "opened while the other, frozen as it closed the device, let go of it");
    if (took > 2500) throw new Error(`opened only after ${took.toFixed(0)} ms, the other frozen holding the store`);
    await leader.cdp("Page.setWebLifecycleState", { state: "active" });
    await leader.evaluate("window.__closed");
  },
  // A tab's worker carries its pipe to the leader's, which never hears of it: the pipe is broken off, and the client
  // dials again, rather than waiting for ever.
  async tab_unheard() {
    const leader = await page();
    await call(leader, "device", "un");
    await call(leader, "create", "un");
    const follower = await page();
    await call(follower, "device", "un");
    // The first pipe the follower's worker asks the leader for goes astray.
    const worker = follower.workers[follower.workers.length - 1];
    const dropped = await follower.cdp<{ result: { value: number } }>(
      "Runtime.evaluate",
      {
        expression: `(() => { const post = BroadcastChannel.prototype.postMessage; let lost = false;
          BroadcastChannel.prototype.postMessage = function (m) { if (!lost && m && typeof m === "object" && "open" in m) { lost = true; return; } return post.call(this, m); };
          return 1; })()`,
        returnByValue: true,
      },
      worker,
    );
    expectEqual(dropped.result.value, 1, "the worker was reached");
    expectEqual(await within(15000, call(follower, "put", "un", "notes", ["one"]).then(() => "written")), "written", "written though the first pipe was lost");
  },
  // Every tab may give the device a credential, as the one it was opened with expires; whichever runs it presents the
  // newest given, and so does whichever runs it next.
  async tab_credential() {
    let r = await relay("first");
    const port = Number(r.address.split(":").pop());
    const via = { key: r.key, url: r.url };
    const owner = join(TMP, "cr-owner");
    const sid = zspd("create", owner);
    zspd("relay", owner, via.key, via.url);
    let o = await node("run", owner, "--credential=first");
    const reader = () => new Client({ connect: zspdConnect(o.address), credential: token(owner) });
    let watching = reader();
    let titles = "";
    const watch = (c: Client) => c.window({ scope: 1, list: "notes", table: { title: columns.string(16) } }, (st) => (titles = st.rows.map((x) => x.title).join()));
    watch(watching);
    const a = await page();
    const { key } = await call<{ key: string }>(a, "device", "cr", "first");
    zspd("admit", owner, key, "1");
    await call(a, "join", "cr", sid, via);
    await call(a, "put", "cr", "notes", ["one"]);
    await eventually(() => titles === "one", "the relay lets in what presents the credential it was opened with", 20000);
    const c = await page();
    await call(c, "device", "cr"); // in line, and given no credential of its own
    // The relay now lets in only what presents "second", which the device was not opened with.
    const again = async (t: string) => {
      watching.close();
      await stop(o.p);
      await stop(r.p);
      r = await relay(t, port);
      o = await node("run", owner, `--credential=${t}`);
      watching = reader();
      watch(watching);
    };
    await again("second");
    await call(a, "put", "cr", "notes", ["two"]);
    await sleep(3000);
    expectEqual(titles.includes("two"), false, "what presents the old credential is not let in");
    const b = await page();
    await call(b, "device", "cr", "second"); // a tab opened with the new one gives it
    await eventually(() => titles === "one,two", "a credential a newer tab gives is presented", 20000);
    await gone(a); // and c, next in line, runs it, presenting the newest given, though not by it
    await call(c, "put", "cr", "notes", ["three"]);
    await eventually(() => titles === "one,two,three", "the next to run the device presents the newest given", 20000);
    await again("third");
    await call(b, "setCredential", "cr", "third"); // as a tab does when the one it was given expires
    await call(b, "put", "cr", "notes", ["four"]);
    await eventually(() => titles === "one,two,three,four", "one set as the old expires is presented", 20000);
    watching.close();
  },
  // A tab whose timers are held back, as a hidden tab's are, types: what it typed is sealed when it should be, by its
  // device's worker's timers, and so another tab comes to hold it sealed. Held back for good here, rather than a minute:
  // a piece sealed by one of the tab's own timers would never be, and the reader never hold it, however fast or slow the
  // machine. (Not that the reader never stops showing it: that the piece reaches it within the ten seconds it shows live
  // text unconfirmed rests on the machine, as tab_late_seal shows: a busy runner once took longer.)
  async tab_held_seal() {
    const writer = await page();
    await call(writer, "device", "hs");
    await call(writer, "create", "hs");
    await call(writer, "put", "hs", "warm", ["its client ready"]);
    const reader = await page();
    await call(reader, "device", "hs");
    await call(reader, "watchText", "hs", "docs");
    await call(writer, "holdTimers");
    await call(writer, "type", "hs", "docs", ["typed ", "while ", "held back"]);
    const seen = () => call<{ shown: string; now: string; dropped: boolean; sealed: boolean }>(reader, "textSeen");
    await eventually(async () => (await seen()).shown === "typed while held back", "the reader sees it");
    // However long the machine takes to say it: what is waited for is never done, if it leans on the tab's timers.
    await eventually(async () => (await seen()).sealed, "what a tab typed with its timers held back is sealed", 60000);
    expectEqual((await seen()).now, "typed while held back", "what the reader shows of it, sealed");
  },
  // What a tab typed is sealed later than another tab shows live text unconfirmed, as when the worker running the device
  // is held up, as a busy machine's storage may hold it: the reader stops showing it, as it would live text whose writer
  // went quiet, and shows it again, all of it, once it is sealed. Nothing typed is lost to a slow machine. (As
  // tab_held_seal once failed on CI's Windows, its reader having nothing of the piece ten seconds on.)
  async tab_late_seal() {
    const writer = await page();
    await call(writer, "device", "ls");
    await call(writer, "create", "ls");
    await call(writer, "put", "ls", "warm", ["its client ready"]);
    const reader = await page();
    await call(reader, "device", "ls");
    await call(reader, "watchText", "ls", "docs");
    // The writer's worker, which keeps its clients' time, says that a time asked for is up only once it is let: as when it
    // is held up, as is the node it runs.
    const worker = writer.workers[writer.workers.length - 1];
    const evaluate = async (expression: string) =>
      (await writer.cdp<{ result: { value: unknown } }>("Runtime.evaluate", { expression, returnByValue: true }, worker)).result.value;
    const holding = await evaluate(`(() => { const post = self.postMessage.bind(self); const held = [];
      self.postMessage = (m, t) => (m && typeof m === "object" && "due" in m ? void held.push(m) : post(m, t));
      self.letTimers = () => { self.postMessage = post; for (const m of held.splice(0)) post(m); return true; };
      return true; })()`);
    expectEqual(holding, true, "the worker was reached");
    await call(writer, "type", "ls", "docs", ["typed ", "and ", "sealed late"]);
    const seen = () => call<{ shown: string; now: string; dropped: boolean; sealed: boolean }>(reader, "textSeen");
    await eventually(async () => (await seen()).shown === "typed and sealed late", "the reader sees it");
    await eventually(async () => (await seen()).dropped, "the reader stops showing live text unconfirmed for ten seconds", 30000);
    const blank = await seen();
    expectEqual({ now: blank.now, sealed: blank.sealed }, { now: "", sealed: false }, "nothing sealed it meanwhile, and the reader shows none of it");
    expectEqual(await evaluate("self.letTimers()"), true, "the worker let its timers go");
    await eventually(async () => (await seen()).sealed, "what was typed is sealed once the worker goes on", 60000);
    expectEqual((await seen()).now, "typed and sealed late", "what the reader shows again, sealed");
  },
  // A tab that opens the device after a credential was given, and gives none, presents the newest given though it heard
  // of none being given; a tab that comes back from being frozen does not present what it gave as newer than what was
  // given while it was away; and nothing said on the channel, nonsense or a credential said to be from the future, is
  // thrown at, or keeps a credential given later from being presented.
  async tab_credential_later() {
    let r = await relay("first");
    const port = Number(r.address.split(":").pop());
    const via = { key: r.key, url: r.url };
    const owner = join(TMP, "cl-owner");
    const sid = zspd("create", owner);
    zspd("relay", owner, via.key, via.url);
    let o = await node("run", owner, "--credential=first");
    let watching: Client | undefined;
    let titles = "";
    const watch = () => {
      watching?.close();
      watching = new Client({ connect: zspdConnect(o.address), credential: token(owner) });
      watching.window({ scope: 1, list: "notes", table: { title: columns.string(16) } }, (st) => (titles = st.rows.map((x) => x.title).join()));
    };
    watch();
    const again = async (t: string) => {
      watching?.close();
      await stop(o.p);
      await stop(r.p);
      r = await relay(t, port);
      o = await node("run", owner, `--credential=${t}`);
      watch();
    };
    const a = await page();
    const { key } = await call<{ key: string }>(a, "device", "cl", "first");
    zspd("admit", owner, key, "1");
    await call(a, "join", "cl", sid, via);
    await call(a, "put", "cl", "notes", ["one"]);
    await eventually(() => titles === "one", "the relay lets in what presents the credential it was opened with", 20000);
    const b = await page();
    await call(b, "device", "cl"); // after "first" was given, and given none
    await gone(a); // b runs it now
    await again("first"); // and so dials again, presenting what it has
    await call(b, "put", "cl", "notes", ["two"]);
    await eventually(() => titles === "one,two", "a tab opened after a credential was given presents it", 20000);
    // Nonsense on the channel, and credentials from the future.
    said.length = 0;
    await call(b, "shout", "cl", null);
    await call(b, "shout", "cl", 7);
    await call(b, "shout", "cl", { failed: 5 });
    await call(b, "shout", "cl", { credential: "poison", at: Number.MAX_VALUE, by: "z" });
    await call(b, "shout", "cl", { credential: "poison", at: Date.now() + 2 ** 41, by: "z" });
    await call(b, "shout", "cl", { credential: "poison", at: 2 ** 52, by: "z" });
    const c = await page();
    await call(c, "device", "cl", "first"); // given now, and so newest, until b gives another
    await again("second");
    await call(b, "setCredential", "cl", "second");
    await call(b, "put", "cl", "notes", ["three"]);
    await eventually(() => titles === "one,two,three", "a credential given after nonsense was said is presented", 20000);
    // c, which gave "first", is frozen and comes back: it does not give "first" as newer than "second".
    await c.cdp("Page.setWebLifecycleState", { state: "frozen" });
    await c.cdp("Page.setWebLifecycleState", { state: "active" });
    await call(c, "member", "cl"); // its worker started again, and has said what it gave
    await again("second"); // b dials again, presenting the newest
    await call(b, "put", "cl", "notes", ["four"]);
    await eventually(() => titles === "one,two,three,four", "what a tab back from being frozen gave before is not taken as newer", 20000);
    // The machine's clock is set back five minutes, in every tab and worker, as a clock put right is: what c gives now is
    // still the newest, and so taken by b, which runs the device. (Less than the quarter of an hour a relay allows a clock
    // to be wrong by: a machine set back further would be refused by relays anyway.)
    const back = "(() => { const was = Date.now; Date.now = () => was() - 300000; return 1; })()";
    for (const p of [b, c]) {
      await p.evaluate(back);
      await p.cdp("Runtime.evaluate", { expression: back }, p.workers[p.workers.length - 1]);
    }
    await again("third");
    await call(c, "setCredential", "cl", "third");
    await call(b, "put", "cl", "notes", ["five"]); // put in the list as of five minutes ago, by the clock as it is now
    await eventually(() => titles.split(",").includes("five"), "what is given after the clock was set back is presented", 20000);
    expectEqual(said.filter((l) => /uncaught/i.test(l)), [], "nonsense on the channel was thrown at");
    watching?.close();
  },
  // Tabs whose clocks are ahead of a tab opened after, as all are after the machine's clock is set back: the new one presents
  // what they gave, and what it gives is taken as newer by the one running the device, which presents it.
  async tab_credential_clock() {
    let r = await relay("first");
    const port = Number(r.address.split(":").pop());
    const via = { key: r.key, url: r.url };
    const owner = join(TMP, "cc-owner");
    const sid = zspd("create", owner);
    zspd("relay", owner, via.key, via.url);
    let o = await node("run", owner, "--credential=first");
    let watching: Client | undefined;
    let titles = "";
    const watch = () => {
      watching?.close();
      watching = new Client({ connect: zspdConnect(o.address), credential: token(owner) });
      watching.window({ scope: 1, list: "notes", table: { title: columns.string(16) } }, (st) => (titles = st.rows.map((x) => x.title).join()));
    };
    watch();
    const again = async (t: string) => {
      watching?.close();
      await stop(o.p);
      await stop(r.p);
      r = await relay(t, port);
      o = await node("run", owner, `--credential=${t}`);
      watch();
    };
    const a = await page();
    await a.evaluate("(() => { const was = Date.now; Date.now = () => was() + 300000; return 1; })()"); // five minutes ahead
    const { key } = await call<{ key: string }>(a, "device", "cc", "first");
    zspd("admit", owner, key, "1");
    await call(a, "join", "cc", sid, via);
    await call(a, "put", "cc", "notes", ["one"]);
    await eventually(() => titles === "one", "the relay lets in what presents the credential it was opened with", 20000);
    const d = await page(); // its clock five minutes behind what a gave by
    await call(d, "device", "cc");
    await again("second");
    await call(d, "setCredential", "cc", "second");
    await call(d, "put", "cc", "notes", ["two"]);
    await eventually(() => titles.split(",").includes("two"), "what a tab whose clock is behind gives is taken as newer", 20000);
    // Given as the tab is put away, before its worker hears of it: its next worker gives it, as newest still.
    await again("third");
    const paused = d.workers[d.workers.length - 1]; // and so hears of nothing, until it is stopped
    await d.cdp("Debugger.enable", {}, paused);
    await d.cdp("Debugger.pause", {}, paused);
    await call(d, "setCredentialAndFreeze", "cc", "third");
    await call(d, "put", "cc", "notes", ["two again"]);
    await eventually(() => titles.split(",").includes("two again"), "a credential given as its tab was put away is given by its next worker", 20000);
    await gone(a); // d runs it now, presenting what it gave
    await again("third");
    await call(d, "put", "cc", "notes", ["three"]);
    await eventually(() => titles.split(",").includes("three"), "and it is presented by the tab whose clock is behind, running it", 20000);
    // And a tab opened after with none of its own presents the newest given, however far ahead of its clock.
    const e = await page();
    await e.evaluate("(() => { const was = Date.now; Date.now = () => was() - 600000; return 1; })()");
    await call(e, "device", "cc");
    await gone(d);
    await again("third");
    await call(e, "put", "cc", "notes", ["four"]);
    await eventually(() => titles.split(",").includes("four"), "a tab whose clock is behind presents the newest given, given ahead of it", 20000);
    // A tab whose clock is ahead gives one, and then one whose clock is behind another: its worker gives that again as newer,
    // and tells its tab, which gives it so to the next it starts. All put away and back, every worker begun again, it is
    // the newest still, though the first was said to be given later by its tab's clock.
    const g = await page();
    await g.evaluate("(() => { const was = Date.now; Date.now = () => was() + 300000; return 1; })()");
    await call(g, "device", "cc", "first");
    const f = await page();
    await call(f, "device", "cc", "fourth");
    await again("fourth");
    await call(e, "put", "cc", "notes", ["five"]);
    await eventually(() => titles.split(",").includes("five"), "a credential a tab opened with, given behind another, is given as newer", 20000);
    for (const p of [e, f, g]) await p.cdp("Page.setWebLifecycleState", { state: "frozen" });
    for (const p of [e, f, g]) await p.cdp("Page.setWebLifecycleState", { state: "active" });
    for (const p of [e, f, g]) await call(p, "member", "cc");
    await again("fourth");
    await call(e, "put", "cc", "notes", ["six"]);
    await eventually(() => titles.split(",").includes("six"), "and still once all are put away and back", 20000);
    watching?.close();
  },
  // A tab that closes its device, its node run by another tab's worker, tells its clients their pipes are gone.
  async tab_close_follower() {
    const leader = await page();
    await call(leader, "device", "cf");
    await call(leader, "create", "cf");
    const follower = await page();
    await call(follower, "device", "cf");
    await call(follower, "put", "cf", "notes", ["one"]);
    expectEqual(await call<boolean>(follower, "closeDevice", "cf"), true, "a client of a closed device was not told");
  },
  // What a tab asked of another's node, which went as it did it, is said to have failed, for it may have been done: it is
  // not done again by the next to run the device.
  async tab_gone_asking() {
    const leader = await page();
    await call(leader, "device", "ga");
    await call(leader, "create", "ga");
    const follower = await page();
    await call(follower, "device", "ga");
    expectEqual(await call<string>(follower, "scopeOrError", "ga"), "2");
    // The leader does what it is asked, and goes before its answer is had.
    const worker = leader.workers[leader.workers.length - 1];
    await leader.cdp(
      "Runtime.evaluate",
      {
        expression: `(() => { const post = BroadcastChannel.prototype.postMessage;
          BroadcastChannel.prototype.postMessage = function (m) { if (m && typeof m === "object" && "answer" in m) return; return post.call(this, m); };
          return 1; })()`,
      },
      worker,
    );
    await call(follower, "scopeLater", "ga");
    await sleep(500); // done there, and not answered
    await gone(leader);
    await eventually(async () => (await call<string[]>(follower, "asked")).length > 0, "what was asked is answered");
    const answer = (await call<string[]>(follower, "asked"))[0];
    expectEqual(answer.startsWith("error"), true, `asked as the leader went, it was answered ${answer}: done again`);
    expectEqual(await call<string>(follower, "scopeOrError", "ga"), "4", "what was done as the leader went was not done, or done twice");
  },
};

// In a Chrome that holds back hidden tabs as it does for anyone, and after three seconds rather than five minutes.
const GRACE = 3;
const held: Record<string, () => Promise<void>> = {
  // A node in a hidden page, rather than a worker, finding an answer a step at a time: it is not held back between steps.
  async tab_hidden_ask() {
    const p = await page();
    await call(p, "pageNode", 12000, 16);
    await page(); // and so the first is hidden
    await sleep(GRACE * 1000 + 1000);
    // Held back, each step would wait for the next minute; not, they take milliseconds, or a second or two on a machine
    // that runs a hidden tab at the least priority there is, as macOS does.
    const ms = await call<number>(p, "pageNodeAsk", 20000);
    console.log(`     a question of 12000 rows answered in ${ms.toFixed(0)} ms in a hidden page`);
    if (ms < 0) throw new Error("a question of a node in a hidden page was not answered in 20 s: held back between its steps");
  },
  // A node in a hidden page, rather than a worker, whose client waits for room: another client is answered at once.
  async tab_hidden_node() {
    const p = await page();
    await call(p, "pageNode", 2000);
    await page(); // and so the first is hidden
    await sleep(GRACE * 1000 + 1000);
    await call(p, "pageNodeRead");
    await sleep(8000); // long enough for each turn it waits for to be a timer held back to the minute, were it one
    const { rows, ms } = await call<{ rows: number; ms: number }>(p, "pageNodeAnswers");
    console.log(`     a new client answered in ${ms.toFixed(0)} ms, the reader having ${rows} rows of 2000`);
    if (ms > 1000) throw new Error(`a new client of a node in a hidden page was answered after ${ms.toFixed(0)} ms`);
  },
};

async function main(): Promise<void> {
  const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : [...Object.keys(tests), ...Object.keys(held)];
  let failed = 0;
  let throttled: boolean | undefined;
  for (const name of names) {
    // Every test of a kind in one Chrome: the held back ones in one of their own.
    if (throttled !== name in held) {
      await chrome?.close();
      throttled = name in held;
      const flags = [`--enable-features=IntensiveWakeUpThrottling:grace_period_seconds/${GRACE}`];
      chrome = await Chrome.launch(throttled ? { throttled, flags } : {});
    }
    const start = performance.now();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      const limit = new Promise<never>((_, fail) => (timer = setTimeout(() => fail(new Error("not done in three minutes")), 180000)));
      chrome!.uncaught.length = 0;
      await Promise.race([(tests[name] ?? held[name])(), limit]);
      // What a page threw that nothing caught fails the test, though nothing it looked at went wrong.
      if (chrome!.uncaught.length > 0) throw new Error("uncaught in a page: " + chrome!.uncaught.join("; "));
      console.log(`ok   ${name} ${((performance.now() - start) / 1000).toFixed(2)}s`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${e instanceof Error ? e.stack : e}`);
    } finally {
      clearTimeout(timer);
      for (const p of pages.splice(0)) await p.close().catch(() => {});
      await stopAll();
    }
  }
  await chrome?.close();
  site.close();
  if (!failed) await cleanUp();
  process.exit(failed ? 1 : 0);
}

await main();
