// A device in Node: its store is a directory, and its node runs in this very thread, as everything in Node does.

import { Client } from "./client.ts";
import type { Device, Relay } from "./index.ts";
import { Node, type NodeOptions } from "./node.ts";
import { NodeVolume } from "./volume-node.ts";
import { loadModule } from "./wasm.ts";

export * from "./index.ts";
export { Node } from "./node.ts";
export { NodeVolume } from "./volume-node.ts";
export { MemoryVolume } from "./volume.ts";

export interface OpenOptions extends Partial<Omit<NodeOptions, "module" | "volume">> {
  /** The directory it keeps what it holds in. */
  dir: string;
}

let compiled: Promise<WebAssembly.Module> | undefined;

/** Opens the device kept in a directory, making it if there is none. */
export async function open(options: OpenOptions): Promise<Device & { readonly node: Node }> {
  compiled ??= loadModule();
  const node = await Node.open({ ...options, volume: new NodeVolume(options.dir), module: await compiled });
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
    connect: node.connect,
    client: (host = {}) => new Client({ ...host, connect: node.connect }),
    close: () => node.close(),
  };
}
