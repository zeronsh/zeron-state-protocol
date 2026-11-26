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
