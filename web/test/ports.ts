// Names, ports and exposure, as the TypeScript client asks its zspd device's host (SPEC §17): the same as
// luau/tests/ports.luau and tests/end_to_end.py's, so that every client is held to the same. `node test/ports.ts`

import { createServer } from "node:net";
import { join } from "node:path";
import { CallFault, Client } from "../src/client.ts";
import { Malformed } from "../src/codec.ts";
import { cleanUp, eventually, node, TMP, token, zspd, zspdConnect } from "./procs.ts";

function fails(what: string, fault: string, p: Promise<unknown>): Promise<void> {
  return p.then(
    () => {
      throw new Error(`${what}: answered, not refused`);
    },
    (e) => {
      if (!(e instanceof CallFault) || e.fault !== fault) throw new Error(`${what}: ${e}`);
    },
  );
}

async function main(): Promise<void> {
  const relay = await node("serve", join(TMP, "pt-relay"));
  const a = join(TMP, "pt-a"), b = join(TMP, "pt-b");
  const sid = zspd("create", a);
  zspd("relay", a, relay.key, relay.url);
  zspd("admit", a, zspd("key", b), "1");
  zspd("join", b, sid, relay.key, relay.url);
  const options = ["--dns=127.0.0.1:0", "--catch=127.0.0.1:0", "--no-proxy"];
  const na = await node("run", a, ...options), nb = await node("run", b, ...options);
  const ca = new Client({ connect: zspdConnect(na.address), credential: token(a) });
  const cb = new Client({ connect: zspdConnect(nb.address), credential: token(b) });
  let devices = 0;
  let ids: string[] = [];
  cb.on("devices", (d) => ((devices = d.length), (ids = d.map((x) => x.id))));
  await eventually("both hear of both", () => devices === 2);
  const listener = createServer((s) => s.end("x"));
  await new Promise<void>((done) => listener.listen(0, "127.0.0.1", done));
  const port = (listener.address() as { port: number }).port;
  try {
    // Every device, by name and address: this one here, the other reachable.
    await eventually("the other can be reached", async () => (await cb.nodes()).some((n) => n.reachable && !n.here), 15000);
    const nodes = await cb.nodes();
    const me = nodes.find((n) => n.here)!, other = nodes.find((n) => !n.here)!;
    if (me.address !== "127.0.0.1" || !me.name.endsWith(".id.zsp.internal") || !/^127\.77\.0\.\d+$/.test(other.address)) throw new Error(JSON.stringify(nodes));
    // Its devices by the ids the client has for them everywhere: 64 hex digits.
    if (!nodes.every((n) => /^[0-9a-f]{64}$/.test(n.id) && ids.includes(n.id))) throw new Error(`ids: ${JSON.stringify(nodes.map((n) => n.id))} ${ids}`);

    // Nothing is offered unless it is; then it is, listed as it listens.
    if ((await ca.offers()).length !== 0) throw new Error("offered unasked");
    const offers = await ca.offer({ lo: port, scope: 1, name: "web" });
    if (offers.length !== 1 || offers[0].lo !== port || offers[0].hi !== port || offers[0].name !== "web" || offers[0].device) throw new Error(JSON.stringify(offers));
    if ((await ca.offer({ lo: 1000, hi: 2000, scope: 1, host: "10.0.0.4" })).length !== 2) throw new Error("a host's offer");
    await fails("this machine is no host", "denied", ca.offer({ lo: 22, scope: 1, host: "127.0.0.1" }));
    await fails("a scope it may not call in", "denied", cb.offer({ lo: 22, scope: 9 }));
    // To one device, by its id; and no port that is not one, rather than one it wraps round to.
    const one = await ca.offer({ lo: port + 2, scope: 1, device: other.id === me.id ? me.id : nodes.find((n) => !n.here)!.id });
    if (!one.some((o) => o.lo === port + 2 && o.device === nodes.find((n) => !n.here)!.id)) throw new Error(JSON.stringify(one));
    await ca.unoffer({ lo: port + 2, scope: 1, device: nodes.find((n) => !n.here)!.id });
    for (const bad of [65616, 0, 1.5, -80]) {
      let threw = false;
      try {
        await ca.offer({ lo: bad, scope: 1 });
      } catch (e) {
        threw = e instanceof RangeError;
      }
      try {
        await ca.expose(bad);
        threw = false;
      } catch (e) {
        threw &&= e instanceof RangeError;
      }
      if (!threw) throw new Error(`port ${bad} was taken`);
    }
    await eventually("the offer is heard", async () => (await cb.nodes()).some((n) => n.ports.some((p) => p.port === port && p.name === "web" && p.scope === 1)), 15000);
    if ((await ca.unoffer({ lo: 1000, hi: 2000, scope: 1, host: "10.0.0.4" })).length !== 1) throw new Error("taken back");

    // Exposed to the public, under a fresh name, and taken back.
    const exposed = await ca.expose(port, { name: "web", proxy: true });
    if (exposed.length !== 1 || exposed[0].port !== port || !exposed[0].proxy || !exposed[0].label.startsWith("web-")) throw new Error(JSON.stringify(exposed));
    const again = await ca.expose(port + 1);
    if (again.length !== 2 || again[1].label === exposed[0].label) throw new Error("a fresh name");
    await fails("exposed already", "denied", ca.expose(port));
    if ((await ca.unexpose(port)).length !== 1 || (await ca.unexpose(port + 1)).length !== 0) throw new Error("taken back");
    await fails("not exposed", "denied", ca.unexpose(port));
    // An answer is read whole, or is not one: what is left over says it was not what it was read as.
    const request = ca.request;
    ca.request = () => Promise.resolve(new Uint8Array([0, 0]));
    try {
      for (const ask of [() => ca.nodes(), () => ca.offers(), () => ca.exposures()]) {
        const read = await ask().then(() => true, (e) => !(e instanceof Malformed));
        if (read) throw new Error(`${ask} read more than an answer`);
      }
    } finally {
      ca.request = request;
    }
    console.log("ok   ports.ts");
  } finally {
    listener.close();
    ca.close();
    cb.close();
    await cleanUp();
  }
}

main().catch(async (e) => {
  console.log("FAIL ports.ts:", e);
  await cleanUp();
  process.exit(1);
});
