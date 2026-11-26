// Where files fetched from devices are kept, and files sent to them are found: a folder of files and folders, by paths
// with `/` between, read and written in their own time, as a browser's page may only. A file being fetched is kept beside
// where it is going until it is whole, as host/transfer.odin keeps one: `<name>.zsp-part`, with what is known of it in
// `<name>.zsp-part.meta`.

/** What is at a path. */
export interface FileInfo {
  readonly kind: "file" | "folder" | "other";
  readonly size: number;
  /** When it was last written, in ms since 1970. */
  readonly modified: number;
  /** What says a file is the one it was, as nothing else is: its size, its time, and which it is on its disk, as far as can be told. */
  readonly identity: Uint8Array;
}

/** What a folder holds, by name. */
export interface FolderEntry {
  readonly name: string;
  readonly kind: "file" | "folder" | "other";
  readonly size: number;
  readonly modified: number;
}

/** A file open for reading, or for reading and writing. */
export interface OpenFile {
  /** Reads into `into` from `at`; resolves to how many bytes there were. */
  read(into: Uint8Array, at: number): Promise<number>;
  write(bytes: Uint8Array, at: number): Promise<void>;
  truncate(size: number): Promise<void>;
  /** What it is now: what was written and not yet flushed, if the platform cannot tell, not counted. */
  info(): Promise<FileInfo>;
  /** Makes everything written so far durable. */
  flush(): Promise<void>;
  close(): Promise<void>;
}

/** A folder, whose paths are names with `/` between. */
export interface Folder {
  /** What is there, or undefined if nothing is. */
  info(path: string): Promise<FileInfo | undefined>;
  /** A file, to read; or to write too, made if there is none. Undefined if there is none to read. */
  open(path: string, write: boolean): Promise<OpenFile | undefined>;
  list(path: string): Promise<FolderEntry[]>;
  /** Makes a folder, and those on the way to it. */
  make(path: string): Promise<void>;
  /** Puts a file where another is, whole: whatever was there is replaced. */
  rename(from: string, to: string): Promise<void>;
  /** Removes a file, if it is there. */
  remove(path: string): Promise<void>;
  /** Says when a file was written, where the platform lets that be said. */
  setModified(path: string, ms: number): Promise<void>;
}

// A path's names, without empty ones or ".".
export function names(path: string): string[] {
  return path.split("/").filter((n) => n !== "" && n !== ".");
}

// Varints of an identity: as many as there are numbers, each unsigned LEB128, however large.
export function identityOf(...numbers: (number | bigint)[]): Uint8Array {
  const out: number[] = [];
  for (const n of numbers) {
    let v = BigInt(n);
    while (v >= 0x80n) {
      out.push(Number(v & 0x7fn) | 0x80);
      v >>= 7n;
    }
    out.push(Number(v));
  }
  return Uint8Array.from(out);
}

/** Files in memory, gone when the process is: for tests, and for what is fetched only to be looked at. */
export class MemoryFolder implements Folder {
  #files = new Map<string, MemoryFile>();
  #folders = new Set<string>([""]);
  #made = 0;

  #key(path: string): string {
    return names(path).join("/");
  }

  #parent(key: string): string {
    const slash = key.lastIndexOf("/");
    return slash < 0 ? "" : key.slice(0, slash);
  }

  async info(path: string): Promise<FileInfo | undefined> {
    const key = this.#key(path);
    const f = this.#files.get(key);
    if (f) return f.info();
    if (this.#folders.has(key)) return { kind: "folder", size: 0, modified: 0, identity: new Uint8Array() };
    return undefined;
  }

  async open(path: string, write: boolean): Promise<OpenFile | undefined> {
    const key = this.#key(path);
    let f = this.#files.get(key);
    if (!f) {
      if (!write) return undefined;
      if (!this.#folders.has(this.#parent(key)) || this.#folders.has(key)) throw new Error(`cannot make ${path}`);
      this.#files.set(key, (f = new MemoryFile(++this.#made)));
    }
    return new MemoryHandle(f);
  }

  async list(path: string): Promise<FolderEntry[]> {
    const key = this.#key(path);
    if (!this.#folders.has(key)) throw new Error(`no folder ${path}`);
    const out: FolderEntry[] = [];
    for (const k of this.#folders) {
      if (k !== "" && this.#parent(k) === key) out.push({ name: k.slice(k.lastIndexOf("/") + 1), kind: "folder", size: 0, modified: 0 });
    }
    for (const [k, f] of this.#files) {
      if (this.#parent(k) === key) out.push({ name: k.slice(k.lastIndexOf("/") + 1), kind: "file", size: f.size, modified: f.modified });
    }
    return out;
  }

  async make(path: string): Promise<void> {
    let key = "";
    for (const name of names(path)) {
      key = key === "" ? name : key + "/" + name;
      if (this.#files.has(key)) throw new Error(`${key} is a file`);
      this.#folders.add(key);
    }
  }

  async rename(from: string, to: string): Promise<void> {
    const f = this.#files.get(this.#key(from));
    const key = this.#key(to);
    if (!f || !this.#folders.has(this.#parent(key)) || this.#folders.has(key)) throw new Error(`cannot put ${from} at ${to}`);
    this.#files.delete(this.#key(from));
    this.#files.set(key, f);
  }

  async remove(path: string): Promise<void> {
    this.#files.delete(this.#key(path));
  }

  async setModified(path: string, ms: number): Promise<void> {
    const f = this.#files.get(this.#key(path));
    if (f) f.modified = ms;
  }
}

class MemoryFile {
  bytes = new Uint8Array(0);
  size = 0;
  modified = Date.now();
  readonly serial: number;

  constructor(serial: number) {
    this.serial = serial;
  }

  info(): FileInfo {
    return { kind: "file", size: this.size, modified: this.modified, identity: identityOf(this.size, this.modified, this.serial) };
  }
}

class MemoryHandle implements OpenFile {
  #f: MemoryFile;
  #open = true;

  constructor(f: MemoryFile) {
    this.#f = f;
  }

  #check(): MemoryFile {
    if (!this.#open) throw new Error("the file is closed");
    return this.#f;
  }

  async read(into: Uint8Array, at: number): Promise<number> {
    const f = this.#check();
    const n = Math.max(0, Math.min(into.length, f.size - at));
    into.set(f.bytes.subarray(at, at + n));
    return n;
  }

  async write(bytes: Uint8Array, at: number): Promise<void> {
    const f = this.#check();
    const end = at + bytes.length;
    if (end > f.bytes.length) {
      const grown = new Uint8Array(Math.max(end, f.bytes.length * 2));
      grown.set(f.bytes.subarray(0, f.size));
      f.bytes = grown;
    }
    if (at > f.size) f.bytes.fill(0, f.size, at);
    f.bytes.set(bytes, at);
    f.size = Math.max(f.size, end);
    f.modified = Date.now();
  }

  async truncate(size: number): Promise<void> {
    const f = this.#check();
    if (size > f.size) await this.write(new Uint8Array(size - f.size), f.size);
    f.size = size;
    f.modified = Date.now();
  }

  async info(): Promise<FileInfo> {
    return this.#check().info();
  }

  async flush(): Promise<void> {
    this.#check();
  }

  async close(): Promise<void> {
    this.#open = false;
  }
}
