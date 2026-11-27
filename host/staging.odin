package host

import "core:crypto"
import "core:encoding/hex"
import "core:strings"

// A save is written whole to a file of its own, its staging file, before it takes the place of what it saves. Its name
// is drawn at random, from 128 bits, so that no save takes another's, by another process or this one, nor one a process
// that ended mid-save left behind, whatever process it was: a process's number may be any's after it, and in a
// container is the same every time. A save holds its staging file from making it until it has its place, so that a
// staging file nobody holds is one left behind, which staging_clear removes.

STAGING_SUFFIX :: ".new"
@(private)
STAGING_TRIES :: 8 // names drawn, at most, of which any is all but certain to be free

@(private, thread_local)
staging_random: proc(into: []byte) // for a test, what names are drawn from in place of crypto.rand_bytes

// A name for a file to be written whole before it replaces another: `path`, 32 hex digits, and STAGING_SUFFIX.
@(private)
staging_name :: proc(path: string) -> string {
	drawn: [16]byte
	if staging_random != nil {
		staging_random(drawn[:])
	} else {
		crypto.rand_bytes(drawn[:])
	}
	return strings.concatenate({path, ".", string(hex.encode(drawn[:], context.temp_allocator)), STAGING_SUFFIX}, context.temp_allocator)
}

// Whether a file's name is a staging file's.
@(private)
staging_named :: proc(name: string) -> bool {
	DRAWN :: 32
	if len(name) <= 1 + DRAWN + len(STAGING_SUFFIX) || !strings.has_suffix(name, STAGING_SUFFIX) {
		return false
	}
	at := len(name) - len(STAGING_SUFFIX) - DRAWN
	if name[at - 1] != '.' {
		return false
	}
	for c in transmute([]byte)name[at:][:DRAWN] {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// Removes the staging files in a directory that a process left behind, ending mid-save: never one a save is writing,
// here or in another process, which holds it until it has its place.
staging_clear :: proc(dir: string) {
	// By name alone, as most names are none: what is no regular file is not removed, as it cannot be held.
	for name in dir_names(dir) {
		if staging_named(name) {
			staging_remove_unheld(file_in(dir, name))
		}
	}
}
