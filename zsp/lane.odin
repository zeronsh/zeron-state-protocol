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

// How urgent a call is, by its method: what someone is typing into first, what is copied in bulk last. What may be
// either, a command or a port, is in the middle with everything else, where what has lately said little goes first.
method_urgency :: proc(method: string) -> u8 {
	switch method {
	case "zsp.pty":
		return 1
	case "zsp.get", "zsp.put":
		return 6
	case "":
		return 4 // between nodes themselves
	}
	return 3
}

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
	} else if l.sent > OUT_HIGH {
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
	lane_free(l)
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
	append(&l.input, ..bytes)
	lane_take(s, l)
	return !s.closing
}

// Takes the whole frames that have come on a lane, once the session may act on them.
@(private)
lane_take :: proc(s: ^Session, l: ^Lane) {
	if !s.ready || s.busy {
		return // they wait, as frames on the session's own stream do
	}
	s.busy = true
	defer s.busy = false
	used := 0
	for !s.closing {
		r := Reader{buf = l.input[used:]}
		n := read_varint(&r)
		if r.bad {
			if len(l.input) - used >= 10 {
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
	if used > 0 {
		remove_range(&l.input, 0, used)
	}
	if len(l.input) == 0 {
		shrink(&l.input)
	}
}

// Frames that waited on lanes for the session to be ready may be taken now.
@(private)
lanes_take :: proc(s: ^Session) {
	for i := 0; i < len(s.lanes); i += 1 {
		if len(s.lanes[i].input) > 0 {
			lane_take(s, s.lanes[i])
		}
	}
}

// The other end has ended its side of a lane: finished it, or given it up, in which case what it carried is lost.
session_lane_heard :: proc(s: ^Session, id: u64, given_up: bool) {
	l := lane_find(s, id)
	if l == nil {
		return
	}
	if !given_up {
		lane_take(s, l)
	}
	l.heard = true
	if given_up || len(l.input) > 0 {
		// A frame cut short, or frames that will now never be whole: its calls cannot go on.
		calls_lost(s.node, s.id, lane = id)
		l.over = true
	}
	lane_prune(s, l)
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
