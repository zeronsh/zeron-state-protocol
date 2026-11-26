#+build !js
package zsp

import "core:math/rand"
import "core:testing"

// Each a reproduction from adversarial review, kept so that what it found stays found.

// What comes on lanes before the session is ready is bounded, as what comes on its own stream is.
@(test)
review_lane_input_before_ready_is_bounded :: proc(t: ^testing.T) {
	state := seeded(101)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 64)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	sess := session_open(&b.node, .Calls, false, a.keys.device)
	defer session_close(sess)
	testing.expect(t, !sess.ready)
	chunk := make([]byte, 1 << 20, context.temp_allocator)
	ok := true
	for _ in 0 ..< 16 {
		if !session_lane_input(sess, 2, 3, chunk) {
			ok = false
			break
		}
	}
	held := 0
	for l in sess.lanes {
		held += len(l.input)
	}
	testing.expectf(t, !ok && held <= MAX_FRAME + 16, "%d bytes held before the session was ready (ok %v)", held, ok)
}

// A lane whose other end has finished it, and on which no call goes on, is over here too.
@(test)
review_lane_with_no_call_is_let_go :: proc(t: ^testing.T) {
	state := seeded(102)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 64)
	s.lanes = true
	defer sim_destroy(&s)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	b_sess := s.links[0].b
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Flow)
	write_varint(&w, u64(9999) << 1)
	write_u8(&w, u8(Flow.End))
	frame_end(&w, at)
	testing.expect(t, session_lane_input(b_sess, 2, 3, w[:]))
	session_lane_heard(b_sess, 2, given_up = false)
	l := lane_find(b_sess, 2)
	testing.expectf(t, l == nil || l.over, "the lane stays: %v", l^ if l != nil else Lane{})
}

// A relay holds no more than LINK_QUEUE for a device, whatever kind of signal, however large.
@(test)
review_relay_signals_are_bounded :: proc(t: ^testing.T) {
	for kind in ([]Post{.Link, .Plain}) {
		state := seeded(103)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
		defer sim_destroy(&s)
		a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
		sim_link(&s, 0, 2)
		sim_link(&s, 1, 2)
		sim_settle(&s)
		to_a, to_b: ^Session
		for sess in relay.node.sessions {
			if sess.peer == a.keys.device {
				to_a = sess
			} else if sess.peer == b.keys.device {
				to_b = sess
			}
		}
		big := make([]byte, 1 << 20, context.temp_allocator)
		w := make([dynamic]byte, context.temp_allocator)
		at := frame_begin(&w, .Signal)
		append(&w, ..b.keys.device[:])
		write_u8(&w, u8(kind))
		append(&w, ..big)
		frame_end(&w, at)
		for _ in 0 ..< 10 {
			testing.expect(t, session_input(to_a, w[:]))
		}
		testing.expectf(t, session_backlog(to_b) <= LINK_QUEUE, "kind %v: the relay holds %d for b", kind, session_backlog(to_b))
	}
}

// A burst of a link's packets that comes all in one read is forwarded whole when the pipe onward takes it at once: a
// relay drops only what would wait, not what came together.
@(test)
review_relay_burst_is_forwarded :: proc(t: ^testing.T) {
	state := seeded(104)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
	defer sim_destroy(&s)
	a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	to_a, to_b: ^Session
	for sess in relay.node.sessions {
		if sess.peer == a.keys.device {
			to_a = sess
		} else if sess.peer == b.keys.device {
			to_b = sess
		}
	}
	@(static) forwarded: int
	forwarded = 0
	relay.node.host.flush = proc(data: rawptr, s: ^Session) {
		// A pipe that takes everything at once, as loopback does.
		out := session_queued(s)
		forwarded += len(out)
		session_sent(s, len(out))
	}
	defer relay.node.host.flush = nil
	packet := make([]byte, 8000, context.temp_allocator)
	w := make([dynamic]byte, context.temp_allocator)
	COUNT :: 64 // half a MiB, twice what a relay holds for anyone
	for _ in 0 ..< COUNT {
		at := frame_begin(&w, .Signal)
		append(&w, ..b.keys.device[:])
		write_u8(&w, u8(Post.Link))
		append(&w, ..packet)
		frame_end(&w, at)
	}
	testing.expect(t, session_input(to_a, w[:]))
	forwarded += len(session_queued(to_b))
	testing.expectf(t, forwarded >= COUNT * len(packet), "forwarded %d of %d", forwarded, COUNT * len(packet))
}

// Round 2. What a relay sends onward in the midst of a session's work is whole frames: the changes of a watch let go
// of, still being gathered, are closed first, and nothing is left pointing past what was sent.
@(test)
review_relay_flush_takes_whole_frames :: proc(t: ^testing.T) {
	state := seeded(201)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
	defer sim_destroy(&s)
	a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	to_a, to_b: ^Session
	for sess in relay.node.sessions {
		if sess.peer == a.keys.device {
			to_a = sess
		} else if sess.peer == b.keys.device {
			to_b = sess
		}
	}
	watch_id := to_b.watches[0].id
	filler := make([]byte, 8000, context.temp_allocator)
	for len(to_b.out) - to_b.sent < LINK_QUEUE - 9000 {
		sig := make([dynamic]byte, context.temp_allocator)
		sat := frame_begin(&sig, .Signal)
		append(&sig, ..b.keys.device[:])
		write_u8(&sig, u8(Post.Link))
		append(&sig, ..filler)
		frame_end(&sig, sat)
		testing.expect(t, session_input(to_a, sig[:]))
	}
	@(static) taken: [dynamic]byte
	clear(&taken)
	defer delete(taken)
	relay.node.host.flush = proc(data: rawptr, sess: ^Session) {
		out := session_queued(sess)
		append(&taken, ..out)
		session_sent(sess, len(out))
	}
	defer relay.node.host.flush = nil
	sim_write(&s, a)
	a_out := session_output(s.links[0].a)
	testing.expect(t, session_input(to_a, a_out))
	session_sent(s.links[0].a, len(a_out))
	w_unwatch := make([dynamic]byte, context.temp_allocator)
	uat := frame_begin(&w_unwatch, .Unwatch)
	write_varint(&w_unwatch, watch_id)
	frame_end(&w_unwatch, uat)
	testing.expect(t, session_input(to_b, w_unwatch[:]))
	sig := make([dynamic]byte, context.temp_allocator)
	sat := frame_begin(&sig, .Signal)
	append(&sig, ..b.keys.device[:])
	write_u8(&sig, u8(Post.Link))
	append(&sig, ..filler)
	frame_end(&sig, sat)
	_ = session_input(to_a, sig[:])
	// All that went, and all that is left, parses as whole frames.
	append(&taken, ..session_output(to_b))
	r := Reader{buf = taken[:]}
	for r.pos < len(r.buf) && !r.bad {
		size := read_varint(&r)
		frame := read_take(&r, int(size))
		testing.expectf(t, r.bad || len(frame) > 0, "an empty frame at %d", r.pos)
	}
	testing.expect(t, !r.bad, "what went onward is not whole frames")
}

// Round 2. What lanes given up held is no longer counted against what lanes may hold: calls cut short, however many,
// do not use up what a healthy one needs.
@(test)
review_lanes_given_up_hold_nothing :: proc(t: ^testing.T) {
	state := seeded(202)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 64)
	s.lanes = true
	defer sim_destroy(&s)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	b_sess := s.links[0].b
	partial := make([dynamic]byte, 0, (64 << 10) + 4, context.temp_allocator)
	write_varint(&partial, 128 << 10)
	resize(&partial, (64 << 10) + len(partial))
	for i in 0 ..< 127 {
		lane_id := u64(2 + i * 2)
		testing.expect(t, session_lane_input(b_sess, lane_id, 3, partial[:]))
		session_lane_heard(b_sess, lane_id, given_up = true)
		if l := lane_find(b_sess, lane_id); l != nil {
			session_lane_closed(b_sess, l)
		}
	}
	testing.expectf(t, len(b_sess.lanes) == 0, "%d lanes left", len(b_sess.lanes))
	ok := session_lane_input(b_sess, 10000, 3, partial[:])
	testing.expectf(t, ok && !b_sess.closing && b_sess.lane_held == len(partial), "held %d, ok %v, closing %v", b_sess.lane_held, ok, b_sess.closing)
}
