// Real processes on real sockets: relays, zspd devices, and web devices, which are this very process's. Each way devices
// can meet runs test/live.ts: the TypeScript client against zspd as the Luau client is, and web devices against zspd
// devices through a relay of zspd's and through the Durable Object. `node test/end_to_end.ts [names...]`

import { rmSync } from "node:fs";
import { join } from "node:path";
import { Client } from "../src/client.ts";
import type { Connect, Wire } from "../src/node.ts";
import { open } from "../src/nodejs.ts";
import { live } from "./live.ts";
import { cloud, eventually, exists, expectEqual, node, procs, TMP, token, zspd, zspdConnect } from "./procs.ts";

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
};

async function main(): Promise<void> {
  const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : Object.keys(tests);
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
      for (const p of procs.splice(0)) p.kill();
    }
  }
  if (!failed) rmSync(TMP, { recursive: true, force: true });
  process.exit(failed ? 1 : 0);
}

await main();
