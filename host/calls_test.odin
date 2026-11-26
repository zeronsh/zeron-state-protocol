package host

import "core:net"
import "core:testing"
import "core:time"
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
	host_serve(&w.hosts[2], "zsp.echo", proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
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
	yc := host_call(a, w.keys[2].device, 1, "zsp.echo", transmute([]byte)string("why"), &y.handler)
	testing.expect(t, yc != 0)
	x.other = &yc
	xc := host_call(a, w.keys[2].device, 1, "zsp.echo", transmute([]byte)string("ex"), &x.handler)
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
	testing.expect(t, host_call(a, w.keys[2].device, 1, "zsp.nothing", nil, &u.handler) != 0)
	testing.expect(t, host_call(a, w.keys[2].device, 2, "zsp.echo", nil, &u.handler) == 0)
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
	kc := host_call(a, w.keys[2].device, 1, "zsp.echo", transmute([]byte)string("keep"), &keep.handler)
	qc := host_call(a, w.keys[2].device, 1, "zsp.echo", transmute([]byte)string("q"), &q.handler)
	p.other = &qc
	pc := host_call(a, w.keys[2].device, 1, "zsp.echo", nil, &p.handler)
	testing.expect(t, kc != 0 && qc != 0 && pc != 0)
	testing.expect(t, call_send(a, pc, transmute([]byte)string("cancel me")))
	testing.expect(t, world_run(&w, proc(w: ^World, p: rawptr) -> bool {return (^Reentrant)(p).faulted && len(world_space(w, 1).node.calls) == 1}, &p))
	testing.expect_value(t, p.fault, zsp.Call_Fault.Cancelled)
	testing.expect(t, !q.faulted && !keep.faulted)
	testing.expect(t, len(a.calls) == 1 && a.calls[0].call == kc)
	call_end(a, kc)
	testing.expect(t, world_run(&w, proc(w: ^World, k: rawptr) -> bool {return (^Reentrant)(k).ended && nobody_left(w, nil)}, &keep))
}

// A call whose other side has said all it will before a socket is joined to it: the socket hears so at once, and
// the bridge is over once the socket has said all it will too.
@(test)
bridge_after_the_end :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	host_serve(&w.hosts[2], "zsp.said", proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
		call_send(sp, call, transmute([]byte)string("all of it"))
		call_end(sp, call)
		@(static) quiet := Call_Handler{}
		return &quiet, .Cancelled
	})
	a := world_space(&w, 1)
	Waiting :: struct {
		using handler: Call_Handler,
		got: [dynamic]byte,
	}
	waiting: Waiting
	defer delete(waiting.got)
	waiting.data = &waiting
	waiting.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		append(&(^Waiting)(h.data).got, ..bytes)
		return true
	}
	call := host_call(a, w.keys[2].device, 1, "zsp.said", nil, &waiting.handler)
	testing.expect(t, call != 0)
	testing.expect(t, world_run(&w, proc(w: ^World, call: rawptr) -> bool {
		c := host_call_find(world_space(w, 1), (^u64)(call)^)
		return c != nil && c.heard_end
	}, &call))
	// A socket's two ends: one for the bridge, one to see what it is told.
	listener, _ := net.listen_tcp({net.IP4_Loopback, 0})
	defer net.close(listener)
	bound, _ := net.bound_endpoint(listener)
	near, _ := net.dial_tcp(bound)
	far, _, _ := net.accept_tcp(listener)
	defer net.close(near)
	bridge(a, call, far)
	net.set_option(near, .Receive_Timeout, 5 * time.Second)
	buf: [64]byte
	n, err := net.recv_tcp(near, buf[:])
	testing.expectf(t, err == nil && n == 0, "the socket was not told the other side had ended: %d, %v", n, err)
	net.shutdown(near, .Send)
	testing.expect(t, world_run(&w, nobody_left))
}
