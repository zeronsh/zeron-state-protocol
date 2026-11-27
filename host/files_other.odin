#+build !windows
package host

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

@(default_calling_convention = "c", private = "file")
foreign libc {
	// Not POSIX, but in every system's C library here: a lock held by an open file, not by a process, so that two in one
	// process exclude each other, and let go of when that is closed.
	flock :: proc(fd: posix.FD, operation: i32) -> i32 ---
}

@(private = "file")
LOCK_EX :: 2
@(private = "file")
LOCK_NB :: 4

// The whole of a file, or false if there is none.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	err: os.Error
	data, err = os.read_entire_file(path, allocator)
	return data, err == nil
}

// Saves bytes as a file, whole or not at all: written to a staging file of its own (see staging.odin), synced, and put
// in its place, which a rename does here whoever has either open; so that a save beside it, by another process or this
// one, is neither written into nor taken for it, and a reader finds one whole version or another.
save :: proc(path: string, bytes: []byte) -> bool {
	s := staging_make(path) or_return
	ok := write_file(s.fd, bytes) && sync_file(s.fd) && posix.rename(s.name, strings.clone_to_cstring(path, context.temp_allocator)) == 0
	if !ok {
		posix.unlink(s.name)
	}
	posix.close(s.fd)
	if ok {
		// The name is the directory's to remember.
		dir := strings.clone_to_cstring(filepath.dir(path), context.temp_allocator)
		if d := open_file(dir, {.CLOEXEC, .DIRECTORY}); d >= 0 {
			sync_file(d)
			posix.close(d)
		}
	}
	return ok
}

// A staging file, made and held, until it is let go of: by its file's being closed.
@(private)
Staging :: struct {
	fd:   posix.FD,
	name: cstring, // temporary
}

@(private)
staging_make :: proc(path: string) -> (s: Staging, ok: bool) {
	for _ in 0 ..< STAGING_TRIES {
		s.name = strings.clone_to_cstring(staging_name(path), context.temp_allocator)
		s.fd = open_file(s.name, {.WRONLY, .CREAT, .EXCL, .CLOEXEC, .NOFOLLOW})
		if s.fd < 0 {
			if posix.errno() == .EEXIST {
				continue // taken, though it was all but certain not to be
			}
			return
		}
		// Held until it has its place. Should staging_clear have taken it for one left behind in the moment before it was
		// held, it is nobody's now, and another is made.
		st: posix.stat_t
		if !lock_file(s.fd, LOCK_EX) || posix.fstat(s.fd, &st) != .OK {
			staging_drop(s)
			return
		}
		if st.st_nlink > 0 {
			return s, true
		}
		posix.close(s.fd)
	}
	return
}

// Lets go of a staging file, and of what was written to it.
@(private)
staging_drop :: proc(s: Staging) {
	posix.unlink(s.name)
	posix.close(s.fd)
}

// Removes a staging file unless a save holds it.
@(private)
staging_remove_unheld :: proc(path: string) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	fd := open_file(name, {.RDWR, .CLOEXEC, .NOFOLLOW})
	if fd < 0 {
		return
	}
	// Held by nobody, it is left behind; or it was made a moment ago, not held yet, and its save will find it gone.
	// And if it has its place already, by the time this holds it, its name is gone, and nothing is removed.
	if flock(fd, LOCK_EX | LOCK_NB) == 0 {
		posix.unlink(name)
	}
	posix.close(fd)
}

// What may wait for as long as anything else takes, as a lock, may be interrupted by a signal, which a handler without
// SA_RESTART lets end the wait: it is begun again. And so is whatever else might be, on whatever file system.

@(private = "file")
open_file :: proc(name: cstring, flags: posix.O_Flags) -> (fd: posix.FD) {
	for {
		fd = posix.open(name, flags, posix.mode_t{.IRUSR, .IWUSR})
		if fd >= 0 || posix.errno() != .EINTR {
			return
		}
	}
}

@(private = "file")
lock_file :: proc(fd: posix.FD, operation: i32) -> bool {
	for {
		if flock(fd, operation) == 0 {
			return true
		}
		if posix.errno() != .EINTR {
			return false
		}
	}
}

@(private = "file")
write_file :: proc(fd: posix.FD, bytes: []byte) -> bool {
	for rest := bytes; len(rest) > 0; {
		n := posix.write(fd, raw_data(rest), uint(len(rest)))
		if n < 0 {
			if posix.errno() == .EINTR {
				continue
			}
			return false
		}
		rest = rest[n:]
	}
	return true
}

@(private = "file")
sync_file :: proc(fd: posix.FD) -> bool {
	for {
		if posix.fsync(fd) == .OK {
			return true
		}
		if posix.errno() != .EINTR {
			return false
		}
	}
}

// Holds a file's lock against every other process that takes it, until let go of: blocking until it is free.
@(private)
File_Lock :: distinct posix.FD

@(private)
file_lock :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	fd := open_file(name, {.RDWR, .CREAT, .CLOEXEC})
	if fd < 0 {
		return
	}
	for posix.lockf(fd, .LOCK, 0) != .OK {
		if posix.errno() != .EINTR {
			posix.close(fd)
			return
		}
	}
	return File_Lock(fd), true
}

@(private)
file_unlock :: proc(lock: File_Lock) {
	posix.close(posix.FD(lock)) // which lets go of the lock
}
