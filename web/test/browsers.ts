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
import { where } from "../src/ask.ts";
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
    const { held } = await call<{ held: number }>(first, "usage", "bp");
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
    // Closed as a device is closed, it is stopped as it should be, and opened again it is as it was.
    await call(again, "close", "bp");
    await again.close();
    pages.splice(pages.indexOf(again), 1);
    const last = await page();
    await call(last, "device", "bp");
    expectEqual((await call<string[]>(last, "titles", "bp", "feed", 1)).includes("partial again"), true);
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

// Not a test, and not run unless named: `./x bench partial [rows]`, which runs zspd as a relay is built, optimised: a
// relay built for debugging is busy long after a big sync, and what connects then waits. A partial device against a full one, in
// Node and in Chrome, on a big space (so many rows, and large texts), over a good network and a poor one: how soon the
// end of a list is shown, how soon a large text is, and what each comes to hold, in memory and in storage.
const partialBench = async () => {
  const ROWS = Number(process.argv[3] ?? 100000), TEXTS = 20, TEXT = 400_000, WAIT = 300_000;
  // With LINGER=ms, what is held is measured so long after it is all there, once the store has had time to tidy up.
  const linger = () => new Promise((done) => setTimeout(done, Number(process.env.LINGER ?? 0)));
  const Row = { title: columns.string(16), body: columns.text(17) };
  const { open: openNode } = await import("../src/nodejs.ts");
  const { readdirSync, statSync } = await import("node:fs");
  const du = (dir: string): number =>
    readdirSync(dir, { withFileTypes: true }).reduce((n, e) => n + (e.isDirectory() ? du(join(dir, e.name)) : statSync(join(dir, e.name)).size), 0);
  const mb = (b: number) => `${(b / 2 ** 20).toFixed(1)} MB`;
  const ms = (x: number) => (x < 0 ? `> ${WAIT / 1000} s` : x < 1000 ? `${x.toFixed(0)} ms` : `${(x / 1000).toFixed(1)} s`);
  const results: string[][] = [];
  const networks = [
    { name: "good", slow: undefined },
    { name: "poor: 1.6 Mbit/s, 300 ms round trip", slow: { bytesPerSecond: 200_000, latency: 150 } },
  ];
  for (const net of networks.filter((n) => !process.env.NET || n.name.startsWith(process.env.NET))) {
    // A relay here, optimised; or, with CLOUD=wss://…, a Durable Object deployed, over the real network.
    const relay = process.env.CLOUD ? await cloud() : await node("serve", join(TMP, `pb-${results.length}-relay`));
    const through = await proxy(relay.url, net.slow);
    const via = { key: relay.key, url: through.url };
    const s = await space(`pb-${results.length}`, via);
    // The space: the owner writes it all, and a full device beside the relay, unthrottled, sees that it is all there.
    // Every device to be measured is made, and admitted, before anything is written: what is measured is what it takes a
    // device to have what it wants, not what it takes the owner to say it belongs, through the same slow network.
    const made = new Map<string, { node?: Awaited<ReturnType<typeof openNode>>; page?: Page; dir: string; store: string }>();
    for (const full of [false, true]) {
      const dir = join(TMP, `pb-${results.length}-node-${full}`);
      const d = await openNode({ dir, udp: false, full, log: () => {} });
      s.admit(d.key, "n", false);
      const p = await page();
      const store = `pb-${results.length}-${full}`;
      const { key } = await call<{ key: string }>(p, "device", store, undefined, full);
      s.admit(key, "c", false);
      made.set(String(full), { node: d, page: p, dir, store });
    }
    const writer = new Client({ connect: zspdConnect(s.o.address), credential: token(s.owner) });
    await eventually("the writer may write", () => writer.may(1, "write"));
    const began = performance.now();
    const writes: Promise<void>[] = [];
    for (let i = 0; i < ROWS; i += 1000)
      writes.push(writer.write(1, (c) => {
        for (let k = i; k < Math.min(i + 1000, ROWS); k++) c.insert(Row, "big", k, { title: `note ${k}`, body: `the quick brown fox jumps over the lazy dog, ${k} times over and again` });
      }));
    for (let i = 0; i < TEXTS; i++) writes.push(writer.write(1, (c) => c.insert(Row, "docs", i, { title: `doc ${i}`, body: String.fromCharCode(97 + (i % 26)).repeat(TEXT) })));
    await Promise.all(writes);
    const check = await openNode({ dir: join(TMP, `pb-${results.length}-check`), udp: false, log: () => {} });
    s.admit(check.key, "check", false);
    await check.join(s.sid, relay);
    // Every row, counted by a full device beside the relay: until then the owner is still sending it, slowly.
    const counter = check.client();
    const count = async (list: string) => (await counter.fetch({ scope: 1, table: {}, where: where.inList(list), limit: 1 })).total;
    await eventually("the relay has it all", async () => (await count("big")) === ROWS && (await count("docs")) === TEXTS, 1800000);
    let all = 0;
    await eventually("and has had it all", async () => {
      const held = (await check.usage()).held;
      const same = held === all;
      all = held;
      return same && (await new Promise((done) => setTimeout(done, 1000)), (await check.usage()).held === all);
    }, 60000);
    counter.close();
    await check.close();
    console.log(`     ${net.name}: ${ROWS} rows and ${TEXTS} texts of ${TEXT / 1000} KB, ${mb(all)}, written in ${ms(performance.now() - began)}`);
    // A full device holds everything once it holds what the one beside the relay does; a partial one is given ten seconds.
    const settle = async (full: boolean, held: () => Promise<number>, since: number): Promise<string> => {
      if (!full) {
        await new Promise((done) => setTimeout(done, 10000));
        return "";
      }
      for (let t = performance.now(); performance.now() - t < WAIT; await new Promise((done) => setTimeout(done, 250))) {
        if ((await held()) >= all * 0.999) return ms(performance.now() - since);
      }
      return ms(-1);
    };
    // Each device, made from nothing, joins through the network and is asked for the end of the list and a text.
    for (const full of [false, true]) {
      // In Node.
      const m = made.get(String(full))!;
      const dir = m.dir, d = m.node!;
      const t0 = performance.now();
      await d.join(s.sid, via);
      const c = d.client();
      const tail = await new Promise<number>((done) => {
        const w = c.window({ scope: 1, list: "big", table: Row, size: 50 }, (st) => {
          if (st.status === "ready" && st.rows.length >= 50 && st.rows[st.rows.length - 1].title === `note ${ROWS - 1}`) w.stop(), done(performance.now() - t0);
        });
        setTimeout(() => done(-1), WAIT);
      });
      const t1 = performance.now();
      const text = await new Promise<number>((done) => {
        const w = c.window({ scope: 1, list: "docs", table: Row, size: 1, from: "start" }, (st) => {
          if (st.rows[0]?.body.length === TEXT) w.stop(), done(performance.now() - t1);
        });
        setTimeout(() => done(-1), WAIT);
      });
      // And then, once a full one holds everything, and a partial one has had a while: what it holds, in memory and on disk.
      const whole = await settle(full, () => d.usage().then((u) => u.held), t0);
      await linger();
      const u = await d.usage();
      if (process.env.DU)
        for (const e of readdirSync(dir, { withFileTypes: true, recursive: true }))
          if (e.isFile()) console.log(`     ${join(e.parentPath, e.name).slice(dir.length)} ${mb(statSync(join(e.parentPath, e.name)).size)}`);
      results.push([net.name, "Node", full ? "full" : "partial", ms(tail), ms(text), whole, mb(u.held), mb(u.memory), mb(du(dir))]);
      console.log("     " + results[results.length - 1].join(" | "));
      c.close();
      await d.close();
      // In Chrome.
      const p = m.page!, store = m.store;
      const before = await call<number>(p, "estimate");
      const profiled = process.env.PROFILE && full ? p.workers[p.workers.length - 1] : undefined;
      if (profiled) {
        await p.cdp("Profiler.enable", {}, profiled);
        await p.cdp("Profiler.setSamplingInterval", { interval: 200 }, profiled);
        await p.cdp("Profiler.start", {}, profiled);
      }
      const t2 = performance.now();
      await call(p, "join", store, s.sid, via);
      const ctail = await call<number>(p, "timeTail", store, "big", 50, `note ${ROWS - 1}`, WAIT);
      const ctailAll = ctail < 0 ? -1 : performance.now() - t2;
      const ctext = await call<number>(p, "timeText", store, "docs", TEXT, WAIT);
      const cwhole = await settle(full, () => call<{ held: number }>(p, "usage", store).then((u) => u.held), t2);
      await linger();
      if (profiled) await summarise((await p.cdp<{ profile: any }>("Profiler.stop", {}, profiled)).profile);
      const cu = await call<{ held: number; memory: number }>(p, "usage", store);
      const after = await call<number>(p, "estimate");
      results.push([net.name, "Chrome", full ? "full" : "partial", ms(ctailAll), ms(ctext), cwhole, mb(cu.held), mb(cu.memory), mb(after - before)]);
      console.log("     " + results[results.length - 1].join(" | "));
      await call(p, "close", store);
      await p.close();
      pages.splice(pages.indexOf(p), 1);
    }
    writer.close();
    await stopAll();
  }
  console.log("\n| network | where | replica | the end of the list | a text of 400 KB | everything | held | memory | storage |");
  console.log("|---|---|---|---|---|---|---|---|---|");
  for (const r of results) console.log(`| ${r.join(" | ")} |`);
};

// Not a test, and not run unless named: `node test/browsers.ts profile [rows]`. Where a full replica in a browser spends
// its time taking in a space: the worker's CPU profile, the functions that take most of it, and the profile kept.
const profileSync = async () => {
  const ROWS = Number(process.argv[3] ?? 20000), TEXTS = 20, TEXT = 400_000;
  const Row = { title: columns.string(16), body: columns.text(17) };
  const relay = await node("serve", join(TMP, "pf-relay"));
  const s = await space("pf", relay);
  const p = await page();
  const { key } = await call<{ key: string }>(p, "device", "pf", undefined, true);
  s.admit(key, "c", false);
  const writer = new Client({ connect: zspdConnect(s.o.address), credential: token(s.owner) });
  await eventually("the writer may write", () => writer.may(1, "write"));
  const writes: Promise<void>[] = [];
  for (let i = 0; i < ROWS; i += 1000)
    writes.push(writer.write(1, (c) => {
      for (let k = i; k < Math.min(i + 1000, ROWS); k++) c.insert(Row, "big", k, { title: `note ${k}`, body: `the quick brown fox jumps over the lazy dog, ${k} times over and again` });
    }));
  for (let i = 0; i < TEXTS; i++) writes.push(writer.write(1, (c) => c.insert(Row, "docs", i, { title: `doc ${i}`, body: "a".repeat(TEXT) })));
  await Promise.all(writes);
  await new Promise((done) => setTimeout(done, 5000));
  const worker = p.workers[p.workers.length - 1];
  await p.cdp("Profiler.enable", {}, worker);
  await p.cdp("Profiler.setSamplingInterval", { interval: 200 }, worker);
  await p.cdp("Profiler.start", {}, worker);
  const t = performance.now();
  await call(p, "join", "pf", s.sid, relay);
  if (process.env.WINDOW) await call(p, "watch", "pf", "big", 50); // as an application would, at once
  const text = process.env.TEXT ? call<number>(p, "timeText", "pf", "docs", TEXT, 300000) : undefined;
  let held = 0;
  for (let last = -1; ; await new Promise((done) => setTimeout(done, 500))) {
    held = (await call<{ held: number }>(p, "usage", "pf")).held;
    if (held === last && held > ROWS * 150) break;
    last = held;
  }
  const took = performance.now() - t;
  if (text) console.log(`     the text, after ${((await text) / 1000).toFixed(1)} s`);
  const { profile } = await p.cdp<{ profile: any }>("Profiler.stop", {}, worker);
  const shown = process.env.WINDOW ? await call<{ titles: string[] }>(p, "seen", "pf", "big") : undefined;
  console.log(`     a full replica took in ${(held / 2 ** 20).toFixed(1)} MB in ${(took / 1000).toFixed(1)} s${shown ? `, its window holding ${shown.titles.length} rows` : ""}:`);
  await summarise(profile);
  writer.close();
};

// Where a profile's time went: self time by function, the most first; and the profile, kept in build/worker.cpuprofile.
async function summarise(profile: any): Promise<void> {
  const { writeFileSync } = await import("node:fs");
  writeFileSync(join(ROOT, "build", "worker.cpuprofile"), JSON.stringify(profile));
  const self = new Map<number, number>();
  const dt = profile.timeDeltas as number[];
  (profile.samples as number[]).forEach((id, i) => self.set(id, (self.get(id) ?? 0) + (dt[i] ?? 0)));
  const byName = new Map<string, number>();
  let total = 0;
  for (const n of profile.nodes) {
    const us = self.get(n.id) ?? 0;
    total += us;
    const f = n.callFrame;
    const name = `${f.functionName || "(anonymous)"} ${(f.url as string).split("/").pop()}:${f.lineNumber}`;
    byName.set(name, (byName.get(name) ?? 0) + us);
  }
  console.log(`     of the worker's ${(total / 1e6).toFixed(1)} s sampled:`);
  for (const [name, us] of [...byName].sort((a, b) => b[1] - a[1]).slice(0, 30)) console.log(`     ${((us / total) * 100).toFixed(1).padStart(5)}%  ${(us / 1e6).toFixed(2).padStart(6)} s  ${name}`);
}

async function main(): Promise<void> {
  const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : Object.keys(tests);
  if (names[0] === "bench") tests.bench = bench;
  if (names[0] === "partial") (tests.partial = partialBench), names.splice(1);
  if (names[0] === "profile") (tests.profile = profileSync), names.splice(1);
  chrome = await Chrome.launch();
  let failed = 0;
  for (const name of names) {
    const start = performance.now();
    let timer: ReturnType<typeof setTimeout> | undefined;
    try {
      // However a page fails to answer, the test fails, by name, rather than waiting for ever.
      const limit = new Promise<never>((_, fail) => (timer = setTimeout(() => fail(new Error("not done in three minutes")), name === "partial" ? 3600000 : 180000)));
      chrome.uncaught.length = 0;
      await Promise.race([tests[name](), limit]);
      // What a page threw that nothing caught fails the test, though nothing it looked at went wrong.
      if (chrome.uncaught.length > 0) throw new Error("uncaught in a page: " + chrome.uncaught.join("; "));
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
