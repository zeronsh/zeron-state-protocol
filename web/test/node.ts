// A device, on its own: what it keeps of itself, what it refuses, and what it does when there is nothing to do.

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Node, spaceUrl } from "../src/node.ts";
import { Client } from "../src/client.ts";
import { MemoryVolume, type File } from "../src/volume.ts";
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

// Nonsense, or a roster that is not its space's, does not make a device of a space; and it can join one after.
{
  const volume = new MemoryVolume();
  const node = await Node.open({ volume, module, log: () => {} });
  const forged = new Uint8Array(200);
  forged.set(new TextEncoder().encode("zsp-r1"));
  crypto.getRandomValues(forged.subarray(6));
  assert(!node.adopt(forged));
  assert.equal(node.space, undefined, "a forged roster made it of a space");
  const owner = join(TMP, "forged-owner");
  const space = execFileSync(BIN, ["create", owner], { encoding: "utf8" }).trim();
  execFileSync(BIN, ["admit", owner, node.key, "1"]);
  await node.close();
  const again = await Node.open({ volume, module, log: () => {} });
  assert.equal(again.space, undefined, "and is so after a restart");
  assert(again.adopt(readFileSync(join(owner, space, "roster"))));
  assert.equal(again.space, space);
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

// What it cannot keep of the space, it does not go on without: keys it could not keep would be lost at the next start, and
// with them everything sealed under them, so the change is refused, the node stops, and nothing more is said durable.
{
  let failing = false;
  class Failing extends MemoryVolume {
    override async open(name: string, create: boolean): Promise<File | undefined> {
      const f = await super.open(name, create);
      if (!f || !/^(keys|roster)\./.test(name)) return f;
      const write = f.write.bind(f);
      f.write = (b, at) => {
        if (failing) throw new Error("the disk is full");
        return write(b, at);
      };
      return f;
    }
  }
  const volume = new Failing();
  volume.openNow = undefined; // through open, which is watched
  const node = await Node.open({ volume, module, log: () => {} });
  let failure: Error | undefined;
  node.onFailure = (e) => (failure = e);
  node.create();
  const client = new Client({ connect: node.connect });
  while (!client.may(1, "write")) await new Promise((done) => setTimeout(done, 1));
  failing = true;
  assert.throws(() => node.scope(true), /storage has failed/);
  let durable = false;
  void client.write(1, (change) => change.insert({}, "x", 1, {})).then(() => (durable = true));
  await new Promise((done) => setTimeout(done, 300));
  assert(failure, "it says that it has stopped");
  assert(!durable, "and says nothing more is durable");
  assert.throws(() => node.member, /storage/, "and answers nothing it would make up");
  assert.throws(() => node.members());
  client.close();
}

// Where a relay keeps a space, a proxy's query staying at the end.
assert.equal(spaceUrl("wss://relay.example/", "ab"), "wss://relay.example/ab");
assert.equal(spaceUrl("wss://relay.example/zsp?key=1", "ab"), "wss://relay.example/zsp/ab?key=1");

rmSync(TMP, { recursive: true, force: true });
console.log("ok");
