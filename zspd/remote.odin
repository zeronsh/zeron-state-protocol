package main

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"
import "../host"
import "../zsp"

// Calls joined to this process's standard input and output: a TCP port there (connect, zsp.tcp), a command (exec,
// zsp.exec), a terminal (terminal, zsp.pty). Input is read only while the call has credit for it, and what comes back
// is credited only once it has been written: a slow reader here slows the writer there, and the other way about.
//
// A command's output and errors stay apart, and its exit is this process's: its code, or 128 and the signal that ended
// it. Signals this process is sent go on to it. A terminal is raw while it is used, every key going there as typed,
// Ctrl-C among them, and is put back as it was however this ends; its size goes there at the start and whenever it
// changes.

FAILED_EXIT :: 255 // what exec and terminal exit with when the command could not be run, or its call failed

Remote_Kind :: enum {
	Tcp,
	Exec,
	Terminal,
}

Remote :: struct {
	using handler: host.Call_Handler,
	c:          ^Client,
	kind:       Remote_Kind,
	device:     zsp.Key32,
	scope:      zsp.Scope,
	first:      []byte, // the call's first message
	call:       u64,
	input:      Input,
	output:     Output,
	queued:     [dynamic][]byte, // messages that wait for credit, owned
	answered:   bool, // the status came
	refused:    bool, // and it was a failure
	input_over: bool, // standard input has ended: End follows what is queued
	said_end:   bool,
	heard_end:  bool,
	over:       bool, // the call failed, or was given up
	exited:     bool, // the command did, with this
	code:       int, // what this process exits with
	why:        string, // what to say of a failure, once the terminal is itself again
	done:       bool,
	rows, cols: u16,
}

// zspd connect <dir> <device> <port> [host] [--scope=N]
connect :: proc(dir: string, args: []string) -> int {
	line, ok := command_line(args, {.Scope}, 3)
	if !ok || len(line.words) < 2 || len(line.words) > 3 {
		return usage()
	}
	port, parsed := strconv.parse_u64(line.words[1])
	if !parsed || port == 0 || port > 65535 {
		return usage()
	}
	device, found := device_named(dir, line.words[0])
	if !found {
		return 1
	}
	r := new(Remote)
	r.kind, r.scope, r.code, r.device = .Tcp, line.scope, 1, device
	target := line.words[2] if len(line.words) == 3 else ""
	r.first = make([]byte, 2 + len(target))
	r.first[0], r.first[1] = u8(port >> 8), u8(port)
	copy(r.first[2:], target)
	return remote(dir, r)
}

// zspd exec <dir> <device> [--scope=N] [--cwd=DIR] [--env=NAME=value ...] -- <argv...>
exec :: proc(dir: string, args: []string) -> int {
	line, ok := command_line(args, {.Scope, .Cwd, .Env, .Argv}, 1)
	if !ok || len(line.words) != 1 || len(line.argv) == 0 {
		return usage()
	}
	device, found := device_named(dir, line.words[0])
	if !found {
		return FAILED_EXIT
	}
	r := new(Remote)
	r.kind, r.scope, r.code, r.device = .Exec, line.scope, FAILED_EXIT, device
	w := make([dynamic]byte)
	append(&w, 0) // flags, none yet
	command_tail(&w, line.argv, line.env[:], line.cwd)
	r.first = w[:]
	return remote(dir, r)
}

// zspd terminal <dir> <device> [--scope=N]
terminal :: proc(dir: string, args: []string) -> int {
	line, ok := command_line(args, {.Scope}, 1)
	if !ok || len(line.words) != 1 {
		return usage()
	}
	if !console_is_terminal() {
		say(os.stderr, "a terminal there wants one here\n")
		return FAILED_EXIT
	}
	device, found := device_named(dir, line.words[0])
	if !found {
		return FAILED_EXIT
	}
	r := new(Remote)
	r.kind, r.scope, r.code, r.device = .Terminal, line.scope, FAILED_EXIT, device
	r.rows, r.cols = 24, 80
	if rows, cols, sized := terminal_size(); sized {
		r.rows, r.cols = rows, cols
	}
	term := os.get_env("TERM", context.temp_allocator)
	w := make([dynamic]byte)
	append(&w, u8(r.rows >> 8), u8(r.rows), u8(r.cols >> 8), u8(r.cols))
	zsp.write_bytes(&w, transmute([]byte)(term if term != "" else "xterm-256color"))
	command_tail(&w, nil, nil, "") // the user's shell, as it would be at a login
	r.first = w[:]
	return remote(dir, r)
}

// What zsp.exec and zsp.pty share: arguments, environment, folder.
@(private = "file")
command_tail :: proc(w: ^[dynamic]byte, argv, env: []string, cwd: string) {
	zsp.write_varint(w, u64(len(argv)))
	for a in argv {
		zsp.write_bytes(w, transmute([]byte)a)
	}
	zsp.write_varint(w, u64(len(env)))
	for e in env {
		zsp.write_bytes(w, transmute([]byte)e)
	}
	zsp.write_bytes(w, transmute([]byte)cwd)
}

@(private = "file")
terminal_saved: Terminal_State
@(private = "file")
terminal_is_raw: bool

@(private = "file")
remote :: proc(dir: string, r: ^Remote) -> int {
	c := new(Client)
	r.c = c
	c.data, c.target = r, r.device
	r.data = r
	r.on_data = remote_on_data
	r.on_end = remote_on_end
	r.on_fault = remote_on_fault
	r.on_room = proc(h: ^host.Call_Handler, call: u64) {
		remote_pump((^Remote)(h.data))
	}
	c.begin = proc(c: ^Client) {
		r := (^Remote)(c.data)
		if r.over {
			return // given up on already
		}
		method := [Remote_Kind]string{.Tcp = "zsp.tcp", .Exec = "zsp.exec", .Terminal = "zsp.pty"}
		r.call = client_call(c, r.device, r.scope, method[r.kind], r.first, &r.handler)
		if r.call == 0 {
			r.why = "it cannot be called"
			remote_over(r)
		}
	}
	c.settle = remote_settle
	if !client_open(c, dir) {
		say(os.stderr, c.failure, "\n")
		return r.code
	}
	console_quiet_pipes()
	// Before any thread begins, so that every thread leaves them to the one that waits for them.
	switch r.kind {
	case .Tcp:
	case .Exec:
		signals_catch({SIGNAL_HANGUP, SIGNAL_INTERRUPT, SIGNAL_QUIT, SIGNAL_TERMINATE})
	case .Terminal:
		signals_catch({SIGNAL_HANGUP, SIGNAL_INTERRUPT, SIGNAL_QUIT, SIGNAL_TERMINATE, SIGNAL_RESIZE})
	}
	r.input = {data = r, room = remote_input_room, take = remote_input_take, ended = remote_input_ended}
	output_start(&r.output)
	input_start(&r.input, r.kind == .Terminal)
	if r.kind == .Terminal {
		saved, raw := terminal_raw()
		if !raw {
			say(os.stderr, "the terminal here cannot be made raw\n")
			return r.code
		}
		terminal_saved, terminal_is_raw = saved, true
		// Put back as it was, however this ends: a failed assertion included.
		context.assertion_failure_proc = proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
			if terminal_is_raw {
				terminal_restore(&terminal_saved)
			}
			runtime.default_assertion_failure_proc(prefix, message, loc)
		}
	}
	ok := client_run(c)
	output_drain(&r.output) // what came, all of it, before this ends
	if terminal_is_raw {
		terminal_restore(&terminal_saved)
		terminal_is_raw = false
	}
	if !ok {
		say(os.stderr, c.failure, "\n")
	} else if r.why != "" {
		say(os.stderr, r.why, "\n")
	}
	return r.code
}

// ---------------------------------------------------------------- the call's side

@(private = "file")
remote_on_data :: proc(h: ^host.Call_Handler, call: u64, bytes: []byte) -> bool {
	r := (^Remote)(h.data)
	if !r.answered {
		r.answered = true
		if len(bytes) == 0 || bytes[0] != 0 {
			// Statuses of zsp.tcp, zsp.exec and zsp.pty are numbered alike.
			r.refused = true
			r.why = strings.clone(status_said(bytes)) // said once the loop is done, and its temporary memory with it
			client_end(r.c, call)
			return true
		}
		input_resume(&r.input)
		return true
	}
	if r.refused || r.over {
		return true
	}
	if r.kind == .Tcp {
		output_put(&r.output, .Stdout, bytes, len(bytes))
		return false
	}
	if len(bytes) == 0 {
		return true
	}
	switch bytes[0] {
	case 1:
		output_put(&r.output, .Stdout, bytes[1:], len(bytes))
		return false
	case 2:
		output_put(&r.output, .Stderr, bytes[1:], len(bytes))
		return false
	case 3:
		reader := zsp.Reader{buf = bytes[1:]}
		code := zsp.read_varint(&reader)
		signal := zsp.read_u8(&reader)
		r.exited = true
		r.code = 128 + int(signal) if signal != 0 else int(code & 0xffff_ffff)
		input_stop(&r.input)
	}
	return true
}

@(private = "file")
remote_on_end :: proc(h: ^host.Call_Handler, call: u64) {
	r := (^Remote)(h.data)
	r.heard_end = true
	if r.kind == .Tcp {
		output_close(&r.output) // a half-close, there and so here
	}
}

@(private = "file")
remote_on_fault :: proc(h: ^host.Call_Handler, call: u64, fault: zsp.Call_Fault) {
	r := (^Remote)(h.data)
	if r.c.phase != .Closed && r.why == "" {
		r.why = fault_text(fault)
	}
	remote_over(r)
}

// The call is over, badly: nothing more is read, and this ends once what came has been written.
@(private = "file")
remote_over :: proc(r: ^Remote) {
	r.over = true
	if !r.exited {
		r.code = 1 if r.kind == .Tcp else FAILED_EXIT
	}
	input_stop(&r.input)
}

// Sends what waits, as credit allows; then End, once input is over; then reads on.
@(private = "file")
remote_pump :: proc(r: ^Remote) {
	for len(r.queued) > 0 {
		if !client_send(r.c, r.call, r.queued[0]) {
			return
		}
		delete(r.queued[0])
		ordered_remove(&r.queued, 0)
	}
	if r.input_over && !r.said_end && client_calling(r.c, r.call) {
		r.said_end = true
		client_end(r.c, r.call)
	}
	input_resume(&r.input)
}

// Sends a message now if credit allows, or once it does, after whatever waits already.
@(private = "file")
remote_say :: proc(r: ^Remote, message: []byte) {
	if len(r.queued) == 0 && client_send(r.c, r.call, message) {
		return
	}
	kept := make([]byte, len(message))
	copy(kept, message)
	append(&r.queued, kept)
}

// ---------------------------------------------------------------- this process's side

@(private = "file")
remote_input_room :: proc(data: rawptr) -> int {
	r := (^Remote)(data)
	if !r.answered || r.refused || r.over || r.input_over || r.said_end || len(r.queued) > 0 {
		return 0
	}
	return client_room(r.c, r.call) - (0 if r.kind == .Tcp else 1)
}

@(private = "file")
remote_input_take :: proc(data: rawptr, bytes: []byte) {
	r := (^Remote)(data)
	if r.kind == .Tcp {
		remote_say(r, bytes)
		return
	}
	message := make([]byte, 1 + len(bytes), context.temp_allocator)
	message[0] = 0 // input
	copy(message[1:], bytes)
	remote_say(r, message)
}

@(private = "file")
remote_input_ended :: proc(data: rawptr) {
	r := (^Remote)(data)
	r.input_over = true
	remote_pump(r)
}

// After every turn of the loop: what was written, read and caught meanwhile; and whether all is done.
@(private = "file")
remote_settle :: proc(c: ^Client) {
	r := (^Remote)(c.data)
	if owed := output_owed(&r.output); owed > 0 {
		client_consumed(c, r.call, owed)
	}
	input_settle(&r.input)
	caught := signals_take()
	if SIGNAL_RESIZE in caught && r.answered && !r.said_end {
		if rows, cols, sized := terminal_size(); sized && (rows != r.rows || cols != r.cols) {
			r.rows, r.cols = rows, cols
			remote_say(r, {2, u8(rows >> 8), u8(rows), u8(cols >> 8), u8(cols)})
		}
	}
	for signal in ([]int{SIGNAL_HANGUP, SIGNAL_INTERRUPT, SIGNAL_QUIT, SIGNAL_TERMINATE}) {
		if signal not_in caught || r.done {
			continue
		}
		// A terminal's own keys signal what runs in it; whoever ends or hangs up on this ends it. A command is sent
		// whatever this is sent, while it can be; once its input is over, or before it has begun, it is ended.
		forward := r.answered && !r.refused && !r.over && !r.said_end
		forward &&= r.kind == .Exec || signal == SIGNAL_INTERRUPT || signal == SIGNAL_QUIT
		if forward {
			remote_say(r, {1, u8(signal)})
			continue
		}
		client_cancel(c, r.call)
		r.code = 128 + signal
		r.exited = true
		remote_over(r)
	}
	if output_broken(&r.output) && !r.over {
		client_cancel(c, r.call)
		r.why = "standard output is closed"
		remote_over(r)
		r.code = 128 + 13 if r.kind == .Exec else r.code // as a broken pipe would end it
	}
	remote_check(r)
}

// Whether all is done: the call over, and all it said written.
@(private = "file")
remote_check :: proc(r: ^Remote) {
	if r.done || !output_idle(&r.output) {
		return
	}
	switch {
	case r.over:
	case r.refused:
		if !r.heard_end {
			return
		}
	case r.kind == .Tcp:
		if !r.said_end || !r.heard_end {
			return
		}
		r.code = 0
	case:
		if !r.exited || !r.heard_end {
			return
		}
		if !r.said_end {
			r.said_end = true
			client_end(r.c, r.call)
		}
	}
	r.done = true
	input_stop(&r.input)
	client_stop(r.c)
}
