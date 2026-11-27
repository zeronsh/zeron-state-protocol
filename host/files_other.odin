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

@(default_calling_convention = "c", private)
foreign libc {
	// Not POSIX, but in every system's C library here: a lock held by an open file, not by a process, so that two in one
	// process exclude each other, and let go of when that is closed, and not when another file of the process on it is.
	flock :: proc(fd: posix.FD, operation: i32) -> i32 ---
}

@(private)
LOCK_EX :: 2
@(private)
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

@(private)
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

// Holds a file's lock against every other that takes it, in another process or in another thread of this one, until let
// go of: blocking until it is free. flock's, an open file's, which neither lets another thread of the process through,
// as a process's own lock (lockf) would, nor is let go of when another file of the process on it is closed.
File_Lock :: distinct posix.FD

@(private)
file_lock :: proc(path: string) -> (lock: File_Lock, ok: bool) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	fd := open_file(name, {.RDWR, .CREAT, .CLOEXEC, .NOFOLLOW}) // never a link, followed to wherever it leads
	if fd < 0 {
		return
	}
	if !lock_file(fd, LOCK_EX) {
		posix.close(fd)
		return
	}
	return File_Lock(fd), true
}

@(private)
file_unlock :: proc(lock: File_Lock) {
	posix.close(posix.FD(lock)) // which lets go of the lock
}

// A store's directory held: see hold.odin.
Dir_Lock :: distinct posix.FD

// Holds the lock file of a store's directory, made if there is none, without waiting; or says why not.
@(private)
dir_lock :: proc(path: string) -> (lock: Dir_Lock, held: Hold) {
	// Readable by nobody else, who could otherwise hold it too and so keep every node from the store. Never a link,
	// followed to wherever it leads.
	fd := open_file(strings.clone_to_cstring(path, context.temp_allocator), {.RDWR, .CREAT, .CLOEXEC, .NOFOLLOW})
	if fd < 0 {
		return Dir_Lock(-1), .Failed
	}
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) {
		posix.close(fd) // nor anything but a file
		return Dir_Lock(-1), .Failed
	}
	if st.st_mode & {.IRGRP, .IWGRP, .IXGRP, .IROTH, .IWOTH, .IXOTH} != {} {
		posix.fchmod(fd, {.IRUSR, .IWUSR}) // as made by another, readable by others, as it is kept from now on
	}
	if held = lock_held(fd); held != .Held {
		posix.close(fd)
		return Dir_Lock(-1), held
	}
	return Dir_Lock(fd), .Held
}

// Where a directory is, as the system takes its path, for this turn: one there is, resolved as the system resolves it,
// links and `..` and all (realpath); one that is not, a part at a time, each that is there resolved so from where the
// last led, and each that is not, which is to be made and so is no link, as written, a `..` after it taking it away. No
// path, not even an empty one, which would be wherever the process happens to be, is no directory.
dir_real :: proc(dir: string) -> (real: string, ok: bool) {
	if dir == "" {
		return
	}
	resolve :: proc(path: string) -> (real: string, there: bool, ok: bool) {
		resolved := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator))
		if resolved == nil {
			return "", false, posix.errno() == .ENOENT
		}
		defer posix.free(rawptr(resolved))
		return strings.clone(string(resolved), context.temp_allocator), true, true
	}
	there: bool
	if real, there = resolve(dir) or_return; there {
		return real, true
	}
	if real, there = resolve("/" if strings.has_prefix(dir, "/") else ".") or_return; !there {
		return
	}
	made := make([dynamic]string, context.temp_allocator) // to be made, after real
	for part in strings.split(dir, "/", context.temp_allocator) {
		switch part {
		case "", ".":
		case "..":
			if len(made) > 0 {
				pop(&made)
			} else {
				real = filepath.dir(real)
			}
		case:
			if len(made) > 0 {
				append(&made, part)
				continue
			}
			next, found := resolve(file_in(real, part)) or_return
			if found {
				real = next
			} else {
				append(&made, part)
			}
		}
	}
	for part in made {
		real = file_in(real, part)
	}
	return real, true
}

// The names in a directory, for this turn, as cheaply as they can be had: without asking anything of what each is.
@(private)
dir_names :: proc(dir: string) -> []string {
	d := posix.opendir(strings.clone_to_cstring(dir, context.temp_allocator))
	if d == nil {
		return nil
	}
	defer posix.closedir(d)
	names := make([dynamic]string, context.temp_allocator)
	for {
		e := posix.readdir(d)
		if e == nil {
			return names[:]
		}
		append(&names, strings.clone(string(cstring(raw_data(e.d_name[:]))), context.temp_allocator))
	}
}

// Lets go of a store's directory, its files being closed already.
dir_unlock :: proc(lock: Dir_Lock) {
	posix.close(posix.FD(lock)) // which lets go of the lock
}
