// A directory on a disk, for Node.

import { closeSync, constants, existsSync, fstatSync, fsyncSync, ftruncateSync, linkSync, mkdirSync, openSync, readdirSync, readSync, realpathSync, rmSync, statfsSync, statSync, writeSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import type { File, Volume } from "./volume.ts";

/**
 * A directory, as a device's store: held by this volume alone, from its first use until it is closed, against every other
 * process and every other volume of this one, as zspd holds its own. Whoever comes second is told the store is in use,
 * and touches nothing. Once closed, it is held again only by a store opening it again, which lists it first: never by
 * what one let go of might yet do, as it would be for good. See holdDirectory.
 */
export class NodeVolume implements Volume {
  readonly path: string;
  #release?: () => void; // while the directory is held
  #closed = false;

  constructor(path: string) {
    this.path = path;
  }

  #hold(opening = false): void {
    if (this.#release) return;
    if (this.#closed && !opening) throw new Error(`the store's directory was let go of: ${this.path}`);
    this.#release = holdDirectory(this.path);
    this.#closed = false;
  }

  async list(): Promise<string[]> {
    this.#hold(true);
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
    this.#hold(); // which makes the directory
    const path = join(this.path, name);
    const made = create && !existsSync(path);
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
    this.#hold();
    rmSync(join(this.path, name), { force: true });
  }

  /** Lets go of the directory, its files being closed already: for this volume to hold again, or another. */
  close(): void {
    const release = this.#release;
    this.#release = undefined;
    this.#closed = true;
    release?.();
  }
}

// A store's directory is one node's at a time, as host/hold.odin says: two writing one log at once each write over what
// the other wrote, and each acknowledges what is lost. So it is held, by a lock on its file "lock" that the kernel lets go
// of when the process ends, however it ends: the lock zspd takes, so that each keeps the other out too. Node has no way
// of its own to take it. On Linux and Windows it is taken through the SQLite Node is built with, which keeps its locks on
// the very bytes zspd locks there: its pending, reserved and shared bytes, at 2^30. Where zspd takes flock's lock, it is
// taken as the file is opened, by O_EXLOCK.
//
// A lock on a file system shared with other machines may not hold, and a store on one is refused, where that can be
// told. Returns what lets go of the directory.
function holdDirectory(dir: string): () => void {
  // Asked of what there is of it, before anything is made there.
  let there = resolve(dir);
  while (!existsSync(there) && dirname(there) !== there) there = dirname(there);
  const kind = shared(there);
  if (kind) throw new Error(`${dir} is on a file system shared with other machines (${kind}), where its lock may not hold: keep the store on a disk of this machine's own`);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const path = join(dir, "lock");
  const inUse = () => new Error(`this store is in use by another process: ${dir}`);
  if (FLOCK.has(process.platform)) {
    const O_EXLOCK = 0x20; // as Darwin and the BSDs have it, and Node does not name it
    let fd: number;
    try {
      fd = openSync(path, constants.O_RDWR | constants.O_CREAT | constants.O_NONBLOCK | constants.O_NOFOLLOW | O_EXLOCK, 0o600);
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      if (code === "EAGAIN" || code === "EWOULDBLOCK") throw inUse();
      throw e;
    }
    return () => closeSync(fd);
  }
  if (process.platform !== "win32") ownLockFile(path);
  const { DatabaseSync } = process.getBuiltinModule("node:sqlite") as typeof import("node:sqlite");
  const db = new DatabaseSync(path, { timeout: 0 });
  try {
    // Its shared lock and its reserved one, which only one holds at a time, by a write begun and never ended: which
    // writes nothing, nor any journal, kept in memory.
    db.exec("PRAGMA journal_mode = MEMORY; BEGIN IMMEDIATE");
  } catch (e) {
    db.close();
    const code = (e as { errcode?: number }).errcode ?? 0;
    if ((code & 0xff) === 5 || (code & 0xff) === 6) throw inUse(); // SQLITE_BUSY, by another; SQLITE_LOCKED, by this one
    throw e;
  }
  return () => db.close();
}

const FLOCK = new Set(["darwin", "freebsd", "openbsd"]);

// Makes the lock file readable and writable by this user alone, as zspd makes it, before SQLite makes it as it makes a
// database, readable by everyone: anyone who can read it can hold it, and so keep every node from the store. It is made
// aside and linked into place, never opened where it is: a file of this process's on it, closed, would let go of every
// lock this process holds there, SQLite's among them, as a process's own locks are let go of.
function ownLockFile(path: string): void {
  if (existsSync(path)) return;
  // Named as a save's staging file is (host/staging.odin), which zspd removes should one be left behind: drawn to be
  // another's than any other's, and made only if it is, but kept from nobody, so drawn as cheaply as can be.
  let aside: string;
  for (;;) {
    aside = `${path}.${Array.from({ length: 4 }, () => ((Math.random() * 2 ** 32) >>> 0).toString(16).padStart(8, "0")).join("")}.new`;
    try {
      closeSync(openSync(aside, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600));
      break;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    }
  }
  try {
    linkSync(aside, path);
  } catch (e) {
    // There already, made by another meanwhile; or on a file system with no links, nor modes to keep anyone out.
    const code = (e as NodeJS.ErrnoException).code;
    if (code !== "EEXIST" && code !== "EPERM" && code !== "ENOTSUP" && code !== "EOPNOTSUPP" && code !== "ENOENT") throw e;
  } finally {
    rmSync(aside, { force: true });
  }
}

// The kind of file system shared with other machines a directory is on, if it is on one, as host/ finds it.
function shared(dir: string): string | undefined {
  if (process.platform === "win32") {
    // The path the system has for it, through every link and mapped drive, is a share's for one of another machine's,
    // \\server\share\...; \\?\ and \\.\ are this machine's.
    return /^\\\\(?![?.]\\)/.test(realpathSync.native(dir)) ? "a network share" : undefined;
  }
  if (FLOCK.has(process.platform)) return notLocal(dir);
  return REMOTE_MAGIC.get(Number(BigInt.asUintN(32, statfsSync(dir, { bigint: true }).type)));
}

// The statfs magic numbers of file systems shared with other machines, as host/hold_linux.odin has them. FUSE's are not
// among them: what a FUSE file system is, only its daemon knows.
const REMOTE_MAGIC = new Map<number, string>([
  [0x6969, "nfs"],
  [0x517b, "smb"],
  [0xff534d42, "cifs"],
  [0xfe534d42, "smb2"],
  [0x5346414f, "afs"],
  [0x6b414653, "afs"],
  [0x73757245, "coda"],
  [0x564c, "ncp"],
  [0x01021997, "9p"],
  [0x00c36400, "ceph"],
  [0x0bd00bd0, "lustre"],
  [0x47504653, "gpfs"],
  [0x01161970, "gfs2"],
  [0x7461636f, "ocfs2"],
  [0xaad7aaea, "panfs"],
  [0x19830326, "beegfs"],
  [0x20030528, "orangefs"],
  [0xbeefdead, "snfs"],
  [0x013111a8, "ibrix"],
  [0x786f4256, "vboxsf"],
  [0xbacbacbc, "vmhgfs"],
  [0x7c7c6673, "prl_fs"],
]);

// Whether the system calls a directory's file system other than local, as zspd asks it (MNT_LOCAL), which Node cannot:
// by what mount(8) says of it. Asked only of a kind of file system other than the root's, which is local; and once for
// each, as a device's number is one file system's for as long as it is mounted.
function notLocal(dir: string): string | undefined {
  if (statfsSync(dir).type === statfsSync("/").type) return undefined;
  const dev = statSync(dir).dev;
  if (mounts.has(dev)) return mounts.get(dev);
  const real = realpathSync(dir);
  const { execFileSync } = process.getBuiltinModule("node:child_process") as typeof import("node:child_process");
  let kind: string | undefined;
  found: for (const line of execFileSync("/sbin/mount", { encoding: "utf8" }).split("\n")) {
    // "<from> on <where> (<kind>, <option>, ...)", or "<from> on <where> type <kind> (<option>, ...)": where " on " may
    // be in <from> too, each place it is is tried.
    for (let at = line.indexOf(" on "); at >= 0; at = line.indexOf(" on ", at + 1)) {
      const m = /^(\/.*?)(?: type (\S+))? \(([^()]*)\)$/.exec(line.slice(at + 4));
      if (!m) continue;
      const [, where, typed, options] = m;
      if (real !== where && !real.startsWith(where.endsWith(sep) ? where : where + sep)) continue;
      let same = false;
      try {
        same = statSync(where).dev === dev;
      } catch {}
      if (!same) continue;
      const said = options.split(",").map((o) => o.trim());
      kind = said.includes("local") ? undefined : (typed ?? said[0]);
      break found;
    }
  }
  mounts.set(dev, kind);
  return kind;
}

const mounts = new Map<number, string | undefined>();

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
