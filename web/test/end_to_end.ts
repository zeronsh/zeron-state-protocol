// Real processes on real sockets: relays, zspd devices, and web devices, which are this very process's. Each way devices
// can meet runs test/live.ts: the TypeScript client against zspd as the Luau client is, and web devices against zspd
// devices through a relay of zspd's and through the Durable Object. `node test/end_to_end.ts [names...]`

import { spawn } from "node:child_process";
import { availableParallelism } from "node:os";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { Client, columns } from "../src/client.ts";
import type { Connect, Wire } from "../src/node.ts";
import { open } from "../src/nodejs.ts";
import { live } from "./live.ts";
import { mirrorSuite } from "./mirror.ts";
import { cloud, eventually, exists, expectEqual, node, stopAll, cleanUp, proxy, TMP, token, zspd, zspdConnect } from "./procs.ts";

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

// Rows of a list, as a zspd device's client sees them.
function watched(client: Client, list: string): () => number {
  let rows = 0;
  client.window({ scope: 1, list, table: {}, size: 1000 }, (st) => (rows = st.rows.length));
  return () => rows;
}

const tests: Record<string, () => Promise<void>> = {
  // A relay answers a ping said in text, and nothing else in text; and nothing may come within a message in several
  // frames, a ping included.
  async text_ping() {
    const relay = await node("serve", join(TMP, "p-relay"));
    const { connect } = await import("node:net");
    const frame = (op: number, fin: boolean, payload: Uint8Array) => {
      const mask = crypto.getRandomValues(new Uint8Array(4));
      const out = new Uint8Array(6 + payload.length);
      out[0] = (fin ? 0x80 : 0) | op;
      out[1] = 0x80 | payload.length;
      out.set(mask, 2);
      payload.forEach((b, i) => (out[6 + i] = b ^ mask[i % 4]));
      return out;
    };
    const ask = (frames: Uint8Array[]) =>
      new Promise<{ heard: string; closed: boolean }>((done) => {
        const port = Number(relay.address.split(":").pop());
        const sock = connect(port, "127.0.0.1", () => {
          sock.write(`GET /${"ab".repeat(32)} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n`);
          for (const f of frames) sock.write(f);
        });
        let got = Buffer.alloc(0);
        sock.on("data", (d) => (got = Buffer.concat([got, d])));
        const end = (closed: boolean) => {
          sock.destroy();
          const head = got.indexOf("\r\n\r\n");
          done({ heard: head < 0 ? "" : got.subarray(head + 4).toString("latin1"), closed });
        };
        sock.on("close", () => end(true));
        setTimeout(() => end(false), 1000);
      });
    const ping = new TextEncoder().encode("ping");
    const alone = await ask([frame(1, true, ping)]);
    expectEqual(alone.heard.includes("pong"), true);
    const within = await ask([frame(2, false, Uint8Array.of(1, 2, 3)), frame(1, true, ping)]);
    expectEqual(within.heard.includes("pong"), false);
    expectEqual(within.closed, true);
  },
  // An owner that has heard nothing for a while revokes a member: what that member rightly wrote meanwhile stands. A grant
  // ends when it is ended, not when its node last heard anything.
  async revoke_when_quiet() {
    const relay = await node("serve", join(TMP, "q-relay"));
    const owner = await open({ dir: join(TMP, "q-owner"), udp: false, log: () => {} }); // no relay: it hears nothing
    const sid = await owner.create();
    expectEqual(await owner.scope(true), 2);
    const [alice, bob] = [await open({ dir: join(TMP, "q-alice"), udp: false, log: () => {} }), await open({ dir: join(TMP, "q-bob"), udp: false, log: () => {} })];
    for (const d of [alice, bob]) await owner.admit(d.key, 1), await owner.admit(d.key, 2);
    const roster = () => owner.node.store.kept("roster").latest!;
    for (const d of [alice, bob]) await d.join(sid, relay), await d.adopt(roster());
    const ca = new Client({ connect: alice.connect }), cb = new Client({ connect: bob.connect });
    await eventually("both may write in the signed scope", () => ca.may(2, "write") && cb.may(2, "write"));
    await new Promise((done) => setTimeout(done, 1500));
    const Note = { title: columns.string(16) };
    let rows = 0;
    ca.window({ scope: 2, list: "notes", table: Note }, (st) => (rows = st.rows.length));
    await cb.write(2, (change) => change.insert(Note, "notes", 1, { title: "before" }));
    await eventually("alice has bob's row", () => rows === 1);
    await owner.revoke(bob.key, 2);
    await alice.adopt(roster());
    await new Promise((done) => setTimeout(done, 500));
    expectEqual(rows, 1);
    for (const c of [ca, cb]) c.close();
    for (const d of [owner, alice, bob]) await d.close();
  },
  // Introduced by a relay, a web device and a zspd device link directly, and need it no more.
  async web_links() {
    const relay = await node("serve", join(TMP, "l-relay"));
    const owner = join(TMP, "l-owner");
    const sid = zspd("create", owner);
    zspd("relay", owner, relay.key, relay.url);
    let linked = false;
    const d = await open({ dir: join(TMP, "l-web"), log: (_, text) => (linked ||= text === "linked directly") });
    zspd("admit", owner, d.key, "1");
    const o = await node("run", owner, "--udp=0");
    await d.join(sid, relay);
    const ca = new Client({ connect: d.connect });
    const cb = new Client({ connect: zspdConnect(o.address), credential: token(owner) });
    await eventually("both may write", () => ca.may(1, "write") && cb.may(1, "write"));
    const seen = watched(cb, "x");
    await ca.write(1, (change) => change.insert({}, "x", 0, {}));
    await eventually("they link directly", () => linked, 15000);
    await new Promise((done) => setTimeout(done, 300));
    relay.p.kill(); // and nothing is missed
    for (let i = 1; i <= 50; i++) void ca.write(1, (change) => change.insert({ v: columns.bytes(16) }, "x", i, { v: crypto.getRandomValues(new Uint8Array(2000)) }));
    await eventually("what is written arrives, with no relay", () => seen() === 51);
    // And live text goes the same way.
    let body = "";
    const Note = { body: columns.text(17) };
    let id = "";
    await ca.write(1, (change) => (id = change.insert(Note, "notes", 1, {})));
    cb.window({ scope: 1, list: "notes", table: Note }, (st) => (body = st.rows[0]?.body ?? ""));
    await new Promise((done) => setTimeout(done, 200));
    const editor = ca.text(id, Note.body);
    editor.append("direct");
    await eventually("live text arrives directly", () => body === "direct");
    editor.close();
    ca.close();
    cb.close();
    await d.close();
  },
  // On one network, with no relay at all: a web device and a zspd device hear each other's beacons.
  async web_lan() {
    const owner = join(TMP, "n-owner");
    const sid = zspd("create", owner);
    let linked = false;
    const d = await open({ dir: join(TMP, "n-web"), log: (_, text) => (linked ||= text === "linked directly") });
    zspd("admit", owner, d.key, "1");
    if (!(await d.adopt(readFileSync(join(owner, sid, "roster"))))) throw new Error("the roster was not taken");
    const o = await node("run", owner, "--udp=0");
    const ca = new Client({ connect: d.connect });
    const cb = new Client({ connect: zspdConnect(o.address), credential: token(owner) });
    await eventually("both may write", () => ca.may(1, "write") && cb.may(1, "write"));
    const seen = watched(ca, "x");
    await eventually("beacons meet", () => linked, 15000);
    await cb.write(1, (change) => change.insert({}, "x", 1, {}));
    await eventually("no servers", () => seen() === 1);
    ca.close();
    cb.close();
    await d.close();
  },
  // A web device makes the space and governs it: zspd devices are admitted to it as to any other.
  async web_governs() {
    const relay = await node("serve", join(TMP, "g-relay"));
    const a = await open({ dir: join(TMP, "g-a"), log: () => {} });
    const sid = await a.create();
    await a.relay(relay.key, relay.url);
    expectEqual(await a.scope(true), 2);
    const dir = join(TMP, "g-b");
    const bob = zspd("key", dir);
    await a.admit(bob, 1);
    await a.admit(bob, 2, { write: true, call: true, vouch: true });
    await a.subject(a.key, "ann");
    await a.subject(bob, "bob");
    zspd("join", dir, sid, relay.key, relay.url);
    const b = await node("run", dir);
    await eventually("it hears who belongs", () => exists(join(dir, sid, "roster")));
    const pipes = new Pipes();
    const ca = new Client({ connect: pipes.wrap(a.connect), linger: 200 });
    const cb = new Client({ connect: pipes.wrap(zspdConnect(b.address)), credential: token(dir), linger: 200 });
    await live({ a: ca, b: cb, breakPipes: () => pipes.break(), say: () => {} });
    const members = await a.members();
    expectEqual(members.length, 2);
    const them = members.find((m) => m.key === bob)!;
    expectEqual(them.subject, "bob");
    expectEqual(them.grants.get(2)?.vouch, true);
    expectEqual(members.find((m) => m.key === a.key)!.owner, true);

    // Another web device, made an admin, governs; unmade, does not.
    const c = await open({ dir: join(TMP, "g-c"), log: () => {} });
    await a.admit(c.key, 1);
    await c.join(sid, relay);
    const cc = new Client({ connect: c.connect, linger: 200 });
    await eventually("c may write", () => cc.may(1, "write"));
    await a.admin(c.key);
    await eventually("c hears that it is an admin", async () => (await c.members()).some((m) => m.key === c.key && m.admin));
    const three = await c.scope();
    await eventually("a hears of the scope c made", () => ca.may(three, "write"));
    await a.admin(c.key, false);
    await eventually("c hears that it is not", async () => (await c.members()).some((m) => m.key === c.key && !m.admin));
    await c.scope().then(
      () => Promise.reject(new Error("an admin no more made a scope")),
      () => {},
    );
    // Revoked, it is told so, and reads nothing written after.
    let rows = 0, status = "";
    cc.window({ scope: 1, list: "after", table: {} }, (st) => ((rows = st.rows.length), (status = st.status)));
    await a.revoke(c.key);
    await eventually("c is told", () => status === "denied");
    await ca.write(1, (change) => change.insert({}, "after", 1, {}));
    await new Promise((done) => setTimeout(done, 500));
    expectEqual(rows, 0);
    for (const x of [ca, cb, cc]) x.close();
    await a.close();
    await c.close();
  },
  // A browser cannot ping a WebSocket, so a web device says "ping", which every relay answers: a quiet connection is
  // kept, and one that has quietly died is known to have, and dialled again.
  // One who begins to look while another is typing sees what was typed before it looked, and the rest as it is typed:
  // not once the piece is sealed, a second after it began, as when frames from the middle of a piece reached a reader that
  // had missed its start. Through zspd's relay and the Durable Object, a web device typing and a zspd device looking.
  async late_reader() {
    for (const kind of ["zspd", "cloud"]) {
      const relay = kind === "zspd" ? await node("serve", join(TMP, "lr-relay")) : await cloud();
      const s = await space("lr-" + kind, relay, ["web", "zspd"]);
      const Note = { title: columns.string(16), body: columns.text(17) };
      await eventually("it may write", () => s.a.may(1, "write") && s.b.may(1, "read"));
      let id = "";
      await s.a.write(1, (change) => (id = change.insert(Note, "late", 1, { title: "note" })));
      const editor = s.a.text(id, Note.body);
      const typed = Date.now();
      editor.append("typed before anyone looked"); // its piece is sealed a second from now, and no sooner
      await new Promise((done) => setTimeout(done, 200)); // said, and dropped, as nobody looked
      let shown: string | undefined;
      const looked = Date.now();
      const w = s.b.window({ scope: 1, list: "late", table: Note }, (state) => (shown = state.rows[0]?.body));
      await eventually("what was typed before it looked", () => shown === "typed before anyone looked");
      const seen = Date.now();
      const began = Date.now();
      editor.append(", and after"); // in the same piece if that is not sealed yet, else in one of its own
      const sealed = began < typed + 1000 ? typed + 1000 : began + 1000;
      await eventually("and what is typed after", () => shown === "typed before anyone looked, and after");
      const done = Date.now();
      // A piece is sealed a second after it began, and no sooner: what is shown before then was live. (Not a bound on
      // how soon after looking: that is all the while a slow machine takes to open the window.)
      if (seen >= typed + 1000 || done >= sealed) {
        throw new Error(`${kind}: shown ${seen - looked} ms after looking and ${done - began} ms after typing, ${seen - typed} and ${done - typed} ms after the piece began: once sealed, not live`);
      }
      editor.close();
      w.stop();
      await s.close();
      await stopAll();
    }
  },
  async keepalive() {
    for (const kind of ["zspd", "cloud"]) {
      const relay = kind === "zspd" ? await node("serve", join(TMP, "k-relay")) : await cloud();
      const through = await proxy(relay.url);
      const owner = join(TMP, "k-owner-" + kind);
      const sid = zspd("create", owner);
      zspd("relay", owner, relay.key, relay.url); // the web device alone goes through the proxy, whose connections are its
      await node("run", owner);
      const d = await open({ dir: join(TMP, "k-web-" + kind), keepalive: { idle: 500, wait: 1000 }, log: () => {} });
      zspd("admit", owner, d.key, "1");
      await d.join(sid, { key: relay.key, url: through.url });
      const c = d.client();
      await eventually("it is admitted", () => c.may(1, "write"));
      const before = through.connections();
      await new Promise((done) => setTimeout(done, 2500));
      expectEqual(through.connections(), before); // pinged, and answered, five times over
      through.swallow();
      await eventually("a connection that died without a word is dialled again", () => through.connections() > before, 5000);
      await eventually("and works", async () => {
        await c.write(1, (change) => change.insert({}, "x", 1, {}));
        return true;
      });
      c.close();
      await d.close();
      await stopAll();
    }
  },
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
  // Structured state, by two web devices through a relay: test/mirror.ts, as luau/tests/mirror.luau is run on zspd's.
  async mirror() {
    const relay = await node("serve", join(TMP, "m-relay"));
    const s = await space("m", relay, ["web", "web"]);
    await mirrorSuite(s);
    await s.close();
  },
};

async function main(): Promise<void> {
  const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : Object.keys(tests);
  if (names.length > 1) {
    // Side by side, each in a process of its own, as tests/end_to_end.py runs; but no more at once than half the machine
    // has cores for, since some say how fast things are, and a machine with more to do than it can is not fast.
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
    const runs = results;
    let failed = false;
    for (const [out, code] of await Promise.all(runs)) {
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
    await tests[name]();
    console.log(`ok   ${name} ${((performance.now() - start) / 1000).toFixed(2)}s`);
  } catch (e) {
    failed = true;
    console.log(`FAIL ${name}: ${e instanceof Error ? e.stack : e}\n     in ${TMP}`);
  } finally {
    await stopAll();
  }
  if (!failed) await cleanUp();
  process.exit(failed ? 1 : 0);
}

await main();
