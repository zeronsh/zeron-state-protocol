#+build !js
package zsp

import "core:math/rand"
import "core:strings"
import "core:testing"

// A local client reduced to its frames.
@(private)
Caller :: struct {
	s:      ^Session,
	calls:  [dynamic]u64, // received
	from:   Key32, // of the last
	method: string,
	first:  [dynamic]byte,
	data:   [dynamic]byte, // messages heard, joined by commas
	ends:   int,
	faults: [dynamic]Call_Fault,
	cancels: int,
	reach:  int, // devices, itself included
}

@(private)
caller_destroy :: proc(c: ^Caller) {
	delete(c.calls)
	delete(c.first)
	delete(c.data)
	delete(c.faults)
	delete(c.method)
}

@(private)
caller_read :: proc(c: ^Caller) {
	out := session_output(c.s)
	r := Reader{buf = out}
	for r.pos < len(out) {
		frame := read_bytes(&r)
		f := Reader{buf = frame[1:]}
		#partial switch Message(frame[0]) {
		case .Call:
			append(&c.calls, read_varint(&f))
			c.from = read_key32(&f)
			_ = read_varint(&f)
			delete(c.method)
			c.method = strings.clone(string(read_bytes(&f)))
			clear(&c.first)
			append(&c.first, ..f.buf[f.pos:])
		case .Flow:
			_ = read_varint(&f)
			kind := Flow(read_u8(&f))
			payload := f.buf[f.pos:]
			#partial switch kind {
			case .Data:
				append(&c.data, ..payload)
				append(&c.data, ',')
			case .End:
				c.ends += 1
			case .Fault:
				append(&c.faults, Call_Fault(payload[0]))
			case .Cancel:
				c.cancels += 1
			}
		case .Presence:
			c.reach = 0
			for f.pos < len(f.buf) {
				_ = read_key32(&f)
				_ = read_bytes(&f)
				c.reach += 1
			}
		}
	}
	session_sent(c.s, len(out))
}

@(private)
caller_serve :: proc(c: ^Caller, scope: Scope, method: string) -> bool {
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Serve)
	write_varint(&w, u64(scope))
	write_u8(&w, 1)
	write_bytes(&w, transmute([]byte)method)
	frame_end(&w, at)
	return session_input(c.s, w[:])
}

@(private)
caller_call :: proc(c: ^Caller, id: u64, device: Key32, scope: Scope, method, body: string) {
	w := make([dynamic]byte, context.temp_allocator)
	call_put(&w, nil, id, device, scope, method, transmute([]byte)body)
	session_input(c.s, w[:])
}

@(private)
caller_flow :: proc(c: ^Caller, id: u64, side: int, kind: Flow, body: string) {
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Flow)
	write_varint(&w, id << 1 | u64(side))
	write_u8(&w, u8(kind))
	append(&w, body)
	frame_end(&w, at)
	session_input(c.s, w[:])
}

@(test)
calls_between_devices :: proc(t: ^testing.T) {
	state := seeded(21)
	context.random_generator = rand.default_random_generator(&state)
	// Once over a direct link, once with only a relay between.
	for relayed in ([]bool{false, true}) {
		s: Sim
		sim_init(t, &s, full = 2, partial = 1, relays = 1, ring = 64)
		defer sim_destroy(&s)
		a, b := s.nodes[0], s.nodes[1]
		if relayed {
			sim_link(&s, 0, 3)
			sim_link(&s, 1, 3)
		} else {
			sim_link(&s, 0, 1)
		}
		sim_settle(&s)
		ca, cb := Caller{s = sim_client(&s, a)}, Caller{s = sim_client(&s, b)}
		defer caller_destroy(&ca)
		defer caller_destroy(&cb)
		settle :: proc(s: ^Sim, cs: ..^Caller) {
			for _ in 0 ..< 3 {
				sim_settle(s)
				for c in cs {
					caller_read(c)
				}
			}
		}
		testing.expect(t, caller_serve(&cb, 1, "echo"))
		settle(&s, &ca, &cb)
		testing.expect_value(t, ca.reach, 2)

		// Unary, then a conversation.
		caller_call(&ca, 1, b.keys.device, 1, "echo", "hi")
		settle(&s, &ca, &cb)
		testing.expect(t, len(cb.calls) == 1 && cb.from == a.keys.device && cb.method == "echo" && string(cb.first[:]) == "hi")
		caller_flow(&cb, cb.calls[0], CALLEE, .Data, "hi yourself")
		caller_flow(&ca, 1, CALLER, .Data, "more")
		settle(&s, &ca, &cb)
		testing.expect_value(t, string(ca.data[:]), "hi yourself,")
		testing.expect_value(t, string(cb.data[:]), "more,")
		caller_flow(&ca, 1, CALLER, .End, "")
		settle(&s, &ca, &cb)
		caller_flow(&cb, cb.calls[0], CALLEE, .End, "")
		settle(&s, &ca, &cb)
		testing.expect(t, ca.ends == 1 && cb.ends == 1)
		testing.expect(t, len(a.node.calls) == 0 && len(b.node.calls) == 0)

		// Refusals: nobody serves it; no right to call; no such device.
		caller_call(&ca, 2, b.keys.device, 1, "nothing", "")
		caller_call(&ca, 3, b.keys.device, 2, "echo", "")
		caller_call(&ca, 4, s.nodes[2].keys.device, 1, "echo", "")
		settle(&s, &ca, &cb)
		testing.expect_value(t, len(ca.faults), 3)
		for want in ([]Call_Fault{.Unserved, .Denied, .Unreachable}) {
			found := false
			for f in ca.faults {
				found ||= f == want
			}
			testing.expectf(t, found, "no %v", want)
		}

		// Cancellation reaches the other side; overrunning the window ends the call for both.
		caller_call(&ca, 5, b.keys.device, 1, "echo", "")
		settle(&s, &ca, &cb)
		caller_flow(&ca, 5, CALLER, .Cancel, "")
		settle(&s, &ca, &cb)
		testing.expect(t, cb.cancels == 1 && len(a.node.calls) == 0 && len(b.node.calls) == 0)
		caller_call(&ca, 6, b.keys.device, 1, "echo", "")
		settle(&s, &ca, &cb)
		big := strings.repeat("x", CALL_WINDOW / 2 + 1, context.temp_allocator)
		caller_flow(&ca, 6, CALLER, .Data, big)
		caller_flow(&ca, 6, CALLER, .Data, big)
		settle(&s, &ca, &cb)
		testing.expect(t, ca.faults[len(ca.faults) - 1] == .Overrun && cb.faults[len(cb.faults) - 1] == .Overrun)
		testing.expect(t, len(a.node.calls) == 0 && len(b.node.calls) == 0)

		// Credit lets a stream run as long as it likes.
		caller_call(&ca, 7, b.keys.device, 1, "echo", "")
		settle(&s, &ca, &cb)
		id := cb.calls[len(cb.calls) - 1]
		clear(&ca.data)
		chunk := strings.repeat("y", 100_000, context.temp_allocator)
		for _ in 0 ..< 10 {
			caller_flow(&cb, id, CALLEE, .Data, chunk)
			settle(&s, &ca, &cb)
			w := make([dynamic]byte, context.temp_allocator)
			write_varint(&w, 100_000)
			caller_flow(&ca, 7, CALLER, .Credit, string(w[:]))
			settle(&s, &ca, &cb)
		}
		testing.expect_value(t, len(ca.data), 10 * 100_001)

		// The path fails: both sides are told, and told it is in doubt.
		n := len(ca.faults)
		for len(s.links) > 0 {
			sim_cut(&s, 0)
		}
		settle(&s, &ca, &cb)
		testing.expect(t, len(ca.faults) == n + 1 && ca.faults[n] == .Lost)
		testing.expect(t, len(a.node.calls) == 0 && len(b.node.calls) == 0)

		// And a client on the same device is called without leaving it.
		caller_call(&cb, 1, b.keys.device, 1, "echo", "me")
		settle(&s, &ca, &cb)
		testing.expect_value(t, string(cb.first[:]), "me")
		session_close(ca.s)
		session_close(cb.s)
		testing.expect(t, len(b.node.calls) == 0 && len(b.node.serving) == 0)
		free_all(context.temp_allocator)
	}
}

// What a relay saw, it cannot say again.
@(test)
tunnels_refuse_replay :: proc(t: ^testing.T) {
	state := seeded(22)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	ca, cb := Caller{s = sim_client(&s, a)}, Caller{s = sim_client(&s, b)}
	defer caller_destroy(&ca)
	defer caller_destroy(&cb)
	caller_serve(&cb, 1, "echo")
	heard := make([dynamic]byte, context.temp_allocator)
	round :: proc(s: ^Sim, heard: ^[dynamic]byte) {
		// Everything the relay says to b, as it says it.
		for _ in 0 ..< 12 {
			for l in s.links {
				for pair in ([][2]^Session{{l.a, l.b}, {l.b, l.a}}) {
					out := session_output(pair[0])
					copied := make([]byte, len(out), context.temp_allocator)
					copy(copied, out)
					session_sent(pair[0], len(out))
					if l.an == 1 && pair[0] == l.b {
						append(heard, ..copied)
					}
					session_input(pair[1], copied)
				}
			}
		}
	}
	caller_call(&ca, 1, b.keys.device, 1, "echo", "pay the bill")
	round(&s, &heard)
	caller_read(&cb)
	testing.expect_value(t, len(cb.calls), 1)
	at_b: ^Session
	for l in s.links {
		if l.an == 1 {
			at_b = l.a
		}
	}
	testing.expect(t, session_input(at_b, heard[:]))
	testing.expect(t, session_input(at_b, heard[:]))
	caller_read(&cb)
	testing.expect_value(t, len(cb.calls), 1)
	// And the tunnel survives the attempt.
	caller_call(&ca, 2, b.keys.device, 1, "echo", "again")
	round(&s, &heard)
	caller_read(&cb)
	testing.expect_value(t, len(cb.calls), 2)
	session_close(ca.s)
	session_close(cb.s)
}
