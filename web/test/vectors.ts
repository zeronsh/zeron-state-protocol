// Agreement with vectors/vectors.json, as luau/tests/vectors.luau has it: node web/test/vectors.ts vectors/vectors.json

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import * as codec from "../src/codec.ts";
import { sha256 } from "../src/sha256.ts";
import * as text from "../src/text.ts";
import { random } from "./random.ts";

type Cell = { kind: number; stamp: string; body: string };
type Vectors = {
  keys: { key: string; wire: string }[];
  lists: { scope: number; list_key: string; name: string; tag: string }[];
  texts: { cells: Cell[]; text: string }[];
};

const vectors = JSON.parse(readFileSync(process.argv[2], "utf8")) as Vectors;
const utf8 = new TextEncoder();
const rng = random(1);

assert.equal(codec.hex(sha256(new Uint8Array(0))), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
assert.equal(codec.hex(sha256(new Uint8Array(1000).fill(97))), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3");
// Every length about the block's edges, against OpenSSL.
{
  const { createHash } = await import("node:crypto");
  const data = new Uint8Array(300);
  for (let i = 0; i < data.length; i++) data[i] = (i * 131 + 7) & 255;
  for (let n = 0; n <= data.length; n++) {
    const part = data.subarray(0, n);
    assert.equal(codec.hex(sha256(part)), createHash("sha256").update(part).digest("hex"), `sha256 of ${n} bytes`);
  }
}

for (const v of vectors.keys) {
  const w = codec.writer();
  codec.putKey(w, codec.binaryFromHex(v.key));
  assert.equal(codec.hex(codec.written(w)), v.wire, v.key);
  assert.equal(codec.hex(codec.key(codec.reader(codec.unhex(v.wire)))), v.key);
}

for (const v of vectors.lists) {
  const name = utf8.encode(v.name);
  const key = codec.unhex(v.list_key);
  const both = new Uint8Array(key.length + name.length);
  both.set(key);
  both.set(name, key.length);
  const tag = codec.u32Binary(v.scope) + codec.binary(sha256(both), 0, 12);
  assert.equal(codec.hex(tag), v.tag, v.name);
}

for (const [i, v] of vectors.texts.entries()) {
  const cells = v.cells.map((c) => ({ kind: c.kind, stamp: codec.binaryFromHex(c.stamp), body: codec.unhex(c.body) }));
  for (let round = 1; round <= 6; round++) {
    // in any order: the text is of the cells alone
    if (round > 1) rng.shuffle(cells);
    const t = text.create();
    for (const c of cells) text.apply(t, c.kind, c.stamp, c.body);
    assert.equal(t.waiting.length, 0, `text ${i + 1} still waits`);
    assert.equal(text.read(t), v.text, `text ${i + 1}`);
  }
}

// Writers here agree with each other, live frames and all.
const fresh = (): string => codec.u32Binary(rng.int(0, 2147483647) * 2 + 1) + codec.u32Binary(rng.int(0, 2147483647) * 2 + 1);
for (let seed = 1; seed <= 60; seed++) {
  const r = random(seed);
  const draw = (): string => codec.u32Binary(r.int(0, 2147483647) * 2 + 1) + codec.u32Binary(r.int(0, 2147483647) * 2 + 1);
  const writers = [text.create(), text.create(), text.create()];
  const all: { stamp: string; body: Uint8Array }[] = [];
  let clock = 0;
  const seal = (t: text.Text): void => {
    clock++;
    const stamp = codec.u64(clock) + draw();
    const body = text.close(t, stamp);
    if (body !== null) all.push({ stamp, body });
  };
  for (let k = 0; k < 200; k++) {
    const t = writers[r.int(0, 2)];
    const n = text.len(t);
    const pick = r.int(1, 10);
    if (pick <= 5) {
      text.insert(t, r.int(0, n), String.fromCharCode(r.int(97, 122)).repeat(r.int(1, 4)), draw);
    } else if (pick === 6 && n > 0) {
      const pos = r.int(0, n - 1);
      text.erase(t, pos, Math.min(r.int(1, 5), n - pos), draw);
    } else if (pick === 7) {
      const [piece, offset, ops] = text.flush(t);
      for (const o of writers) if (o !== t && piece !== "" && r.int(1, 2) === 1) text.live(o, piece, offset, ops);
    } else if (pick === 8) {
      seal(t);
    } else if (all.length > 0) {
      const c = all[r.int(0, all.length - 1)];
      text.apply(t, 4, c.stamp, c.body);
    }
  }
  for (const t of writers) seal(t);
  for (const t of writers) {
    r.shuffle(all);
    for (const c of all) text.apply(t, 4, c.stamp, c.body);
    assert.ok(t.waiting.length === 0 && text.read(t) === text.read(writers[0]), `seed ${seed}`);
  }
}

// However deep or wide someone makes a text, a place in it is found in a few steps.
{
  const t = text.create();
  const ids: string[] = [];
  const took = [0, 0];
  const N = 12000;
  const ref = (of: string): string => "\x02" + of + "\0";
  for (let i = 1; i <= N; i++) {
    const id = fresh();
    let where: string;
    if (i === 1) where = "\0\0";
    else if (i % 3 === 0) where = "\0" + ref(ids[ids.length - 3] ?? ids[0]);
    else if (i % 3 === 1) where = ref(ids[0]) + "\0";
    else where = ref(ids[rng.int(0, ids.length - 1)]) + ref(ids[rng.int(0, ids.length - 1)]);
    const before = text.steps();
    assert.equal(text.apply(t, 4, codec.u64(i) + fresh(), codec.bytesOf(id + "\x01" + where + "\x01x")), "changed");
    if (i <= 1000) took[0] += text.steps() - before;
    else if (i > N - 1000) took[1] += text.steps() - before;
    ids.push(id);
  }
  assert.ok(took[1] < 3 * took[0], `the last took ${took[1]} steps, the first ${took[0]}`);
}

console.log("ok");
