// A device, on its own: what it keeps of itself, what it refuses, and what it does when there is nothing to do.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Node, spaceUrl } from "../src/node.ts";
import { MemoryVolume } from "../src/volume.ts";
import { loadModule } from "../src/wasm.ts";
import { BIN } from "./procs.ts";

const module = await loadModule();
const TMP = mkdtempSync(join(tmpdir(), "zsp-node-"));

// One that never joined anything closes as well as any.
{
  const node = await Node.open({ volume: new MemoryVolume(), module });
  assert.equal(node.space, undefined);
  assert.equal(node.member, false);
  assert.equal(node.connect(() => {}, () => {}), undefined, "no client before there is a space");
  await node.close();
}

// Its key is its own for good, and so is the space it joins.
{
  const volume = new MemoryVolume();
  const first = await Node.open({ volume, module });
  assert.match(first.key, /^[0-9a-f]{128}$/);
  assert.equal(first.key.slice(0, 64), first.id);
  assert.throws(() => first.join("no", { key: "a".repeat(64), url: "ws://127.0.0.1:1" }));
  first.join("ab".repeat(32), { key: "cd".repeat(32), url: "ws://127.0.0.1:1" });
  assert.throws(() => first.join("ab".repeat(32), { key: "cd".repeat(32), url: "ws://127.0.0.1:1" }), "one space, once");
  await first.close();
  const again = await Node.open({ volume, module });
  assert.equal(again.key, first.key);
  assert.equal(again.space, "ab".repeat(32));
  await again.close();
}

// By a roster alone, and a member at once.
{
  const owner = join(TMP, "owner");
  const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  const node = await Node.open({ volume: new MemoryVolume(), module });
  execFileSync(BIN, ["admit", owner, node.key, "1"]);
  assert(node.adopt(readFileSync(join(owner, space, "roster"))));
  assert.equal(node.space, space);
  assert(node.member);
  assert(!node.adopt(new Uint8Array(100)), "nonsense is not a roster");
  await node.close();
}

// Where a relay keeps a space, a proxy's query staying at the end.
assert.equal(spaceUrl("wss://relay.example/", "ab"), "wss://relay.example/ab");
assert.equal(spaceUrl("wss://relay.example/zsp?key=1", "ab"), "wss://relay.example/zsp/ab?key=1");

rmSync(TMP, { recursive: true, force: true });
console.log("ok");
