#+build !windows
package host

import "core:c"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:sys/posix"

// A process on Linux, macOS or FreeBSD: a session and process group of its own, its pipes or its terminal made
// non-blocking and waited on through the event loop, and a descriptor that becomes readable once it has ended (a
// pidfd on Linux, a kqueue of its own elsewhere: see process_linux.odin and process_kqueue.odin), so that nothing
// here waits but the loop.

Process :: struct {
	events:   Process_Events,
	pid:      posix.pid_t, // and its group's
	pty:      bool,
	master:   posix.FD, // the terminal; -1 for pipes
	input:    posix.FD, // its stdin, or the terminal; -1 once closed
	output:   [2]posix.FD, // its stdout (or the terminal) and stderr; -1 once all is read
	watch:    posix.FD, // readable once it has ended; -1 once reaped
	read_ops: [2]^nbio.Operation,
	write_op: ^nbio.Operation,
	watch_op: ^nbio.Operation,
	held:     [dynamic]byte, // input not yet written
	written:  int, // of held
	reading:  bool, // output is wanted
	pulling:  [2]bool, // reading now, which a callback may come back into
	ending:   bool, // no more input will come: stdin is closed once what is held is written
	reaped:   bool,
	exit:     Exit,
	told:     bool, // on_exit
	telling:  int, // callbacks under way
	freed:    bool, // let go of while telling: freed once that is over
}

// What the child is to do between fork and exec, made ready before the fork, for nothing may be allocated after.
@(private)
Process_Child :: struct {
	path:   cstring,
	argv:   [^]cstring,
	envp:   [^]cstring,
	dir:    cstring,
	stdio:  [3]posix.FD,
	report: posix.FD, // where it says why it could not exec; closed by the exec when it can
	pty:    bool,
	most:   posix.FD, // above every descriptor it could have
}

// What failed in the child, as it reports it.
@(private)
Process_Stage :: enum i32 {
	Setup,
	Dir,
	Exec,
}

process_start :: proc(spec: Process_Spec, events: Process_Events) -> (p: ^Process, err: string) {
	argv := spec.argv
	if len(argv) == 0 {
		// A login shell, which a terminal's is told it is by the dash before its name.
		shell := process_shell()
		login := make([]string, 1, context.temp_allocator)
		login[0] = shell
		if spec.pty {
			login[0] = strings.concatenate({"-", shell[strings.last_index_byte(shell, '/') + 1:]}, context.temp_allocator)
		}
		return process_spawn(spec, events, shell, login)
	}
	path := argv[0]
	if path == "" {
		return nil, "no program given"
	}
	if strings.index_byte(path, '/') < 0 {
		found, missing := process_find(path, process_env_value(spec, "PATH"))
		if missing != "" {
			return nil, missing
		}
		path = found
	}
	return process_spawn(spec, events, path, argv)
}

@(private)
process_spawn :: proc(spec: Process_Spec, events: Process_Events, path: string, argv: []string) -> (p: ^Process, err: string) {
	child: Process_Child
	child.path = strings.clone_to_cstring(path, context.temp_allocator)
	args := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv {
		args[i] = strings.clone_to_cstring(a, context.temp_allocator)
	}
	child.argv = raw_data(args)
	child.envp = process_environment(spec)
	dir := spec.dir if spec.dir != "" else process_home()
	child.dir = strings.clone_to_cstring(dir, context.temp_allocator)
	child.pty = spec.pty
	child.most = process_fd_limit()

	// The parent's ends, and the child's.
	mine := [3]posix.FD{-1, -1, -1}
	theirs := [3]posix.FD{-1, -1, -1}
	master: posix.FD = -1
	defer if err != "" {
		for fd in mine {
			if fd >= 0 && fd != master {
				posix.close(fd)
			}
		}
		if master >= 0 {
			posix.close(master)
		}
	}
	defer for fd, i in theirs {
		if fd >= 0 && (i == 0 || fd != theirs[0]) {
			posix.close(fd)
		}
	}
	if spec.pty {
		slave: posix.FD
		failed: string
		master, slave, failed = process_terminal(spec.rows, spec.cols)
		if failed != "" {
			return nil, failed
		}
		mine = {master, master, -1}
		theirs = {slave, slave, slave}
	} else {
		for i in 0 ..< 3 {
			fds: [2]posix.FD
			if !process_pipe(&fds) {
				return nil, process_error("cannot make a pipe: ", posix.errno())
			}
			// stdin is written here and read there; the others the other way.
			if i == 0 {
				mine[i], theirs[i] = fds[1], fds[0]
			} else {
				mine[i], theirs[i] = fds[0], fds[1]
			}
		}
		process_nosigpipe(mine[0])
	}
	child.stdio = theirs

	report: [2]posix.FD
	if !process_pipe(&report) {
		return nil, process_error("cannot make a pipe: ", posix.errno())
	}
	child.report = report[1]

	// No handler of this process may run in the child before it execs: signals wait until the child has put
	// them back as they were before this process changed them.
	all, old: posix.sigset_t
	posix.sigfillset(&all)
	posix.pthread_sigmask(.SETMASK, &all, &old)
	pid := posix.fork()
	if pid == 0 {
		process_child(&child)
	}
	fork_errno := posix.errno()
	posix.pthread_sigmask(.SETMASK, &old, nil)
	posix.close(report[1])
	if pid < 0 {
		posix.close(report[0])
		return nil, process_error("cannot start a process: ", fork_errno)
	}

	// Closed by the exec, or written first if there is none: so this waits only as long as the child takes to
	// exec, which is no time.
	failure: [2]i32
	got := 0
	for got < size_of(failure) {
		n := posix.read(report[0], ([^]byte)(&failure)[got:], c.size_t(size_of(failure) - got))
		if n < 0 && posix.errno() == .EINTR {
			continue
		}
		if n <= 0 {
			break
		}
		got += int(n)
	}
	posix.close(report[0])
	if got == size_of(failure) {
		process_wait(pid)
		errno := posix.Errno(failure[1])
		switch Process_Stage(failure[0]) {
		case .Dir:
			if errno == .ENOENT || errno == .ENOTDIR {
				return nil, strings.concatenate({"no such directory: ", dir}, context.temp_allocator)
			}
			return nil, process_error(strings.concatenate({"cannot enter ", dir, ": "}, context.temp_allocator), errno)
		case .Exec:
			#partial switch errno {
			case .ENOENT:
				return nil, strings.concatenate({"no such program: ", argv[0]}, context.temp_allocator)
			case .EACCES:
				return nil, strings.concatenate({"permission denied: ", argv[0]}, context.temp_allocator)
			case .ENOEXEC:
				return nil, strings.concatenate({"not a program: ", argv[0]}, context.temp_allocator)
			}
			return nil, process_error(strings.concatenate({"cannot run ", argv[0], ": "}, context.temp_allocator), errno)
		case .Setup:
		}
		return nil, process_error("cannot start a process: ", errno)
	}

	watch := process_watch(pid)
	if watch < 0 {
		watch_errno := posix.errno()
		posix.kill(-pid, .SIGKILL)
		process_wait(pid)
		return nil, process_error("cannot watch a process: ", watch_errno)
	}
	for fd in mine {
		if fd >= 0 {
			process_nonblocking(fd)
		}
	}

	p = new(Process)
	p.events = events
	p.pid = pid
	p.pty = spec.pty
	p.master = master
	p.input = mine[0]
	p.output = {mine[1], mine[2]}
	p.watch = watch
	p.reading = true
	// Not read at once, but once the loop says there is something: no callback may come before this returns.
	process_listen(p, 0)
	process_listen(p, 1)
	process_await(p)
	return p, ""
}

process_read :: proc(p: ^Process, want: bool) {
	if p.freed {
		return
	}
	// A poll that fires while output is not wanted reads nothing, and is not made again until it is.
	p.reading = want
	if want {
		process_listen(p, 0)
		process_listen(p, 1)
	}
}

process_input :: proc(p: ^Process, bytes: []byte) -> int {
	if p.freed || p.input < 0 || p.ending || len(bytes) == 0 {
		return 0
	}
	taken := 0
	if p.written == len(p.held) && p.write_op == nil {
		// Straight through, as much as it takes now.
		n, errno := process_write(p.input, bytes)
		if errno != nil && errno != .EAGAIN && errno != .EWOULDBLOCK {
			process_input_close(p) // its stdin is gone, or the terminal is
			return 0
		}
		taken = n
	}
	more := min(len(bytes) - taken, process_input_room(p))
	append(&p.held, ..bytes[taken:][:more])
	taken += more
	if p.written < len(p.held) && p.write_op == nil {
		process_await_room(p)
	}
	return taken
}

process_input_room :: proc(p: ^Process) -> int {
	if p.freed || p.input < 0 || p.ending {
		return 0
	}
	return PROCESS_INPUT - (len(p.held) - p.written)
}

process_end_input :: proc(p: ^Process) {
	if p.freed || p.pty || p.ending {
		return
	}
	p.ending = true
	if p.written == len(p.held) {
		process_input_close(p)
	}
}

process_signal :: proc(p: ^Process, s: Signal) {
	if p.freed || !process_running(p) {
		return
	}
	group := p.pid
	if p.pty && (s == .Interrupt || s == .Quit) {
		// As the terminal would: to whatever is in its foreground, which a shell's job may be.
		if foreground := posix.tcgetpgrp(p.master); foreground > 0 {
			group = foreground
		}
	}
	posix.kill(-group, process_signal_number(s))
}

process_resize :: proc(p: ^Process, rows, cols: u16) {
	if p.freed || p.master < 0 {
		return
	}
	process_winsize(p.master, rows, cols)
}

process_free :: proc(p: ^Process) {
	if p == nil || p.freed {
		return
	}
	p.freed = true
	p.events = {}
	if process_running(p) {
		posix.kill(-p.pid, .SIGKILL)
	}
	// What waits on a descriptor is taken back before it is closed.
	for &op in p.read_ops {
		if op != nil {
			nbio.remove(op)
			op = nil
		}
	}
	if p.write_op != nil {
		nbio.remove(p.write_op)
		p.write_op = nil
	}
	if p.watch_op != nil {
		nbio.remove(p.watch_op)
		p.watch_op = nil
	}
	if !p.reaped {
		process_wait(p.pid) // killed: it ends as soon as the kernel gets to it
		p.reaped = true
	}
	if p.watch >= 0 {
		posix.close(p.watch)
		p.watch = -1
	}
	if !p.pty {
		for &fd in p.output {
			if fd >= 0 {
				posix.close(fd)
				fd = -1
			}
		}
		if p.input >= 0 {
			posix.close(p.input)
		}
	}
	p.input = -1
	p.output = {-1, -1}
	if p.master >= 0 {
		posix.close(p.master)
		p.master = -1
	}
	if p.telling == 0 {
		process_release(p)
	}
}

@(private)
process_release :: proc(p: ^Process) {
	delete(p.held)
	free(p)
}

// Whether p is still wanted after its owner was told something: one let go of meanwhile is freed once nothing here
// is in the middle of telling it anything.
@(private)
process_told :: proc(p: ^Process) -> bool {
	p.telling -= 1
	if !p.freed {
		return true
	}
	if p.telling == 0 {
		process_release(p)
	}
	return false
}

// Whether anything of its group may still be there to signal. Once the process itself is reaped its group id may be
// taken by another, but not while any of its group lives on, which one holding its output open is taken to do.
@(private)
process_running :: proc(p: ^Process) -> bool {
	return !p.reaped || p.output[0] >= 0 || p.output[1] >= 0
}

// ---------------------------------------------------------------- output

@(private)
process_listen :: proc(p: ^Process, i: int) {
	if !p.reading || p.output[i] < 0 || p.read_ops[i] != nil || p.pulling[i] {
		return
	}
	p.read_ops[i] = nbio.poll_poly2(net.TCP_Socket(p.output[i]), .Receive, p, i, proc(op: ^nbio.Operation, p: ^Process, i: int) {
		p.read_ops[i] = nil
		process_pull(p, i)
	})
}

// Reads what there is while it is wanted, a turn's worth, and tells it.
@(private)
process_pull :: proc(p: ^Process, i: int) {
	buf: [PROCESS_READ]byte
	p.pulling[i] = true
	for _ in 0 ..< 16 {
		if !p.reading {
			p.pulling[i] = false
			return
		}
		n := posix.read(p.output[i], raw_data(buf[:]), len(buf))
		if n < 0 {
			errno := posix.errno()
			if errno == .EINTR {
				continue
			}
			p.pulling[i] = false
			if errno == .EAGAIN || errno == .EWOULDBLOCK {
				process_listen(p, i)
			} else {
				process_eof(p, i) // a terminal nobody holds any more says EIO, which is its end
			}
			return
		}
		if n == 0 {
			p.pulling[i] = false
			process_eof(p, i)
			return
		}
		p.telling += 1
		p.events.on_output(p.events.data, Output_Stream(i + 1), buf[:n])
		if !process_told(p) {
			return
		}
	}
	// Others have a turn; this goes on at once after.
	p.pulling[i] = false
	process_listen(p, i)
}

@(private)
process_eof :: proc(p: ^Process, i: int) {
	if !p.pty {
		posix.close(p.output[i])
	}
	p.output[i] = -1
	process_check_done(p)
}

@(private)
process_check_done :: proc(p: ^Process) {
	if p.told || !p.reaped || p.output[0] >= 0 || p.output[1] >= 0 {
		return
	}
	p.told = true
	if p.events.on_exit != nil {
		p.telling += 1
		p.events.on_exit(p.events.data, p.exit)
		process_told(p)
	}
}

// ---------------------------------------------------------------- input

@(private)
process_await_room :: proc(p: ^Process) {
	p.write_op = nbio.poll_poly(net.TCP_Socket(p.input), .Send, p, proc(op: ^nbio.Operation, p: ^Process) {
		p.write_op = nil
		process_flush(p)
	})
}

@(private)
process_flush :: proc(p: ^Process) {
	for p.written < len(p.held) {
		n, errno := process_write(p.input, p.held[p.written:])
		p.written += n
		if errno == .EAGAIN || errno == .EWOULDBLOCK {
			process_await_room(p)
			return
		}
		if errno != nil {
			process_input_close(p) // what was held for it never will be taken
			return
		}
	}
	clear(&p.held)
	p.written = 0
	if cap(p.held) > 64 << 10 {
		shrink(&p.held)
	}
	if p.ending {
		process_input_close(p)
		return
	}
	if p.events.on_room != nil {
		p.telling += 1
		p.events.on_room(p.events.data)
		process_told(p)
	}
}

@(private)
process_input_close :: proc(p: ^Process) {
	if p.input < 0 {
		return
	}
	if p.write_op != nil {
		nbio.remove(p.write_op)
		p.write_op = nil
	}
	if !p.pty {
		posix.close(p.input)
	}
	p.input = -1
	delete(p.held)
	p.held = nil
	p.written = 0
}

// Writes what a pipe or terminal takes now. A pipe whose reader has gone says EPIPE, and would raise SIGPIPE too,
// which ends a process that has not said otherwise: so the signal is held back while writing, and taken back if
// the write raised it. On macOS the pipe itself is told not to raise it (process_nosigpipe), and there this is a
// plain write.
@(private)
process_write :: proc(fd: posix.FD, bytes: []byte) -> (int, posix.Errno) {
	when ODIN_OS == .Darwin {
		for {
			n := posix.write(fd, raw_data(bytes), len(bytes))
			if n >= 0 {
				return int(n), nil
			}
			if errno := posix.errno(); errno != .EINTR {
				return 0, errno
			}
		}
	} else {
		pipe, old: posix.sigset_t
		posix.sigemptyset(&pipe)
		posix.sigaddset(&pipe, .SIGPIPE)
		posix.pthread_sigmask(.BLOCK, &pipe, &old)
		defer posix.pthread_sigmask(.SETMASK, &old, nil)
		for {
			n := posix.write(fd, raw_data(bytes), len(bytes))
			if n >= 0 {
				return int(n), nil
			}
			errno := posix.errno()
			if errno == .EINTR {
				continue
			}
			if errno == .EPIPE && posix.sigismember(&old, .SIGPIPE) == 0 {
				// Raised by this write, to this thread, which held it back: taken now, so it never arrives.
				pending: posix.sigset_t
				posix.sigpending(&pending)
				if posix.sigismember(&pending, .SIGPIPE) == 1 {
					taken: posix.Signal
					posix.sigwait(&pipe, &taken)
				}
			}
			return 0, errno
		}
	}
}

// ---------------------------------------------------------------- the end

@(private)
process_await :: proc(p: ^Process) {
	p.watch_op = nbio.poll_poly(net.TCP_Socket(p.watch), .Receive, p, proc(op: ^nbio.Operation, p: ^Process) {
		p.watch_op = nil
		process_reap(p)
	})
}

@(private)
process_reap :: proc(p: ^Process) {
	process_watched(p.watch)
	status: c.int
	r := posix.waitpid(p.pid, &status, {.NOHANG})
	for r < 0 && posix.errno() == .EINTR {
		r = posix.waitpid(p.pid, &status, {.NOHANG})
	}
	if r == 0 {
		process_await(p) // not yet, after all
		return
	}
	switch {
	case r != p.pid:
		p.exit = {code = -1} // reaped by someone else, who knows how it ended
	case posix.WIFEXITED(status):
		p.exit = {code = int(posix.WEXITSTATUS(status))}
	case:
		// Ended by a signal, for it was not asked about stops. (core:sys/posix's WIFSIGNALED is true of an exit
		// on Linux, so it is not asked.)
		signal := int(posix.WTERMSIG(status))
		p.exit = {code = 128 + signal, signal = signal} // its code as a shell would say it
	}
	p.reaped = true
	posix.close(p.watch)
	p.watch = -1
	process_check_done(p)
}

// Reaps a child that has ended or is about to, waiting for it.
@(private)
process_wait :: proc(pid: posix.pid_t) {
	status: c.int
	for posix.waitpid(pid, &status, {}) < 0 && posix.errno() == .EINTR {
	}
}

// ---------------------------------------------------------------- between fork and exec

// The child: async-signal-safe calls only, for any other thread of this process may have held a lock at the fork.
@(private)
process_child :: proc(child: ^Process_Child) -> ! {
	report := child.report
	// Handlers are reset by the exec, but what this process ignores would stay ignored, and its mask would stay.
	act: posix.sigaction_t
	act.sa_handler = auto_cast posix.SIG_DFL
	for sig in 1 ..< 32 {
		posix.sigaction(posix.Signal(sig), &act, nil)
	}
	none: posix.sigset_t
	posix.sigemptyset(&none)
	posix.pthread_sigmask(.SETMASK, &none, nil)

	if posix.setsid() < 0 {
		process_child_failed(report, .Setup)
	}
	// Above where they are going, so that none is overwritten before it is moved.
	stdio := child.stdio
	for &fd in stdio {
		if fd < 3 {
			fd = posix.FD(posix.fcntl(fd, .DUPFD, posix.FD(3)))
		}
	}
	if report < 3 {
		report = posix.FD(posix.fcntl(report, .DUPFD_CLOEXEC, posix.FD(3)))
	}
	if child.pty && !process_ioctl(stdio[0], PROCESS_TIOCSCTTY, nil) {
		process_child_failed(report, .Setup)
	}
	for fd, i in stdio {
		if posix.dup2(fd, posix.FD(i)) < 0 {
			process_child_failed(report, .Setup)
		}
	}
	if report != 3 {
		if posix.dup2(report, 3) < 0 {
			process_child_failed(report, .Setup)
		}
		report = 3
		posix.fcntl(report, .SETFD, i32(posix.FD_CLOEXEC))
	}
	process_close_from(4, child.most)
	if posix.chdir(child.dir) != .OK {
		process_child_failed(report, .Dir)
	}
	posix.execve(child.path, child.argv, child.envp)
	process_child_failed(report, .Exec)
}

@(private)
process_child_failed :: proc(report: posix.FD, stage: Process_Stage) -> ! {
	failure := [2]i32{i32(stage), i32(posix.errno())}
	posix.write(report, ([^]byte)(&failure), size_of(failure))
	posix._exit(127)
}

// ---------------------------------------------------------------- what it starts with

// A terminal pair, sized: the master for this process, the slave for the child.
@(private)
process_terminal :: proc(rows, cols: u16) -> (master, slave: posix.FD, err: string) {
	master = posix.posix_openpt({.RDWR, .NOCTTY})
	if master < 0 {
		return -1, -1, process_error("cannot make a terminal: ", posix.errno())
	}
	name: [128]byte
	if posix.grantpt(master) != .OK || posix.unlockpt(master) != .OK || !process_terminal_name(master, name[:]) {
		errno := posix.errno()
		posix.close(master)
		return -1, -1, process_error("cannot make a terminal: ", errno)
	}
	posix.fcntl(master, .SETFD, i32(posix.FD_CLOEXEC))
	slave = posix.open(cstring(&name[0]), {.RDWR, .NOCTTY, .CLOEXEC})
	if slave < 0 {
		errno := posix.errno()
		posix.close(master)
		return -1, -1, process_error("cannot open a terminal: ", errno)
	}
	process_winsize(master, rows if rows > 0 else 24, cols if cols > 0 else 80)
	return master, slave, ""
}

@(private)
process_winsize :: proc(fd: posix.FD, rows, cols: u16) {
	size := [4]u16{rows, cols, 0, 0} // struct winsize: rows, columns, and pixels nobody uses
	process_ioctl(fd, PROCESS_TIOCSWINSZ, &size)
}

@(private)
process_nonblocking :: proc(fd: posix.FD) {
	flags := posix.fcntl(fd, .GETFL)
	posix.fcntl(fd, .SETFL, flags | transmute(c.int)posix.O_Flags{.NONBLOCK})
}

// NAME=value from the host's environment, as the spec changes it: a name it gives alone is removed, a terminal is
// given its kind, and the last word on any name is the spec's.
@(private)
process_environment :: proc(spec: Process_Spec) -> [^]cstring {
	list := make([dynamic]cstring, context.temp_allocator)
	for i := 0; posix.environ[i] != nil; i += 1 {
		entry := string(posix.environ[i])
		name := process_env_name(entry)
		if process_env_names(spec, name) || (spec.pty && name == "TERM") {
			continue // the spec's to say, or the terminal's own kind
		}
		append(&list, posix.environ[i])
	}
	if spec.pty && !process_env_names(spec, "TERM") {
		term := spec.term if spec.term != "" else "xterm-256color"
		append(&list, strings.clone_to_cstring(strings.concatenate({"TERM=", term}, context.temp_allocator), context.temp_allocator))
	}
	for entry, i in spec.env {
		name := process_env_name(entry)
		if len(name) == len(entry) {
			continue // a removal
		}
		later := false
		for other in spec.env[i + 1:] {
			later ||= process_env_name(other) == name
		}
		if !later {
			append(&list, strings.clone_to_cstring(entry, context.temp_allocator))
		}
	}
	append(&list, nil)
	return raw_data(list)
}

@(private)
process_env_name :: proc(entry: string) -> string {
	if eq := strings.index_byte(entry, '='); eq >= 0 {
		return entry[:eq]
	}
	return entry
}

@(private)
process_env_names :: proc(spec: Process_Spec, name: string) -> bool {
	for entry in spec.env {
		if process_env_name(entry) == name {
			return true
		}
	}
	return false
}

// A variable as the child will have it.
@(private)
process_env_value :: proc(spec: Process_Spec, name: string) -> string {
	#reverse for entry in spec.env {
		if process_env_name(entry) == name {
			return entry[len(name) + 1:] if len(entry) > len(name) else ""
		}
	}
	return string(posix.getenv(strings.clone_to_cstring(name, context.temp_allocator)))
}

// Finds a program on PATH, as an absolute path, for the child starts somewhere else.
@(private)
process_find :: proc(name, path: string) -> (found: string, err: string) {
	path := path if path != "" else "/usr/bin:/bin"
	denied := false
	for dir in strings.split_iterator(&path, ":") {
		candidate := strings.concatenate({dir if dir != "" else ".", "/", name}, context.temp_allocator)
		cpath := strings.clone_to_cstring(candidate, context.temp_allocator)
		st: posix.stat_t
		if posix.stat(cpath, &st) != .OK || !posix.S_ISREG(st.st_mode) {
			continue
		}
		if posix.access(cpath, {.X_OK}) != .OK {
			denied = true
			continue
		}
		if candidate[0] != '/' {
			resolved: [4096]byte
			if posix.realpath(cpath, &resolved[0]) == nil {
				continue
			}
			candidate = strings.clone_from_cstring(cstring(&resolved[0]), context.temp_allocator)
		}
		return candidate, ""
	}
	if denied {
		return "", strings.concatenate({"permission denied: ", name}, context.temp_allocator)
	}
	return "", strings.concatenate({"no such program: ", name}, context.temp_allocator)
}

// The user's login shell: $SHELL, or what the password database says, or sh.
@(private)
process_shell :: proc() -> string {
	if shell := string(posix.getenv("SHELL")); shell != "" {
		return shell
	}
	entry: posix.passwd
	buf: [4096]byte
	found: ^posix.passwd
	if posix.getpwuid_r(posix.getuid(), &entry, &buf[0], len(buf), &found) == nil && found != nil && found.pw_shell != nil && found.pw_shell != "" {
		return strings.clone_from_cstring(found.pw_shell, context.temp_allocator)
	}
	return "/bin/sh"
}

@(private)
process_home :: proc() -> string {
	if home := string(posix.getenv("HOME")); home != "" {
		return home
	}
	entry: posix.passwd
	buf: [4096]byte
	found: ^posix.passwd
	if posix.getpwuid_r(posix.getuid(), &entry, &buf[0], len(buf), &found) == nil && found != nil && found.pw_dir != nil && found.pw_dir != "" {
		return strings.clone_from_cstring(found.pw_dir, context.temp_allocator)
	}
	return "/"
}

@(private)
process_signal_number :: proc(s: Signal) -> posix.Signal {
	switch s {
	case .Interrupt:
		return .SIGINT
	case .Hangup:
		return .SIGHUP
	case .Quit:
		return .SIGQUIT
	case .Kill:
		return .SIGKILL
	case .Terminate:
		return .SIGTERM
	case .Stop:
		return .SIGSTOP
	case .Continue:
		return .SIGCONT
	}
	return .SIGTERM
}

@(private)
process_error :: proc(what: string, errno: posix.Errno) -> string {
	return strings.concatenate({what, string(posix.strerror(errno))}, context.temp_allocator)
}
