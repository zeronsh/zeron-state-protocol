#+build !windows
package main

import "core:c"
import "core:os"
import "core:sys/posix"
import "core:thread"

when ODIN_OS == .Darwin {
	foreign import libc "system:System"
} else {
	foreign import libc "system:c"
}

@(default_calling_convention = "c")
foreign libc {
	@(private = "file")
	ioctl :: proc(fd: c.int, request: c.ulong, #c_vararg args: ..any) -> c.int ---
}

when ODIN_OS == .Linux {
	@(private = "file")
	TIOCGWINSZ :: 0x5413
} else {
	@(private = "file")
	TIOCGWINSZ :: 0x40087468
}

@(private = "file")
Winsize :: struct {
	rows, cols, x_pixels, y_pixels: u16,
}

console_stdin :: proc() -> posix.FD {
	return 0
}

// Whether standard input can be waited for by the event loop: a pipe, a socket, or a terminal. A file, or a device
// such as /dev/null, is always ready, and readiness says nothing of its end; and macOS's kqueue does not wait on
// terminals at all.
console_pollable :: proc() -> bool {
	info, err := os.fstat(os.stdin, context.temp_allocator)
	if err != nil {
		return false
	}
	#partial switch info.type {
	case .Named_Pipe, .Socket:
		return true
	case .Character_Device:
		return ODIN_OS != .Darwin && bool(posix.isatty(0))
	}
	return false
}

// One read of standard input, which waits only if nothing has come.
console_read :: proc(i: ^Input, buf: []byte) -> int {
	for {
		n := posix.read(0, raw_data(buf), len(buf))
		if n >= 0 {
			return int(n)
		}
		#partial switch posix.errno() {
		case .EINTR:
			continue
		case .EAGAIN:
			return INPUT_AGAIN
		}
		return INPUT_FAILED
	}
}

// Writes all of it, waiting as long as it takes: this is the writer's thread, and nothing else waits on it.
console_write :: proc(stream: Output_Stream, bytes: []byte) -> bool {
	fd := posix.FD(1 if stream == .Stdout else 2)
	bytes := bytes
	for len(bytes) > 0 {
		n := posix.write(fd, raw_data(bytes), len(bytes))
		if n >= 0 {
			bytes = bytes[n:]
			continue
		}
		#partial switch posix.errno() {
		case .EINTR:
			continue
		case .EAGAIN:
			// Someone made it non-blocking: wait until it takes more.
			p := posix.pollfd{fd = fd, events = {.OUT}}
			posix.poll(&p, 1, -1)
			continue
		}
		return false
	}
	return true
}

// Says there is no more: to a socket by shutting its sending side, for standard input may be the same socket (as an
// ssh ProxyCommand's may be), and closing one of the two would say nothing.
console_close_stdout :: proc() {
	posix.shutdown(1, .WR)
	posix.close(1)
}

// A broken pipe is a failed write, said as such, rather than the end of this process.
console_quiet_pipes :: proc() {
	posix.signal(.SIGPIPE, auto_cast posix.SIG_IGN)
}

console_is_terminal :: proc() -> bool {
	return bool(posix.isatty(0))
}

Terminal_State :: struct {
	saved: posix.termios,
}

// The terminal, raw: every key as it is typed, Ctrl-C and the like among them, nothing echoed or changed on the way
// in or out. Its character size and speed are left as they are.
terminal_raw :: proc() -> (state: Terminal_State, ok: bool) {
	if posix.tcgetattr(0, &state.saved) != .OK {
		return
	}
	raw := state.saved
	raw.c_iflag -= {.IGNBRK, .BRKINT, .PARMRK, .ISTRIP, .INLCR, .IGNCR, .ICRNL, .IXON}
	raw.c_oflag -= {.OPOST}
	raw.c_lflag -= {.ECHO, .ECHONL, .ICANON, .ISIG, .IEXTEN}
	raw.c_cflag -= {.PARENB}
	raw.c_cc[.VMIN] = 1
	raw.c_cc[.VTIME] = 0
	return state, posix.tcsetattr(0, .TCSADRAIN, &raw) == .OK
}

terminal_restore :: proc(state: ^Terminal_State) {
	posix.tcsetattr(0, .TCSADRAIN, &state.saved)
}

// The terminal's size, in characters.
terminal_size :: proc() -> (rows, cols: u16, ok: bool) {
	for fd in ([]c.int{0, 1}) {
		w: Winsize
		if ioctl(fd, TIOCGWINSZ, &w) == 0 && w.rows > 0 && w.cols > 0 {
			return w.rows, w.cols, true
		}
	}
	return
}

// Catches these signals from now on: they are blocked here and in every thread begun after, and a thread of their
// own waits for them, so that none interrupts anything and none is missed.
signals_catch :: proc(which: Signal_Set) {
	set: posix.sigset_t
	posix.sigemptyset(&set)
	for s in which {
		posix.sigaddset(&set, posix.Signal(s))
		// A handler that never runs, every thread blocking it: a signal whose action is to be ignored, as a resized
		// window's is, may be discarded as it comes rather than kept for sigwait, as macOS does.
		posix.signal(posix.Signal(s), proc "c" (_: posix.Signal) {})
	}
	posix.pthread_sigmask(.BLOCK, &set, nil)
	waiting := new(posix.sigset_t)
	waiting^ = set
	thread.create_and_start_with_poly_data(waiting, proc(set: ^posix.sigset_t) {
		for {
			signal: posix.Signal
			if posix.sigwait(set, &signal) == .NONE {
				signal_caught(int(signal))
			}
		}
	})
}
