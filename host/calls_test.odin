package host

import "core:testing"
import "../zsp"

// What a handler does, said back to it.
@(private)
Reentrant :: struct {
	using handler: Call_Handler,
	sp:      ^Space,
	other:   ^u64, // a call to cancel, from within
	got:     [dynamic]byte,
	ended:   bool,
	faulted: bool,
	fault:   zsp.Call_Fault,
}

@(private)
reentrant_init :: proc(r: ^Reentrant, sp: ^Space) {
	r.sp = sp
	r.data = r
	r.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		r := (^Reentrant)(h.data)
		append(&r.got, ..bytes)
		if r.other != nil && r.other^ != 0 {
			call_cancel(r.sp, r.other^) // another call, from within this one's
			r.other^ = 0
			call_end(r.sp, call) // and this one's own end
		}
		return true
	}
	r.on_end = proc(h: ^Call_Handler, call: u64) {
		r := (^Reentrant)(h.data)
		r.ended = true
	}
	r.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {
		r := (^Reentrant)(h.data)
		r.faulted, r.fault = true, fault
		if r.other != nil && r.other^ != 0 {
			call_cancel(r.sp, r.other^) // another call, from within this one's ending
			r.other^ = 0
		}
	}
}

// B's answers echo from within on_data, end from within on_end, and A's handler cancels another call and ends its own
// from within on_data: everything said at once, from within, lands where it should, and nothing is left behind.
@(test)
handlers_may_speak_at_once :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	host_serve(&w.hosts[2], "echo", proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
		h := new(Call_Handler)
		h.data = sp
		h.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
			sp := (^Space)(h.data)
			if string(bytes) == "cancel me" {
				call_cancel(sp, call)
				free(h)
				return true
			}
			call_send(sp, call, bytes) // back at once
			return true
		}
		h.on_end = proc(h: ^Call_Handler, call: u64) {
			call_end((^Space)(h.data), call) // over, at once
			free(h)
		}
		h.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {
			free(h)
		}
		call_send(sp, call, first) // said within the answer itself
		return h, .Cancelled
	})
	a := world_space(&w, 1)
	x, y: Reentrant
	reentrant_init(&x, a)
	reentrant_init(&y, a)
	defer delete(x.got)
	defer delete(y.got)
	yc := host_call(a, w.keys[2].device, 1, "echo", transmute([]byte)string("why"), &y.handler)
	testing.expect(t, yc != 0)
	x.other = &yc
	xc := host_call(a, w.keys[2].device, 1, "echo", transmute([]byte)string("ex"), &x.handler)
	testing.expect(t, xc != 0)
	testing.expect(t, world_run(&w, proc(w: ^World, x: rawptr) -> bool {
		return (^Reentrant)(x).ended && nobody_left(w, nil) && len(world_space(w, 1).node.calls) + len(world_space(w, 2).node.calls) == 0
	}, &x))
	testing.expect_value(t, string(x.got[:]), "ex")
	testing.expect(t, !y.faulted && !y.ended) // it cancelled itself, so it is told nothing
	// A call to a method nobody serves, and one with no right to it.
	u: Reentrant
	reentrant_init(&u, a)
	defer delete(u.got)
	testing.expect(t, host_call(a, w.keys[2].device, 1, "nothing", nil, &u.handler) != 0)
	testing.expect(t, host_call(a, w.keys[2].device, 2, "echo", nil, &u.handler) == 0)
	testing.expect(t, world_run(&w, proc(w: ^World, u: rawptr) -> bool {return (^Reentrant)(u).faulted}, &u))
	testing.expect_value(t, u.fault, zsp.Call_Fault.Unserved)

	// B cancels the last call made; A, told so, cancels the one before it from within: neither is left, and nothing
	// else is touched.
	q, p, keep: Reentrant
	reentrant_init(&q, a)
	reentrant_init(&p, a)
	reentrant_init(&keep, a)
	defer delete(q.got)
	defer delete(p.got)
	defer delete(keep.got)
	kc := host_call(a, w.keys[2].device, 1, "echo", transmute([]byte)string("keep"), &keep.handler)
	qc := host_call(a, w.keys[2].device, 1, "echo", transmute([]byte)string("q"), &q.handler)
	p.other = &qc
	pc := host_call(a, w.keys[2].device, 1, "echo", nil, &p.handler)
	testing.expect(t, kc != 0 && qc != 0 && pc != 0)
	testing.expect(t, call_send(a, pc, transmute([]byte)string("cancel me")))
	testing.expect(t, world_run(&w, proc(w: ^World, p: rawptr) -> bool {return (^Reentrant)(p).faulted && len(world_space(w, 1).node.calls) == 1}, &p))
	testing.expect_value(t, p.fault, zsp.Call_Fault.Cancelled)
	testing.expect(t, !q.faulted && !keep.faulted)
	testing.expect(t, len(a.calls) == 1 && a.calls[0].call == kc)
	call_end(a, kc)
	testing.expect(t, world_run(&w, proc(w: ^World, k: rawptr) -> bool {return (^Reentrant)(k).ended && nobody_left(w, nil)}, &keep))
}

// What a local client hears: the methods called on it, and of a call's messages, the bytes, and whether it ended or
// failed. The output is taken.
@(private = "file")
Heard :: struct {
	called: [dynamic]string, // methods, in temporary memory
	data:   int,
	ended:  bool,
	faulted: bool,
}

@(private = "file")
heard_by :: proc(local: ^zsp.Session, h: ^Heard) {
	out := zsp.session_output(local)
	r := zsp.Reader{buf = out}
	for r.pos < len(r.buf) && !r.bad {
		n := int(zsp.read_varint(&r))
		frame := zsp.read_take(&r, n)
		if r.bad || len(frame) < 1 {
			continue
		}
		body := zsp.Reader{buf = frame[1:]}
		#partial switch zsp.Message(frame[0]) {
		case .Call:
			_ = zsp.read_varint(&body)
			_ = zsp.read_take(&body, 32)
			_ = zsp.read_varint(&body)
			append(&h.called, string(zsp.read_bytes(&body)))
		case .Flow:
			_ = zsp.read_varint(&body)
			#partial switch zsp.Flow(zsp.read_u8(&body)) {
			case .Data:
				h.data += len(body.buf) - body.pos
			case .End:
				h.ended = true
			case .Fault, .Cancel:
				h.faulted = true
			}
		}
	}
	zsp.session_sent(local, len(out))
}

@(private = "file")
local_serve :: proc(local: ^zsp.Session, scope: zsp.Scope, method: string) -> bool {
	w := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&w, .Serve)
	zsp.write_varint(&w, u64(scope))
	append(&w, 1)
	zsp.write_bytes(&w, transmute([]byte)method)
	zsp.frame_end(&w, at)
	return zsp.session_input(local, w[:])
}

// A method the host serves is answered in-process, in place of a local client that serves it too; one it does not, or
// no longer, or that it passes on (.Unserved), goes to the local client. Its own local client may call it as well, and
// it is told so.
@(test)
host_and_clients_share_methods :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	echo_serve(&w.hosts[2])
	@(static) local_caller: bool
	host_serve(&w.hosts[2], "maybe", proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
		if string(first) == "pass" {
			return nil, .Unserved
		}
		local_caller = from.local != nil && from.device == sp.host.device
		call_send(sp, call, transmute([]byte)string("mine"))
		call_end(sp, call)
		@(static) quiet := Call_Handler{}
		return &quiet, .Cancelled
	})
	local := open_local_session(t, b, w.space, []zsp.Grant{{scope = 1, rights = {.Read, .Write, .Call}}})
	defer zsp.session_close(local)
	testing.expect(t, local_serve(local, 1, "echo") && local_serve(local, 1, "maybe") && local_serve(local, 1, "theirs"))
	heard: Heard

	// The host's own, though the client serves it too.
	p: Pump
	testing.expect(t, pump_start(&p, &w, 100 << 10))
	testing.expect(t, world_run(&w, pump_done, &p))
	testing.expect(t, pump_whole(&p))
	// The client's alone; and one the host passes on.
	x, y: Reentrant
	reentrant_init(&x, a)
	reentrant_init(&y, a)
	defer delete(x.got)
	defer delete(y.got)
	testing.expect(t, host_call(a, w.keys[2].device, 1, "theirs", nil, &x.handler) != 0)
	testing.expect(t, host_call(a, w.keys[2].device, 1, "maybe", transmute([]byte)string("pass"), &y.handler) != 0)
	testing.expect(t, world_run(&w, proc(w: ^World, local: rawptr) -> bool {
		return len(zsp.session_output((^zsp.Session)(local))) > 0 && len(world_space(w, 2).calls) == 0
	}, local))
	heard_by(local, &heard)
	testing.expectf(t, len(heard.called) == 2 && heard.called[0] == "theirs" && heard.called[1] == "maybe", "the client was called by %v", heard.called[:])
	call_cancel(a, 0) // nothing
	// No longer served by the host: the client has it.
	host_serve(&w.hosts[2], "echo", nil)
	e: Reentrant
	reentrant_init(&e, a)
	defer delete(e.got)
	testing.expect(t, host_call(a, w.keys[2].device, 1, "echo", nil, &e.handler) != 0)
	testing.expect(t, world_run(&w, proc(w: ^World, local: rawptr) -> bool {return len(zsp.session_output((^zsp.Session)(local))) > 0}, local))
	clear(&heard.called)
	heard_by(local, &heard)
	testing.expectf(t, len(heard.called) == 1 && heard.called[0] == "echo", "the client was called by %v", heard.called[:])

	// The device's own client calls its host.
	testing.expect(t, local_call(local, 1, w.keys[2].device, 1, "maybe", nil))
	heard_by(local, &heard)
	testing.expect(t, local_caller)
	testing.expect_value(t, heard.data, 4)
	testing.expect(t, heard.ended && !heard.faulted)
}

// How urgent a call's stream is, is its caller's to say: a host's by host_call, a local client's in its Call, and the
// other end takes the lane as it was opened. More than 7 is no urgency at all.
@(test)
urgency_is_the_callers :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	echo_serve(&w.hosts[2])
	toward :: proc(sp: ^Space, device: zsp.Key32) -> ^zsp.Session {
		for s in sp.node.sessions {
			if s.ready && s.role == .Peer && !s.peer_relay && s.peer == device {
				return s
			}
		}
		return nil
	}
	ab, ba := toward(a, w.keys[2].device), toward(b, w.keys[1].device)
	testing.expect(t, ab != nil && ba != nil)
	if ab == nil || ba == nil {
		return
	}
	urgencies :: proc(s: ^zsp.Session) -> (out: [dynamic]u8) {
		out = make([dynamic]u8, context.temp_allocator)
		for l in zsp.session_lanes(s) {
			append(&out, l.urgency)
		}
		return
	}
	bulk, typing: Pump
	testing.expect(t, pump_start(&bulk, &w, 4 << 20, urgency = 6))
	testing.expect(t, pump_start(&typing, &w, 10, urgency = 1))
	mine := urgencies(ab)
	testing.expectf(t, len(mine) == 2 && mine[0] == 6 && mine[1] == 1, "A's lanes: %v", mine[:])
	testing.expect(t, world_run(&w, proc(w: ^World, _: rawptr) -> bool {return len(zsp.session_lanes(toward_b(w))) == 2}))
	theirs := urgencies(ba) // in the order they came, which may be either
	testing.expectf(t, len(theirs) == 2 && theirs[0] + theirs[1] == 7 && theirs[0] * theirs[1] == 6, "B's lanes: %v", theirs[:])
	testing.expect(t, world_run(&w, pump_done, &bulk) && world_run(&w, pump_done, &typing))
	testing.expect(t, pump_whole(&bulk) && pump_whole(&typing))
	testing.expect(t, host_call(a, w.keys[2].device, 1, "echo", nil, &bulk.handler, urgency = 8) == 0)

	// A local client's, as it said.
	local := open_local_session(t, a, w.space, []zsp.Grant{{scope = 1, rights = {.Read, .Write, .Call}}})
	defer zsp.session_close(local)
	before := len(zsp.session_lanes(ab))
	testing.expect(t, local_call(local, 1, w.keys[2].device, 1, "echo", transmute([]byte)string("hi"), urgency = 0))
	now := urgencies(ab)
	testing.expectf(t, len(now) == before + 1 && now[len(now) - 1] == 0, "A's lanes: %v", now[:])
	testing.expect(t, !local_call(local, 2, w.keys[2].device, 1, "echo", nil, urgency = 8))
}

@(private = "file")
toward_b :: proc(w: ^World) -> ^zsp.Session {
	for s in world_space(w, 2).node.sessions {
		if s.ready && s.role == .Peer && !s.peer_relay && s.peer == w.keys[1].device {
			return s
		}
	}
	return nil
}
