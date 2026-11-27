// A directory on a disk, for Node.

import { chmodSync, closeSync, constants, existsSync, fstatSync, fsyncSync, ftruncateSync, lstatSync, mkdirSync, openSync, readdirSync, readSync, realpathSync, renameSync, rmSync, statfsSync, statSync, writeSync } from "node:fs";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import type { File, Volume } from "./volume.ts";

/**
 * A directory, as a device's store: held by this volume alone, from its first use until it is closed, against every other
 * process and every other volume of this one, as zspd holds its own. Whoever comes second is told the store is in use,
 * and touches nothing. Once closed, it is held again only by a store opening it again, which lists it first: never by
 * what one let go of might yet do, as it would be for good. See holdDirectory.
 */
export class NodeVolume implements Volume {
  readonly path: string;
  #at: string; // where the directory is as the system takes it, once held: what is made and held, and kept in
  #release?: () => void; // while the directory is held
  #closed = false;

  constructor(path: string) {
    this.path = this.#at = path;
  }

  #hold(opening = false): void {
    if (this.#release) return;
    if (this.#closed && !opening) throw new Error(`the store's directory was let go of: ${this.path}`);
    [this.#at, this.#release] = holdDirectory(this.path);
    this.#closed = false;
  }

  async list(): Promise<string[]> {
    this.#hold(true);
    let names: string[];
    try {
      names = readdirSync(this.#at);
    } catch {
      return [];
    }
    // What a lock file was made from, left by a process that ended in the moment it was being made: long done with.
    for (const name of names) {
      if (!ASIDE.test(name)) continue;
      const path = join(this.#at, name);
      try {
        if (Date.now() - statSync(path).mtimeMs > 60_000) rmSync(path, { force: true });
      } catch {}
    }
    return names;
  }

  async open(name: string, create: boolean): Promise<File | undefined> {
    return this.openNow(name, create);
  }

  openNow(name: string, create: boolean): File | undefined {
    this.#hold(); // which makes the directory
    const path = join(this.#at, name);
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
      const dir = openSync(this.#at, "r");
      fsyncSync(dir);
      closeSync(dir);
    }
    return new NodeFile(fd);
  }

  async remove(name: string): Promise<void> {
    this.#hold();
    rmSync(join(this.#at, name), { force: true });
  }

  /** Lets go of the directory, its files being closed already: for this volume to hold again, or another. */
  close(): void {
    const release = this.#release;
    this.#release = undefined;
    this.#closed = true;
    release?.();
  }
}

/**
 * Where zspd and Node take flock's lock on a store's lock file, and not a lock on its bytes: as host/hold_bsd.odin is
 * built for, which web/test/hold.ts holds this to.
 */
export const FLOCK = new Set<string>(["darwin", "freebsd", "openbsd", "netbsd"]);

/**
 * What a lock file is made from is named so: as no save's staging file is (host/staging.odin), so that zspd, which removes
 * those it finds held by nobody, never removes one, which Node cannot hold as a save does.
 */
export const ASIDE = /^\.lock\.[0-9a-f]{32}\.making$/;

/**
 * A store's lock file, in its directory, as host/hold.odin names it: hidden, as what nothing but whoever holds the store is
 * to open, so that what reads a directory's files but not its hidden ones leaves it alone.
 */
export const LOCK = ".lock";

// A store's directory is one node's at a time, as host/hold.odin says: two writing one log at once each write over what
// the other wrote, and each acknowledges what is lost. So it is held, by a lock on its file ".lock" that the kernel lets go
// of when the process ends, however it ends: the lock zspd takes, so that each keeps the other out too. Node has no way
// of its own to take it. On Linux and Windows it is taken through the SQLite Node is built with, which keeps its locks on
// the very bytes zspd locks there: its pending, reserved and shared bytes, at 2^30. Where zspd takes flock's lock, it is
// taken as the file is opened, by O_EXLOCK.
//
// On Linux that lock is SQLite's POSIX record lock, which the kernel holds for the process, not for the file opened: should
// anything else in this process open the store's lock file and close it again (fs.cp of the store's directory, say, or
// anything that reads every file in it), the kernel lets go of the lock while the device runs, and another process may
// then open the store beside it, and nothing says so. Nothing here ever opens the lock file but SQLite, which keeps its own
// files open while it holds locks for that reason; another device of this process on the directory goes through SQLite
// too, and is refused; and it is hidden, `.lock`, so that what reads a directory's files but not its hidden ones leaves it
// alone. Node 24 has no other lock, nor any way to see one let go of; Node 26's node:ffi could take zspd's own, but is
// experimental, and cannot call fcntl as declared (see docs/web.md). So, on Linux, nothing else in the process may open a
// running device's lock file: copy a device's directory only once it is closed. Windows' locks are the handle's and
// macOS' are the open file's, so there they hold whatever else is opened.
//
// A lock on a file system shared with other machines may not hold, and a store on one is refused, where that can be
// told, before anything is made there. Returns where the directory is, as held, and what lets go of it.
function holdDirectory(dir: string): [string, () => void] {
  // No path, which would be wherever the process happens to be, is no directory.
  if (dir === "") throw new Error("a store's directory is named by no path");
  // Judged as the system will take it: itself if it is there, links and all; if not, the longest part of its path that
  // is, as the system resolves it, and the rest, to be made, as written.
  const there = existsSync(dir);
  const at = there ? realpathSync.native(dir) : resolved(dir);
  let judged = at;
  while (!existsSync(judged) && dirname(judged) !== judged) judged = dirname(judged);
  const kind = shared(judged);
  if (kind) throw new Error(`${dir} is on a file system shared with other machines (${kind}), where its lock may not hold: keep the store on a disk of this machine's own`);
  if (!there) mkdirSync(at, { recursive: true, mode: 0o700 });
  const path = join(at, LOCK);
  const inUse = () => new Error(`this store is in use by another process: ${dir}`);
  const notFile = () => new Error(`${path} is not a file: a store's lock file is never a link, nor anything but a file`);
  // Nothing but a file, never a link followed to wherever it leads, readable by its owner alone, as zspd holds it to: one
  // anyone could read anyone could hold too, and so keep every node from the store. Only asked of by its name, never
  // opened, which on Linux would let go of what this process holds there.
  const st = lstatSync(path, { throwIfNoEntry: false });
  if (st && !st.isFile()) throw notFile();
  if (st && process.platform !== "win32" && st.mode & 0o077) {
    try {
      chmodSync(path, st.mode & 0o600);
    } catch {}
  }
  if (FLOCK.has(process.platform)) {
    const O_EXLOCK = 0x20; // as Darwin and the BSDs have it, and Node does not name it
    let fd: number;
    try {
      fd = openSync(path, constants.O_RDWR | constants.O_CREAT | constants.O_NONBLOCK | constants.O_NOFOLLOW | O_EXLOCK, 0o600);
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      if (code === "EAGAIN" || code === "EWOULDBLOCK") throw inUse();
      if (code === "ELOOP") throw notFile();
      throw e;
    }
    if (!fstatSync(fd).isFile()) {
      closeSync(fd);
      throw notFile();
    }
    return [at, () => closeSync(fd)];
  }
  const { DatabaseSync } = process.getBuiltinModule("node:sqlite") as typeof import("node:sqlite");
  const take = (): (() => void) => {
    // Made, if it is not there, as zspd makes it, readable by its owner alone, where SQLite would make it readable by
    // everyone: as another file made so is (modeof), made aside first, never in its place.
    let aside: string | undefined;
    let name: string | URL = path;
    if (process.platform !== "win32" && !existsSync(path)) {
      aside = madeAside(at, new Uint8Array(0));
      name = pathToFileURL(path);
      name.searchParams.set("modeof", aside);
    }
    let db: InstanceType<typeof DatabaseSync> | undefined;
    try {
      db = new DatabaseSync(name, { timeout: 0 });
      // Its shared lock and its reserved one, which only one holds at a time, by a write begun and never ended: which
      // writes nothing, nor any journal, kept in memory.
      db.exec("PRAGMA journal_mode = MEMORY; BEGIN IMMEDIATE");
      const held = db;
      return () => held.close();
    } catch (e) {
      db?.close();
      throw e;
    } finally {
      if (aside) rmSync(aside, { force: true });
    }
  };
  const code = (e: unknown) => ((e as { errcode?: number }).errcode ?? 0) & 0xff;
  const filled = () => (lstatSync(path, { throwIfNoEntry: false })?.size ?? 0) > 0;
  for (let tries = 0; ; tries++) {
    // Something in it, which nothing writes and zspd pays no heed to, is emptied first: for SQLite makes of it what it
    // may, and of some of it a database it only reads, in which it begins a write, says so, and holds nothing. It is
    // emptied by SQLite itself, as it does what a hot journal beside a database says: through its own file and under its
    // own lock, with what it holds in this process known to it, where anything else here opening the file and closing
    // it would let go of what this process holds there, as a process's locks are let go of. SQLite plays the journal
    // only with the file held by nobody, in this process or another, zspd or a device: so it is put there whether or not
    // anyone holds the file now, which decides, and does no harm if someone does. The journal says the database had no
    // pages before, and so is to have none, and nothing more; it is removed once played, or once the file is found
    // empty. Put in its place whole, it is never read half written.
    if (filled()) journalToEmpty(at, path);
    let release: () => void;
    try {
      release = take();
    } catch (e) {
      if (code(e) === 5 || code(e) === 6) throw inUse(); // SQLITE_BUSY, by another; SQLITE_LOCKED, by this one
      // Anything else, with something in it still, is what is in it, whatever SQLite made of it, and is emptied once
      // nobody holds it; with nothing in it, it is no such thing.
      if (tries === 4 || !filled()) throw e;
      continue;
    }
    // Held only of a file with nothing in it, of which SQLite's write is a write, and its lock the lock.
    if (!filled()) return [at, release];
    release();
    if (tries === 4) throw new Error(`${path} has something in it that is not let go of: nothing writes it, so it may be removed once no node runs here`);
  }
}

// Puts beside a lock file a hot journal that has SQLite empty it, once nobody holds it: see holdDirectory.
function journalToEmpty(at: string, path: string): void {
  const journal = new Uint8Array(512);
  const header = new DataView(journal.buffer);
  journal.set([0xd9, 0xd5, 0x05, 0xf9, 0x20, 0xa1, 0x63, 0xd7]); // the journal's magic
  // records 0, checksum seed 0, pages the database had 0, then its sector size and its page size
  header.setUint32(20, 512);
  header.setUint32(24, 4096);
  const aside = madeAside(at, journal);
  try {
    renameSync(aside, path + "-journal");
  } catch (e) {
    rmSync(aside, { force: true });
    // On Windows, another's journal being played, which SQLite has open and does not let be replaced meanwhile: that
    // other is emptying the file, and then holds it, or not, as taking it finds.
    const busy = ["EPERM", "EBUSY", "EACCES"].includes((e as NodeJS.ErrnoException).code ?? "");
    if (!(process.platform === "win32" && busy)) throw e;
  }
}

// A file made, holding what is given, under a name of its own that ASIDE matches, readable by its owner alone; the
// whole of it on disk before anything takes it for what it is to be. Returns its path.
function madeAside(dir: string, bytes: Uint8Array): string {
  for (;;) {
    const aside = join(dir, `${LOCK}.${Array.from({ length: 4 }, () => ((Math.random() * 2 ** 32) >>> 0).toString(16).padStart(8, "0")).join("")}.making`);
    let fd: number;
    try {
      fd = openSync(aside, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL, 0o600);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "EEXIST") continue;
      throw e;
    }
    try {
      if (bytes.length > 0) {
        writeSync(fd, bytes, 0, bytes.length, 0);
        fsyncSync(fd);
      }
    } finally {
      closeSync(fd);
    }
    return aside;
  }
}

// Where a directory that is not there would be, as the system takes its path: a part at a time, each that is there
// resolved as the system resolves it (realpath), links and `..` and all, from where the last led, and each that is not,
// which is to be made and so is no link, as written, a `..` after it taking it away. Windows takes `..` only as written.
function resolved(dir: string): string {
  if (process.platform === "win32") return resolve(dir);
  const real = (path: string): string | undefined => {
    try {
      return realpathSync.native(path);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") return undefined;
      throw e;
    }
  };
  let at = real(isAbsolute(dir) ? "/" : ".")!;
  const made: string[] = [];
  for (const part of dir.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      if (made.length > 0) made.pop();
      else at = dirname(at);
      continue;
    }
    const next = made.length === 0 ? real(join(at, part)) : undefined;
    if (next !== undefined) at = next;
    else made.push(part);
  }
  return join(at, ...made);
}

// The kind of file system shared with other machines a directory there is is on, if it is on one, as host/ finds it.
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
// by what mount(8) says of it. A directory on a file system of the root's kind, as most are, is as the root is, which is
// asked once, as it is the same file system for as long as the machine runs; any other, each time, as what is mounted
// where may change, and a device's number with it.
function notLocal(dir: string): string | undefined {
  if (judgedByRoot(statfsSync(dir).type, statfsSync("/").type)) return (rootKind ??= [mountKind("/")])[0];
  return mountKind(dir);
}

/**
 * Whether a file system is judged as the root's is, by its kind, as Node has it from statfs: never where Node says no
 * kind at all, as on OpenBSD and NetBSD, where every file system is of kind 0, the root's and a share's alike.
 */
export function judgedByRoot(type: number, root: number): boolean {
  return type !== 0 && type === root;
}

let rootKind: [string | undefined] | undefined;

function mountKind(dir: string): string | undefined {
  const dev = statSync(dir).dev;
  const real = realpathSync(dir);
  const { execFileSync } = process.getBuiltinModule("node:child_process") as typeof import("node:child_process");
  for (const line of execFileSync("/sbin/mount", { encoding: "utf8" }).split("\n")) {
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
      return said.includes("local") ? undefined : (typed ?? said[0]);
    }
  }
  return undefined;
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
