package zsp

import "base:runtime"
import "core:crypto"
import "core:slice"

// A node is a store, perhaps a keyring, and the sessions that feed on them. A node without a
// keyring is a relay: it merges, pages and forwards exactly like any other node, and can read nothing.
//
// The host owns all I/O. It feeds bytes to `session_input`, takes bytes from `session_output`
// whenever the pipe can accept some, and calls `node_sync` when a deadline it chose passes.

Node :: struct {
	using store: Store,
	keys:        ^Keyring,
	roster:      Roster,
	space:       Key32,
	full:        bool, // replicate everything, rather than what local clients watch
	now:         u64, // milliseconds; the host advances this
	sessions:    [dynamic]^Session,
	interests:   [dynamic]Interest,
	next_id:     u32,
	next_watch:  u64,
	calls:       [dynamic]Call,
	serving:     [dynamic]Serving,
	tunnels:     [dynamic]Tunnel,
	next_call:   u64,
	next_tunnel: u32,
	recent:      [64]u64, // salts of live frames lately passed on
	recent_at:   int,
	host:        Host,
}

// Everything this package leaves to whoever embeds it. Any field may be nil.
Host :: struct {
	data:         rawptr,
	random:       proc(data: rawptr, into: []byte), // defaults to the operating system
	// Decides whether a connection may be served at all: accounts, tokens, quotas, billing. The peer
	// has already proven it holds `s.peer`; the credential is whatever it chose to present. Answer with
	// session_accept or session_refuse, now or whenever the answer is known; until then the session's
	// input waits. When nil, peers are judged by the roster alone and open sessions are refused.
	authenticate: proc(data: rawptr, s: ^Session, credential: []byte),
	roster:       proc(data: rawptr, bytes: []byte), // a newer roster was adopted: persist it
	signal:       proc(data: rawptr, from: Key32, blob: []byte), // from another member, via a relay
	presence:     proc(data: rawptr, online: []Key32),
}

// Interest ids never meet the ids of root watches.
@(private)
INTEREST :: u64(1) << 62

// A range some session watches that this node asks others about in turn.
Interest :: struct {
	id:      u64,
	session: u32,
	watch:   Watch,
	limit:   u64,
	back:    bool,
	waiting: int, // upstreams yet to settle
	reports: [dynamic]Report, // what full replicas last said of it
}

@(private)
Report :: struct {
	session: u32,
	lo, hi:  Key,
	before, after: int,
}

node_init :: proc(n: ^Node, disk: Disk, space: Key32, keys: ^Keyring, full: bool, ring := 256) -> bool {
	n.space = space
	n.keys = keys
	n.full = full
	n.next_id = 1
	n.partial = !full
	return store_open(&n.store, disk, ring)
}

node_destroy :: proc(n: ^Node) {
	for len(n.sessions) > 0 {
		session_close(n.sessions[0])
	}
	rpc_destroy(n)
	for it in n.interests {
		delete(it.reports)
	}
	delete(n.sessions)
	delete(n.interests)
	roster_destroy(&n.roster)
	store_close(&n.store)
	n^ = {}
}

// Adopts a roster if it is genuine and newer. Sessions it no longer allows end; if this device is the
// one it no longer allows, its keys go and its clients are told. (What it already holds is the host's to
// keep or wipe.)
node_adopt :: proc(n: ^Node, bytes: []byte) -> bool {
	r := roster_parse(bytes, n.space) or_return
	if r.serial <= n.roster.serial {
		roster_destroy(&r)
		return false
	}
	old_keys: Keyring
	if n.keys != nil {
		old_keys.scopes = n.keys.scopes
		n.keys.scopes = {}
		if !roster_unwrap(n.keys, &r) {
			keyring_clear(n.keys)
			n.keys.root = nil
		}
	}
	old := n.roster
	n.roster = r
	swept := roster_sweep(n, &old, &old_keys)
	roster_destroy(&old)
	keyring_destroy(&old_keys)
	if swept && !store_checkpoint(&n.store) {
		return false // or a crash could bring back, under this roster, what it made unlawful
	}
	if n.host.roster != nil {
		n.host.roster(n.host.data, n.roster.bytes)
	}
	for s in n.sessions {
		if s.greeted && s.accepted {
			send_roster(s) // and to one whose own, older, is still on its way
		}
		if !s.ready {
			continue
		}
		session_authorize(s)
		if swept {
			session_recompare(s)
		}
	}
	rpc_roster_changed(n)
	reach_tell(n)
	return true
}

// Whether the roster allows this device anything at all.
@(require_results)
node_member :: proc(n: ^Node) -> bool {
	m := roster_member(&n.roster, n.keys.device) if n.keys != nil else nil
	return m != nil && member_active(m)
}

// A roster can make unlawful what was accepted before it was heard: cells later than the end of the key
// or the right they were written by. One sealed under an old key by someone who merely had not heard is
// sealed again, under the new key, its identity unchanged, by every device that can; what cannot be is
// dropped. Either way all replicas come to hold the same.
@(private)
roster_sweep :: proc(n: ^Node, old: ^Roster, old_keys: ^Keyring) -> (swept: bool) {
	for info in n.roster.scopes {
		was := roster_scope(old, info.id)
		if was == nil {
			continue
		}
		from := max(u64)
		if .Signed not_in info.flags && info.epoch > was.epoch {
			from = info.closed[was.epoch - 1]
		}
		if .Signed in info.flags {
			for m in n.roster.members {
				before := roster_member(old, m.device)
				for g, i in m.grants {
					if g.scope == info.id && .Write in g.rights && g.until != 0 && (before == nil || i >= len(before.grants) || before.grants[i].until == 0) {
						from = min(from, g.until)
					}
				}
			}
		}
		if from == max(u64) {
			continue
		}
		swept = true
		late := make([dynamic]Leaf, context.temp_allocator)
		scan := tree_scan(n, n.cells, scope_lo(info.id), scope_hi(info.id))
		for leaf in tree_next(&scan) {
			if leaf.key[3] > from {
				append(&late, leaf)
			}
		}
		for leaf in late {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			c, at := cell_unkey(leaf)
			c.body = log_bytes(&n.store, at.off, at.len)
			if c.body == nil || cell_authentic(&n.roster, &c) {
				continue
			}
			c.body = slice.clone(c.body, context.temp_allocator)
			again := c
			if n.keys != nil && .Signed not_in info.flags && cell_open(old_keys, &n.roster, &again) && cell_seal(n.keys, &n.roster, &again) {
				store_replace(&n.store, &again)
				// Someone who had heard already may have refused it, and will take it now.
				places := row_places(&n.store, c.row)
				ring_push(&n.events, {c.row, c.slot, c.kind, c.stamp, 0}, &places, &places)
				if n.partial {
					tree_put(n, &n.outbox, {c.row[0], c.row[1], 0, 0, 0}, {})
				}
			} else {
				forget(&n.store, leaf)
			}
		}
	}
	return
}

@(private)
node_random :: proc(n: ^Node, into: []byte) {
	if n.host.random != nil {
		n.host.random(n.host.data, into)
	} else {
		crypto.rand_bytes(into)
	}
}

// A stamp greater than any this node has seen. Every cell gets its own.
@(require_results)
node_stamp :: proc(n: ^Node) -> (s: Stamp) {
	salt: [8]byte
	node_random(n, salt[:])
	n.clock = max(n.clock + 1, n.now << 16)
	return {n.clock, get_u64(salt[:])}
}

@(require_results)
node_id :: proc(n: ^Node, scope: Scope) -> Id {
	b: [8]byte
	node_random(n, b[:])
	return {u64(scope) << 32 | u64(u32(n.now / 1000)), get_u64(b[:])}
}

// Writes open cells on behalf of this node itself. False, and nothing written, if it may not.
node_write :: proc(n: ^Node, cells: []Cell) -> bool {
	for &c in cells {
		if len(c.body) > MAX_OPEN || !cell_valid(&c) || !node_may_write(n, row_scope(c.row)) || !cell_seal(n.keys, &n.roster, &c) {
			return false
		}
	}
	if record_size(cells) > MAX_RECORD {
		return false
	}
	node_commit(n, cells, nil)
	return true
}

@(require_results)
node_may_write :: proc(n: ^Node, scope: Scope) -> bool {
	if n.keys == nil {
		return false
	}
	m := roster_member(&n.roster, n.keys.device)
	return m != nil && .Write in member_rights(m, scope)
}

@(private)
node_commit :: proc(n: ^Node, cells: []Cell, from: ^Session) -> int {
	accepted := store_commit(&n.store, cells, from.id if from != nil else 0)
	if accepted > 0 && !n.full && (from == nil || from.role == .Open) {
		for c in cells {
			tree_put(n, &n.outbox, {c.row[0], c.row[1], 0, 0, 0}, {})
		}
	}
	return accepted
}

// Makes commits durable and releases the acknowledgements that were waiting for it.
node_sync :: proc(n: ^Node) -> bool {
	if !store_sync(&n.store) || n.failed {
		return false
	}
	if store_wants_checkpoint(&n.store) {
		return store_checkpoint(&n.store)
	}
	return true
}

@(private)
node_session :: proc(n: ^Node, id: u32) -> ^Session {
	for s in n.sessions {
		if s.id == id {
			return s
		}
	}
	return nil
}

@(private)
node_wants :: proc(n: ^Node, key: Key) -> bool {
	if n.full {
		return true
	}
	for &i in n.interests {
		if i.watch.data && range_has(&i.watch, key) {
			return true
		}
	}
	return false
}

// Whether a watch that arrived on `from` concerns `to` as well.
@(private)
interest_concerns :: proc(n: ^Node, from: u32, to: ^Session) -> bool {
	return to.ready && to.role == .Peer && to.id != from
}

@(private)
interest_add :: proc(s: ^Session, w: Watch, limit: u64, back: bool) -> ^Interest {
	n := s.node
	w := w
	w.data = w.data && !n.full
	if !w.data && !w.live {
		return nil
	}
	n.next_watch += 1
	append(&n.interests, Interest{id = INTEREST | n.next_watch, session = s.id, watch = w, limit = limit, back = back})
	it := &n.interests[len(n.interests) - 1]
	for to in n.sessions {
		if interest_concerns(n, s.id, to) {
			interest_send(to, it)
		}
	}
	return it
}

@(private)
interest_remove :: proc(n: ^Node, i: int) {
	it := n.interests[i]
	delete(it.reports)
	unordered_remove(&n.interests, i)
	for to in n.sessions {
		if interest_concerns(n, it.session, to) {
			send_unwatch(to, it.id)
		}
	}
}

// Announces an interest. Data comes from full peers; live frames come from anyone.
@(private)
interest_send :: proc(to: ^Session, it: ^Interest) {
	data := it.watch.data && to.peer_full
	if .Read not_in session_rights(to, key_scope(it.watch.lo)) {
		return
	}
	if !data && !it.watch.live {
		return
	}
	if data && !slice.contains(to.owed[:], it.id) {
		it.waiting += 1
		append(&to.owed, it.id)
	}
	send_watch(to, it.id, it.watch.lo, it.watch.hi, {live = it.watch.live, data = data, back = it.back, counts = data && it.watch.counts}, it.limit)
}

// Rows awaiting their first full replica go out again on every new connection to one.
@(private)
outbox_send :: proc(s: ^Session) {
	scan := tree_scan(s.node, s.node.outbox, KEY_MIN, KEY_MAX)
	for leaf in tree_next(&scan) {
		append(&s.tasks, Task{kind = .Row, row = {leaf.key[0], leaf.key[1]}})
	}
}

// A beacon for the local network: which device this is and on which port, sealed under a key only
// those who know the space can derive. Temporary memory.
@(require_results)
beacon_seal :: proc(n: ^Node, port: int) -> []byte {
	if n.keys == nil {
		return nil
	}
	stamp := Stamp{}
	salt: [8]byte
	node_random(n, salt[:])
	stamp.salt = get_u64(salt[:])
	iv := aead_nonce(stamp, 0, LIVE_KIND + 2)
	plain: [34]byte
	copy(plain[:], n.keys.device[:])
	plain[32], plain[33] = byte(port >> 8), byte(port)
	w := make([dynamic]byte, context.temp_allocator)
	append(&w, 0x44)
	append(&w, ..salt[:])
	aead_append(&w, derive(n.space, "zsp-beacon"), &iv, nil, plain[:])
	return w[:]
}

@(require_results)
beacon_open :: proc(n: ^Node, packet: []byte) -> (device: Key32, port: int, ok: bool) {
	if len(packet) != 9 + 34 + TAG || packet[0] != 0x44 {
		return
	}
	iv := aead_nonce({0, get_u64(packet[1:])}, 0, LIVE_KIND + 2)
	w := make([dynamic]byte, context.temp_allocator)
	aead_open(&w, derive(n.space, "zsp-beacon"), &iv, nil, packet[9:]) or_return
	copy(device[:], w[:32])
	return device, int(w[32]) << 8 | int(w[33]), true
}
