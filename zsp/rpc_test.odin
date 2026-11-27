#+build !js
package zsp

import "core:fmt"
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
	who:    string, // owned; for whom the last call was
	claim:  []byte, // what is said of that in calling, for what it is worth
}

@(private)
caller_destroy :: proc(c: ^Caller) {
	delete(c.calls)
	delete(c.first)
	delete(c.data)
	delete(c.faults)
	delete(c.method)
	delete(c.who)
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
			delete(c.who)
			c.who = strings.clone(string(read_bytes(&f)))
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
	device := device
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Call)
	write_varint(&w, id)
	append(&w, ..device[:])
	write_varint(&w, u64(scope))
	write_bytes(&w, transmute([]byte)method)
	write_bytes(&w, c.claim)
	write_u8(&w, URGENCY) // a local client says how urgent
	append(&w, ..transmute([]byte)body)
	frame_end(&w, at)
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
	// Over a direct link, then one that carries each call on a stream of its own, then with only a relay between.
	for mode in 0 ..< 3 {
		relayed := mode == 2
		s: Sim
		sim_init(t, &s, full = 2, partial = 1, relays = 1, ring = 64)
		s.lanes = mode == 1
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
		// The method with no name is for nodes themselves, not for whoever uses one.
		caller_call(&ca, 9, b.keys.device, 1, "", "")
		caller_call(&ca, 10, a.keys.device, 1, "", "")
		settle(&s, &ca, &cb)
		testing.expect(t, len(ca.faults) == 5 && ca.faults[3] == .Denied && ca.faults[4] == .Denied)
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

		if s.lanes {
			// Each call went on a lane of its own, and every lane of a call that is over is gone, both ways.
			l := s.links[0]
			testing.expectf(t, l.lanes.opened >= 5, "%d lanes", l.lanes.opened)
			testing.expect_value(t, len(session_lanes(l.a)) + len(session_lanes(l.b)), 2) // call 7 goes on
		}
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

// Serving is for those who may: one that may not call does not stand in the way of one that may, nor can any client
// serve so much that others cannot, or cannot cease to.
@(test)
serving_is_for_those_who_may :: proc(t: ^testing.T) {
	state := seeded(22)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 64)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	sim_link(&s, 0, 1)
	sim_settle(&s)
	b.node.host.authenticate = proc(_: rawptr, s: ^Session, credential: []byte) {
		session_accept(s, {{0, {.Read} if string(credential) == "reader" else {.Read, .Write, .Call}, 0}})
	}
	ca, cb := Caller{s = sim_client(&s, a)}, Caller{s = sim_client(&s, b)}
	reader := Caller{s = session_open(&b.node, .Open, false)}
	defer caller_destroy(&ca)
	defer caller_destroy(&cb)
	defer caller_destroy(&reader)
	hello := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&hello, .Hello)
	append(&hello, VERSION, 0)
	zero: Key32
	append(&hello, ..zero[:])
	write_varint(&hello, 0)
	write_bytes(&hello, transmute([]byte)string("reader"))
	frame_end(&hello, at)
	testing.expect(t, session_input(reader.s, hello[:]) && .Call not_in session_rights(reader.s, 1))
	testing.expect(t, caller_serve(&cb, 1, "echo") && caller_serve(&reader, 1, "echo"))
	caller_call(&ca, 1, b.keys.device, 1, "echo", "hi")
	settle(&s, &ca, &cb, &reader)
	testing.expect(t, len(cb.calls) == 1 && len(reader.calls) == 0 && len(ca.faults) == 0)
	full := true
	for i in 0 ..< MAX_CALLS {
		full &&= caller_serve(&reader, 1, fmt.tprint(i))
	}
	testing.expect(t, !full)
	unserve := make([dynamic]byte, context.temp_allocator)
	at = frame_begin(&unserve, .Serve)
	write_varint(&unserve, 1)
	write_u8(&unserve, 0)
	write_bytes(&unserve, transmute([]byte)string("echo"))
	frame_end(&unserve, at)
	testing.expect(t, session_input(cb.s, unserve[:]) && caller_serve(&cb, 1, "another"))
	session_close(ca.s)
	session_close(cb.s)
	if !reader.s.closing {
		session_close(reader.s)
	}
}

@(private)
settle :: proc(s: ^Sim, cs: ..^Caller) {
	for _ in 0 ..< 3 {
		sim_settle(s)
		for c in cs {
			caller_read(c)
		}
	}
}

// A relay carries links' packets between devices it serves, and drops them, rather than queue them, when a device
// has more waiting than it can take; it drops nothing else. A device takes them only through a relay it dialled,
// and only from a member.
@(test)
relays_carry_links :: proc(t: ^testing.T) {
	state := seeded(22)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
	defer sim_destroy(&s)
	a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	Heard :: struct {
		packets: int,
		bytes:   int,
		via:     u32,
		from:    Key32,
	}
	heard: Heard
	b.node.host.data = &heard
	b.node.host.link = proc(data: rawptr, relay: u32, from: Key32, packet: []byte) {
		h := (^Heard)(data)
		h.packets += 1
		h.bytes += len(packet)
		h.via, h.from = relay, from
	}
	via: u32
	for x in a.node.sessions {
		if x.peer_relay {
			via = x.id
		}
	}
	packet: [8192]byte
	testing.expect(t, node_post_link(&a.node, via, b.keys.device, packet[:]))
	sim_settle(&s)
	testing.expect(t, heard.packets == 1 && heard.bytes == len(packet) && heard.from == a.keys.device)
	// b's session at the relay takes nothing for a while: what piles up past the relay's queue is dropped there.
	to_b: ^Session
	for x in relay.node.sessions {
		if x.peer == b.keys.device {
			to_b = x
		}
	}
	for x in s.links {
		if x.a.node == &a.node || x.b.node == &a.node {
			for _ in 0 ..< 200 {
				node_post_link(&a.node, via, b.keys.device, packet[:])
				sim_pass(&s, x.a, x.b)
				sim_pass(&s, x.b, x.a)
			}
		}
	}
	testing.expectf(t, len(to_b.out) - to_b.sent <= LINK_QUEUE + len(packet) + 64, "the relay holds %d for b", len(to_b.out) - to_b.sent)
	heard = {}
	sim_settle(&s)
	testing.expectf(t, heard.packets > 0 && heard.packets < 200, "%d of 200 came", heard.packets)
	// Nobody else's packets are taken: not from a session that is not with a relay.
	before := heard.packets
	w: [dynamic]byte
	defer delete(w)
	at := frame_begin(&w, .Signal)
	append(&w, ..a.keys.device[:])
	append(&w, u8(Post.Link), 1, 2, 3)
	frame_end(&w, at)
	for x in s.links {
		if x.b.node == &b.node && x.b.peer_relay {
			session_input(x.b, w[:]) // as though a relay said it: it is one
			testing.expect_value(t, heard.packets, before + 1)
		}
	}
}

// Who is called has, by then, what the caller wrote before calling.
@(test)
calls_come_after_what_they_are_about :: proc(t: ^testing.T) {
	for mode in 0 ..< 3 {
		relayed := mode == 1
		state := seeded(u64(24 + mode))
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
		s.lanes = mode == 2 // each call on a stream of its own, which may overtake what was said before it
		defer sim_destroy(&s)
		a, b := s.nodes[0], s.nodes[1]
		if relayed {
			sim_link(&s, 0, 2)
			sim_link(&s, 1, 2)
		} else {
			sim_link(&s, 0, 1)
		}
		sim_settle(&s)
		ca, cb := Caller{s = sim_client(&s, a)}, Caller{s = sim_client(&s, b)}
		defer caller_destroy(&ca)
		defer caller_destroy(&cb)
		caller_serve(&cb, 1, "echo")
		settle(&s, &ca, &cb)
		caller_call(&ca, 1, b.keys.device, 1, "echo", "first") // and a tunnel, where there is none yet
		settle(&s, &ca, &cb)
		for i in 0 ..< 30 {
			a.node.now = sim_now(&s, a)
			row := node_id(&a.node, 1)
			body: [24]byte
			list := list_tag(keyring_scope(&a.keys, 1), "a")
			put_u64(body[:], list[0])
			put_u64(body[8:], list[1])
			testing.expect(t, node_write(&a.node, {{row, 1, .Place, node_stamp(&a.node), body[:]}}))
			calls := len(cb.calls)
			caller_call(&ca, u64(2 + i), b.keys.device, 1, "echo", "look")
			for len(cb.calls) == calls {
				for l in s.links {
					sim_pass(&s, l.a, l.b, l.lanes, 0)
					sim_pass(&s, l.b, l.a, l.lanes, 1)
				}
				sim_relayed_pump(&s)
				caller_read(&cb)
				caller_read(&ca)
				if len(b.node.calls) > calls {
					// It has come as far as the node.
					testing.expect(t, row_places(&b.node.store, row).count == 1)
				}
			}
			testing.expect(t, row_places(&b.node.store, row).count == 1)
			s.now += 10
		}
		session_close(ca.s)
		session_close(cb.s)
	}
}

// What the hosts in hosts_speak_at_once heard, and the call each cancels when another ends.
@(private)
Hosted :: struct {
	n:      ^Node,
	calls:  [dynamic]u64, // answered
	faults: [dynamic]u64,
	then:   u64, // to cancel, from within, when told a call is over
}

// A host may say anything in any call at once, from within being told something: here, told that one call is over,
// it cancels another, which lies just before it among the node's calls. Each is let go of once, and no other.
@(test)
hosts_speak_at_once :: proc(t: ^testing.T) {
	state := seeded(31)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 64)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	sim_link(&s, 0, 1)
	sim_settle(&s)
	ha, hb := Hosted{n = &a.node}, Hosted{n = &b.node}
	defer delete(ha.calls)
	defer delete(ha.faults)
	defer delete(hb.calls)
	defer delete(hb.faults)
	for x in ([]^Hosted{&ha, &hb}) {
		x.n.host.data = x
		x.n.host.method = proc(data: rawptr, call: u64, from: Caller_Info, scope: Scope, method: string, first: []byte) -> Maybe(Call_Fault) {
			append(&(^Hosted)(data).calls, call)
			return nil
		}
		x.n.host.flow = proc(data: rawptr, call: u64, kind: Flow, payload: []byte) {
			h := (^Hosted)(data)
			if kind == .Fault || kind == .Cancel {
				append(&h.faults, call)
				if h.then != 0 {
					other := h.then
					h.then = 0
					node_flow(h.n, other, .Cancel)
				}
			}
		}
	}
	keep := node_call_method(&a.node, b.keys.device, 1, "x", nil)
	q := node_call_method(&a.node, b.keys.device, 1, "x", nil)
	p := node_call_method(&a.node, b.keys.device, 1, "x", nil)
	testing.expect(t, keep != 0 && q != 0 && p != 0)
	sim_settle(&s)
	testing.expect_value(t, len(hb.calls), 3)
	// B cancels p, the last of A's calls; A, told so, cancels q, which comes before it.
	ha.then = q
	node_flow(&b.node, hb.calls[2], .Cancel)
	sim_settle(&s)
	testing.expectf(t, len(ha.faults) == 1 && ha.faults[0] == p, "%v", ha.faults[:])
	testing.expect_value(t, len(a.node.calls), 1)
	testing.expect(t, len(a.node.calls) == 1 && a.node.calls[0].ends[CALLER].id == keep)
	testing.expect_value(t, len(b.node.calls), 1)
}
