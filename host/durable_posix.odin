#+build !windows
package host

import "core:strings"
import "core:sys/posix"

// How a sync went: F_FULLFSYNC's, which has the drive write out its cache, or an fsync's.
@(private)
Synced :: enum u8 {
	Failed,
	Fsync,
	Full,
}

// Told of every sync made for durability, as it is made, should a test want to see which: nil but in tests.
@(private)
durable_hook: proc(fd: posix.FD, how: Synced) // atomic

@(private)
dir_synced :: proc(dir: string) -> Synced {
	name := strings.clone_to_cstring(dir if dir != "" else ".", context.temp_allocator)
	fd: posix.FD
	for {
		fd = posix.open(name, {.CLOEXEC, .DIRECTORY})
		if fd >= 0 || posix.errno() != .EINTR {
			break
		}
	}
	if fd < 0 {
		return .Failed
	}
	defer posix.close(fd)
	return fd_durable(fd)
}
