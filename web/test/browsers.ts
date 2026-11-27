// Web devices in a browser: headless Chrome, its origin's private file system, its workers, its WebSockets. Each runs
// test/live.ts against a zspd device through zspd's relay, and against another browser device through the Durable
// Object; tabs share one device and hand it on when the one running it goes; and a device is what it was after a
// restart, with nothing to reach. `node test/browsers.ts [names...]`

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createServer as http } from "node:http";
import { createServer as tcp, connect as dial } from "node:net";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { Chrome, findChrome, type Page } from "./chrome.ts";
import { cloud, eventually, exists, expectEqual, node, proxy, stopAll, cleanUp, ROOT, TMP, token, zspd, zspdConnect } from "./procs.ts";
import { Client, columns, type State } from "../src/client.ts";
import type { Side } from "./browser.ts";

// A machine without a browser cannot run these, and says so; but CI is never such a machine.
if (!findChrome()) {
  if (process.env.CI) throw new Error("no Chrome here: set CHROME to where it is");
  console.log("skip browsers: no Chrome here; set CHROME to where it is");
  process.exit(0);
}

const WEB = join(ROOT, "web");
execFileSync(process.execPath, [join(WEB, "build.ts"), "--test"], { stdio: "inherit" });

// The test page, and what it loads, from this origin.
const TYPES: Record<string, string> = { ".js": "text/javascript", ".wasm": "application/wasm", ".html": "text/html" };
const held: (() => void)[] = []; // asked for held.wasm, which is not there: said so when let go
let onceAsked = false;
const site = http((req, res) => {
  const path = new URL(req.url!, "http://x").pathname;
  if (path === "/held.wasm") {
    held.push(() => res.writeHead(404).end());
    return;
  }
  if (path === "/once.wasm" && !onceAsked) {
    onceAsked = true; // not there the first time, and there after
    res.writeHead(404).end();
    return;
  }
  if (path === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><meta charset="utf-8"><script type="module" src="/test.js"></script>');
    return;
  }
  try {
    const body = readFileSync(join(WEB, "dist", path === "/once.wasm" ? "node.wasm" : path.slice(1)));
    res.writeHead(200, { "content-type": TYPES[path.slice(path.lastIndexOf("."))] ?? "application/octet-stream" });
    res.end(body);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise<void>((done) => site.listen(0, "127.0.0.1", done));
const origin = `http://127.0.0.1:${(site.address() as AddressInfo).port}/`;

// A local client of zspd from a page, through this: zspd rightly hears from no page, so the Origin goes.
async function bridge(address: string): Promise<string> {
  const [host, port] = [address.slice(0, address.lastIndexOf(":")), Number(address.slice(address.lastIndexOf(":") + 1))];
  const server = tcp((from) => {
    let head = Buffer.alloc(0);
    const first = (d: Buffer) => {
      head = Buffer.concat([head, d]);
      const end = head.indexOf("\r\n\r\n");
      if (end < 0) return;
      from.off("data", first);
      from.pause();
      const lines = head.subarray(0, end).toString("latin1").split("\r\n").filter((l) => !/^origin:/i.test(l));
      const to = dial(port, host, () => {
        to.write(lines.join("\r\n") + "\r\n\r\n");
        to.write(head.subarray(end + 4));
        from.pipe(to).pipe(from);
        from.resume();
      });
      to.on("error", () => from.destroy());
      from.on("error", () => to.destroy());
    };
    from.on("data", first);
  });
  await new Promise<void>((done) => server.listen(0, "127.0.0.1", done));
  return `ws://127.0.0.1:${(server.address() as AddressInfo).port}/`;
}

let chrome: Chrome;
const pages: Page[] = [];
async function page(): Promise<Page> {
  const p = await chrome.open(origin, (line) => console.log("     page: " + line));
  await p.evaluate("new Promise((done) => { const go = () => window.zsp ? done() : setTimeout(go, 10); go(); })");
  pages.push(p);
  return p;
}

const call = <T>(p: Page, f: string, ...args: unknown[]) =>
  p.evaluate<T>(`window.zsp.${f}(${args.map((a) => (a === undefined ? "undefined" : JSON.stringify(a))).join(", ")})`);

// A space with scope 1, and scope 2 signed in which b may vouch: a goes by "ann" and b by "bob". Its owner is zspd's.
async function space(name: string, relay: { key: string; url: string }, credential = "") {
  const owner = join(TMP, name + "-owner");
  const sid = zspd("create", owner);
  zspd("relay", owner, relay.key, relay.url);
  expectEqual(zspd("scope", owner, "signed"), "2");
  const o = await node("run", owner, ...(credential ? [`--credential=${credential}`] : []));
  const admit = (key: string, subject: string, vouch: boolean) => {
    zspd("admit", owner, key, "1");
    zspd("admit", owner, key, "2", ...(vouch ? ["vouch"] : []));
    zspd("subject", owner, key, subject);
  };
  return { owner, sid, admit, o };
}

async function browserDevice(p: Page, store: string, s: { sid: string; admit: (k: string, sub: string, v: boolean) => void }, relay: { key: string; url: string }, subject: string, vouch: boolean, credential?: string) {
  const { key } = await call<{ key: string }>(p, "device", store, credential);
  s.admit(key, subject, vouch);
  await call(p, "join", store, s.sid, relay);
  return key;
}

const tests: Record<string, () => Promise<void>> = {
  // A browser's device, and a zspd device's client in the same page, through zspd's relay.
  async browser_with_zspd() {
    const relay = await node("serve", join(TMP, "bz-relay"));
    const s = await space("bz", relay);
    const p = await page();
    await browserDevice(p, "bz-a", s, relay, "ann", false);
    const dir = join(TMP, "bz-b");
    const key = zspd("key", dir);
    s.admit(key, "bob", true);
    zspd("join", dir, s.sid, relay.key, relay.url);
    const b = await node("run", dir);
    await eventually("it hears who belongs", () => exists(join(dir, s.sid, "roster")));
    const said = await call<string>(p, "live", { device: "bz-a" } satisfies Side, { bridge: await bridge(b.address), token: token(dir) } satisfies Side);
    console.log(said);
  },
  // Two browser devices, of different stores, through the Durable Object.
  async browsers_cloud() {
    const relay = await cloud({ ACCESS_TOKEN: "sesame" });
    const s = await space("bc", relay, "sesame");
    const p = await page();
    await browserDevice(p, "bc-a", s, relay, "ann", false, "sesame");
    await browserDevice(p, "bc-b", s, relay, "bob", true, "sesame");
    const said = await call<string>(p, "live", { device: "bc-a" } satisfies Side, { device: "bc-b" } satisfies Side);
    console.log(said);
  },
  // Tabs of one origin share its device; when the tab running it goes, another runs it, and nothing is lost.
  async browser_tabs() {
    const relay = await node("serve", join(TMP, "bt-relay"));
    const s = await space("bt", relay);
    const first = await page();
    const key = await browserDevice(first, "bt", s, relay, "ann", false);
    await call(first, "put", "bt", "notes", ["one"]);
    const second = await page();
    const again = await call<{ key: string }>(second, "device", "bt");
    expectEqual(again.key, key);
    expectEqual((await call<string[]>(second, "titles", "bt", "notes", 1)).join(), "one");
    await call(second, "put", "bt", "notes", ["two"]);
    expectEqual((await call<string[]>(first, "titles", "bt", "notes", 2)).join(), "one,two");
    // The tab that runs it goes, without a word.
    await first.close();
    pages.splice(pages.indexOf(first), 1);
    await call(second, "put", "bt", "notes", ["three"]);
    expectEqual((await call<string[]>(second, "titles", "bt", "notes", 3)).join(), "one,two,three");
    // And the rest of the space heard all of it.
    const dir = join(TMP, "bt-b");
    s.admit(zspd("key", dir), "bob", true);
    zspd("join", dir, s.sid, relay.key, relay.url);
    const b = await node("run", dir);
    const there = new Client({ connect: zspdConnect(b.address), credential: token(dir) });
    let titles = "";
    there.window({ scope: 1, list: "notes", table: { title: columns.string(16) } }, (st) => (titles = st.rows.map((r) => r.title).join()));
    await eventually("a zspd device has it all", () => titles === "one,two,three");
    there.close();
  },
  // A tab that goes takes with it what it was doing on another tab's node: what it served is served no longer, and a call
  // to it is answered so, rather than never.
  async browser_tab_gone() {
    const relay = await node("serve", join(TMP, "tg-relay"));
    const s = await space("tg", relay);
    const leader = await page();
    await browserDevice(leader, "tg", s, relay, "ann", false);
    const follower = await page();
    await call(follower, "device", "tg");
    await call(follower, "serve", "tg", "where", "here");
    expectEqual(await call<string>(leader, "request", "tg", "where", 5000), "here");
    await follower.close();
    pages.splice(pages.indexOf(follower), 1);
    // Answered while it goes, which is not at once; then one in flight as it goes may be lost; none goes unanswered, and
    // the next is told there is nobody to answer.
    let first = "here";
    await eventually("it is gone", async () => (first = await call<string>(leader, "request", "tg", "where", 5000)) !== "here");
    if (first !== "fault lost" && first !== "fault unserved") throw new Error(`a call to a tab that has gone: ${first}`);
    expectEqual(await call<string>(leader, "request", "tg", "where", 5000), "fault unserved");
  },
  // When the storage of the tab running a device fails, every tab is told, nothing made up is said, and another tab's
  // worker may then have the store, and runs it once it can.
  async browser_leader_fails() {
    const relay = await node("serve", join(TMP, "lf-relay"));
    const s = await space("lf", relay);
    const leader = await page();
    await browserDevice(leader, "lf", s, relay, "ann", false);
    const follower = await page();
    await call(follower, "device", "lf");
    await call(follower, "put", "lf", "notes", ["one"]);
    await follower.quota(1);
    for (let i = 0; i < 4; i++) await call(follower, "putLarge", "lf", "big", 900 << 10);
    await eventually("both tabs are told", async () => (await call<string[]>(leader, "failures")).length > 0 && (await call<string[]>(follower, "failures")).length > 0);
    // The follower's worker, next in line, has the store at once, and its storage is as full: it stops too, and says so.
    await eventually("the follower's worker tries, and stops", async () => (await call<string[]>(follower, "failures")).length > 1);
    await follower.quota(); // room again
    await leader.close(); // its worker has let go already; this tab may stay or go
    pages.splice(pages.indexOf(leader), 1);
    // Wanted again, the follower's worker tries again, and has the store: it says what is so, and what it writes is durable.
    const member = () => Promise.race([call<string>(follower, "memberOrError", "lf"), new Promise<string>((done) => setTimeout(() => done("no answer"), 2000))]);
    await eventually("the follower runs it", async () => (await member()) === "true");
    await call(follower, "put", "lf", "notes", ["two"]);
    expectEqual((await call<string[]>(follower, "titles", "lf", "notes", 2)).join(), "one,two");
  },
  // A pipe of one's own may be given a view of a buffer its giver goes on using: what it hands on is its own copy.
  async browser_pipe_copies() {
    const p = await page();
    await call(p, "device", "pc");
    await call(p, "create", "pc");
    expectEqual(await call<string>(p, "sendView", "pc"), "intact");
  },
  // What was asked of a node whose storage failed, and was told to the asker as failed, is not done after all by the next.
  async browser_failed_asks() {
    const leader = await page();
    await call(leader, "device", "fa");
    await call(leader, "create", "fa"); // the device owns its space: it may add scopes
    const follower = await page();
    await call(follower, "device", "fa");
    await call(follower, "put", "fa", "notes", ["one"]);
    await follower.quota(1);
    for (let i = 0; i < 4; i++) await call(follower, "putLarge", "fa", "big", 900 << 10);
    await call(follower, "scopeLater", "fa"); // asked as the node stops
    await eventually("the follower is told", async () => (await call<string[]>(follower, "failures")).length > 0);
    await eventually("and what it asked is answered", async () => (await call<string[]>(follower, "asked")).length > 0);
    await follower.quota();
    await leader.close();
    pages.splice(pages.indexOf(leader), 1);
    await eventually("the follower runs it", async () => (await call<string>(follower, "memberOrError", "fa")) === "true");
    const said = (await call<string[]>(follower, "asked"))[0];
    const next = await call<string>(follower, "scopeOrError", "fa");
    // Either it was done, and said so, or it was not done at all.
    expectEqual(next, said.startsWith("error") ? "2" : "3");
  },
  // And what a worker was asked while it opened the store, when the opening fails, is not done by the next either.
  async browser_failed_opening() {
    const first = await page();
    await call(first, "device", "fo");
    await call(first, "create", "fo");
    const second = await page();
    await call(second, "deviceWith", "fo", "/held.wasm"); // whose worker, given the store, cannot load the node
    await first.close();
    pages.splice(pages.indexOf(first), 1);
    await eventually("the second opens the store", async () => held.length > 0);
    await call(second, "scopeLater", "fo"); // asked as it does
    await new Promise((done) => setTimeout(done, 100));
    for (const go of held.splice(0)) go();
    await eventually("the second is told", async () => (await call<string[]>(second, "failures")).length > 0);
    await eventually("and what it asked is answered", async () => (await call<string[]>(second, "asked")).length > 0);
    expectEqual((await call<string[]>(second, "asked"))[0].slice(0, 6), "error:");
    const third = await page();
    await call(third, "device", "fo");
    expectEqual(await call<string>(third, "scopeOrError", "fo"), "2"); // or 3, should what failed be done after all
  },
  // A tab whose worker could not start the node, once, is not left with a pipe to one that is gone: its client dials
  // again, and so the worker tries again, and runs it.
  async browser_start_fails_once() {
    const first = await page();
    await call(first, "device", "sf");
    await call(first, "create", "sf");
    const second = await page();
    await call(second, "deviceWith", "sf", "/once.wasm");
    await call(second, "put", "sf", "notes", ["one"]); // its client's pipe, carried to the first
    await first.close();
    pages.splice(pages.indexOf(first), 1);
    await eventually("the second's worker could not start it", async () => (await call<string[]>(second, "failures")).length > 0);
    const put = Promise.race([call(second, "put", "sf", "notes", ["two"]).then(() => "written"), new Promise<string>((done) => setTimeout(() => done("not written"), 8000))]);
    expectEqual(await put, "written");
    expectEqual((await call<string[]>(second, "titles", "sf", "notes", 2)).join(), "one,two");
  },
  // Whichever tab joins, makes or adopts a space, every tab's device says it is of it.
  async browser_space_told() {
    const one = await page();
    const two = await page();
    await call(one, "device", "st");
    await call(two, "device", "st");
    const made = await call<string>(two, "create", "st");
    await eventually("the other tab knows", async () => (await call<string | undefined>(one, "spaceOf", "st")) === made);
    // And a device that adopts a roster says it is of that roster's space.
    const owner = join(TMP, "st-owner");
    const sid = zspd("create", owner);
    await call(one, "device", "st-adopt");
    expectEqual(await call<boolean>(one, "adopt", "st-adopt", Array.from(readFileSync(join(owner, sid, "roster")))), true);
    expectEqual(await call<string | undefined>(one, "spaceOf", "st-adopt"), sid);
  },
  // A device is what it was after its tabs have all gone, with no relay to be had: its key, and what it held.
  // A browser's device is a partial replica unless told otherwise: it has the end of a big list at once and holds little
  // more; it says that what it shows is only what it holds while it reaches nobody, and shows that, after a restart too;
  // what it writes meanwhile reaches the others once it is back. Opened as a full replica it comes to hold everything, and
  // opened as a partial one again it loses nothing.
  async browser_partial() {
    const relay = await node("serve", join(TMP, "bp-relay"));
    const through = await proxy(relay.url);
    const via = { key: relay.key, url: through.url };
    const s = await space("bp", via);
    const writer = new Client({ connect: zspdConnect(s.o.address), credential: token(s.owner) });
    const Note = { title: columns.string(16) };
    await eventually("the writer may write", () => writer.may(1, "write"));
    for (let i = 0; i < 2000; i++) void writer.write(1, (c) => c.insert(Note, "feed", i, { title: "note " + i }));
    await writer.write(1, (c) => c.insert(Note, "feed", 2000, { title: "last" }));
    const first = await page();
    await browserDevice(first, "bp", s, via, "ann", false);
    const opened = performance.now();
    await call(first, "watch", "bp", "feed", 20);
    type Seen = { titles: string[]; status: string; before: number; after: number } | undefined;
    const seen = (p: Page, list: string, from?: string) => call<Seen>(p, "seen", "bp", list, from);
    await eventually("the end of the list, at once", async () => {
      const x = await seen(first, "feed");
      return x?.status === "ready" && x.titles.length === 20 && x.before === 1981 && x.titles[19] === "last";
    });
    console.log(`     the end of a list of 2001, in a browser that held none of it: ${(performance.now() - opened).toFixed(0)} ms`);
    const held = await call<number>(first, "held", "bp");
    if (held > 20000) throw new Error(`it holds ${held} bytes, as though it held the whole list`);

    // It reaches nobody.
    through.cut();
    await eventually("what it shows is said to be what it holds", async () => (await seen(first, "feed"))?.status === "stale");
    await call(first, "put", "bp", "feed", ["while away"]);
    await first.close();
    pages.splice(pages.indexOf(first), 1);
    const later = await page();
    await call(later, "device", "bp");
    await call(later, "watch", "bp", "feed", 3000, "start");
    await eventually("after a restart, what it held and what it wrote", async () => {
      const x = await seen(later, "feed", "start");
      return x?.status === "stale" && x.titles.length === 21 && x.titles.includes("while away");
    });

    // Back.
    through.mend();
    await eventually("kept up again", async () => (await seen(later, "feed", "start"))?.status === "ready", 20000);
    let theirs: State<typeof Note> | undefined;
    writer.window({ scope: 1, list: "feed", table: Note, size: 5 }, (x) => (theirs = x));
    await eventually("what it wrote while away is had by the others", () => theirs?.rows.some((r) => r.title === "while away") === true, 20000);
    await call(later, "unwatch", "bp", "feed", "start");
    await later.close();
    pages.splice(pages.indexOf(later), 1);

    // The same store, as a full replica, and then as a partial one again.
    const whole = await page();
    await call(whole, "device", "bp", undefined, true);
    await call(whole, "watch", "bp", "feed", 3000, "start");
    await eventually("as a full replica, all of it", async () => (await seen(whole, "feed", "start"))?.titles.length === 2002, 20000);
    await whole.close();
    pages.splice(pages.indexOf(whole), 1);
    const again = await page();
    await call(again, "device", "bp");
    await call(again, "put", "bp", "feed", ["partial again"]);
    await eventually("what it writes as a partial one again is had by the others", () => theirs?.rows.some((r) => r.title === "partial again") === true, 20000);
    writer.close();
  },
  async browser_restart() {
    const relay = await node("serve", join(TMP, "br-relay"));
    const s = await space("br", relay);
    const first = await page();
    const key = await browserDevice(first, "br", s, relay, "ann", false);
    const many = Array.from({ length: 50 }, (_, i) => "note " + i);
    await call(first, "put", "br", "notes", many);
    await first.close();
    pages.splice(pages.indexOf(first), 1);
    await stopAll();
    const later = await page();
    const back = await call<{ key: string; space?: string }>(later, "device", "br");
    expectEqual(back.key, key);
    expectEqual(back.space, s.sid);
    expectEqual((await call<string[]>(later, "titles", "br", "notes", 50)).join(), many.join());
  },
};

// Not a test, and not run unless named: `node test/browsers.ts bench`.
const bench = async () => {
  const relay = await node("serve", join(TMP, "bench-relay"));
  const s = await space("bench", relay);
  const p = await page();
  const { key, opened } = await call<{ key: string; opened: number }>(p, "benchOpen", "bench");
  s.admit(key, "ann", false);
  await call(p, "join", "bench", s.sid, relay);
  await browserDevice(p, "bench-b", s, relay, "bob", false);
  const rows = 20000;
  const r = await call<Record<string, number>>(p, "benchRun", "bench", rows, "bench-b");
  const ms = (x: number) => (x < 1 ? `${(x * 1000).toFixed(0)} µs` : `${x.toFixed(x < 10 ? 2 : 0)} ms`);
  console.log(`opening a device made from nothing: worker, node and store     ${ms(opened)}`);
  console.log(`one small durable write, in the origin's file system           ${ms(r.write)}`);
  console.log(`writing ${rows} rows, a thousand to a write                      ${ms(r.bulk)}, ${((rows / r.bulk) * 1000).toFixed(0)} rows/s`);
  console.log(`a page of 50 rows of ${rows}, to a client that holds none          ${ms(r.page)}`);
  console.log(`a streamed token, from one client of the device to another       ${ms(r.token)}`);
  console.log(`a streamed token, to another browser device through zspd's relay  ${ms(r.across)}`);
};

async function main(): Promise<void> {
  const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : Object.keys(tests);
  if (names[0] === "bench") tests.bench = bench;
  chrome = await Chrome.launch();
  let failed = 0;
  for (const name of names) {
    const start = performance.now();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      // However a page fails to answer, the test fails, by name, rather than waiting for ever.
      const limit = new Promise<never>((_, fail) => (timer = setTimeout(() => fail(new Error("not done in three minutes")), 180000)));
      await Promise.race([tests[name](), limit]);
      console.log(`ok   ${name} ${((performance.now() - start) / 1000).toFixed(2)}s`);
    } catch (e) {
      failed++;
      console.log(`FAIL ${name}: ${e instanceof Error ? e.stack : e}\n     in ${TMP}`);
    } finally {
      clearTimeout(timer);
      for (const go of held.splice(0)) go();
      for (const p of pages.splice(0)) await p.close().catch(() => {});
      await stopAll();
    }
  }
  await chrome.close();
  site.close();
  if (!failed) await cleanUp();
  process.exit(failed ? 1 : 0);
}

await main();
