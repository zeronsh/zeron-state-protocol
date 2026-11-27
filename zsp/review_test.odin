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

// Round 8. A signal a relay drops for a session with too much waiting leaves no frame of that session's open, to be
// cut short in place and then rolled back over by a step that missed in a lazy store: what the peer is sent stays
// whole frames, and the change it was owed comes.
@(test)
review_dropped_signal_leaves_frames_whole :: proc(t: ^testing.T) {
	state := seeded(801)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	s.lazy = .Remote
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 64)
	defer sim_destroy(&s)
	a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	r := &relay.remote.remote
	relay.remote.host.fail = 0
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	rows := make([dynamic]Id, context.temp_allocator)
	for i in u64(0) ..< 120 {
		s.now += 3
		a.node.now = sim_now(&s, a)
		row := node_id(&a.node, 1)
		append(&rows, row)
		body: [24]byte
		put_u64(body[:], 1 << 32 | 5)
		put_u64(body[8:], 5)
		put_u64(body[16:], i + 1)
		_ = node_write(&a.node, {{row, PLACE, .Place, node_stamp(&a.node), body[:]}})
		if i % 40 == 39 {
			sim_settle(&s)
		}
	}
	sim_settle(&s)
	r.want_checkpoint = true
	sim_settle(&s)
	remote_rest(r)
	forget :: proc(relay: ^Sim_Node, r: ^Remote) {
		for no, entry in r.pages {
			if no != 0 {
				free(entry.pg)
				delete_key(&r.pages, no)
			}
		}
		for kind in Cached {
			for _, bytes in relay.remote.host.cache[kind] {
				delete(bytes)
			}
			clear(&relay.remote.host.cache[kind])
		}
	}
	forget(relay, r)
	to_a, to_b := s.links[0].b, s.links[1].b
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
	// One small change, owed to b.
	s.now += 3
	a.node.now = sim_now(&s, a)
	small_row := node_id(&a.node, 1)
	pbody: [24]byte
	put_u64(pbody[:], 1 << 32 | 5)
	put_u64(pbody[8:], 5)
	put_u64(pbody[16:], 99999)
	_ = node_write(&a.node, {{small_row, PLACE, .Place, node_stamp(&a.node), pbody[:]}})
	a_out := session_output(s.links[0].a)
	testing.expect(t, session_input(to_a, a_out))
	session_sent(s.links[0].a, len(a_out))
	for to_a.stalled {
		remote_work(r)
		remote_ops(r)
		for len(relay.remote.host.ops) > 0 {
			review_answer(&relay.remote.host, r, 0, true)
		}
		node_retry(&relay.node)
	}
	// A signal that takes b's session past what a relay holds for it: dropped.
	sig := make([dynamic]byte, context.temp_allocator)
	sat := frame_begin(&sig, .Signal)
	append(&sig, ..b.keys.device[:])
	write_u8(&sig, u8(Post.Link))
	append(&sig, ..make([]byte, 9000, context.temp_allocator))
	frame_end(&sig, sat)
	testing.expect(t, session_input(to_a, sig[:]))
	// Then a frame on b's session that answers in part and misses in part, so is rolled back.
	forget(relay, r)
	want := make([dynamic]byte, context.temp_allocator)
	wat := frame_begin(&want, .Want)
	write_u8(&want, 0)
	write_varint(&want, 2)
	write_pair(&want, rows[len(rows) - 1])
	write_varint(&want, 1)
	write_u8(&want, u8(Kind.Value))
	write_u8(&want, 0)
	write_stamp(&want, Stamp{s.now + 100, 2})
	write_pair(&want, rows[0])
	write_varint(&want, 1)
	write_u8(&want, u8(Kind.Value))
	write_u8(&want, 0)
	write_stamp(&want, Stamp{1, 1})
	frame_end(&want, wat)
	_ = session_input(to_b, want[:])
	out := session_queued(to_b)
	rd := Reader{buf = out}
	whole := true
	for rd.pos < len(rd.buf) && !rd.bad {
		size := read_varint(&rd)
		frame := read_take(&rd, int(size))
		whole &&= len(frame) > 0 && frame[0] != 0
	}
	ok := session_input(s.links[1].a, out)
	session_sent(to_b, len(out))
	sim_settle(&s)
	scan := row_scan(&b.node.store, small_row)
	_, has := row_next(&b.node.store, &scan)
	testing.expectf(t, ok && whole && !rd.bad && has, "frames whole %v, b has the change %v", whole && !rd.bad, has)
}

// A store not yet held to its roster resumes with it, whatever roster.old says: the one before it, which says what
// it changed; or the same one, which says nothing, as hosts once kept it at every start.
@(test)
review_resume_with_the_same_roster_before :: proc(t: ^testing.T) {
	mine, root: Key32
	for i in 0 ..< 32 {
		mine[i], root[i] = byte(i + 1), byte(i * 5 + 2)
	}
	for same in ([]bool{false, true}) {
		keys: Keyring
		keyring_init(&keys, mine)
		defer keyring_destroy(&keys)
		none: Roster
		d := draft_from(&none, 1 << 16)
		home := draft_scope(&d)
		draft_grant(&d, keys.device, keys.signer, home, {.Write}).owner = true
		first, ok := roster_sign(&keys, root, &d, context.temp_allocator)
		testing.expect(t, ok)
		was, parsed := roster_parse(first, ed25519_public(root))
		testing.expect(t, parsed)
		defer roster_destroy(&was)
		next := draft_from(&was, 2 << 16)
		draft_scope(&next)
		second, ok2 := roster_sign(&keys, root, &next, context.temp_allocator)
		testing.expect(t, ok2)
		m: Memory_Disk
		defer memory_disk_destroy(&m)
		n: Node
		testing.expect(t, node_init(&n, memory_disk(&m), ed25519_public(root), &keys, true))
		defer node_destroy(&n)
		before := second if same else first
		testing.expectf(t, node_resume(&n, before, second), "same %v: not resumed", same)
		serial, _ := roster_claims(second, n.space)
		testing.expectf(t, n.roster.serial == serial, "same %v: resumed with %x, not %x", same, n.roster.serial, serial)
	}
}
