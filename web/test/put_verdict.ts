// A put whose file changed as it went is not taken for a success, whatever the other end says of it after.

import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NodeFolder } from "../src/folder-node.ts";
import type { Folder, OpenFile } from "../src/folder.ts";
import { put, ServiceError } from "../src/services.ts";

const base = mkdtempSync(join(tmpdir(), "zsp-verdict-"));
try {
  writeFileSync(join(base, "f.bin"), new Uint8Array(100_000));
  const real = new NodeFolder(base);
  // Its file is another by the time all of it has gone.
  const folder: Folder = Object.create(real);
  folder.open = async (path: string, write: boolean) => {
    const f = (await real.open(path, write)) as OpenFile;
    let asked = 0;
    const info = f.info.bind(f);
    f.info = async () => {
      const i = await info();
      return asked++ === 0 ? i : { ...i, identity: new Uint8Array([9, 9, 9]) };
    };
    return f;
  };
  // A device that says Ok to everything.
  const client = {
    call() {
      const call: Record<string, unknown> = {
        ondata: undefined, onend: undefined, onfault: undefined, onroom: undefined, room: 1 << 20,
        send(m: Uint8Array) {
          if (m[0] === 3) queueMicrotask(() => {
            (call.ondata as (m: Uint8Array) => void)(new Uint8Array([0]));
            (call.onend as () => void)();
          });
          return true;
        },
        finish() {}, cancel() {}, consumed() {},
      };
      queueMicrotask(() => (call.ondata as (m: Uint8Array) => void)(new Uint8Array([0, 0])));
      return call;
    },
  };
  let status = "ok";
  try {
    await put(client as never, "peer", 1, "f.bin", "docs/f.bin", { folder });
  } catch (e) {
    assert.ok(e instanceof ServiceError, String(e));
    status = e.status;
  }
  assert.equal(status, "changed", "a file that changed as it went was taken");
} finally {
  rmSync(base, { recursive: true, force: true });
}
console.log("a put that changed as it went is said to have changed, whatever the other end says");
