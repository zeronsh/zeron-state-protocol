#+build darwin, freebsd, openbsd, netbsd
package host

import "core:strings"
import "core:sys/posix"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

@(default_calling_convention = "c", private = "file")
foreign libc {
	flock :: proc(fd: posix.FD, operation: i32) -> i32 ---
}

// flock's lock, which an open file holds: against another opening of the file in this process as in any other's, and
// let go of when the file is closed or the process ends. It is what Node's O_EXLOCK takes, as it opens the file.
@(private)
lock_held :: proc(fd: posix.FD) -> Hold {
	LOCK_EX :: 2
	LOCK_NB :: 4
	for {
		if flock(fd, LOCK_EX | LOCK_NB) == 0 {
			return .Held
		}
		#partial switch posix.errno() {
		case .EINTR:
			continue
		case .EWOULDBLOCK:
			return .In_Use
		case:
			return .Failed
		}
	}
}

// Whether what is at a path is on a file system shared with other machines, and what kind: one its system does not call
// local (MNT_LOCAL), as NFS, SMB, AFP and WebDAV are, and FUSE's unless mounted saying they are; and whether there is
// anything there to ask of.
@(private)
path_remote :: proc(path: string) -> (remote: bool, kind: string, found: bool) {
	name := strings.clone_to_cstring(path, context.temp_allocator)
	MNT_LOCAL :: 0x1000
	when ODIN_OS == .Darwin {
		// struct statfs, as it is with 64-bit inode numbers, which arm64 always has and amd64 asks for by name.
		Stat_FS :: struct {
			bsize:       u32,
			iosize:      i32,
			blocks:      u64,
			bfree:       u64,
			bavail:      u64,
			files:       u64,
			ffree:       u64,
			fsid:        [2]i32,
			owner:       u32,
			type:        u32,
			flags:       u32,
			fssubtype:   u32,
			fstypename:  [16]u8,
			mntonname:   [1024]u8,
			mntfromname: [1024]u8,
			flags_ext:   u32,
			reserved:    [7]u32,
		}
		foreign libc {
			@(link_name = "statfs$INODE64" when ODIN_ARCH == .amd64 else "statfs")
			statfs :: proc "c" (path: cstring, buf: ^Stat_FS) -> i32 ---
		}
	} else when ODIN_OS == .FreeBSD {
		// struct statfs since FreeBSD 12, as statfs is now.
		Stat_FS :: struct {
			version:     u32,
			type:        u32,
			flags:       u64,
			_:           [11]u64, // sizes, counts
			_:           [10]u64,
			namemax:     u32,
			owner:       u32,
			fsid:        [2]i32,
			_:           [80]u8,
			fstypename:  [16]u8,
			mntfromname: [1024]u8,
			mntonname:   [1024]u8,
		}
		foreign libc {
			statfs :: proc "c" (path: cstring, buf: ^Stat_FS) -> i32 ---
		}
	} else when ODIN_OS == .OpenBSD {
		// Of struct statfs, its flags come first, and its name is not looked at.
		Stat_FS :: struct {
			flags: u32,
			_:     [4096]u8,
		}
		foreign libc {
			statfs :: proc "c" (path: cstring, buf: ^Stat_FS) -> i32 ---
		}
	}
	for {
		when ODIN_OS == .NetBSD {
			st: posix.statvfs_t
			if posix.statvfs(name, &st) == .OK {
				return transmute(uint)st.f_flag & MNT_LOCAL == 0, named(st.f_fstypename[:]), true
			}
		} else {
			st: Stat_FS
			if statfs(name, &st) == 0 {
				when ODIN_OS == .OpenBSD {
					return st.flags & MNT_LOCAL == 0, "not local", true
				} else {
					return st.flags & MNT_LOCAL == 0, named(st.fstypename[:]), true
				}
			}
		}
		if posix.errno() != .EINTR {
			return
		}
	}
}

// A name the system wrote into room of its own, ending where a nul does: kept, as the room is not.
@(private = "file")
named :: proc(name: []u8) -> string {
	end := len(name)
	for b, i in name {
		if b == 0 {
			end = i
			break
		}
	}
	return strings.clone(string(name[:end]), context.temp_allocator)
}
