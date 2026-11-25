// A directory of the origin private file system, for a browser's dedicated worker: the only place a page may read and
// write files synchronously, through handles each of which holds its file for itself until closed.

import type { File, Volume } from "./volume.ts";

// Not yet in every library of DOM types.
interface SyncHandle {
  read(into: Uint8Array, options: { at: number }): number;
  write(bytes: Uint8Array, options: { at: number }): number;
  getSize(): number;
  truncate(size: number): void;
  flush(): void;
  close(): void;
}

export class OpfsVolume implements Volume {
  #dir: FileSystemDirectoryHandle;

  private constructor(dir: FileSystemDirectoryHandle) {
    this.#dir = dir;
  }

  /** The directory at a path of the origin's file system, made if need be. */
  static async at(path: string): Promise<OpfsVolume> {
    let dir = await navigator.storage.getDirectory();
    for (const part of path.split("/").filter(Boolean)) dir = await dir.getDirectoryHandle(part, { create: true });
    return new OpfsVolume(dir);
  }

  async list(): Promise<string[]> {
    const names: string[] = [];
    for await (const [name, handle] of (this.#dir as unknown as AsyncIterable<[string, FileSystemHandle]>)) {
      if (handle.kind === "file") names.push(name);
    }
    return names;
  }

  async open(name: string, create: boolean): Promise<File | undefined> {
    let handle: FileSystemFileHandle;
    try {
      handle = await this.#dir.getFileHandle(name, { create });
    } catch (e) {
      if ((e as DOMException).name === "NotFoundError") return undefined;
      throw e;
    }
    const sync = await (handle as unknown as { createSyncAccessHandle(): Promise<SyncHandle> }).createSyncAccessHandle();
    return new OpfsFile(sync);
  }

  async remove(name: string): Promise<void> {
    try {
      await this.#dir.removeEntry(name);
    } catch (e) {
      if ((e as DOMException).name !== "NotFoundError") throw e;
    }
  }
}

class OpfsFile implements File {
  #h: SyncHandle;

  constructor(h: SyncHandle) {
    this.#h = h;
  }

  read(into: Uint8Array, at: number): number {
    return this.#h.read(into, { at });
  }

  write(bytes: Uint8Array, at: number): number {
    let put = 0;
    while (put < bytes.length) {
      const n = this.#h.write(bytes.subarray(put), { at: at + put });
      if (n <= 0) throw new Error("the file system would take no more");
      put += n;
    }
    return put;
  }

  size(): number {
    return this.#h.getSize();
  }

  truncate(size: number): void {
    this.#h.truncate(size);
  }

  flush(): void {
    this.#h.flush();
  }

  close(): void {
    this.#h.close();
  }
}
