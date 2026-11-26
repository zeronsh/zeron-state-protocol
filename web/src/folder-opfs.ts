// A folder of the origin private file system, for a page: read through the files it gives, written through writable
// streams, which a page may have where it may not have a worker's synchronous handles. What is written is the file's
// once flushed or closed. A browser keeps no time for a file but when it was last written, and says nothing of which
// file it is, so a file's identity here is its size and that time.

import { identityOf, names, type FileInfo, type Folder, type FolderEntry, type OpenFile } from "./folder.ts";

// Not yet in every library of DOM types.
type Movable = FileSystemFileHandle & { move?(to: FileSystemDirectoryHandle | string, name?: string): Promise<void> };
type Entries = AsyncIterable<[string, FileSystemHandle]>;

const notFound = (e: unknown) => (e as DOMException).name === "NotFoundError" || (e as DOMException).name === "TypeMismatchError";

export class OpfsFolder implements Folder {
  readonly path: string;
  #root?: FileSystemDirectoryHandle;

  /** The folder at a path of the origin's file system, made when first used. */
  constructor(path: string) {
    this.path = path;
  }

  async #top(): Promise<FileSystemDirectoryHandle> {
    if (!this.#root) {
      let dir = await navigator.storage.getDirectory();
      for (const name of names(this.path)) dir = await dir.getDirectoryHandle(name, { create: true });
      this.#root = dir;
    }
    return this.#root;
  }

  // The folder a path is in, and its last name; the folders on the way made if asked.
  async #parent(path: string, make = false): Promise<[FileSystemDirectoryHandle, string]> {
    const parts = names(path);
    const last = parts.pop();
    if (last === undefined) throw new Error("a path names something within the folder");
    let dir = await this.#top();
    for (const name of parts) dir = await dir.getDirectoryHandle(name, { create: make });
    return [dir, last];
  }

  async #folder(path: string, make = false): Promise<FileSystemDirectoryHandle> {
    let dir = await this.#top();
    for (const name of names(path)) dir = await dir.getDirectoryHandle(name, { create: make });
    return dir;
  }

  async #file(path: string, create = false): Promise<FileSystemFileHandle | undefined> {
    try {
      const [dir, name] = await this.#parent(path);
      return await dir.getFileHandle(name, { create });
    } catch (e) {
      if (notFound(e)) return undefined;
      throw e;
    }
  }

  async info(path: string): Promise<FileInfo | undefined> {
    if (names(path).length === 0) return { kind: "folder", size: 0, modified: 0, identity: new Uint8Array() };
    const f = await this.#file(path);
    if (f) return infoOf(await f.getFile());
    try {
      await this.#folder(path);
      return { kind: "folder", size: 0, modified: 0, identity: new Uint8Array() };
    } catch (e) {
      if (notFound(e)) return undefined;
      throw e;
    }
  }

  async open(path: string, write: boolean): Promise<OpenFile | undefined> {
    const f = await this.#file(path, write);
    return f && new OpfsOpenFile(f);
  }

  async list(path: string): Promise<FolderEntry[]> {
    const out: FolderEntry[] = [];
    for await (const [name, handle] of (await this.#folder(path)) as unknown as Entries) {
      if (handle.kind === "file") {
        const file = await (handle as FileSystemFileHandle).getFile();
        out.push({ name, kind: "file", size: file.size, modified: file.lastModified });
      } else out.push({ name, kind: "folder", size: 0, modified: 0 });
    }
    return out;
  }

  async make(path: string): Promise<void> {
    await this.#folder(path, true);
  }

  async rename(from: string, to: string): Promise<void> {
    const f = (await this.#file(from)) as Movable | undefined;
    if (!f) throw new Error(`no file ${from}`);
    const [dir, name] = await this.#parent(to);
    if (f.move) {
      try {
        await f.move(dir, name);
        return;
      } catch (e) {
        // Where a browser will not move a file over another, the other goes first.
        if ((e as DOMException).name !== "InvalidModificationError" && (e as DOMException).name !== "NoModificationAllowedError") throw e;
        await dir.removeEntry(name);
        await f.move(dir, name);
        return;
      }
    }
    // A browser that cannot move one: copied whole, then let go of.
    const into = await (await dir.getFileHandle(name, { create: true })).createWritable({ keepExistingData: false });
    await into.write(await f.getFile());
    await into.close();
    await this.remove(from);
  }

  async remove(path: string): Promise<void> {
    try {
      const [dir, name] = await this.#parent(path);
      await dir.removeEntry(name);
    } catch (e) {
      if (!notFound(e)) throw e;
    }
  }

  /** A browser says when a file was written, and nothing else may: so this says nothing. */
  async setModified(): Promise<void> {}
}

function infoOf(file: File): FileInfo {
  return { kind: "file", size: file.size, modified: file.lastModified, identity: identityOf(file.size, file.lastModified) };
}

class OpfsOpenFile implements OpenFile {
  #handle: FileSystemFileHandle;
  #writing?: FileSystemWritableFileStream;

  constructor(handle: FileSystemFileHandle) {
    this.#handle = handle;
  }

  async #writable(): Promise<FileSystemWritableFileStream> {
    this.#writing ??= await this.#handle.createWritable({ keepExistingData: true });
    return this.#writing;
  }

  async read(into: Uint8Array, at: number): Promise<number> {
    const file = await this.#handle.getFile();
    const got = new Uint8Array(await file.slice(at, at + into.length).arrayBuffer());
    into.set(got);
    return got.length;
  }

  async write(bytes: Uint8Array, at: number): Promise<void> {
    await (await this.#writable()).write({ type: "write", position: at, data: bytes.slice() });
  }

  async truncate(size: number): Promise<void> {
    await (await this.#writable()).truncate(size);
  }

  async info(): Promise<FileInfo> {
    return infoOf(await this.#handle.getFile());
  }

  async flush(): Promise<void> {
    // What a writable stream wrote is the file's when it closes, and not before.
    const w = this.#writing;
    this.#writing = undefined;
    await w?.close();
  }

  async close(): Promise<void> {
    await this.flush();
  }
}
