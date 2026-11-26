package zsp

import "base:runtime"
import "core:slice"
import "core:strings"

VERSION :: 1
OUT_HIGH :: 64 << 10 // stop producing bulk when this much is waiting
OUT_LIVE :: 16 << 10 // drop live frames when this much is waiting
CELLS_FRAME :: 16 << 10 // close a cells frame past this
RECON_FRAME :: 128 << 10 // say no more than this at once; the rest is said next time
WANT_FRAME :: 64 << 10
WANT_HELD :: 2048 // do not list more of a row than this: have it sent whole
MAX_LIVE :: 64 << 10
MAX_LIVE_OPEN :: MAX_LIVE - 128 // before it is sealed
LIVE_LATE :: 60 << 26 // a minute of stamp time: 60 * 1024 ms * 2^16
LIST_MAX :: 32 // reconcile ranges this small by listing them
FANOUT :: 16
MAX_REFUSED :: 4096
MAX_STALLED :: 4 * MAX_FRAME // input held while storage fetches what a frame needs

Role :: enum u8 {
	Peer, // sealed cells over an authenticated channel
	Open, // plain cells over a trusted pipe
}

Fault :: enum u8 {
	None      = 0,
	Malformed = 1,
	Denied    = 2,
	Version   = 3,
	Failed    = 4,
	Clock     = 5, // one end's clock is wrong by more than can be allowed for
}

Session :: struct {
	node:      ^Node,
	id:        u32,
	role:      Role,
	initiator: bool,
	peer:      Key32,
	relay:     bool, // dialled as a relay, at a key known to be one's
	peer_full: bool,
	peer_relay: bool, // and says it is
	peer_serial: u64, // known to be held by them, or on its way to them
	promised:  u64, // what their hello said they held
	credential: []byte, // owned; presented in our hello
	grants:    [dynamic]Grant, // what the peer may do; scope zero stands for every scope
	greeted:   bool, // their hello arrived
	accepted:  bool, // the host vouches for the connection
	ready:     bool, // and the roster for the peer
	fault:     Fault, // ours with them, or theirs with us
	closing:   bool, // send what is queued, then close
	roots:     [dynamic]Scope, // scopes this end watches whole
	roots_gen: u64,
	roots_due: int, // how many of them are yet to be brought level
	settled:   bool, // none
	told:      bool, // and the responder has been told that all of it was sent
	hushed:    u64, // roster serial under which it was paused
	paused:    bool, // everyone who could write is reachable without this session

	input:     [dynamic]byte, // an incomplete frame, or frames awaiting the host's verdict
	busy:      bool, // within session_input
	stalled:   bool, // a frame in input read what storage did not yet have: see lazy.odin
	recompare: bool, // session_recompare is owed, where storage may answer "not yet"
	counts_due: bool, // changes have been sent since what lies beyond its windows was last counted
	out:       [dynamic]byte,
	sent:      int,
	tasks:     [dynamic]Task, // bulk work, done as the pipe drains
	task_head: int,
	cells:     Cells_Frame,
	cursor:    u64, // into the event ring
	whole:     Id, // a row lately sent whole, covering its events before whole_to
	whole_to:  u64,
	watches:   [dynamic]Watch, // theirs on us
	seq_out:   u64,
	seq_in:    u64,
	ack_at:    u64, // log position that makes seq_in durable
	acked_in:  u64,
	refused:   [dynamic]Id, // rows something of which was not taken since
	unacked:   [dynamic]Unacked,
	owed:      [dynamic]u64, // interests this peer has yet to say are level
	online:    [dynamic]Key32, // latest presence
	as:        string, // owned; whom the host says a local client is for
	authors:   map[Author]u32, // that it has been told of, by the numbers it knows them by
	next_author: u32,
	wants_authors: bool,
	// Where live frames go when the pipe has a faster, lossier way to carry them.
	datagram_data: rawptr,
	datagram:  proc(data: rawptr, frame: []byte) -> bool,
}

Watch :: struct {
	id:     u64,
	lo, hi: Key,
	data:   bool,
	live:   bool,
	level:  bool, // the watcher is known to hold all that lies within
	counts: bool, // and is told whenever what lies beyond changes
	settled: bool,
	before, after: int, // as last told
	far:    bool, // what lies beyond is known from a full replica:
	far_before, far_after: int,
}

Watch_Flags :: bit_field u8 {
	data:   bool | 1, // send cells
	live:   bool | 1, // send live frames
	back:   bool | 1, // the limit counts from the upper end
	adopt:  bool | 1, // the watcher is already current
	known:  bool | 1, // a count and fingerprint follow
	counts: bool | 1, // say again when what lies beyond changes
	_:      u8   | 2,
}

Synced_Flags :: bit_field u8 {
	settled: bool | 1, // a full replica has confirmed this, or none is reachable
	restart: bool | 1, // not an end but a beginning: the range is about to be sent afresh
	denied:  bool | 1, // the watcher may not read this
	_:       u8   | 5,
}

Hello_Flags :: bit_field u8 {
	full:  bool | 1,
	relay: bool | 1,
	authors: bool | 1, // a local client's, which wants to be told who wrote what
	_:     u8   | 5,
}

Task :: struct {
	kind:   enum u8 {
		Row, // every cell of a row
		Cell, // one cell
		Fill, // every row in a range
		Synced,
	},
	settled: bool,
	restart: bool,
	denied:  bool,
	row:     Id,
	watch:   u64,
	lo, hi:  Key,
	before, after: int,
}

Unacked :: struct {
	seq: u64,
	row: Id,
}

@(private)
Cells_Frame :: struct {
	start: int, // zero when no frame is open
	row:   Id,
}

// `peer` is the key the channel proved, and nothing for open sessions. `credential` is for the other
// end's host to judge. `relay` says the key dialled is known to be a relay's: no peer can say so itself.
session_open :: proc(n: ^Node, role: Role, initiator: bool, peer: Key32 = {}, credential: []byte = nil, relay := false) -> ^Session {
	s := new(Session)
	s.node = n
	s.id = n.next_id
	n.next_id += 1
	s.role = role
	s.initiator = initiator
	s.peer = peer
	s.relay = relay
	s.credential = slice.clone(credential)
	s.cursor = n.events.next
	append(&n.sessions, s)
	send_hello(s)
	return s
}

// The host vouches for a connection. Open sessions get exactly these grants; a peer's come from the
// roster, and these are not consulted.
session_accept :: proc(s: ^Session, grants: []Grant = nil, as: string = "") {
	if s.accepted || s.closing {
		return
	}
	if len(as) > MAX_AS {
		session_refuse(s)
		return
	}
	s.accepted = true
	if s.role == .Open {
		append(&s.grants, ..grants)
		s.as = strings.clone(as)
	}
	session_settle_membership(s)
	if !s.busy {
		session_input(s, nil) // whatever waited for the verdict
	}
}

session_refuse :: proc(s: ^Session) {
	session_fail(s, .Denied)
}

// What the peer may do in a scope.
@(require_results)
session_rights :: proc(s: ^Session, scope: Scope) -> Rights {
	return grants_rights(s.grants[:], scope)
}

@(private)
grants_rights :: proc(grants: []Grant, scope: Scope) -> Rights {
	for g in grants {
		if (g.scope == scope || g.scope == 0) && g.until == 0 {
			return g.rights
		}
	}
	return {}
}

// The host's name for whoever is at the other end, as the roster records it.
@(require_results)
session_subject :: proc(s: ^Session) -> []byte {
	m := roster_member(&s.node.roster, s.peer)
	return m.subject if m != nil else nil
}

session_close :: proc(s: ^Session) {
	n := s.node
	for x, i in n.sessions {
		if x == s {
			unordered_remove(&n.sessions, i)
			break
		}
	}
	#reverse for it, i in n.interests {
		if it.session == s.id {
			interest_remove(n, i)
		}
	}
	rpc_session_closed(n, s)
	if q := &n.host.questions; s.role == .Open && q.ended != nil {
		q.ended(q.data, s)
	}
	delete(s.credential)
	delete(s.grants)
	delete(s.roots)
	delete(s.input)
	delete(s.out)
	delete(s.tasks)
	delete(s.watches)
	delete(s.unacked)
	delete(s.refused)
	for &it in n.interests {
		for r, i in it.reports {
			if r.session != s.id {
				continue
			}
			unordered_remove(&it.reports, i)
			// The last to be heard stands, though it is gone: nobody knows better.
			if to := node_session(n, it.session); to != nil && len(it.reports) > 0 {
				for &w in to.watches {
					if w.id == it.watch.id && w.data {
						interest_beyond(n, &it, &w)
					}
				}
			}
			break
		}
	}
	for id in s.owed {
		interest_settled(n, id) // it never will: what is here is all that can be had
	}
	delete(s.owed)
	delete(s.online)
	delete(s.as)
	authors_clear(s)
	delete(s.authors)
	ready := s.ready
	free(s)
	if ready && n.keys == nil {
		presence_send(n)
	}
	// The others may now have to say what this one was saying.
	node_balance(n)
	reach_tell(n)
}

@(private)
session_fail :: proc(s: ^Session, f: Fault) {
	if s.fault != .None {
		return
	}
	s.fault = f
	s.closing = true
	s.ready = false
	cells_close(s)
	at := frame_begin(&s.out, .Error)
	write_u8(&s.out, u8(f))
	frame_end(&s.out, at)
}

// Feeds bytes from the pipe, in any fragmentation. False means close the pipe.
session_input :: proc(s: ^Session, bytes: []byte) -> bool {
	if s.closing {
		return false
	}
	s.busy = true
	defer s.busy = false
	bytes := bytes
	if len(s.input) > 0 {
		append(&s.input, ..bytes)
		bytes = s.input[:]
	}
	used := 0
	stalled := false
	for !s.closing && (s.accepted || !s.greeted) {
		r := Reader{buf = bytes[used:]}
		n := read_varint(&r)
		if r.bad {
			if len(bytes) - used >= 10 {
				session_fail(s, .Malformed)
			}
			break
		}
		if n == 0 || n > MAX_FRAME {
			session_fail(s, .Malformed)
			break
		}
		if int(n) > len(r.buf) - r.pos {
			break
		}
		frame := r.buf[r.pos:][:n]
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if !frame_step(s, frame) {
			stalled = true // and again when what it read has come
			break
		}
		used += r.pos + int(n)
	}
	s.stalled = stalled
	rest := bytes[used:]
	if len(rest) > (MAX_STALLED if stalled else MAX_FRAME + 16) {
		session_fail(s, .Failed if stalled else .Malformed)
	}
	if len(s.input) > 0 {
		copy(s.input[:], rest)
		resize(&s.input, len(rest))
	} else {
		append(&s.input, ..rest)
	}
	if len(s.input) == 0 && cap(s.input) > 4096 {
		shrink(&s.input)
	}
	return !s.closing
}

// Bytes ready for the pipe. Producing them is when work happens: an idle or blocked pipe costs nothing.
@(require_results)
session_output :: proc(s: ^Session) -> []byte {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	if s.ready && !s.closing {
		pump(s)
	}
	return s.out[s.sent:]
}

session_sent :: proc(s: ^Session, n: int) {
	s.sent += n
	if s.sent == len(s.out) {
		s.sent = 0
		clear(&s.out)
		if cap(s.out) > 4096 {
			shrink(&s.out)
		}
	} else if s.sent > OUT_HIGH {
		resize(&s.out, copy(s.out[:], s.out[s.sent:]))
		s.sent = 0
	}
}

@(private)
session_frame :: proc(s: ^Session, frame: []byte) -> Fault {
	n := s.node
	r := Reader{buf = frame[1:]}
	type := Message(frame[0])
	if !s.greeted && type != .Hello {
		return .Malformed
	}
	if !s.ready && type != .Hello && type != .Roster {
		// Nothing is accepted before both sides agree on membership; a peer that is merely early
		// is told by the roster already on its way.
		return .Denied
	}
	#partial switch type {
	case .Hello:
		return on_hello(s, &r)
	case .Roster:
		return on_roster(s, &r)
	case .Watch:
		on_watch(s, &r)
	case .Unwatch:
		// What was committed while the watch stood is owed to it.
		if !flush_changes(s) {
			return .None // to be done again, when what it needs has come
		}
		on_unwatch(s, read_varint(&r))
	case .Recon:
		on_recon(s, &r)
	case .Want:
		on_want(s, &r)
	case .Cells:
		on_cells(s, &r)
	case .Ack:
		on_ack(s, &r)
	case .Live:
		on_live(s, &r)
	case .Synced:
		on_synced(s, &r)
	case .Signal:
		on_signal(s, &r)
	case .Presence:
		on_presence(s, &r)
	case .Error:
		s.closing = true
		if code := read_u8(&r); s.fault == .None && code <= u8(max(Fault)) {
			s.fault = Fault(code)
		}
	case .Serve:
		on_serve(s, &r)
	case .Call:
		on_call(s, &r)
	case .Flow:
		on_flow(s, &r)
	case:
		if q := &n.host.questions; frame[0] >= QUESTION && s.role == .Open && q.asked != nil {
			return .None if q.asked(q.data, s, frame[0], frame[1:]) else .Malformed
		}
		return .None // unknown messages are for a later version
	}
	return .Malformed if r.bad else .None
}

// ---------------------------------------------------------------- greeting

@(private)
send_hello :: proc(s: ^Session) {
	n := s.node
	at := frame_begin(&s.out, .Hello)
	write_u8(&s.out, VERSION)
	write_u8(&s.out, u8(Hello_Flags{full = n.full, relay = n.keys == nil}))
	append(&s.out, ..n.space[:])
	write_varint(&s.out, n.roster.serial)
	write_bytes(&s.out, s.credential)
	frame_end(&s.out, at)
}

@(private)
on_hello :: proc(s: ^Session, r: ^Reader) -> Fault {
	n := s.node
	if s.greeted {
		return .Malformed
	}
	if read_u8(r) != VERSION {
		return .Version
	}
	flags := Hello_Flags(read_u8(r))
	s.wants_authors = flags.authors && s.role == .Open
	space := read_key32(r)
	s.promised = read_varint(r)
	s.peer_serial = min(s.promised, n.roster.serial)
	credential := read_bytes(r)
	if r.bad {
		return .Malformed
	}
	s.greeted = true
	if s.role == .Peer && space != n.space {
		return .Denied
	}
	s.peer_full = flags.full
	s.peer_relay = s.relay && flags.relay
	if s.relay != s.peer_relay {
		return .Denied
	}
	switch {
	case s.initiator && s.role == .Peer:
		session_accept(s) // the dialler chose whom to dial
	case n.host.authenticate != nil:
		n.host.authenticate(n.host.data, s, credential)
	case s.role == .Peer:
		session_accept(s)
	case:
		return .Denied
	}
	return .None
}

// Both ends must agree on the roster before either counts on it.
@(private)
session_settle_membership :: proc(s: ^Session) {
	n := s.node
	if s.role == .Open {
		if n.keys == nil {
			session_fail(s, .Denied)
			return
		}
		session_authorize(s)
		return
	}
	send_roster(s)
	if s.promised <= n.roster.serial {
		session_authorize(s)
	} // else a newer roster is on its way, and decides
}

// Peers get the roster; open sessions get what it means for them.
@(private)
send_roster :: proc(s: ^Session) {
	n := s.node
	if s.role == .Open {
		return
	}
	if s.peer_serial >= n.roster.serial {
		return
	}
	s.peer_serial = n.roster.serial
	cells_close(s)
	at := frame_begin(&s.out, .Roster)
	append(&s.out, ..n.roster.bytes)
	frame_end(&s.out, at)
}

SAYS_WHOSE :: 0x80 // with the rights in a scope: what is written there says who wrote it

@(private)
send_scopes :: proc(s: ^Session) {
	n := s.node
	cells_close(s)
	at := frame_begin(&s.out, .Roster)
	write_u64(&s.out, n.clock)
	for &k in n.keys.scopes {
		rights := session_rights(s, k.scope) & device_rights(n, n.keys.device, k.scope)
		if rights == {} {
			continue
		}
		write_varint(&s.out, u64(k.scope))
		signed := .Signed in roster_scope(&n.roster, k.scope).flags
		write_u8(&s.out, transmute(u8)rights | (SAYS_WHOSE if signed else 0))
		append(&s.out, ..k.list_key[:])
	}
	frame_end(&s.out, at)
}

@(private)
on_roster :: proc(s: ^Session, r: ^Reader) -> Fault {
	n := s.node
	bytes := r.buf[r.pos:]
	if s.role == .Open {
		// The signature is all the authority a roster needs, whoever brings it.
		node_adopt(n, bytes)
		return .None
	}
	serial, ok := roster_claims(bytes, n.space)
	if !ok {
		return .Malformed
	}
	if !s.ready && serial < s.promised {
		return .Malformed // it said it had a later one
	}
	if serial > n.roster.serial {
		roster, sound := roster_parse(bytes, n.space, &n.roster)
		if !sound {
			return .Malformed
		}
		s.peer_serial = max(s.peer_serial, serial)
		node_take(n, roster)
	}
	if n.keys != nil && !node_member(n) {
		return .Denied // a device that does not belong has no peers
	}
	send_roster(s)
	if !s.ready {
		session_authorize(s)
	}
	return .None
}

// Derives what the peer may do, now and whenever the roster changes.
@(private)
session_authorize :: proc(s: ^Session) {
	n := s.node
	before := slice.clone(s.grants[:], context.temp_allocator)
	if s.role == .Peer {
		clear(&s.grants)
		m := roster_member(&n.roster, s.peer)
		switch {
		case m != nil && member_active(m):
			append(&s.grants, ..m.grants)
		case m == nil && s.peer_relay:
			// Not a member: trusted only to be the relay whose key was dialled, and to carry.
			append(&s.grants, Grant{0, {.Read, .Write}, 0})
		case:
			session_fail(s, .Denied)
			return
		}
	}
	#reverse for w in s.watches {
		if .Read not_in session_rights(s, key_scope(w.lo)) || (s.role == .Open && keyring_scope(n.keys, key_scope(w.lo)) == nil) {
			append(&s.tasks, Task{kind = .Synced, watch = w.id, lo = w.lo, hi = w.hi, denied = true})
			on_unwatch(s, w.id)
		}
	}
	if s.role == .Open {
		s.ready = true
		send_scopes(s)
		authors_tell(s)
		reach_tell(n, s)
		if n.host.questions.again != nil {
			n.host.questions.again(n.host.questions.data, s)
		}
		return
	}
	if s.ready {
		// Either end may have dropped what the other watched, or begun to withhold it, under a roster in between
		// that the other never heard. Asking again costs a fingerprint.
		if !s.paused {
			roots_send(s, afresh = true)
		}
		if n.keys == nil {
			// A relay's are never dropped; but there may be more it can ask now.
			for &it in n.interests {
				scope := key_scope(it.watch.lo)
				if interest_concerns(n, it.session, s) && .Read in session_rights(s, scope) && .Read not_in grants_rights(before, scope) {
					interest_send(s, &it)
				}
			}
		}
		if !n.full && s.peer_full {
			outbox_send(s)
		}
		return
	}
	s.ready = true
	s.cursor = n.events.next
	roots_send(s)
	if !n.full && s.peer_full {
		outbox_send(s)
	}
	for &it in n.interests {
		if interest_concerns(n, it.session, s) {
			interest_send(s, &it)
		}
	}
	if n.keys == nil {
		presence_send(n)
	}
	node_balance(n)
	reach_tell(n)
}

@(private)
ROOT :: u64(1) << 32

// Watches whole every scope that this node replicates and the peer may serve.
@(private)
roots_send :: proc(s: ^Session, afresh := false) {
	n := s.node
	if n.keys == nil || !n.full || !s.peer_full || !s.initiator {
		return
	}
	if s.paused && !afresh {
		return
	}
	if afresh {
		roots_drop(s)
	}
	for &k in n.keys.scopes {
		if slice.contains(s.roots[:], k.scope) || .Read not_in session_rights(s, k.scope) {
			continue
		}
		append(&s.roots, k.scope)
		s.roots_due += 1
		s.told = false
		send_watch(s, s.roots_gen * ROOT + u64(k.scope), scope_lo(k.scope), scope_hi(k.scope), {data = true})
	}
	s.settled = s.roots_due == 0
}

@(private)
roots_drop :: proc(s: ^Session) {
	for scope in s.roots {
		send_unwatch(s, s.roots_gen * ROOT + u64(scope))
	}
	clear(&s.roots)
	s.roots_gen += 1 // answers to the old watches no longer count
	s.roots_due = 0
	s.settled = false
	s.told = false
}

// ---------------------------------------------------------------- watching

@(private)
send_watch :: proc(s: ^Session, id: u64, lo, hi: Key, flags: Watch_Flags, limit: u64 = 0) {
	n := s.node
	flags := flags
	sum: Sum
	if flags.data && !flags.adopt {
		sum = store_range(&n.store, lo, hi)
		flags.known = true
	}
	cells_close(s)
	at := frame_begin(&s.out, .Watch)
	write_varint(&s.out, id)
	write_u8(&s.out, u8(flags))
	write_key(&s.out, lo)
	write_key(&s.out, hi)
	write_varint(&s.out, limit)
	if flags.known {
		write_varint(&s.out, u64(sum.count))
		write_pair(&s.out, sum.print)
	}
	frame_end(&s.out, at)
}

@(private)
send_unwatch :: proc(s: ^Session, id: u64) {
	cells_close(s)
	at := frame_begin(&s.out, .Unwatch)
	write_varint(&s.out, id)
	frame_end(&s.out, at)
}

@(private)
on_watch :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	id := read_varint(r)
	flags := Watch_Flags(read_u8(r))
	lo, hi := read_key(r), read_key(r)
	limit := read_varint(r)
	theirs: Sum
	if flags.known {
		theirs.count = int(read_varint(r) & 0xffff_ffff)
		theirs.print = read_pair(r, Print)
	}
	scope := key_scope(lo)
	if r.bad || !key_less(lo, hi) || key_less(scope_hi(scope), hi) || len(s.watches) >= (1024 if s.role == .Open else MAX_INTERESTS) {
		r.bad = true
		return
	}
	if .Read not_in session_rights(s, scope) || (s.role == .Open && keyring_scope(n.keys, scope) == nil) {
		append(&s.tasks, Task{kind = .Synced, watch = id, lo = lo, hi = hi, denied = true})
		return
	}
	asked := [2]Key{lo, hi}
	missed := store_misses(&n.store)
	if limit > 0 && flags.data {
		from, to := tree_prefix(n, n.shelf, lo).count, tree_prefix(n, n.shelf, hi).count
		if u64(to - from) > limit {
			if flags.back {
				lo, _ = tree_select(n, n.shelf, to - int(limit))
			} else {
				hi, _ = tree_select(n, n.shelf, from + int(limit))
			}
		}
	}
	// Everything read is read before anything is done, so that a step undone has done nothing beyond this session.
	mine: Sum
	recon: Recon_Writer
	same := false
	if flags.data && !flags.adopt {
		mine = store_range(&n.store, lo, hi)
		same = flags.known && asked == {lo, hi} && mine == theirs
		if !same && flags.known && !(theirs.count == 0 && s.role == .Open) {
			recon = recon_prepare(s, id, lo, hi, theirs, mine)
		}
	}
	if store_misses(&n.store) != missed {
		return
	}
	on_unwatch(s, id)
	if !s.initiator && id < INTEREST {
		s.settled = false
	}
	w := Watch{id = id, lo = lo, hi = hi, data = flags.data, live = flags.live, counts = flags.counts}
	append(&s.watches, w)

	// Data interests spread outward from clients, and live ones through relays.
	settled := true
	if s.role == .Open || n.keys == nil {
		up := w
		up.lo, up.hi = asked[0], asked[1]
		if n.keys == nil {
			up.data = false
		}
		if it := interest_add(s, up, limit, flags.back); it != nil {
			settled = it.waiting == 0
		}
	}
	if !flags.data {
		return
	}
	if flags.adopt {
		append(&s.tasks, Task{kind = .Synced, watch = id, lo = lo, hi = hi, settled = settled})
		return
	}
	switch {
	case same:
		append(&s.tasks, Task{kind = .Synced, watch = id, lo = lo, hi = hi, settled = settled})
	case !flags.known || (theirs.count == 0 && s.role == .Open):
		append(&s.tasks, Task{kind = .Fill, lo = lo, hi = hi})
		append(&s.tasks, Task{kind = .Synced, watch = id, lo = lo, hi = hi, settled = settled})
	case:
		recon_finish(&recon, lo, hi, theirs)
	}
}

@(private)
on_unwatch :: proc(s: ^Session, id: u64) {
	for w, i in s.watches {
		if w.id == id {
			unordered_remove(&s.watches, i)
			break
		}
	}
	if (s.role == .Open && id != SHOWN) || s.node.keys == nil {
		for it, i in s.node.interests {
			if it.session == s.id && it.watch.id == id {
				interest_remove(s.node, i)
				break
			}
		}
	}
}

@(private)
on_synced :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	id := read_varint(r)
	if id < INTEREST {
		if !s.initiator {
			// The dialler has compared everything and sent what this end lacked: this end is level too.
			flags := Synced_Flags(read_u8(r))
			_, _ = read_key(r), read_key(r)
			_, _ = read_varint(r), read_varint(r)
			compared := false
			for &w in s.watches {
				compared ||= w.data && w.id < INTEREST
			}
			if !r.bad && s.peer_full && flags.settled && compared {
				s.settled = true
				node_balance(n)
			}
			return
		}
		if id / ROOT == s.roots_gen && s.roots_due > 0 && slice.contains(s.roots[:], Scope(id % ROOT)) {
			s.roots_due -= 1
			s.settled = s.roots_due == 0
			node_balance(n)
		}
		return
	}
	flags := Synced_Flags(read_u8(r))
	lo, hi := read_key(r), read_key(r)
	before, after := int(read_varint(r) & 0xffff_ffff), int(read_varint(r) & 0xffff_ffff)
	if r.bad {
		return
	}
	if !flags.denied {
		interest_bound(s, id, lo, hi, before, after)
	}
	for x, i in s.owed {
		if x == id {
			unordered_remove(&s.owed, i)
			interest_settled(n, id)
			break
		}
	}
}

// A full replica has said what a client's window really spans and what lies beyond it. What this one
// happens to hold outside that span has gaps in it, so the window closes to it. Replicas may lag one
// another: the window is what all have vouched for, and what lies beyond is the most any of them knows of.
@(private)
interest_bound :: proc(s: ^Session, id: u64, lo, hi: Key, before, after: int) {
	n := s.node
	for &it in n.interests {
		if it.id != id || !it.watch.data {
			continue
		}
		to := node_session(n, it.session)
		if to == nil {
			return
		}
		mine: ^Report
		for &r in it.reports {
			if r.session == s.id {
				mine = &r
			}
		}
		if mine == nil {
			append(&it.reports, Report{session = s.id})
			mine = &it.reports[len(it.reports) - 1]
		}
		mine^ = {s.id, lo, hi, before, after}
		for &w in to.watches {
			if w.id != it.watch.id || !w.data {
				continue
			}
			w.lo = lo if key_less(w.lo, lo) else w.lo
			w.hi = hi if key_less(hi, w.hi) else w.hi
			it.watch.lo, it.watch.hi, it.limit = w.lo, w.hi, 0
			interest_beyond(n, &it, &w)
			if it.waiting == 0 && w.settled {
				append(&to.tasks, Task{kind = .Synced, watch = w.id, lo = w.lo, hi = w.hi, settled = true})
			}
		}
	}
}

// What lies beyond a window, from all that has been reported of it.
@(private)
interest_beyond :: proc(n: ^Node, it: ^Interest, w: ^Watch) {
	w.far, w.far_before, w.far_after = len(it.reports) > 0, 0, 0
	for r in it.reports {
		w.far_before = max(w.far_before, r.before + store_range(&n.store, r.lo, w.lo).count)
		w.far_after = max(w.far_after, r.after + store_range(&n.store, w.hi, r.hi).count)
	}
}

// Entries of the list before and after a watched range.
@(private)
watch_beyond :: proc(n: ^Node, w: ^Watch) -> (before, after: int) {
	if w.far {
		return w.far_before, w.far_after
	}
	list := key_list(w.lo)
	return store_range(&n.store, list_lo(list), w.lo).count, store_range(&n.store, w.hi, list_hi(list)).count
}

// Once per burst of changes, however many there were.
@(private)
tell_counts :: proc(s: ^Session) {
	missed := store_misses(&s.node.store)
	beyond := make([][2]int, len(s.watches), context.temp_allocator)
	for &w, i in s.watches {
		if w.counts && w.level && !w.far {
			beyond[i][0], beyond[i][1] = watch_beyond(s.node, &w)
		}
	}
	if store_misses(&s.node.store) != missed {
		return // read before anything is done: to be done again
	}
	for &w, i in s.watches {
		if !w.counts || !w.level || w.far {
			continue
		}
		before, after := beyond[i][0], beyond[i][1]
		if before != w.before || after != w.after {
			append(&s.tasks, Task{kind = .Synced, watch = w.id, lo = w.lo, hi = w.hi, settled = w.settled})
			w.before, w.after = before, after
		}
	}
}

// One fewer peer stands between a client's window and being settled.
@(private)
interest_settled :: proc(n: ^Node, id: u64) {
	for &it in n.interests {
		if it.id != id {
			continue
		}
		it.waiting -= 1
		to := node_session(n, it.session)
		if it.waiting > 0 || to == nil {
			return
		}
		for w in to.watches {
			if w.id == it.watch.id {
				append(&to.tasks, Task{kind = .Synced, watch = w.id, lo = w.lo, hi = w.hi, settled = true})
			}
		}
	}
}

@(private)
range_has :: proc(w: ^Watch, key: Key) -> bool {
	key := key
	return key_cmp(&w.lo, &key) <= 0 && key_cmp(&key, &w.hi) < 0
}

// ---------------------------------------------------------------- reconciling

@(private)
Part :: enum u8 {
	Skip  = 0,
	Print = 1, // count, fingerprint
	List  = 2, // every key in the part, each with half a fingerprint
}

@(private)
Recon_Writer :: struct {
	s:     ^Session,
	buf:   [dynamic]byte, // temporary
	skip:  Key, // pending skip, up to here
	skips: bool,
}

@(private)
recon_begin :: proc(s: ^Session, id: u64, owner: bool, lo: Key) -> (w: Recon_Writer) {
	w.s = s
	w.buf = make([dynamic]byte, context.temp_allocator)
	write_varint(&w.buf, id << 1 | (1 if owner else 0))
	write_key(&w.buf, lo)
	return
}

// Adjacent skips merge, and trailing ones are implied.
@(private)
recon_part :: proc(w: ^Recon_Writer, hi: Key, part: Part) {
	if part == .Skip {
		w.skip, w.skips = hi, true
		return
	}
	if w.skips {
		write_key(&w.buf, w.skip)
		write_u8(&w.buf, u8(Part.Skip))
		w.skips = false
	}
	write_key(&w.buf, hi)
	write_u8(&w.buf, u8(part))
}

@(private)
recon_print :: proc(w: ^Recon_Writer, hi: Key, sum: Sum) {
	recon_part(w, hi, .Print)
	write_varint(&w.buf, u64(sum.count))
	write_pair(&w.buf, sum.print)
}

@(private)
recon_end :: proc(w: ^Recon_Writer) {
	cells_close(w.s)
	at := frame_begin(&w.s.out, .Recon)
	append(&w.s.out, ..w.buf[:])
	frame_end(&w.s.out, at)
}

// Describes a range where the sides may differ: by listing it, or by fingerprints of its sixteenths.
@(private)
recon_describe :: proc(w: ^Recon_Writer, lo, hi: Key, mine: Sum) {
	n := w.s.node
	if mine.count <= LIST_MAX {
		recon_part(w, hi, .List)
		write_varint(&w.buf, u64(mine.count))
		scan := tree_scan(n, n.shelf, lo, hi)
		prev: Key
		for leaf in tree_next(&scan) {
			write_key_delta(&w.buf, prev, leaf.key)
			write_u64(&w.buf, leaf.val[0])
			prev = leaf.key
		}
		return
	}
	first := tree_prefix(n, n.shelf, lo).count
	from := lo
	for i in 1 ..= FANOUT {
		to := hi
		if i < FANOUT {
			to, _ = tree_select(n, n.shelf, first + mine.count * i / FANOUT)
		}
		recon_print(w, to, store_range(&n.store, from, to))
		from = to
	}
}

// Opens the comparison of a watched range, from the side that owns the data.
@(private)
recon_start :: proc(s: ^Session, id: u64, lo, hi: Key, theirs: Sum, mine: Sum) {
	w := recon_prepare(s, id, lo, hi, theirs, mine)
	recon_finish(&w, lo, hi, theirs)
}

// What recon_start reads, read; recon_finish does what it does.
@(private)
recon_prepare :: proc(s: ^Session, id: u64, lo, hi: Key, theirs: Sum, mine: Sum) -> (w: Recon_Writer) {
	w = recon_begin(s, id, true, lo)
	if theirs.count != 0 {
		recon_describe(&w, lo, hi, mine)
	}
	return
}

@(private)
recon_finish :: proc(w: ^Recon_Writer, lo, hi: Key, theirs: Sum) {
	if theirs.count == 0 {
		// Nothing to compare, only to send.
		append(&w.s.tasks, Task{kind = .Fill, lo = lo, hi = hi})
	}
	recon_end(w)
}

// The id's low bit says whether the sender owns the watched data (it answers a watch) or watches.
@(private)
on_recon :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	tag := read_varint(r)
	id, owner_sent := tag >> 1, tag & 1 == 1
	lo := read_key(r)
	scope := key_scope(lo)
	if r.bad || .Read not_in session_rights(s, scope) {
		return
	}
	if r.pos == len(r.buf) && !owner_sent {
		// The watcher agrees with everything: all it asked for is queued before this.
		for w in s.watches {
			if w.id == id {
				append(&s.tasks, Task{kind = .Synced, watch = id, lo = w.lo, hi = w.hi, settled = true})
			}
		}
		return
	}
	out := recon_begin(s, id, !owner_sent, lo)
	wants := want_begin(s)
	rest, rests: Key // parts put off until next time
	put_off := false
	for r.pos < len(r.buf) && !r.bad {
		hi := read_key(r)
		if !key_less(lo, hi) || key_less(scope_hi(scope), hi) {
			r.bad = true
			break
		}
		if len(out.buf) > RECON_FRAME {
			if !put_off {
				put_off = true
				rest = lo
			}
			if recon_pass(r) {
				rests = hi
			}
			lo = hi
			continue
		}
		switch Part(read_u8(r)) {
		case .Skip:
			recon_part(&out, hi, .Skip)
		case .Print:
			theirs: Sum
			theirs.count = int(read_varint(r) & 0xffff_ffff)
			theirs.print = read_pair(r, Print)
			mine := store_range(&n.store, lo, hi)
			switch {
			case mine == theirs:
				recon_part(&out, hi, .Skip)
			case theirs.count == 0:
				push_range(s, lo, hi)
				recon_part(&out, hi, .Skip)
			case theirs.count <= LIST_MAX && mine.count > LIST_MAX:
				// They can name theirs more cheaply than this side can narrow it down.
				recon_print(&out, hi, mine)
			case:
				recon_describe(&out, lo, hi, mine)
			}
		case .List:
			recon_compare(s, r, &wants, scope, lo, hi)
			recon_part(&out, hi, .Skip)
		case:
			r.bad = true
		}
		lo = hi
	}
	if r.bad {
		return
	}
	if put_off && key_less(rest, rests) {
		recon_print(&out, rests, store_range(&n.store, rest, rests))
	}
	// Wants precede the reply, so that the reply's acceptance implies their answers.
	want_send(&wants)
	recon_end(&out)
}

// Walks their list beside this side's range, sending what they lack and asking for what differs.
@(private)
recon_compare :: proc(s: ^Session, r: ^Reader, wants: ^Wants, scope: Scope, lo, hi: Key) {
	n := s.node
	count := read_count(r)
	scan := tree_scan(n, n.shelf, lo, hi)
	mine, have := tree_next(&scan)
	prev: Key
	for _ in 0 ..< count {
		key := read_key_delta(r, prev)
		print := read_u64(r)
		if r.bad || key_less(key, lo) || !key_less(key, hi) || !key_less(prev, key) || row_scope(key_row(key)) != scope {
			r.bad = true
			return
		}
		prev = key
		for have && key_cmp(&mine.key, &key) < 0 {
			push_row(s, mine.key)
			mine, have = tree_next(&scan)
		}
		if have && mine.key == key {
			if mine.val[0] != print {
				want_row(wants, key_row(key))
			}
			mine, have = tree_next(&scan)
		} else if node_wants(n, key) {
			want_row(wants, key_row(key))
		}
	}
	for have {
		push_row(s, mine.key)
		mine, have = tree_next(&scan)
	}
}

// Sends a row the peer lacks, if the peer would keep it.
@(private)
push_row :: proc(s: ^Session, key: Key) {
	if s.peer_full || watched(s, key) {
		append(&s.tasks, Task{kind = .Row, row = key_row(key)})
	}
}

@(private)
push_range :: proc(s: ^Session, lo, hi: Key) {
	if s.peer_full {
		append(&s.tasks, Task{kind = .Fill, lo = lo, hi = hi})
		return
	}
	scan := tree_scan(s.node, s.node.shelf, lo, hi)
	for leaf in tree_next(&scan) {
		push_row(s, leaf.key)
	}
}

@(private)
watched :: proc(s: ^Session, key: Key) -> bool {
	for &w in s.watches {
		if w.data && range_has(&w, key) {
			return true
		}
	}
	return false
}

// Steps over a part without acting on it. Whether there was anything in it to act on.
@(private)
recon_pass :: proc(r: ^Reader) -> bool {
	switch Part(read_u8(r)) {
	case .Skip:
		return false
	case .Print:
		_ = read_varint(r)
		_ = read_pair(r, Print)
	case .List:
		count := read_count(r)
		for _ in 0 ..< count {
			_ = read_key_delta(r, KEY_MIN)
			_ = read_u64(r)
			if r.bad {
				break
			}
		}
	case:
		r.bad = true
	}
	return true
}

@(private)
Wants :: struct {
	s:     ^Session,
	buf:   [dynamic]byte,
	count: int,
	final: bool,
}

@(private)
want_begin :: proc(s: ^Session, final := false) -> Wants {
	return {s = s, buf = make([dynamic]byte, context.temp_allocator), final = final}
}

// "Here is what I hold of this row: send the rest, and ask for what you lack."
@(private)
want_row :: proc(w: ^Wants, row: Id) {
	n := w.s.node
	if len(w.buf) > WANT_FRAME {
		want_send(w)
	}
	write_pair(&w.buf, row)
	scan := row_scan(&n.store, row)
	count := 0
	for _ in tree_next(&scan) {
		count += 1
	}
	if count > WANT_HELD {
		count = 0
	}
	write_varint(&w.buf, u64(count))
	w.count += 1
	if count == 0 {
		return
	}
	scan = row_scan(&n.store, row)
	for leaf in tree_next(&scan) {
		c, _ := cell_unkey(leaf)
		write_u8(&w.buf, u8(c.kind))
		write_u8(&w.buf, u8(c.slot))
		write_stamp(&w.buf, c.stamp)
	}
}

@(private)
want_send :: proc(w: ^Wants) {
	if w.count == 0 {
		return
	}
	s := w.s
	cells_close(s)
	at := frame_begin(&s.out, .Want)
	write_u8(&s.out, 1 if w.final else 0)
	write_varint(&s.out, u64(w.count))
	append(&s.out, ..w.buf[:])
	frame_end(&s.out, at)
	clear(&w.buf)
	w.count = 0
}

@(private)
Held :: struct {
	kind:  Kind,
	slot:  Slot,
	stamp: Stamp,
}

@(private)
on_want :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	final := read_u8(r) == 1
	counter := want_begin(s, true)
	rows := read_count(r)
	for _ in 0 ..< rows {
		row := read_pair(r, Id)
		held := make([]Held, read_count(r), context.temp_allocator)
		for &h in held {
			h.kind = Kind(read_u8(r))
			h.slot = Slot(read_u8(r))
			h.stamp = read_stamp(r)
		}
		if r.bad {
			return
		}
		if .Read not_in session_rights(s, row_scope(row)) {
			continue
		}
		if len(held) == 0 {
			append(&s.tasks, Task{kind = .Row, row = row})
			continue
		}
		keys := make([]Key, len(held), context.temp_allocator)
		for h, i in held {
			keys[i] = cell_key(row, h.slot, h.kind, h.stamp)
		}
		slice.sort_by(keys, proc(a, b: Key) -> bool {return key_less(a, b)})
		scan := row_scan(&n.store, row)
		i := 0
		for leaf in tree_next(&scan) {
			for i < len(keys) && key_less(keys[i], leaf.key) {
				i += 1
			}
			if i == len(keys) || keys[i] != leaf.key {
				append(&s.tasks, Task{kind = .Cell, row = row, lo = leaf.key})
			}
		}
		if final {
			continue
		}
		for h in held {
			if store_news(&n.store, row, h.slot, h.kind, h.stamp) {
				want_row(&counter, row)
				break
			}
		}
	}
	want_send(&counter)
}

// ---------------------------------------------------------------- cells

@(private)
cells_open :: proc(s: ^Session) {
	if s.cells.start == 0 {
		s.seq_out += 1
		s.cells = {frame_begin(&s.out, .Cells), {}}
		write_varint(&s.out, s.seq_out)
	}
}

@(private)
cells_close :: proc(s: ^Session) {
	if s.cells.start != 0 {
		frame_end(&s.out, s.cells.start)
		s.cells = {}
	}
}

// Who wrote something, as a local client is told it.
@(private)
Author :: struct {
	device: Key32,
	as:     string, // owned; whom the device vouched for, or nothing if it was for its own
}

@(private)
author_tell :: proc(s: ^Session, number: u32, device: Key32, subject: []byte) {
	device := device
	cells_close(s)
	at := frame_begin(&s.out, .Author)
	write_varint(&s.out, u64(number))
	append(&s.out, ..device[:])
	write_bytes(&s.out, subject)
	frame_end(&s.out, at)
}

// The number a local client knows a cell's author by, told it first if need be.
@(private)
session_author :: proc(s: ^Session, c: ^Cell, by: By) -> (number: u32, ok: bool) {
	device, subject, vouched := cell_author(&s.node.roster, c, by) or_return
	a := Author{device, string(subject) if vouched else ""}
	known: bool
	if number, known = s.authors[a]; known {
		return number, true
	}
	a.as = strings.clone(a.as)
	s.next_author += 1 // none is this client's own
	number = s.next_author
	s.authors[a] = number
	author_tell(s, number, device, subject)
	return number, true
}

// Says who the client is, as others will see it.
@(private)
authors_tell :: proc(s: ^Session) {
	n := s.node
	if !s.wants_authors {
		return
	}
	mine := transmute([]byte)s.as
	if m := roster_member(&n.roster, n.keys.device); m != nil && len(mine) == 0 {
		mine = m.subject
	}
	author_tell(s, 0, n.keys.device, mine)
}

// Someone goes by another name: who wrote what is told afresh, with what they wrote.
@(private)
authors_renew :: proc(s: ^Session) {
	if s.wants_authors && s.ready {
		authors_clear(s)
		resync(s)
	}
}

@(private)
authors_clear :: proc(s: ^Session) {
	for a in s.authors {
		delete(a.as)
	}
	clear(&s.authors)
}

// For whom a local client writes or calls in a scope, if for another than this device belongs to; and whether it may.
@(private)
session_as :: proc(s: ^Session, scope: Scope, call := false) -> (as: []byte, ok: bool) {
	n := s.node
	info := roster_scope(&n.roster, scope)
	m := roster_member(&n.roster, n.keys.device) if n.keys != nil else nil
	if s.as == "" || info == nil || m == nil || s.as == string(m.subject) {
		return nil, true
	}
	// Where nobody could tell, nothing is said. Where they are told, it must be so.
	if !call && .Signed not_in info.flags {
		return nil, true
	}
	return transmute([]byte)s.as, .Vouch in member_rights(m, scope)
}

@(private)
emit_cell :: proc(s: ^Session, c: ^Cell) {
	n := s.node
	if .Read not_in session_rights(s, row_scope(c.row)) {
		// Not sent, so no acknowledgement to come is for the row as it now is.
		#reverse for u, i in s.unacked {
			if u.row == c.row {
				ordered_remove(&s.unacked, i)
			}
		}
		return
	}
	by: By
	if s.role == .Open && !cell_open(n.keys, &n.roster, c, &by if s.wants_authors else nil) {
		return
	}
	author, known := session_author(s, c, by)
	cells_open(s)
	at := len(s.out)
	write_cell(&s.out, c, c.row == s.cells.row)
	if known {
		s.out[at] |= 0x40
		write_varint(&s.out, u64(author))
	}
	s.cells.row = c.row
	if !n.full && s.peer_full {
		if _, ok := tree_get(n, n.outbox, {c.row[0], c.row[1], 0, 0, 0}); ok {
			append(&s.unacked, Unacked{s.seq_out, c.row})
		}
	}
	if len(s.out) - s.cells.start > CELLS_FRAME {
		cells_close(s)
	}
}

@(private)
emit_row :: proc(s: ^Session, row: Id) {
	scan := row_scan(&s.node.store, row)
	for {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		c := row_next(&s.node.store, &scan) or_break
		emit_cell(s, &c)
	}
}

@(private)
on_cells :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	seq := read_varint(r)
	cells := make([dynamic]Cell, context.temp_allocator)
	row: Id
	for r.pos < len(r.buf) {
		c, ok := read_cell(r, row)
		if !ok {
			return
		}
		if s.role == .Open && len(c.body) > MAX_OPEN {
			r.bad = true
			return
		}
		if !stamp_timely(c.stamp, n.now) {
			// Nobody's fault for certain. Dialling again, until the clocks agree, sets it right.
			session_fail(s, .Clock)
			return
		}
		row = c.row
		if s.role == .Open {
			scope := row_scope(c.row)
			as, may := session_as(s, scope)
			if !may || .Write not_in session_rights(s, scope) || !node_may_write(n, scope) || !cell_seal(n.keys, &n.roster, &c, 0, as) {
				session_fail(s, .Denied)
				return
			}
		} else if _, held := tree_get(&n.store, n.cells, cell_key(c.row, c.slot, c.kind, c.stamp)); held {
			continue // whatever it says, it goes no further: most often, it came by two roads
		} else if !cell_welcome(s, c) {
			if len(s.refused) == 0 || s.refused[len(s.refused) - 1] != c.row {
				append(&s.refused, c.row)
			}
			if len(s.refused) > MAX_REFUSED {
				session_fail(s, .Denied)
				return
			}
			continue
		}
		append(&cells, c)
	}
	if record_size(cells[:]) > MAX_RECORD {
		r.bad = true
		return
	}
	stale: [dynamic]Id // not in temporary memory, which merging gives back
	defer delete(stale)
	n.stale = &stale
	node_commit(n, cells[:], s)
	n.stale = nil
	if s.role == .Open {
		for c in cells {
			as, _ := session_as(s, row_scope(c.row))
			text_tidy(n, c, as)
		}
	}
	s.seq_in = seq
	s.ack_at = store_tail(&n.store)
	// The sender holds something older than this side does, and would not otherwise hear of it.
	slice.sort_by(stale[:], proc(a, b: Id) -> bool {return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])})
	for id in slice.unique(stale[:]) {
		append(&s.tasks, Task{kind = .Row, row = id})
	}
}

// A cell from a peer must have been allowed to exist. Forgeries, and cells from the far side of a
// revocation, are dropped without ceremony.
@(private)
cell_welcome :: proc(s: ^Session, c: Cell) -> bool {
	n := s.node
	scope := row_scope(c.row)
	info := roster_scope(&n.roster, scope)
	if info == nil {
		return false
	}
	if .Signed not_in info.flags && .Write not_in session_rights(s, scope) {
		return false
	}
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	c := c
	cell_lawful(&n.roster, &c) or_return
	cell_authentic(&n.roster, &c) or_return
	// Where this node holds the key, garbage cannot win by claiming a late stamp.
	return n.keys == nil || cell_open(n.keys, &n.roster, &c)
}

@(private)
on_ack :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	seq := read_varint(r)
	refused := make([dynamic]Id, context.temp_allocator)
	for r.pos < len(r.buf) && !r.bad {
		append(&refused, read_pair(r, Id))
	}
	if r.bad {
		return
	}
	done := 0
	for done < len(s.unacked) && s.unacked[done].seq <= seq {
		done += 1
	}
	if done == 0 || s.cursor < n.events.first {
		remove_range(&s.unacked, 0, done)
		return // what was written since is not known
	}
	// A row refused, or written again since, stays until its latest version is acknowledged too.
	owed := make(map[Id]bool, context.temp_allocator)
	for row in refused {
		owed[row] = true
	}
	for v in s.unacked[done:] {
		owed[v.row] = true
	}
	for t in s.tasks[s.task_head:] {
		if t.kind == .Row || t.kind == .Cell {
			owed[t.row] = true
		}
	}
	for i := s.cursor; i < n.events.next; i += 1 {
		if c := ring_at(&n.events, i); c.origin != s.id { // what came from there does not go back
			owed[c.row] = true
		}
	}
	for u in s.unacked[:done] {
		if u.row not_in owed {
			tree_delete(n, &n.outbox, {u.row[0], u.row[1], 0, 0, 0})
		}
	}
	remove_range(&s.unacked, 0, done)
}

// ---------------------------------------------------------------- live

LIVE_KIND :: 0x40

@(private)
Live :: struct {
	row:    Id,
	slot:   Slot,
	piece:  u64,
	offset: u64,
	stamp:  Stamp,
	body:   []byte,
}

@(private)
live_bind :: proc(l: ^Live) -> (b: [33]byte) {
	put_u64(b[0:], l.row[0])
	put_u64(b[8:], l.row[1])
	b[16] = byte(l.slot)
	put_u64(b[17:], l.piece)
	put_u64(b[25:], l.offset)
	return
}

@(private)
send_live :: proc(s: ^Session, l: ^Live) {
	if len(s.out) - s.sent > OUT_LIVE {
		return // the piece itself will follow; a slow pipe is not helped by more
	}
	cells_close(s)
	start := len(s.out)
	at := frame_begin(&s.out, .Live)
	write_pair(&s.out, l.row)
	write_u8(&s.out, u8(l.slot))
	write_u64(&s.out, l.piece)
	write_varint(&s.out, l.offset)
	write_stamp(&s.out, l.stamp)
	append(&s.out, ..l.body)
	frame_end(&s.out, at)
	if s.datagram != nil && s.datagram(s.datagram_data, s.out[start:]) {
		resize(&s.out, start)
	}
}

// A live frame that came by the lossy way.
session_datagram :: proc(s: ^Session, bytes: []byte) {
	r := Reader{buf = bytes}
	frame := read_bytes(&r)
	if s.ready && len(frame) > 0 && Message(frame[0]) == .Live && read_done(&r) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		live := Reader{buf = frame[1:]}
		// A step, where storage may answer "not yet": one that reads what is not at hand is dropped, as any live frame may be.
		t := store_begin(&s.node.store)
		on_live(s, &live)
		store_end(&s.node.store, &t, !store_missed(&s.node.store, &t))
	}
}

@(private)
on_live :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	l: Live
	l.row = read_pair(r, Id)
	l.slot = Slot(read_u8(r))
	l.piece = read_u64(r)
	l.offset = read_varint(r)
	l.stamp = read_stamp(r)
	l.body = read_take(r, len(r.buf) - r.pos)
	if r.bad {
		return
	}
	scope := row_scope(l.row)
	info := roster_scope(&n.roster, scope)
	if info == nil || len(l.body) > (MAX_LIVE_OPEN if s.role == .Open else MAX_LIVE) {
		return
	}
	signed := .Signed in info.flags
	missed := store_misses(&n.store)
	keys := keyring_scope(n.keys, scope) if n.keys != nil else nil
	sealed, open := l, l
	if s.role == .Open {
		if .Write not_in session_rights(s, scope) || !node_may_write(n, scope) {
			return
		}
		sealed.stamp = node_stamp(n)
		if !live_seal(n, keys, signed, &sealed) {
			return
		}
	} else {
		// Late is as good as never, and may be a replay.
		if !stamp_timely(l.stamp, n.now) || l.stamp.time + LIVE_LATE < max(n.clock, (max(n.now, LEAP_MS) - LEAP_MS) << 16) {
			return
		}
		if !signed && .Write not_in session_rights(s, scope) {
			return
		}
		// The same frame may arrive by two roads.
		for salt in n.recent {
			if salt == l.stamp.salt {
				return
			}
		}
		if !live_open(n, keys, signed, &open) {
			return
		}
	}
	places := row_places(&n.store, l.row)
	if store_misses(&n.store) != missed {
		return // read before anything is done: to be done again
	}
	if s.role != .Open {
		n.recent[n.recent_at] = l.stamp.salt
		n.recent_at = (n.recent_at + 1) % len(n.recent)
	}
	for to in n.sessions {
		if to == s || !to.ready || !(live_watched(to, &places) || session_shows(to, l.row)) {
			continue
		}
		if to.role == .Open {
			send_live(to, &open)
		} else if s.role == .Open || n.keys == nil {
			send_live(to, &sealed)
		}
	}
}

// Seals a live frame under its stamp and, in a signed scope, signs it, as a cell is.
@(private)
live_seal :: proc(n: ^Node, keys: ^Scope_Keys, signed: bool, l: ^Live) -> bool {
	if keys == nil || keys.epochs[len(keys.epochs) - 1] == {} {
		return false
	}
	bind := live_bind(l)
	iv := aead_nonce(l.stamp, l.slot, LIVE_KIND)
	w := make([dynamic]byte, context.temp_allocator)
	if signed {
		write_varint(&w, author_index(n.keys, &n.roster) or_return)
	}
	seal_append(&w, keys, &iv, bind[:], l.body)
	if signed {
		sign_append(&w, n.keys, live_signed(l, bind[:], w[:])) or_return
	}
	l.body = w[:]
	return true
}

// Checks a live frame as far as this node can, and opens it if it holds the key.
@(private)
live_open :: proc(n: ^Node, keys: ^Scope_Keys, signed: bool, l: ^Live) -> bool {
	bind := live_bind(l)
	body := l.body
	if signed {
		r := Reader{buf = body}
		author := read_varint(&r)
		// What is live is now: a right that has ended is none.
		if r.bad || len(body) - r.pos < SIGNATURE || author >= u64(len(n.roster.members)) {
			return false
		}
		if .Write not_in member_rights(&n.roster.members[author], row_scope(l.row)) {
			return false
		}
		rest := body[:len(body) - SIGNATURE]
		ed25519_verify(n.roster.members[author].signer, live_signed(l, bind[:], rest), body[len(rest):]) or_return
		body = rest[r.pos:]
	}
	if keys == nil {
		return n.keys == nil
	}
	// Only the key of the moment will do: what is live is now.
	r := Reader{buf = body}
	if last := len(keys.epochs) - 1; keys.epochs[last] == {} || read_u32(&r) != keys.ids[last] {
		return false
	}
	iv := aead_nonce(l.stamp, l.slot, LIVE_KIND)
	w := make([dynamic]byte, context.temp_allocator)
	open_append(&w, keys, &iv, bind[:], body) or_return
	l.body = w[:]
	return true
}

@(private)
live_signed :: proc(l: ^Live, bind, body: []byte) -> []byte {
	m := make([dynamic]byte, context.temp_allocator)
	append(&m, ..bind)
	write_u8(&m, LIVE_KIND)
	write_stamp(&m, l.stamp)
	append(&m, ..body)
	return m[:]
}

@(private)
session_shows :: proc(s: ^Session, row: Id) -> bool {
	q := &s.node.host.questions
	return s.role == .Open && q.shows != nil && q.shows(q.data, s, row)
}

// Says something in answer to a question.
session_post :: proc(s: ^Session, type: u8, payload: []byte) {
	cells_close(s)
	at := frame_begin(&s.out, Message(type))
	append(&s.out, ..payload)
	frame_end(&s.out, at)
}

// Has the whole of a row sent, before whatever is said after.
session_show :: proc(s: ^Session, row: Id) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	emit_row(s, row)
	cells_close(s)
}

@(private)
SHOWN :: max(u64) // the window of an interest in what an answer shows

// Wants what is typed in a range of places streamed here, for what a client is shown in answers; and if this is a
// partial replica, perhaps what is there too.
session_wants :: proc(s: ^Session, lo, hi: Key, data := false) {
	interest_add(s, {id = SHOWN, lo = lo, hi = hi, live = true, data = data}, 0, false)
}

session_unwants :: proc(s: ^Session, lo, hi: Key, data := false) {
	for it, i in s.node.interests {
		w := it.watch
		if it.session == s.id && w.id == SHOWN && w.lo == lo && w.hi == hi && w.data == (data && !s.node.full) {
			interest_remove(s.node, i)
			return
		}
	}
}

// Whether some of what is wanted to be shown has yet to be confirmed by a full replica.
session_awaits :: proc(s: ^Session, at: Key) -> bool {
	for it in s.node.interests {
		if it.session == s.id && it.watch.id == SHOWN && it.watch.data && it.waiting > 0 && it.watch.lo == at {
			return true
		}
	}
	return false
}

@(private)
live_watched :: proc(s: ^Session, places: ^Places) -> bool {
	for &w in s.watches {
		if !w.live {
			continue
		}
		for k in places.keys[:places.count] {
			if range_has(&w, k) {
				return true
			}
		}
	}
	return false
}

// ---------------------------------------------------------------- signalling

// Asks whichever relay can see the device to pass it a message only it and its peers can read.
node_signal :: proc(n: ^Node, to: Key32, plain: []byte) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	to := to
	for s in n.sessions {
		if !s.ready || !s.peer_relay || !slice.contains(s.online[:], to) {
			continue
		}
		stamp := node_stamp(n)
		bind: [64]byte
		copy(bind[:], n.keys.device[:])
		copy(bind[32:], to[:])
		iv := aead_nonce(stamp, 0, LIVE_KIND + 1)
		key, ok := signal_key(n.keys, to)
		if !ok {
			return
		}
		w := make([dynamic]byte, context.temp_allocator)
		write_stamp(&w, stamp)
		aead_append(&w, key, &iv, bind[:], plain)
		post(s, to, .Plain, w[:])
	}
}

// Known to the two devices alone.
@(private)
signal_key :: proc(k: ^Keyring, other: Key32) -> (key: Key32, ok: bool) {
	shared := x25519_shared(k.secret, other) or_return
	return derive(shared, "zsp-signal"), true
}

@(private)
on_signal :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	device := read_key32(r)
	rest := read_take(r, len(r.buf) - r.pos)
	if r.bad {
		return
	}
	if n.keys == nil {
		for to in n.sessions {
			// What was committed before goes before: all of it, to everyone it goes to, or nothing yet.
			if to.ready && to.peer == device && !flush_changes(to) {
				return
			}
		}
		for to in n.sessions {
			if to.ready && to.peer == device {
				cells_close(to)
				at := frame_begin(&to.out, .Signal)
				append(&to.out, ..s.peer[:])
				append(&to.out, ..rest)
				frame_end(&to.out, at)
			}
		}
		return
	}
	if len(rest) == 0 {
		return
	}
	if kind := Post(rest[0]); kind != .Plain {
		tunnel_input(s, device, kind, rest[1:])
		return
	}
	rest = rest[1:]
	sealed := Reader{buf = rest}
	stamp := read_stamp(&sealed)
	bind: [64]byte
	copy(bind[:], device[:])
	copy(bind[32:], n.keys.device[:])
	iv := aead_nonce(stamp, 0, LIVE_KIND + 1)
	w := make([dynamic]byte, context.temp_allocator)
	key, ok := signal_key(n.keys, device)
	if ok && !sealed.bad && n.host.signal != nil && aead_open(&w, key, &iv, bind[:], rest[sealed.pos:]) {
		n.host.signal(n.host.data, device, w[:])
	}
}

// Tells every device on a relay who else is there. The node does so itself, but when sessions are lost without
// its knowing, as while it slept.
presence_send :: proc(n: ^Node) {
	for to in n.sessions {
		if !to.ready || to.role != .Peer {
			continue
		}
		cells_close(to)
		at := frame_begin(&to.out, .Presence)
		for s in n.sessions {
			if s.ready && s.role == .Peer && s.peer != to.peer {
				append(&to.out, ..s.peer[:])
			}
		}
		frame_end(&to.out, at)
	}
}

@(private)
on_presence :: proc(s: ^Session, r: ^Reader) {
	n := s.node
	clear(&s.online)
	for r.pos < len(r.buf) && !r.bad {
		device := read_key32(r)
		if !slice.contains(s.online[:], device) {
			append(&s.online, device)
		}
	}
	if r.bad {
		return
	}
	tunnels_prune(s)
	node_balance(n)
	reach_tell(n)
	if n.host.presence != nil {
		n.host.presence(n.host.data, s.online[:])
	}
}

// While every other online device is linked directly, a relay has nothing to say that they do not
// say sooner, so it is asked to hush. It is still told everything, for those who are away.
@(private)
node_balance :: proc(n: ^Node) {
	if !n.full {
		return
	}
	for s in n.sessions {
		if !s.ready || !s.peer_relay || !s.initiator {
			continue
		}
		hush := s.settled && len(s.online) > 0
		for device in s.online {
			direct := false
			for d in n.sessions {
				direct ||= d.ready && d.peer == device && d.settled && d.peer_full
			}
			hush &&= direct
		}
		if hush && s.paused && s.hushed != n.roster.serial {
			hush = false // the roster has changed: there may be scopes here never yet compared
		}
		if hush == s.paused {
			continue
		}
		s.paused = hush
		if hush {
			s.hushed = n.roster.serial
			roots_drop(s)
			s.settled = true
		} else {
			roots_send(s, afresh = true)
		}
		for &it in n.interests {
			if interest_concerns(n, it.session, s) {
				if hush {
					send_unwatch(s, it.id)
				} else {
					interest_send(s, &it)
				}
			}
		}
	}
}

// ---------------------------------------------------------------- producing

@(private)
pump :: proc(s: ^Session) {
	n := s.node
	go := true
	if s.recompare {
		go = unit_step(s, proc(s: ^Session, _: ^Task) {session_recompare(s)})
		s.recompare &&= !go
	}
	if go && (s.cursor != n.events.next || s.counts_due) {
		go = flush_changes(s, OUT_HIGH) && unit_step(s, proc(s: ^Session, _: ^Task) {tell_counts(s)})
		s.counts_due &&= !go
	}
	for go && len(s.out) - s.sent < OUT_HIGH && s.task_head < len(s.tasks) {
		go = unit_step(s, run_task, &s.tasks[s.task_head])
	}
	if go && s.initiator && n.full && s.peer_full && s.settled && !s.told && len(s.roots) > 0 && s.task_head == len(s.tasks) {
		s.told = true
		cells_close(s)
		at := frame_begin(&s.out, .Synced)
		append(&s.out, 0, 1, 0, 0, 0, 0)
		frame_end(&s.out, at)
	}
	if s.task_head == len(s.tasks) && len(s.tasks) > 0 {
		clear(&s.tasks)
		s.task_head = 0
		if cap(s.tasks) > 64 {
			shrink(&s.tasks)
		}
	}
	cells_close(s)
	if s.seq_in > s.acked_in && n.synced >= s.ack_at {
		at := frame_begin(&s.out, .Ack)
		write_varint(&s.out, s.seq_in)
		for row in s.refused {
			write_pair(&s.out, row)
		}
		frame_end(&s.out, at)
		s.acked_in = s.seq_in
		clear(&s.refused)
	}
}

// Sends what has changed since the session last heard. False if it stopped at something storage did not yet have.
@(private)
flush_changes :: proc(s: ^Session, high := max(int)) -> bool {
	n := s.node
	// Whoever flushes, the counts are owed until pump has told them.
	s.counts_due ||= s.cursor != n.events.next
	if s.cursor < n.events.first && !unit_step(s, proc(s: ^Session, _: ^Task) {resync(s)}) {
		return false
	}
	for s.cursor < n.events.next && len(s.out) - s.sent < high {
		if !unit_step(s, flush_one) {
			return false
		}
	}
	return true
}

@(private)
flush_one :: proc(s: ^Session, _: ^Task) {
	n := s.node
	c := ring_at(&n.events, s.cursor)
	s.cursor += 1
	covered := c.row == s.whole && s.cursor <= s.whole_to
	if c.origin != s.id && !covered {
		emit_change(s, &c)
	}
}

@(private)
emit_change :: proc(s: ^Session, c: ^Change) {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	n := s.node
	// Was the row in view before, and is the peer sure to hold it whole?
	// A row that was nowhere until now was in nobody's, and may have cells that came before it did.
	now := s.initiator && s.peer_full
	was := now && (len(c.before) > 0 || len(c.after) == 0)
	level := was && s.settled
	for &w in s.watches {
		if !w.data {
			continue
		}
		for k in c.before {
			if range_has(&w, k) {
				was = true
				level ||= w.level
			}
		}
		for k in c.after {
			now ||= range_has(&w, k)
		}
	}
	if !now && s.role == .Open && session_shows(s, c.row) {
		was, now, level = true, true, true // it was sent whole when it was found
	}
	if !was && !now {
		return
	}
	// A row coming into view is sent whole. So is one that moves while its window is still being
	// compared, for it may have slipped from a part not yet reached into one already passed.
	if !was || (!level && c.kind == .Place) {
		emit_row(s, c.row)
		s.whole, s.whole_to = c.row, n.events.next
		return
	}
	// Gone if already superseded; the event that superseded it follows.
	if cell, ok := store_cell(&n.store, c.row, c.slot, c.kind, c.stamp); ok {
		emit_cell(s, &cell)
	}
}

@(private)
run_task :: proc(s: ^Session, t: ^Task) {
	n := s.node
	task := t^
	switch task.kind {
	case .Row:
		s.task_head += 1
		emit_row(s, task.row)
	case .Cell:
		s.task_head += 1
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if v, ok := tree_get(n, n.cells, task.lo); ok {
			c, at := cell_unkey({task.lo, v})
			c.body = log_bytes(&n.store, at.off, at.len)
			emit_cell(s, &c)
		}
	case .Fill:
		scan := tree_scan(n, n.shelf, task.lo, task.hi)
		for {
			leaf, ok := tree_next(&scan)
			if !ok {
				s.task_head += 1
				return
			}
			emit_row(s, key_row(leaf.key))
			if len(s.out) - s.sent >= OUT_HIGH {
				t.lo = key_next(leaf.key)
				return
			}
		}
	case .Synced:
		missed := store_misses(&n.store)
		beyond := make([][2]int, len(s.watches), context.temp_allocator)
		for &w, i in s.watches {
			if w.id == task.watch && !task.restart && w.data {
				beyond[i][0], beyond[i][1] = watch_beyond(n, &w)
			}
		}
		if store_misses(&n.store) != missed {
			return // read before anything is done: to be done again
		}
		s.task_head += 1
		for &w, i in s.watches {
			if w.id == task.watch {
				w.level = !task.restart
				w.settled = task.settled
				task.lo, task.hi = w.lo, w.hi
				if task.restart || !w.data {
					continue
				}
				w.before, w.after = beyond[i][0], beyond[i][1]
				task.before, task.after = w.before, w.after
			}
		}
		send_synced(s, &task)
	}
}

@(private)
send_synced :: proc(s: ^Session, t: ^Task) {
	cells_close(s)
	at := frame_begin(&s.out, .Synced)
	write_varint(&s.out, t.watch)
	write_u8(&s.out, u8(Synced_Flags{settled = t.settled, restart = t.restart, denied = t.denied}))
	write_key(&s.out, t.lo)
	write_key(&s.out, t.hi)
	// How much of the list lies beyond each end, for scrollbars and for knowing when to stop.
	write_varint(&s.out, u64(t.before))
	write_varint(&s.out, u64(t.after))
	frame_end(&s.out, at)
}

// What this end holds has changed otherwise than by being told: all that either watches is compared again.
@(private)
session_recompare :: proc(s: ^Session) {
	n := s.node
	if !s.ready {
		return
	}
	if !flush_changes(s) {
		return // undone, and done again
	}
	if s.role == .Open {
		resync(s)
		return
	}
	for &w in s.watches {
		if w.data && key_less(w.lo, w.hi) {
			w.level = false
			recon_start(s, w.id, w.lo, w.hi, {count = 1}, store_range(&n.store, w.lo, w.hi))
		}
	}
}

// The session fell off the ring: bring its windows level by comparison instead.
@(private)
resync :: proc(s: ^Session) {
	n := s.node
	s.cursor = n.events.next
	if n.host.questions.again != nil && s.role == .Open {
		n.host.questions.again(n.host.questions.data, s)
	}
	for &w in s.watches {
		if !w.data {
			continue
		}
		w.level = false
		if s.role == .Open {
			append(&s.tasks, Task{kind = .Synced, watch = w.id, lo = w.lo, hi = w.hi, restart = true})
			append(&s.tasks, Task{kind = .Fill, lo = w.lo, hi = w.hi})
			settled := true
			for &it in n.interests {
				settled &&= it.session != s.id || it.watch.id != w.id || it.waiting == 0
			}
			append(&s.tasks, Task{kind = .Synced, watch = w.id, lo = w.lo, hi = w.hi, settled = settled})
		} else {
			recon_start(s, w.id, w.lo, w.hi, {count = 1}, store_range(&n.store, w.lo, w.hi))
		}
	}
	if s.initiator && s.peer_full {
		if n.full {
			s.paused = false
			roots_send(s, afresh = true)
		} else {
			outbox_send(s)
		}
	}
}
