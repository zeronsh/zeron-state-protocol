// Where a device keeps what it holds: a directory of files that are read and written synchronously, as the node
// needs, though they may only be opened, made and removed in their own time, as a browser's are.

/** A file open for reading and writing. Every call is synchronous; failures throw. */
export interface File {
  /** Reads into `into` from `at`; returns how many bytes there were. */
  read(into: Uint8Array, at: number): number;
  write(bytes: Uint8Array, at: number): number;
  size(): number;
  truncate(size: number): void;
  /** Makes everything written so far durable. */
  flush(): void;
  close(): void;
}

/** A directory of files. */
export interface Volume {
  /** The names of the files there. */
  list(): Promise<string[]>;
  open(name: string, create: boolean): Promise<File | undefined>;
  /** The same, at once, where the platform can; a browser cannot. */
  openNow?(name: string, create: boolean): File | undefined;
  remove(name: string): Promise<void>;
  /** Lets go of the directory, its files being closed already. */
  close?(): void;
}

/**
 * Files in memory, which are gone when the process is. `crash()` forgets everything not flushed, as a machine
 * that loses power does, and `slow` makes opening take until `settle()`, as it does in a browser.
 */
export class MemoryVolume implements Volume {
  #files = new Map<string, MemoryFile>();
  #waiting: (() => void)[] = [];
  slow = false;

  constructor({ slow = false } = {}) {
    this.slow = slow;
    if (!slow) this.openNow = (name, create) => this.#open(name, create);
  }

  openNow?: (name: string, create: boolean) => File | undefined;

  async list(): Promise<string[]> {
    return [...this.#files.keys()];
  }

  async open(name: string, create: boolean): Promise<File | undefined> {
    if (this.slow) await new Promise<void>((done) => this.#waiting.push(done));
    return this.#open(name, create);
  }

  #open(name: string, create: boolean): File | undefined {
    let f = this.#files.get(name);
    if (!f && create) this.#files.set(name, (f = new MemoryFile()));
    return f && new MemoryHandle(f);
  }

  async remove(name: string): Promise<void> {
    if (this.slow) await new Promise<void>((done) => this.#waiting.push(done));
    this.#files.delete(name);
  }

  /** Lets whatever is waiting to be opened or removed be. */
  settle(): void {
    for (const done of this.#waiting.splice(0)) done();
  }

  /** Forgets what was never flushed. Files made and not flushed are kept, empty, as a directory may keep them. */
  crash(): void {
    for (const f of this.#files.values()) f.bytes = f.durable.slice(), (f.size = f.durable.length);
  }
}

class MemoryFile {
  bytes = new Uint8Array(0);
  size = 0;
  durable = new Uint8Array(0);
}

class MemoryHandle implements File {
  #f: MemoryFile;
  #open = true;

  constructor(f: MemoryFile) {
    this.#f = f;
  }

  #check(): MemoryFile {
    if (!this.#open) throw new Error("the file is closed");
    return this.#f;
  }

  read(into: Uint8Array, at: number): number {
    const f = this.#check();
    const n = Math.max(0, Math.min(into.length, f.size - at));
    into.set(f.bytes.subarray(at, at + n));
    return n;
  }

  write(bytes: Uint8Array, at: number): number {
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
    return bytes.length;
  }

  size(): number {
    return this.#check().size;
  }

  truncate(size: number): void {
    const f = this.#check();
    if (size > f.size) this.write(new Uint8Array(size - f.size), f.size);
    f.size = size;
  }

  flush(): void {
    const f = this.#check();
    f.durable = f.bytes.slice(0, f.size);
  }

  close(): void {
    this.#open = false;
  }
}
