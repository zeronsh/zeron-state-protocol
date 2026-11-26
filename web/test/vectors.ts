// Agreement with vectors/vectors.json, as luau/tests/vectors.luau has it: node web/test/vectors.ts vectors/vectors.json

import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

import * as codec from "../src/codec.ts";
import * as services from "../src/services.ts";
import { Sha256, sha256 } from "../src/sha256.ts";
import * as text from "../src/text.ts";
import { random } from "./random.ts";

type Cell = { kind: number; stamp: string; body: string };
type Vectors = {
  keys: { key: string; wire: string }[];
  lists: { scope: number; list_key: string; name: string; tag: string }[];
  texts: { cells: Cell[]; text: string }[];
  files: { size: number; chunks: string[]; file: string }[];
  services: { message: string; bytes: string }[];
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

// A piece at a time, however the pieces fall, as at once.
{
  const { createHash } = await import("node:crypto");
  const data = new Uint8Array(5000);
  for (let i = 0; i < data.length; i++) data[i] = (i * 31 + 3) & 255;
  for (let k = 0; k < 200; k++) {
    const n = rng.int(0, data.length);
    const h = new Sha256();
    for (let at = 0; at < n; ) {
      const step = Math.min(n - at, rng.int(0, 150));
      h.update(data.subarray(at, at + step));
      at += step;
    }
    assert.equal(codec.hex(h.digest()), createHash("sha256").update(data.subarray(0, n)).digest("hex"), `sha256 of ${n} bytes in pieces`);
  }
}

// Files hashed in chunks of a MiB, as §16 says: fed in pieces that fall across the chunks' edges.
for (const v of vectors.files) {
  const data = new Uint8Array(v.size);
  for (let i = 0; i < v.size; i++) data[i] = (i * 7 + Math.floor(i / 251)) & 255;
  const h = new services.Hashing();
  const chunks: string[] = [];
  for (let at = 0; at < data.length; ) {
    const { taken, ended } = h.feed(data.subarray(at, at + 65536 + 3));
    at += taken;
    if (ended || at === data.length) chunks.push(codec.hex(h.chunk()));
  }
  assert.deepEqual(chunks, v.chunks, `the chunks of ${v.size} bytes`);
  assert.equal(codec.hex(h.file()), v.file, `the file of ${v.size} bytes`);
}

// What services say, byte for byte: what a client says made here, and what a device says read here. Each of them.
{
  const said = new Map(vectors.services.map((v) => [v.message, v.bytes]));
  const seen = new Set<string>();
  const of = (message: string): Uint8Array => {
    assert.ok(said.has(message), `vectors.json says "${message}"`);
    seen.add(message);
    return codec.unhex(said.get(message)!);
  };
  const made = (message: string, bytes: Uint8Array) => assert.equal(codec.hex(bytes), codec.hex(of(message)), message);
  const hash = codec.unhex("5e884898da28047151d0e56f8dc6292773603d0d6aabbdd62a11ef721d1542d8");
  made("zsp.tcp to port 22 of 127.0.0.1", services.tcpRequest(22, "127.0.0.1"));
  made("zsp.exec ls -l /tmp, LANG=C and without HOME, in /srv", services.execRequest(["ls", "-l", "/tmp"], { LANG: "C", HOME: null }, "/srv"));
  made("zsp.pty 24 rows by 80, xterm-256color, the user's shell, COLORTERM=truecolor", services.ptyRequest(24, 80, "xterm-256color", { COLORTERM: "truecolor" }));
  made("zsp.get docs/report.pdf from 3 MiB, as it was", services.getRequest("docs/report.pdf", 3 << 20, Uint8Array.of(0xaa, 0xbb, 0xcc)));
  made(
    "zsp.put docs/new/report.pdf of 2.5 MiB, replacing, making folders",
    services.putRequest("docs/new/report.pdf", 2621440, 1700000000123, Uint8Array.of(1, 2, 3, 4), { replace: true, folders: true }),
  );
  made("zsp.list docs/sub", services.listRequest("docs/sub"));
  made("input: ls", services.inputMessage(new TextEncoder().encode("ls\n")));
  made("signal: interrupt", services.signalMessage("interrupt"));
  made("resize: 50 rows by 132", services.resizeMessage(50, 132));
  made("a chunk's hash follows its bytes", services.chunkMessage(hash));
  made("the end of a file sent whole, with its hash", services.endMessage("ok", hash));

  assert.deepEqual(services.readEntries(of("an entry: a.txt, 1234 bytes")), [{ name: "a.txt", kind: "file", size: 1234, modified: 1700000000000 }]);
  const listed = services.readStatus(of("zsp.services: terminals and commands, docs to read and write, port 22 as ssh"));
  assert.equal(listed.status, "ok");
  assert.deepEqual(services.readServices(listed.rest), [
    { kind: "shell", terminal: true, commands: true },
    { kind: "files", name: "docs", read: true, write: true },
    { kind: "tcp", port: 22, host: "", name: "ssh" },
  ]);
  const ok = services.readStatus(of("status: ok"));
  assert.ok(ok.status === "ok" && ok.rest.length === 0);
  const denied = services.readStatus(of("status: denied, with a reason"));
  assert.deepEqual([denied.status, denied.reason], ["denied", "not shared with you"]);
  const got = services.readStatus(of("zsp.get answered: 2.5 MiB, from 1 MiB"));
  assert.deepEqual({ ...services.readGot(got.rest), identity: codec.hex(services.readGot(got.rest).identity) }, { size: 2621440, modified: 1700000000123, identity: "aabbcc", from: 1 << 20 });
  assert.equal(services.readFrom(services.readStatus(of("zsp.put answered: from 2 MiB")).rest), 2 << 20);
  assert.deepEqual(services.readOutput(of("output: hi")), { kind: "output", data: new TextEncoder().encode("hi") });
  assert.deepEqual(services.readOutput(of("errors: no")), { kind: "errors", data: new TextEncoder().encode("no") });
  assert.deepEqual(services.readOutput(of("exited 1")), { kind: "exit", exit: { code: 1, signal: 0 } });
  assert.deepEqual(services.readOutput(of("killed by 9")), { kind: "exit", exit: { code: 0, signal: 9 } });
  assert.deepEqual([...said.keys()].filter((m) => !seen.has(m)), [], "every message is held to");
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
