#+build !js
package zsp

import "core:math/rand"
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
		c = {{1 << 32 | u64(i), 1}, GRAVE, .Grave, {u64(i) + 1, 1}, nil}
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
	draft_grant(&d, a.device, a.signer, shown, {.Write}).admin = true
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
		draft_grant(&d, x.keys.device, x.keys.signer, home, {.Write}).admin = i == 0
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
	testing.expect_value(t, census(&b.node.store), before)
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
