// The Zeron State Protocol, for TypeScript: what is the same in a browser and in Node. `open` is the platform's own, in
// ./browser.ts and ./nodejs.ts, which `import { open } from "zsp"` chooses between.

import type { Client, Host } from "./client.ts";
import type { Connect } from "./node.ts";

export { Client, CallFault, columns } from "./client.ts";
export type { Answer, Asking, AuthorsColumn, Call, Change, Column, Device as Who, Editor, Entry, Event, Fault, Host, Is, Query, Row, State, Status, Stored, Table, TextColumn, Values, Window } from "./client.ts";
export { where } from "./ask.ts";
export type { Match, Question, Total, Where } from "./ask.ts";
export { spaceUrl } from "./node.ts";
export type { Connect, Wire } from "./node.ts";

/** A relay: the key devices pin, and where it is. */
export interface Relay {
  key: string;
  url: string;
}

/** This device: its key, its store and its node, here or in a worker. */
export interface Device {
  /** Its key, which peers know it by: 64 hex digits. */
  readonly id: string;
  /** What an admin needs to admit it, as `zspd admit` takes it: its key and its signer's. */
  readonly key: string;
  /** The space it is of, once it has joined one. */
  readonly space: string | undefined;
  /** Becomes a device of a space that has admitted it, or will, meeting the others at a relay. */
  join(space: string, relay: Relay): Promise<void>;
  /** Becomes a device of a space by a roster alone, as `zspd peer` does. */
  adopt(roster: Uint8Array): Promise<boolean>;
  /** Whether the roster it holds lets it do anything at all. */
  member(): Promise<boolean>;
  /** Opens a pipe to the node, for a client of your own making. */
  readonly connect: Connect;
  /** A client of the node. */
  client(host?: Partial<Omit<Host, "connect">>): Client;
  /** Stops the node, which makes what it was given durable. */
  close(): Promise<void>;
}
