// UDP for a device in Node, for links (SPEC.md §14): a socket for each family on one port, and one that hears the local
// network's beacons, shared with whoever else on this machine hears them.

import { createSocket, type Socket } from "node:dgram";
import { lookup } from "node:dns/promises";
import { networkInterfaces } from "node:os";
import type { Datagrams } from "./node.ts";

const BEACON_PORT = 9083;

// An address as 16 bytes, IPv4 mapped.
function bytesOf(address: string): Uint8Array {
  const out = new Uint8Array(16);
  const v4 = address.startsWith("::ffff:") && address.includes(".") ? address.slice(7) : address.includes(".") ? address : undefined;
  if (v4) {
    out[10] = out[11] = 0xff;
    v4.split(".").forEach((part, i) => (out[12 + i] = Number(part)));
    return out;
  }
  const [head, tail = ""] = address.split("%")[0].split("::");
  const groups = (s: string) => (s ? s.split(":").map((g) => parseInt(g, 16)) : []);
  const h = groups(head), t = groups(tail);
  const all = [...h, ...Array(8 - h.length - t.length).fill(0), ...t];
  all.forEach((g, i) => ((out[2 * i] = g >> 8), (out[2 * i + 1] = g & 255)));
  return out;
}

const isPort = (n: number) => Number.isInteger(n) && n > 0 && n <= 65535;

function stringOf(ip: Uint8Array): { address: string; v4: boolean } {
  const v4 = ip.subarray(0, 10).every((b) => b === 0) && ip[10] === 0xff && ip[11] === 0xff;
  if (v4) return { address: `${ip[12]}.${ip[13]}.${ip[14]}.${ip[15]}`, v4 };
  const groups: string[] = [];
  for (let i = 0; i < 16; i += 2) groups.push(((ip[i] << 8) | ip[i + 1]).toString(16));
  return { address: groups.join(":"), v4 };
}

export interface UdpOptions {
  /** The port links use; any if not said. */
  port?: number;
  /** host:port of a STUN server, by which this machine learns its outside address. */
  stun?: string;
}

/** Sockets for links, in Node. */
export async function nodeDatagrams(options: UdpOptions = {}): Promise<Datagrams> {
  // What it is told is looked at before anything is bound, so that nothing is left bound when it is refused.
  let stunAt: { host: string; port: number } | undefined;
  if (options.stun !== undefined) {
    const at = options.stun.lastIndexOf(":");
    const port = Number(options.stun.slice(at + 1));
    if (at <= 0 || !isPort(port)) throw new RangeError(`a STUN server is host:port, its port of 1 to 65535: not ${options.stun}`);
    stunAt = { host: options.stun.slice(0, at), port };
  }
  if (options.port !== undefined && !(Number.isInteger(options.port) && options.port >= 0 && options.port <= 65535)) {
    throw new RangeError(`a UDP port is of 0 to 65535: not ${options.port}`);
  }
  let receive: (ip: Uint8Array, port: number, data: Uint8Array) => void = () => {};
  const hear = (msg: Buffer, from: { address: string; port: number }) => receive(bytesOf(from.address), from.port, new Uint8Array(msg));
  // A socket's error is a packet that did not go, or a network that went: links notice what that means, and the process
  // goes on.
  const bind = (s: Socket, port: number, address?: string) =>
    new Promise<boolean>((done) => {
      s.on("error", () => {});
      s.once("error", () => done(false));
      s.bind({ port, address, exclusive: false }, () => done(true));
    });
  const v4 = createSocket({ type: "udp4" });
  if (!(await bind(v4, options.port ?? 0))) {
    v4.close();
    throw new Error("could not bind a UDP port");
  }
  v4.on("message", hear);
  const port = v4.address().port;
  // Where one socket covers both families this bind fails, harmlessly.
  let v6: Socket | undefined = createSocket({ type: "udp6", ipv6Only: true });
  if (await bind(v6, port)) v6.on("message", hear);
  else v6.close(), (v6 = undefined);
  // Beacons go out by a socket of their own, the only one that may broadcast: so that nothing sent where a peer says
  // reaches everyone on a network, as its own broadcast address would, which only the system knows to refuse. It hears
  // those nearby, at BEACON_PORT, which others here share; or where it cannot, it has a port of its own, and only says.
  let beacon: Socket | undefined = createSocket({ type: "udp4", reuseAddr: true });
  if (!(await bind(beacon, BEACON_PORT))) {
    beacon.close();
    beacon = createSocket({ type: "udp4" });
    if (!(await bind(beacon, 0))) beacon.close(), (beacon = undefined);
  }
  beacon?.setBroadcast(true);
  beacon?.on("message", hear);
  let stun: { ip: Uint8Array; port: number } | undefined;
  if (stunAt) {
    try {
      // Resolved once, up front; a host without a name server still has its local addresses.
      const { address } = await lookup(stunAt.host, { family: 4 });
      stun = { ip: bytesOf(address), port: stunAt.port };
    } catch {
      stun = undefined;
    }
  }
  return {
    port,
    stun,
    listen: (f) => (receive = f),
    send: (ip, to, data) => {
      // Nowhere, as a peer may say it is, is not sent to: a packet that cannot go is the link's to notice, as one lost is.
      if (!isPort(to)) return;
      const { address, v4: four } = stringOf(ip);
      const s = four ? v4 : v6;
      try {
        s?.send(data, to, address, () => {}); // an unreachable peer is the link's to notice
      } catch {
        // as unreachable
      }
    },
    announce: (ip, to, data) => {
      try {
        beacon?.send(data, to, stringOf(ip).address, () => {});
      } catch {
        // as lost
      }
    },
    interfaces: () => {
      const out: { ip: Uint8Array; broadcast?: Uint8Array }[] = [];
      for (const list of Object.values(networkInterfaces())) {
        for (const i of list ?? []) {
          const ip = bytesOf(i.address);
          if (i.family === "IPv4") {
            const mask = bytesOf(i.netmask).subarray(12);
            out.push({ ip, broadcast: Uint8Array.from(ip.subarray(12), (b, k) => b | (~mask[k] & 255)) });
          } else {
            out.push({ ip });
          }
        }
      }
      return out;
    },
    close: () => {
      v4.close();
      v6?.close();
      beacon?.close();
    },
  };
}
