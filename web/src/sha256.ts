// FIPS 180-4, for naming lists, synchronously: WebCrypto would make every list name wait. Nothing secret passes through
// here twice.

// The first 32 bits of the fractions of the cube roots of the first 64 primes.
const K = new Int32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
]);

const W = new Int32Array(64);
const H = new Int32Array(8);
const tail = new Uint8Array(128);

// One 64-byte block of data, from `at`, into H.
function block(data: Uint8Array, at: number): void {
  for (let i = 0; i < 16; i++, at += 4) W[i] = (data[at] << 24) | (data[at + 1] << 16) | (data[at + 2] << 8) | data[at + 3];
  for (let i = 16; i < 64; i++) {
    const a = W[i - 15];
    const b = W[i - 2];
    const s0 = ((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3);
    const s1 = ((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10);
    W[i] = (W[i - 16] + s0 + W[i - 7] + s1) | 0;
  }
  let a = H[0], b = H[1], c = H[2], d = H[3], e = H[4], f = H[5], g = H[6], h = H[7];
  for (let i = 0; i < 64; i++) {
    const t1 = (h + (((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))) + ((e & f) ^ (~e & g)) + K[i] + W[i]) | 0;
    const t2 = ((((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
    h = g;
    g = f;
    f = e;
    e = (d + t1) | 0;
    d = c;
    c = b;
    b = a;
    a = (t1 + t2) | 0;
  }
  H[0] += a;
  H[1] += b;
  H[2] += c;
  H[3] += d;
  H[4] += e;
  H[5] += f;
  H[6] += g;
  H[7] += h;
}

export function sha256(data: Uint8Array): Uint8Array {
  H[0] = 0x6a09e667;
  H[1] = 0xbb67ae85 | 0;
  H[2] = 0x3c6ef372;
  H[3] = 0xa54ff53a | 0;
  H[4] = 0x510e527f;
  H[5] = 0x9b05688c | 0;
  H[6] = 0x1f83d9ab;
  H[7] = 0x5be0cd19;
  const n = data.length;
  const whole = n - (n % 64);
  for (let at = 0; at < whole; at += 64) block(data, at);
  // What is left, a one bit, zeros, and the length in bits: one block or two.
  const left = n - whole;
  tail.fill(0);
  tail.set(data.subarray(whole), 0);
  tail[left] = 0x80;
  const end = left < 56 ? 64 : 128;
  const hi = Math.floor(n / 0x20000000);
  const lo = (n << 3) >>> 0;
  tail[end - 8] = hi >>> 24;
  tail[end - 7] = hi >>> 16;
  tail[end - 6] = hi >>> 8;
  tail[end - 5] = hi;
  tail[end - 4] = lo >>> 24;
  tail[end - 3] = lo >>> 16;
  tail[end - 2] = lo >>> 8;
  tail[end - 1] = lo;
  block(tail, 0);
  if (end === 128) block(tail, 64);
  const out = new Uint8Array(32);
  for (let i = 0; i < 8; i++) {
    const v = H[i];
    out[i * 4] = v >>> 24;
    out[i * 4 + 1] = v >>> 16;
    out[i * 4 + 2] = v >>> 8;
    out[i * 4 + 3] = v;
  }
  return out;
}
