package zsp

// A relay that sleeps between messages keeps its sessions with its sockets. Only what cannot be told
// from the store or the roster is kept, which comes to a few hundred bytes.

// Appends the session's state. False when it is in the middle of something and must not sleep.
@(require_results)
session_save :: proc(s: ^Session, w: ^[dynamic]byte) -> bool {
	n := s.node
	if s.role != .Peer || len(s.input) > 0 || len(s.out) > 0 || len(s.tasks) > 0 || len(s.refused) > 0 || s.closing {
		return false
	}
	// Nor anything more that is not saved: changes it has yet to be sent (as where storage answered "not yet"), counts
	// owed for them, a comparison owed, an acknowledgement owed, or the host's verdict on it. Better it reconnects than
	// misses any.
	if s.cursor != n.events.next || s.counts_due || s.recompare || s.seq_in > s.acked_in || (s.greeted && !s.accepted) {
		return false
	}
	// Nor a call it carries, which is not saved: woken, the node would number its next call as one the other side still
	// has open. It reconnects, and the other side hears that its calls are over.
	if node_calling(n, s) {
		return false
	}
	write_varint(w, u64(s.id))
	write_u8(
		w,
		(1 if s.greeted else 0) | (2 if s.accepted else 0) | (4 if s.ready else 0) | (8 if s.peer_full else 0) | (16 if s.peer_relay else 0),
	)
	append(w, ..s.peer[:])
	write_varint(w, s.peer_serial)
	write_varint(w, s.seq_out)
	write_varint(w, s.seq_in)
	write_varint(w, s.acked_in)
	for &x in s.watches {
		write_varint(w, x.id)
		interest: u64
		for &it in n.interests {
			if it.session == s.id && it.watch.id == x.id {
				interest = it.id
			}
		}
		write_u8(
			w,
			(1 if x.data else 0) | (2 if x.live else 0) | (4 if x.level else 0) | (8 if interest != 0 else 0) | (16 if x.counts else 0) | (32 if x.settled else 0) | (64 if x.counts else 0),
		)
		write_key(w, x.lo)
		write_key(w, x.hi)
		if interest != 0 {
			write_varint(w, interest)
		}
		if x.counts {
			// What the peer was last told lies beyond the window: what is to be told next is what differs from it.
			write_varint(w, u64(x.before))
			write_varint(w, u64(x.after))
		}
	}
	return true
}

// Revives a session without a word to the peer, which never knew.
@(require_results)
session_load :: proc(n: ^Node, bytes: []byte) -> (s: ^Session, ok: bool) {
	r := Reader{buf = bytes}
	s = new(Session)
	s.node = n
	s.id = u32(read_varint(&r))
	flags := read_u8(&r)
	s.greeted = flags & 1 != 0
	s.accepted = flags & 2 != 0
	s.ready = flags & 4 != 0
	s.peer_full = flags & 8 != 0
	s.peer_relay = flags & 16 != 0
	s.peer = read_key32(&r)
	s.peer_serial = read_varint(&r)
	s.seq_out = read_varint(&r)
	s.seq_in = read_varint(&r)
	s.acked_in = read_varint(&r)
	s.cursor = n.events.next
	m := roster_member(&n.roster, s.peer)
	taken := false // another session has its id: what was saved is not this node's
	for x in n.sessions {
		taken ||= x.id == s.id
	}
	if r.bad || s.id == 0 || taken || flags & ~u8(31) != 0 || (s.ready && (m == nil || !member_active(m))) {
		free(s)
		return nil, false
	}
	// What a watch below adds, and nothing else, is taken back should what follows not be sound.
	interests, next_watch := len(n.interests), n.next_watch
	for r.pos < len(r.buf) && !r.bad {
		x: Watch
		x.id = read_varint(&r)
		f := read_u8(&r)
		r.bad ||= f & 128 != 0
		x.data, x.live, x.level = f & 1 != 0, f & 2 != 0, f & 4 != 0
		x.lo, x.hi = read_key(&r), read_key(&r)
		x.counts, x.settled = f & 16 != 0, f & 32 != 0
		if f & 8 != 0 {
			id := read_varint(&r)
			w := x
			w.data = false
			append(&n.interests, Interest{id = id, session = s.id, watch = w})
			n.next_watch = max(n.next_watch, id & ~INTEREST)
		}
		if f & 64 != 0 {
			x.before, x.after = int(read_varint(&r)), int(read_varint(&r))
		} else if x.counts {
			// Saved by a relay that kept no counts. Where storage may answer "not yet" nothing may be read here, and
			// counted later, a change since would be counted in as though told: better it reconnects.
			if store_lazy(&n.store) {
				r.bad = true
				break
			}
			x.before, x.after = watch_beyond(n, &x)
		}
		append(&s.watches, x)
	}
	if r.bad {
		// Nothing of it stays: nor what it asked upstream for.
		for i in interests ..< len(n.interests) {
			delete(n.interests[i].reports)
		}
		resize(&n.interests, interests)
		n.next_watch = next_watch
		delete(s.watches)
		free(s)
		return nil, false
	}
	if m != nil {
		append(&s.grants, ..m.grants)
	}
	n.next_id = max(n.next_id, s.id + 1)
	append(&n.sessions, s)
	return s, true
}
