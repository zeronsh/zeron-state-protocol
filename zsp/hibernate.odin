package zsp

// A relay that sleeps between messages keeps its sessions with its sockets. Only what cannot be told
// from the store or the roster is kept, which comes to a few hundred bytes.

// Appends the session's state. False when it is in the middle of something and must not sleep.
@(require_results)
session_save :: proc(s: ^Session, w: ^[dynamic]byte) -> bool {
	if s.role != .Peer || len(s.input) > 0 || len(s.out) > 0 || len(s.tasks) > 0 || len(s.refused) > 0 || s.closing {
		return false
	}
	n := s.node
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
		write_u8(w, (1 if x.data else 0) | (2 if x.live else 0) | (4 if x.level else 0) | (8 if interest != 0 else 0) | (16 if x.counts else 0) | (32 if x.settled else 0))
		write_key(w, x.lo)
		write_key(w, x.hi)
		if interest != 0 {
			write_varint(w, interest)
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
	for r.pos < len(r.buf) && !r.bad {
		x: Watch
		x.id = read_varint(&r)
		f := read_u8(&r)
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
		x.before, x.after = watch_beyond(n, &x)
		append(&s.watches, x)
	}
	m := roster_member(&n.roster, s.peer)
	if r.bad || (s.ready && (m == nil || !member_active(m))) {
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
