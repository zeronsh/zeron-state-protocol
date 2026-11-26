// Clients that hear only each other, through a node made of nothing: what one writes is kept, as a node keeps it, and
// told to another as a node would tell it. As luau/tests/mirror_model.luau has them, for the mirror's tests.

import * as codec from "../src/codec.ts";
import { Client } from "../src/client.ts";

const ROSTER = 2, CELLS = 7;
export const KEY = "k".repeat(32);

export interface Peer {
  client: Client;
  receive: (data: Uint8Array) => void;
  deferred: (() => void)[];
  /** What it has written, as another would be sent it. */
  out: Uint8Array[];
  /** What its node holds: whole rows, and of each that is deleted, by what. */
  rows: Map<string, Map<string, Uint8Array>>;
  dead: Map<string, string>;
}

/** A client of scope 1, which it may read, write and call in, with KEY for its key; random gives bytes, now the time. */
export function peer(random: (n: number) => Uint8Array, now: () => number): Peer {
  const self: Peer = { client: undefined as unknown as Client, receive: () => {}, deferred: [], out: [], rows: new Map(), dead: new Map() };
  self.client = new Client({
    credential: "x",
    now,
    random,
    defer: (f) => void self.deferred.push(f),
    after: () => () => {},
    connect: (receive) => {
      self.receive = receive;
      return {
        send: (data) => {
          const r = codec.reader(data);
          while (r.pos < r.len) {
            const body = codec.bytes(r);
            if (body[0] === CELLS) {
              const f = codec.reader(body.subarray(1));
              codec.varint(f);
              self.out.push(codec.rest(f).slice());
            }
          }
        },
        close: () => {},
      };
    },
  });
  const w = codec.writer();
  codec.putU8(w, ROSTER);
  codec.putBinary(w, "\0".repeat(8) + "\x01\x07" + KEY);
  tell(self, codec.written(w));
  return self;
}

function tell(p: Peer, body: Uint8Array): void {
  const framed = codec.writer(body.length + 8);
  codec.putBytes(framed, body);
  p.receive(codec.written(framed).slice());
}

export function run(p: Peer): void {
  while (p.deferred.length > 0) p.deferred.shift()!();
}

/**
 * Cells as a node would send them: whole rows, of what it holds; and nothing of a row it holds deleted, but a later
 * deletion. Only what is in the list, as a watch of it is sent: a row with no place yet is nowhere until it has one.
 * Says how many milliseconds of it were the client's own.
 */
export function hear(p: Peer, cells: Uint8Array): number {
  const touched = new Set<string>();
  const r = codec.reader(cells);
  let id = "";
  while (r.pos < r.len) {
    const tag = codec.u8(r);
    if (tag < 128) id = codec.takeBinary(r, 16);
    const slot = codec.u8(r);
    const stamp = codec.takeBinary(r, 16);
    const body = codec.bytes(r);
    const kind = tag % 64;
    const w = codec.writer(body.length + 40);
    codec.putU8(w, kind);
    codec.putBinary(w, id);
    codec.putU8(w, slot);
    codec.putBinary(w, stamp);
    codec.putBytes(w, body);
    const cell = codec.written(w).slice();
    const dead = p.dead.get(id);
    if (kind === 1) {
      if (dead === undefined || stamp > dead) {
        p.dead.set(id, stamp);
        p.rows.set(id, new Map([["grave", cell]]));
        touched.add(id);
      }
    } else if (dead === undefined) {
      let row = p.rows.get(id);
      if (!row) p.rows.set(id, (row = new Map()));
      row.set(String.fromCharCode(slot, kind) + stamp, cell);
      touched.add(id);
    }
  }
  const out = codec.writer();
  codec.putU8(out, CELLS);
  codec.putVarint(out, 0);
  for (const t of touched) {
    const row = p.rows.get(t)!;
    let placed = row.has("grave");
    for (const k of row.keys()) placed ||= k.charCodeAt(1) === 2;
    if (placed) for (const c of row.values()) codec.put(out, c);
  }
  const t = performance.now();
  tell(p, codec.written(out));
  run(p);
  return performance.now() - t;
}
