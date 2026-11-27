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
      addEventListener('pageshow', (e) => e.persisted && localStorage.setItem('restored', 'true'));
      location.href = '/elsewhere', 1`);
    await eventually(async () => (await follower.evaluate("localStorage.getItem('cached')")) !== null);
    expectEqual(await follower.evaluate("localStorage.getItem('cached')"), "true", "the leader was put in the back/forward cache");
    expectEqual(await within(10000, call(follower, "put", "bf", "notes", ["two"]).then(() => "written")), "written", "written while it is cached");
    await leader.evaluate("history.back(), 1");
    await eventually(async () => (await follower.evaluate("localStorage.getItem('restored')")) !== null);
    expectEqual(await follower.evaluate("localStorage.getItem('restored')"), "true", "and taken from it again");
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
  // A tab whose timers are held back, as a hidden tab's are, types: what it typed is sealed when it should be, and so
  // another tab that shows it never stops showing it, as it would live text whose writer has gone quiet unsealed.
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
    await eventually(async () => (await call<{ shown: string }>(reader, "textSeen")).shown === "typed while held back", "the reader sees it");
    await sleep(13000); // longer than live text is shown unsealed
    const seen = await call<{ shown: string; dropped: boolean }>(reader, "textSeen");
    expectEqual(seen, { shown: "typed while held back", dropped: false }, "what a tab typed with its timers held back, after a while");
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
    await call(b, "shout", "cl", { credential: "poison", at: Date.now() + 3600000, by: "z" });
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
    expectEqual(said.filter((l) => /uncaught/i.test(l)), [], "nonsense on the channel was thrown at");
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
      await Promise.race([(tests[name] ?? held[name])(), limit]);
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
