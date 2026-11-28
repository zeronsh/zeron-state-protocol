package zsp

import "base:runtime"

// Lanes: where the pipe beneath a session carries many independent streams (a link does), each call takes one
// of its own, so that a packet lost from one call holds up no other, nor the session. A lane carries only Call
// and Flow frames, in either direction, and its first bytes each way are delivered no earlier than everything
// the session said before it began: so whoever is called has what the call is about, as §12 asks.
//
// The host opens a lane's stream when asked (Session.lane_open), passes along what it has to say
// (session_lane_output and session_lane_sent), feeds it what comes (session_lane_input) and says when the
// other end has finished with it (session_lane_heard). A lane whose calls are over is `over`: the host ends its
// stream once all of it is sent, and calls session_lane_closed, after which the lane is gone.

MAX_LANES :: 1024 // a session's, open at once; past this, calls share the session's own stream
MAX_LANE_FRAME :: CALL_WINDOW + 4096 // a frame on a lane: one message of a call, and what says which
MAX_LANE_HELD :: 8 << 20 // frames cut short, across a session's lanes, waiting for the rest

Lane :: struct {
	id:      u64, // the pipe's stream
	urgency: u8, // 0 most, 7 least
	after:   u64, // of the session's own stream, said before this lane's first bytes this way
	begun:   bool, // `after` is settled
	out:     [dynamic]byte,
	sent:    int,
	input:   [dynamic]byte, // an incomplete frame, or frames that wait for the session to be ready
	calls:   int, // that use it
	over:    bool, // nothing more will be said on it from here
	ended:   bool, // and the host has ended its stream
	heard:   bool, // the other end has ended its side
}

URGENCY :: 3 // a call's lane, unless its caller says otherwise
URGENCY_NODES :: 4 // of calls between nodes themselves
URGENCY_LEAST :: 7

// What a session has produced on its own stream, sent or not.
@(private)
session_produced :: proc(s: ^Session) -> u64 {
	return s.taken + u64(len(s.out) - s.sent)
}

@(private)
lane_find :: proc(s: ^Session, id: u64) -> ^Lane {
	for l in s.lanes {
		if l.id == id {
			return l
		}
	}
	return nil
}

// A lane for a call this node sends on a session, if the session's pipe carries lanes.
@(private)
lane_open :: proc(s: ^Session, urgency: u8) -> ^Lane {
	if s.lane_open == nil || len(s.lanes) >= MAX_LANES {
		return nil
	}
	cells_close(s)
	after := session_produced(s)
	id, ok := s.lane_open(s.lane_data, urgency, after)
	if !ok {
		return nil
	}
	l := new(Lane)
	l.id, l.urgency, l.after, l.begun = id, urgency, after, true
	append(&s.lanes, l)
	return l
}

// Appends to a lane what a frame says, settling, at its first bytes this way, what was said before them.
@(private)
lane_out :: proc(s: ^Session, l: ^Lane) -> ^[dynamic]byte {
	if !l.begun {
		cells_close(s)
		l.after = session_produced(s)
		l.begun = true
	}
	return &l.out
}

// The lanes, for the host to draw from.
session_lanes :: proc(s: ^Session) -> []^Lane {
	return s.lanes[:]
}

session_lane_output :: proc(s: ^Session, l: ^Lane) -> []byte {
	if s.node.failed {
		return nil // storage failed: nothing more is said
	}
	return l.out[l.sent:]
}

session_lane_sent :: proc(s: ^Session, l: ^Lane, n: int) {
	l.sent += n
	if l.sent == len(l.out) {
		l.sent = 0
		clear(&l.out)
		if cap(l.out) > 4096 {
			shrink(&l.out)
		}
	} else if l.sent > OUT_HIGH && l.sent >= len(l.out) - l.sent {
		// Moved down only once what is sent is at least what is left, so that each byte is moved once at most: a
		// lane may hold a whole call window, far more than a link takes at once.
		resize(&l.out, copy(l.out[:], l.out[l.sent:]))
		l.sent = 0
	}
}

// Whether the host should end a lane's stream now: its calls are over and all of it has been sent.
session_lane_done :: proc(s: ^Session, l: ^Lane) -> bool {
	return l.over && !l.ended && l.sent == len(l.out)
}

// The host has ended the lane's stream; once the other end has too, the lane is let go.
session_lane_closed :: proc(s: ^Session, l: ^Lane) {
	l.ended = true
	lane_prune(s, l)
}

@(private)
lane_prune :: proc(s: ^Session, l: ^Lane) {
	if !l.ended || !l.heard {
		return
	}
	for x, i in s.lanes {
		if x == l {
			ordered_remove(&s.lanes, i)
			break
		}
	}
	lane_drop_input(s, l)
	lane_free(l)
}

// What waited on a lane, let go of: nor is it counted any longer against what lanes may hold.
@(private)
lane_drop_input :: proc(s: ^Session, l: ^Lane) {
	s.lane_held -= len(l.input)
	clear(&l.input)
	shrink(&l.input)
}

@(private)
lane_free :: proc(l: ^Lane) {
	delete(l.out)
	delete(l.input)
	free(l)
}

// What came on a lane, in any fragmentation. False means the session is to be closed.
session_lane_input :: proc(s: ^Session, id: u64, urgency: u8, bytes: []byte) -> bool {
	if s.closing || id == 0 {
		return !s.closing
	}
	l := lane_find(s, id)
	if l == nil {
		if len(s.lanes) >= 2 * MAX_LANES {
			session_fail(s, .Malformed)
			return false
		}
		l = new(Lane)
		l.id, l.urgency = id, urgency
		append(&s.lanes, l)
	}
	if l.heard {
		return true
	}
	if len(l.input) == 0 && s.ready && !s.busy {
		// Taken where they lie, and only what is cut short kept for later.
		used := lane_frames(s, l, bytes)
		if !s.closing {
			lane_keep(s, l, bytes[used:])
		}
		return !s.closing
	}
	lane_keep(s, l, bytes)
	lane_take(s, l)
	return !s.closing
}

// Keeps what must wait on a lane, as much as may wait: before the session is ready, no more across its lanes than
// its own stream may hold; after, frames cut short, no more across them than MAX_LANE_HELD.
@(private)
lane_keep :: proc(s: ^Session, l: ^Lane, bytes: []byte) {
	if len(bytes) == 0 {
		return
	}
	most := MAX_LANE_HELD if s.ready else MAX_FRAME + 16
	if s.lane_held + len(bytes) > most {
		session_fail(s, .Malformed)
		return
	}
	append(&l.input, ..bytes)
	s.lane_held += len(bytes)
}

// Takes the whole frames that have come on a lane, once the session may act on them.
@(private)
lane_take :: proc(s: ^Session, l: ^Lane) {
	if !s.ready || s.busy || len(l.input) == 0 {
		return // they wait, as frames on the session's own stream do
	}
	used := lane_frames(s, l, l.input[:])
	if used > 0 {
		remove_range(&l.input, 0, used)
		s.lane_held -= used
	}
	if len(l.input) == 0 {
		shrink(&l.input)
	}
}

// Acts on the whole frames at the start of `bytes`; returns how many bytes they were.
@(private)
lane_frames :: proc(s: ^Session, l: ^Lane, bytes: []byte) -> (used: int) {
	s.busy = true
	defer s.busy = false
	for !s.closing {
		r := Reader{buf = bytes[used:]}
		n := read_varint(&r)
		if r.bad {
			if len(bytes) - used >= 10 {
				session_fail(s, .Malformed)
			}
			break
		}
		if n == 0 || n > MAX_LANE_FRAME {
			session_fail(s, .Malformed)
			break
		}
		if int(n) > len(r.buf) - r.pos {
			break
		}
		frame := r.buf[r.pos:][:n]
		used += r.pos + int(n)
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		inner := Reader{buf = frame[1:]}
		#partial switch Message(frame[0]) {
		case .Call:
			on_call(s, &inner, lane = l)
		case .Flow:
			on_flow(s, &inner)
		case:
			session_fail(s, .Malformed) // a lane carries calls and nothing else
		}
		if inner.bad && !s.closing {
			session_fail(s, .Malformed)
		}
	}
	return
}

// Frames that waited on lanes for the session to be ready may be taken now, of lanes the other end has ended too.
@(private)
lanes_take :: proc(s: ^Session) {
	for i := 0; i < len(s.lanes); {
		l := s.lanes[i]
		if len(l.input) > 0 {
			lane_take(s, l)
		}
		if l.heard && !lane_heard_done(s, l) {
			continue // let go of, and what was after it is here now
		}
		i += 1
	}
}

// The other end has ended its side of a lane: finished it, or given it up, in which case what it carried is lost.
session_lane_heard :: proc(s: ^Session, id: u64, given_up: bool) {
	l := lane_find(s, id)
	if l == nil {
		return
	}
	l.heard = true
	if given_up {
		// What it carried is lost: its calls cannot go on, nor is any of it taken.
		lane_drop_input(s, l)
		calls_lost(s.node, s.id, lane = id)
		l.over = true
		lane_prune(s, l)
		return
	}
	lane_take(s, l)
	lane_heard_done(s, l)
}

// Once what came whole on a lane the other end has ended is taken, what is left was cut short. Whole frames that wait
// for the session to be ready wait on, and are taken then. True while the lane is still there.
@(private)
lane_heard_done :: proc(s: ^Session, l: ^Lane) -> bool {
	if len(l.input) > 0 && (!s.ready || s.busy) && !s.closing {
		return true
	}
	if l.calls <= 0 {
		l.over = true // nothing goes on on it, nor can now
	}
	if len(l.input) > 0 {
		// A frame cut short, that will now never be whole: its calls cannot go on, nor is any of it taken.
		lane_drop_input(s, l)
		calls_lost(s.node, s.id, lane = l.id)
		l.over = true
	}
	was := len(s.lanes)
	lane_prune(s, l)
	return len(s.lanes) == was
}

// What this end sent on a lane will not all arrive, for the other end wants no more of it.
session_lane_stopped :: proc(s: ^Session, id: u64) {
	l := lane_find(s, id)
	if l == nil {
		return
	}
	calls_lost(s.node, s.id, lane = id)
	l.over = true
	l.ended = true
	clear(&l.out)
	l.sent = 0
	lane_prune(s, l)
}

@(private)
lanes_destroy :: proc(s: ^Session) {
	for l in s.lanes {
		lane_free(l)
	}
	delete(s.lanes)
}
