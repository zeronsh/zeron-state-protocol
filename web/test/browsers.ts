// Web devices in a browser: headless Chrome, its origin's private file system, its workers, its WebSockets. Each runs
// test/live.ts against a zspd device through zspd's relay, and against another browser device through the Durable
// Object; tabs share one device and hand it on when the one running it goes; and a device is what it was after a
// restart, with nothing to reach. `node test/browsers.ts [names...]`

import { execFileSync } from "node:child_process";
import { readFileSync, rmSync } from "node:fs";
import { createServer as http } from "node:http";
import { createServer as tcp, connect as dial } from "node:net";
import type { AddressInfo } from "node:net";
import { join } from "node:path";
import { Chrome, type Page } from "./chrome.ts";
import { cloud, eventually, exists, expectEqual, node, procs, ROOT, TMP, token, zspd, zspdConnect } from "./procs.ts";
import { Client, columns } from "../src/client.ts";
import type { Side } from "./browser.ts";

const WEB = join(ROOT, "web");
execFileSync(process.execPath, [join(WEB, "build.ts"), "--test"], { stdio: "inherit" });

// The test page, and what it loads, from this origin.
const TYPES: Record<string, string> = { ".js": "text/javascript", ".wasm": "application/wasm", ".html": "text/html" };
const site = http((req, res) => {
  const path = new URL(req.url!, "http://x").pathname;
  if (path === "/") {
    res.writeHead(200, { "content-type": "text/html" });
    res.end('<!doctype html><meta charset="utf-8"><script type="module" src="/test.js"></script>');
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

const call = <T>(p: Page, f: string, ...args: unknown[]) => p.evaluate<T>(`window.zsp.${f}(${args.map((a) => JSON.stringify(a)).join(", ")})`);

// A space with scope 1, and scope 2 signed in which b may vouch: a goes by "ann" and b by "bob". Its owner is zspd's.
async function space(name: string, relay: { key: string; url: string }, credential = "") {
  const owner = join(TMP, name + "-owner");
  const sid = zspd("create", owner);
  zspd("relay", owner, relay.key, relay.url);
  expectEqual(zspd("scope", owner, "signed"), "2");
  await node("run", owner, ...(credential ? [`--credential=${credential}`] : []));
  const admit = (key: string, subject: string, vouch: boolean) => {
    zspd("admit", owner, key, "1");
    zspd("admit", owner, key, "2", ...(vouch ? ["vouch"] : []));
    zspd("subject", owner, key, subject);
  };
  return { owner, sid, admit };
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
  // A device is what it was after its tabs have all gone, with no relay to be had: its key, and what it held.
  async browser_restart() {
    const relay = await node("serve", join(TMP, "br-relay"));
    const s = await space("br", relay);
    const first = await page();
    const key = await browserDevice(first, "br", s, relay, "ann", false);
    const many = Array.from({ length: 50 }, (_, i) => "note " + i);
    await call(first, "put", "br", "notes", many);
    await first.close();
    pages.splice(pages.indexOf(first), 1);
    for (const p of procs.splice(0)) p.kill();
    const later = await page();
    const back = await call<{ key: string; space?: string }>(later, "device", "br");
    expectEqual(back.key, key);
    expectEqual(back.space, s.sid);
    expectEqual((await call<string[]>(later, "titles", "br", "notes", 50)).join(), many.join());
  },
};

async function main(): Promise<void> {
  const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : Object.keys(tests);
  chrome = await Chrome.launch();
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
      for (const p of pages.splice(0)) await p.close().catch(() => {});
      for (const p of procs.splice(0)) p.kill();
    }
  }
  await chrome.close();
  site.close();
  if (!failed) rmSync(TMP, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}

await main();
