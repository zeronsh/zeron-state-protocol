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
udp.close();
console.log("ok");
