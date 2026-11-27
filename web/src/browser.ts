// A device in a browser. Its node runs in a worker, where its store, a directory of the origin's private file system,
// may be read and written synchronously; tabs of one origin share it, whichever of them happens to run it (./worker.ts).

import { Client } from "./client.ts";
import type { Device, Relay } from "./index.ts";
import type { Connect, Member, Rights } from "./node.ts";
import type { Command, Op, Report, Say } from "./worker.ts";

export * from "./index.ts";

export interface OpenOptions {
  /** Which store: one device each, shared by the origin's tabs. "default" unless said. */
  name?: string;
  /**
   * Replicate everything, rather than what clients here watch and ask about. Not by default: a browser's device is a
   * partial replica, which has what it needs at once however big the space, and keeps no more than `keep` says of what
   * it no longer watches. A space needs a full replica somewhere that can read, to answer questions about all of it: a
   * zspd device, or a browser's opened with `full: true`. A store may be opened either way, and lose nothing.
   */
  full?: boolean;
  /** What a partial replica keeps of what it no longer watches: see NodeOptions. */
  keep?: { days?: number; bytes?: number } | false;
  /** Presented to relays, whose hosts decide by it whom they serve. */
  credential?: string | Uint8Array;
  /** Where the worker's script is, if not worker.js beside this one. */
  worker?: string | URL;
  /** Where node.wasm is, if not beside the worker's script. */
  wasm?: string | URL;
  /** Told if the node stops of itself, as when storage fails. */
  onFailure?: (error: Error) => void;
}

/** Opens this origin's device of that name, making it if there is none. */
export async function open(options: OpenOptions = {}): Promise<Device> {
  const worker = new Worker(options.worker ?? new URL("./worker.js", import.meta.url), { type: "module", name: "zsp" });
  let asked = 0;
  const answers = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
  const fail = (error: Error) => {
    for (const a of answers.values()) a.reject(error);
    answers.clear();
    options.onFailure?.(error);
  };
  worker.onerror = (e) => fail(new Error(e.message || "the worker could not be started"));
  worker.onmessage = (e: MessageEvent<Report>) => {
    const r = e.data;
    if ("failed" in r) {
      fail(new Error(r.failed));
      return;
    }
    if ("space" in r) {
      space = r.space;
      return;
    }
    const a = answers.get(r.answer);
    answers.delete(r.answer);
    if (r.error !== undefined) a?.reject(new Error(r.error));
    else a?.resolve(r.value);
  };
  const ask = <T>(op: Op, ...args: unknown[]): Promise<T> =>
    new Promise((resolve, reject) => {
      answers.set(++asked, { resolve: resolve as (v: unknown) => void, reject });
      worker.postMessage({ ask: asked, op, args } satisfies Command);
    });
  const command: Command = {
    open: { name: options.name ?? "default", full: options.full, keep: options.keep, credential: options.credential, wasm: options.wasm?.toString() },
  };
  worker.postMessage(command);
  let space: string | undefined;
  const identity = await ask<{ id: string; key: string; space?: string }>("identity");
  space ??= identity.space;

  const connect: Connect = (receive, closed) => {
    const { port1, port2 } = new MessageChannel();
    let open = true;
    port1.onmessage = (e: MessageEvent<Say>) => {
      const say = e.data;
      if (!open) return;
      if ("close" in say) {
        open = false;
        port1.close();
        closed();
      } else if ("data" in say) {
        receive(say.data);
        port1.postMessage({ credit: say.data.length } satisfies Say); // dealt with
      }
    };
    worker.postMessage({ connect: port2 } satisfies Command, [port2]);
    return {
      send: (data) => {
        // A copy, of its own, is handed over: what was given may be a view of something its giver goes on using.
        if (!open) return;
        const own = data.slice();
        port1.postMessage({ data: own } satisfies Say, [own.buffer]);
      },
      close: () => {
        if (!open) return;
        open = false;
        port1.postMessage({ close: true } satisfies Say);
        port1.close();
      },
    };
  };

  return {
    id: identity.id,
    key: identity.key,
    get space() {
      return space;
    },
    join: async (s: string, relay: Relay) => {
      space = await ask<string>("join", s, relay);
    },
    adopt: async (roster: Uint8Array) => {
      const taken = await ask<boolean>("adopt", roster);
      space = (await ask<{ space?: string }>("identity")).space;
      return taken;
    },
    member: () => ask<boolean>("member"),
    create: async () => (space = await ask<string>("create")),
    scope: (signed?: boolean) => ask<number>("scope", signed),
    admit: (key: string, scope: number, rights?: Rights) => ask<void>("admit", key, scope, rights),
    revoke: (key: string, scope?: number) => ask<void>("revoke", key, scope),
    subject: (key: string, subject: string) => ask<void>("subject", key, subject),
    admin: (key: string, on?: boolean) => ask<void>("admin", key, on),
    owner: (key: string) => ask<void>("owner", key),
    relay: (key: string, url: string) => ask<void>("relay", key, url),
    members: () => ask<Member[]>("members"),
    usage: () => ask<{ held: number; memory: number }>("usage"),
    connect,
    client: (host = {}) => new Client({ ...host, connect }),
    close: async () => worker.terminate(),
  };
}
