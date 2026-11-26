// Where a UTF-16 index of what bytes read as falls in them, held to TextDecoder over random bytes, valid and not.

import assert from "node:assert/strict";
import { utf8Offset } from "../src/codec.ts";

const decoder = new TextDecoder("utf-8", { ignoreBOM: true });
let seed = 7;
const random = () => ((seed = (seed * 1103515245 + 12345) & 0x7fffffff) / 0x80000000);
const pieces = [[0x61], [0xc3, 0xa9], [0xe2, 0x82, 0xac], [0xf0, 0x9f, 0x98, 0x80], [0xef, 0xbb, 0xbf], [0xff], [0xc3], [0xe2, 0x82], [0xf0, 0x9f], [0xed, 0xa0, 0x80], [0x80], [0xf4, 0x90, 0x80, 0x80], [0xc0, 0xaf]];
let checked = 0;
for (let round = 0; round < 3000; round++) {
  const parts: number[] = [];
  for (let n = Math.floor(random() * 12); n > 0; n--) parts.push(...pieces[Math.floor(random() * pieces.length)]);
  if (random() < 0.3) for (let n = Math.floor(random() * 6); n > 0; n--) parts.push(Math.floor(random() * 256));
  const bytes = Uint8Array.from(parts);
  const shown = decoder.decode(bytes);
  for (let k = 0; k <= shown.length; k++) {
    const c = shown.charCodeAt(k - 1);
    if (k > 0 && k < shown.length && c >= 0xd800 && c < 0xdc00) {
      assert.throws(() => utf8Offset(bytes, k), RangeError);
      continue;
    }
    const at = utf8Offset(bytes, k);
    assert.equal(decoder.decode(bytes.subarray(0, at)), shown.slice(0, k), `${Array.from(bytes)} at ${k}`);
    assert.equal(decoder.decode(bytes.subarray(at)), shown.slice(k), `${Array.from(bytes)} from ${k}`);
    checked++;
  }
  assert.throws(() => utf8Offset(bytes, shown.length + 1), RangeError);
}
console.log(`${checked} places in random bytes, each where TextDecoder puts it`);
console.log("ok");
