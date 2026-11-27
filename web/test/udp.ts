// UDP for links in Node: an error on a socket, once it is bound, is no reason for the process to end, nor for packets to
// stop.

import assert from "node:assert/strict";
import dgram, { type Socket } from "node:dgram";
import { syncBuiltinESMExports } from "node:module";

// Every socket made, that an error can be said on it as the system would.
const made: Socket[] = [];
const create = dgram.createSocket;
dgram.createSocket = ((...args: Parameters<typeof create>) => {
  const s = create(...args);
  made.push(s);
  return s;
}) as typeof create;
syncBuiltinESMExports();
const { nodeDatagrams } = await import("../src/udp-node.ts");

const udp = await nodeDatagrams();
assert(made.length > 0);
for (const s of made) for (let k = 0; k < 2; k++) s.emit("error", new Error("the network went"));
const heard = new Promise<Uint8Array>((done) => udp.listen((_ip, _port, data) => done(data)));
const loopback = new Uint8Array(16);
loopback[10] = loopback[11] = 0xff;
loopback.set([127, 0, 0, 1], 12);
udp.send(loopback, udp.port, Uint8Array.of(1, 2, 3));
assert.deepEqual([...(await heard)], [1, 2, 3]);

// What goes to a peer goes by a socket that may not broadcast, so that no address a member names, as its network's own
// broadcast address, reaches everyone on it; beacons go by one that may. Where the loopback network has one: Linux's.
if (process.platform === "linux") {
  const everyone = create("udp4");
  await new Promise<void>((done) => everyone.bind(0, "0.0.0.0", done));
  const got: string[] = [];
  everyone.on("message", (m) => got.push(String(m)));
  const all = Uint8Array.of(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 127, 255, 255, 255);
  udp.send(all, everyone.address().port, new TextEncoder().encode("as to a peer"));
  udp.announce!(all, everyone.address().port, new TextEncoder().encode("to everyone"));
  await new Promise((done) => setTimeout(done, 300));
  assert.deepEqual(got, ["to everyone"]);
  everyone.close();
}
udp.close();
console.log("ok");
