#+build linux
package host

import "core:sys/linux"
import "core:sys/posix"

// Linux's part of process_posix.odin: a process's end is waited on through a pidfd, which becomes readable when it
// ends, and the child closes what it should not have with close_range.

PROCESS_TIOCSWINSZ :: 0x5414
PROCESS_TIOCSCTTY :: 0x540E

foreign import libc "system:c"

@(private)
foreign libc {
	ptsname_r :: proc(fd: posix.FD, buf: [^]byte, size: uint) -> i32 ---
}

// Readable once the process has ended; -1 if the kernel cannot say (before 5.3).
@(private)
process_watch :: proc(pid: posix.pid_t) -> posix.FD {
	fd, errno := linux.pidfd_open(linux.Pid(pid), {})
	if errno != nil {
		posix.errno(posix.Errno(errno))
		return -1
	}
	return posix.FD(fd)
}

// A pidfd says only that the process has ended, and has nothing to take.
@(private)
process_watched :: proc(watch: posix.FD) {}

@(private)
process_pipe :: proc(fds: ^[2]posix.FD) -> bool {
	errno := linux.pipe2((^[2]linux.Fd)(fds), {.CLOEXEC})
	if errno != nil {
		posix.errno(posix.Errno(errno))
		return false
	}
	return true
}

// A pipe here raises SIGPIPE in the thread that wrote, which process_write holds back.
@(private)
process_nosigpipe :: proc(fd: posix.FD) {}

@(private)
process_terminal_name :: proc(master: posix.FD, name: []byte) -> bool {
	if errno := ptsname_r(master, raw_data(name), len(name)); errno != 0 {
		posix.errno(posix.Errno(errno))
		return false
	}
	return true
}

@(private)
process_ioctl :: proc(fd: posix.FD, request: u32, arg: rawptr) -> bool {
	return int(linux.ioctl(linux.Fd(fd), request, uintptr(arg))) >= 0
}

// The most descriptors this process could have, for a kernel without close_range (before 5.9).
@(private)
process_fd_limit :: proc() -> posix.FD {
	limit: posix.rlimit
	if posix.getrlimit(.NOFILE, &limit) != .OK || limit.rlim_cur > 1 << 20 {
		return 1 << 20
	}
	return posix.FD(limit.rlim_cur)
}

// In the child: closes every descriptor from `lowest` on.
@(private)
process_close_from :: proc(lowest, most: posix.FD) {
	if linux.close_range(linux.Fd(lowest), max(linux.Fd), {}) == nil {
		return
	}
	for fd in lowest ..< most {
		posix.close(fd)
	}
}
