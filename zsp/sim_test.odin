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
	relayed: [dynamic]Sim_Relayed, // sessions for calls, carried through a relay
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
	if x.roster != nil {
		assert(node_resume(&x.node, x.roster_old, x.roster) && !x.node.failed)
	} else if !x.relay {
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
sim_worlds :: proc(t: ^testing.T, lazy: Sim_Storage) {
	SEEDS :: #config(ZSP_SEEDS, 6)
	FIRST :: #config(ZSP_FIRST_SEED, 0)
	missed, writes, reads := 0, 0, 0
	defer testing.expectf(t, lazy == .Quick || (missed > 100 && writes > 10 && reads > 10), "the relays missed %d reads, wrote %d times and read %d times", missed, writes, reads)
	for seed in FIRST ..< FIRST + SEEDS {
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
// was checkpointed; and the other way about. One whose store does not say that its outbox is whole, as one kept before
// every replica kept one, goes on as a full replica until it is level with another, and is partial from then on.
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

	// A full replica writes while it reaches nobody, its store is checkpointed, and it starts again as a partial one.
	for i in 0 ..< 20 {
		sim_put(&s, laptop, u64(i))
	}
	sim_restart(&s, laptop, full = false)
	testing.expect(t, !laptop.node.full)
	sim_link(&s, 0, 2)
	sim_link(&s, 1, 2)
	sim_settle(&s)
	testing.expect_value(t, count(big), 20)
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
