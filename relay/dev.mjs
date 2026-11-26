// Runs the relay under workerd on this machine: node dev.mjs [port] [address]
import { Miniflare } from "miniflare";
import { readFileSync } from "node:fs";
import { randomBytes } from "node:crypto";

const at = (name) => new URL(`src/${name}`, import.meta.url);
const text = (name) => readFileSync(at(name), "utf8");
const secret = process.env.RELAY_SECRET ?? randomBytes(32).toString("hex");

const mf = new Miniflare({
  port: Number(process.argv[2] ?? 0),
  host: process.argv[3] ?? "127.0.0.1",
  modules: [
    { type: "ESModule", path: "worker.js", contents: text("worker.js") },
    { type: "ESModule", path: "index.js", contents: text("index.js") },
    { type: "ESModule", path: "storage.js", contents: text("storage.js") },
    { type: "ESModule", path: "public.js", contents: text("public.js") },
    { type: "CompiledWasm", path: "relay.wasm", contents: readFileSync(at("relay.wasm")) },
  ],
  compatibilityDate: "2026-01-01",
  bindings: {
    RELAY_SECRET: secret,
    ...(process.env.ACCESS_TOKEN && { ACCESS_TOKEN: process.env.ACCESS_TOKEN }),
    ...(process.env.STORAGE_LIMIT && { STORAGE_LIMIT: process.env.STORAGE_LIMIT }),
    ...(process.env.FULL_WAIT && { FULL_WAIT: process.env.FULL_WAIT }),
    ...(process.env.CACHE_BYTES && { CACHE_BYTES: process.env.CACHE_BYTES }),
    ...(process.env.PAGES_KEPT && { PAGES_KEPT: process.env.PAGES_KEPT }),
    ...(process.env.BLOCKS_KEPT && { BLOCKS_KEPT: process.env.BLOCKS_KEPT }),
    ...(process.env.QUIET_TAIL && { QUIET_TAIL: process.env.QUIET_TAIL }),
    ...(process.env.QUIET_MS && { QUIET_MS: process.env.QUIET_MS }),
    ...(process.env.EXPOSE_DOMAIN && { EXPOSE_DOMAIN: process.env.EXPOSE_DOMAIN }),
    STATS: "1",
  },
  // A bucket for what the objects' own storage does not keep, unless NO_R2 says to see what happens without one.
  ...(!process.env.NO_R2 && { r2Buckets: ["STORE"], r2Persist: process.env.PERSIST ?? false }),
  durableObjects: { SPACE: { className: "Space", useSQLite: true }, LABEL: { className: "Label", useSQLite: true } },
  durableObjectsPersist: process.env.PERSIST ?? false,
});
const url = await mf.ready;
const key = (await (await fetch(url)).text()).trim();
console.log(`${key} listening on ws://${url.host}`);
process.on("SIGTERM", async () => { await mf.dispose(); process.exit(0); });
