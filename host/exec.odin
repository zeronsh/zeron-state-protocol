package host

import "core:strings"
import "../zsp"

// Commands (zsp.exec) and terminals (zsp.pty), run here for whoever calls, as the user this host runs as. Output is
// read only while the call has credit for it, and input credited only as the process takes it: a process whose caller
// stops reading stops at its own pipe, and one fed faster than it reads holds up its feeder.
//
//     exec: flags (1) ‖ n varint ‖ n × argument bytes ‖ m varint ‖ m × environment bytes (NAME=value) ‖ folder bytes
//     pty:  rows (2) ‖ columns (2) ‖ terminal bytes (TERM) ‖ then as exec, after the flags
//     → status, and for a failure a reason; then, tagged:
//     to it:    0 ‖ input bytes · 1 ‖ signal (1) · 2 ‖ rows (2) ‖ columns (2)        and End: no more input
//     from it:  1 ‖ output bytes · 2 ‖ error bytes · 3 ‖ code varint ‖ signal (1)    the last, then End
//
// A command's arguments are its own, never through a shell: whoever wants one asks for it. A cancelled call kills
// what was started, and all it started in turn.

@(private)
Exec :: struct {
	using handler: Call_Handler,
	sp:       ^Space,
	call:     u64,
	p:        ^Process,
	caller:   zsp.Key32,
	who:      string, // owned
	scope:    zsp.Scope,
	detail:   string, // owned
	terminal: bool,
	held:     [dynamic]byte, // input from the call that the process has not taken
	ending:   bool, // the call said all its input; the process is told once held input is taken
	exited:   bool,
	freed:    bool,
	bytes_in, bytes_out: u64,
}

@(private)
serve_exec :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	return exec_begin(sp, call, from, scope, first, false)
}

@(private)
serve_pty :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	return exec_begin(sp, call, from, scope, first, true)
}

@(private)
exec_begin :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte, terminal: bool) -> (^Call_Handler, zsp.Call_Fault) {
	r := zsp.Reader{buf = first}
	spec: Process_Spec
	if terminal {
		spec.pty = true
		spec.rows = u16(zsp.read_u8(&r)) << 8 | u16(zsp.read_u8(&r))
		spec.cols = u16(zsp.read_u8(&r)) << 8 | u16(zsp.read_u8(&r))
		spec.term = string(zsp.read_bytes(&r))
	} else {
		_ = zsp.read_u8(&r) // flags, none yet
	}
	strings_of :: proc(r: ^zsp.Reader) -> []string {
		n := zsp.read_count(r)
		out := make([]string, n, context.temp_allocator)
		for &s in out {
			s = string(zsp.read_bytes(r))
		}
		return out
	}
	spec.argv = strings_of(&r)
	spec.env = strings_of(&r)
	spec.dir = string(zsp.read_bytes(&r))
	service := "pty" if terminal else "exec"
	if r.bad || (!terminal && len(spec.argv) == 0) {
		status_send(sp, call, .Malformed)
		return refused_handler(), .Cancelled
	}
	detail := strings.join(spec.argv, " ", context.temp_allocator)
	if len(detail) > 512 {
		detail = detail[:512]
	}
	if _, status := share_for(sp, from, scope, .Shell, terminal = terminal); status != .Ok {
		audit(sp, {device = from.device, subject = string(from.who), scope = scope, service = service, detail = detail, event = .Denied})
		status_send(sp, call, status)
		return refused_handler(), .Cancelled
	}
	e := new(Exec)
	e.sp, e.call, e.caller, e.scope, e.terminal = sp, call, from.device, scope, terminal
	e.who = strings.clone(string(from.who))
	e.detail = strings.clone(detail)
	e.data = e
	e.on_data = exec_on_data
	e.on_end = exec_on_end
	e.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {
		e := (^Exec)(h.data)
		exec_close_audit(e, fault_text(fault))
		exec_free(e) // and what it started, killed
	}
	e.on_room = proc(h: ^Call_Handler, call: u64) {
		exec_want(((^Exec)(h.data)))
	}
	p, err := process_start(spec, {data = e, on_output = exec_output, on_room = exec_input_room, on_exit = exec_exited})
	if p == nil {
		audit(sp, {device = from.device, subject = string(from.who), scope = scope, service = service, detail = detail, event = .Close, peer = err})
		delete(e.who)
		delete(e.detail)
		free(e)
		status_send(sp, call, .Not_Found if strings.has_prefix(err, "no such") else .Failed, err)
		return refused_handler(), .Cancelled
	}
	e.p = p
	audit(sp, {device = from.device, subject = e.who, scope = scope, service = service, detail = detail, event = .Open})
	status_send(sp, call, .Ok)
	service_begin(sp, call, from, scope, .Shell, "", false, terminal, e, proc(data: rawptr) {
		e := (^Exec)(data)
		exec_close_audit(e, "no longer allowed")
		exec_free(e)
	})
	exec_want(e)
	return &e.handler, .Cancelled
}

// Reads output only while there is credit for a whole read of it.
@(private)
exec_want :: proc(e: ^Exec) {
	if e.p != nil && !e.exited {
		process_read(e.p, call_room(e.sp, e.call) >= 1 + PROCESS_READ)
	}
}

@(private)
exec_output :: proc(data: rawptr, stream: Output_Stream, bytes: []byte) {
	e := (^Exec)(data)
	w := make([]byte, 1 + len(bytes), context.temp_allocator)
	w[0] = u8(stream)
	copy(w[1:], bytes)
	if !call_send(e.sp, e.call, w) {
		// Read with too little credit: cannot be, but if so, the call is no better than lost.
		call_fault(e.sp, e.call, .Overrun)
		exec_free(e)
		return
	}
	e.bytes_out += u64(len(bytes))
	exec_want(e)
}

@(private)
exec_exited :: proc(data: rawptr, exit: Exit) {
	e := (^Exec)(data)
	e.exited = true
	w := make([dynamic]byte, context.temp_allocator)
	append(&w, 3)
	zsp.write_varint(&w, u64(u32(exit.code)))
	append(&w, u8(exit.signal))
	call_send(e.sp, e.call, w[:])
	exec_close_audit(e, "")
	service_end(e.sp, e.call)
	// Ended, and all it said told: let go of now, its terminal or pipes with it, whenever the caller says it has done.
	process_free(e.p)
	e.p = nil
	c := host_call_find(e.sp, e.call)
	heard := c != nil && c.heard_end
	call_end(e.sp, e.call)
	if heard || c == nil {
		exec_free(e)
	}
}

@(private)
exec_on_data :: proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
	e := (^Exec)(h.data)
	if e.exited || e.p == nil || len(bytes) == 0 {
		return true
	}
	payload := bytes[1:]
	switch bytes[0] {
	case 0:
		if e.ending {
			return true
		}
		e.bytes_in += u64(len(payload))
		taken := 0
		if len(e.held) == 0 {
			taken = process_input(e.p, payload)
			if taken == len(payload) {
				return true
			}
			payload = payload[taken:]
		}
		if process_input_closed(e.p) {
			exec_input_drop(e) // never to be taken: let go of, and credited, with what waited before it
			return true
		}
		// The tag and what was taken are credited now, what is held as it is taken: the whole message, in the end.
		call_consumed(e.sp, call, 1 + taken)
		append(&e.held, ..payload)
		return false
	case 1:
		if len(payload) == 1 {
			process_signal(e.p, Signal(payload[0]))
		}
	case 2:
		if len(payload) == 4 {
			process_resize(e.p, u16(payload[0]) << 8 | u16(payload[1]), u16(payload[2]) << 8 | u16(payload[3]))
		}
	}
	return true
}

@(private)
exec_input_room :: proc(data: rawptr) {
	e := (^Exec)(data)
	if process_input_closed(e.p) {
		exec_input_drop(e)
		return
	}
	if len(e.held) > 0 {
		n := process_input(e.p, e.held[:])
		remove_range(&e.held, 0, n)
		call_consumed(e.sp, e.call, n)
	}
	if len(e.held) == 0 && e.ending {
		process_end_input(e.p)
	}
}

// Input held for a process that will never take it: let go of, and credited, so that the call goes on.
@(private)
exec_input_drop :: proc(e: ^Exec) {
	call_consumed(e.sp, e.call, len(e.held))
	clear(&e.held)
}

@(private)
exec_on_end :: proc(h: ^Call_Handler, call: u64) {
	e := (^Exec)(h.data)
	if e.exited {
		exec_free(e) // and ours was said
		return
	}
	e.ending = true
	if len(e.held) == 0 && e.p != nil {
		process_end_input(e.p)
	}
}

@(private)
exec_close_audit :: proc(e: ^Exec, why: string) {
	if e.detail == "" {
		return
	}
	audit(e.sp, {device = e.caller, subject = e.who, scope = e.scope, service = "pty" if e.terminal else "exec", detail = e.detail, event = .Close, bytes_in = e.bytes_in, bytes_out = e.bytes_out, peer = why})
	delete(e.detail)
	e.detail = ""
}

@(private)
exec_free :: proc(e: ^Exec) {
	if e.freed {
		return
	}
	e.freed = true
	service_end(e.sp, e.call)
	if e.p != nil {
		process_free(e.p)
		e.p = nil
	}
	delete(e.held)
	delete(e.detail)
	delete(e.who)
	free(e)
}
