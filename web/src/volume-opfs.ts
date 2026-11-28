// A directory of the origin private file system, for a browser's dedicated worker: the only place a page may read and
// write files synchronously, through handles each of which holds its file for itself until closed.

import { StoreLocked, type File, type Volume } from "./volume.ts";

// Not yet in every library of DOM types.
interface SyncHandle {
  read(into: Uint8Array, options: { at: number }): number;
  write(bytes: Uint8Array, options: { at: number }): number;
  getSize(): number;
  truncate(size: number): void;
  flush(): void;
  close(): void;
}

/**
 * How long a file held by something else is waited for, in ms, before the store is said to be locked. Chromium lets go of
 * the store's Web Lock as soon as the worker that held it is gone, which may be before it has let go of that worker's files:
 * so a worker that has just been given the lock may find a file held still, for as long as that takes. Measured in Chrome
 * 151, it took no time at all, after a worker was stopped, mid-task or not, a tab closed, reloaded, frozen or put in the
 * back/forward cache, or its renderer crashed (which lets go of the lock half a second later); and it has been seen to
 * take more than a second, and to be for ever, until the browser was restarted. Twice that second, and then it is said.
 */
export const HELD_WITHIN = 2000;
const LONGEST_WAIT = 250; // between tries, which begin a millisecond apart, and twice that each time

// What Chromium says when another holds the file: NoModificationAllowedError, as the File System standard has it, and
// InvalidStateError, as Chromium did before it.
const HELD = new Set(["NoModificationAllowedError", "InvalidStateError"]);

/**
 * Does something to a file, waiting for whatever holds it to let go: tried again a millisecond later, then two, then four,
 * and so on, until `within` is up and it is said that the store is locked. `wait` waits so long, or, should the volume be
 * let go of meanwhile, says it did not, and nothing more is tried. `within` is counted from when this file was first found
 * held, this time, and from nothing before: once had, it was let go of, and whatever is found held after, however soon, is
 * waited for as long again.
 */
export async function take<H>(name: string, open: () => Promise<H>, wait: (ms: number) => Promise<boolean>, within = HELD_WITHIN): Promise<H> {
  let since: number | undefined; // when it was first found held
  for (let delay = 1; ; delay = Math.min(delay * 2, LONGEST_WAIT)) {
    try {
      return await open();
    } catch (e) {
      if (!HELD.has((e as { name?: unknown } | null)?.name as string)) throw e;
      const now = performance.now();
      const until = (since ??= now) + within;
      if (now >= until) {
        throw new StoreLocked(`the store's file ${name} is held by something else, and was not let go of in ${within / 1000} s: another tab of this site may hold it, or the browser, until it is restarted`, { cause: e });
      }
      if (!(await wait(Math.min(delay, until - now)))) throw e;
    }
  }
}

/**
 * A store's path in the origin's file system, under zsp/, as its name gives it: what its directory, its lock and its
 * channel are all named by, so that "app", "app/", "/app" and "app//" are one store, one lock. A name of no parts, or of
 * "." or "..", names none; nor does one with a backslash, which the File System standard allows in no name.
 */
export function storePath(name: string): string {
  const parts = name.split("/").filter(Boolean);
  if (parts.length === 0 || parts.some((p) => p === "." || p === ".." || p.includes("\\"))) throw new RangeError(`no store is named ${JSON.stringify(name)}`);
  return parts.join("/");
}

export class OpfsVolume implements Volume {
  #dir: FileSystemDirectoryHandle;
  #closed = false;
  #waits = new Set<{ timer: ReturnType<typeof setTimeout>; done: (waited: boolean) => void }>(); // for a file held by another
  #files = new Set<OpfsFile>(); // open
  /** How many things have been done to its files, tries included: that whoever uses it is getting on, not stuck. */
  steps = 0;

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
    this.steps++;
    return names;
  }

  async open(name: string, create: boolean): Promise<File | undefined> {
    let handle: FileSystemFileHandle;
    try {
      handle = await this.#step(this.#dir.getFileHandle(name, { create }));
    } catch (e) {
      if ((e as DOMException).name === "NotFoundError") return undefined;
      throw e;
    }
    const file = handle as unknown as { createSyncAccessHandle(): Promise<SyncHandle> };
    const h = await take(name, () => this.#step(file.createSyncAccessHandle()), (ms) => this.#wait(ms));
    if (this.#closed) {
      h.close(); // let go of as it was had: closed with the rest
      throw new Error("the store was let go of as its file " + name + " was opened");
    }
    const f = new OpfsFile(h, () => this.#files.delete(f));
    this.#files.add(f);
    return f;
  }

  // Counts what is done, as it is done, however it went.
  #step<T>(p: Promise<T>): Promise<T> {
    return p.finally(() => void this.steps++);
  }

  #wait(ms: number): Promise<boolean> {
    if (this.#closed) return Promise.resolve(false);
    return new Promise((done) => {
      const w = { timer: setTimeout(() => (this.#waits.delete(w), done(true)), ms), done };
      this.#waits.add(w);
    });
  }

  /**
   * Lets go of the directory: whatever is being opened gives up waiting for its file, and is closed as it comes; and any file
   * still open is closed, as when it is let go of as it is opened, its files not yet the store's to close.
   */
  close(): void {
    this.#closed = true;
    for (const w of this.#waits) clearTimeout(w.timer), w.done(false);
    this.#waits.clear();
    for (const f of [...this.#files]) {
      try {
        f.close();
      } catch {
        // nothing more can be done with it
      }
    }
  }

  // Removed as a file is opened, waiting for whatever holds it, which a file with a handle open cannot be.
  async remove(name: string): Promise<void> {
    try {
      await take(name, () => this.#step(this.#dir.removeEntry(name)), (ms) => this.#wait(ms));
    } catch (e) {
      if ((e as DOMException).name !== "NotFoundError") throw e;
    }
  }
}

class OpfsFile implements File {
  #h: SyncHandle;
  #closed: () => void;

  constructor(h: SyncHandle, closed: () => void) {
    this.#h = h;
    this.#closed = closed;
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
    this.#closed();
    this.#h.close();
  }
}
