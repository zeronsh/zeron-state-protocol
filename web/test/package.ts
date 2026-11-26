// What `import { open } from "zsp"` gives: in Node, a device in a directory; in a browser, one in the origin's files.

import assert from "node:assert/strict";
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import * as zsp from "zsp";

assert.equal(typeof zsp.open, "function");
assert.equal(typeof zsp.Client, "function");
assert.equal(typeof zsp.mirror.open, "function");
assert.equal(typeof (zsp as { NodeVolume?: unknown }).NodeVolume, "function", "Node has the Node one");

const here = fileURLToPath(new URL("..", import.meta.url));
const bundled = await build({
  absWorkingDir: here,
  stdin: { contents: 'import { open } from "zsp"; globalThis.open = open;', resolveDir: here, loader: "ts" },
  bundle: true,
  write: false,
  platform: "browser",
  format: "esm",
  metafile: true,
  external: ["node:*"],
  logLevel: "silent",
});
const inputs = Object.keys(bundled.metafile!.inputs);
assert(inputs.includes("src/browser.ts"), "a browser has the browser's");
assert(!inputs.includes("src/nodejs.ts"));
console.log("ok");
