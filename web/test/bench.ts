// What a web device costs, in Node: `node --expose-gc test/bench.ts [rows]`, or `./x bench web`. Each figure is the median of many.

import { execFileSync, spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client, columns as c } from "../src/client.ts";
import { where } from "../src/ask.ts";
import { Node } from "../src/node.ts";
import { NodeVolume } from "../src/volume-node.ts";
import { MemoryVolume, type Volume } from "../src/volume.ts";
import { loadModule } from "../src/wasm.ts";
import { BIN } from "./procs.ts";

const ROWS = Number(process.argv[2] ?? 100000);
const TMP = mkdtempSync(join(tmpdir(), "zsp-bench-"));
const zspd = (...args: string[]) => execFileSync(BIN, args, { encoding: "utf8" }).trim();
const Message = { author: c.string(16), body: c.text(17), stars: c.number(18) };
const sleep = (ms: number) => new Promise((done) => setTimeout(done, ms));
const median = (xs: number[]) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];
const ms = (x: number) => (x < 1 ? `${(x * 1000).toFixed(0)} µs` : `${x.toFixed(x < 10 ? 2 : 0)} ms`);
const out: [string, string][] = [];
const say = (what: string, figure: string) => {
  out.push([what, figure]);
  console.log(`${what.padEnd(60)} ${figure}`);
};

// A space of its own, which this device is admitted to, with no relay.
const owner = join(TMP, "owner");
const space = zspd("create", owner);
async function device(volume: Volume, module: WebAssembly.Module): Promise<{ node: Node; client: Client }> {
  const node = await Node.open({ volume, module });
  if (!node.space) {
    zspd("admit", owner, node.key, "1");
    node.adopt(readFileSync(join(owner, space, "roster")));
  }
  const client = new Client({ connect: node.connect });
  while (!client.may(1, "write")) await sleep(1);
  return { node, client };
}

let t = performance.now();
const module = await loadModule();
say("compiling the node", ms(performance.now() - t));

// Starting: a device made from nothing, and one opened again.
{
  const starts: number[] = [];
  for (let i = 0; i < 10; i++) {
    t = performance.now();
    const node = await Node.open({ volume: new NodeVolume(join(TMP, "start-" + i)), module });
    starts.push(performance.now() - t);
    await node.close();
  }
  say("starting a device, made from nothing", ms(median(starts)));
}

for (const [name, volume] of [
  ["on disk", new NodeVolume(join(TMP, "disk"))],
  ["in memory", new MemoryVolume()],
] as const) {
  const { node, client } = await device(volume, module);
  // A write, durable: one row at a time, each waited for.
  const writes: number[] = [];
  for (let i = 0; i < 300; i++) {
    t = performance.now();
    await client.write(1, (change) => change.insert(Message, "chat", i, { author: "wing", stars: i }));
    writes.push(performance.now() - t);
    if (i % 3 === 0) await sleep(110); // and some after a pause, which wait for nobody's sync but their own
  }
  say(`one small durable write, ${name}`, ms(median(writes)));

  // Many rows, a thousand to a write, as fast as they are taken: all asked for, and the last waited for.
  t = performance.now();
  const all: Promise<void>[] = [];
  for (let i = 0; i < ROWS; i += 1000) {
    all.push(
      client.write(1, (change) => {
        for (let k = i; k < i + 1000 && k < ROWS; k++) change.insert(Message, "big", k, { author: "author " + (k % 100), stars: k % 1000, body: "the quick brown fox " + k });
      }),
    );
  }
  await Promise.all(all);
  const took = performance.now() - t;
  say(`writing ${ROWS} rows, a thousand to a write, ${name}`, `${ms(took)}, ${((ROWS / took) * 1000).toFixed(0)} rows/s`);
  if (name === "on disk") {
    await node.close();
    t = performance.now();
    const again = await Node.open({ volume: new NodeVolume(join(TMP, "disk")), module });
    say(`opening it again, ${ROWS} rows`, ms(performance.now() - t));
    await again.close();
    continue;
  }
  // A page of 50 rows, by a client that has nothing yet: found, read, opened, put in order.
  const pages: number[] = [];
  for (let i = 0; i < 30; i++) {
    const fresh = new Client({ connect: node.connect });
    while (!fresh.ready) await sleep(0);
    t = performance.now();
    await new Promise<void>((done) => {
      const w = fresh.window({ scope: 1, list: "big", table: Message, size: 50 }, (s) => {
        if (s.status === "ready" && s.rows.length === 50) (pages.push(performance.now() - t), w.stop(), done());
      });
    });
    fresh.close();
  }
  say(`a page of 50 rows of ${ROWS}, to a client that holds none`, ms(median(pages)));
  // A question, once its index is made.
  await client.fetch({ scope: 1, table: Message, where: where.is("author", "author 7"), order: ["-stars"], limit: 50 });
  const asks: number[] = [];
  for (let i = 0; i < 30; i++) {
    t = performance.now();
    const a = await client.fetch({ scope: 1, table: Message, where: where.is("author", `author ${i}`), order: ["-stars"], limit: 50 });
    asks.push(performance.now() - t);
    if (a.rows.length !== 50) throw new Error("a short answer");
  }
  say(`a question of ${ROWS} rows, the first 50 of ${ROWS / 100} by a number`, ms(median(asks)));
  // A token, typed by one client and seen by another, of one device.
  const rid = await new Promise<string>((done) => {
    let id = "";
    void client.write(1, (change) => (id = change.insert(Message, "tokens", 1, {}))).then(() => done(id));
  });
  const reader = new Client({ connect: node.connect });
  let shown = "";
  reader.window({ scope: 1, list: "tokens", table: Message }, (s) => (shown = s.rows[0]?.body ?? ""));
  while (!reader.ready) await sleep(1);
  const editor = client.text(rid, Message.body);
  const tokens: number[] = [];
  let said = "";
  for (let i = 0; i < 200; i++) {
    said += `token${i} `;
    t = performance.now();
    editor.append(`token${i} `);
    while (shown !== said) await new Promise((done) => setImmediate(done));
    tokens.push(performance.now() - t);
  }
  say("a streamed token, from one client of a device to another", ms(median(tokens)));
  editor.close();
  (globalThis as { gc?: () => void }).gc?.();
  say(`memory, the node holding ${ROWS} rows and a page`, `${(node.memory / 1048576).toFixed(1)} MB of wasm, ${(process.memoryUsage().heapUsed / 1048576).toFixed(1)} MB of JS heap`);
  reader.close();
  client.close();
  await node.close();
}

// A token through a relay, from one web device to another.
{
  const relay = spawn(BIN, ["serve", join(TMP, "relay"), "--listen=127.0.0.1:0", "--no-udp"], { stdio: ["ignore", "pipe", "ignore"] });
  const [key, address] = await new Promise<string[]>((done) => relay.stdout.once("data", (d) => done(/(\w{64}) listening on ws:\/\/(\S+)/.exec(String(d))!.slice(1))));
  const url = "ws://127.0.0.1:" + address.split(":")[1];
  const o2 = join(TMP, "o2");
  const sid = zspd("create", o2);
  zspd("relay", o2, key, url);
  const ownerNode = spawn(BIN, ["run", o2, "--listen=127.0.0.1:0", "--no-udp"], { stdio: ["ignore", "pipe", "ignore"] });
  await new Promise((done) => ownerNode.stdout.once("data", done));
  const sides: Client[] = [];
  const nodes: Node[] = [];
  for (let k = 0; k < 2; k++) {
    const node = await Node.open({ volume: new MemoryVolume(), module });
    zspd("admit", o2, node.key, "1");
    node.join(sid, { key, url });
    const cl = new Client({ connect: node.connect });
    while (!cl.may(1, "write")) await sleep(5);
    sides.push(cl);
    nodes.push(node);
  }
  const [a, b] = sides;
  let id = "";
  await a.write(1, (change) => (id = change.insert(Message, "t", 1, {})));
  let shown = "";
  b.window({ scope: 1, list: "t", table: Message }, (s) => (shown = s.rows[0]?.body ?? ""));
  await sleep(300);
  const editor = a.text(id, Message.body);
  const tokens: number[] = [];
  let said = "";
  for (let i = 0; i < 200; i++) {
    said += `token${i} `;
    t = performance.now();
    editor.append(`token${i} `);
    while (shown !== said) await new Promise((done) => setImmediate(done));
    tokens.push(performance.now() - t);
  }
  say("a streamed token, web device to zspd relay to web device's screen", ms(median(tokens)));
  editor.close();
  a.close();
  b.close();
  for (const node of nodes) await node.close();
  relay.kill();
  ownerNode.kill();
}

rmSync(TMP, { recursive: true, force: true });
process.exit(0); // what is left open, such as a socket closing, is not waited for
