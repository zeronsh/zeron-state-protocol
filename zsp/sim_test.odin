#+build !js
package zsp

import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
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
	slow:   ^Slow_Disk, // a relay whose storage may answer "not yet"; else disk
	remote: ^Remote_Store, // or one kept in object storage
	missed: int, // reads it missed, before it last crashed
	roster, roster_old, kept: []byte, // as persisted
	skew:   i64, // of its clock, in milliseconds
	ui:     ^Session, // of a partial replica: a client of its own, watching this and that
	relayed: [dynamic]Sim_Relayed, // sessions for calls, carried through a relay
	bare:   bool, // joined, and given no roster yet: as one that has only its space's id and its relay's
}

// A session for calls with a device reached only through a relay, its bytes carried in links' packets there. (The
// host carries them in a link, with its loss recovery; here the relay drops nothing it is not made to.)
@(private)
Sim_Relayed :: struct {
	device: Key32,
	session: ^Session,
	mine:   bool, // this end began it
	via:    u32, // the session with the relay
}

@(private)
sim_relayed_find :: proc(x: ^Sim_Node, device: Key32, mine: bool) -> ^Sim_Relayed {
	for &r in x.relayed {
		if r.device == device && r.mine == mine {
			return &r
		}
	}
	return nil
}

// A session with the relay where a device is present.
@(private)
sim_relay_with :: proc(x: ^Sim_Node, device: Key32) -> u32 {
	for s in x.node.sessions {
		if s.ready && s.peer_relay && !s.closing && slice.contains(s.online[:], device) {
			return s.id
		}
	}
	return max(u32)
}

// Moves what relayed sessions have to say into their relays; lets go of those no relay can carry any longer.
@(private)
sim_relayed_pump :: proc(s: ^Sim) -> (busy: bool) {
	for x in s.nodes {
		for i := len(x.relayed) - 1; i >= 0; i -= 1 {
			r := &x.relayed[i]
			if node_session(&x.node, r.via) == nil {
				r.via = sim_relay_with(x, r.device)
			}
			if r.via == max(u32) || r.session.closing {
				session_close(r.session)
				unordered_remove(&x.relayed, i)
				busy = true
				continue
			}
			out := session_output(r.session)
			if len(out) == 0 {
				continue
			}
			n := min(len(out), 8192) // as large as a link's packet through a relay, at most
			blob := make([]byte, n + 1, context.temp_allocator)
			blob[0] = 0 if r.mine else 1
			copy(blob[1:], out[:n])
			if node_post_link(&x.node, r.via, r.device, blob) {
				session_sent(r.session, n)
				busy = true
			}
		}
	}
	return
}

@(private)
Sim_Storage :: enum u8 {
	Quick, // a disk that always answers
	Slow, // one that answers "not yet" until fetched
	Remote, // object storage, under a host that crashes and fails
}

@(private)
Sim_Link :: struct {
	a, b:   ^Session, // a dialled
	an, bn: int,
	lanes:  ^Sim_Lanes, // when the pipe carries many streams
}

// A pipe of many streams, as a link is: each lane's bytes arrive in order, in any order with the others', but
// never before as much of the session's own stream as its first bytes said.
@(private)
Sim_Lanes :: struct {
	ends:    [2]Sim_Lane_End,
	moved:   [2]u64, // of the sessions' own streams, delivered each way
	flight:  [2][dynamic]Sim_Chunk, // each way
	opened:  int, // lanes, ever
}

@(private)
Sim_Lane_End :: struct {
	lanes: ^Sim_Lanes,
	side:  int,
	next:  u64,
}

@(private)
Sim_Chunk :: struct {
	id:      u64,
	urgency: u8,
	after:   u64,
	bytes:   []byte, // owned
	end:     bool,
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
	lazy:   Sim_Storage, // what relays keep things in
	lanes:  bool, // links between devices carry many streams
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
		if x.relay && s.lazy == .Slow {
			x.slow = new(Slow_Disk)
			x.slow.stingy = true
		}
		if x.relay && s.lazy == .Remote {
			x.remote = new(Remote_Store)
			x.remote.host.fail = 6
			x.remote.host.stingy = true
		}
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
	disk := slow_disk(x.slow) if x.slow != nil else memory_disk(&x.disk)
	if x.remote != nil {
		assert(remote_open(&x.remote.remote, model_host(&x.remote.host), 8, 2))
		x.node.store.remote = &x.remote.remote
		disk = remote_disk(&x.remote.remote)
	}
	assert(node_init(&x.node, disk, s.space, nil if x.relay else &x.keys, x.full, s.ring))
	if x.slow != nil {
		x.slow.store = &x.node.store
	}
	if x.remote != nil {
		x.remote.remote.store = &x.node.store
	}
	x.node.host.random = proc(_: rawptr, into: []byte) {
		sim_random(into)
	}
	x.node.host.authenticate = proc(_: rawptr, s: ^Session, credential: []byte) {
		if s.role != .Open {
			session_accept(s)
		} else if string(credential) == "let me in" {
			session_accept(s, {{0, {.Read, .Write, .Call}, 0}})
		} else if strings.has_prefix(string(credential), "as ") {
			session_accept(s, {{0, {.Read, .Write, .Call}, 0}}, string(credential[3:]))
		} else {
			session_refuse(s)
		}
	}
	x.node.now = sim_now(s, x)
	if !x.full {
		node_keep(&x.node, {age = 300, bytes = 3000}) // and so lets go of a great deal, often
	}
	if x.roster != nil {
		assert(node_resume(&x.node, x.roster_old, x.roster) && !x.node.failed)
	} else if !x.relay && !x.bare {
		assert(node_adopt(&x.node, s.roster))
	}
	x.node.host.data = x
	if !x.relay {
		x.node.host.reach = proc(data: rawptr, device: Key32) -> ^Session {
			x := (^Sim_Node)(data)
			if r := sim_relayed_find(x, device, true); r != nil {
				return r.session
			}
			via := sim_relay_with(x, device)
			if via == max(u32) {
				return nil
			}
			session := session_open(&x.node, .Calls, true, device)
			append(&x.relayed, Sim_Relayed{device, session, true, via})
			return session
		}
		x.node.host.link = proc(data: rawptr, relay: u32, from: Key32, packet: []byte) {
			x := (^Sim_Node)(data)
			if len(packet) == 0 {
				return
			}
			// What the other end began comes to the session this end answers with, and the other way about.
			mine := packet[0] == 1
			r := sim_relayed_find(x, from, mine)
			if r == nil {
				if mine {
					return // this end has let it go
				}
				append(&x.relayed, Sim_Relayed{from, session_open(&x.node, .Calls, false, from), false, relay})
				r = &x.relayed[len(x.relayed) - 1]
			}
			r.via = relay
			session_input(r.session, packet[1:])
		}
	}
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
		for r in x.relayed {
			session_close(r.session)
		}
		delete(x.relayed)
		node_destroy(&x.node)
		keyring_destroy(&x.keys)
		memory_disk_destroy(&x.disk)
		if x.slow != nil {
			slow_disk_destroy(x.slow)
			free(x.slow)
		}
		if x.remote != nil {
			remote_close(&x.remote.remote)
			model_host_destroy(&x.remote.host)
			free(x.remote)
		}
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
	l := Sim_Link {
		session_open(&x.node, .Peer, true, x25519_public(y.secret), relay = y.relay),
		session_open(&y.node, .Peer, false, x25519_public(x.secret)),
		a,
		b,
		nil,
	}
	if s.lanes && !x.relay && !y.relay {
		l.lanes = new(Sim_Lanes)
		for &e, i in l.lanes.ends {
			e = {l.lanes, i, u64(2 if i == 0 else 1)}
			session := l.a if i == 0 else l.b
			session.lane_data = &e
			session.lane_open = proc(data: rawptr, urgency: u8, after: u64) -> (id: u64, ok: bool) {
				e := (^Sim_Lane_End)(data)
				id = e.next
				e.next += 2
				e.lanes.opened += 1
				return id, true
			}
		}
	}
	append(&s.links, l)
}

// Moves some of what lanes have to say one way, and delivers some of what is on its way, in any order the pipe
// allows. Returns whether anything moved.
@(private)
sim_lanes :: proc(s: ^Sim, l: ^Sim_Lanes, from, to: ^Session, way: int) -> (busy: bool) {
	lanes := session_lanes(from)
	for i := 0; i < len(lanes); i += 1 {
		lane := lanes[i]
		if out := session_lane_output(from, lane); len(out) > 0 {
			n := len(out) if rand.int_max(2) == 0 else 1 + rand.int_max(len(out))
			append(&l.flight[way], Sim_Chunk{lane.id, lane.urgency, lane.after, slice.clone(out[:n]), false})
			session_lane_sent(from, lane, n)
			busy = true
		}
		if session_lane_done(from, lane) {
			append(&l.flight[way], Sim_Chunk{id = lane.id, after = lane.after, end = true})
			session_lane_closed(from, lane)
			lanes = session_lanes(from)
			i -= 1
			busy = true
		}
	}
	flight := &l.flight[way]
	for _ in 0 ..< len(flight) {
		// Any chunk that is first of its lane, and whose lane may be delivered.
		i := rand.int_max(len(flight))
		c := flight[i]
		first := true
		for j in 0 ..< i {
			first &&= flight[j].id != c.id
		}
		if !first || l.moved[way] < c.after {
			continue
		}
		ordered_remove(flight, i)
		if c.end {
			session_lane_heard(to, c.id, false)
		} else {
			testing.expectf(s.t, session_lane_input(to, c.id, c.urgency, c.bytes), "lane input failed: %v", to.fault)
			delete(c.bytes)
		}
		busy = true
	}
	return
}

@(private)
sim_cut :: proc(s: ^Sim, i: int) {
	l := s.links[i]
	unordered_remove(&s.links, i)
	session_close(l.a)
	session_close(l.b)
	if l.lanes != nil {
		for f in l.lanes.flight {
			for c in f {
				delete(c.bytes)
			}
			delete(f)
		}
		free(l.lanes)
	}
}

// Moves some bytes one way. Returns whether there were any.
@(private)
sim_pass :: proc(s: ^Sim, from, to: ^Session, lanes: ^Sim_Lanes = nil, way := 0) -> bool {
	out := session_output(from)
	busy := false
	if lanes != nil {
		busy = sim_lanes(s, lanes, from, to, way)
	}
	if len(out) == 0 {
		return busy
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
	if lanes != nil {
		lanes.moved[way] += u64(n)
	}
	ok := session_input(to, copied)
	testing.expectf(s.t, ok, "session failed: %v", to.fault)
	return true
}

@(private)
sim_settle :: proc(s: ^Sim) {
	for round := 0; ; round += 1 {
		busy := false
		// What was fetched has come, and what waited for it goes on, before bytes move: what it says moves with them.
		for x in s.nodes {
			if x.remote != nil {
				answered := model_tick(&x.remote.host, &x.remote.remote, 1 << 20)
				waiting := node_retry(&x.node)
				waiting = remote_work(&x.remote.remote) || waiting
				busy |= waiting || answered > 0
			}
			if x.slow != nil {
				// The host brings what was asked for, and what waited for it goes on; and its cache lets things go.
				if rand.int_max(4) == 0 {
					slow_evict(x.slow, 64)
				}
				fetched := slow_fetch(x.slow, all = true)
				waiting := node_retry(&x.node)
				busy |= fetched > 0 || waiting
			}
		}
		for l in s.links {
			busy |= sim_pass(s, l.a, l.b, l.lanes, 0)
			busy |= sim_pass(s, l.b, l.a, l.lanes, 1)
		}
		busy |= sim_relayed_pump(s)
		for x in s.nodes {
			if x.remote != nil {
				remote_ops(&x.remote.remote)
				remote_rest(&x.remote.remote)
				busy |= len(x.remote.host.ops) > 0
			}
			if x.slow != nil {
				busy |= len(x.slow.want_pages) + len(x.slow.want_blocks) > 0
			}
			if store_unsynced(&x.node.store) {
				node_sync(&x.node)
				busy = true
			}
			if x.ui != nil {
				out := len(session_output(x.ui))
				session_sent(x.ui, out)
				busy |= out > 0
			}
		}
		if !busy {
			return
		}
		if round > 20_000 {
			for x, i in s.nodes {
				if x.remote != nil {
					r := &x.remote.remote
					stalled := 0
					for ss in x.node.sessions {
						stalled += int(ss.stalled)
					}
					testing.expectf(s.t, false, "relay %d: replaying %v stalled %d inflight %v acc %d/%d entry %v gc %v slot %d/%d asked %v hints %d dirty %d failed %v unguarded %d evac %v sweep %d repair %v",
						i, x.node.store.replaying, stalled, r.inflight != nil, r.accounted, len(x.node.store.pending), r.entry, r.gc.active, r.gc.slot, r.gc.total, r.gc.asked, len(r.gc.hints), len(x.node.store.dirty), x.node.failed, r.unguarded, x.node.store.evac, len(x.node.sweep.plans), x.node.store.repair.root)
				}
			}
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

// Brings everything a relay keeps in object storage to hand, so that it may be looked at outside any step.
@(private)
sim_fetch_all :: proc(s: ^Sim, x: ^Sim_Node) {
	st := &x.node.store
	for tries := 0; ; tries += 1 {
		t := store_begin(st)
		_ = census(st, shelved = true, reader = s.nodes[0])
		scan := tree_scan(st, st.shelf, KEY_MIN, KEY_MAX)
		for _ in tree_next(&scan) {}
		if !store_missed(st, &t) {
			store_end(st, &t, true)
			return
		}
		store_end(st, &t, false)
		remote_ops(&x.remote.remote)
		model_tick(&x.remote.host, &x.remote.remote, 1 << 20)
		if tries > 10_000 {
			testing.fail_now(s.t, "a relay never has what it keeps")
		}
	}
}

@(private)
sim_check :: proc(s: ^Sim, looked := false) {
	want: Maybe(Census)
	for x in s.nodes {
		if x.remote != nil {
			testing.expectf(s.t, x.remote.remote.unguarded == 0, "a relay read %d times what it did not have, outside a step", x.remote.remote.unguarded)
			sim_fetch_all(s, x)
		}
		if x.slow != nil {
			testing.expectf(s.t, x.slow.unguarded == 0, "a relay read %d times what it did not have, outside a step", x.slow.unguarded)
			x.slow.all = true
		}
	}
	defer for x in s.nodes {
		if x.slow != nil {
			x.slow.all = false
		}
	}
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
		case r >= 95 && rand.int_max(2) == 0:
			// A partial replica's client looks at something, or no longer, and it lets go of what it may.
			if x := rand.choice(s.nodes[:]); !x.full {
				if x.ui == nil {
					x.ui = sim_client(s, x)
				}
				id := u64(1 + rand.int_max(4))
				if rand.int_max(3) == 0 {
					f: [dynamic]byte
					at := frame_begin(&f, .Unwatch)
					write_varint(&f, id)
					frame_end(&f, at)
					session_input(x.ui, f[:])
					delete(f)
				} else {
					scope := Scope(1 + rand.int_max(2))
					list: List = {u64(scope) << 32 | u64(1 + rand.int_max(6)), 77}
					limit := u64(rand.choice([]int{0, 3, 20}))
					sim_watch(x.ui, id, list_lo(list), list_hi(list), limit, {data = true, live = true, back = rand.int_max(2) == 0})
				}
				session_sent(x.ui, len(session_output(x.ui)))
				s.now += u64(rand.int_max(1000))
				x.node.now = sim_now(s, x)
				for node_retain(&x.node) {}
			}
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
			if x.remote != nil {
				// Mid-checkpoint, perhaps: its pack under way, and landing after.
				if rand.int_max(2) == 0 {
					x.remote.remote.want_checkpoint = true
					remote_work(&x.remote.remote)
					remote_ops(&x.remote.remote)
				}
				model_crash(&x.remote.host)
			}
			node_destroy(&x.node)
			x.ui = nil // gone with it
			if x.remote != nil {
				x.missed += x.remote.remote.missed
				remote_close(&x.remote.remote)
			}
			// Of what was written and not synced, some may be there and some not.
			m := &x.slow.m if x.slow != nil else &x.disk
			if end := memory_disk_end(m); end > m.kept && m.kept / SEGMENT == end / SEGMENT {
				d := memory_disk(m)
				d.log_truncate(m, m.kept + u64(rand.int_max(int(end - m.kept) + 1)))
			}
			if x.slow != nil {
				// What was fetched was in memory, and is gone with it.
				clear(&x.slow.pages)
				clear(&x.slow.blocks)
				clear(&x.slow.want_pages)
				clear(&x.slow.want_blocks)
				x.slow.store = nil
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
			// And it may come back the other kind of replica: what it wrote as the one, the other must not lose.
			if i != 0 && !x.relay && rand.int_max(3) == 0 {
				x.full = !x.full
			}
			// What it had learnt, it has kept.
			keyring_destroy(&x.keys)
			keyring_init(&x.keys, x.secret)
			if x.kept != nil {
				testing.expect(s.t, keyring_load(&x.keys, x.kept))
			}
			sim_boot(s, x)
		case r < 60 && s.lazy != .Quick:
			x := rand.choice(s.nodes[:])
			if x.remote != nil {
				node_retry(&x.node)
				remote_work(&x.remote.remote)
				remote_ops(&x.remote.remote)
				model_tick(&x.remote.host, &x.remote.remote, rand.int_max(8))
				remote_rest(&x.remote.remote)
			}
			if x.slow != nil {
				switch rand.int_max(4) {
				case 0:
					slow_evict(x.slow, 3)
				case 1:
					// What it holds goes out to where it must be fetched from.
					store_sync(&x.node.store)
					store_checkpoint(&x.node.store)
				}
				slow_fetch(x.slow)
				node_retry(&x.node)
			}
		case:
			if len(s.links) > 0 {
				l := rand.choice(s.links[:])
				if rand.int_max(2) == 0 {
					sim_pass(s, l.a, l.b, l.lanes, 0)
				} else {
					sim_pass(s, l.b, l.a, l.lanes, 1)
				}
			}
		}
		free_all(context.temp_allocator)
	}
}

@(test)
network_converges :: proc(t: ^testing.T) {
	sim_worlds(t, .Quick)
}

// A world in which a device becoming partial was acknowledged what it had still to send of a row, which, its cell
// killed meanwhile, sent nothing: the row stayed in its outbox, though held, until it next connected.
@(test)
network_converges_seed_98 :: proc(t: ^testing.T) {
	sim_worlds(t, .Slow, 98, 1)
}

// Worlds in which a partial device fell behind its ring of changes by what its full peer had sent it alone, and was
// acknowledged meanwhile: it went on, rather than comparing all again, and so it must know then what it may let go
// of, or what was acknowledged stays in its outbox for good.
@(test)
network_converges_seed_1038 :: proc(t: ^testing.T) {
	sim_worlds(t, .Quick, 1038, 1)
}

@(test)
network_converges_seed_1056 :: proc(t: ^testing.T) {
	sim_worlds(t, .Slow, 1056, 1)
}

// And through relays whose storage holds only some of what they keep at hand, fetching the rest as it is wanted.
@(test)
network_converges_through_slow_relays :: proc(t: ^testing.T) {
	sim_worlds(t, .Slow)
}

// And through relays that keep everything in object storage, under hosts that fail and crash.
@(test)
network_converges_through_remote_relays :: proc(t: ^testing.T) {
	sim_worlds(t, .Remote)
}

@(private)
sim_worlds :: proc(t: ^testing.T, lazy: Sim_Storage, first := #config(ZSP_FIRST_SEED, 0), seeds := #config(ZSP_SEEDS, 6)) {
	missed, writes, reads := 0, 0, 0
	defer testing.expectf(t, lazy == .Quick || seeds < 6 || (missed > 100 && writes > 10 && reads > 10), "the relays missed %d reads, wrote %d times and read %d times", missed, writes, reads)
	for seed in first ..< first + seeds {
		state := seeded(u64(seed) + 100 + 200 * u64(lazy))
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		s.lazy = lazy
		sim_init(t, &s, full = 3, partial = 1, relays = 1 + seed % 2, ring = 8 if seed % 3 == 0 else 256)
		s.lanes = seed % 5 == 2
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
		// The relays' storage was put to work: reads missed, and object storage was written and read.
		for x in s.nodes {
			if x.slow != nil {
				missed += x.slow.missed
				reads += 100
				writes += 100
			}
			if x.remote != nil {
				missed += x.missed + x.remote.remote.missed
				writes += x.remote.host.class_a
				reads += x.remote.host.class_b
			}
		}
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

	// A relay that dies owing an answer leaves the client with what there is, and told so: that it is no more than that.
	session_sent(ui, len(session_output(ui)))
	sim_watch(ui, 2, list_lo({1 << 32 | 6, 5}), list_hi({1 << 32 | 6, 5}), 50, {data = true})
	settled :: proc(ui: ^Session, watch: u64) -> (said, settled: bool) {
		out := session_output(ui)
		r := Reader{buf = out}
		for r.pos < len(out) {
			frame := read_bytes(&r)
			if Message(frame[0]) == .Synced {
				f := Reader{buf = frame[1:]}
				if read_varint(&f) == watch {
					said = true
					settled = Synced_Flags(read_u8(&f)).settled
				}
			}
		}
		session_sent(ui, len(out))
		return
	}
	said, done := settled(ui, 2)
	testing.expect(t, said && !done)
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	said, done = settled(ui, 2)
	testing.expect(t, said && !done)

	// So does one that dies having said so; and one that comes back says so again.
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	said, done = settled(ui, 3)
	testing.expect(t, said && done)
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	said, done = settled(ui, 3)
	testing.expect(t, said && !done)
	// Nor is a window first watched with nobody to ask settled.
	sim_watch(ui, 4, list_lo({1 << 32 | 5, 5}), list_hi({1 << 32 | 5, 5}), 10, {data = true, back = true})
	said, done = settled(ui, 4)
	testing.expect(t, said && !done)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	out := session_output(ui)
	r := Reader{buf = out}
	latest: [5]Maybe(bool)
	for r.pos < len(out) {
		frame := read_bytes(&r)
		if Message(frame[0]) == .Synced {
			f := Reader{buf = frame[1:]}
			if id := read_varint(&f); id < len(latest) {
				latest[id] = Synced_Flags(read_u8(&f)).settled
			}
		}
	}
	session_sent(ui, len(out))
	for id in ([]int{3, 4}) {
		testing.expectf(t, latest[id] == true, "watch %d is not settled again: %v", id, latest[id])
	}
}

// A device that was a full replica and is now a partial one loses nothing it wrote meanwhile, however long ago its store
// was checkpointed, for it goes on as a full replica until it is level with another, and is partial from its next start;
// and the other way about. So does one whose store was kept before there were outboxes.
@(test)
partial_after_full :: proc(t: ^testing.T) {
	state := seeded(12)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, laptop := s.nodes[0], s.nodes[1]
	count :: proc(x: ^Sim_Node) -> int {
		return store_range(&x.node.store, KEY_MIN, KEY_MAX).count
	}

	// A full replica writes while it reaches nobody, its store is checkpointed, and it starts again as a partial one: a
	// full one until it is level, and partial at its next start.
	for i in 0 ..< 20 {
		sim_put(&s, laptop, u64(i))
	}
	sim_restart(&s, laptop, full = false)
	testing.expect(t, laptop.node.full && laptop.node.becoming && !laptop.node.whole)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, count(big), 20)
	testing.expect(t, laptop.node.whole)
	sim_restart(&s, laptop, full = false)
	testing.expect(t, !laptop.node.full && !laptop.node.becoming)
	testing.expect_value(t, laptop.node.outbox.root, 0)

	// A partial replica writes while it reaches nobody, and starts again as a full one, and then as a partial one.
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	for i in 100 ..< 110 {
		sim_put(&s, laptop, u64(i))
	}
	sim_restart(&s, laptop, full = true)
	sim_restart(&s, laptop, full = false)
	testing.expect(t, laptop.node.becoming)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, count(big), 30)

	// A store kept as a full replica's before there were outboxes, which writes while it reaches nobody.
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	sim_restart(&s, laptop, full = true)
	for i in 200 ..< 205 {
		sim_put(&s, laptop, u64(i))
	}
	clear_map_outbox(&laptop.node)
	sim_restart(&s, laptop, full = false, older = true)
	testing.expect(t, laptop.node.full && laptop.node.becoming && !laptop.node.whole) // full until level with one
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, count(big), 35)
	testing.expect(t, laptop.node.whole)
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	sim_restart(&s, laptop, full = false)
	testing.expect(t, !laptop.node.full && !laptop.node.becoming)
	sim_put(&s, laptop, 300)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, count(big), 36)
}

// A partial replica lets go of what it no longer watches: of a list nobody has watched for long enough, and, when it
// holds more than it may, of the lists watched least lately first. Never of what it wrote and nobody else is known to
// hold, nor of what is watched; and whatever it let go of comes again once it is watched again.
@(test)
partial_lets_go :: proc(t: ^testing.T) {
	state := seeded(13)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, phone := s.nodes[0], s.nodes[1]
	HOUR :: 3600 * 1000
	node_keep(&phone.node, {age = 24 * HOUR, bytes = 0})
	list :: proc(i: u64) -> List {
		return {1 << 32 | 100 + i, i}
	}
	put :: proc(s: ^Sim, x: ^Sim_Node, l: List, order: u64, size: int) {
		s.now += 3
		x.node.now = sim_now(s, x)
		place: [24]byte
		put_u64(place[:], l[0])
		put_u64(place[8:], l[1])
		put_u64(place[16:], order)
		body := make([]byte, size, context.temp_allocator)
		row := node_id(&x.node, 1)
		_ = node_write(&x.node, {{row, PLACE, .Place, node_stamp(&x.node), place[:]}, {row, DATA, .Value, node_stamp(&x.node), body}})
		free_all(context.temp_allocator)
	}
	held :: proc(x: ^Sim_Node, l: List) -> int {
		return store_range(&x.node.store, list_lo(l), list_hi(l)).count
	}
	retain :: proc(s: ^Sim, x: ^Sim_Node, after: u64) {
		s.now += after
		for y in s.nodes {
			y.node.now = sim_now(s, y)
		}
		for _ in 0 ..< 10_000 {
			if !node_retain(&x.node) {
				break
			}
		}
	}
	for i in 0 ..< 300 {
		for l in u64(0) ..< 3 {
			put(&s, big, list(l), u64(i), 1000)
		}
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	ui := sim_client(&s, phone)
	defer session_close(ui)
	look :: proc(s: ^Sim, ui: ^Session, id: u64, l: List, limit: u64) {
		sim_watch(ui, id, list_lo(l), list_hi(l), limit, {data = true, live = true, back = true})
		sim_settle(s)
	}
	unlook :: proc(s: ^Sim, ui: ^Session, id: u64) {
		f: [dynamic]byte
		defer delete(f)
		at := frame_begin(&f, .Unwatch)
		write_varint(&f, id)
		frame_end(&f, at)
		session_input(ui, f[:])
		sim_settle(s)
	}
	// It reads all of list 0, then all of list 1, and keeps the end of list 2 open.
	look(&s, ui, 1, list(0), 0)
	unlook(&s, ui, 1)
	retain(&s, phone, 6 * HOUR)
	look(&s, ui, 2, list(1), 0)
	unlook(&s, ui, 2)
	look(&s, ui, 3, list(2), 20)
	testing.expect_value(t, held(phone, list(0)), 300)
	testing.expect_value(t, held(phone, list(1)), 300)
	testing.expect_value(t, held(phone, list(2)), 20)
	// It writes in list 3 while it reaches nobody.
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	for i in 0 ..< 5 {
		put(&s, phone, list(3), u64(i), 100)
	}
	// A day after it last looked at list 0, that goes; list 1, looked at later, stays, and so does all the rest.
	retain(&s, phone, 18 * HOUR + 1)
	testing.expect_value(t, held(phone, list(0)), 0)
	testing.expect_value(t, held(phone, list(1)), 300)
	testing.expect_value(t, held(phone, list(2)), 20)
	testing.expect_value(t, held(phone, list(3)), 5)
	// And when it holds more than it may, the lists looked at least lately go first, and what is watched stays.
	node_keep(&phone.node, {age = 24 * HOUR, bytes = u64(store_held(&phone.node.store)) / 2})
	retain(&s, phone, 1)
	testing.expect_value(t, held(phone, list(1)), 0)
	testing.expect_value(t, held(phone, list(2)), 20)
	testing.expect_value(t, held(phone, list(3)), 5)
	// Days later, what it wrote is still there, for nobody has it yet; what is watched is there however long.
	retain(&s, phone, 72 * HOUR)
	testing.expect_value(t, held(phone, list(2)), 20)
	testing.expect_value(t, held(phone, list(3)), 5)
	// Once its writing is held elsewhere, that goes too, in its time; and what went comes back when it is looked at.
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, held(big, list(3)), 5)
	testing.expect_value(t, phone.node.outbox.root, 0)
	retain(&s, phone, 25 * HOUR)
	testing.expect_value(t, held(phone, list(3)), 0)
	testing.expect_value(t, held(phone, list(2)), 20)
	look(&s, ui, 4, list(0), 0)
	testing.expect_value(t, held(phone, list(0)), 300)
	sim_check(&s)
	// It holds more than it may, all of it watched: once it has found that, it does not go over it again and again,
	// at every checkpoint, but only once it has grown by much since.
	grow :: proc(s: ^Sim, x: ^Sim_Node, rows: int) {
		for i in 0 ..< rows {
			put(s, x, list(2), u64(1000 + i), 10)
		}
		testing.expect(s.t, node_sync(&x.node) && store_checkpoint(&x.node.store))
		retain_grown(&x.node)
	}
	grow(&s, phone, 1)
	retain(&s, phone, 1)
	testing.expect_value(t, held(phone, list(0)), 300)
	grow(&s, phone, 5)
	testing.expect(t, node_retain_due(&phone.node) > phone.node.now)
	grow(&s, phone, 2000)
	testing.expect(t, node_retain_due(&phone.node) <= phone.node.now)
	retain(&s, phone, 1)
	// It has nothing to do until the next list comes of age.
	testing.expectf(t, node_retain_due(&phone.node) > phone.node.now, "due %v now %v running %v", node_retain_due(&phone.node), phone.node.now, phone.node.retain.running)
}

// A full replica that has said it holds what a partial one wrote, which therefore forgets it, and then starts again
// as a partial one itself, still offers it: nobody else may have it. (Review 1, 1.)
@(test)
review_full_takes_what_it_acks :: proc(t: ^testing.T) {
	state := seeded(41)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, laptop, phone := s.nodes[0], s.nodes[1], s.nodes[2]
	sim_link(&s, 2, 1) // the phone and the laptop, directly, and no relay
	sim_settle(&s)
	sim_put(&s, phone, 7)
	sim_settle(&s)
	testing.expect_value(t, phone.node.outbox.root, 0)
	testing.expect_value(t, store_range(&laptop.node.store, KEY_MIN, KEY_MAX).count, 1)
	sim_restart(&s, laptop, full = false)
	sim_link(&s, 1, 3)
	sim_link(&s, 0, 3)
	sim_link(&s, 2, 3)
	sim_settle(&s)
	testing.expect_value(t, store_range(&big.node.store, KEY_MIN, KEY_MAX).count, 1)
}

// What says a window is settled is a full replica that was asked, with bounds within it; nothing else is believed, nor
// passed on. (Review 1, 2.)
@(test)
review_settled_is_not_forged :: proc(t: ^testing.T) {
	state := seeded(42)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 0, partial = 2, relays = 1, ring = 256)
	defer sim_destroy(&s)
	victim := s.nodes[0]
	sim_link(&s, 0, 1)
	sim_settle(&s)
	ui := sim_client(&s, victim)
	defer session_close(ui)
	list := List{1 << 32 | 5, 5}
	sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true, live = true})
	sim_settle(&s)
	testing.expect(t, len(victim.node.interests) == 1)
	f: [dynamic]byte
	defer delete(f)
	at := frame_begin(&f, .Synced)
	write_varint(&f, victim.node.interests[0].id)
	write_u8(&f, 1) // settled
	write_key(&f, list_hi(list))
	write_key(&f, list_lo(list))
	write_varint(&f, 0)
	write_varint(&f, 0)
	frame_end(&f, at)
	session_input(s.links[0].a, f[:])
	sim_settle(&s)
	testing.expect(t, !interest_sure(&victim.node, &victim.node.interests[0]), "a partial peer made a window settled")
	w := victim.node.interests[0].watch
	testing.expect(t, key_less(w.lo, w.hi), "and made it nothing")
	sim_link(&s, 0, 2)
	sim_settle(&s)
	for l in s.links {
		testing.expect(t, !l.a.closing && !l.b.closing, "and broke a session with a relay")
	}
}

// What a partial replica lets go of stays gone, though it is stopped at once after, as a host stops it. (Review 1, 3.)
@(test)
review_letting_go_is_kept :: proc(t: ^testing.T) {
	state := seeded(43)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, phone := s.nodes[0], s.nodes[1]
	for i in 0 ..< 50 {
		sim_put(&s, big, u64(i))
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	node_keep(&phone.node, {age = 1000, bytes = 0})
	ui := sim_client(&s, phone)
	list := List{1 << 32 | 5, 5}
	sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true})
	sim_settle(&s)
	testing.expect(t, store_checkpoint(&phone.node.store))
	session_close(ui)
	sim_settle(&s)
	s.now += 5000
	phone.node.now = sim_now(&s, phone)
	for node_retain(&phone.node) {}
	testing.expect_value(t, store_range(&phone.node.store, list_lo(list), list_hi(list)).count, 0)
	// Stopped as a host stops it, with nothing written since but what letting go did.
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	testing.expect(t, store_sync(&phone.node.store))
	node_destroy(&phone.node)
	keyring_destroy(&phone.keys)
	keyring_init(&phone.keys, phone.secret)
	if phone.kept != nil {
		testing.expect(t, keyring_load(&phone.keys, phone.kept))
	}
	sim_boot(&s, phone)
	testing.expect_value(t, store_range(&phone.node.store, list_lo(list), list_hi(list)).count, 0)
}

// A full replica's outbox, filled again from its log when it starts, is emptied once it is level with another: it does
// not grow from one start to the next. (Review 1, 7A.)
@(test)
review_full_outbox_empties :: proc(t: ^testing.T) {
	state := seeded(44)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	laptop := s.nodes[1]
	for i in 0 ..< 20 {
		sim_put(&s, laptop, u64(i))
	}
	sim_link(&s, 1, 2)
	sim_link(&s, 0, 2)
	sim_settle(&s)
	testing.expect_value(t, laptop.node.outbox.root, 0)
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	testing.expect(t, store_sync(&laptop.node.store))
	node_destroy(&laptop.node)
	keyring_destroy(&laptop.keys)
	keyring_init(&laptop.keys, laptop.secret)
	if laptop.kept != nil {
		testing.expect(t, keyring_load(&laptop.keys, laptop.kept))
	}
	sim_boot(&s, laptop)
	sim_link(&s, 1, 2)
	sim_link(&s, 0, 2)
	sim_settle(&s)
	testing.expect_value(t, laptop.node.outbox.root, 0)
}

// A window a full replica has said is settled, and which then goes before the client has been told so, is told that it
// is not, last of all. (Review 1, 8A.)
@(test)
review_settled_race :: proc(t: ^testing.T) {
	state := seeded(45)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	phone := s.nodes[1]
	sim_put(&s, s.nodes[0], 1)
	sim_link(&s, 0, 2)
	sim_settle(&s)
	ui := sim_client(&s, phone)
	defer session_close(ui)
	list := List{1 << 32 | 5, 5}
	sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true})
	session_sent(ui, len(session_output(ui)))
	sim_link(&s, 1, 2)
	// What the relay says reaches the phone, which has yet to tell its client.
	for _ in 0 ..< 50 {
		for l in s.links {
			sim_pass(&s, l.a, l.b)
			sim_pass(&s, l.b, l.a)
		}
	}
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	out := session_output(ui)
	r := Reader{buf = out}
	last: Maybe(bool)
	for r.pos < len(out) {
		frame := read_bytes(&r)
		if Message(frame[0]) == .Synced {
			f := Reader{buf = frame[1:]}
			if read_varint(&f) == 1 {
				last = Synced_Flags(read_u8(&f)).settled
			}
		}
	}
	session_sent(ui, len(out))
	testing.expectf(t, last == false, "last said of the window: settled %v", last)
}

// When a roster leaves nobody who can read a scope among those a partial replica reaches, its windows there are told
// that they are no longer settled. (Review 1, 8B.)
@(test)
review_settled_roster :: proc(t: ^testing.T) {
	state := seeded(46)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 1, relays = 0, ring = 256)
	defer sim_destroy(&s)
	owner, helper, phone := s.nodes[0], s.nodes[1], s.nodes[2]
	sim_put(&s, helper, 1)
	sim_link(&s, 2, 1)
	sim_settle(&s)
	ui := sim_client(&s, phone)
	defer session_close(ui)
	list := List{1 << 32 | 5, 5}
	sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true})
	sim_settle(&s)
	session_sent(ui, len(session_output(ui)))
	owner.node.now = sim_now(&s, owner)
	d := draft_from(&owner.node.roster, max(owner.node.clock, owner.node.now << 16))
	d.random = sim_random
	draft_revoke(&d, helper.keys.device, 1)
	bytes, ok := roster_sign(&owner.keys, s.root, &d)
	defer delete(bytes)
	testing.expect(t, ok && node_adopt(&owner.node, bytes) && node_adopt(&phone.node, bytes) && node_adopt(&helper.node, bytes))
	sim_settle(&s)
	out := session_output(ui)
	r := Reader{buf = out}
	last: Maybe(bool)
	for r.pos < len(out) {
		frame := read_bytes(&r)
		if Message(frame[0]) == .Synced {
			f := Reader{buf = frame[1:]}
			if read_varint(&f) == 1 {
				last = Synced_Flags(read_u8(&f)).settled
			}
		}
	}
	session_sent(ui, len(out))
	testing.expectf(t, last == false, "last said of the window: settled %v", last)
}

// A device becoming partial is not level with one that cannot read a scope it holds keys for, though it may no longer
// write there: it may have before. (Review 1, 9A.)
@(test)
review_level_in_every_scope :: proc(t: ^testing.T) {
	state := seeded(50)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 3, partial = 0, relays = 0, ring = 256)
	defer sim_destroy(&s)
	owner, laptop, other := s.nodes[0], s.nodes[1], s.nodes[2]
	owner.node.now = sim_now(&s, owner)
	d := draft_from(&owner.node.roster, max(owner.node.clock, owner.node.now << 16))
	d.random = sim_random
	draft_revoke(&d, other.keys.device, 2)
	draft_grant(&d, laptop.keys.device, laptop.keys.signer, 2, {.Read})
	bytes, ok := roster_sign(&owner.keys, s.root, &d)
	defer delete(bytes)
	testing.expect(t, ok)
	for x in s.nodes {
		testing.expect(t, node_adopt(&x.node, bytes))
	}
	sim_restart(&s, laptop, full = false, older = true)
	testing.expect(t, laptop.node.becoming)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect(t, !laptop.node.whole, "level with one that cannot read all it may hold")
	sim_link(&s, 1, 0)
	sim_settle(&s)
	testing.expect(t, laptop.node.whole)
}

// An Ack of more than was sent makes no sense, and the session ends: it is not believed. (Review 1, 9B.)
@(test)
review_ack_beyond :: proc(t: ^testing.T) {
	state := seeded(47)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 256)
	defer sim_destroy(&s)
	sim_link(&s, 1, 0)
	sim_settle(&s)
	f: [dynamic]byte
	defer delete(f)
	at := frame_begin(&f, .Ack)
	write_varint(&f, max(u64))
	frame_end(&f, at)
	testing.expect(t, !session_input(s.links[0].a, f[:]), "an Ack of what was never sent was taken")
}

// What is kept, however long it is said to be, is no longer than may be reckoned with: nothing wraps, and nothing is
// looked at again and again for having wrapped. (Review 1, 10.)
@(test)
review_keep_bounds :: proc(t: ^testing.T) {
	state := seeded(48)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 0, ring = 256)
	defer sim_destroy(&s)
	phone := s.nodes[1]
	node_keep(&phone.node, {age = max(u64), bytes = max(u64)})
	for node_retain(&phone.node) {}
	sim_put(&s, phone, 1)
	// What it wrote is written down a little after, as when lists were last used is; and then nothing for a long while.
	s.now += 10_000
	phone.node.now = sim_now(&s, phone)
	for node_retain(&phone.node) {}
	due := node_retain_due(&phone.node)
	testing.expectf(t, due == 0 || due > phone.node.now + 24 * 3600 * 1000, "due %v at %v", due, phone.node.now)
}

// Once nothing holds on to what is held beyond what may be, it is let go of soon, and not a month later. (Review 1, 11.)
@(test)
review_over_when_let_go :: proc(t: ^testing.T) {
	state := seeded(49)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, phone := s.nodes[0], s.nodes[1]
	for i in 0 ..< 200 {
		sim_put(&s, big, u64(i))
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	ui := sim_client(&s, phone)
	list := List{1 << 32 | 5, 5}
	sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true})
	sim_settle(&s)
	node_keep(&phone.node, {age = 30 * 24 * 3600 * 1000, bytes = store_held(&phone.node.store) / 4})
	for node_retain(&phone.node) {}
	testing.expect_value(t, store_range(&phone.node.store, list_lo(list), list_hi(list)).count, 200)
	session_close(ui)
	sim_settle(&s)
	s.now += 2000
	phone.node.now = sim_now(&s, phone)
	testing.expectf(t, node_retain_due(&phone.node) <= phone.node.now, "due %v, now %v", node_retain_due(&phone.node), phone.node.now)
	for node_retain(&phone.node) {}
	testing.expect(t, store_held(&phone.node.store) <= phone.node.keep.bytes)
}

// Brings a device becoming partial to the point where it has sent all it had to a relay, and waits to hear that it is
// durable there: true if it got there before hearing, as is wanted.
@(private)
sim_to_level :: proc(s: ^Sim, l: Sim_Link) -> bool {
	for _ in 0 ..< 10_000 {
		if l.a.level_at > 0 {
			return !l.a.node.whole
		}
		busy := sim_pass(s, l.a, l.b)
		if l.a.level_at > 0 {
			return !l.a.node.whole
		}
		busy |= sim_pass(s, l.b, l.a)
		if store_unsynced(&l.b.node.store) {
			node_sync(l.b.node)
			busy = true
		}
		if !busy {
			return false
		}
	}
	return false
}

// What a device becoming partial is written, or given by a partial peer, while it waits to hear that all it sent is
// durable, is not lost when it hears, and goes on to be partial. (Review 2, 1A.)
@(test)
review2_becoming_window :: proc(t: ^testing.T) {
	for given in ([]bool{false, true}) {
		state := seeded(51)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 2, partial = 1, relays = 1, ring = 256)
		defer sim_destroy(&s)
		big, dev, phone := s.nodes[0], s.nodes[1], s.nodes[2]
		sim_put(&s, dev, 1)
		sim_restart(&s, dev, full = false)
		testing.expect(t, dev.node.becoming)
		sim_link(&s, 1, 3)
		testing.expect(t, sim_to_level(&s, s.links[0]), "never got to the point where it waits")
		if given {
			// A partial peer gives it something, and forgets it once told it is held.
			sim_link(&s, 2, 1)
			sim_put(&s, phone, 2)
			l := s.links[1]
			for _ in 0 ..< 20 {
				sim_pass(&s, l.a, l.b)
				node_sync(&dev.node)
				sim_pass(&s, l.b, l.a)
			}
		} else {
			sim_put(&s, dev, 2)
		}
		// It hears that what it sent is durable, and the link goes before it says more.
		l := s.links[0]
		for _ in 0 ..< 20 {
			node_sync(l.b.node)
			sim_pass(&s, l.b, l.a)
		}
		testing.expect(t, dev.node.whole)
		for len(s.links) > 0 {
			sim_cut(&s, 0)
		}
		sim_restart(&s, dev, full = false)
		testing.expect(t, !dev.node.becoming)
		sim_link(&s, 1, 3)
		sim_link(&s, 0, 3)
		sim_link(&s, 2, 3)
		sim_settle(&s)
		testing.expectf(t, store_range(&big.node.store, KEY_MIN, KEY_MAX).count == 2, "given %v: big has %d of 2", given, store_range(&big.node.store, KEY_MIN, KEY_MAX).count)
	}
}

// A device becoming partial is not level for an Ack that refuses something, for the whole-scope watches of a roster
// since let go of, nor for watches the other refuses. (Review 2, 1B, 1C, 1D.)
@(test)
review2_level_is_earned :: proc(t: ^testing.T) {
	for way in 0 ..< 3 {
		state := seeded(52)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
		defer sim_destroy(&s)
		dev := s.nodes[1]
		sim_put(&s, dev, 1)
		sim_restart(&s, dev, full = false)
		sim_link(&s, 1, 2)
		l := s.links[0]
		switch way {
		case 0, 1:
			testing.expect(t, sim_to_level(&s, l))
			f: [dynamic]byte
			defer delete(f)
			if way == 0 {
				at := frame_begin(&f, .Ack)
				write_varint(&f, l.a.seq_out)
				scan := tree_scan(&dev.node, dev.node.cells, KEY_MIN, KEY_MAX)
				leaf, _ := tree_next(&scan)
				write_pair(&f, Id{leaf.key[0], leaf.key[1]})
				frame_end(&f, at)
			} else {
				roots_drop(l.a)
				at := frame_begin(&f, .Ack)
				write_varint(&f, l.a.seq_out)
				frame_end(&f, at)
			}
			session_input(l.a, f[:])
		case 2:
			// Before anything is compared, the other says it holds none of what is watched.
			for _ in 0 ..< 50 {
				if len(l.a.roots) > 0 {
					break
				}
				sim_pass(&s, l.a, l.b)
				sim_pass(&s, l.b, l.a)
			}
			f: [dynamic]byte
			defer delete(f)
			for scope in l.a.roots {
				at := frame_begin(&f, .Synced)
				write_varint(&f, l.a.roots_gen * ROOT + u64(scope))
				write_u8(&f, 4) // denied
				write_key(&f, {})
				write_key(&f, {})
				write_varint(&f, 0)
				write_varint(&f, 0)
				frame_end(&f, at)
			}
			session_input(l.a, f[:])
			_ = session_output(l.a)
		}
		testing.expectf(t, !dev.node.whole, "way %d: level without having earned it", way)
	}
}

// Two devices becoming partial, that meet only each other, are not level with each other: neither holds for good what
// the other has. (Review 2, 2.)
@(test)
review2_becoming_pair :: proc(t: ^testing.T) {
	state := seeded(53)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	a, b, relay := s.nodes[0], s.nodes[1], s.nodes[2]
	sim_put(&s, a, 1)
	sim_put(&s, b, 2)
	sim_restart(&s, a, full = false)
	sim_restart(&s, b, full = false)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	sim_cut(&s, 0)
	sim_link(&s, 1, 0)
	sim_settle(&s)
	testing.expect(t, !a.node.whole && !b.node.whole)
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	sim_restart(&s, a, full = false)
	sim_restart(&s, b, full = false)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, store_range(&relay.node.store, KEY_MIN, KEY_MAX).count, 2)
}

// What a full peer says of a window is believed only of what was asked for, and only when it says it is settled.
// (Review 2, 3A, 3B.)
@(test)
review2_settled_from_a_full_peer :: proc(t: ^testing.T) {
	for way in 0 ..< 2 {
		state := seeded(54)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
		defer sim_destroy(&s)
		victim := s.nodes[1]
		sim_link(&s, 1, 0)
		sim_settle(&s)
		ui := sim_client(&s, victim)
		defer session_close(ui)
		list, other := List{1 << 32 | 5, 5}, List{1 << 32 | 6, 6}
		sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true, live = true})
		for _ in 0 ..< 3 {
			sim_pass(&s, s.links[0].a, s.links[0].b) // the watch reaches the peer, which has not answered
		}
		it := &victim.node.interests[0]
		f: [dynamic]byte
		defer delete(f)
		at := frame_begin(&f, .Synced)
		write_varint(&f, it.id)
		if way == 0 {
			write_u8(&f, 1)
			write_key(&f, list_lo(other))
			write_key(&f, list_hi(other))
		} else {
			write_u8(&f, 0)
			write_key(&f, list_lo(list))
			write_key(&f, list_hi(list))
		}
		write_varint(&f, 0)
		write_varint(&f, 0)
		frame_end(&f, at)
		session_input(s.links[0].a, f[:])
		w := victim.node.interests[0].watch
		testing.expectf(t, key_less(w.lo, w.hi), "way %d: the window came to nothing", way)
		testing.expectf(t, way == 0 || len(victim.node.interests[0].reports) == 0, "an unsettled Synced counted")
		sim_link(&s, 1, 2)
		sim_settle(&s)
		for l in s.links {
			testing.expect(t, !l.a.closing && !l.b.closing)
		}
	}
}

// A row in two lists, of which one was never said to be watched, as one held before lists' ages were kept, is kept as
// long as any, whichever list is gone over first. (Review 2, 6.)
@(test)
review2_unstamped_list :: proc(t: ^testing.T) {
	state := seeded(55)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, phone := s.nodes[0], s.nodes[1]
	a, b := List{1 << 32 | 5, 5}, List{1 << 32 | 6, 6}
	big.node.now = sim_now(&s, big)
	row := node_id(&big.node, 1)
	place :: proc(l: List) -> []byte {
		body := make([]byte, 24, context.temp_allocator)
		put_u64(body, l[0])
		put_u64(body[8:], l[1])
		return body
	}
	testing.expect(t, node_write(&big.node, {{row, PLACE, .Place, node_stamp(&big.node), place(a)}, {row, PLACE + 1, .Place, node_stamp(&big.node), place(b)}}))
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	node_keep(&phone.node, {age = 2000, bytes = 0})
	ui := sim_client(&s, phone)
	sim_watch(ui, 1, list_lo(b), list_hi(b), 0, {data = true})
	sim_settle(&s)
	session_close(ui)
	sim_settle(&s)
	clear_used(&phone.node) // as though held before lists' ages were kept
	ui = sim_client(&s, phone)
	sim_watch(ui, 1, list_lo(a), list_hi(a), 0, {data = true})
	sim_settle(&s)
	session_close(ui)
	sim_settle(&s)
	s.now += 5000
	phone.node.now = sim_now(&s, phone)
	for node_retain(&phone.node) {}
	testing.expect_value(t, store_range(&phone.node.store, list_lo(b), list_hi(b)).count, 1)
}

// What a peer refused is not made up for by a later Ack that refuses nothing: a device becoming partial is not level on
// that session, and offers the row again. (Review 3, 1.)
@(test)
review3_refused_then_clean :: proc(t: ^testing.T) {
	state := seeded(61)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	dev := s.nodes[1]
	sim_put(&s, dev, 1)
	sim_restart(&s, dev, full = false)
	sim_link(&s, 1, 2)
	l := s.links[0]
	testing.expect(t, sim_to_level(&s, l))
	scan := tree_scan(&dev.node, dev.node.cells, KEY_MIN, KEY_MAX)
	leaf, _ := tree_next(&scan)
	w1 := Id{leaf.key[0], leaf.key[1]}
	f: [dynamic]byte
	defer delete(f)
	at := frame_begin(&f, .Ack)
	write_varint(&f, l.a.seq_out)
	write_pair(&f, w1)
	frame_end(&f, at)
	session_input(l.a, f[:])
	testing.expect(t, !dev.node.whole)
	// Then something more is written, sent, and acknowledged with nothing refused.
	sim_put(&s, dev, 2)
	for _ in 0 ..< 10 {
		sim_pass(&s, l.a, l.b)
	}
	clear(&f)
	at = frame_begin(&f, .Ack)
	write_varint(&f, l.a.seq_out)
	frame_end(&f, at)
	session_input(l.a, f[:])
	_, offered := tree_get(&dev.node, dev.node.outbox, {w1[0], w1[1], 0, 0, 0})
	testing.expectf(t, !dev.node.whole || offered, "level, with what was refused offered nowhere")
}

// A window a full peer is asked for with a limit, narrowed here to what is held, is not emptied by bounds the peer says
// that meet what was asked but not the window. (Review 3, 2.)
@(test)
review3_limit_window :: proc(t: ^testing.T) {
	state := seeded(62)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, victim := s.nodes[0], s.nodes[1]
	for i in 0 ..< 20 {
		sim_put(&s, big, u64(i))
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	list := List{1 << 32 | 5, 5}
	ui := sim_client(&s, victim)
	defer session_close(ui)
	sim_watch(ui, 9, list_lo(list), list_hi(list), 0, {data = true})
	sim_settle(&s)
	sim_watch(ui, 9, list_lo(list), list_hi(list), 0, {})
	sim_settle(&s)
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	keys := make([dynamic]Key, context.temp_allocator)
	scan := tree_scan(&victim.node, victim.node.shelf, list_lo(list), list_hi(list))
	for leaf in tree_next(&scan) {
		append(&keys, leaf.key)
	}
	testing.expect_value(t, len(keys), 20)
	sim_link(&s, 1, 0) // to a full peer, which is not to be believed of more than it was asked
	sim_settle(&s)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 5, {data = true})
	for _ in 0 ..< 3 {
		sim_pass(&s, s.links[0].a, s.links[0].b)
	}
	var_it: ^Interest
	for &it in victim.node.interests {
		if it.watch.data {
			var_it = &it
		}
	}
	testing.expect(t, var_it != nil)
	f: [dynamic]byte
	defer delete(f)
	at := frame_begin(&f, .Synced)
	write_varint(&f, var_it.id)
	write_u8(&f, 1)
	write_key(&f, keys[10])
	write_key(&f, list_hi(list))
	write_varint(&f, 0)
	write_varint(&f, 0)
	frame_end(&f, at)
	session_input(s.links[0].a, f[:])
	for w in ui.watches {
		w := w
		testing.expectf(t, key_less(w.lo, w.hi), "the window %d came to nothing", w.id)
	}
	for it in victim.node.interests {
		it := it
		testing.expect(t, key_less(it.watch.lo, it.watch.hi))
	}
	sim_link(&s, 1, 2)
	sim_settle(&s)
	for l in s.links {
		testing.expectf(t, !l.a.closing && !l.b.closing, "closing %d->%d: %v %v %v %v", l.an, l.bn, l.a.closing, l.a.fault, l.b.closing, l.b.fault)
	}
}

// A device becoming partial that is brought level by a full peer that is not a relay does not record all it was sent as
// though it were its own: it can let go of it once partial, and does not send it all back. (Review 3, 3.)
@(test)
review3_becoming_takes_only_its_own :: proc(t: ^testing.T) {
	state := seeded(63)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 256)
	defer sim_destroy(&s)
	desk, laptop := s.nodes[0], s.nodes[1]
	for i in 0 ..< 50 {
		sim_put(&s, desk, u64(i))
	}
	sim_restart(&s, laptop, full = false)
	sim_link(&s, 1, 0)
	sim_settle(&s)
	testing.expect(t, laptop.node.whole)
	testing.expect_value(t, laptop.node.outbox.root, 0)
}

// A device becoming partial, dialled by a full peer, is brought level as well as one that dials. (Review 3, 5.)
@(test)
review3_becoming_dialled :: proc(t: ^testing.T) {
	state := seeded(64)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 256)
	defer sim_destroy(&s)
	desk, laptop := s.nodes[0], s.nodes[1]
	sim_put(&s, desk, 1)
	sim_put(&s, laptop, 2)
	sim_restart(&s, laptop, full = false)
	sim_link(&s, 0, 1) // the desk dials
	sim_settle(&s)
	testing.expect_value(t, store_range(&desk.node.store, KEY_MIN, KEY_MAX).count, 2)
	testing.expect_value(t, store_range(&laptop.node.store, KEY_MIN, KEY_MAX).count, 2)
	testing.expect(t, laptop.node.whole)
}

// Something refused before a device becoming partial has sent all it has, however early, means it is not level on that
// session; and what a peer says it refused is not taken on trust into the outbox. (Review 4, 1, 2.)
@(test)
review4_refused_early :: proc(t: ^testing.T) {
	for way in 0 ..< 2 {
		state := seeded(71)
		context.random_generator = rand.default_random_generator(&state)
		s: Sim
		sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
		defer sim_destroy(&s)
		dev := s.nodes[1]
		dev.node.now = sim_now(&s, dev)
		big_value := make([]byte, 16 << 10)
		defer delete(big_value)
		for i in 0 ..< (6 if way == 0 else 1) {
			sim_put(&s, dev, u64(i))
			scan := tree_scan(&dev.node, dev.node.shelf, KEY_MIN, KEY_MAX)
			last: Key
			for leaf in tree_next(&scan) {
				last = leaf.key
			}
			row := key_row(last)
			testing.expect(t, node_write(&dev.node, {{row, DATA, .Value, node_stamp(&dev.node), big_value}}))
		}
		sim_restart(&s, dev, full = false)
		sim_link(&s, 1, 2)
		l := s.links[0]
		f: [dynamic]byte
		defer delete(f)
		if way == 0 {
			// The first cells have gone, and there is more to send.
			for _ in 0 ..< 1000 {
				if l.a.seq_out > 0 || l.a.level_at > 0 {
					break
				}
				sim_pass(&s, l.a, l.b)
				sim_pass(&s, l.b, l.a)
			}
			testing.expect(t, l.a.seq_out > 0 && l.a.level_at == 0, "never between")
			// Whatever of a frame from the relay is on its way arrives whole first: frames are cut up as they go.
			for len(l.a.input) > 0 {
				out := session_output(l.b)
				if len(out) == 0 {
					break
				}
				copied := slice.clone(out, context.temp_allocator)
				session_sent(l.b, len(out))
				testing.expect(t, session_input(l.a, copied))
			}
			testing.expect(t, l.a.level_at == 0 && len(l.a.input) == 0, "no longer between")
			scan := tree_scan(&dev.node, dev.node.cells, KEY_MIN, KEY_MAX)
			leaf, _ := tree_next(&scan)
			at := frame_begin(&f, .Ack)
			write_varint(&f, l.a.seq_out)
			write_pair(&f, Id{leaf.key[0], leaf.key[1]})
			frame_end(&f, at)
			session_input(l.a, f[:])
			sim_settle(&s)
			testing.expect(t, !dev.node.whole, "level, though something was refused")
		} else {
			testing.expect(t, sim_to_level(&s, l))
			at := frame_begin(&f, .Ack)
			write_varint(&f, 0)
			for i in 0 ..< 500 {
				write_pair(&f, Id{u64(1) << 32 | 7, u64(i)})
			}
			frame_end(&f, at)
			session_input(l.a, f[:])
			n := 0
			scan := tree_scan(&dev.node, dev.node.outbox, KEY_MIN, KEY_MAX)
			for _ in tree_next(&scan) {
				n += 1
			}
			testing.expectf(t, n < 10, "a peer put %d rows in the outbox", n)
		}
	}
}

// When lists were last watched is written down soon after, though the node is never stopped, as a browser's tab may go
// without stopping it: a list read the day before is not let go of after, and one read long ago is. (Review 5, 2.)
@(test)
review5_ages_are_kept :: proc(t: ^testing.T) {
	state := seeded(81)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, phone := s.nodes[0], s.nodes[1]
	DAY :: 24 * 3600 * 1000
	sim_put(&s, big, 1)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	list := List{1 << 32 | 5, 5}
	tick :: proc(s: ^Sim, x: ^Sim_Node, after: u64) {
		s.now += after
		for y in s.nodes {
			y.node.now = sim_now(s, y)
		}
		for node_retain(&x.node) {} // as a host does, when it is due
	}
	look :: proc(s: ^Sim, x: ^Sim_Node, list: List) {
		ui := sim_client(s, x)
		sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true})
		sim_settle(s)
		session_close(ui)
		sim_settle(s)
	}
	// Gone without being stopped: what was synced is there, and what was checkpointed.
	gone :: proc(s: ^Sim, x: ^Sim_Node) {
		#reverse for l, j in s.links {
			if l.a.node == &x.node || l.b.node == &x.node {
				sim_cut(s, j)
			}
		}
		testing.expect(s.t, store_sync(&x.node.store))
		node_destroy(&x.node)
		keyring_destroy(&x.keys)
		keyring_init(&x.keys, x.secret)
		if x.kept != nil {
			testing.expect(s.t, keyring_load(&x.keys, x.kept))
		}
		sim_boot(s, x)
		node_keep(&x.node, {age = 30 * DAY, bytes = 0})
	}
	node_keep(&phone.node, {age = 30 * DAY, bytes = 0})
	look(&s, phone, list)
	testing.expect(t, store_checkpoint(&phone.node.store)) // as it was, on the first day
	tick(&s, phone, 10_000)
	tick(&s, phone, 29 * DAY)
	look(&s, phone, list) // read again on the 29th day
	tick(&s, phone, 10_000)
	gone(&s, phone)
	tick(&s, phone, 2 * DAY)
	testing.expect_value(t, store_range(&phone.node.store, list_lo(list), list_hi(list)).count, 1)
	// And one not read again goes when its time is up, however often the device comes and goes.
	tick(&s, phone, 10_000)
	gone(&s, phone)
	tick(&s, phone, 29 * DAY)
	testing.expect_value(t, store_range(&phone.node.store, list_lo(list), list_hi(list)).count, 0)
}

// A row in several places of one list that is let go of is let go of once: what it left behind is counted once.
// (Review 5, 3.)
@(test)
review5_let_go_once :: proc(t: ^testing.T) {
	state := seeded(82)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, phone := s.nodes[0], s.nodes[1]
	list := List{1 << 32 | 5, 5}
	big.node.now = sim_now(&s, big)
	row := node_id(&big.node, 1)
	cells := make([dynamic]Cell, context.temp_allocator)
	for slot in PLACE ..< PLACE + 5 {
		body := make([]byte, 24, context.temp_allocator)
		put_u64(body, list[0])
		put_u64(body[8:], list[1])
		put_u64(body[16:], u64(slot))
		append(&cells, Cell{row, slot, .Place, node_stamp(&big.node), body})
	}
	append(&cells, Cell{row, DATA, .Value, node_stamp(&big.node), make([]byte, 10_000, context.temp_allocator)})
	testing.expect(t, node_write(&big.node, cells[:]))
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	node_keep(&phone.node, {age = 1000, bytes = 0})
	ui := sim_client(&s, phone)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true})
	sim_settle(&s)
	session_close(ui)
	sim_settle(&s)
	held := store_held(&phone.node.store)
	forgot := phone.node.forgot
	s.now += 5000
	phone.node.now = sim_now(&s, phone)
	for node_retain(&phone.node) {}
	testing.expect_value(t, store_range(&phone.node.store, list_lo(list), list_hi(list)).count, 0)
	testing.expectf(t, phone.node.forgot - forgot == 6, "forgot %d cells of 6", phone.node.forgot - forgot)
	_ = held
}

// After a crash, what a partial replica's log has to say of what it held since its last checkpoint is replayed: what it
// was given by others it may let go of, offline, as anything; only what its own clients wrote is kept until a full
// replica holds it.
@(test)
crash_tail_lets_go :: proc(t: ^testing.T) {
	state := seeded(91)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, phone := s.nodes[0], s.nodes[1]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 20 {
		sim_put(&s, big, u64(i))
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect(t, store_checkpoint(&phone.node.store))
	ui := sim_client(&s, phone)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 0, {data = true})
	sim_settle(&s)
	session_close(ui)
	sim_settle(&s)
	testing.expect_value(t, store_range(&phone.node.store, list_lo(list), list_hi(list)).count, 20)
	// It writes, while it reaches nobody, and then loses its power: none of this was checkpointed.
	for len(s.links) > 0 {
		sim_cut(&s, 0)
	}
	sim_put(&s, phone, 1000)
	testing.expect(t, store_sync(&phone.node.store))
	node_destroy(&phone.node)
	keyring_destroy(&phone.keys)
	keyring_init(&phone.keys, phone.secret)
	if phone.kept != nil {
		testing.expect(t, keyring_load(&phone.keys, phone.kept))
	}
	sim_boot(&s, phone)
	n := 0
	scan := tree_scan(&phone.node, phone.node.outbox, KEY_MIN, KEY_MAX)
	for _ in tree_next(&scan) {
		n += 1
	}
	testing.expectf(t, n == 1, "%d rows in the outbox, of which one is its own", n)
	// Days later, still offline: what others wrote goes, and what it wrote stays.
	node_keep(&phone.node, {age = 1000, bytes = 0})
	for node_retain(&phone.node) {} // as it starts: when it last watched the list was lost with the rest, and is now
	s.now += 100_000
	phone.node.now = sim_now(&s, phone)
	for node_retain(&phone.node) {}
	testing.expect_value(t, store_range(&phone.node.store, list_lo(list), list_hi(list)).count, 1)
	// And once it reaches a full replica, that is had there too.
	sim_link(&s, 1, 2)
	sim_link(&s, 0, 2)
	sim_settle(&s)
	testing.expect_value(t, store_range(&big.node.store, list_lo(list), list_hi(list)).count, 21)
	testing.expect_value(t, phone.node.outbox.root, 0)
}

// A full replica that is being brought level, and is asked meanwhile for the end of a list, shows the end of the list,
// as the one it is brought level by says it is: not as much as it happened to hold of the list when it was asked, and
// all that comes after into the bargain. Its window is settled once that one has said so; and one with nobody to ask
// is the one that says so.
@(test)
full_window_while_catching_up :: proc(t: ^testing.T) {
	state := seeded(92)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, fresh := s.nodes[0], s.nodes[1]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 1000 {
		sim_put(&s, big, u64(i))
	}
	sim_link(&s, 0, 2)
	sim_settle(&s)
	ui := sim_client(&s, fresh)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true})
	// Alone, it is all there is: settled.
	out := session_output(ui)
	settled_now := false
	r := Reader{buf = out}
	for r.pos < len(out) {
		frame := read_bytes(&r)
		if Message(frame[0]) == .Synced {
			f := Reader{buf = frame[1:]}
			_ = read_varint(&f)
			settled_now = Synced_Flags(read_u8(&f)).settled
		}
	}
	session_sent(ui, len(out))
	testing.expect(t, settled_now, "a full replica with nobody to ask did not say its window was settled")
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, store_range(&fresh.node.store, KEY_MIN, KEY_MAX).count, 1000)
	w := ui.watches[0]
	testing.expectf(t, store_range(&fresh.node.store, w.lo, w.hi).count == 50, "the window spans %d rows, not 50", store_range(&fresh.node.store, w.lo, w.hi).count)
	testing.expect(t, w.settled)
}

// A window of limited size that waits for a full replica to bound it is, meanwhile, what is held: as rows come, from
// wherever, it is bounded again, and stays about its size, rather than growing with all that comes, all of it sent to
// the client (again, whole, whenever the client falls behind), as in a browser being brought level it did.
@(test)
waiting_window_stays_its_size :: proc(t: ^testing.T) {
	state := seeded(93)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	device := s.nodes[0]
	list := List{1 << 32 | 5, 5}
	sim_link(&s, 0, 1)
	sim_settle(&s)
	ui := sim_client(&s, device)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true, counts = true})
	session_sent(ui, len(session_output(ui)))
	// The relay is asked, and its answer does not come: nothing passes between them until they settle.
	widest := 0
	for i in 0 ..< 2000 {
		sim_put(&s, device, u64(i))
		if i % 40 == 39 {
			session_sent(ui, len(session_output(ui)))
			w := ui.watches[0]
			widest = max(widest, store_range(&device.node.store, w.lo, w.hi).count)
		}
	}
	testing.expectf(t, widest <= 2 * 50 + 40, "a window of 50 came to span %d rows", widest)
	w := ui.watches[0]
	testing.expect(t, !w.settled)
	// Once answered, it is as the answer says, and grows with its list from then on.
	sim_settle(&s)
	for len(session_output(ui)) > 0 {
		session_sent(ui, len(session_output(ui)))
	}
	w = ui.watches[0]
	testing.expect(t, w.settled)
	for i in 2000 ..< 2200 {
		sim_put(&s, device, u64(i))
	}
	sim_settle(&s)
	for len(session_output(ui)) > 0 {
		session_sent(ui, len(session_output(ui)))
	}
	w = ui.watches[0]
	testing.expect(t, store_range(&device.node.store, w.lo, w.hi).count > 200, "an answered window stopped growing with its list")
}

// A full replica being brought level by another that holds much, asked meanwhile for the end of a list, has it at
// once, before the rest: what the other answers a window of limited size with goes before the rest of what it sends.
@(test)
window_goes_before_the_rest :: proc(t: ^testing.T) {
	state := seeded(94)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	big, fresh := s.nodes[0], s.nodes[1]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 10_000 {
		sim_put(&s, big, u64(i))
	}
	sim_link(&s, 0, 2)
	sim_settle(&s)
	ui := sim_client(&s, fresh)
	defer session_close(ui)
	sim_link(&s, 1, 2)
	up := s.links[1]
	for !up.a.ready || !up.b.ready {
		sim_pass(&s, up.a, up.b)
		sim_pass(&s, up.b, up.a)
	}
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true})
	held_when_settled := -1
	for round := 0; round < 10_000; round += 1 {
		busy := false
		for l in s.links {
			busy |= sim_pass(&s, l.a, l.b)
			busy |= sim_pass(&s, l.b, l.a)
		}
		session_sent(ui, len(session_output(ui)))
		if held_when_settled < 0 && len(ui.watches) > 0 && ui.watches[0].settled {
			held_when_settled = store_range(&fresh.node.store, list_lo(list), list_hi(list)).count
		}
		if !busy {
			break
		}
	}
	testing.expect_value(t, store_range(&fresh.node.store, list_lo(list), list_hi(list)).count, 10_000)
	testing.expectf(t, held_when_settled >= 0 && held_when_settled < 5000, "the end of the list was had once %d rows of 10,000 were", held_when_settled)
	w := ui.watches[0]
	testing.expect_value(t, store_range(&fresh.node.store, w.lo, w.hi).count, 50)
}

// A row of a list, `tag`, with a value of so many bytes.
@(private)
sim_put_big :: proc(s: ^Sim, x: ^Sim_Node, tag, order: u64, size: int) {
	s.now += 3
	x.node.now = sim_now(s, x)
	place: [24]byte
	put_u64(place[:], 1 << 32 | tag)
	put_u64(place[8:], tag)
	put_u64(place[16:], order)
	value := make([]byte, size)
	defer delete(value)
	id := node_id(&x.node, 1)
	_ = node_write(&x.node, {{id, PLACE, .Place, node_stamp(&x.node), place[:]}, {id, DATA, .Value, node_stamp(&x.node), value}})
	free_all(context.temp_allocator)
}

// Draws all a client is said, until it is said nothing more.
@(private)
sim_drain :: proc(ui: ^Session) {
	for len(session_output(ui)) > 0 {
		session_sent(ui, len(session_output(ui)))
	}
}

// What answers a window hurried goes first, but in its own order: the rows it found the watcher lacked go before what
// says the window is level, however many of them there are, and however the comparing of it went.
@(test)
review6_hurried_window_settles_after_its_rows :: proc(t: ^testing.T) {
	state := seeded(95)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 0, ring = 256)
	defer sim_destroy(&s)
	owner, phone := s.nodes[0], s.nodes[1]
	list := List{1 << 32 | 5, 5}
	sim_put_big(&s, phone, 5, 0, 20_000)
	sim_link(&s, 1, 0)
	sim_settle(&s)
	for i in 1 ..= 20 {
		sim_put_big(&s, owner, 5, u64(i), 20_000)
	}
	ui := sim_client(&s, phone)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true})
	held_when_settled := -1
	for round := 0; round < 10_000; round += 1 {
		busy := false
		for l in s.links {
			busy |= sim_pass(&s, l.a, l.b)
			busy |= sim_pass(&s, l.b, l.a)
		}
		sim_drain(ui)
		if held_when_settled < 0 && ui.watches[0].settled {
			held_when_settled = store_range(&phone.node.store, list_lo(list), list_hi(list)).count
		}
		if !busy {
			break
		}
	}
	testing.expect_value(t, held_when_settled, 21)
}

// A watch replaced is not hurried for the one it was: what replaces it, however large, waits its turn.
@(test)
review6_replaced_watch_is_not_hurried :: proc(t: ^testing.T) {
	state := seeded(96)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 0, ring = 256)
	defer sim_destroy(&s)
	owner := s.nodes[0]
	for i in 0 ..< 100 {
		sim_put_big(&s, owner, 5, u64(i), 20_000)
		sim_put_big(&s, owner, 6, u64(i), 100)
	}
	sim_link(&s, 1, 0)
	sim_settle(&s)
	at := s.links[0].b // the owner's end
	a, b := List{1 << 32 | 5, 5}, List{1 << 32 | 6, 6}
	sim_watch(at, 10, list_lo(a), list_hi(a), 200, {data = true})
	testing.expect(t, slice.contains(at.hurried[:], 10))
	_ = session_output(at) // some of it, not all
	sim_watch(at, 10, list_lo(b), list_hi(b), 0, {data = true, known = true})
	_ = session_output(at)
	testing.expect(t, !slice.contains(at.hurried[:], 10), "a watch replaced stayed hurried for what replaced it")
}

// A full replica alone says a window is settled: it is all there is. Once it asks another, it says so no longer until
// that one answers; and a window that its client has gone on from with a page before it is not cut short there, before
// the answer or after, or what lay between the two would be in neither.
@(test)
review6_window_gone_on_from_is_not_cut :: proc(t: ^testing.T) {
	state := seeded(97)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	owner := s.nodes[0]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 100 {
		sim_put(&s, owner, u64(100 + i))
	}
	ui := sim_client(&s, owner)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true, counts = true})
	sim_drain(ui)
	testing.expect(t, ui.watches[0].settled)
	// The page before it, as a client asks for it when it is scrolled to.
	page := ui.watches[0]
	sim_watch(ui, 2, list_lo(list), page.lo, 50, {data = true, live = true, back = true, counts = true})
	sim_drain(ui)
	// And more, after.
	for i in 200 ..< 300 {
		sim_put(&s, owner, u64(i))
	}
	sim_drain(ui)
	find :: proc(ui: ^Session, id: u64) -> Watch {
		for w in ui.watches {
			if w.id == id {
				return w
			}
		}
		return {}
	}
	testing.expect(t, find(ui, 1).lo == page.lo)
	sim_link(&s, 0, 1)
	up := s.links[0]
	// Until both are ready, and no more: what the relay says once its end is ready is held back, its answer too.
	for !up.a.ready || !up.b.ready {
		sim_pass(&s, up.a, up.b)
		if !up.a.ready {
			sim_pass(&s, up.b, up.a)
		}
	}
	sim_put(&s, owner, 300)
	sim_drain(ui)
	testing.expect(t, !find(ui, 1).settled, "a full replica said its window was settled while it waited for another")
	testing.expect(t, find(ui, 1).lo == page.lo, "a window gone on from was cut short before the answer")
	sim_settle(&s)
	sim_drain(ui)
	testing.expect(t, find(ui, 1).settled)
	testing.expect(t, find(ui, 1).lo == find(ui, 2).hi, "a window gone on from was cut short by the answer")
}

// A relay hushed, as one is once every other device it carries is reached directly, owes nothing more: what it was
// asked and never answered is not waited for for ever.
@(test)
review6_hushed_relay_owes_nothing :: proc(t: ^testing.T) {
	state := seeded(98)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	a := s.nodes[0]
	list := List{1 << 32 | 5, 5}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	sim_put(&s, a, 1)
	ui := sim_client(&s, a)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true})
	// Asked of the relay; and, before it answers, the other is reached directly, and the relay hushed.
	to_relay: ^Session
	for l in s.links {
		if l.an == 0 && l.bn == 2 {
			to_relay = l.a
		}
	}
	testing.expect(t, len(to_relay.owed) == 1)
	sim_link(&s, 0, 1)
	direct := s.links[len(s.links) - 1]
	for round := 0; round < 1000 && !to_relay.paused; round += 1 {
		sim_pass(&s, direct.a, direct.b)
		sim_pass(&s, direct.b, direct.a)
	}
	testing.expect(t, to_relay.paused, "the relay was not hushed")
	sim_settle(&s)
	sim_drain(ui)
	testing.expect(t, ui.watches[0].settled, "a window stayed waiting for a relay hushed")
	testing.expect(t, !to_relay.paused || len(to_relay.owed) == 0, "a relay hushed was still owed")
}

// A new roster asks again of whoever can answer; of a full replica alone, nobody: its windows stay settled.
@(test)
review6_roster_leaves_alone_settled :: proc(t: ^testing.T) {
	state := seeded(99)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256) // the relay is never reached
	defer sim_destroy(&s)
	owner := s.nodes[0]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 10 {
		sim_put(&s, owner, u64(i))
	}
	ui := sim_client(&s, owner)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true})
	sim_drain(ui)
	testing.expect(t, ui.watches[0].settled)
	sim_rotate(&s, restore = true)
	sim_drain(ui)
	testing.expect(t, ui.watches[0].settled, "a new roster unsettled a full replica's window, with nobody to settle it again")
}

// A row offered again, once all that was to be sent of it has been, is offered then: not when something else is next
// to be said.
@(test)
review6_reoffer_goes_at_once :: proc(t: ^testing.T) {
	state := seeded(100)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 0, ring = 256)
	defer sim_destroy(&s)
	phone := s.nodes[1]
	sim_link(&s, 1, 0)
	sim_settle(&s)
	phone.node.now = sim_now(&s, phone)
	id := node_id(&phone.node, 1)
	place: [24]byte
	put_u64(place[:], 1 << 32 | 5)
	put_u64(place[8:], 5)
	_ = node_write(&phone.node, {{id, PLACE, .Place, node_stamp(&phone.node), place[:]}})
	sim_settle(&s)
	ps := s.links[0].a
	testing.expect(t, len(session_output(ps)) == 0)
	// As though it had been acknowledged while a cell of it, killed since, was still to be sent.
	tree_put(&phone.node, &phone.node.outbox, {id[0], id[1], 0, 0, 0}, {})
	append(&ps.tasks, Task{kind = .Cell, row = id, lo = {id[0], id[1], u64(DATA) << 8, 0, 1}})
	append(&ps.reoffer, id)
	testing.expect(t, len(session_output(ps)) > 0, "a row to offer again waited for something else to be said")
	free_all(context.temp_allocator)
}

// A window that its client has gone on from below is not cut short there; and what a full replica said of less than it,
// is not taken for the whole of it: the whole is asked for, and kept up, before it is said to be settled.
@(test)
review7_uncut_window_is_asked_for_whole :: proc(t: ^testing.T) {
	state := seeded(101)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 1, relays = 0, ring = 256)
	defer sim_destroy(&s)
	owner, phone := s.nodes[0], s.nodes[1]
	list := List{1 << 32 | 5, 5}
	for i in 100 ..< 200 {
		sim_put(&s, phone, u64(i))
	}
	// Held by both, and then the phone is away.
	sim_link(&s, 1, 0)
	sim_settle(&s)
	sim_cut(&s, 0)
	ui := sim_client(&s, phone)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true, counts = true})
	sim_drain(ui)
	page := ui.watches[0]
	sim_watch(ui, 2, list_lo(list), page.lo, 50, {data = true, live = true, back = true, counts = true})
	sim_drain(ui)
	sim_put(&s, owner, 165)
	for i in 200 ..< 230 {
		sim_put(&s, owner, u64(i))
	}
	sim_link(&s, 1, 0)
	sim_settle(&s)
	sim_drain(ui)
	find :: proc(ui: ^Session, id: u64) -> Watch {
		for w in ui.watches {
			if w.id == id {
				return w
			}
		}
		return {}
	}
	w := find(ui, 1)
	testing.expect(t, w.lo == page.lo)
	testing.expect(t, w.settled)
	testing.expect_value(t, store_range(&phone.node.store, w.lo, w.hi).count, store_range(&owner.node.store, w.lo, w.hi).count)
	// And kept up, all of it.
	sim_put(&s, owner, 166)
	sim_settle(&s)
	sim_drain(ui)
	w = find(ui, 1)
	testing.expect_value(t, store_range(&phone.node.store, w.lo, w.hi).count, store_range(&owner.node.store, w.lo, w.hi).count)
}

// A relay does not sleep with what goes first still to be done.
@(test)
review7_no_sleep_with_first :: proc(t: ^testing.T) {
	state := seeded(102)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	for i in 0 ..< 100 {
		sim_put(&s, s.nodes[0], u64(i))
	}
	sim_link(&s, 0, 1)
	sim_settle(&s)
	at := s.links[0].b // the relay's end
	list := List{1 << 32 | 5, 5}
	sim_watch(at, 7, list_lo(list), list_hi(list), 50, {data = true, back = true})
	testing.expect(t, len(at.first) > 0)
	saved: [dynamic]byte
	defer delete(saved)
	testing.expect(t, !session_save(at, &saved), "a relay would sleep with a window's answer still to give")
}

// A full replica that was all there was, asked of another once it reaches it, bounds its window as rows come, though
// what it said of it before has yet to be told.
@(test)
review7_bounded_before_told :: proc(t: ^testing.T) {
	state := seeded(103)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	owner := s.nodes[0]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 10 {
		sim_put(&s, owner, u64(i))
	}
	ui := sim_client(&s, owner)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true, counts = true})
	sim_drain(ui)
	testing.expect(t, ui.watches[0].settled)
	sim_link(&s, 0, 1)
	up := s.links[0]
	// Until both are ready, and no more: what the relay says once its end is ready is held back, its answer too.
	for !up.a.ready || !up.b.ready {
		sim_pass(&s, up.a, up.b)
		if !up.a.ready {
			sim_pass(&s, up.b, up.a)
		}
	}
	for i in 10 ..< 410 {
		sim_put(&s, owner, u64(i))
	}
	sim_drain(ui)
	w := ui.watches[0]
	testing.expectf(t, store_range(&owner.node.store, w.lo, w.hi).count <= 100, "a window of 50 spans %d rows", store_range(&owner.node.store, w.lo, w.hi).count)
	testing.expect(t, !w.settled)
}

// A relay hushed is forgotten as one gone is: what it said stands for nothing once it no longer keeps it up.
@(test)
review7_hushed_relay_said_nothing :: proc(t: ^testing.T) {
	state := seeded(104)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	a := s.nodes[0]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 100 {
		sim_put(&s, a, u64(i))
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	ui := sim_client(&s, a)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true, counts = true})
	sim_settle(&s)
	sim_drain(ui)
	testing.expect(t, ui.watches[0].settled)
	to_relay := s.links[0].a
	sim_link(&s, 0, 1)
	sim_settle(&s)
	sim_drain(ui)
	testing.expect(t, to_relay.paused, "the relay was not hushed")
	for it in a.node.interests {
		for r in it.reports {
			testing.expect(t, r.session != to_relay.id, "a relay hushed still stood for a window")
		}
	}
	// The other goes: the relay is asked again, and until it answers the window is not settled.
	sim_cut(&s, len(s.links) - 1)
	sim_drain(ui)
	testing.expect(t, !to_relay.paused)
	testing.expect(t, !ui.watches[0].settled, "a window was settled while the relay it waits for had yet to answer")
	sim_settle(&s)
	sim_drain(ui)
	testing.expect(t, ui.watches[0].settled)
}

// A peer that says, again and again, that a window gone on from is less than it is, is not believed: the window is not
// asked for again on its word, nor are what others said of it forgotten.
@(test)
review8_narrow_answers_not_believed :: proc(t: ^testing.T) {
	state := seeded(105)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 1, relays = 0, ring = 256)
	defer sim_destroy(&s)
	phone := s.nodes[2]
	list := List{1 << 32 | 5, 5}
	for i in 100 ..< 200 {
		sim_put(&s, phone, u64(i))
	}
	sim_link(&s, 2, 0)
	sim_link(&s, 2, 1)
	sim_settle(&s)
	ui := sim_client(&s, phone)
	defer session_close(ui)
	sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true, counts = true})
	sim_settle(&s)
	sim_drain(ui)
	page := ui.watches[0]
	testing.expect(t, page.settled)
	sim_watch(ui, 2, list_lo(list), page.lo, 50, {data = true, live = true, back = true, counts = true})
	sim_settle(&s)
	sim_drain(ui)
	it := &phone.node.interests[0]
	for &x in phone.node.interests {
		if x.watch.id == 1 {
			it = &x
		}
	}
	id, reports := it.id, len(it.reports)
	testing.expect_value(t, reports, 2)
	// A key within the window, past where it begins.
	inside: Key
	scan := tree_scan(&phone.node, phone.node.shelf, page.lo, page.hi)
	seen := 0
	for leaf in tree_next(&scan) {
		if seen == 10 {
			inside = leaf.key
			break
		}
		seen += 1
	}
	rogue := s.links[1].a // the phone's end of the link to the second
	for _ in 0 ..< 5 {
		f: [dynamic]byte
		at := frame_begin(&f, .Synced)
		write_varint(&f, it.id)
		flags := Synced_Flags{settled = true}
		write_u8(&f, u8(flags))
		write_key(&f, inside)
		write_key(&f, list_hi(list))
		write_varint(&f, 60)
		write_varint(&f, 0)
		frame_end(&f, at)
		testing.expect(t, session_input(rogue, f[:]))
		delete(f)
		sim_drain(ui)
	}
	testing.expect(t, it.id == id, "a window was asked for again on the word of one that was not asked")
	testing.expect_value(t, len(it.reports), reports)
	testing.expect(t, ui.watches[0].settled)
	free_all(context.temp_allocator)
}

// A full replica brought level by a relay while the relay is still taking in what was written, both falling behind
// what comes in (rings of 256 changes): what it is sent is what there is, about once; not all it lacks again whenever
// either falls behind, and again, while what it lacked is still on its way.
@(test)
catching_up_is_sent_once :: proc(t: ^testing.T) {
	state := seeded(106)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	writer, fresh := s.nodes[0], s.nodes[1]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 3000 {
		sim_put_big(&s, writer, 5, u64(i), 200)
	}
	sim_link(&s, 0, 2)
	up := s.links[0]
	for _ in 0 ..< 4 { // the writing on its way to the relay, and some there
		sim_pass(&s, up.a, up.b)
		sim_pass(&s, up.b, up.a)
	}
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, store_range(&fresh.node.store, list_lo(list), list_hi(list)).count, 3000)
	sent: u64
	for l in s.links {
		if l.an == 1 {
			sent = l.b.taken // what the relay said to it
		}
	}
	whole := u64(3000 * 300) // about what the rows come to, said
	testing.expectf(t, sent < 2 * whole, "%d bytes were sent to bring level %d bytes' worth", sent, whole)
}

// A full replica taking in much from one peer, faster than its ring of changes keeps, misses only what came from that
// peer, which it would never send back: it goes on, rather than asking for everything afresh as though it had missed
// what it should send.
@(test)
missing_only_theirs_is_missing_nothing :: proc(t: ^testing.T) {
	state := seeded(107)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	writer, fresh := s.nodes[0], s.nodes[1]
	for i in 0 ..< 3000 {
		sim_put_big(&s, writer, 5, u64(i), 200)
	}
	sim_link(&s, 0, 2)
	sim_settle(&s)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	list := List{1 << 32 | 5, 5}
	testing.expect_value(t, store_range(&fresh.node.store, list_lo(list), list_hi(list)).count, 3000)
	for l in s.links {
		if l.an == 1 {
			testing.expectf(t, l.a.roots_gen == 0, "it asked for everything afresh %d times", l.a.roots_gen)
		}
	}
}

// What is queued to be sent is not queued again: a row, nor what a Fill still to come will send; but what a step undone
// took back is, and what goes first is not taken to be sent by what goes after it.
@(test)
queued_once :: proc(t: ^testing.T) {
	state := seeded(108)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	at := s.links[0].b // the relay's end: its peer is a full replica, to which every row may be pushed
	list := List{1 << 32 | 5, 5}
	key := Key{list_lo(list)[0], list_lo(list)[1], 7, 1, 2}
	other := Key{list_lo(list)[0], list_lo(list)[1], 9, 3, 4}
	base := len(at.tasks)
	push_row(at, key)
	push_row(at, key)
	testing.expect_value(t, len(at.tasks) - base, 1)
	// Taken back, as by a step undone: then queued again.
	resize(&at.tasks, base)
	push_row(at, key)
	testing.expect_value(t, len(at.tasks) - base, 1)
	// What a Fill still to come will send.
	queue(at, false, {kind = .Fill, lo = list_lo(list), hi = list_hi(list)})
	push_row(at, other)
	testing.expect_value(t, len(at.tasks) - base, 2)
	// Hurried: only what goes first counts.
	at.hurrying = true
	push_row(at, key)
	at.hurrying = false
	testing.expect_value(t, len(at.first), 1)
	clear(&at.tasks)
	clear(&at.first)
	at.task_head, at.first_head = 0, 0
}

// A watch compared afresh is not compared where a Fill still to come will send all of it.
@(test)
unfilled_only_compared :: proc(t: ^testing.T) {
	state := seeded(109)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	for i in 0 ..< 100 {
		sim_put(&s, s.nodes[0], u64(i))
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	at: ^Session
	for l in s.links {
		if l.an == 1 {
			at = l.b // the relay's end of the second's link: the second watches it whole
		}
	}
	testing.expect(t, len(at.watches) > 0)
	w := &at.watches[0]
	queue(at, false, {kind = .Fill, watch = w.id, lo = w.lo, hi = w.hi})
	before := len(at.out)
	recon_unfilled(at, w)
	testing.expect_value(t, len(at.out), before)
	clear(&at.tasks)
	at.task_head = 0
	free_all(context.temp_allocator)
}

// A way between two sessions as a network is: so many bytes a round at most, arriving so many rounds after they went.
@(private)
Sim_Way :: struct {
	line:   [dynamic]Sim_Held,
	queued: int, // bytes on the way, not yet arrived
}

@(private)
Sim_Held :: struct {
	due:   int, // the round from which it may arrive
	bytes: []byte,
}

// What the session has to say goes onto the way, all of it, as onto a socket that takes it.
@(private)
sim_way_send :: proc(from: ^Session, way: ^Sim_Way, round, latency: int) {
	out := session_output(from)
	if len(out) > 0 {
		append(&way.line, Sim_Held{round + latency, slice.clone(out)})
		way.queued += len(out)
		session_sent(from, len(out))
	}
}

// And comes off it, so many bytes a round, in order.
@(private)
sim_way_deliver :: proc(way: ^Sim_Way, to: ^Session, round, rate: int) {
	budget := rate
	for budget > 0 && len(way.line) > 0 && way.line[0].due <= round {
		h := &way.line[0]
		n := min(budget, len(h.bytes))
		_ = session_input(to, h.bytes[:n])
		budget -= n
		way.queued -= n
		if n == len(h.bytes) {
			delete(h.bytes)
			ordered_remove(&way.line, 0)
		} else {
			rest := slice.clone(h.bytes[n:])
			delete(h.bytes)
			h.bytes = rest
		}
	}
}

@(private)
sim_way_destroy :: proc(way: ^Sim_Way) {
	for h in way.line {
		delete(h.bytes)
	}
	delete(way.line)
}

// A full replica brought level over a slow way (8 KiB a round of 10 ms, 150 ms each way: 10 MB takes some 1,200 rounds): whether a window its client
// asks for meanwhile is answered soon, and when it holds everything.
@(private)
slow_way_run :: proc(t: ^testing.T, held: bool) -> (answered, whole: int) {
	state := seeded(112)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 0, ring = 256)
	defer sim_destroy(&s)
	big, fresh := s.nodes[0], s.nodes[1]
	list := List{1 << 32 | 5, 5}
	for i in 0 ..< 5000 {
		sim_put_big(&s, big, 5, u64(i), 2000)
	}
	sim_link(&s, 1, 0)
	l := s.links[0] // fresh dials: l.a is its, l.b the other's
	ui := sim_client(&s, fresh)
	defer session_close(ui)
	up, down: Sim_Way
	defer sim_way_destroy(&up)
	defer sim_way_destroy(&down)
	answered, whole = -1, -1
	for round in 0 ..< 20_000 {
		s.now += 10
		big.node.now = sim_now(&s, big)
		fresh.node.now = sim_now(&s, fresh)
		if !held {
			l.a.peer_took, l.b.peer_took = false, false // as with a peer that says nothing of what it took
		}
		sim_way_send(l.a, &up, round, 15)
		sim_way_send(l.b, &down, round, 15)
		sim_way_deliver(&up, l.b, round, 8192)
		sim_way_deliver(&down, l.a, round, 8192)
		if round == 300 {
			sim_watch(ui, 1, list_lo(list), list_hi(list), 50, {data = true, live = true, back = true})
		}
		for len(session_output(ui)) > 0 {
			session_sent(ui, len(session_output(ui)))
		}
		if answered < 0 && round > 300 && len(ui.watches) > 0 && ui.watches[0].settled {
			answered = round - 300
		}
		if whole < 0 && store_range(&fresh.node.store, list_lo(list), list_hi(list)).count == 5000 {
			whole = round
		}
		if whole >= 0 && answered >= 0 {
			break
		}
		free_all(context.temp_allocator)
	}
	return
}

// What is made for a peer is held to a window, so that a window asked for in the midst of bringing it level goes ahead
// of what was made before, within a few round trips, rather than after all that lay on the way; and so that it is
// brought level no later.
@(test)
held_to_a_window :: proc(t: ^testing.T) {
	answered, whole := slow_way_run(t, held = true)
	answered_unheld, whole_unheld := slow_way_run(t, held = false)
	testing.expectf(t, answered >= 0 && answered <= 150, "a window was answered %d rounds after it was asked for (%d without a window)", answered, answered_unheld)
	testing.expectf(t, answered_unheld > 600, "without a window, it was answered after %d rounds: the test does not test", answered_unheld)
	testing.expectf(t, whole >= 0 && f64(whole) <= 1.05 * f64(whole_unheld), "brought level in %d rounds, %d without a window", whole, whole_unheld)
}

// Both ends count the same bytes: a sender, once all is said, is said to have had all it made taken; and one whose
// peer says nothing of what it took holds nothing back, and is sent no Took.
@(test)
took_counts_alike :: proc(t: ^testing.T) {
	state := seeded(110)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 1, relays = 1, ring = 256)
	defer sim_destroy(&s)
	for i in 0 ..< 300 {
		sim_put_big(&s, s.nodes[0], 5, u64(i), 300)
	}
	sim_link(&s, 0, 3)
	sim_link(&s, 1, 3)
	sim_link(&s, 2, 3)
	for _ in 0 ..< 4 {
		sim_settle(&s)
	}
	for l in s.links {
		testing.expect(t, window_held(l.a) && window_held(l.b))
		testing.expect_value(t, l.a.acked, window_made(l.a))
		testing.expect_value(t, l.b.acked, window_made(l.b))
	}
	// One that says nothing of what it took.
	l := s.links[0]
	l.b.peer_took = false
	l.b.window.size = WINDOW_MIN
	l.b.acked = 0
	testing.expect(t, window_open(l.b))
	before := l.b.took_out
	_ = session_input(l.b, {})
	sim_put(&s, s.nodes[0], 9999)
	sim_settle(&s)
	testing.expect_value(t, l.b.took_out, before)
}

// A relay does not sleep owing a peer word of what it took, which it holds what it sends to a window by; and woken, it
// goes on saying what it takes to a peer that says what it took.
@(test)
sleeps_having_said_what_it_took :: proc(t: ^testing.T) {
	state := seeded(113)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	l := s.links[0]
	at := l.b // the relay's end
	saved := make([dynamic]byte, context.temp_allocator)
	testing.expect(t, session_save(at, &saved))
	// Something comes, which asks for nothing back, and is taken in, but not yet said to have been.
	f: [dynamic]byte
	defer delete(f)
	frame := frame_begin(&f, .Unwatch)
	write_varint(&f, 12345)
	frame_end(&f, frame)
	testing.expect(t, session_input(at, f[:]))
	clear(&saved)
	testing.expect(t, !session_save(at, &saved), "a relay would sleep owing word of what it took")
	exchange :: proc(t: ^testing.T, from, to: ^Session) {
		out := session_output(from)
		testing.expect(t, session_input(to, out))
		session_sent(from, len(out))
	}
	exchange(t, at, l.a) // it says so
	clear(&saved)
	testing.expect(t, session_save(at, &saved))
	// Cells come, are kept, and are acknowledged: and until the peer says that has come, it does not sleep.
	sim_put(&s, s.nodes[0], 2)
	exchange(t, l.a, at)
	testing.expect(t, node_sync(&s.nodes[1].node))
	said := slice.clone(session_output(at), context.temp_allocator)
	session_sent(at, len(said))
	clear(&saved)
	testing.expect(t, !session_save(at, &saved), "a relay would sleep with what it sent not yet said to have come")
	testing.expect(t, session_input(l.a, said))
	exchange(t, l.a, at)
	exchange(t, at, l.a)
	clear(&saved)
	testing.expect(t, session_save(at, &saved))
	sim_cut(&s, 0)
	revived, ok := session_load(&s.nodes[1].node, saved[:])
	testing.expect(t, ok)
	if ok {
		testing.expect(t, revived.peer_took)
		session_close(revived)
	}
	free_all(context.temp_allocator)
}

// What is not a frame, before anything is agreed, fails the session, and does nothing more: it is not walked as frames
// to see what of it is of Took frames, by lengths that would lead backwards, or nowhere.
@(test)
nonsense_is_not_walked :: proc(t: ^testing.T) {
	state := seeded(114)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	for bytes in ([][]byte{
		{0x80, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x00}, // a length of 2^64 - 256
		{0xf6, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x00}, // of 2^64 - 10
		{0xfb, 0xff, 0xff, 0xff, 0x0f, 0x00}, // of 2^32 - 5
		{0x00, 0x12, 0x01, 0x00},
	}) {
		x := session_open(&s.nodes[1].node, .Peer, false)
		_ = session_input(x, bytes)
		testing.expect(t, x.closing)
		session_close(x)
	}
}

// One whose peer says nothing of what it took sleeps as ever: it owes no word of what it took, which it does not say.
@(test)
sleeps_beside_a_peer_that_says_nothing_of_it :: proc(t: ^testing.T) {
	state := seeded(115)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 1, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	sim_link(&s, 0, 1)
	sim_settle(&s)
	l := s.links[0]
	l.a.peer_took, l.b.peer_took = false, false
	sim_put(&s, s.nodes[0], 1)
	sim_settle(&s)
	saved := make([dynamic]byte, context.temp_allocator)
	testing.expect(t, session_save(l.b, &saved), "a relay would not sleep beside a peer that says nothing of what it took")
	free_all(context.temp_allocator)
}

// A watch compared afresh is compared where a Fill for another watch is still to come: that says nothing of this one,
// nor is what says this one is level queued after it.
@(test)
another_watchs_fill_says_nothing :: proc(t: ^testing.T) {
	state := seeded(116)
	context.random_generator = rand.default_random_generator(&state)
	s: Sim
	sim_init(t, &s, full = 2, partial = 0, relays = 1, ring = 256)
	defer sim_destroy(&s)
	for i in 0 ..< 100 {
		sim_put(&s, s.nodes[0], u64(i))
	}
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	at: ^Session
	for l in s.links {
		if l.an == 1 {
			at = l.b
		}
	}
	w := &at.watches[0]
	queue(at, false, {kind = .Fill, watch = w.id + 12345, lo = w.lo, hi = w.hi})
	before := len(at.out)
	recon_unfilled(at, w)
	testing.expect(t, len(at.out) > before, "a Fill for another watch was taken to say this one would be level")
	clear(&at.tasks)
	at.task_head = 0
	free_all(context.temp_allocator)
}

@(private)
clear_used :: proc(n: ^Node) {
	keys := make([dynamic]Key, context.temp_allocator)
	scan := tree_scan(n, n.used, KEY_MIN, KEY_MAX)
	for leaf in tree_next(&scan) {
		append(&keys, leaf.key)
	}
	for k in keys {
		tree_delete(n, &n.used, k)
	}
}

// Forgets what is in the outbox, as a store kept before full replicas kept one would never have had it.
@(private)
clear_map_outbox :: proc(n: ^Node) {
	keys := make([dynamic]Key, context.temp_allocator)
	scan := tree_scan(n, n.outbox, KEY_MIN, KEY_MAX)
	for leaf in tree_next(&scan) {
		append(&keys, leaf.key)
	}
	for k in keys {
		tree_delete(n, &n.outbox, k)
	}
}

// Stops a device cleanly, its store checkpointed, and starts it again, as a full replica or a partial one; and, if
// `older`, as though its store had been kept by a node that knew nothing of the tail of its header.
@(private)
sim_restart :: proc(s: ^Sim, x: ^Sim_Node, full: bool, older := false) {
	i := 0
	for y, j in s.nodes {
		if y == x {
			i = j
		}
	}
	#reverse for l, j in s.links {
		if l.an == i || l.bn == i {
			sim_cut(s, j)
		}
	}
	testing.expect(s.t, store_sync(&x.node.store) && store_checkpoint(&x.node.store))
	node_destroy(&x.node)
	x.ui = nil
	if older {
		for no in Page_No(0) ..< HEADER_PAGES {
			if pg := x.disk.pages[no]; pg != nil {
				tail := ([^]byte)(rawptr(uintptr(pg) + size_of(Header)))[:size_of(Header_Tail)]
				slice.zero(tail)
			}
		}
	}
	keyring_destroy(&x.keys)
	keyring_init(&x.keys, x.secret)
	if x.kept != nil {
		testing.expect(s.t, keyring_load(&x.keys, x.kept))
	}
	x.full = full
	sim_boot(s, x)
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
