// A folder on a disk, for Node: paths are the system's own, or relative to the folder's root, `/` serving between names
// on every system.

import { constants, type BigIntStats } from "node:fs";
import { mkdir, open, readdir, rename, rm, stat, utimes, type FileHandle } from "node:fs/promises";
import { resolve } from "node:path";
import { identityOf, type FileInfo, type Folder, type FolderEntry, type OpenFile } from "./folder.ts";

const kindOf = (s: { isFile(): boolean; isDirectory(): boolean }): FileInfo["kind"] => (s.isFile() ? "file" : s.isDirectory() ? "folder" : "other");

// When a file was written, in whole ms. A time is set here in seconds, as a double, which falls short of the ms it was set to
// by less than a µs: so what falls so little short is that ms, and not the one before.
const msOf = (s: BigIntStats): number => Number((s.mtimeNs + 1000n) / 1_000_000n);

// Its size, its time, and which it is on its disk: as host/files.odin says a file is the one it was.
function infoOf(s: BigIntStats): FileInfo {
  return {
    kind: kindOf(s),
    size: Number(s.size),
    modified: msOf(s),
    identity: identityOf(s.size, s.mtimeNs, s.ino & 0xffffffffffffffffn, s.ino >> 64n, s.dev),
  };
}

const missing = (e: unknown) => (e as NodeJS.ErrnoException).code === "ENOENT";

export class NodeFolder implements Folder {
  readonly root: string;

  /** Paths are taken from `root`, the working directory unless said; an absolute one is where it says. */
  constructor(root = ".") {
    this.root = resolve(root);
  }

  #path(path: string): string {
    return resolve(this.root, path);
  }

  async info(path: string): Promise<FileInfo | undefined> {
    try {
      return infoOf(await stat(this.#path(path), { bigint: true }));
    } catch (e) {
      if (missing(e)) return undefined;
      throw e;
    }
  }

  async open(path: string, write: boolean): Promise<OpenFile | undefined> {
    try {
      // Not "a+": positional writes to a file opened for appending append, on Linux.
      return new NodeOpenFile(await open(this.#path(path), write ? constants.O_RDWR | constants.O_CREAT : constants.O_RDONLY, 0o600));
    } catch (e) {
      if (missing(e) && !write) return undefined;
      throw e;
    }
  }

  async list(path: string): Promise<FolderEntry[]> {
    const dir = this.#path(path);
    const out: FolderEntry[] = [];
    for (const d of await readdir(dir, { withFileTypes: true })) {
      try {
        const s = await stat(resolve(dir, d.name), { bigint: true });
        out.push({ name: d.name, kind: kindOf(s), size: Number(s.size), modified: msOf(s) });
      } catch (e) {
        if (!missing(e)) out.push({ name: d.name, kind: "other", size: 0, modified: 0 }); // a link to nothing, or gone since
      }
    }
    return out;
  }

  async make(path: string): Promise<void> {
    await mkdir(this.#path(path), { recursive: true });
  }

  async rename(from: string, to: string): Promise<void> {
    await rename(this.#path(from), this.#path(to));
  }

  async remove(path: string): Promise<void> {
    await rm(this.#path(path), { force: true });
  }

  async setModified(path: string, ms: number): Promise<void> {
    const t = new Date(ms);
    await utimes(this.#path(path), t, t);
  }
}

class NodeOpenFile implements OpenFile {
  #fh: FileHandle;

  constructor(fh: FileHandle) {
    this.#fh = fh;
  }

  async read(into: Uint8Array, at: number): Promise<number> {
    let got = 0;
    while (got < into.length) {
      const { bytesRead } = await this.#fh.read(into, got, into.length - got, at + got);
      if (bytesRead === 0) break;
      got += bytesRead;
    }
    return got;
  }

  async write(bytes: Uint8Array, at: number): Promise<void> {
    let put = 0;
    while (put < bytes.length) put += (await this.#fh.write(bytes, put, bytes.length - put, at + put)).bytesWritten;
  }

  async truncate(size: number): Promise<void> {
    await this.#fh.truncate(size);
  }

  async info(): Promise<FileInfo> {
    return infoOf(await this.#fh.stat({ bigint: true }));
  }

  async flush(): Promise<void> {
    await this.#fh.sync();
  }

  async close(): Promise<void> {
    await this.#fh.close();
  }
}
