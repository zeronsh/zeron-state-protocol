#+build !js
package zsp

import "core:crypto/ed25519"
import "core:math/rand"
import "core:slice"
import "core:testing"

// Each of these was once an attack, or a failure, that worked. Most were found by an independent review.

@(private)
pass_all :: proc(s: ^Sim, rounds := 12) {
	for _ in 0 ..< rounds {
		for l in s.links {
			for pair in ([][2]^Session{{l.a, l.b}, {l.b, l.a}}) {
				out := session_output(pair[0])
				copied := make([]byte, len(out), context.temp_allocator)
				copy(copied, out)
				session_sent(pair[0], len(out))
				session_input(pair[1], copied)
			}
		}
		for x in s.nodes {
			node_sync(&x.node)
		}
	}
}

@(private)
raw_cells :: proc(cells: []Cell) -> []byte {
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Cells)
	write_varint(&w, 1)
	for &c, i in cells {
		write_cell(&w, &c, i > 0 && cells[i - 1].row == c.row)
	}
	frame_end(&w, at)
	return w[:]
}

// A device that is no longer a member cannot call itself a relay.
@(test)
a_relay_is_whom_you_dialled :: proc(t: ^testing.T) {
	state := seeded(31)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	a := s.nodes[0]
	stranger := test_keyring()
	defer keyring_destroy(&stranger)
	sim_put(&s, a, 1)
	p := session_open(&a.node, .Peer, true, stranger.device)
	hello := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&hello, .Hello)
	append(&hello, VERSION, 3)
	append(&hello, ..a.node.space[:])
	write_varint(&hello, a.node.roster.serial)
	write_varint(&hello, 0)
	frame_end(&hello, at)
	session_input(p, hello[:])
	testing.expect(t, !p.ready && len(p.grants) == 0)
	session_close(p)
}

// No stamp a writer may send can leave others unable to write.
@(test)
a_stamp_cannot_brick_a_space :: proc(t: ^testing.T) {
	state := seeded(32)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	pass_all(&s)
	b.node.clock = 1 << 63 - 2
	body: [24]byte
	put_u64(body[:], 1 << 32 | 5)
	put_u64(body[8:], 5)
	row := node_id(&b.node, 1)
	c := Cell{row, PLACE, .Place, {1 << 63 - 1, 1}, body[:]}
	_ = cell_seal(&b.keys, &b.node.roster, &c)
	store_commit(&b.node.store, {c})
	pass_all(&s)
	testing.expect(t, a.node.clock < 1 << 62)
	sim_put(&s, a, 3)
	pass_all(&s)
	found := false
	for l in s.links {
		testing.expect(t, l.an != 0 || (l.a.fault == .None && l.b.fault == .None))
	}
	found = store_range(&s.nodes[2].node.store, KEY_MIN, KEY_MAX).count >= 1
	testing.expect(t, found)
}

// A window may only be compared within itself.
@(test)
a_list_stays_in_its_window :: proc(t: ^testing.T) {
	state := seeded(33)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	a := s.nodes[0]
	sim_link(&s, 1, 0)
	pass_all(&s)
	body: [24]byte
	put_u64(body[:], 2 << 32 | 5)
	put_u64(body[8:], 5)
	secret := node_id(&a.node, 2)
	testing.expect(t, node_write(&a.node, {{secret, PLACE, .Place, node_stamp(&a.node), body[:]}}))
	at_a := s.links[0].b
	clear(&at_a.grants)
	append(&at_a.grants, Grant{1, {.Read, .Write}, 0})
	pass_all(&s)
	session_sent(at_a, len(session_output(at_a)))
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Recon)
	write_varint(&w, 1 << 1)
	write_key(&w, scope_lo(1))
	write_key(&w, scope_hi(1))
	write_u8(&w, u8(Part.List))
	write_varint(&w, 1)
	write_key_delta(&w, KEY_MIN, place_key({2 << 32 | 5, 5}, 0, secret))
	write_u64(&w, 99)
	frame_end(&w, at)
	session_input(at_a, w[:])
	out := session_output(at_a)
	r := Reader{buf = out}
	for r.pos < len(out) {
		frame := read_bytes(&r)
		testing.expect(t, Message(frame[0]) != .Want)
	}
}

// Nothing a peer or client may send, and nothing that follows from it, outgrows a frame or a record.
@(test)
big_frames_are_survived :: proc(t: ^testing.T) {
	state := seeded(34)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 0, 0, 64)
	defer sim_destroy(&s)
	a := s.nodes[0]
	ui := sim_client(&s, a)
	cells := make([]Cell, 4000)
	defer delete(cells)
	for &c, i in cells {
		c = {{1 << 32, u64(i) + 1}, GRAVE, .Grave, {u64(i) + 1, 1}, nil}
	}
	session_input(ui, raw_cells(cells))
	session_close(ui)
	ui = sim_client(&s, a)
	big := make([]byte, MAX_CELL, context.temp_allocator)
	session_input(ui, raw_cells({{{1 << 32, 7}, DATA, .Value, {node_stamp(&a.node).time, 1}, big}}))
	scan := tree_scan(&a.node, a.node.cells, KEY_MIN, KEY_MAX)
	for leaf in tree_next(&scan) {
		c, at := cell_unkey(leaf)
		c.body = log_bytes(&a.node.store, at.off, at.len)
		testing.expect(t, cell_valid(&c))
	}
	session_close(ui)
}

// Two honest replicas with everything to tell each other do so within bounded frames.
@(test)
utter_disagreement_is_bounded :: proc(t: ^testing.T) {
	state := seeded(35)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	for x in s.nodes {
		for _ in 0 ..< 12_000 {
			sim_put(&s, x, u64(rand.uint32()))
		}
	}
	sim_link(&s, 0, 1)
	largest := 0
	for _ in 0 ..< 20_000 {
		busy := false
		for l in s.links {
			for pair in ([][2]^Session{{l.a, l.b}, {l.b, l.a}}) {
				out := session_output(pair[0])
				r := Reader{buf = out}
				for r.pos < len(out) {
					frame := read_bytes(&r)
					if Message(frame[0]) == .Recon || Message(frame[0]) == .Want {
						largest = max(largest, len(frame))
					}
				}
				busy |= len(out) > 0
				copied := make([]byte, len(out))
				copy(copied, out)
				session_sent(pair[0], len(out))
				session_input(pair[1], copied)
				delete(copied)
			}
		}
		for x in s.nodes {
			busy |= store_unsynced(&x.node.store)
			node_sync(&x.node)
		}
		if !busy {
			break
		}
		free_all(context.temp_allocator)
	}
	sim_check(&s)
	testing.expectf(t, largest < 512 << 10, "a frame of %d bytes", largest)
}

// Bundles absorb what came before them, pieces and bundles only, in whatever order all arrive.
@(test)
bundles_commute :: proc(t: ^testing.T) {
	named :: proc(stamps: ..Stamp) -> []byte {
		b := make([]byte, 4 + 16 * len(stamps), context.temp_allocator)
		put_u32(b, u32(len(stamps)))
		for s, i in stamps {
			put_u64(b[4 + i * 16:], s.time)
			put_u64(b[12 + i * 16:], s.salt)
		}
		return b
	}
	row := Id{1 << 32, 1}
	value := Cell{row, DATA, .Value, {10, 1}, nil}
	over := Cell{row, DATA, .Bundle, {20, 1}, named({10, 1})}
	x := Cell{row, DATA, .Bundle, {30, 1}, named({40, 2})}
	y := Cell{row, DATA, .Bundle, {40, 2}, named({30, 1})}
	testing.expect(t, !cell_valid(&x) || !cell_valid(&y))
	want: Census
	for order, i in ([][2]Cell{{value, over}, {over, value}}) {
		m: Memory_Disk
		defer memory_disk_destroy(&m)
		s: Store
		testing.expect(t, store_open(&s, memory_disk(&m)))
		defer store_close(&s)
		for c in order {
			store_commit(&s, {c})
		}
		if i == 0 {
			want = census(&s)
		}
		testing.expect_value(t, census(&s), want)
	}
}

// Evacuating a damaged segment loses what was damaged and nothing else.
@(test)
evacuation_keeps_the_living :: proc(t: ^testing.T) {
	m: Memory_Disk
	defer memory_disk_destroy(&m)
	s: Store
	testing.expect(t, store_open(&s, memory_disk(&m)))
	body: [SEGMENT / 128]byte
	for i in 0 ..< 60 {
		body[0] = byte(i)
		store_commit(&s, {{{1 << 32, u64(i) + 1}, DATA, .Value, {u64(i) + 1, 1}, body[:]}})
	}
	store_flush(&s)
	// Now most of the segment dies, and the rest must move; but a byte of it has rotted.
	for i in 0 ..< 90 {
		store_commit(&s, {{{1 << 32, 9999}, DATA, .Value, {u64(i) + 1000, 1}, body[:]}})
		store_flush(&s)
	}
	for i in 100 ..< 400 {
		store_commit(&s, {{{1 << 32, 9999}, DATA, .Value, {u64(i) + 2000, 1}, body[:]}})
		store_flush(&s)
	}
	m.log[0][RECORD_HEAD + 200] ~= 1
	for _ in 0 ..< 4 {
		testing.expect(t, store_checkpoint(&s))
	}
	readable := 0
	scan := tree_scan(&s, s.cells, KEY_MIN, KEY_MAX)
	for leaf in tree_next(&scan) {
		_, at := cell_unkey(leaf)
		if len(log_bytes(&s, at.off, at.len)) == at.len {
			readable += 1
		}
	}
	testing.expectf(t, readable >= 60 && !s.failed, "%d readable, failed %v", readable, s.failed)
	store_close(&s)
}

// Taking a right away does not unwrite what was written by right.
@(test)
downgrades_keep_history :: proc(t: ^testing.T) {
	root, space := test_root()
	a, b := test_keyring(), test_keyring()
	defer keyring_destroy(&a)
	defer keyring_destroy(&b)
	none: Roster
	d := draft_from(&none, 100)
	shown := draft_scope(&d, {.Signed})
	draft_grant(&d, a.device, a.signer, shown, {.Write}).owner = true
	draft_grant(&d, b.device, b.signer, shown, {.Write})
	r1 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r1)
	testing.expect(t, roster_unwrap(&a, &r1) && roster_unwrap(&b, &r1))
	post := test_cell(shown)
	testing.expect(t, cell_seal(&b, &r1, &post))
	d = draft_from(&r1, 100)
	draft_grant(&d, b.device, b.signer, shown, {.Read})
	r2 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r2)
	testing.expect(t, cell_authentic(&r2, &post))
	testing.expect(t, .Write not_in member_rights(roster_member(&r2, b.device), shown))
}

// A hibernating relay does not wake a device that was revoked.
@(test)
revoked_devices_stay_asleep :: proc(t: ^testing.T) {
	state := seeded(38)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	sim_link(&s, 1, 2)
	pass_all(&s)
	relay := s.nodes[2]
	at_relay := s.links[0].b
	saved := make([dynamic]byte, context.temp_allocator)
	testing.expect(t, session_save(at_relay, &saved))
	for &m in relay.node.roster.members {
		m.admin = false
		for &g in m.grants {
			g.until = 1
		}
	}
	revived, ok := session_load(&relay.node, saved[:])
	testing.expect(t, !ok)
	if ok {
		session_close(revived)
	}
}

// Review of the strip, round 1. What a hibernating relay kept is resumed only if it is what this node saved: not with
// the id of none, nor another session's, nor flags it does not know.
@(test)
only_what_was_saved_is_resumed :: proc(t: ^testing.T) {
	state := seeded(40)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	sim_link(&s, 1, 2)
	pass_all(&s)
	relay := s.nodes[2]
	at_relay := s.links[0].b
	saved := make([dynamic]byte, context.temp_allocator)
	testing.expect(t, session_save(at_relay, &saved))
	sessions := len(relay.node.sessions)
	odd :: proc(saved: []byte, id: u64, flags: u8) -> []byte {
		r := Reader{buf = saved}
		_ = read_varint(&r)
		_ = read_u8(&r)
		w := make([dynamic]byte, context.temp_allocator)
		write_varint(&w, id)
		append(&w, flags)
		append(&w, ..saved[r.pos:])
		return w[:]
	}
	flags := saved[1] if at_relay.id < 128 else saved[2]
	for bad in ([][]byte{odd(saved[:], 0, flags), odd(saved[:], u64(at_relay.id), flags), odd(saved[:], 999, flags | 64), odd(saved[:], 999, flags | 128)}) {
		revived, ok := session_load(&relay.node, bad)
		testing.expect(t, !ok)
		if ok {
			session_close(revived)
		}
	}
	testing.expect_value(t, len(relay.node.sessions), sessions)
	revived, ok := session_load(&relay.node, odd(saved[:], 999, flags))
	testing.expect(t, ok) // and so it was the id and the flags alone that were refused
	if ok {
		session_close(revived)
	}
}

// Review of the strip, round 2. What a partial replica kept is not resumed at another session's cost: one saved with a
// live session's id, or that turns out not to be sound, takes away none of what the live one asked upstream for, and
// leaves the count of watches as it was.
@(test)
a_load_refused_takes_nothing_away :: proc(t: ^testing.T) {
	state := seeded(41)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 1, 1, 64)
	defer sim_destroy(&s)
	sim_link(&s, 1, 2)
	pass_all(&s)
	partial := s.nodes[1]
	live := s.links[0].a
	saved := make([dynamic]byte, context.temp_allocator)
	testing.expect(t, session_save(live, &saved))
	append(&partial.node.interests, Interest{id = INTEREST | 42, session = live.id})
	interests, next_watch := len(partial.node.interests), partial.node.next_watch
	with :: proc(saved: []byte, id: u64, watch_then_garbage: bool) -> []byte {
		r := Reader{buf = saved}
		_ = read_varint(&r)
		w := make([dynamic]byte, context.temp_allocator)
		write_varint(&w, id)
		append(&w, ..saved[r.pos:])
		if watch_then_garbage {
			write_varint(&w, 9)
			write_u8(&w, 1 | 8)
			write_key(&w, KEY_MIN)
			write_key(&w, KEY_MAX)
			write_varint(&w, INTEREST | 999_999)
			append(&w, 1) // a watch cut short
		}
		return w[:]
	}
	for bad in ([][]byte{with(saved[:], u64(live.id), false), with(saved[:], u64(live.id), true), with(saved[:], 999, true)}) {
		revived, ok := session_load(&partial.node, bad)
		testing.expect(t, !ok)
		if ok {
			session_close(revived)
		}
		testing.expect_value(t, len(partial.node.interests), interests)
		testing.expect_value(t, partial.node.next_watch, next_watch)
	}
	testing.expect(t, partial.node.interests[interests - 1].id == INTEREST | 42)
	pop(&partial.node.interests)
}

// Either end of a direct link may hush a relay, and both listen again when it goes.
@(test)
hushing_is_mutual :: proc(t: ^testing.T) {
	state := seeded(39)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	for l in s.links {
		testing.expectf(t, l.bn != 2 || l.a.paused, "node %d still listens twice", l.an)
	}
	// What each writes still reaches the other, and the relay.
	sim_put(&s, s.nodes[0], 1)
	sim_put(&s, s.nodes[1], 2)
	sim_settle(&s)
	sim_check(&s)
	// The direct link goes, and both listen again.
	#reverse for l, i in s.links {
		if l.bn == 1 {
			sim_cut(&s, i)
		}
	}
	sim_settle(&s)
	for l in s.links {
		testing.expect(t, !l.a.paused)
	}
	sim_put(&s, s.nodes[0], 3)
	sim_settle(&s)
	sim_check(&s)
}

// Live text in a signed scope is as hard to forge as anything else in it, and cannot be said again later.
@(test)
live_text_is_signed :: proc(t: ^testing.T) {
	state := seeded(40)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 1, 64) // the third device only reads scope 2
	defer sim_destroy(&s)
	for i in 0 ..< 3 {
		sim_link(&s, i, 3)
	}
	sim_settle(&s)
	body: [24]byte
	put_u64(body[:], 2 << 32 | 5)
	put_u64(body[8:], 5)
	row := node_id(&s.nodes[0].node, 2)
	testing.expect(t, node_write(&s.nodes[0].node, {{row, PLACE, .Place, node_stamp(&s.nodes[0].node), body[:]}}))
	sim_settle(&s)
	reader, writer := &s.nodes[2].node, &s.nodes[0].node
	keys := keyring_scope(reader.keys, 2)
	forged := Live{row = row, slot = DATA, piece = 7, body = {2, 1, 'x'}, stamp = node_stamp(reader)}
	testing.expect(t, live_seal(reader, keys, true, &forged))
	testing.expect(t, !live_open(writer, keyring_scope(writer.keys, 2), true, &forged))
	honest := Live{row = row, slot = DATA, piece = 7, body = {2, 1, 'x'}, stamp = node_stamp(writer)}
	testing.expect(t, live_seal(writer, keyring_scope(writer.keys, 2), true, &honest))
	sealed := honest
	testing.expect(t, live_open(reader, keys, true, &honest) && len(honest.body) == 3 && honest.body[2] == 'x')
	// And a relay checks it without reading it.
	testing.expect(t, live_open(&s.nodes[3].node, nil, true, &sealed))
	testing.expect(t, !live_open(&s.nodes[3].node, nil, true, &forged))
}

// A key that was given up seals nothing later; what was rightly sealed by those who had not heard survives.
@(test)
rotation_is_not_retroactive :: proc(t: ^testing.T) {
	state := seeded(41)
	context.random_generator = rand.default_random_generator(&state)
	root, space := test_root()
	a, b, c: Sim_Node
	for x in ([]^Sim_Node{&a, &b, &c}) {
		x.keys = test_keyring()
		x.full = true
	}
	defer for x in ([]^Sim_Node{&a, &b, &c}) {
		node_destroy(&x.node)
		keyring_destroy(&x.keys)
		memory_disk_destroy(&x.disk)
	}
	none: Roster
	d := draft_from(&none, 1)
	home := draft_scope(&d)
	for x, i in ([]^Sim_Node{&a, &b, &c}) {
		draft_grant(&d, x.keys.device, x.keys.signer, home, {.Write}).owner = i == 0
	}
	first, _ := roster_sign(&a.keys, root, &d, context.temp_allocator)
	for x in ([]^Sim_Node{&a, &b, &c}) {
		testing.expect(t, node_init(&x.node, memory_disk(&x.disk), space, &x.keys, true, 64))
		x.node.now = 1_800_000_000_000
		testing.expect(t, node_adopt(&x.node, first))
	}
	put :: proc(n: ^Node, home: Scope) -> Id {
		body := make([]byte, 24, context.temp_allocator)
		put_u64(body, u64(home) << 32 | 5)
		put_u64(body[8:], 5)
		row := node_id(n, home)
		node_write(n, {{row, PLACE, .Place, node_stamp(n), body}})
		return row
	}
	put(&a.node, home)
	// c is revoked; b, offline, has not heard, and goes on writing under the old key.
	dn := draft_from(&a.node.roster, a.node.clock)
	draft_revoke(&dn, c.keys.device)
	second, ok := roster_sign(&a.keys, root, &dn, context.temp_allocator)
	testing.expect(t, ok && node_adopt(&a.node, second))
	for x in ([]^Sim_Node{&b, &c}) {
		x.node.now += 5000
	}
	put(&b.node, home)
	// What c seals from now on, nobody takes.
	body: [24]byte
	put_u64(body[:], u64(home) << 32 | 5)
	put_u64(body[8:], 6)
	late := Cell{node_id(&c.node, home), PLACE, .Place, node_stamp(&c.node), body[:]}
	testing.expect(t, cell_seal(&c.keys, &c.node.roster, &late))
	testing.expect(t, !cell_authentic(&a.node.roster, &late))
	// When b hears, its own late writing is sealed anew, under the same identity, and is welcome.
	before := census(&b.node.store)
	testing.expect(t, node_adopt(&b.node, second))
	after := census(&b.node.store)
	testing.expect(t, after.shelf == before.shelf && after.cells == before.cells && after.bodies != before.bodies)
	scan := tree_scan(&b.node, b.node.cells, KEY_MIN, KEY_MAX)
	for leaf in tree_next(&scan) {
		cell, at := cell_unkey(leaf)
		cell.body = log_bytes(&b.node.store, at.off, at.len)
		testing.expect(t, cell_authentic(&a.node.roster, &cell) && cell_open(&a.keys, &a.node.roster, &cell))
	}
	testing.expect(t, !cell_authentic(&b.node.roster, &late))
}

// Text compares what it was shown with what was sealed, byte for byte; and no piece is nobody.
@(test)
text_trusts_bytes :: proc(t: ^testing.T) {
	x, y: Text
	defer text_destroy(&x)
	defer text_destroy(&y)
	ops :: proc(s: string) -> []byte {
		w := make([dynamic]byte, context.temp_allocator)
		append(&w, 1, 0, 0)
		write_bytes(&w, transmute([]byte)s)
		return w[:]
	}
	sealed := Cell{{1 << 32, 1}, DATA, .Piece, {1, 1}, nil}
	body := make([dynamic]byte, context.temp_allocator)
	write_u64(&body, 5)
	append(&body, ..ops("cacc"))
	sealed.body = body[:]
	text_live(&x, 5, 0, ops("bcbc"))
	if text_apply(&x, &sealed) == .Rebuild {
		text_destroy(&x)
		text_apply(&x, &sealed)
	}
	text_apply(&y, &sealed)
	testing.expect_value(t, text_string(&x), text_string(&y))
	nobody := sealed
	zero := make([dynamic]byte, context.temp_allocator)
	write_u64(&zero, 0)
	append(&zero, ..ops("hello"))
	nobody.body, nobody.stamp = zero[:], {2, 2}
	z: Text
	defer text_destroy(&z)
	testing.expect_value(t, text_apply(&z, &nobody), Text_Result.Same)
}

// ---------------------------------------------------------------- the second review

@(private)
test_amend :: proc(s: ^Sim, x: ^Sim_Node, change: proc(s: ^Sim, d: ^Draft)) -> bool {
	d := draft_from(&x.node.roster, max(x.node.clock, x.node.now << 16))
	change(s, &d)
	bytes, ok := roster_sign(&x.keys, s.root, &d, context.temp_allocator)
	return ok && node_adopt(&x.node, bytes)
}

// Sets every clock right.
@(private)
sim_level :: proc(s: ^Sim) {
	for x in s.nodes {
		x.skew = 0
		x.node.now = s.now
	}
}

// A hushed relay is asked about a scope that came to be while it was hushed.
@(test)
hushed_relays_hear_of_new_scopes :: proc(t: ^testing.T) {
	state := seeded(50)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 1, 64)
	defer sim_destroy(&s)
	sim_link(&s, 0, 3)
	sim_link(&s, 1, 3)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	testing.expect(t, s.links[0].a.paused)
	// The relay has a scope, and a row in it, that the first has yet to hear of; which it does, from elsewhere.
	third, relay, first := s.nodes[2], s.nodes[3], s.nodes[0]
	testing.expect(t, test_amend(&s, third, proc(s: ^Sim, d: ^Draft) {
		id := draft_scope(d)
		for x in s.nodes {
			if !x.relay {
				draft_grant(d, x.keys.device, x.keys.signer, id, {.Write})
			}
		}
	}))
	body: [24]byte
	put_u64(body[:], 3 << 32 | 5)
	put_u64(body[8:], 5)
	c := Cell{node_id(&third.node, 3), PLACE, .Place, node_stamp(&third.node), body[:]}
	testing.expect(t, node_write(&third.node, {c}))
	testing.expect(t, cell_seal(&third.keys, &third.node.roster, &c))
	testing.expect(t, node_adopt(&relay.node, third.node.roster.bytes))
	store_commit(&relay.node.store, {c})
	for x in relay.node.sessions {
		x.cursor = relay.node.events.next // sent, while it was asked to hush
	}
	testing.expect(t, node_adopt(&first.node, third.node.roster.bytes))
	testing.expect(t, !s.links[0].a.paused)
	sim_settle(&s)
	testing.expect_value(t, store_range(&first.node.store, scope_lo(3), scope_hi(3)).count, 1)
}

// Nobody may be made to send what others will not take; and while clocks disagree, dialling again is enough.
@(test)
a_writer_cannot_outrun_the_clock :: proc(t: ^testing.T) {
	state := seeded(51)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	s.now += 1000
	for x in s.nodes {
		x.node.now = s.now
	}
	relay.node.now -= 50 // a little behind
	put :: proc(n: ^Node) -> bool {
		body := make([]byte, 24, context.temp_allocator)
		put_u64(body, 1 << 32 | 5)
		put_u64(body[8:], 5)
		return node_write(n, {{node_id(n, 1), PLACE, .Place, node_stamp(n), body}})
	}
	// As late a stamp as a will take.
	b.node.clock = (s.now + LEAP_MS) << 16 | 0xfffe
	testing.expect(t, put(&b.node))
	sim_link(&s, 0, 1)
	sim_settle(&s)
	testing.expect(t, put(&a.node))
	sim_cut(&s, 0)
	sim_link(&s, 0, 2)
	pass_all(&s)
	testing.expect(t, s.links[0].b.fault == .Clock || s.links[0].b.fault == .None)
	sim_cut(&s, 0)
	for x in s.nodes {
		x.node.now += 60
	}
	sim_link(&s, 0, 2)
	sim_settle(&s)
	testing.expect_value(t, census(&relay.node.store), census(&a.node.store))
	// And what is further ahead than that, nobody takes.
	far := Cell{node_id(&b.node, 1), DATA, .Value, {(s.now + 60 * 60 * 1000) << 16, 1}, nil}
	testing.expect(t, !stamp_timely(far.stamp, s.now))
}

// Whoever has lost the right to write cannot touch what was made since, whatever time they pretend it is.
@(test)
the_past_cannot_kill_the_future :: proc(t: ^testing.T) {
	row := Id{1 << 32 | 1_700_000_100, 5}
	old := Cell{row, GRAVE, .Grave, {1_700_000_099_999 << 16, 1}, nil}
	testing.expect(t, !cell_valid(&old))
	old.stamp.time = 1_700_000_100_000 << 16
	testing.expect(t, cell_valid(&old))
	piece := Cell{row, DATA, .Piece, {1, 1}, nil}
	testing.expect(t, !cell_valid(&piece))
}

// A device that first meets a newer roster as it starts holds what it has against it all the same; and what
// was written since the last checkpoint counts towards what time it is.
@(test)
starting_is_hearing :: proc(t: ^testing.T) {
	state := seeded(53)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	sim_level(&s)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	sim_cut(&s, 1)
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		d.scopes[0].rotate = true
	}))
	s.now += 10_000
	sim_put(&s, b, 1) // has not heard
	store_sync(&b.node.store)
	testing.expect_value(t, store_clock(memory_disk(&b.disk)), b.node.clock)
	node_destroy(&b.node)
	delete(b.roster)
	b.roster = make([]byte, len(a.node.roster.bytes))
	copy(b.roster, a.node.roster.bytes)
	sim_boot(&s, b)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	sim_check(&s)
	testing.expect_value(t, store_range(&a.node.store, KEY_MIN, KEY_MAX).count, 1)
	// Having done so once, it does not again.
	testing.expect_value(t, b.node.serial, b.node.roster.serial)
	testing.expect_value(t, b.node.serial_kept, b.node.roster.serial)
}

// Whether or not its disk can keep up, a device that hears of a revocation acts on it.
@(test)
a_failing_disk_does_not_admit_the_revoked :: proc(t: ^testing.T) {
	state := seeded(54)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	a := s.nodes[0]
	sim_link(&s, 1, 0)
	sim_settle(&s)
	sim_put(&s, a, 1)
	a.disk.fail = true
	testing.expect(t, !test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		draft_revoke(d, s.nodes[1].keys.device)
	}))
	testing.expect(t, !s.links[0].b.ready && a.node.failed)
	testing.expect_value(t, string(a.roster), string(a.node.roster.bytes)) // and will have heard when it starts again
	a.disk.fail = false
}

// A client on this machine sees what a roster makes unlawful go.
@(test)
clients_see_what_is_forgotten :: proc(t: ^testing.T) {
	state := seeded(55)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	sim_level(&s)
	sim_link(&s, 1, 0)
	sim_settle(&s)
	body: [24]byte
	put_u64(body[:], 2 << 32 | 5)
	put_u64(body[8:], 5)
	s.now += 1000
	b.node.now = s.now
	testing.expect(t, node_write(&b.node, {{node_id(&b.node, 2), PLACE, .Place, node_stamp(&b.node), body[:]}}))
	sim_settle(&s)
	ui := session_open(&a.node, .Open, false)
	defer session_close(ui)
	a.node.host.authenticate = proc(_: rawptr, s: ^Session, _: []byte) {
		session_accept(s, {{2, {.Read, .Write}, 0}})
	}
	hello := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&hello, .Hello)
	append(&hello, VERSION, 0)
	resize(&hello, len(hello) + 32)
	append(&hello, 0, 0)
	frame_end(&hello, at)
	testing.expect(t, session_input(ui, hello[:]))
	sim_watch(ui, 1, list_lo({2 << 32 | 5, 5}), list_hi({2 << 32 | 5, 5}), 0, {data = true})
	session_sent(ui, len(session_output(ui)))
	// b's right turns out to have ended before that.
	d := draft_from(&a.node.roster, (s.now - 500) << 16)
	draft_grant(&d, b.keys.device, b.keys.signer, 2, {.Read})
	bytes, ok := roster_sign(&a.keys, s.root, &d, context.temp_allocator)
	testing.expect(t, ok && node_adopt(&a.node, bytes))
	testing.expect_value(t, store_range(&a.node.store, KEY_MIN, KEY_MAX).count, 0)
	restarted := false
	out := session_output(ui)
	r := Reader{buf = out}
	for r.pos < len(out) {
		frame := read_bytes(&r)
		f := Reader{buf = frame[1:]}
		restarted ||= Message(frame[0]) == .Synced && read_varint(&f) == 1 && Synced_Flags(read_u8(&f)).restart
	}
	testing.expect(t, restarted)
}

// Live text needs a right that stands, not one that stood; and as much may be said as may be sealed.
@(test)
live_text_needs_a_standing_right :: proc(t: ^testing.T) {
	state := seeded(56)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	a, b := s.nodes[0], s.nodes[1]
	row := node_id(&a.node, 2)
	l := Live{row = row, slot = DATA, piece = 7, body = {2, 1, 'x'}, stamp = node_stamp(&b.node)}
	testing.expect(t, live_seal(&b.node, keyring_scope(b.node.keys, 2), true, &l))
	again := l
	testing.expect(t, live_open(&a.node, keyring_scope(a.node.keys, 2), true, &again))
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		d.now = max(u64) >> 2 // however late it is said to have ended
		draft_grant(d, s.nodes[1].keys.device, s.nodes[1].keys.signer, 2, {.Read})
	}))
	again = l
	testing.expect(t, !live_open(&a.node, keyring_scope(a.node.keys, 2), true, &again))

	big := Live{row = row, slot = DATA, piece = 8, body = make([]byte, MAX_LIVE_OPEN, context.temp_allocator), stamp = node_stamp(&a.node)}
	testing.expect(t, live_seal(&a.node, keyring_scope(a.node.keys, 2), true, &big) && len(big.body) <= MAX_LIVE)
}

// Damage is found in every form: rotted, zeroed, or cut short; and whatever was in it is forgotten unread.
@(test)
evacuation_finds_all_damage :: proc(t: ^testing.T) {
	for damage in 0 ..< 5 {
		m: Memory_Disk
		defer memory_disk_destroy(&m)
		s: Store
		testing.expect(t, store_open(&s, memory_disk(&m)))
		defer store_close(&s)
		body: [SEGMENT / 128]byte
		first: int
		for i in 0 ..< 40 {
			place: [24]byte
			put_u64(place[:], 1 << 32 | 5)
			put_u64(place[8:], 5)
			put_u64(place[16:], u64(i))
			store_commit(&s, {{{1 << 32, u64(i) + 1}, PLACE, .Place, {u64(i) + 1, 1}, place[:]}, {{1 << 32, u64(i) + 1}, DATA, .Value, {u64(i) + 1, 2}, body[:]}})
			if i == 0 {
				first = len(s.buf)
			}
		}
		store_flush(&s)
		for i in 0 ..< 400 {
			store_commit(&s, {{{1 << 32, 9999}, DATA, .Value, {u64(i) + 1000, 1}, body[:]}})
			store_flush(&s)
		}
		testing.expect(t, store_tail(&s) / SEGMENT > 1)
		log := &m.log[0]
		switch damage {
		case 0:
			log[200] ~= 1
		case 1:
			for &x in log[:first] {
				x = 0
			}
		case 2:
			resize(log, first) // at the end of a record
		case 3:
			resize(log, first + 20) // in the middle of a placement
		case 4:
			for &x in log[:8] {
				x = 0xff
			}
		}
		for _ in 0 ..< 4 {
			testing.expectf(t, store_checkpoint(&s), "damage %d", damage)
		}
		held := 0
		scan := tree_scan(&s, s.cells, KEY_MIN, KEY_MAX)
		for leaf in tree_next(&scan) {
			_, at := cell_unkey(leaf)
			testing.expectf(t, len(log_bytes(&s, at.off, at.len)) == at.len, "damage %d", damage)
			held += 1
		}
		testing.expectf(t, !s.failed && held >= (3 if damage > 1 else 79), "damage %d: %d held, failed %v", damage, held, s.failed)
		check_shelf(t, &s)
	}
}

// What a dead process wrote is there to read, and not yet there to stay.
@(test)
what_is_found_is_not_yet_kept :: proc(t: ^testing.T) {
	m: Memory_Disk
	defer memory_disk_destroy(&m)
	s: Store
	testing.expect(t, store_open(&s, memory_disk(&m)))
	one := random_cell(4, 10)
	store_commit(&s, {one})
	testing.expect(t, store_flush(&s))
	store_close(&s) // the process dies; the system still has it
	testing.expect(t, store_open(&s, memory_disk(&m)))
	testing.expect(t, store_unsynced(&s))
	testing.expect(t, store_checkpoint(&s))
	testing.expect_value(t, m.kept, memory_disk_end(&m)) // before any page said it was there
	store_close(&s)
}

// The dialler's word that all was compared counts when something was, and it said so.
@(test)
level_is_not_for_the_asking :: proc(t: ^testing.T) {
	state := seeded(57)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	sim_link(&s, 1, 0)
	sim_settle(&s)
	at_a := s.links[0].b
	testing.expect(t, at_a.settled)
	for short in ([]bool{true, false}) {
		at_a.settled = false
		w := make([dynamic]byte, context.temp_allocator)
		at := frame_begin(&w, .Synced)
		append(&w, 0, 1)
		if !short {
			append(&w, 0, 0, 0, 0)
			for &x in at_a.watches {
				x.data = false
			}
		}
		frame_end(&w, at)
		session_input(at_a, w[:])
		testing.expect(t, !at_a.settled)
	}
}

// An acknowledgement says what it does not cover, so that a right regained finds what it was owed.
@(test)
refusals_are_not_acknowledged :: proc(t: ^testing.T) {
	state := seeded(58)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 1, 1, 64)
	defer sim_destroy(&s)
	a, phone, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	sim_level(&s)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	// The relay hears that the phone may not write; the phone has not yet, and writes.
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		d.now = 1 << 62
		draft_revoke(d, s.nodes[1].keys.device, 1)
	}))
	out := session_output(s.links[0].a)
	copied := make([]byte, len(out), context.temp_allocator)
	copy(copied, out)
	session_sent(s.links[0].a, len(out))
	session_input(s.links[0].b, copied)
	testing.expect_value(t, relay.node.roster.serial, a.node.roster.serial)
	sim_put(&s, phone, 1)
	sim_settle(&s)
	testing.expect_value(t, store_range(&a.node.store, KEY_MIN, KEY_MAX).count, 0)
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		draft_grant(d, s.nodes[1].keys.device, s.nodes[1].keys.signer, 1, {.Write})
	}))
	sim_settle(&s)
	testing.expect_value(t, store_range(&a.node.store, KEY_MIN, KEY_MAX).count, 1)
}

// A right lost and regained, by one who was there all along, brings what was missed between.
@(test)
rights_regained_bring_what_was_missed :: proc(t: ^testing.T) {
	state := seeded(59)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 1, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	sim_link(&s, 0, 3)
	sim_link(&s, 2, 3)
	sim_link(&s, 1, 2) // and one that is dialled by the one who loses it
	sim_settle(&s)
	testing.expect(t, test_amend(&s, s.nodes[0], proc(s: ^Sim, d: ^Draft) {
		draft_revoke(d, s.nodes[2].keys.device, 1)
	}))
	sim_settle(&s)
	sim_put(&s, s.nodes[0], 1)
	sim_settle(&s)
	testing.expect_value(t, store_range(&s.nodes[2].node.store, KEY_MIN, KEY_MAX).count, 0)
	testing.expect(t, test_amend(&s, s.nodes[0], proc(s: ^Sim, d: ^Draft) {
		draft_grant(d, s.nodes[2].keys.device, s.nodes[2].keys.signer, 1, {.Write})
	}))
	sim_settle(&s)
	sim_check(&s)
}

// Which key a late cell is sealed under again does not depend on which rosters a device happened to hear.
@(test)
resealing_is_canonical :: proc(t: ^testing.T) {
	state := seeded(60)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 0, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, b, c := s.nodes[0], s.nodes[1], s.nodes[2]
	rotate :: proc(s: ^Sim, d: ^Draft) {
		d.scopes[0].rotate = true
	}
	testing.expect(t, test_amend(&s, a, rotate))
	s.now += 1000
	sim_put(&s, b, 1)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	sim_cut(&s, 0)
	testing.expect(t, node_adopt(&b.node, a.node.roster.bytes))
	s.now += 1000
	a.node.now = s.now
	testing.expect(t, test_amend(&s, a, rotate))
	testing.expect(t, node_adopt(&b.node, a.node.roster.bytes)) // has heard both
	testing.expect(t, node_adopt(&c.node, a.node.roster.bytes)) // only the second
	testing.expect_value(t, census(&b.node.store), census(&c.node.store))
}

// An admin governs, and can be unmade; an owner cannot, least of all by an admin.
@(test)
admins_come_and_go :: proc(t: ^testing.T) {
	root, space := test_root()
	a, b, c := test_keyring(), test_keyring(), test_keyring()
	defer keyring_destroy(&a)
	defer keyring_destroy(&b)
	defer keyring_destroy(&c)
	none: Roster
	d := draft_from(&none, 100)
	home := draft_scope(&d)
	draft_grant(&d, a.device, a.signer, home, {.Write}).owner = true
	draft_grant(&d, b.device, b.signer, home, {.Write}).admin = true
	r1 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r1)
	testing.expect(t, roster_unwrap(&a, &r1) && roster_unwrap(&b, &r1))
	testing.expect(t, a.root == root && b.root == nil)
	testing.expect(t, keyring_rules(&a, &r1) && keyring_rules(&b, &r1) && !keyring_rules(&c, &r1))

	// An admin may admit, and may rotate.
	d = draft_from(&r1, 200)
	draft_grant(&d, c.device, c.signer, home, {.Write})
	d.scopes[0].rotate = true
	bytes, ok := roster_sign(&b, nil, &d, context.temp_allocator)
	testing.expect(t, ok)
	r2, sound := roster_parse(bytes, space)
	defer roster_destroy(&r2)
	testing.expect(t, sound && r2.serial > r1.serial && roster_unwrap(&c, &r2) && roster_unwrap(&a, &r2) && roster_unwrap(&b, &r2))

	// But may make no admin, and nobody else may sign at all.
	d = draft_from(&r2, 300)
	d.members[2].admin = true
	_, ok = roster_sign(&b, nil, &d, context.temp_allocator)
	testing.expect(t, !ok)
	d = draft_from(&r2, 300)
	_, ok = roster_sign(&c, nil, &d, context.temp_allocator)
	testing.expect(t, !ok)

	// Nor leave the owner out: the charter goes with every roster, and the owner's key is in it.
	d = draft_from(&r2, 300)
	ordered_remove(&d.members, 0)
	_, ok = roster_sign(&b, nil, &d, context.temp_allocator)
	testing.expect(t, !ok) // and one who signed it regardless
	d.owners = nil
	bytes, ok = roster_sign(&b, nil, &d, context.temp_allocator)
	testing.expect(t, ok)
	_, parsed := roster_parse(bytes, space)
	testing.expect(t, !parsed)

	// The owner unmakes the admin, and no serial the admin can reach outranks that.
	testing.expect(t, roster_unwrap(&a, &r2))
	d = draft_from(&r2, 400)
	draft_revoke(&d, b.device)
	r3 := test_publish(t, &a, root, space, &d)
	defer roster_destroy(&r3)
	testing.expect(t, roster_unwrap(&a, &r3) && !keyring_rules(&b, &r3))
	d = draft_from(&r2, 500)
	d.last |= 1 << TERM_SHIFT - 1
	d.last &~= 1 << COUNT_SHIFT
	bytes, ok = roster_sign(&b, nil, &d, context.temp_allocator)
	if ok {
		late, _ := roster_parse(bytes, space)
		testing.expect(t, late.serial < r3.serial)
		roster_destroy(&late)
	}

	// An admin who lacks a scope's keys cannot sign for it, rather than losing them for everyone.
	keyring_clear(&b)
	d = draft_from(&r2, 600)
	_, ok = roster_sign(&b, nil, &d, context.temp_allocator)
	testing.expect(t, !ok)
}

// Whoever offers what has been superseded is sent what superseded it, all of it.
@(test)
the_stale_are_told :: proc(t: ^testing.T) {
	state := seeded(61)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, b := s.nodes[0], s.nodes[1]
	sim_link(&s, 1, 0)
	sim_settle(&s)
	rows: [200]Id
	old := make([]Cell, len(rows), context.temp_allocator)
	for &row, i in rows {
		row = node_id(&b.node, 1)
		old[i] = {row, DATA, .Value, node_stamp(&b.node), nil}
		testing.expect(t, cell_seal(&b.keys, &b.node.roster, &old[i]))
	}
	for row in rows {
		c := Cell{row, DATA, .Value, node_stamp(&a.node), nil}
		c.stamp.time += 1 << 20
		testing.expect(t, cell_seal(&a.keys, &a.node.roster, &c))
		store_commit(&a.node.store, {c})
	}
	at_a := s.links[0].b
	testing.expect(t, session_input(at_a, raw_cells(old)))
	testing.expect_value(t, len(at_a.tasks) - at_a.task_head, len(rows))
	for task in at_a.tasks[at_a.task_head:] {
		testing.expect(t, slice.contains(rows[:], task.row))
	}
}

// Cells that came before their row's first place go with it to everyone, whoever brought the place.
@(test)
rows_come_into_view_whole :: proc(t: ^testing.T) {
	state := seeded(62)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 1, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	body: [24]byte
	put_u64(body[:], 1 << 32 | 5)
	put_u64(body[8:], 5)
	row := node_id(&b.node, 1)
	place := Cell{row, PLACE, .Place, node_stamp(&b.node), body[:]}
	piece := Cell{row, DATA, .Piece, node_stamp(&b.node), nil}
	testing.expect(t, node_write(&b.node, {place}))
	testing.expect(t, cell_seal(&b.keys, &b.node.roster, &piece))
	store_commit(&a.node.store, {piece})
	sim_link(&s, 0, 2)
	sim_settle(&s)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	sim_check(&s)
	testing.expect_value(t, census(&relay.node.store).cells.count, 2)
}

// What was withheld from a peer is not acknowledged by it, along with what was not.
@(test)
what_is_withheld_is_still_owed :: proc(t: ^testing.T) {
	state := seeded(63)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 1, 0, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	phone := s.nodes[1]
	sim_link(&s, 1, 0)
	sim_settle(&s)
	at_phone := s.links[0].a
	sim_put(&s, phone, 1)
	out := session_output(at_phone)
	copied := make([]byte, len(out), context.temp_allocator)
	copy(copied, out)
	session_sent(at_phone, len(out))
	// On its way; and now the row changes, while the peer may not read it.
	kept := at_phone.grants[0]
	at_phone.grants[0].rights = {}
	scan := tree_scan(&phone.node, phone.node.cells, KEY_MIN, KEY_MAX)
	leaf, _ := tree_next(&scan)
	row := Id{leaf.key[0], leaf.key[1]}
	testing.expect(t, node_write(&phone.node, {{row, DATA, .Value, node_stamp(&phone.node), nil}}))
	_ = session_output(at_phone)
	testing.expect(t, session_input(s.links[0].b, copied))
	sim_settle(&s)
	testing.expect(t, phone.node.outbox.root != 0)
	at_phone.grants[0] = kept
	outbox_send(at_phone)
	sim_settle(&s)
	testing.expect_value(t, census(&s.nodes[0].node.store), census(&phone.node.store))
	testing.expect_value(t, phone.node.outbox.root, 0)
}

// What a device that has gone had taken charge of, and told nobody, is offered again by whoever gave it.
@(test)
the_revoked_take_nothing_with_them :: proc(t: ^testing.T) {
	state := seeded(64)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 1, 1, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, phone := s.nodes[0], s.nodes[2]
	sim_link(&s, 2, 1)
	sim_settle(&s)
	sim_put(&s, phone, 1)
	sim_settle(&s)
	testing.expect_value(t, phone.node.outbox.root, 0)
	sim_cut(&s, 0)
	s.now += 1000
	a.node.now = s.now
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		draft_revoke(d, s.nodes[1].keys.device)
	}))
	sim_link(&s, 0, 3)
	sim_link(&s, 2, 3)
	sim_settle(&s)
	testing.expect_value(t, store_range(&a.node.store, KEY_MIN, KEY_MAX).count, 1)
	testing.expect_value(t, phone.node.outbox.root, 0)
}

// ---------------------------------------------------------------- the third review

// An admin gone bad garbles the keys it wraps for the owner, and the history, under a key of its own choosing.
// The owner still holds what it had, still owns the space, and takes it back with everyone's writing.
@(test)
an_owner_outlasts_a_rogue_admin :: proc(t: ^testing.T) {
	state := seeded(70)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 1, 64) // the first owns, the second is an admin
	defer sim_destroy(&s)
	sim_level(&s)
	a, b, c := s.nodes[0], s.nodes[1], s.nodes[2]
	for i in 0 ..< 3 {
		sim_link(&s, i, 3)
	}
	sim_put(&s, a, 1)
	sim_settle(&s)

	// Nobody can be rid of an owner the plain way.
	d := draft_from(&b.node.roster, max(b.node.clock, b.node.now << 16))
	draft_revoke(&d, a.keys.device)
	d.scopes[0].rotate = true
	bytes, ok := roster_sign(&b.keys, nil, &d, context.temp_allocator)
	testing.expect(t, ok)
	fair, sound := roster_parse(bytes, s.space)
	testing.expect(t, sound)
	for g in roster_member(&fair, a.keys.device).grants {
		testing.expect(t, g.until == 0)
	}
	// Nor by hand: the first of the owner's grants is made to have ended, and its key is not wrapped.
	shorn := make([dynamic]byte, context.temp_allocator)
	append(&shorn, ..fair.bytes)
	entry := 0
	for i in 0 ..< len(shorn) - 64 {
		if string(shorn[i:][:32]) == string(a.keys.device[:]) && string(shorn[i + 32:][:32]) == string(a.keys.signer[:]) {
			entry = i // the last: the charter's comes before
		}
	}
	testing.expect(t, shorn[entry + 64] == 0 && shorn[entry + 66] == 1 && shorn[entry + 68] == 0) // no subject; scope 1; in force
	shorn[entry + 68] = 1
	lost := int(uintptr(raw_data(fair.wraps)) - uintptr(raw_data(fair.bytes)))
	remove_range(&shorn, lost, lost + 48)
	resign: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_set_bytes(&resign, b.keys.seed[:]))
	ed25519.sign(&resign, shorn[:len(shorn) - 64], shorn[len(shorn) - 64:])
	_, usurped := roster_parse(shorn[:], s.space)
	testing.expect(t, !usurped)

	// So it is left its rights, and lied to about the keys.
	at := int(uintptr(raw_data(fair.wraps)) - uintptr(raw_data(fair.bytes)))
	bad := slice.clone(fair.bytes, context.temp_allocator)
	for &x in bad[at:][:48] {
		x ~= 0x55 // the owner's, for the first scope
	}
	history := int(uintptr(raw_data(fair.history)) - uintptr(raw_data(fair.bytes)))
	for &x in bad[history:][:len(fair.history)] {
		x ~= 0x55 // everyone's, of what came before
	}
	roster_destroy(&fair)
	sk: ed25519.Private_Key
	testing.expect(t, ed25519.private_key_set_bytes(&sk, b.keys.seed[:]))
	ed25519.sign(&sk, bad[:len(bad) - 64], bad[len(bad) - 64:])
	testing.expect(t, node_adopt(&b.node, bad))
	sim_settle(&s)
	testing.expect_value(t, a.node.roster.serial, b.node.roster.serial)
	testing.expect(t, a.keys.root != nil && keyring_scope(&a.keys, 1).epochs[1] == {} && keyring_scope(&a.keys, 1).epochs[0] != {})
	// Others write on, under a key the owner was never given.
	sim_put(&s, c, 2)
	sim_settle(&s)
	testing.expect_value(t, store_range(&a.node.store, scope_lo(1), scope_hi(1)).count, 1)

	// What was sealed under the key it was denied is named by that key, whatever time it claims.
	denied := Cell{row = {1 << 32, 1}, slot = DATA, kind = .Value, stamp = {1, 1}}
	denied.body = make([]byte, 24, context.temp_allocator)
	put_u32(denied.body, key_id(roster_scope(&c.node.roster, 1).commits[1]))
	testing.expect(t, cell_lawful(&c.node.roster, &denied))
	denied_id := get_u32(denied.body)

	// The owner's device dies, and comes back with what it had kept.
	#reverse for l, i in s.links {
		if l.an == 0 {
			sim_cut(&s, i)
		}
	}
	store_sync(&a.node.store)
	node_destroy(&a.node)
	keyring_destroy(&a.keys)
	keyring_init(&a.keys, a.secret)
	testing.expect(t, keyring_load(&a.keys, a.kept))
	sim_boot(&s, a)
	testing.expect(t, keyring_scope(&a.keys, 1).epochs[0] != {})

	// And takes it back.
	s.now += 1000
	a.node.now = s.now
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		draft_revoke(d, s.nodes[1].keys.device)
	}))
	testing.expect(t, epoch_void(roster_scope(&a.node.roster, 1), 2))
	denied.body = make([]byte, 24, context.temp_allocator)
	put_u32(denied.body, denied_id)
	testing.expect(t, !cell_lawful(&a.node.roster, &denied))
	sim_link(&s, 0, 3)
	for _ in 0 ..< 40 {
		pass_all(&s, 1)
	}
	testing.expect(t, !node_member(&b.node))
	testing.expect_value(t, store_range(&a.node.store, scope_lo(1), scope_hi(1)).count, 2)
	for x in ([]^Sim_Node{a, c, s.nodes[3]}) {
		testing.expect_value(t, census(&x.node.store), census(&a.node.store))
		scan := tree_scan(&x.node, x.node.cells, KEY_MIN, KEY_MAX)
		for leaf in tree_next(&scan) {
			cell, where_ := cell_unkey(leaf)
			cell.body = log_bytes(&x.node.store, where_.off, where_.len)
			testing.expect(t, cell_authentic(&a.node.roster, &cell) && cell_open(&a.keys, &a.node.roster, &cell))
		}
	}
	// No serial the admin can reach outranks that, and nobody may share a signer, or an owner's.
	testing.expect(t, a.node.roster.term > 1)
}

// Nobody in a roster is two, and no owner is another.
@(test)
members_are_who_they_are :: proc(t: ^testing.T) {
	root, space := test_root()
	a, b, c := test_keyring(), test_keyring(), test_keyring()
	defer keyring_destroy(&a)
	defer keyring_destroy(&b)
	defer keyring_destroy(&c)
	for way in 0 ..< 4 {
		none: Roster
		d := draft_from(&none, 100)
		home := draft_scope(&d)
		draft_grant(&d, a.device, a.signer, home, {.Write}).owner = true
		draft_grant(&d, b.device, b.signer, home, {.Write}).admin = true
		r1 := test_publish(t, &a, root, space, &d)
		defer roster_destroy(&r1)
		testing.expect(t, roster_unwrap(&b, &r1))
		d = draft_from(&r1, 200)
		switch way {
		case 1:
			draft_grant(&d, c.device, b.signer, home, {.Write}) // a stranger who signs as an admin
		case 2:
			d.members[0].signer = c.signer // an owner who signs as a stranger
		case 3:
			d.members[0].device = c.device // a stranger who signs as an owner
		}
		bytes, ok := roster_sign(&b, nil, &d, context.temp_allocator)
		r2, sound := roster_parse(bytes, space)
		testing.expectf(t, (ok && sound) == (way == 0), "way %d", way)
		if sound {
			roster_destroy(&r2)
		}
	}
}

// A store that was held against a later roster than the one found at the start loses nothing by it.
@(test)
an_older_roster_undoes_nothing :: proc(t: ^testing.T) {
	state := seeded(72)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a := s.nodes[0]
	sim_put(&s, a, 1)
	older: []byte
	defer delete(older)
	for i in 0 ..< 2 {
		s.now += 1000
		a.node.now = s.now
		testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
			d.scopes[0].rotate = true
		}))
		if i == 0 {
			older = slice.clone(a.node.roster.bytes)
		}
	}
	newer := slice.clone(a.node.roster.bytes)
	defer delete(newer)
	s.now += 1000
	sim_put(&s, a, 2)
	testing.expect(t, store_checkpoint(&a.node.store))
	want := census(&a.node.store)
	node_destroy(&a.node)
	delete(a.roster)
	delete(a.roster_old)
	a.roster_old = nil
	a.roster = slice.clone(older)
	sim_boot(&s, a)
	testing.expect_value(t, census(&a.node.store), want)
	testing.expect(t, node_adopt(&a.node, newer))
	testing.expect_value(t, census(&a.node.store), want)
}

// A forgery costs whoever sends it an answer to nothing.
@(test)
forgeries_are_not_answered :: proc(t: ^testing.T) {
	state := seeded(73)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 0, 64) // the third only reads scope 2
	defer sim_destroy(&s)
	sim_level(&s)
	a := s.nodes[0]
	sim_link(&s, 2, 0)
	sim_settle(&s)
	rows: [2]Id
	body: [24]byte
	put_u64(body[:], 2 << 32 | 5)
	put_u64(body[8:], 5)
	for &row in rows {
		row = node_id(&a.node, 2)
		testing.expect(t, node_write(&a.node, {{row, PLACE, .Place, node_stamp(&a.node), body[:]}, {row, DATA, .Value, node_stamp(&a.node), nil}}))
	}
	sim_settle(&s)
	at_a := s.links[0].b
	forged := make([]Cell, 200, context.temp_allocator)
	zeroes := make([]byte, 80, context.temp_allocator) // the first member's, under the right key, so far
	put_u32(zeroes[1:], key_id(roster_scope(&a.node.roster, 2).commits[0]))
	for &c, i in forged {
		c = {rows[i % 2], DATA, .Value, {row_born(rows[i % 2]) + u64(i), 1}, zeroes}
	}
	testing.expect(t, session_input(at_a, raw_cells(forged)))
	testing.expect_value(t, len(at_a.tasks) - at_a.task_head, 0)
	testing.expect(t, len(at_a.refused) > 0)
}

// A row is as young as all its maker has heard, so that no right the maker knows to have ended can reach it.
@(test)
rows_are_younger_than_what_ended :: proc(t: ^testing.T) {
	state := seeded(74)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, b := s.nodes[0], s.nodes[1]
	b.node.now -= 5 * 60 * 1000
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		draft_grant(d, s.nodes[1].keys.device, s.nodes[1].keys.signer, 2, {.Read})
	}))
	ended: u64
	for g in roster_member(&a.node.roster, b.keys.device).grants {
		ended = max(ended, g.until)
	}
	testing.expect(t, node_adopt(&b.node, a.node.roster.bytes))
	row := node_id(&b.node, 1)
	testing.expect(t, row_born(row) > ended && stamp_timely(node_stamp(&b.node), s.now))
}

// Who says they hold a later roster must show it.
@(test)
promised_rosters_are_shown :: proc(t: ^testing.T) {
	state := seeded(75)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 64)
	defer sim_destroy(&s)
	a := s.nodes[0]
	p := session_open(&a.node, .Peer, false, s.nodes[1].keys.device)
	defer session_close(p)
	w := make([dynamic]byte, context.temp_allocator)
	at := frame_begin(&w, .Hello)
	append(&w, VERSION, 1)
	append(&w, ..a.node.space[:])
	write_varint(&w, max(u64))
	write_varint(&w, 0)
	frame_end(&w, at)
	at = frame_begin(&w, .Roster)
	append(&w, "zsp-r1")
	append(&w, ..a.node.space[:])
	append(&w, 0, 0)
	frame_end(&w, at)
	session_input(p, w[:])
	testing.expect(t, !p.ready && p.fault == .Malformed)
}

// However fast rosters come, a window is settled by answers to the last asking; and what changed nothing for a
// peer asks nothing of it.
@(test)
asking_afresh_is_counted :: proc(t: ^testing.T) {
	state := seeded(76)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 2, 1, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, phone, relay := s.nodes[0], s.nodes[1], s.nodes[3]
	for i in 0 ..< 3 {
		sim_link(&s, i, 3)
	}
	sim_settle(&s)
	ui := sim_client(&s, phone)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo({1 << 32 | 5, 5}), list_hi({1 << 32 | 5, 5}), 50, {data = true, live = true})
	empty :: proc(s: ^Sim, d: ^Draft) {
		draft_scope(d)
	}
	for _ in 0 ..< 2 {
		testing.expect(t, test_amend(&s, a, empty))
		testing.expect(t, node_adopt(&phone.node, a.node.roster.bytes))
	}
	waiting := 0
	for it in phone.node.interests {
		waiting += it.waiting
	}
	owed := 0
	for x in phone.node.sessions {
		owed += len(x.owed)
	}
	testing.expect(t, waiting == 1 && owed == 1)
	sim_settle(&s)
	for it in phone.node.interests {
		testing.expect_value(t, it.waiting, 0)
	}
	// Nothing of the relay's interests is said again for a scope that has nothing to do with them.
	for x in relay.node.sessions {
		session_sent(x, len(session_output(x)))
	}
	before := relay.node.next_watch
	testing.expect(t, test_amend(&s, a, empty))
	testing.expect(t, node_adopt(&relay.node, a.node.roster.bytes))
	for x in relay.node.sessions {
		out := session_output(x)
		r := Reader{buf = out}
		for r.pos < len(out) {
			testing.expect(t, Message(read_bytes(&r)[0]) != .Watch)
		}
	}
	testing.expect_value(t, relay.node.next_watch, before)
}

// Who never could write somewhere offers nothing of it again.
@(test)
readers_offer_nothing :: proc(t: ^testing.T) {
	state := seeded(77)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 1, 0, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, phone := s.nodes[0], s.nodes[2]
	body: [24]byte
	put_u64(body[:], 2 << 32 | 5)
	put_u64(body[8:], 5)
	testing.expect(t, node_write(&a.node, {{node_id(&a.node, 2), PLACE, .Place, node_stamp(&a.node), body[:]}}))
	sim_link(&s, 2, 0)
	sim_settle(&s)
	ui := sim_client(&s, phone)
	defer session_close(ui)
	sim_watch(ui, 1, scope_lo(2), scope_hi(2), 0, {data = true})
	sim_settle(&s)
	testing.expect_value(t, store_range(&phone.node.store, KEY_MIN, KEY_MAX).count, 1)
	testing.expect(t, test_amend(&s, a, proc(s: ^Sim, d: ^Draft) {
		draft_grant(d, s.nodes[1].keys.device, s.nodes[1].keys.signer, 2, {.Read})
	}))
	testing.expect(t, node_adopt(&phone.node, a.node.roster.bytes))
	testing.expect_value(t, phone.node.outbox.root, 0)
}

// Two admins draw up rosters at once, each with a key for the same epoch and a scope of the same number. All
// agree which it is, whatever was in flight, and nothing is left that cannot be read.
@(test)
forks_heal :: proc(t: ^testing.T) {
	state := seeded(78)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 3, 0, 1, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, b, c, relay := s.nodes[0], s.nodes[1], s.nodes[2], s.nodes[3]
	both :: proc(s: ^Sim, d: ^Draft) {
		d.scopes[0].rotate = true
		id, shown := draft_scope(d), draft_scope(d, {.Signed})
		for x in s.nodes {
			if !x.relay {
				draft_grant(d, x.keys.device, x.keys.signer, id, {.Write})
				draft_grant(d, x.keys.device, x.keys.signer, shown, {.Write, .Vouch})
			}
		}
	}
	s.now += 1000
	a.node.now, b.node.now = s.now, s.now
	testing.expect(t, test_amend(&s, a, both))
	d := draft_from(&b.node.roster, max(b.node.clock, b.node.now << 16))
	both(&s, &d)
	bytes, ok := roster_sign(&b.keys, nil, &d, context.temp_allocator)
	testing.expect(t, ok && node_adopt(&b.node, bytes))
	testing.expect(t, node_adopt(&c.node, bytes) && a.node.roster.serial != b.node.roster.serial)
	s.now += 1000
	for x in ([]^Sim_Node{a, b, c}) {
		sim_put(&s, x, 1)
		body: [24]byte
		put_u64(body[:], 3 << 32 | 5)
		put_u64(body[8:], 5)
		testing.expect(t, node_write(&x.node, {{node_id(&x.node, 3), PLACE, .Place, node_stamp(&x.node), body[:]}}))
		put_u64(body[:], 4 << 32 | 5)
		testing.expect(t, node_write(&x.node, {{node_id(&x.node, 4), PLACE, .Place, node_stamp(&x.node), body[:]}}, transmute([]byte)string("zoe")))
	}
	// The relay has the one, and the other's writing is on its way to it already.
	winner := a if a.node.roster.serial > b.node.roster.serial else b
	testing.expect(t, node_adopt(&relay.node, winner.node.roster.bytes))
	for i in 0 ..< 3 {
		sim_link(&s, i, 3)
	}
	sim_settle(&s)
	sim_check(&s)
	testing.expect_value(t, store_range(&a.node.store, scope_lo(1), scope_hi(1)).count, 3)
	testing.expect_value(t, store_range(&a.node.store, scope_lo(3), scope_hi(3)).count, 3)
	// Whose name it was written in, it is in still.
	for x in ([]^Sim_Node{a, b, c}) {
		said: [3]bool
		scan := tree_scan(&x.node, x.node.cells, scope_lo(4), scope_hi(4))
		for leaf in tree_next(&scan) {
			cell, at := cell_unkey(leaf)
			cell.body = log_bytes(&x.node.store, at.off, at.len)
			by: By
			testing.expect(t, cell_open(&x.keys, &x.node.roster, &cell, &by))
			device, subject, vouched, known := cell_author(&x.node.roster, &cell, by)
			testing.expect(t, known && vouched && string(subject) == "zoe")
			for y, i in ([]^Sim_Node{a, b, c}) {
				said[i] ||= y.keys.device == device
			}
		}
		testing.expect(t, said[0] && said[1] && said[2])
	}
}

// What came from a peer does not keep the phone in debt to it.
@(test)
echoes_are_not_owed :: proc(t: ^testing.T) {
	state := seeded(79)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 1, 1, 0, 64)
	defer sim_destroy(&s)
	sim_level(&s)
	a, phone := s.nodes[0], s.nodes[1]
	sim_link(&s, 1, 0)
	sim_settle(&s)
	sim_put(&s, phone, 1)
	at_phone, at_a := s.links[0].a, s.links[0].b
	carry :: proc(from, to: ^Session) {
		out := session_output(from)
		copied := make([]byte, len(out), context.temp_allocator)
		copy(copied, out)
		session_sent(from, len(out))
		session_input(to, copied)
	}
	carry(at_phone, at_a)
	node_sync(&a.node)
	out := session_output(at_a) // the acknowledgement
	ack := make([]byte, len(out), context.temp_allocator)
	copy(ack, out)
	session_sent(at_a, len(out))
	// Something of that very row comes from there first.
	scan := tree_scan(&phone.node, phone.node.cells, KEY_MIN, KEY_MAX)
	leaf, _ := tree_next(&scan)
	c := Cell{{leaf.key[0], leaf.key[1]}, DATA, .Value, node_stamp(&a.node), nil}
	testing.expect(t, cell_seal(&a.keys, &a.node.roster, &c))
	testing.expect(t, session_input(at_phone, raw_cells({c})))
	at_a.seq_out = max(at_a.seq_out, 1) // as it would be, had it sent that itself, for the phone acknowledges it
	testing.expect(t, session_input(at_phone, ack))
	sim_settle(&s)
	testing.expect_value(t, phone.node.outbox.root, 0)
}
