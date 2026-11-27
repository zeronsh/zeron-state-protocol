// A device in Node: its store is a directory, and its node runs in this very thread, as everything in Node does.

import { Client } from "./client.ts";
import type { Device, Relay } from "./index.ts";
import { Node, type NodeOptions, type Rights } from "./node.ts";
import { nodeDatagrams, type UdpOptions } from "./udp-node.ts";
import { NodeVolume } from "./volume-node.ts";
import { loadModule } from "./wasm.ts";

export * from "./index.ts";
export { Node } from "./node.ts";
export { NodeVolume } from "./volume-node.ts";
export { MemoryVolume } from "./volume.ts";

export interface OpenOptions extends Partial<Omit<NodeOptions, "module" | "volume" | "datagrams">> {
  /** The directory it keeps what it holds in. */
  dir: string;
  /** Links straight to other devices, over UDP, on this port or any; or none, and everything through relays. */
  udp?: UdpOptions | false;
}

let compiled: Promise<WebAssembly.Module> | undefined;

/** Opens the device kept in a directory, making it if there is none. */
export async function open(options: OpenOptions): Promise<Device & { readonly node: Node }> {
  compiled ??= loadModule();
  const datagrams = options.udp === false ? undefined : await nodeDatagrams(options.udp ?? {});
  const node = await Node.open({ ...options, volume: new NodeVolume(options.dir), module: await compiled, datagrams });
  return {
    node,
    id: node.id,
    key: node.key,
    get space() {
      return node.space;
    },
    join: async (space: string, relay: Relay) => node.join(space, relay),
    adopt: async (roster: Uint8Array) => node.adopt(roster),
    member: async () => node.member,
    create: async () => node.create(),
    scope: async (signed?: boolean) => node.scope(signed),
    admit: async (key: string, scope: number, rights?: Rights) => node.admit(key, scope, rights),
    revoke: async (key: string, scope?: number) => node.revoke(key, scope),
    subject: async (key: string, subject: string) => node.subject(key, subject),
    admin: async (key: string, on?: boolean) => node.admin(key, on),
    owner: async (key: string) => node.owner(key),
    relay: async (key: string, url: string) => node.relay(key, url),
    members: async () => node.members(),
    held: async () => node.held,
    connect: node.connect,
    client: (host = {}) => new Client({ ...host, connect: node.connect }),
    close: () => node.close(),
  };
}
