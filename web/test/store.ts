// What a web device says is durable is: through bursts of writing, segments rolling and being evacuated and dropped,
// files that open only in their own time as a browser's do, and power lost at any moment. Against a node built with
// small segments, so that all of that happens often. `node test/store.ts <node-small.wasm> [seeds] [first]`

import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client, columns } from "../src/client.ts";
import { Node } from "../src/node.ts";
import { Store } from "../src/store.ts";
import { MemoryVolume } from "../src/volume.ts";
import { loadModule } from "../src/wasm.ts";

const ROOT = new URL("../../", import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, "$1");
const BIN = process.env.ZSPD ?? join(ROOT, "build", process.platform === "win32" ? "zspd.exe" : "zspd");
const module = await loadModule(new URL(process.argv[2], "file://" + process.cwd() + "/"));
const SEEDS = Number(process.argv[3] ?? 8);
const FIRST = Number(process.argv[4] ?? 1);
const TMP = mkdtempSync(join(tmpdir(), "zsp-store-"));
const owner = join(TMP, "owner");
const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();

const Row = { v: columns.bytes(16) };

// xorshift, so that a seed is a world.
function prng(seed: number) {
  let x = seed * 2654435761 + 1;
  return () => {
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    return (x >>> 0) / 4294967296;
  };
}

// Opens a node, letting whatever it waits to open be opened meanwhile.
async function opened(volume: MemoryVolume): Promise<Node> {
  const settling = setInterval(() => volume.settle(), 1);
  try {
    const node = await Node.open({ volume, module, log: (level, text) => level === "error" && console.error(text) });
    node.onFailure = (e) => {
      throw e;
    };
    return node;
  } finally {
    clearInterval(settling);
  }
}

const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));
const same = (a: Uint8Array, b: Uint8Array) => a.length === b.length && a.every((x, i) => x === b[i]);

interface Written {
  value: Uint8Array;
  durable: boolean;
  lost?: boolean; // asked for before a crash, and never said to be durable: it may or may not have been
}

async function world(seed: number): Promise<{ steps: number; crashes: number; bytes: number }> {
  const random = prng(seed);
  // Files opened at once, as Node opens them; or in their own time, as a browser does, now soon, now hardly ever, so that
  // writing outruns the files opened ahead of it.
  const slow = seed % 3 !== 0;
  const patience = seed % 3 === 2 ? 0.01 : 0.5;
  const volume = new MemoryVolume({ slow });
  let node = await opened(volume);
  execFileSync(BIN, ["admit", owner, node.key, "1"]);
  if (!node.adopt(readFileSync(join(owner, space, "roster")))) throw new Error("the roster was not taken");
  let client = new Client({ connect: node.connect });
  const rows = new Map<string, Written[]>(); // every value written to each, in order
  let order = 0, crashes = 0, bytes = 0, steps = 0;

  const until = async (f: () => boolean) => {
    for (let i = 0; i < 2000 && !f(); i++) {
      if (slow && random() < patience) volume.settle();
      await sleep(1);
    }
    if (!f()) throw new Error(`seed ${seed}${slow ? " (slow)" : ""}: never, at step ${steps}, with ${[...rows.values()].flat().filter((x) => !x.durable && !x.lost).length} writes outstanding`);
  };
  await until(() => client.may(1, "write"));

  // Each row now holds the last value said to be durable, or one written after it: nothing older, nothing lost.
  const check = async (when: string) => {
    let state: { rows: readonly { id: string; v?: Uint8Array }[]; status: string } | undefined;
    const w = client.window({ scope: 1, list: "l", table: Row, size: 0, from: "start" }, (s) => (state = s));
    await until(() => state !== undefined && state.status !== "loading");
    const seen = new Map(state!.rows.map((r) => [r.id, r.v]));
    for (const [id, written] of rows) {
      let last = -1;
      written.forEach((x, i) => x.durable && (last = i));
      const got = seen.get(id);
      // A row is in the list by the cell its making put there; made and lost, it is nowhere, whatever was said of it later.
      if (last < 0 || !written[0].durable) continue;
      if (!got || !written.slice(last).some((x) => same(x.value, got))) {
        throw new Error(`seed ${seed}${slow ? " (slow)" : ""}, ${when}: row ${id} lost what was durable (${written.length} writes, the last durable ${last}, ${got ? "an older value" : "gone"})`);
      }
    }
    w.stop();
  };

  for (; steps < 150; steps++) {
    const r = random();
    if (r < 0.45) {
      // A burst: new rows and new values for old ones, some of them large, all durable together.
      const burst: [string, Written][] = [];
      const ids = [...rows.keys()];
      let room = 96 << 10; // a record is at most half a segment, here 128 KiB, and a burst is one record
      void client
        .write(1, (change) => {
          for (let n = 1 + Math.floor(random() * 6); n > 0 && room > 400; n--) {
            const size = Math.min(room - 400, random() < 0.3 ? 20000 + Math.floor(random() * 40000) : 1 + Math.floor(random() * 300));
            room -= size + 100;
            const value = Uint8Array.from({ length: size }, () => Math.floor(random() * 256));
            bytes += size;
            const id = ids.length > 0 && random() < 0.5 ? ids[Math.floor(random() * ids.length)] : change.insert(Row, "l", ++order, {});
            change.set(id, Row, { v: value });
            burst.push([id, { value, durable: false }]);
          }
        })
        .then(() => burst.forEach(([, x]) => !x.lost && (x.durable = true)));
      for (const [id, x] of burst) rows.set(id, [...(rows.get(id) ?? []), x]);
    } else if (r < 0.75) {
      await sleep(random() < 0.8 ? 0 : 1 + Math.floor(random() * 120));
    } else if (r < 0.9 && slow) {
      if (random() < patience) volume.settle();
    } else if (r < 0.93) {
      // The power goes: whatever was not flushed is lost, and what is said to be durable must still be there.
      crashes++;
      for (const w of rows.values()) for (const x of w) if (!x.durable) x.lost = true;
      client.close();
      node.abandon();
      volume.crash();
      node = await opened(volume);
      client = new Client({ connect: node.connect });
      await until(() => client.may(1, "write"));
      await check("after a crash");
    }
  }
  await until(() => [...rows.values()].every((w) => w.every((x) => x.durable || x.lost)));
  await check("at the end");
  client.close();
  const settling = setInterval(() => volume.settle(), 1);
  await node.close();
  clearInterval(settling);
  return { steps, crashes, bytes };
}

let crashes = 0, bytes = 0;
const start = performance.now();
for (let seed = FIRST; seed < FIRST + SEEDS; seed++) {
  const w = await world(seed);
  crashes += w.crashes;
  bytes += w.bytes;
}
const { held, journaled, replayed } = Store.counts;
console.log(
  `${SEEDS} worlds, ${crashes} crashes, ${(bytes / 1048576).toFixed(0)} MB written, ${held} writes held for a file, ${journaled} journaled, ${replayed} replayed, in ${((performance.now() - start) / 1000).toFixed(1)} s`,
);
if (SEEDS >= 8 && (held === 0 || journaled === 0 || replayed === 0)) throw new Error("the ways round a file not yet open were not all taken");
rmSync(TMP, { recursive: true, force: true });
console.log("ok");
