// Luau's mirror and this one read each other's documents. A client here and one in Luau, each through a node made of
// nothing, write into one document at once, each as it likes, and hear each other's cells, and those of someone who minds
// nothing, in any order and some twice; whenever both have heard everything, each document is the same, to the byte.
// The Luau is luau/zsp's, or main's if the mirror is not there yet. node web/test/mirror_interop.ts [seeds] [first]

import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import * as codec from "../src/codec.ts";
import { columns as c } from "../src/client.ts";
import * as m from "../src/mirror.ts";
import type { Client } from "../src/client.ts";
import { board, derive, hostile, latest, mutate, rows } from "./mirror_cases.ts";
import { hear, peer, run } from "./peers.ts";
import { random } from "./random.ts";

const SEEDS = Number(process.argv[2] ?? 30);
const FIRST = Number(process.argv[3] ?? 1);
const STEPS = 24;

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "../..");
const utf8 = new TextEncoder();

// Numbers as eight bytes and nothing else, as the Luau side reads them too: so that what is read of a value is the same
// to both, and what is held to the same is the mirror.
const number = (slot: number) =>
  c.custom<number>(
    slot,
    (v) => {
      const b = new Uint8Array(8);
      new DataView(b.buffer).setFloat64(0, v);
      return b;
    },
    (b) => {
      if (b.length !== 8) throw new RangeError("a number is eight bytes");
      return new DataView(b.buffer, b.byteOffset, 8).getFloat64(0);
    },
  );
const Board = board(number); // as web/test/mirror_interop.luau has it

// Strings and numbers as their bytes, maps by their keys' bytes, in order, and ids as hex, as the Luau side writes them
// down. An empty string in a map is no value, as it is to a mirror; and an empty list is "{}", as is an empty map.
function canon(v: unknown): string {
  if (typeof v === "string") return "s" + codec.hex(utf8.encode(v));
  if (typeof v === "number") {
    if (Number.isNaN(v)) return "nnan";
    const b = new Uint8Array(8);
    new DataView(b.buffer).setFloat64(0, v);
    return "n" + codec.hex(b);
  }
  if (typeof v === "boolean") return v ? "t" : "f";
  if (typeof v !== "object" || v === null) return "?" + String(v);
  if (Array.isArray(v) && v.length > 0) return "[" + v.map(canon).join(",") + "]";
  const parts: string[] = [];
  for (const [k, x] of Object.entries(v)) {
    if (x === "" || x === undefined) continue;
    parts.push(k === "id" ? "id=" + x : codec.hex(utf8.encode(k)) + "=" + canon(x));
  }
  return "{" + parts.sort().join(",") + "}";
}

// An empty string is no value, and no text is an empty one; ids aside, as what is set new has none.
function like(a: unknown, b: unknown): boolean {
  if (a === "") a = undefined;
  if (b === "") b = undefined;
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return Object.is(a, b);
  const x = a as Record<string, unknown>, y = b as Record<string, unknown>;
  for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) if (k !== "id" && !like(x[k], y[k])) return false;
  return true;
}

// A copy as plain objects, as a draft is once it is done with.
const plain = (v: unknown): unknown =>
  typeof v !== "object" || v === null ? v : Array.isArray(v) ? v.map(plain) : Object.fromEntries(Object.entries(v).map(([k, x]) => [k, plain(x)]));

// Every row's word on where it is, as docs/mirror.md lays it out, from whichever writer: what is wrong, or undefined.
const ZERO = "\0".repeat(16), NOWHERE = "\0".repeat(12);
function misplaced(client: Client): string | undefined {
  const id = (s: string) => s === ZERO || s.startsWith("\0\0\0\x01");
  const marker = (s: string) => s.length === 12 && codec.u32Of(s, 8) < 2 ** 20;
  for (const [row, stored] of rows(client)) {
    const cell = stored.dead ? undefined : latest(stored, 255);
    if (!cell) continue;
    const r = codec.reader(cell.body);
    const owner = codec.takeBinary(r, 16), field = codec.binary(codec.bytes(r)), kind = codec.u8(r), rest = codec.binary(codec.rest(r));
    let fine = false;
    if (kind === 0) fine = rest === "" && (owner === ZERO ? field === "" && row === derive("") : row === derive(owner, field));
    else if (kind === 1) fine = marker(rest);
    else if (kind === 2) fine = rest.length >= 1 && rest.charCodeAt(0) <= 1 && row === derive(owner, field, rest.slice(1));
    else if (kind === 3) fine = rest.length === 56 && id(rest.slice(0, 16)) && marker(rest.slice(16, 28)) && id(rest.slice(28, 44)) && (rest.slice(44) === NOWHERE || marker(rest.slice(44)));
    if (!fine || !id(owner)) return `row ${codec.hex(row)}: kind ${kind}, ${codec.hex(cell.body)}`;
  }
  return undefined;
}

// The Luau client, which says what came of each thing it is told.
function luau(): { ask: (line: string) => Promise<string>; done: () => Promise<void> } {
  let path = join(root, "luau/zsp");
  let dir: string | undefined;
  if (!existsSync(join(path, "mirror.luau"))) {
    dir = mkdtempSync(join(tmpdir(), "zsp-luau-"));
    const names = execFileSync("git", ["-C", root, "ls-tree", "--name-only", "origin/main", "luau/zsp/"], { encoding: "utf8" }).trim().split("\n");
    for (const name of names) writeFileSync(join(dir, name.split("/").pop()!), execFileSync("git", ["-C", root, "show", `origin/main:${name}`]));
    path = dir;
  }
  const p = spawn("lune", ["run", join(here, "mirror_interop.luau"), relative(here, path)], { stdio: ["pipe", "pipe", "inherit"] });
  const lines = createInterface({ input: p.stdout })[Symbol.asyncIterator]();
  const ended = new Promise<number | null>((go) => p.on("close", (code) => go(code))); // heard however early it ends
  return {
    ask: async (line) => {
      p.stdin.write(line + "\n");
      const r = await lines.next();
      if (r.done) throw new Error(`the Luau side ended, told: ${line.slice(0, 80)}`);
      return r.value;
    },
    // Ends the Luau side, and fails if it did not end well: what it said wrong after its last answer is a failure too.
    done: async () => {
      if (p.exitCode === null && p.signalCode === null) p.stdin.end("quit\n");
      const code = await ended;
      if (dir) rmSync(dir, { recursive: true, force: true });
      if (code !== 0) throw new Error(`the Luau side ended with ${code}`);
    },
  };
}

const began = performance.now();
const side = luau();
let compared = 0, cells = 0;
try {
  for (let seed = FIRST; seed < FIRST + SEEDS; seed++) {
    const rng = random(seed);
    const R = (n: number) => rng.int(1, n);
    let clock = 1800000000;
    const p = peer((n) => Uint8Array.from({ length: n }, () => rng.int(0, 255)), () => clock * 1000);
    const doc = m.open(p.client, { scope: 1, name: "board", schema: Board });
    run(p);
    await side.ask(`seed ${seed}`);
    const log: Uint8Array[] = []; // every write, by either, and the forger's
    const heard = [new Set<number>(), new Set<number>()];
    const tell = async (to: number, k: number) => {
      heard[to].add(k);
      if (to === 0) hear(p, log[k]);
      else await side.ask("hear " + codec.hex(log[k]));
    };
    // Whenever both have heard everything, each document is the same.
    const same = async (when: string) => {
      for (const to of [0, 1]) {
        const order = log.map((_, k) => k).filter((k) => !heard[to].has(k));
        rng.shuffle(order);
        for (const k of order) await tell(to, k);
      }
      const ours = canon(doc.state);
      const theirs = await side.ask("state");
      compared++;
      // And each has written what docs/mirror.md says, as the other reads it, where nobody forges anything.
      if (seed % 3 !== 0) {
        const wrong = misplaced(p.client) ?? (await side.ask("check"));
        if (wrong !== undefined && wrong !== "ok") throw new Error(`seed ${seed}, ${when}: ${wrong}`);
      }
      if (ours !== theirs) {
        let at = 0;
        while (ours[at] === theirs[at]) at++;
        throw new Error(`seed ${seed}, ${when}: the documents differ from byte ${at}\n  ts   ...${ours.slice(Math.max(0, at - 80), at + 160)}\n  luau ...${theirs.slice(Math.max(0, at - 80), at + 160)}`);
      }
    };
    let forged = 0;
    for (let step = 1; step <= STEPS; step++) {
      clock += (rng.int(0, 2 ** 30) / 2 ** 30) * 3;
      await side.ask(`clock ${clock}`);
      if (R(3) > 1) {
        const before = p.out.length;
        let draft: unknown;
        void doc.update((d) => {
          mutate(d, rng);
          draft = plain(d);
        });
        run(p);
        if (!like(doc.state, draft)) throw new Error(`seed ${seed}, step ${step}: what TypeScript set is not what it reads: ${canon(draft)}`);
        for (let k = before; k < p.out.length; k++) log.push(p.out[k]);
      }
      if (R(3) > 1) {
        const said = await side.ask("write");
        if (!said.startsWith("cells")) throw new Error(`seed ${seed}, step ${step}: what Luau set is not what it reads: ${said}`);
        for (const h of said.split(" ").slice(1)) if (h) log.push(codec.unhex(h));
      }
      if (seed % 3 === 0 && R(3) === 1) log.push(hostile(p.client, rng, clock, ++forged, true));
      // Some of it reaches either, in any order, some of it twice.
      for (const to of [0, 1]) for (let times = rng.int(0, 4); times > 0 && log.length > 0; times--) await tell(to, R(log.length) - 1);
      if (step % 6 === 0) await same(`step ${step}`);
    }
    cells += log.length;
    doc.close();
  }
} finally {
  await side.done();
}
console.log(`${SEEDS} seeds, ${cells} writes between Luau and TypeScript, ${compared} times the same: ${((performance.now() - began) / 1000).toFixed(2)} s`);
console.log("ok");
