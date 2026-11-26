// Real processes on real sockets: relays, zspd devices, and web devices, which are this very process's. Each way devices
// can meet runs test/live.ts: the TypeScript client against zspd as the Luau client is, and web devices against zspd
// devices through a relay of zspd's and through the Durable Object. `node test/end_to_end.ts [names...]`

import { spawn } from "node:child_process";
import { rmSync } from "node:fs";
import { join } from "node:path";
import { Client } from "../src/client.ts";
import type { Connect, Wire } from "../src/node.ts";
import { open } from "../src/nodejs.ts";
import { live } from "./live.ts";
import { mirrorSuite } from "./mirror.ts";
import { cloud, eventually, exists, expectEqual, node, procs, proxy, TMP, token, zspd, zspdConnect } from "./procs.ts";

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

const tests: Record<string, () => Promise<void>> = {
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
  async keepalive() {
    for (const kind of ["zspd", "cloud"]) {
      const relay = kind === "zspd" ? await node("serve", join(TMP, "k-relay")) : await cloud();
      const through = await proxy(relay.url);
      const owner = join(TMP, "k-owner-" + kind);
      const sid = zspd("create", owner);
      zspd("relay", owner, relay.key, through.url);
      await node("run", owner);
      const d = await open({ dir: join(TMP, "k-web-" + kind), keepalive: { idle: 300, wait: 300 }, log: () => {} });
      zspd("admit", owner, d.key, "1");
      await d.join(sid, { key: relay.key, url: through.url });
      const c = d.client();
      await eventually("it is admitted", () => c.may(1, "write"));
      const before = through.connections();
      await new Promise((done) => setTimeout(done, 1500));
      expectEqual(through.connections(), before); // pinged, and answered, five times over
      through.swallow();
      await eventually("a connection that died without a word is dialled again", () => through.connections() > before, 3000);
      await eventually("and works", async () => {
        await c.write(1, (change) => change.insert({}, "x", 1, {}));
        return true;
      });
      c.close();
      await d.close();
      for (const p of procs.splice(0)) p.kill();
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
    // Side by side, each in a process of its own, as tests/end_to_end.py runs.
    const runs = names.map((name) => {
      const p = spawn(process.execPath, [process.argv[1], name], { stdio: ["ignore", "pipe", "pipe"] });
      let out = "";
      p.stdout.on("data", (d) => (out += d));
      p.stderr.on("data", (d) => (out += d));
      return new Promise<[string, number]>((done) => p.on("exit", (code) => done([out, code ?? 1])));
    });
    let failed = false;
    for (const [out, code] of await Promise.all(runs)) {
      process.stdout.write(out);
      failed ||= code !== 0;
    }
    rmSync(TMP, { recursive: true, force: true });
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
    for (const p of procs.splice(0)) p.kill();
  }
  if (!failed) rmSync(TMP, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}

await main();
