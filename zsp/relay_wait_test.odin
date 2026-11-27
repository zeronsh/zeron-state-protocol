#+build !js
package zsp

import "base:runtime"
import "core:slice"
import "core:testing"

// b, of a world of a, b and a relay, as having joined: it has the keys it had, and nothing of the space but its id.
@(private = "file")
bare_b :: proc(t: ^testing.T, s: ^Sim) {
	sim_init(t, s, full = 2, partial = 0, relays = 1, ring = 64)
	b := s.nodes[1]
	testing.expect(t, s.nodes[2].node.roster.serial == 0, "the relay knows a roster already")
	testing.expect(t, len(b.keys.scopes) > 0, "b has no scope's key, as one that held one would")
	node_destroy(&b.node)
	memory_disk_destroy(&b.disk)
	b.disk = {}
	delete(b.roster)
	delete(b.roster_old)
	b.roster, b.roster_old = nil, nil
	b.bare = true
	sim_boot(s, b)
	testing.expect(t, b.node.roster.serial == 0)
	sim_link(s, 1, 2) // b dials the relay, before anyone who has the roster does
	sim_settle(s)
	b_to_relay, relay_to_b := s.links[0].a, s.links[0].b
	// Neither end can judge the other, and neither says anything it could only say ready: no watch of a scope b has
	// a key of, which the relay would refuse.
	testing.expectf(t, relay_to_b.fault == .None && !relay_to_b.closing, "the relay turned b away: %v", relay_to_b.fault)
	testing.expectf(t, b_to_relay.fault == .None && !b_to_relay.closing, "b gave up on the relay: %v", b_to_relay.fault)
	testing.expect(t, !relay_to_b.ready, "the relay took b for a member with no roster to say so")
	testing.expect(t, !b_to_relay.ready, "b took itself for admitted with no roster to say so")
	testing.expect(t, session_waited(b_to_relay) && session_waited(relay_to_b))
}

// A relay that knows no roster yet cannot say who belongs, and so says nothing yet: a device that has joined, with no
// roster either, waits there until a member brings one, and is admitted the moment it comes. Turned away instead, it
// would ask again only after a while that grows each time, however soon the roster came.
@(test)
review_relay_without_roster_waits :: proc(t: ^testing.T) {
	s: Sim
	bare_b(t, &s)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	b_to_relay, relay_to_b := s.links[0].a, s.links[0].b
	sim_link(&s, 0, 2) // a brings the roster
	sim_settle(&s)
	testing.expect(t, relay_to_b.ready && relay_to_b.fault == .None, "b was not admitted when the roster came")
	testing.expect(t, b_to_relay.ready && b_to_relay.fault == .None, "b did not take itself for admitted when the roster came")
	testing.expectf(t, b.node.roster.serial == a.node.roster.serial, "b has roster %x, not %x", b.node.roster.serial, a.node.roster.serial)
	testing.expect(t, node_member(&b.node), "b is not a member by it")
}

// And one that comes to have the roster itself, as given it here, says so to the relay it waits at, and both are ready
// at once, on the one connection.
@(test)
review_device_brings_the_roster_it_waited_for :: proc(t: ^testing.T) {
	s: Sim
	bare_b(t, &s)
	defer sim_destroy(&s)
	b := s.nodes[1]
	b_to_relay, relay_to_b := s.links[0].a, s.links[0].b
	testing.expect(t, node_adopt(&b.node, s.roster))
	sim_settle(&s)
	testing.expect(t, b_to_relay.ready && b_to_relay.fault == .None, "b did not take itself for admitted once it had the roster")
	testing.expect(t, relay_to_b.ready && relay_to_b.fault == .None, "the relay did not admit b once b brought the roster")
	testing.expect(t, s.nodes[2].node.roster.serial == b.node.roster.serial, "the relay did not take the roster b brought")
}

@(private = "file")
hello_frame :: proc(space: Key32, serial: u64, calls := false, relay := false) -> []byte {
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Hello)
	write_u8(&w, VERSION)
	write_u8(&w, u8(Hello_Flags{full = !calls, calls = calls, relay = relay}))
	space := space
	append(&w, ..space[:])
	write_varint(&w, serial)
	write_bytes(&w, nil)
	frame_end(&w, at)
	return w[:]
}

@(private = "file")
roster_frame :: proc(bytes: []byte) -> []byte {
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Roster)
	append(&w, ..bytes)
	frame_end(&w, at)
	return w[:]
}

// Rosters for these tests: three members of scope 1, and then one that revokes the second.
@(private = "file")
Three :: struct {
	root, space:  Key32,
	keys:         [3]Keyring,
	r1, r2_b:     []byte,
	serial:       u64, // of the second that revokes
}

@(private = "file")
three_init :: proc(x: ^Three) {
	x.root = Key32{0 = 11, 1 = 22}
	x.space = ed25519_public(x.root)
	for &k, i in x.keys {
		keyring_init(&k, Key32{1 = u8(i + 1)})
	}
	none: Roster
	d := draft_from(&none, 1000 << 16)
	scope := draft_scope(&d)
	for &k in x.keys {
		draft_grant(&d, k.device, k.signer, scope, {.Read, .Write, .Call})
	}
	ok: bool
	x.r1, ok = roster_sign(&x.keys[0], x.root, &d)
	assert(ok)
	r1, _ := roster_parse(x.r1, x.space)
	defer roster_destroy(&r1)
	d3 := draft_from(&r1, 2000 << 16)
	draft_revoke(&d3, x.keys[1].device, scope)
	x.r2_b, ok = roster_sign(&x.keys[0], x.root, &d3)
	assert(ok)
	r2, _ := roster_parse(x.r2_b, x.space)
	defer roster_destroy(&r2)
	x.serial = r2.serial
}

@(private = "file")
three_destroy :: proc(x: ^Three) {
	for &k in x.keys {
		keyring_destroy(&k)
	}
	delete(x.r1)
	delete(x.r2_b)
}

// A relay that sleeps keeps only sessions that are ready: one that has not yet said hello, or whose peer said it has a
// roster newer than the relay's and has not yet shown it, is not taken for ready when the relay wakes, by the roster the
// relay has then or by an older one the peer shows; it connects again.
@(test)
review_hibernation_keeps_only_ready_sessions :: proc(t: ^testing.T) {
	x: Three
	three_init(&x)
	defer three_destroy(&x)
	disk: Memory_Disk
	defer memory_disk_destroy(&disk)
	n: Node
	testing.expect(t, node_init(&n, memory_disk(&disk), x.space, nil, true))
	defer node_destroy(&n)
	n.now = 3000
	testing.expect(t, node_adopt(&n, x.r1))
	saved := make([dynamic]byte, context.temp_allocator)

	silent := session_open(&n, .Peer, false, x.keys[2].device)
	testing.expect(t, !session_save(silent, &saved), "a session that has not said hello was kept")

	waiting := session_open(&n, .Peer, false, x.keys[1].device)
	testing.expect(t, session_input(waiting, hello_frame(x.space, x.serial + 100)))
	session_sent(waiting, len(session_output(waiting)))
	testing.expect(t, waiting.greeted && waiting.accepted && !waiting.ready)
	clear(&saved)
	testing.expect(t, !session_save(waiting, &saved), "a session waiting for the roster its peer promised was kept")

	// And one saved so, as by an earlier version, is not woken; saved ready, it is.
	ready := session_open(&n, .Peer, false, x.keys[1].device)
	ready.greeted, ready.accepted, ready.ready, ready.cursor = true, true, true, n.events.next
	session_sent(ready, len(session_output(ready)))
	clear(&saved)
	testing.expect(t, session_save(ready, &saved))
	session_close(ready)
	flags := 1 // after the id's varint
	for saved[flags - 1] & 0x80 != 0 {
		flags += 1
	}
	unready := slice.clone(saved[:], context.temp_allocator)
	unready[flags] &~= 4
	_, woke := session_load(&n, unready)
	testing.expect(t, !woke, "a session saved as not ready was woken")
	again, woke_ready := session_load(&n, saved[:])
	testing.expect(t, woke_ready, "a session saved ready was not woken")
	if woke_ready {
		session_close(again)
	}
}

// A device judges, by the roster its peer itself shows, both the peer and whether it still belongs: one that waits for a
// peer's roster is not taken for ready by another's, as one revoking this device.
@(test)
review_device_waits_for_its_peers_roster :: proc(t: ^testing.T) {
	x: Three
	three_init(&x)
	defer three_destroy(&x)
	disk: Memory_Disk
	defer memory_disk_destroy(&disk)
	n: Node
	testing.expect(t, node_init(&n, memory_disk(&disk), x.space, &x.keys[1], true))
	defer node_destroy(&n)
	n.now = 3000
	testing.expect(t, node_adopt(&n, x.r1) && node_member(&n))
	owner := session_open(&n, .Peer, false, x.keys[0].device)
	peer := session_open(&n, .Peer, false, x.keys[2].device)
	calls := session_open(&n, .Calls, false, x.keys[2].device)
	testing.expect(t, session_input(owner, hello_frame(x.space, x.serial)))
	testing.expect(t, session_input(peer, hello_frame(x.space, x.serial)))
	testing.expect(t, session_input(calls, hello_frame(x.space, x.serial, calls = true)))
	_ = session_input(owner, roster_frame(x.r2_b)) // which revokes this device, and so ends this session
	testing.expect(t, !node_member(&n))
	testing.expectf(t, !peer.ready, "a peer's session was taken for ready on a device no longer a member")
	testing.expectf(t, !calls.ready, "a session for calls was taken for ready on a device no longer a member")
	// And each is let go of, the session for calls as the peer's: none waits on for a roster that has come.
	testing.expectf(t, peer.closing && peer.fault == .Denied, "a peer's session waits on: %v", peer.fault)
	testing.expectf(t, calls.closing && calls.fault == .Denied, "a session for calls waits on: %v", calls.fault)
}

// A device the roster no longer admits has no peers: not one it was with when it heard so, which is told the roster
// and let go of, nor a relay it dials after, which never needs to tell it, having the same roster.
@(test)
review_device_no_longer_a_member_has_no_peers :: proc(t: ^testing.T) {
	x: Three
	three_init(&x)
	defer three_destroy(&x)
	r1, _ := roster_parse(x.r1, x.space)
	defer roster_destroy(&r1)
	disk: Memory_Disk
	defer memory_disk_destroy(&disk)
	n: Node
	testing.expect(t, node_init(&n, memory_disk(&disk), x.space, &x.keys[1], true))
	defer node_destroy(&n)
	n.now = 3000
	testing.expect(t, node_adopt(&n, x.r1) && node_member(&n))
	peer := session_open(&n, .Peer, false, x.keys[2].device)
	testing.expect(t, session_input(peer, hello_frame(x.space, r1.serial)))
	testing.expect(t, peer.ready, "a member's session with a member was not ready")
	session_sent(peer, len(session_output(peer)))

	_ = node_adopt(&n, x.r2_b) // which revokes this device
	testing.expect(t, !node_member(&n))
	testing.expectf(t, !peer.ready || peer.closing, "a session went on with a device no longer a member")
	testing.expectf(t, peer.fault == .Denied, "and ended %v", peer.fault)
	said := session_output(peer)
	testing.expect(t, len(said) > len(x.r2_b), "the peer was not told the roster that ended it")

	relay_key := Key32{1 = 9}
	relay := session_open(&n, .Peer, true, x25519_public(relay_key), relay = true)
	session_sent(relay, len(session_output(relay)))
	_ = session_input(relay, hello_frame(x.space, n.roster.serial, relay = true))
	testing.expectf(t, !relay.ready || relay.closing, "a device no longer a member was ready with a relay")
	testing.expectf(t, relay.fault == .Denied, "and ended %v", relay.fault)
}

@(private = "file")
call_frame :: proc(call: u64, to: Key32, scope: Scope, method: string, body: string) -> []byte {
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Call)
	write_varint(&w, call)
	to := to
	append(&w, ..to[:])
	write_varint(&w, u64(scope))
	write_bytes(&w, transmute([]byte)method)
	write_bytes(&w, nil) // whose
	append(&w, body)
	frame_end(&w, at)
	return w[:]
}

@(private = "file")
pump :: proc(a, b: ^Session) {
	for moved := true; moved; {
		moved = false
		for pair in ([2][2]^Session{{a, b}, {b, a}}) {
			if out := session_output(pair[0]); len(out) > 0 {
				bytes := slice.clone(out, context.temp_allocator)
				session_sent(pair[0], len(out))
				_ = session_input(pair[1], bytes)
				moved = true
			}
		}
	}
}

// A session for calls between two devices that know no roster yet waits at both ends, as a peers' does, and is ready
// at both once either has a roster: a call from either end is then taken.
@(test)
review_calls_wait_for_a_roster_as_peers_do :: proc(t: ^testing.T) {
	x: Three
	three_init(&x)
	defer three_destroy(&x)
	da, db: Memory_Disk
	defer memory_disk_destroy(&da)
	defer memory_disk_destroy(&db)
	a, b: Node
	testing.expect(t, node_init(&a, memory_disk(&da), x.space, &x.keys[0], true))
	testing.expect(t, node_init(&b, memory_disk(&db), x.space, &x.keys[1], true))
	defer node_destroy(&a)
	defer node_destroy(&b)
	a.now, b.now = 3000, 3000
	to_b := session_open(&a, .Calls, true, x.keys[1].device)
	to_a := session_open(&b, .Calls, false, x.keys[0].device)
	pump(to_b, to_a)
	testing.expect(t, !to_b.ready && !to_a.ready && to_b.fault == .None && to_a.fault == .None, "ready with no roster")
	testing.expect(t, node_adopt(&a, x.r1))
	pump(to_b, to_a)
	testing.expectf(t, to_b.ready && to_a.ready, "ready: a's end %v, b's %v", to_b.ready, to_a.ready)
	testing.expect(t, session_input(to_b, call_frame(1, x.keys[0].device, 1, "", "hi")), "b's call refused at a")
	testing.expectf(t, to_b.fault == .None && !to_b.closing, "a's end failed: %v", to_b.fault)
}

// What came on a lane of a session waiting for a roster, as a call, is taken once the roster comes, whoever brings it:
// not left until the session next hears something, which may be never.
@(test)
review_lane_held_while_waiting_is_taken :: proc(t: ^testing.T) {
	x: Three
	three_init(&x)
	defer three_destroy(&x)
	disk: Memory_Disk
	defer memory_disk_destroy(&disk)
	n: Node
	testing.expect(t, node_init(&n, memory_disk(&disk), x.space, &x.keys[0], true))
	defer node_destroy(&n)
	n.now = 3000
	called := 0
	n.host.questions.data = &called
	n.host.questions.called = proc(data: rawptr, _: u64, _: Key32, _: Scope, _: []byte) {(^int)(data)^ += 1}
	s := session_open(&n, .Peer, false, x.keys[1].device)
	testing.expect(t, session_input(s, hello_frame(x.space, 0)))
	testing.expect(t, s.greeted && s.accepted && !s.ready, "not waiting for a roster")
	testing.expect(t, session_lane_input(s, 1, 0, call_frame(1, x.keys[0].device, 1, "", "world")))
	testing.expect(t, called == 0, "a call taken before the session was ready")
	testing.expect(t, node_adopt(&n, x.r1)) // the roster comes, not from this peer
	testing.expect(t, s.ready, "not ready once the roster came")
	testing.expectf(t, called == 1, "the call held on a lane was taken %d times, once the session was ready", called)
}

// Waiting is for a roster neither end has: a device with none, at one that said it has one, waits only for that one
// to send it, and if let go of meanwhile, failed as anyone the other end lets go of without a word.
@(test)
review_waited_only_for_a_roster_neither_has :: proc(t: ^testing.T) {
	x: Three
	three_init(&x)
	defer three_destroy(&x)
	disk: Memory_Disk
	defer memory_disk_destroy(&disk)
	n: Node
	testing.expect(t, node_init(&n, memory_disk(&disk), x.space, &x.keys[1], true))
	defer node_destroy(&n)
	n.now = 3000
	neither := session_open(&n, .Peer, true, Key32{1 = 9}, relay = true)
	session_sent(neither, len(session_output(neither)))
	testing.expect(t, session_input(neither, hello_frame(x.space, 0, relay = true)))
	testing.expect(t, session_waited(neither), "waiting at a relay with no roster either is not waiting")
	other := session_open(&n, .Peer, true, Key32{1 = 10}, relay = true)
	session_sent(other, len(session_output(other)))
	testing.expect(t, session_input(other, hello_frame(x.space, 42, relay = true)))
	testing.expect(t, !other.ready && !session_waited(other), "waiting for the relay's own roster taken for waiting for one neither has")
}

@(private = "file")
Victim :: struct {
	victim: ^Session,
	closed: bool,
}

// What is done for one session made ready by a roster may let go of another made ready with it, as a method its call
// came to may close it: that other is passed over, not read after it is gone.
@(test)
review_a_woken_session_let_go_of_meanwhile_is_passed_over :: proc(t: ^testing.T) {
	// From the heap itself, rather than the test's own allocator, which keeps what is let go of: so that under
	// AddressSanitizer, as ./x test runs this, what is read after it is let go of is caught.
	context.allocator = runtime.heap_allocator()
	x: Three
	three_init(&x)
	defer three_destroy(&x)
	disk: Memory_Disk
	defer memory_disk_destroy(&disk)
	n: Node
	testing.expect(t, node_init(&n, memory_disk(&disk), x.space, &x.keys[0], true))
	defer node_destroy(&n)
	n.now = 3000
	first := session_open(&n, .Peer, false, x.keys[1].device)
	second := session_open(&n, .Peer, false, x.keys[2].device)
	testing.expect(t, session_input(first, hello_frame(x.space, 0)) && session_input(second, hello_frame(x.space, 0)))
	testing.expect(t, session_lane_input(first, 1, 3, call_frame(1, x.keys[0].device, 1, "close_other", "hi")))
	v := Victim{victim = second}
	n.host.data = &v
	n.host.method = proc(data: rawptr, _: u64, _: Caller_Info, _: Scope, _: string, _: []byte) -> Maybe(Call_Fault) {
		v := (^Victim)(data)
		if !v.closed {
			v.closed = true
			session_close(v.victim)
		}
		return nil
	}
	testing.expect(t, node_adopt(&n, x.r1))
	testing.expect(t, v.closed, "the call held on the first's lane was never taken")
	testing.expect(t, len(n.sessions) == 1 && n.sessions[0] == first, "the one let go of is still there")
}

// A relay tells the others a device has gone as soon as its session fails, not when its host lets it go: by then it is
// no longer ready, and told nobody. Whether it failed as it was made ready, or was ready and the roster ended it.
@(test)
review_presence_told_as_a_session_fails :: proc(t: ^testing.T) {
	x: Three
	three_init(&x)
	defer three_destroy(&x)
	relay_key := Key32{1 = 99}
	for revoked in ([2]bool{false, true}) {
		dr, da, db: Memory_Disk
		defer memory_disk_destroy(&dr)
		defer memory_disk_destroy(&da)
		defer memory_disk_destroy(&db)
		r, a, b: Node
		testing.expect(t, node_init(&r, memory_disk(&dr), x.space, nil, true))
		testing.expect(t, node_init(&a, memory_disk(&da), x.space, &x.keys[0], true))
		testing.expect(t, node_init(&b, memory_disk(&db), x.space, &x.keys[1], true))
		defer node_destroy(&r)
		defer node_destroy(&a)
		defer node_destroy(&b)
		r.now, a.now, b.now = 3000, 3000, 3000
		if revoked {
			testing.expect(t, node_adopt(&r, x.r1) && node_adopt(&a, x.r1) && node_adopt(&b, x.r1))
		}
		to_a := session_open(&r, .Peer, false, x.keys[0].device)
		at_a := session_open(&a, .Peer, true, relay_key, relay = true)
		to_b := session_open(&r, .Peer, false, x.keys[1].device)
		at_b := session_open(&b, .Peer, true, relay_key, relay = true)
		pump(to_a, at_a)
		pump(to_b, at_b)
		pump(to_a, at_a)
		if revoked {
			testing.expect(t, slice.contains(at_a.online[:], x.keys[1].device), "a was not told b is there")
			testing.expect(t, node_adopt(&a, x.r2_b)) // which revokes b, and goes to the relay
			pump(to_a, at_a)
			testing.expectf(t, to_b.closing && to_b.fault == .Denied, "b's session at the relay: %v", to_b.fault)
		} else {
			// b waits at a relay with no roster, with a call on a lane its rights will not allow: made ready by the
			// roster, it fails at once.
			testing.expect(t, session_lane_input(to_b, 1, 3, call_frame(1, x.keys[0].device, 1, "ping", "")))
			testing.expect(t, node_adopt(&r, x.r1))
			testing.expectf(t, to_b.closing && !to_b.ready, "b's session at the relay did not fail: %v", to_b.fault)
		}
		pump(to_a, at_a)
		testing.expectf(t, !slice.contains(at_a.online[:], x.keys[1].device), "revoked %v: a still sees b there, before b is let go of", revoked)
		pump(to_b, at_b)
		session_close(to_b)
		pump(to_a, at_a)
		testing.expectf(t, !slice.contains(at_a.online[:], x.keys[1].device), "revoked %v: a still sees b there", revoked)
	}
}
