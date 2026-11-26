// Agreement with vectors.json by an implementation that shares nothing with the Odin one: OpenSSL through
// node:crypto, and SPEC.md.

import { createCipheriv, createDecipheriv, createHash, createHmac, createPrivateKey, createPublicKey, diffieHellman, verify } from "node:crypto";
import { readFileSync } from "node:fs";
import assert from "node:assert/strict";

const v = JSON.parse(readFileSync(process.argv[2]));
const bytes = (h) => Buffer.from(h, "hex");
const sha = (...p) => createHash("sha256").update(Buffer.concat(p)).digest();
const hmac = (k, ...p) => createHmac("sha256", k).update(Buffer.concat(p)).digest();
const hkdf = (salt, secret, info) => hmac(hmac(salt ?? Buffer.alloc(32), secret), Buffer.from(info), Buffer.from([1]));

const der = { private: bytes("302e020100300506032b656e04220420"), public: bytes("302a300506032b656e032100"), ed: bytes("302a300506032b6570032100"), edPrivate: bytes("302e020100300506032b657004220420") };
const secret = (k) => createPrivateKey({ key: Buffer.concat([der.private, k]), format: "der", type: "pkcs8" });
const publicOf = (k) => createPublicKey(secret(k)).export({ format: "der", type: "spki" }).subarray(-32);
const dh = (k, p) => diffieHellman({ privateKey: secret(k), publicKey: createPublicKey({ key: Buffer.concat([der.public, p]), format: "der", type: "spki" }) });

function hchacha(key, nonce) {
  const s = new Uint32Array(16);
  s.set([0x61707865, 0x3320646e, 0x79622d32, 0x6b206574]);
  for (let i = 0; i < 8; i++) s[4 + i] = key.readUInt32LE(i * 4);
  for (let i = 0; i < 4; i++) s[12 + i] = nonce.readUInt32LE(i * 4);
  const rot = (x, n) => (x << n) | (x >>> (32 - n));
  const q = (a, b, c, d) => {
    s[a] += s[b]; s[d] = rot(s[d] ^ s[a], 16); s[c] += s[d]; s[b] = rot(s[b] ^ s[c], 12);
    s[a] += s[b]; s[d] = rot(s[d] ^ s[a], 8); s[c] += s[d]; s[b] = rot(s[b] ^ s[c], 7);
  };
  for (let i = 0; i < 10; i++) {
    q(0, 4, 8, 12); q(1, 5, 9, 13); q(2, 6, 10, 14); q(3, 7, 11, 15);
    q(0, 5, 10, 15); q(1, 6, 11, 12); q(2, 7, 8, 13); q(3, 4, 9, 14);
  }
  const out = Buffer.alloc(32);
  for (let i = 0; i < 4; i++) out.writeUInt32LE(s[i], i * 4), out.writeUInt32LE(s[12 + i], 16 + i * 4);
  return out;
}
const open = (key, iv, ad, sealed) => {
  const d = createDecipheriv("chacha20-poly1305", key, iv, { authTagLength: 16 });
  d.setAAD(ad, { plaintextLength: sealed.length - 16 });
  d.setAuthTag(sealed.subarray(-16));
  return Buffer.concat([d.update(sealed.subarray(0, -16)), d.final()]);
};
const seal = (key, iv, ad, plain) => {
  const c = createCipheriv("chacha20-poly1305", key, iv, { authTagLength: 16 });
  c.setAAD(ad, { plaintextLength: plain.length });
  return Buffer.concat([c.update(plain), c.final(), c.getAuthTag()]);
};
const xopen = (key, nonce, ad, sealed) => open(hchacha(key, nonce.subarray(0, 16)), Buffer.concat([Buffer.alloc(4), nonce.subarray(16)]), ad, sealed);

// §3 keys
const device = bytes(v.device.secret);
assert.equal(publicOf(device).toString("hex"), v.device.device);
const seed = hkdf(null, device, "zsp-sign");
const signer = createPublicKey(createPrivateKey({ key: Buffer.concat([der.edPrivate, seed]), format: "der", type: "pkcs8" }));
assert.equal(signer.export({ format: "der", type: "spki" }).subarray(-32).toString("hex"), v.device.signer);

for (const { list_key, scope, name, tag } of v.lists) {
  const s = Buffer.alloc(4);
  s.writeUInt32BE(scope);
  assert.equal(Buffer.concat([s, sha(bytes(list_key), Buffer.from(name)).subarray(0, 12)]).toString("hex"), tag);
}

// §4 cells
function cell(buf) {
  const kind = buf[0], row = buf.subarray(1, 17), slot = buf[17], stamp = buf.subarray(18, 34);
  let n = 0, shift = 0, at = 34, b;
  do (b = buf[at++]), (n |= (b & 127) << shift), (shift += 7);
  while (b & 128);
  assert.equal(at + n, buf.length);
  return { kind, row, slot, stamp, body: buf.subarray(at) };
}
for (const c of v.cells) {
  const o = cell(bytes(c.open)), s = cell(bytes(c.sealed));
  const id = Buffer.concat([s.row, Buffer.from([s.slot, s.kind])]);
  assert.equal(sha(id, s.stamp).subarray(0, 16).toString("hex"), c.print);
  const clear = s.kind === 2 ? 24 : s.kind === 5 ? 4 + 16 * s.body.readUInt32BE(0) : 0;
  let sealed = s.body.subarray(clear);
  if (s.row.readUInt32BE(0) === 4) {
    // a signed scope: author, seal, signature
    const body = s.body.subarray(0, -64);
    assert(verify(null, Buffer.concat([id, s.stamp, body]), signer, s.body.subarray(-64)));
    assert.equal(sealed[0], 0);
    sealed = body.subarray(clear + 1);
  }
  assert.deepEqual(sealed.subarray(0, 4), hkdf(null, bytes(c.key), "zsp-commit").subarray(0, 4)); // which key
  const nonce = Buffer.concat([s.stamp, Buffer.from([s.slot, s.kind, 0, 0, 0, 0, 0, 0])]);
  const plain = xopen(bytes(c.key), nonce, Buffer.concat([id, s.body.subarray(0, clear)]), sealed.subarray(4));
  // and in a signed scope, for whom, first
  const as = bytes(c.as);
  const before = s.row.readUInt32BE(0) === 4 ? Buffer.concat([Buffer.from([as.length]), as]) : Buffer.alloc(0);
  assert.deepEqual(plain.subarray(0, before.length), before);
  assert.deepEqual(Buffer.concat([s.body.subarray(0, clear), plain.subarray(before.length)]), o.body);
}

// §7 the handshake, from both ends
{
  const x = Object.fromEntries(Object.entries(v.handshake).map(([k, h]) => [k, bytes(h)]));
  const rs = publicOf(x.responder), is = publicOf(x.initiator);
  let hash = Buffer.from("Noise_IK_25519_ChaChaPoly_SHA256"), chain = hash, key, n;
  const mix = (d) => (hash = sha(hash, d));
  const dhMix = (s) => {
    const prk = hmac(chain, s);
    chain = hmac(prk, Buffer.from([1]));
    key = hmac(prk, chain, Buffer.from([2]));
    n = 0;
  };
  const put = (plain) => {
    const iv = Buffer.alloc(12);
    iv.writeBigUInt64LE(BigInt(n++), 4);
    const out = seal(key, iv, hash, plain);
    mix(out);
    return out;
  };
  mix(Buffer.concat([Buffer.from("zsp-1"), x.space]));
  mix(rs);
  const ie = publicOf(x.initiator_ephemeral), re = publicOf(x.responder_ephemeral);
  mix(ie);
  dhMix(dh(x.initiator_ephemeral, rs));
  const s1 = put(is);
  dhMix(dh(x.initiator, rs));
  const s2 = put(x.when);
  assert.deepEqual(Buffer.concat([ie, s1, s2]), x.first);
  mix(re);
  dhMix(dh(x.initiator_ephemeral, re));
  dhMix(dh(x.initiator, re));
  assert.deepEqual(Buffer.concat([re, put(Buffer.alloc(0))]), x.second);
  const prk = hmac(chain, Buffer.alloc(0));
  const send = hmac(prk, Buffer.from([1]));
  assert.deepEqual(send, x.send);
  assert.deepEqual(hmac(prk, send, Buffer.from([2])), x.recv);
}

// A local client's Call, which says how urgent it is, and a Flow's credit (§12): frames as a pipe carries them.
{
  const varint = (x) => {
    const out = [];
    for (; x >= 128; x = Math.floor(x / 128)) out.push((x % 128) | 128);
    return Buffer.from([...out, x]);
  };
  const str = (b) => Buffer.concat([varint(b.length), b]);
  const frame = (type, ...parts) => {
    const body = Buffer.concat([Buffer.from([type]), ...parts]);
    return Buffer.concat([varint(body.length), body]);
  };
  const c = v.local_call;
  const call = frame(15, varint(c.id), bytes(c.device), varint(c.scope), str(Buffer.from(c.method)), str(Buffer.from(c.for)), Buffer.from([c.urgency]), bytes(c.first));
  assert.deepEqual(call, bytes(c.frame));
  const k = v.credit;
  assert.deepEqual(frame(16, varint((k.id << 1) | (k.callee ? 1 : 0)), Buffer.from([4]), varint(k.bytes)), bytes(k.frame));
}

// A whole session against a live relay is tests/end_to_end.py's business.
console.log("ok");
