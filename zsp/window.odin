package zsp

// What is made for a peer is held to a window: so much at most made and not yet said by the peer to have been taken.
// Whatever lies between the two ends, a socket's buffers, a proxy's, the network's, a runtime's that takes all it is
// given, then holds no more than the window, and what is to go first, made now, is taken within about a round trip,
// rather than after all that was handed over before it. The window is what keeps the way busy and no more: two and a
// half times the most delivered in a while, per millisecond, times the least a round trip has ever taken on the
// session, as BBR reckons it (which twice is, and which, of a peer that says what it took a little late, or in a
// lump, leaves the way idle now and then). (Ever: a round trip taken later may have waited behind what the window let wait, and taken for the least,
// would let more wait, and so on. A way that becomes slower is mostly a way taken afresh, by a session anew.)
//
// But never as less than WINDOW_RTT_LEAST. A peer says what it took once it has taken in a whole message, and a round
// trip shorter than taking one in is no round trip of the way: on a way of a millisecond, a window of a few
// milliseconds' worth holds a message or two, and the two ends take turns, the peer taking in what was made while this
// end waits for word of it, and then this end making more while the peer waits for it; which takes the rate measured
// down, and with it the window, until a message at a time goes. Whatever goes first then waits behind no more than
// that much of taking in.
//
// What is taken is what has come, whole frames or not: a frame of 400 KB, said to be taken only once it had all come,
// would keep the window shut for as long as it took to come, and then the way idle for a round trip.
//
// A peer says what it took, in bytes of frames, those saying what was taken aside, by Took, and only if it said it
// would in its Hello; nor over a link, which carries a session on streams of its own, under its own control.

WINDOW_MIN :: 64 << 10
WINDOW_START :: 256 << 10
WINDOW_MAX :: 64 << 20
WINDOW_HEADROOM :: 64 << 10 // what goes first may go so far beyond it
WINDOW_SAMPLE :: 16 << 10 // a round trip is timed once for so many bytes
WINDOW_GAIN :: 5 // halves: the window is so many halves of what is delivered in a round trip
WINDOW_RTT_LEAST :: 20 // ms: the least round trip the window is reckoned for
WINDOW_RATE_KEPT :: 2000 // ms: the most delivered is that of this long

Window :: struct {
	size:       u64, // zero until first reckoned: WINDOW_START
	samples:    [64]Window_Sample,
	head, held: int,
	next:       u64, // of what the peer counts, where the next is timed
	counted:    u64, // of what the peer counts, the most the host had taken when it last took any
	slept:      u64, // of what the peer counts, so much was on its way when the session slept: nothing is timed until it has come
	rate:       u64, // most delivered lately, bytes per ms
	rate_at:    u64,
	rtt:        u64, // least round trip, ms
}

@(private)
Window_Sample :: struct {
	at:    u64, // of what the peer counts, the first byte of what was taken then
	time:  u64, // ms
	acked: u64, // `acked` then
}

// Whether what is made for the peer is held to a window.
@(private)
window_held :: proc(s: ^Session) -> bool {
	return s.peer_took && s.lane_open == nil
}

// Bytes made for the peer, but Took frames, which it does not count: as it counts what it says it took.
@(private)
window_made :: proc(s: ^Session) -> u64 {
	made := s.taken + u64(len(s.out) - s.sent)
	return made - min(s.took_out, made)
}

// Bytes made for the peer, and not yet said to have been taken.
@(private)
window_in_flight :: proc(s: ^Session) -> u64 {
	made := window_made(s)
	return made - min(s.acked, made)
}

// Whether more may be made: of what goes first, beyond the window by WINDOW_HEADROOM.
@(private)
window_open :: proc(s: ^Session, first := false) -> bool {
	if !window_held(s) {
		return true
	}
	size := s.window.size if s.window.size > 0 else WINDOW_START
	return window_in_flight(s) < size + (WINDOW_HEADROOM if first else 0)
}

// The host took bytes: a round trip is timed now and then, of the first byte taken now that the peer counts. (Not of
// what was taken before: that would be timed from now, and taken to have come back sooner; nor of the last taken now,
// which comes only after all taken with it, at the rate the way allows, which is not the way's round trip.)
@(private)
window_sent :: proc(s: ^Session) {
	w := &s.window
	// What the peer counts, as the host has taken it: less, now and then, than before, while a Took frame is part taken,
	// it being counted out whole as it is made. What was the most is kept: the first byte of what is taken now is
	// past it, never before, and is not taken for what came before a sleep.
	counted := s.taken - min(s.took_out, s.taken)
	if counted <= w.counted {
		return
	}
	first := w.counted + 1
	w.counted = counted
	// Nor timed while what was on its way before a sleep has yet to be said to have come: said to have come, it would be
	// taken for what was delivered in a round trip of what was sent after.
	if !window_held(s) || counted < w.next || s.acked < w.slept {
		return
	}
	w.next = counted + WINDOW_SAMPLE
	if w.held == len(w.samples) {
		return // so many on their way: this one goes untimed
	}
	w.samples[(w.head + w.held) % len(w.samples)] = {first, s.node.now, s.acked}
	w.held += 1
}

// The peer says it took so many more bytes.
@(private)
on_took :: proc(s: ^Session, r: ^Reader) {
	n := read_varint(r)
	if r.bad {
		return
	}
	s.acked += n
	w := &s.window
	now := s.node.now
	for w.held > 0 && w.samples[w.head].at <= s.acked {
		x := w.samples[w.head]
		w.head = (w.head + 1) % len(w.samples)
		w.held -= 1
		rtt := max(now - min(x.time, now), 1)
		rate := (s.acked - x.acked) / rtt
		if rate >= w.rate || now - w.rate_at > WINDOW_RATE_KEPT {
			w.rate, w.rate_at = rate, now
		}
		if w.rtt == 0 || rtt < w.rtt {
			w.rtt = rtt
		}
		w.size = clamp(WINDOW_GAIN * w.rate * max(w.rtt, WINDOW_RTT_LEAST) / 2, WINDOW_MIN, WINDOW_MAX)
	}
}

// Of what has come and is not yet taken in, whole frames or a part of one, what is or may be of Took frames: what is
// said to be taken is not, until it is known not to be.
@(private)
took_held :: proc(rest: []byte) -> (held: u64) {
	r := Reader{buf = rest}
	for r.pos < len(rest) {
		start := r.pos
		n := read_varint(&r)
		if r.bad || r.pos >= len(rest) {
			return held + u64(len(rest) - start) // its kind not known yet
		}
		if n == 0 || n > MAX_FRAME {
			return // no frame: the session fails on it, and nothing more is said
		}
		end := r.pos + int(min(n, u64(len(rest) - r.pos)))
		if Message(rest[r.pos]) == .Took {
			held += u64(end - start)
		}
		r.pos = end
	}
	return
}

// Whether the peer is owed word of what has come.
@(private)
took_owed :: proc(s: ^Session) -> bool {
	return window_held(s) && s.took - min(s.took_frames + s.took_held, s.took) > s.took_said
}

// Says what has come in since it last said, but Took frames, if anything has: in a frame the peer does not count, nor
// is said to have taken.
@(private)
took_send :: proc(s: ^Session) {
	if !took_owed(s) {
		return
	}
	counted := s.took - min(s.took_frames + s.took_held, s.took)
	cells_close(s)
	before := len(s.out)
	at := frame_begin(&s.out, .Took)
	write_varint(&s.out, counted - s.took_said)
	frame_end(&s.out, at)
	s.took_said = counted
	s.took_out += u64(len(s.out) - before)
}
