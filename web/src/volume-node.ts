// A directory on a disk, for Node.

import { closeSync, constants, existsSync, fstatSync, fsyncSync, ftruncateSync, mkdirSync, openSync, readdirSync, readSync, rmSync, writeSync } from "node:fs";
import { join } from "node:path";
import type { File, Volume } from "./volume.ts";

export class NodeVolume implements Volume {
  readonly path: string;

  constructor(path: string) {
    this.path = path;
  }

  async list(): Promise<string[]> {
    try {
      return readdirSync(this.path);
    } catch {
      return [];
    }
  }

  async open(name: string, create: boolean): Promise<File | undefined> {
    return this.openNow(name, create);
  }

  openNow(name: string, create: boolean): File | undefined {
    const path = join(this.path, name);
    const made = create && !existsSync(path);
    if (made) mkdirSync(this.path, { recursive: true, mode: 0o700 });
    let fd: number;
    try {
      // Not "a+": positional writes to a file opened for appending append, on Linux.
      fd = openSync(path, constants.O_RDWR | (create ? constants.O_CREAT : 0), 0o600);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT" && !create) return undefined;
      throw e;
    }
    if (made && process.platform !== "win32") {
      // The name is the directory's to remember.
      const dir = openSync(this.path, "r");
      fsyncSync(dir);
      closeSync(dir);
    }
    return new NodeFile(fd);
  }

  async remove(name: string): Promise<void> {
    rmSync(join(this.path, name), { force: true });
  }
}

class NodeFile implements File {
  #fd: number;

  constructor(fd: number) {
    this.#fd = fd;
  }

  read(into: Uint8Array, at: number): number {
    let got = 0;
    while (got < into.length) {
      const n = readSync(this.#fd, into, got, into.length - got, at + got);
      if (n === 0) break;
      got += n;
    }
    return got;
  }

  write(bytes: Uint8Array, at: number): number {
    let put = 0;
    while (put < bytes.length) put += writeSync(this.#fd, bytes, put, bytes.length - put, at + put);
    return put;
  }

  size(): number {
    return fstatSync(this.#fd).size;
  }

  truncate(size: number): void {
    ftruncateSync(this.#fd, size);
  }

  flush(): void {
    fsyncSync(this.#fd);
  }

  close(): void {
    closeSync(this.#fd);
  }
}
