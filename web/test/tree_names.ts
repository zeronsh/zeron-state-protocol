// A device that lists a folder with names leading out of it, as one that means harm may, has nothing written anywhere
// but within the folder asked for: getTree takes no such name. Played by a client of this test's own.

import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { NodeFolder } from "../src/folder-node.ts";
import { chunkMessage, endMessage, getTree, ServiceError } from "../src/services.ts";

const sha256 = (b: Uint8Array) => new Uint8Array(createHash("sha256").update(b).digest());
const payload = new TextEncoder().encode("PWNED\n");
const chunk = sha256(payload);
const whole = sha256(chunk);

// A client whose every listing says `name`, and whose every file is `payload`.
function lying(name: string) {
  return {
    call(_device: string, _scope: number, method: string) {
      const call: Record<string, unknown> = {
        ondata: undefined, onend: undefined, onfault: undefined, onroom: undefined,
        send: () => true, room: 1 << 20, finish() {}, cancel() {}, consumed() {},
      };
      queueMicrotask(() => {
        const ondata = call.ondata as ((m: Uint8Array) => void) | undefined;
        const onend = call.onend as (() => void) | undefined;
        if (method === "zsp.list") {
          const n = new TextEncoder().encode(name);
          ondata?.(new Uint8Array([0]));
          ondata?.(new Uint8Array([1, n.length, ...n, payload.length, 0]));
          onend?.();
        } else if (method === "zsp.get") {
          ondata?.(new Uint8Array([0, payload.length, 0, 1, 1, 0]));
          ondata?.(new Uint8Array([1, ...payload]));
          ondata?.(chunkMessage(chunk));
          ondata?.(endMessage("ok", whole));
          onend?.();
        }
      });
      return call;
    },
  };
}

for (const name of ["../../escaped.txt", "..", "a/../../escaped.txt", "/tmp/escaped.txt", "a\\..\\..\\escaped.txt", "c:escaped.txt", ""]) {
  const base = mkdtempSync(join(tmpdir(), "zsp-tree-"));
  try {
    let refused = false;
    try {
      await getTree(lying(name) as never, "peer", 1, "share", "work/downloads", { folder: new NodeFolder(base) });
    } catch (e) {
      refused = e instanceof ServiceError && e.status === "malformed";
      if (!refused) throw e;
    }
    assert.ok(refused, `${JSON.stringify(name)} was taken`);
    assert.ok(!existsSync(join(base, "escaped.txt")) && !existsSync(join(base, "work", "escaped.txt")), `${JSON.stringify(name)} led out`);
  } finally {
    rmSync(base, { recursive: true, force: true });
  }
}
console.log("no name a folder is listed with leads out of it");
