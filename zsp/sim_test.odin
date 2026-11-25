#+build !js
package zsp

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:testing"

// Whole networks in one thread, under a seeded scheduler that fragments, delays, partitions and
// crashes. Every run must end with every replica identical.

@(private)
Sim_Node :: struct {
	node:   Node,
	disk:   Memory_Disk,
	keys:   Keyring,
	secret: Key32,
	relay:  bool,
	full:   bool,
	roster, roster_old, kept: []byte, // as persisted
	skew:   i64, // of its clock, in milliseconds
}

@(private)
Sim_Link :: struct {
	a, b:   ^Session, // a dialled
	an, bn: int,
}

@(private)
Sim :: struct {
	t:      ^testing.T,
	nodes:  [dynamic]^Sim_Node,
	links:  [dynamic]Sim_Link,
	space:  Key32,
	roster: []byte,
	root:   Key32,
	now:    u64,
	rows:   [dynamic]Id,
	ring:   int,
	bytes:  int,
}

@(private)
sim_init :: proc(t: ^testing.T, s: ^Sim, full, partial, relays, ring: int) {
	s.t = t
	s.now = 1_700_000_000_000
	s.ring = ring
	root, space := test_root()
	s.space = space
	s.root = root
	admin: Keyring
	defer keyring_destroy(&admin)
	none: Roster
	d := draft_from(&none, 100)
	d.random = sim_random
	home := draft_scope(&d)
	shown := draft_scope(&d, {.Signed})
	for i in 0 ..< full + partial + relays {
		x := new(Sim_Node)
		for &b in x.secret {
			b = byte(rand.uint32())
		}
		keyring_init(&x.keys, x.secret)
		x.relay = i >= full + partial
		x.full = i < full || x.relay
		x.skew = rand.int63_max(600_000) - 300_000
		append(&s.nodes, x)
		if !x.relay {
			m := draft_grant(&d, x.keys.device, x.keys.signer, home, {.Write, .Call})
			// The first owns the space, and the second helps run it.
			m.owner, m.admin = i == 0, i == 1
			// The first two devices publish; the others only read.
			draft_grant(&d, x.keys.device, x.keys.signer, shown, {.Write} if i < 2 else {.Read})
		}
	}
	ok: bool
	s.roster, ok = roster_sign(&admin, root, &d)
	assert(ok)
	for x in s.nodes {
		sim_boot(s, x)
	}
}

@(private)
sim_boot :: proc(s: ^Sim, x: ^Sim_Node) {
	assert(node_init(&x.node, memory_disk(&x.disk), s.space, nil if x.relay else &x.keys, x.full, s.ring))
	x.node.host.random = proc(_: rawptr, into: []byte) {
		sim_random(into)
	}
	x.node.host.authenticate = proc(_: rawptr, s: ^Session, credential: []byte) {
		if s.role == .Peer {
			session_accept(s)
		} else if string(credential) == "let me in" {
			session_accept(s, {{0, {.Read, .Write, .Call}, 0}})
		} else {
			session_refuse(s)
		}
	}
	x.node.now = sim_now(s, x)
	if x.roster != nil {
		assert(node_resume(&x.node, x.roster_old, x.roster) && !x.node.failed)
	} else if !x.relay {
		assert(node_adopt(&x.node, s.roster))
	}
	x.node.host.data = x
	x.node.host.roster = proc(data: rawptr, bytes: []byte) {
		x := (^Sim_Node)(data)
		delete(x.roster_old)
		x.roster_old = x.roster
		x.roster = slice.clone(bytes)
	}
	x.node.host.keep = proc(data: rawptr, bytes: []byte) {
		x := (^Sim_Node)(data)
		delete(x.kept)
		x.kept = slice.clone(bytes)
	}
}

@(private)
sim_random :: proc(into: []byte) {
	for &b in into {
		b = byte(rand.uint32())
	}
}

@(private)
sim_now :: proc(s: ^Sim, x: ^Sim_Node) -> u64 {
	return u64(i64(s.now) + x.skew)
}

// One of those who may changes who may do what, or draws new keys, perhaps both at once; the others hear of it when they hear of it.
@(private)
sim_rotate :: proc(s: ^Sim, restore := false) {
	x := s.nodes[0] if restore || len(s.nodes) < 2 || s.nodes[1].relay else s.nodes[rand.int_max(2)]
	x.node.now = sim_now(s, x)
	d := draft_from(&x.node.roster, max(x.node.clock, x.node.now << 16))
	d.random = sim_random
	who := s.nodes[1 + rand.int_max(len(s.nodes) - 1)]
	switch r := rand.int_max(6); {
	case restore:
		for y, i in s.nodes {
			if !y.relay {
				draft_grant(&d, y.keys.device, y.keys.signer, 1, {.Write, .Call})
				draft_grant(&d, y.keys.device, y.keys.signer, 2, {.Write} if i < 2 else {.Read})
				for z in d.scopes[2:] {
					draft_grant(&d, y.keys.device, y.keys.signer, z.id, {.Write})
				}
			}
		}
	case r < 2:
		d.scopes[rand.int_max(2)].rotate = true
	case r == 2 && !who.relay:
		draft_grant(&d, who.keys.device, who.keys.signer, 2, {.Read})
	case r == 3 && !who.relay:
		draft_grant(&d, who.keys.device, who.keys.signer, 2, {.Write})
	case r == 4 && !who.relay:
		// All but the scope it stays a member by.
		draft_revoke(&d, who.keys.device, 1)
	case r == 5 && len(d.scopes) < 4:
		id := draft_scope(&d)
		for y in s.nodes {
			if !y.relay {
				draft_grant(&d, y.keys.device, y.keys.signer, id, {.Write})
			}
		}
	case !who.relay:
		draft_grant(&d, who.keys.device, who.keys.signer, 1, {.Write, .Call})
	}
	root: Maybe(Key32)
	if x == s.nodes[0] {
		root = s.root
	}
	bytes, ok := roster_sign(&x.keys, root, &d)
	defer delete(bytes)
	// The second cannot while it is shut out of something.
	testing.expect(s.t, ok || x != s.nodes[0])
	if ok {
		testing.expect(s.t, node_adopt(&x.node, bytes))
	}
}

@(private)
sim_destroy :: proc(s: ^Sim) {
	for len(s.links) > 0 {
		sim_cut(s, 0)
	}
	for x in s.nodes {
		node_destroy(&x.node)
		keyring_destroy(&x.keys)
		memory_disk_destroy(&x.disk)
		delete(x.roster)
		delete(x.roster_old)
		delete(x.kept)
		free(x)
	}
	delete(s.nodes)
	delete(s.links)
	delete(s.roster)
	delete(s.rows)
}

@(private)
sim_link :: proc(s: ^Sim, a, b: int) {
	for l in s.links {
		if (l.an == a && l.bn == b) || (l.an == b && l.bn == a) {
			return
		}
	}
	x, y := s.nodes[a], s.nodes[b]
	append(
		&s.links,
		Sim_Link {
			session_open(&x.node, .Peer, true, x25519_public(y.secret), relay = y.relay),
			session_open(&y.node, .Peer, false, x25519_public(x.secret)),
			a,
			b,
		},
	)
}

@(private)
sim_cut :: proc(s: ^Sim, i: int) {
	l := s.links[i]
	unordered_remove(&s.links, i)
	session_close(l.a)
	session_close(l.b)
}

// Moves some bytes one way. Returns whether there were any.
@(private)
sim_pass :: proc(s: ^Sim, from, to: ^Session) -> bool {
	out := session_output(from)
	if len(out) == 0 {
		return false
	}
	n := 1 + rand.int_max(len(out))
	if rand.int_max(3) > 0 {
		n = len(out)
	}
	copied := make([]byte, n)
	defer delete(copied)
	copy(copied, out)
	session_sent(from, n)
	s.bytes += n
	ok := session_input(to, copied)
	testing.expectf(s.t, ok, "session failed: %v", to.fault)
	return true
}

@(private)
sim_settle :: proc(s: ^Sim) {
	for round := 0; ; round += 1 {
		busy := false
		for l in s.links {
			busy |= sim_pass(s, l.a, l.b)
			busy |= sim_pass(s, l.b, l.a)
		}
		for x in s.nodes {
			if store_unsynced(&x.node.store) {
				node_sync(&x.node)
				busy = true
			}
		}
		if !busy {
			return
		}
		if round > 20_000 {
			testing.fail_now(s.t, "network never settles")
		}
	}
}

@(private)
sim_write :: proc(s: ^Sim, x: ^Sim_Node) {
	s.now += u64(rand.int_max(30))
	x.node.now = sim_now(s, x) // clocks disagree
	body := make([]byte, 24 + rand.int_max(200), context.temp_allocator)
	for &b in body {
		b = byte(rand.uint32())
	}
	scope := Scope(1 + rand.int_max(9) / 4)
	if !node_may_write(&x.node, scope) {
		scope = 1
	}
	if !node_may_write(&x.node, scope) {
		return
	}
	put_u64(body, u64(scope) << 32 | u64(1 + rand.int_max(6)))
	put_u64(body[8:], 77)
	put_u64(body[16:], u64(rand.int_max(1000)))
	place := Cell{kind = .Place, slot = PLACE + Slot(rand.int_max(2)), body = body[:24]}
	value := Cell{kind = .Value, slot = DATA + Slot(rand.int_max(3)), body = body[24:]}
	piece := Cell{kind = .Piece, slot = DATA + 9, body = body[24:]}
	cells := make([dynamic]Cell, context.temp_allocator)
	if len(s.rows) == 0 || rand.int_max(3) == 0 {
		append(&s.rows, node_id(&x.node, scope))
		append(&cells, place, value)
		for &c in cells {
			c.row = s.rows[len(s.rows) - 1]
		}
	} else {
		row := rand.choice(s.rows[:])
		// Nobody edits what they have never seen.
		if row_places(&x.node.store, row).count == 0 || !node_may_write(&x.node, row_scope(row)) {
			return
		}
		put_u64(body, u64(row_scope(row)) << 32 | u64(1 + rand.int_max(6)))
		switch r := rand.int_max(20); {
		case r == 0:
			append(&cells, Cell{kind = .Grave, slot = GRAVE})
		case r < 5:
			append(&cells, place)
		case r < 12:
			append(&cells, value)
		case r == 12:
			// Bundle whatever pieces this node can see.
			stamps := make([dynamic]Stamp, context.temp_allocator)
			scan := row_scan(&x.node.store, row, DATA + 9, DATA + 9)
			for old in row_next(&x.node.store, &scan) {
				if old.kind == .Bundle {
					for i in 0 ..< int(get_u32(old.body)) {
						append(&stamps, bundle_at(old.body, i))
					}
				}
				if old.kind != .Value {
					append(&stamps, old.stamp)
				}
			}
			if len(stamps) == 0 {
				return
			}
			slice.sort_by(stamps[:], proc(a, b: Stamp) -> bool {return stamp_less(a, b)})
			unique := slice.unique(stamps[:])
			bundle := make([]byte, 4 + 16 * len(unique) + 20, context.temp_allocator)
			put_u32(bundle, u32(len(unique)))
			for p, i in unique {
				put_u64(bundle[4 + i * 16:], p.time)
				put_u64(bundle[12 + i * 16:], p.salt)
			}
			append(&cells, Cell{kind = .Bundle, slot = DATA + 9, body = bundle})
		case:
			append(&cells, piece)
		}
		for &c in cells {
			c.row = row
		}
	}
	for &c in cells {
		c.stamp = node_stamp(&x.node)
	}
	testing.expect(s.t, node_write(&x.node, cells[:]))
}

@(private)
sim_check :: proc(s: ^Sim, looked := false) {
	want: Maybe(Census)
	for x, i in s.nodes {
		testing.expectf(s.t, !x.node.failed && x.node.roster.serial == s.nodes[0].node.roster.serial, "node %d missed a roster, or failed", i)
		scan := tree_scan(&x.node, x.node.cells, KEY_MIN, KEY_MAX)
		for leaf in tree_next(&scan) {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			c, at := cell_unkey(leaf)
			c.body = log_bytes(&x.node.store, at.off, at.len)
			// Signatures are checked once: the others hold the very same bytes, as will be seen.
			sound := cell_valid(&c) && (cell_authentic(&x.node.roster, &c) if i == 0 else cell_lawful(&x.node.roster, &c))
			sound &&= (x.relay || cell_open(&x.keys, &x.node.roster, &c))
			testing.expectf(s.t, sound, "node %d holds what nobody may", i)
		}
		if !x.full && !looked {
			// A partial replica may lag a full one, but never knows better.
			scan = tree_scan(&x.node, x.node.cells, KEY_MIN, KEY_MAX)
			for leaf in tree_next(&scan) {
				c, _ := cell_unkey(leaf)
				news := store_news(&s.nodes[0].node.store, c.row, c.slot, c.kind, c.stamp)
				testing.expectf(s.t, !news, "node %d kept %v to itself", i, c)
			}
			continue
		}
		check_shelf(s.t, &x.node.store)
		got := census(&x.node.store, shelved = true, reader = s.nodes[0])
		w, have := want.?
		if !have {
			want = got
			continue
		}
		testing.expectf(s.t, got == w, "node %d differs: %v %v", i, got, w)
	}
}

// Has every partial replica look at everything, which is to say that it must come to hold the same as a full one.
// What it only happens to have cached may be more than anyone else has kept: a writer that died before its
// disk had what it had already said.
@(private)
sim_look :: proc(s: ^Sim) {
	lookers := make([dynamic]^Session, context.temp_allocator)
	for x in s.nodes {
		if !x.full {
			ui := sim_client(s, x)
			for info in x.node.roster.scopes {
				sim_watch(ui, u64(info.id), scope_lo(info.id), scope_hi(info.id), 0, {data = true, known = true})
			}
			append(&lookers, ui)
		}
	}
	sim_settle(s)
	sim_check(s, looked = true)
	for ui in lookers {
		session_close(ui)
	}
	for x in s.nodes {
		testing.expect(s.t, x.full || x.node.outbox.root == 0)
		testing.expect(s.t, x.relay || len(x.keys.before) == 0)
	}
	sim_settle(s)
}

@(private)
sim_chaos :: proc(s: ^Sim, steps: int) {
	n := len(s.nodes)
	for _ in 0 ..< steps {
		switch r := rand.int_max(100); {
		case r < 40:
			x := rand.choice(s.nodes[:])
			if !x.relay {
				sim_write(s, x)
			}
		case r < 46:
			a, b := rand.int_max(n), rand.int_max(n)
			if a != b && !s.nodes[a].relay && (s.nodes[b].relay || s.nodes[b].full) {
				sim_link(s, a, b)
			}
		case r < 49:
			if len(s.links) > 0 {
				sim_cut(s, rand.int_max(len(s.links)))
			}
		case r < 50 && rand.int_max(4) == 0:
			sim_rotate(s)
		case r < 50:
			// Power loss: the last synced state comes back, and nothing after it was acknowledged.
			i := rand.int_max(n)
			#reverse for l, j in s.links {
				if l.an == i || l.bn == i {
					sim_cut(s, j)
				}
			}
			x := s.nodes[i]
			if rand.int_max(2) == 0 {
				store_checkpoint(&x.node.store)
			}
			if rand.int_max(2) == 0 {
				store_flush(&x.node.store)
			}
			node_destroy(&x.node)
			// Of what was written and not synced, some may be there and some not.
			if end := memory_disk_end(&x.disk); end > x.disk.kept && x.disk.kept / SEGMENT == end / SEGMENT {
				d := memory_disk(&x.disk)
				d.log_truncate(&x.disk, x.disk.kept + u64(rand.int_max(int(end - x.disk.kept) + 1)))
			}
			newest := &s.nodes[0].node.roster
			if x != s.nodes[0] && newest.serial > 0 && rand.int_max(3) == 0 {
				if serial, _ := roster_claims(x.roster, s.space); serial < newest.serial {
					// And someone gave it a later roster meanwhile.
					delete(x.roster_old)
					x.roster_old = x.roster
					x.roster = slice.clone(newest.bytes)
				}
			}
			// What it had learnt, it has kept.
			keyring_destroy(&x.keys)
			keyring_init(&x.keys, x.secret)
			if x.kept != nil {
				testing.expect(s.t, keyring_load(&x.keys, x.kept))
			}
			sim_boot(s, x)
		case:
			if len(s.links) > 0 {
				l := rand.choice(s.links[:])
				if rand.int_max(2) == 0 {
					sim_pass(s, l.a, l.b)
				} else {
					sim_pass(s, l.b, l.a)
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
network_converges :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_SEEDS, 6)
	FIRST :: #config(ZSP_FIRST_SEED, 0)
	for seed in FIRST ..< FIRST + SEEDS {
		state := seeded(u64(seed) + 100)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 3, partial = 1, relays = 1 + seed % 2, ring = 8 if seed % 3 == 0 else 256)
		defer sim_destroy(&s)
		sim_chaos(&s, 800)
		// Heal, through the relays alone, or with them hushed.
		direct := seed % 4 == 3
		for i in 0 ..< len(s.nodes) {
			for j in 0 ..< len(s.nodes) {
				if !s.nodes[i].relay && (s.nodes[j].relay || (direct && s.nodes[j].full && i != j)) {
					sim_link(&s, i, j)
				}
			}
		}
		// Whichever roster won is known to all, and then the owner's is the only one drawn up.
		sim_settle(&s)
		sim_rotate(&s, restore = true)
		sim_settle(&s)
		sim_look(&s)
		// And go on, whole, through changes of everything.
		for _ in 0 ..< 30 {
			switch rand.int_max(8) {
			case 0:
				sim_rotate(&s)
			case 1:
				sim_settle(&s)
			case:
				if x := rand.choice(s.nodes[:]); !x.relay {
					sim_write(&s, x)
				}
			}
			free_all(context.temp_allocator)
		}
		sim_settle(&s)
		sim_rotate(&s, restore = true)
		sim_settle(&s)
		sim_look(&s)
		if testing.failed(t) {
			fmt.println("seed", seed)
			return
		}
	}
}

// Reconnecting two equal replicas of any size costs one fingerprint; one difference among thousands
// costs a logarithmic exchange.
@(test)
reconcile_is_logarithmic :: proc(t: ^testing.T) {
	state := seeded(9)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, 2, 0, 0, 256)
	defer sim_destroy(&s)
	x := s.nodes[0]
	for i in 0 ..< 20_000 {
		s.now += 3
		x.node.now = sim_now(&s, x)
		body: [24]byte
		put_u64(body[:], 1 << 32 | u64(i % 10) + 1)
		put_u64(body[16:], u64(i))
		_ = node_write(&x.node, {{node_id(&x.node, 1), PLACE, .Place, node_stamp(&x.node), body[:]}})
		free_all(context.temp_allocator)
	}
	sim_link(&s, 0, 1)
	sim_settle(&s)
	sim_check(&s)
	first := s.bytes
	sim_cut(&s, 0)

	s.bytes = 0
	sim_link(&s, 1, 0)
	sim_settle(&s)
	testing.expectf(t, s.bytes < 400, "level reconnect took %d bytes", s.bytes)
	sim_cut(&s, 0)

	sim_write(&s, s.nodes[1])
	s.bytes = 0
	sim_link(&s, 0, 1)
	sim_settle(&s)
	sim_check(&s)
	testing.expectf(t, s.bytes < 6000, "one difference in 20000 took %d bytes (all took %d)", s.bytes, first)
}

// A partial replica holds exactly what it watches, keeps it live, and its own writes reach everyone.
@(test)
partial_replica :: proc(t: ^testing.T) {
	state := seeded(11)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, phone := s.nodes[0], s.nodes[1]
	for i in 0 ..< 1000 {
		sim_put(&s, big, u64(i))
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, store_range(&phone.node.store, KEY_MIN, KEY_MAX).count, 0)

	// A client on the phone opens the tail of the list.
	ui := sim_client(&s, phone)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo({1 << 32 | 5, 5}), list_hi({1 << 32 | 5, 5}), 50, {data = true, live = true, back = true, known = true})
	sim_settle(&s)
	testing.expect_value(t, store_range(&phone.node.store, KEY_MIN, KEY_MAX).count, 50)

	sim_put(&s, big, 2000) // into view
	sim_put(&s, big, 3) // far above it
	sim_put(&s, phone, 2001)
	sim_put(&s, phone, 4)
	sim_settle(&s)
	testing.expect_value(t, store_range(&phone.node.store, KEY_MIN, KEY_MAX).count, 53)
	testing.expect_value(t, store_range(&big.node.store, KEY_MIN, KEY_MAX).count, 1004)
	sim_check(&s)
	testing.expect_value(t, phone.node.outbox.root, 0)

	// Scrolling away ends the subscription.
	at := frame_begin(&ui.input, .Unwatch)
	write_varint(&ui.input, 1)
	frame_end(&ui.input, at)
	testing.expect(t, session_input(ui, nil))
	sim_settle(&s)
	sim_put(&s, big, 2002)
	sim_settle(&s)
	testing.expect_value(t, store_range(&phone.node.store, KEY_MIN, KEY_MAX).count, 53)

	// What a page says lies beyond it is what a full replica says, and stays true as it changes; and
	// what is cached here with gaps in it never shows beside what is whole.
	session_sent(ui, len(session_output(ui)))
	last :: proc(ui: ^Session, watch: u64) -> (lo: Key, before, after: int, settled: bool) {
		out := session_output(ui)
		r := Reader{buf = out}
		for r.pos < len(out) {
			frame := read_bytes(&r)
			f := Reader{buf = frame[1:]}
			if Message(frame[0]) == .Synced && read_varint(&f) == watch {
				settled = Synced_Flags(read_u8(&f)).settled
				lo = read_key(&f)
				_ = read_key(&f)
				before, after = int(read_varint(&f)), int(read_varint(&f))
			}
		}
		session_sent(ui, len(out))
		return
	}
	for i in 3000 ..< 3100 {
		sim_put(&s, big, u64(i))
	}
	sim_settle(&s)
	sim_watch(ui, 3, list_lo({1 << 32 | 5, 5}), list_hi({1 << 32 | 5, 5}), 50, {data = true, back = true, counts = true})
	_, early, _, whole := last(ui, 3)
	testing.expect(t, early < 1055 && !whole) // cached, and said to be so
	sim_settle(&s)
	lo, before, after, sure := last(ui, 3)
	testing.expect(t, sure && before == 1055 && after == 0)
	testing.expect_value(t, store_range(&phone.node.store, lo, list_hi({1 << 32 | 5, 5})).count, 50)
	sim_put(&s, big, 7)
	sim_put(&s, big, 8)
	sim_settle(&s)
	_, before, _, _ = last(ui, 3)
	testing.expect_value(t, before, 1057)

	// A relay that dies owing an answer leaves the client with what there is, and told so.
	session_sent(ui, len(session_output(ui)))
	sim_watch(ui, 2, list_lo({1 << 32 | 6, 5}), list_hi({1 << 32 | 6, 5}), 50, {data = true})
	settled :: proc(ui: ^Session) -> (said, settled: bool) {
		out := session_output(ui)
		r := Reader{buf = out}
		for r.pos < len(out) {
			frame := read_bytes(&r)
			if Message(frame[0]) == .Synced {
				f := Reader{buf = frame[1:]}
				said = read_varint(&f) == 2
				settled = said && Synced_Flags(read_u8(&f)).settled
			}
		}
		session_sent(ui, len(out))
		return
	}
	said, done := settled(ui)
	testing.expect(t, said && !done)
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	said, done = settled(ui)
	testing.expect(t, said && done)
}

@(private)
sim_put :: proc(s: ^Sim, x: ^Sim_Node, order: u64) {
	s.now += 3
	x.node.now = sim_now(s, x)
	body: [24]byte
	put_u64(body[:], 1 << 32 | 5)
	put_u64(body[8:], 5)
	put_u64(body[16:], order)
	_ = node_write(&x.node, {{node_id(&x.node, 1), PLACE, .Place, node_stamp(&x.node), body[:]}})
	free_all(context.temp_allocator)
}

@(private)
sim_client :: proc(s: ^Sim, x: ^Sim_Node) -> ^Session {
	ui := session_open(&x.node, .Open, false)
	hello: [dynamic]byte
	defer delete(hello)
	at := frame_begin(&hello, .Hello)
	append(&hello, VERSION, 0)
	zero: Key32
	append(&hello, ..zero[:])
	write_varint(&hello, 0)
	write_bytes(&hello, transmute([]byte)string("let me in"))
	frame_end(&hello, at)
	testing.expect(s.t, session_input(ui, hello[:]))
	return ui
}

@(private)
sim_watch :: proc(ui: ^Session, id: u64, lo, hi: Key, limit: u64, flags: Watch_Flags) {
	f: [dynamic]byte
	defer delete(f)
	at := frame_begin(&f, .Watch)
	write_varint(&f, id)
	write_u8(&f, u8(flags))
	write_key(&f, lo)
	write_key(&f, hi)
	write_varint(&f, limit)
	if flags.known {
		write_varint(&f, 0)
		write_pair(&f, Print{})
	}
	frame_end(&f, at)
	session_input(ui, f[:])
}
