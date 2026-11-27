// What structured state costs on a client, without a network, as luau/tests/mirror_bench.luau measures it, case for case,
// from what it wrote down of what a node sends (the clients read each other's writing):
//
//   node --expose-gc web/test/mirror_bench.ts [rows...]               every case once, timed, with what it holds after
//   node --expose-gc web/test/mirror_bench.ts rows CASE FILE COUNT    one case, COUNT times (0: only what leads to it)
//
//   node --expose-gc web/test/mirror_bench.ts rows CASE FILE COUNT memory   and what the heap holds after, collected
//   node --expose-gc web/test/mirror_bench.ts rows CASE FILE COUNT alloc    and what the case made
//
// Where ZSP_PERF_CTL and ZSP_PERF_ACK name perf's control and answering fifos, perf counts only the case itself.
//
// bench/mirror.py runs each case as a process of its own; see there.

import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, openSync, readFileSync, readSync, writeSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { Client, columns as c } from "../src/client.ts";
import { where } from "../src/ask.ts";
import * as m from "../src/mirror.ts";
import * as codec from "../src/codec.ts";

const CELLS = 7, ACK = 8, ROSTER = 2, ASK = 32, UNASK = 33, ANSWER = 34;
const KEY = "k".repeat(32);
const TIMES = 200;
const PART = 10000; // items to a change, as luau/tests/mirror_bench.luau makes them
const root = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

type Data = Map<string, Uint8Array[]>;

// The same numbers every run: a xorshift of 32 bits, as the Luau bench has.
let seed = 2463534242;
function next(lo: number, hi: number): number {
  seed = (seed ^ (seed << 13)) >>> 0;
  seed = (seed ^ (seed >>> 17)) >>> 0;
  seed = (seed ^ (seed << 5)) >>> 0;
  return lo + (seed % (hi - lo + 1));
}

interface Peer {
  client: Client;
  receive: (data: Uint8Array) => void;
  deferred: (() => void)[];
  asks: Uint8Array[];
  sent: number; // the last of what it wrote
  acked: number;
  unasks: number[]; // questions no longer asked, to be let go of
}

function frame(body: Uint8Array): Uint8Array {
  const w = codec.writer(body.length + 8);
  codec.putBytes(w, body);
  return codec.written(w).slice();
}

function cellsFrame(cells: Uint8Array): Uint8Array {
  const w = codec.writer(cells.length + 8);
  codec.putU8(w, CELLS);
  codec.putVarint(w, 0);
  codec.put(w, cells);
  return frame(codec.written(w));
}

function peer(): Peer {
  const self: Peer = { client: undefined as unknown as Client, receive: () => {}, deferred: [], asks: [], sent: 0, acked: 0, unasks: [] };
  self.client = new Client({
    credential: "x",
    now: () => 1800000000000,
    random: (n) => {
      const b = new Uint8Array(n);
      for (let i = 0; i < n; i++) b[i] = next(0, 255);
      return b;
    },
    defer: (f) => void self.deferred.push(f),
    after: () => () => {},
    connect: (receive) => {
      self.receive = receive;
      let rest = new Uint8Array(0);
      return {
        send: (data) => {
          // A stream of bytes, sent in pieces of at most a MiB: a frame may be cut, and is read once it is whole.
          let all = data;
          if (rest.length > 0) {
            all = new Uint8Array(rest.length + data.length);
            all.set(rest);
            all.set(data, rest.length);
          }
          const r = codec.reader(all);
          while (r.pos < r.len) {
            const at = r.pos;
            let n: number;
            try {
              n = codec.varint(r);
            } catch {
              r.pos = at;
              break;
            }
            if (r.pos + n > r.len) {
              r.pos = at;
              break;
            }
            const body = all.subarray(r.pos, r.pos + n);
            r.pos += n;
            if (body[0] === ASK) self.asks.push(body.slice(1));
            else if (body[0] === CELLS || body[0] === UNASK) {
              const f = codec.reader(body);
              f.pos = 1;
              if (body[0] === CELLS) self.sent = codec.varint(f);
              else self.unasks.push(codec.varint(f));
            }
          }
          rest = all.slice(r.pos);
        },
        close: () => {},
      };
    },
  });
  const w = codec.writer();
  codec.putU8(w, ROSTER);
  codec.putBinary(w, "\0".repeat(8) + "\x01\x07" + KEY);
  self.receive(frame(codec.written(w)));
  return self;
}

// What is deferred, done; and then, as a node would, what was written acknowledged and what was no longer asked let go of.
function run(p: Peer): void {
  for (;;) {
    while (p.deferred.length > 0) p.deferred.shift()!();
    if (p.acked < p.sent) {
      const w = codec.writer();
      codec.putU8(w, ACK);
      codec.putVarint(w, (p.acked = p.sent));
      p.receive(frame(codec.written(w)));
    } else if (p.unasks.length > 0) {
      const w = codec.writer();
      codec.putU8(w, ANSWER);
      codec.putVarint(w, p.unasks.shift()!);
      codec.putU8(w, 16);
      p.receive(frame(codec.written(w)));
    } else return;
  }
}

const Big = m.map({ items: m.list(18, m.map({ n: c.number(16), label: c.string(17) })) });
const Notes = m.map({ items: m.list(18, m.map({ n: c.number(16), body: c.text(17) })) });
const Plain = { n: c.number(16), label: c.string(17) };

function readData(path: string): Data {
  const r = codec.reader(readFileSync(path));
  const out: Data = new Map();
  while (r.pos < r.len) {
    const name = new TextDecoder().decode(codec.bytes(r));
    const list: Uint8Array[] = [];
    for (let n = codec.varint(r); n > 0; n--) list.push(codec.bytes(r).slice());
    out.set(name, list);
  }
  return out;
}

const rowsOf = (data: Data) => Number(new TextDecoder().decode(data.get("rows")![0]));

// What the heap holds once collected.
function settled(): number {
  const gc = (globalThis as { gc?: () => void }).gc;
  if (!gc) throw new Error("run with --expose-gc");
  gc();
  gc();
  return process.memoryUsage().heapUsed;
}

// Counting by perf, when bench/mirror.py runs it so (perf stat -D -1 --control): only what is between counting(true) and
// counting(false), each told and answered before going on, so that what leads to a case costs it nothing.
const ctl = process.env.ZSP_PERF_CTL ? openSync(process.env.ZSP_PERF_CTL, "w") : undefined;
const ack = process.env.ZSP_PERF_ACK ? openSync(process.env.ZSP_PERF_ACK, "r") : undefined;
function counting(on: boolean) {
  if (ctl === undefined || ack === undefined) return;
  writeSync(ctl, on ? "enable\n" : "disable\n");
  readSync(ack, new Uint8Array(5));
}

// Answers a question as a node would, with the rows it was given: by ids, those; anything else, what the document's
// question finds.
function answer(q: Peer, data: Data): void {
  while (q.asks.length > 0) {
    const r = codec.reader(q.asks.shift()!);
    const id = codec.varint(r);
    codec.varint(r);
    // By ids, or all of: the list (16 bytes) and ids.
    const op = codec.u8(r);
    let byIds = op === 11;
    if (op === 1) {
      for (let n = codec.varint(r); n > 0; n--) {
        const inner = codec.u8(r);
        if (inner === 11) byIds = true;
        if (inner !== 9) break;
        codec.take(r, 16);
      }
    }
    const [rows, ids] = data.get(byIds ? "root" : "found")!;
    q.receive(cellsFrame(rows));
    const a = codec.writer();
    codec.putU8(a, ANSWER);
    codec.putVarint(a, id);
    codec.putU8(a, 1);
    codec.putVarint(a, ids.length / 16);
    codec.putVarint(a, 0);
    codec.putVarint(a, ids.length / 16);
    codec.put(a, ids);
    codec.putVarint(a, 0);
    q.receive(frame(codec.written(a)));
    run(q);
  }
}

function opened(data: Data, name: string, schema: m.MapSchema<any>, frames: string): { q: Peer; doc: m.Mirror<any> } {
  const q = peer();
  const doc = m.open(q.client, { scope: 1, name, schema });
  run(q);
  for (const f of data.get(frames)!) q.receive(f);
  run(q);
  return { q, doc };
}

interface Case {
  setup(data: Data): any;
  step(s: any, data: Data, k: number): void;
}

const cases: Record<string, Case> = {
  make: {
    setup: (data) => {
      const p = peer();
      const doc = m.open(p.client, { scope: 1, name: "big", schema: Big });
      run(p);
      return { p, doc, items: Array.from({ length: rowsOf(data) }, (_, i) => ({ n: i + 1, label: `item ${i + 1}` })) };
    },
    step: (s) => {
      // A change may be 4 MiB at most (SPEC.md 8): made in changes of so many, each the items there are and so many more.
      for (let at = 0; at < s.items.length; at += PART) {
        void s.doc.set({ items: [...s.doc.state.items, ...s.items.slice(at, at + PART)] });
        run(s.p);
      }
    },
  },
  open: {
    setup: () => {
      const q = peer();
      const doc = m.open(q.client, { scope: 1, name: "big", schema: Big });
      run(q);
      return { q, doc };
    },
    step: (s, data) => {
      s.q.receive(data.get("open")![0]);
      run(s.q);
      if (s.doc.state.items.length !== rowsOf(data)) throw new Error("not all of it is there");
    },
  },
  set_change: {
    setup: (data) => opened(data, "big", Big, "open"),
    step: (s) => {
      const list = [...s.doc.state.items];
      const i = next(1, list.length) - 1;
      list[i] = { ...list[i], n: list[i].n + 1 };
      void s.doc.set({ items: list });
      run(s.q);
    },
  },
  update_change: {
    setup: (data) => opened(data, "big", Big, "open"),
    step: (s) => {
      void s.doc.update((d: any) => {
        d.items[next(1, d.items.length) - 1].n += 1;
      });
      run(s.q);
    },
  },
  set_move: {
    setup: (data) => opened(data, "big", Big, "open"),
    step: (s) => {
      const list = [...s.doc.state.items];
      const [x] = list.splice(next(1, list.length) - 1, 1);
      list.splice(next(1, list.length + 1) - 1, 0, x);
      void s.doc.set({ items: list });
      run(s.q);
    },
  },
  update_move: {
    setup: (data) => opened(data, "big", Big, "open"),
    step: (s) => {
      void s.doc.update((d: any) => {
        const [x] = d.items.splice(next(1, d.items.length) - 1, 1);
        d.items.splice(next(1, d.items.length + 1) - 1, 0, x);
      });
      run(s.q);
    },
  },
  heard_change: {
    setup: (data) => opened(data, "big", Big, "open"),
    step: (s, data, k) => {
      const frames = data.get("change")!;
      s.q.receive(frames[(k - 1) % frames.length]);
      run(s.q);
    },
  },
  heard_move: {
    setup: (data) => opened(data, "big", Big, "open"),
    step: (s, data, k) => {
      const frames = data.get("move")!;
      s.q.receive(frames[(k - 1) % frames.length]);
      run(s.q);
    },
  },
  window: {
    setup: () => {
      const q = peer();
      const w = q.client.window({ scope: 1, list: "plain", table: Plain, size: 0, from: "start", bare: false }, () => {});
      run(q);
      return { q, w };
    },
    step: (s, data) => {
      s.q.receive(data.get("window")![0]);
      run(s.q);
      if (s.w.entries().length !== rowsOf(data)) throw new Error("not all of it is there");
    },
  },
  window_rows: {
    setup: () => {
      const q = peer();
      const box: { last?: any } = {};
      q.client.window({ scope: 1, list: "plain", table: Plain, size: 0, from: "start" }, (state) => (box.last = state));
      run(q);
      return { q, box };
    },
    step: (s, data) => {
      s.q.receive(data.get("window")![0]);
      run(s.q);
      if (s.box.last.rows.length !== rowsOf(data)) throw new Error("not all of it is there");
    },
  },
  notes_open: {
    setup: () => {
      const q = peer();
      const doc = m.open(q.client, { scope: 1, name: "notes", schema: Notes });
      run(q);
      return { q, doc };
    },
    step: (s, data) => {
      s.q.receive(data.get("notes")![0]);
      run(s.q);
      if (s.doc.state.items.length !== rowsOf(data)) throw new Error("not all of it is there");
    },
  },
  typing: {
    setup: (data) => {
      const { q, doc } = opened(data, "notes", Notes, "notes");
      const editor = q.client.text(codec.hex(data.get("typing")![0]), c.text(17));
      run(q);
      return { q, doc, editor };
    },
    step: (s, _data, k) => {
      s.editor.insert(0, String.fromCharCode(96 + (k % 26)));
      run(s.q);
    },
  },
  live_heard: {
    setup: (data) => opened(data, "notes", Notes, "notes"),
    step: (s, data, k) => {
      const frames = data.get("live")!;
      s.q.receive(frames[(k - 1) % frames.length]);
      run(s.q);
    },
  },
  ask: {
    setup: () => ({ q: peer() }),
    step: (s, data) => {
      let got: any;
      const asked = m.ask(s.q.client, { scope: 1, name: "big", schema: Big }, ["items"], { where: where.under("n", 51), limit: 50 }, (a) => (got = a));
      run(s.q);
      answer(s.q, data);
      if (!got || got.rows.length !== data.get("found")![1].length / 16) throw new Error("the question is not answered with what the node found");
      asked.stop();
      run(s.q);
    },
  },
};
const ORDER = ["make", "open", "set_change", "update_change", "set_move", "update_move", "heard_change", "heard_move", "window", "window_rows", "notes_open", "typing", "live_heard", "ask"];
const ONCE = new Set(["make", "open", "window", "window_rows", "notes_open"]);

function dataFor(rows: number): string {
  const path = join(root, "build", `mirror-bench-${rows}.bin`);
  if (!existsSync(path)) {
    mkdirSync(dirname(path), { recursive: true });
    execFileSync("lune", ["run", join(root, "luau/tests/mirror_bench.luau"), String(rows), "prep", path], { stdio: "inherit" });
  }
  return path;
}

const args = process.argv.slice(2);
if (args.length >= 3 && cases[args[1]]) {
  const data = readData(args[2]);
  const one = cases[args[1]];
  const count = Number(args[3] ?? "1");
  const memory = args[4] === "memory";
  const s = one.setup(data);
  settled(); // what opening left for the collector is collected now, whether the case is then done or not
  // Done some times first, not counted (ZSP_WARM), so that what is counted is a change as it is once the client has been
  // going a while: in V8, compiled as it will be; and not what is let go of only once, after what led to it.
  const warm = Number(process.env.ZSP_WARM ?? "0");
  for (let k = 1; k <= warm; k++) one.step(s, data, k);
  if (warm > 0) settled();
  const before = memory ? settled() : 0;
  counting(true);
  const t = performance.now();
  if (args[4] === "alloc") {
    // What the case made, where nothing is collected while it is done (bench/mirror.py gives V8 a young space big enough
    // for that); had anything been, the heap would have been less than it was a step before.
    const made = process.memoryUsage().heapUsed;
    let last = made, collected = 0;
    for (let k = 1; k <= count; k++) {
      one.step(s, data, warm + k);
      const now = process.memoryUsage().heapUsed;
      if (now < last) collected = 1;
      last = now;
    }
    console.log(`alloc_kb ${((last - made) / 1024).toFixed(1)} collected ${collected}`);
  } else for (let k = 1; k <= count; k++) one.step(s, data, warm + k);
  const took = (performance.now() - t) / 1000;
  counting(false);
  const after = memory ? settled() : 0;
  console.log(`seconds ${took.toFixed(6)} heap_kb ${Math.round((after - before) / 1024)}`);
  (globalThis as { kept?: unknown }).kept = s; // held until measured
} else {
  for (const rows of args.length > 0 ? args.map(Number) : [2000, 20000]) {
    const data = readData(dataFor(rows));
    console.log(`${rows} rows, each a map in one list; ${TIMES} of each change`);
    for (const name of ORDER) {
      const one = cases[name];
      const count = ONCE.has(name) ? 1 : TIMES;
      const s = one.setup(data);
      (globalThis as { kept?: unknown }).kept = s;
      const before = settled();
      const t = performance.now();
      for (let k = 1; k <= count; k++) one.step(s, data, k);
      const ms = (performance.now() - t) / count;
      const held = Math.round((settled() - before) / 1024);
      console.log(`  ${name.padEnd(16)} ${ms.toFixed(2).padStart(10)} ms ${String(held).padStart(10)} KB held after`);
    }
  }
  console.log("ok");
}
