// The Zeron State Protocol, for TypeScript: what is the same in a browser and in Node. `open` is the platform's own, in
// ./browser.ts and ./nodejs.ts, which `import { open } from "zsp"` chooses between.

import type { Client, Host } from "./client.ts";
import type { Connect, Member, Rights } from "./node.ts";

export { Client, CallFault, columns } from "./client.ts";
export type { Answer, Asking, AuthorsColumn, Call, Change, Column, Device as Who, Editor, Entry, Event, Exposure, Fault, Host, Is, NodeInfo, Offer, Port, Query, RelayExposure, Row, State, Status, Stored, Table, TextColumn, Values, Window } from "./client.ts";
export { where } from "./ask.ts";
export * as mirror from "./mirror.ts";
export type { Doc, Draft, Fields, Input, ListSchema, MapSchema, Mirror, Of, RecordSchema, Schema, TreeSchema } from "./mirror.ts";
export type { Match, Question, Total, Where } from "./ask.ts";
export { spaceUrl } from "./node.ts";
export type { Connect, Member, Rights, Wire } from "./node.ts";
export { Process, ServiceError, Stream, Terminal } from "./services.ts";
export type {
  Entry as FileEntry,
  Environment,
  ExecOptions,
  Exit,
  PutOptions,
  Ran,
  Reading,
  Refusal,
  RunOptions,
  Service,
  Signal,
  TerminalOptions,
  TransferOptions,
  Transferred,
  TreeFile,
} from "./services.ts";
export { MemoryFolder } from "./folder.ts";
export type { FileInfo, Folder, FolderEntry, OpenFile } from "./folder.ts";

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
  /** Makes a space this device owns, as `zspd create` does, and becomes its first device. Resolves to its name. */
  create(): Promise<string>;
  // Governing the space, as zspd's commands do, by an owner or admin: each change is signed, kept and said to everyone.
  /** Adds a scope, signed or not; resolves to its number. */
  scope(signed?: boolean): Promise<number>;
  /** Lets a device, by its key, read a scope, and unless said otherwise write and call there. */
  admit(key: string, scope: number, rights?: Rights): Promise<void>;
  /** Ends a device's grants in a scope, or in every one. */
  revoke(key: string, scope?: number): Promise<void>;
  /** Says whose a device is. */
  subject(key: string, subject: string): Promise<void>;
  /** Lets a device govern the space but for making admins and owners, or no longer. */
  admin(key: string, on?: boolean): Promise<void>;
  /** Makes a device an owner too, for good. */
  owner(key: string): Promise<void>;
  /** Names a relay for the space's devices to meet at. */
  relay(key: string, url: string): Promise<void>;
  /** Who is in the space. */
  members(): Promise<Member[]>;
  /** Opens a pipe to the node, for a client of your own making. */
  readonly connect: Connect;
  /** A client of the node, which keeps files it fetches in a folder of the platform's unless told of another. */
  client(host?: Partial<Omit<Host, "connect">>): Client;
  /** Stops the node, which makes what it was given durable. */
  close(): Promise<void>;
}
