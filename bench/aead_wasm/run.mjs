// Builds aead.odin for js_wasm32, as the relay is built (with simd128 too, given "simd"), checks zsp's AEAD against
// core's inside it, and times both: node bench/aead_wasm/run.mjs [simd]
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const simd = process.argv.includes("simd");
const out = fileURLToPath(new URL("../../build/aead.wasm", import.meta.url));
execFileSync("odin", ["build", fileURLToPath(new URL(".", import.meta.url)), "-target:js_wasm32", "-o:speed", "-no-entry-point", `-out:${out}`, "-vet", "-strict-style",
  ...(simd ? ["-target-features:simd128"] : []), "-extra-linker-flags:--strip-all -z stack-size=262144 --stack-first"], { stdio: "inherit" });
let memory;
const view = (p, n) => new Uint8Array(memory.buffer, p, n);
const { instance } = await WebAssembly.instantiate(readFileSync(out), {
  odin_env: new Proxy({ rand_bytes: (p, n) => crypto.getRandomValues(view(p, n)), write: () => {}, time_now: () => 0n, tick_now: () => performance.now() }, { get: (t, k) => t[k] ?? (() => 0) }),
});
memory = instance.exports.memory;
const x = instance.exports;
const ok = x.check(BigInt(Date.now()), 4000);
console.log(`zsp as core in wasm${simd ? " with simd128" : ""}: ${ok ? "same" : "DIFFERENT"}`);
if (!ok) process.exit(1);
if (process.argv.includes("check")) process.exit(0);
for (const n of [1452, 8192, 61440]) {
  const row = [];
  for (const f of ["seal_core", "seal_zsp"]) {
    const times = Math.ceil(64e6 / n);
    x[f](n, 100);
    let best = Infinity;
    for (let r = 0; r < 5; r++) {
      const t = performance.now();
      x[f](n, times);
      best = Math.min(best, (performance.now() - t) * 1e6 / (times * n));
    }
    row.push(`${f} ${best.toFixed(2)} ns/byte`);
  }
  console.log(`  ${n}: ${row.join(", ")}`);
}
