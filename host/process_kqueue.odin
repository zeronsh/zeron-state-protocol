#+build darwin, freebsd, netbsd, openbsd
package host

import "core:c"
import "core:sys/posix"
import kq "core:sys/kqueue"

// The BSDs' and macOS's part of process_posix.odin. A process's end is waited on through a kqueue of its own, which
// holds only that process's NOTE_EXIT: a kqueue is itself readable while it has an event to give, so the event loop
// polls it as it would a pipe, and no thread waits on anyone's behalf. (The loop's own kqueue is nbio's, which takes
// every event it gives for one of its operations.)

PROCESS_TIOCSWINSZ :: 0x80087467
PROCESS_TIOCSCTTY :: 0x20007461

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

@(private)
foreign libc {
	ioctl :: proc(fd: posix.FD, request: c.ulong, #c_vararg args: ..any) -> c.int ---
	ptsname_r :: proc(fd: posix.FD, buf: [^]byte, size: c.size_t) -> c.int ---
}

when ODIN_OS == .Darwin {
	@(private)
	foreign libc {
		getdtablesize :: proc() -> c.int ---
	}
} else {
	@(private)
	foreign libc {
		closefrom :: proc(lowfd: c.int) ---
		pipe2 :: proc(fds: ^[2]posix.FD, flags: posix.O_Flags) -> posix.result ---
	}
}

// Readable once the process has ended.
@(private)
process_watch :: proc(pid: posix.pid_t) -> posix.FD {
	q, err := kq.kqueue()
	if err != nil {
		return -1
	}
	exit := [1]kq.KEvent{{ident = uintptr(pid), filter = .Proc, flags = {.Add, .One_Shot}, fflags = {fproc = {.Exit}}}}
	zero: posix.timespec
	if _, kerr := kq.kevent(q, exit[:], nil, &zero); kerr != nil {
		if kerr != .ESRCH {
			posix.close(q)
			posix.errno(kerr)
			return -1
		}
		// Gone already, and only waits to be reaped: the kqueue is made readable at once instead.
		now := [1]kq.KEvent{{ident = 0, filter = .User, flags = {.Add, .One_Shot}, fflags = {user = {.Trigger}}}}
		if _, uerr := kq.kevent(q, now[:], nil, &zero); uerr != nil {
			posix.close(q)
			posix.errno(uerr)
			return -1
		}
	}
	return q
}

// Takes what the kqueue has, so that it is not readable for ever.
@(private)
process_watched :: proc(watch: posix.FD) {
	events: [2]kq.KEvent
	zero: posix.timespec
	kq.kevent(watch, nil, events[:], &zero)
}

@(private)
process_pipe :: proc(fds: ^[2]posix.FD) -> bool {
	when ODIN_OS == .Darwin {
		// macOS has no pipe2: another thread's fork may come between, but every child of this one closes what it
		// has beyond its stdio.
		if posix.pipe(fds) != .OK {
			return false
		}
		posix.fcntl(fds[0], .SETFD, i32(posix.FD_CLOEXEC))
		posix.fcntl(fds[1], .SETFD, i32(posix.FD_CLOEXEC))
		return true
	} else {
		return pipe2(fds, {.CLOEXEC}) == .OK
	}
}

// macOS raises SIGPIPE in the process rather than the thread, where no mask of the writer's could hold it back:
// so a pipe written here is told not to raise it at all.
@(private)
process_nosigpipe :: proc(fd: posix.FD) {
	when ODIN_OS == .Darwin {
		F_SETNOSIGPIPE :: 73
		posix.fcntl(fd, posix.FCNTL_Cmd(F_SETNOSIGPIPE), c.int(1))
	}
}

@(private)
process_terminal_name :: proc(master: posix.FD, name: []byte) -> bool {
	if errno := ptsname_r(master, raw_data(name), len(name)); errno != 0 {
		return false
	}
	return true
}

@(private)
process_ioctl :: proc(fd: posix.FD, request: u32, arg: rawptr) -> bool {
	return ioctl(fd, c.ulong(request), arg) >= 0
}

@(private)
process_fd_limit :: proc() -> posix.FD {
	when ODIN_OS == .Darwin {
		return posix.FD(getdtablesize()) // the lesser of the limit and what the kernel allows a process
	} else {
		return 0 // closefrom needs none
	}
}

// In the child: closes every descriptor from `lowest` on.
@(private)
process_close_from :: proc(lowest, most: posix.FD) {
	when ODIN_OS == .Darwin {
		for fd in lowest ..< most {
			posix.close(fd)
		}
	} else {
		closefrom(c.int(lowest))
	}
}
