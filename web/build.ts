// Builds what a browser loads: dist/zsp.js, the worker it starts, and the node, side by side, as each finds the next by
// its own URL. `node build.ts [--test]`: with --test, the browser tests too, unminified.

import { build } from "esbuild";
import { copyFileSync, mkdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { gzipSync } from "node:zlib";

const here = fileURLToPath(new URL(".", import.meta.url));
const test = process.argv.includes("--test");
mkdirSync(join(here, "dist"), { recursive: true });

await build({
  absWorkingDir: here,
  entryPoints: { zsp: "src/browser.ts", worker: "src/worker.ts", ...(test ? { test: "test/browser.ts" } : {}) },
  outdir: "dist",
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  minify: !test,
  sourcemap: test ? "inline" : false,
  external: ["node:*"],
  logLevel: "warning",
});
copyFileSync(join(here, "src", "node.wasm"), join(here, "dist", "node.wasm"));

if (!test) {
  for (const name of ["zsp.js", "worker.js", "node.wasm"]) {
    const bytes = readFileSync(join(here, "dist", name));
    console.log(`${name.padEnd(10)} ${(statSync(join(here, "dist", name)).size / 1024).toFixed(0).padStart(5)} KB, ${(gzipSync(bytes, { level: 9 }).length / 1024).toFixed(0).padStart(4)} KB gzipped`);
  }
}
