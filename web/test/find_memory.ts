// Asking about column after column makes an index of each, in bulk: what that takes is given back, in WebAssembly too,
// where there is no arena to put it in and it comes from the heap. `node test/find_memory.ts`

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client, columns, type Column } from "../src/client.ts";
import { where } from "../src/ask.ts";
import { Node } from "../src/node.ts";
import { MemoryVolume } from "../src/volume.ts";
import { loadModule } from "../src/wasm.ts";
import { BIN } from "./procs.ts";

const TMP = mkdtempSync(join(tmpdir(), "zsp-find-"));
const owner = join(TMP, "owner");
const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
const node = await Node.open({ volume: new MemoryVolume(), module: await loadModule(), log: () => {} });
execFileSync(BIN, ["admit", owner, node.key, "1"]);
node.adopt(readFileSync(join(owner, space, "roster")));
const client = new Client({ connect: node.connect });
while (!client.may(1, "write")) await new Promise((done) => setTimeout(done, 1));

const COLUMNS = 40, ROWS = 4000;
const table: Record<string, Column<number>> = {};
for (let k = 0; k < COLUMNS; k++) table["c" + k] = columns.number(16 + k);
for (let i = 0; i < ROWS; i += 500) {
  await client.write(1, (change) => {
    for (let r = i; r < i + 500; r++) {
      const values: Record<string, number> = {};
      for (let k = 0; k < COLUMNS; k++) values["c" + k] = (r * (k + 7)) % 997;
      change.insert(table, "rows", r, values);
    }
  });
}
const ask = (k: number) => client.fetch({ scope: 1, table, where: where.over("c" + k, 500), order: ["c" + k], limit: 10 });
// Some first, that whatever is kept of indexes is kept; then the rest, which should cost no more memory than that.
for (let k = 0; k < 10; k++) assert.equal((await ask(k)).rows.length, 10);
const before = node.memory;
for (let k = 10; k < COLUMNS; k++) assert.equal((await ask(k)).rows.length, 10);
const grown = (node.memory - before) / 1048576;
console.log(`${COLUMNS - 10} more columns made an index of: the node grew by ${grown.toFixed(1)} MB`);
assert(grown < 2, `${grown.toFixed(1)} MB more: what making an index takes is not given back`);
client.close();
await node.close();
rmSync(TMP, { recursive: true, force: true });
console.log("ok");
