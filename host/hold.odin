package host

import "core:os"
import "core:path/filepath"

// A store's directory is one node's at a time. Two writing one log at once each write over what the other wrote, at the
// same places, and each acknowledges what the other has already overwritten: nothing says so, then or at the next start.
// So whoever keeps a store holds its directory, by a lock on the file LOCK_FILE in it, from before anything there is read
// until everything is written and let go of: zspd for its whole life, a relay's spaces as each is open, and a Node
// device's volume (web/src/volume-node.ts) likewise. Whoever comes second is told the store is in use, and touches
// nothing. The kernel lets go of the lock when the process ends, however it ends, so that a node killed leaves nothing
// behind it to clear.
//
// The lock is the system's own, the same in every process that keeps a store: on Linux, an open file description's lock
// on bytes LOCK_AT to LOCK_AT + LOCK_SIZE; on Windows, a lock on the same bytes; elsewhere, flock's on the whole file.
// Node has none of these of its own. On Linux and Windows it locks those bytes through the SQLite it is built with, which
// keeps its locks there: its pending byte, reserved byte and shared bytes. Elsewhere it opens the file with O_EXLOCK,
// which is flock's.
//
// A process forked shares its parent's open files, and with them the lock, until it ends or execs, which lets go of every
// file here, all being opened close-on-exec: an embedder that forks and does not exec closes them in the child.
//
// A lock on a file system shared with other machines may not hold: one machine's lock may not be seen by another, or may
// be lost while it is held, when the server or the network is slow. So a store on one is refused, where that can be told,
// before anything is made there.
//
// zspd's commands beside a node tell whether one runs by the lock too, not by whether anything answers where one said it
// listens, which another may by then. A node starting holds START_FILE's lock, waiting for it, from before it holds the
// directory until it has said where it listens (see zspd/main.odin); and so does every command that holds the directory
// a while, so that neither takes the other for a node that is running, nor is kept from the directory by the other.

LOCK_FILE :: "lock"
LOCK_AT :: 1 << 30 // SQLite's PENDING_BYTE: bytes nothing is ever written to, there or here
LOCK_SIZE :: 512 // its pending byte, its reserved byte, and its 510 shared bytes
START_FILE :: "start.lock"

// What holding a directory came to.
Hold :: enum {
	Held,
	In_Use, // by another process, or by another part of this one
	Remote, // on a file system shared with other machines
	Failed,
}

// Holds a store's directory, made if there is none, against every other process and every other holder in this one,
// until let go of by dir_unlock or the end of the process: or says why not, through report, and holds nothing.
@(require_results)
dir_hold :: proc(dir: string) -> (lock: Dir_Lock, ok: bool) {
	held: Hold
	kind: string
	lock, held, kind = dir_try(dir)
	hold_report(dir, held, kind)
	return lock, held == .Held
}

// The same, saying nothing.
@(require_results)
dir_try :: proc(dir: string) -> (lock: Dir_Lock, held: Hold, kind: string) {
	remote, there: bool
	if remote, kind, there = dir_shared(dir); remote {
		held = .Remote
		return
	}
	if !there {
		if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
			held = .Failed
			return
		}
	}
	lock, held = dir_lock(file_in(dir, LOCK_FILE))
	return
}

// Whether a directory is on a file system shared with other machines, and what kind, and whether it is there: asked of
// what there is of it, before anything is made there.
@(private)
dir_shared :: proc(dir: string) -> (remote: bool, kind: string, there: bool) {
	at := dir
	for {
		found: bool
		remote, kind, found = path_remote(at)
		if found {
			return remote, kind, at == dir
		}
		up := filepath.dir(at)
		if up == at || up == "" {
			return
		}
		at = up
	}
}

// Says why a directory was not held, if it was not.
hold_report :: proc(dir: string, held: Hold, kind: string) {
	switch held {
	case .Held:
	case .In_Use:
		report(.Error, "this store is in use by another process: ", dir)
	case .Remote:
		report(.Error, dir, " is on a file system shared with other machines (", kind, "), where its lock may not hold: keep the store on a disk of this machine's own")
	case .Failed:
		report(.Error, "could not lock ", dir)
	}
}

// Waits until no node is starting in a directory, nor any command holding it a while, and keeps any from starting until
// let go of by dir_started.
@(require_results)
dir_starting :: proc(dir: string) -> (lock: File_Lock, ok: bool) {
	if remote, kind, _ := dir_shared(dir); remote {
		hold_report(dir, .Remote, kind)
		return
	}
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		report(.Error, "could not make ", dir)
		return
	}
	lock, ok = file_lock(file_in(dir, START_FILE))
	if !ok {
		report(.Error, "could not lock ", dir)
	}
	return
}

dir_started :: proc(lock: File_Lock) {
	file_unlock(lock)
}
