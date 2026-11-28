#+build darwin
package host

import "core:os"
import "core:sync"
import "core:sys/posix"

// What every sync made for durability here calls: so that what is said to be kept is kept through a loss of power, as
// SPEC says. fsync(2) on macOS hands what was written to the drive and no further: the drive may hold it in its own cache,
// and lose it, or write it out of order. F_FULLFSYNC asks the drive to write out its cache too, as SQLite does for
// fullfsync. Nothing here asks for less (F_BARRIERFSYNC, which orders what was written before it against what is written
// after, and flushes nothing): a store's every sync comes before an Ack, or before the log that is the only other copy of
// what it keeps is let go of, where order is not enough. The find index's alone needs no more than order, for it can
// always be made again; it is synced in full too, so that there is one way of syncing to trust, at a cost to indexing.
file_durable :: proc(f: ^os.File) -> bool {
	return fd_durable(posix.FD(os.fd(f))) != .Failed
}

// A directory, kept as it is now: the names made or changed in it, which a sync of the file named does not keep.
dir_durable :: proc(dir: string) -> bool {
	return dir_synced(dir) != .Failed
}

@(private)
F_FULLFSYNC :: 51 // <sys/fcntl.h>

@(private)
fd_durable :: proc(fd: posix.FD) -> (how: Synced) {
	defer if hook := sync.atomic_load(&durable_hook); hook != nil {
		hook(fd, how)
	}
	for {
		if posix.fcntl(fd, posix.FCNTL_Cmd(F_FULLFSYNC)) != -1 {
			return .Full
		}
		#partial switch posix.errno() {
		case .EINTR:
			continue
		case .ENOTSUP, .EINVAL, .ENOTTY:
		// A file system that has no such thing, as some do not (network ones, FAT): an fsync then, which is all there is
		// of it there, as SQLite falls back to. Not after any other failure, as of the device, which an fsync after it
		// might not say again.
		case:
			return .Failed
		}
		break
	}
	for {
		if posix.fsync(fd) == .OK {
			return .Fsync
		}
		if posix.errno() != .EINTR {
			return .Failed
		}
	}
}
