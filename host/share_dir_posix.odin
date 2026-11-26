#+build !windows
package host

import "core:os"
import "core:strings"
import "core:sys/posix"

// A folder within a share, held open while a file is written in it: what is made, opened, renamed or removed there is
// named within it, never by a path that may since lead elsewhere. Every step to it is taken from the one before, by
// name, and none through a link: a link in a share may lead out of it, so nothing is written by way of one.

@(private)
Share_Dir :: struct {
	fd: posix.FD,
}

// The folder `parts` within the share whose real path is `root`; what is missing is made, if asked.
@(private)
share_dir_open :: proc(root: string, parts: []string, make: bool) -> (d: Share_Dir, status: Status) {
	fd := posix.open(strings.clone_to_cstring(root, context.temp_allocator), {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
	if fd < 0 {
		return {-1}, .Not_Found
	}
	for part in parts {
		name := strings.clone_to_cstring(part, context.temp_allocator)
		next := posix.openat(fd, name, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
		if next < 0 && posix.errno() == .ENOENT && make {
			if posix.mkdirat(fd, name, {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}) == .OK || posix.errno() == .EEXIST {
				next = posix.openat(fd, name, {.DIRECTORY, .NOFOLLOW, .CLOEXEC})
			}
		}
		if next < 0 {
			e := posix.errno()
			posix.close(fd)
			return {-1}, share_status(e)
		}
		posix.close(fd)
		fd = next
	}
	return {fd}, .Ok
}

@(private)
share_dir_close :: proc(d: ^Share_Dir) {
	if d.fd >= 0 {
		posix.close(d.fd)
		d.fd = -1
	}
}

// A regular file in the folder, to read and write: made if asked, emptied if asked, and never a link.
@(private)
share_file_open :: proc(d: Share_Dir, name: string, create := false, truncate := false) -> (f: ^os.File, status: Status) {
	flags := posix.O_Flags{.RDWR, .NOFOLLOW, .NONBLOCK, .CLOEXEC}
	if create {
		flags += {.CREAT}
	}
	fd := posix.openat(d.fd, strings.clone_to_cstring(name, context.temp_allocator), flags, posix.mode_t{.IRUSR, .IWUSR})
	if fd < 0 {
		return nil, share_status(posix.errno())
	}
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) {
		posix.close(fd)
		return nil, .Denied
	}
	if truncate && posix.ftruncate(fd, 0) != .OK {
		posix.close(fd)
		return nil, .Failed
	}
	return os.new_file(uintptr(fd), name), .Ok
}

// Whether something is there by that name, and if so whether a regular file: a link is not followed to say.
@(private)
share_kind :: proc(d: Share_Dir, name: string) -> (exists, regular: bool) {
	st: posix.stat_t
	if posix.fstatat(d.fd, strings.clone_to_cstring(name, context.temp_allocator), &st, {.SYMLINK_NOFOLLOW}) != .OK {
		return false, false
	}
	return true, posix.S_ISREG(st.st_mode)
}

// Puts `from` in the place of `to`, whatever was there (a link there is replaced, not followed); durably.
@(private)
share_rename :: proc(d: Share_Dir, from, to: string) -> bool {
	if posix.renameat(d.fd, strings.clone_to_cstring(from, context.temp_allocator), d.fd, strings.clone_to_cstring(to, context.temp_allocator)) != .OK {
		return false
	}
	posix.fsync(d.fd)
	return true
}

@(private)
share_remove :: proc(d: Share_Dir, name: string) {
	posix.unlinkat(d.fd, strings.clone_to_cstring(name, context.temp_allocator), {})
}

@(private)
share_status :: proc(e: posix.Errno) -> Status {
	#partial switch e {
	case .ENOENT, .ENOTDIR:
		return .Not_Found
	case .ELOOP, .EACCES, .EPERM, .EISDIR:
		return .Denied
	}
	return .Failed
}
