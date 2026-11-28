#+build !darwin
#+build !windows
package host

import "core:os"
import "core:sync"
import "core:sys/posix"

// What every sync made for durability here calls: so that what is said to be kept is kept through a loss of power, as
// SPEC says. An fsync, which on Linux writes out the file's data and what the system knows of it (its size among it),
// and has the drive write out its cache, where the drive has one and the file system was not told not to (barrier=0,
// nobarrier). Not fdatasync, which may leave out what is needed to find the data again after a crash.
file_durable :: proc(f: ^os.File) -> bool {
	return fd_durable(posix.FD(os.fd(f))) != .Failed
}

// A directory, kept as it is now: the names made or changed in it, which a sync of the file named does not keep.
dir_durable :: proc(dir: string) -> bool {
	return dir_synced(dir) != .Failed
}

@(private)
fd_durable :: proc(fd: posix.FD) -> (how: Synced) {
	defer if hook := sync.atomic_load(&durable_hook); hook != nil {
		hook(fd, how)
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
