/*
Package pipe carries sessions between machines: an encrypted reliable transport over UDP, WebSocket
framing, and enough TLS to reach a WebSocket on port 443. Like package zsp it performs no I/O; time
and bytes are arguments, so every protocol here runs under simulation.
*/
package pipe

import "core:crypto"
import "core:encoding/endian"
import "../zsp"

// A link carries many ordered reliable byte streams, each independent of the others as in QUIC, plus
// unreliable datagrams, between two devices that know each other's keys. A packet lost from one stream
// holds up that stream alone: the others are delivered as they come.
//
// Loss recovery follows RFC 9002. Congestion control models the path, after BBR: it keeps about one
// bandwidth-delay product in flight, and loss alone does not frighten it. Flow control is per stream and
// per link, and each window grows while it is what limits the other side. Streams are served by urgency,
// and within an urgency by deficit round robin in which a stream that has lately had nothing to send goes
// first (after fq_codel): keystrokes overtake a bulk transfer without anyone having to say which is which.
//
// Stream 0 is open from the start. Each other stream's first bytes, each way, say how urgent it is and how
// much of stream 0 its sender had written before it, and it is delivered no earlier than that much of
// stream 0 has been: whatever was said before a stream began is heard before it.
//
// An idle link sends nothing, ever. It has no timers unless data is in flight.

PACKET :: 1200 // until a probe proves more
PACKET_MAX :: 1452
HEAD :: 13 // type, receiver, counter
MAX_EARLY :: 2048 // pieces held out of order, across the streams of a link, however small
STREAM_WINDOW :: 256 << 10 // what a stream may send beyond what has been delivered, at first
STREAM_WINDOW_MAX :: 16 << 20
LINK_WINDOW :: 1 << 20 // and the streams of a link together
LINK_WINDOW_MAX :: 32 << 20
SEND_BUFFER :: 16 << 20 // at most, written and unacknowledged: twice the congestion window, short of this
STREAMS :: 256 // that the peer may have open at once
URGENT :: 3 // an urgency this or lower is interactive: bulk never keeps it waiting for the link's window
RESERVE :: 64 << 10 // of the link's window, which bulk may not take
QUANTUM :: PACKET
ACK_DELAY :: 5 * MS
MAX_ACK_DELAY :: 25 * MS // that a peer's word is believed about
MAX_PROBES :: 6
PROBE_MOST :: 2_000 * MS // between them, unless the path is slower than that
// And with nothing heard for so long, at the least, however short the probes were: on a fast path six of them come to
// less than a second, which a busy machine, or a relay's, can be silent for without being gone.
LINK_DEAD :: Time(#config(ZSP_LINK_DEAD, 10_000)) * MS
MAX_PATH_PROBES :: 3
MAX_HEADER :: 11 // urgency, then a varint

// First bytes. STUN's are below 0x40.
Type :: enum u8 {
	Punch = 0x40,
	First = 0x41,
	Second = 0x42,
	Data  = 0x43,
}

FIRST_SIZE :: 1 + 4 + zsp.HANDSHAKE_1
SECOND_SIZE :: 1 + 4 + 4 + zsp.HANDSHAKE_2

@(private)
Frame :: enum u8 {
	Pad      = 0,
	Ping     = 1,
	Ack      = 2, // largest, delay, first run, gap/run pairs, a zero gap
	Stream   = 3, // id, offset, bytes
	Datagram = 4, // bytes
	Close    = 5,
	Fin      = 6, // id, offset, bytes: the last of the stream
	Reset    = 7, // id, final size: its sender has given up on it
	Stop     = 8, // id: the receiver wants no more of it
	Window   = 9, // id, the highest offset permitted
	Limit    = 10, // the highest sum of offsets permitted, the most streams the peer may have opened
}

Time :: distinct i64 // microseconds; zero is never

MS :: Time(1000)

Link_State :: enum {
	Dialling, // sent the first message
	Waiting, // answered it; unconfirmed until data arrives
	Open,
	Closed,
}

// What happened to a stream, as told to whoever receives it.
Stream_Event :: enum u8 {
	Data, // bytes, in order
	Fin, // there will be no more
	Reset, // its sender gave up on it: there will be no more, and some may never have come
	Stopped, // its receiver wants no more of what this end sends: that side is given up
}

Link :: struct {
	state:       Link_State,
	channel:     zsp.Channel,
	handshake:   zsp.Handshake,
	first:       [zsp.HANDSHAKE_1]byte,
	second:      [zsp.HANDSHAKE_2]byte,
	local:       u32, // how the peer addresses this link
	remote:      u32,
	dialler:     bool,
	mtu:         int,
	path_probes: int,
	now:         Time, // as of the last input or output

	// Streams, by id; stream 0 first, always. The dialler opens even ids, the other odd ones.
	streams:     [dynamic]^Stream,
	opened:      u64, // streams this end has opened
	may_open:    u64, // how many it may have opened, by the peer's word
	peer_floor:  u64, // every stream the peer opened, counted from 1, up to this is done with
	peer_done:   [dynamic][2]u64, // and these beyond it, as runs from first to last, ascending and apart: no more of
	// them than STREAMS + 1, for what lies between them was opened and goes on, or was passed over, and the peer may have
	// no more than STREAMS of those together
	peer_opened: u64, // the most it has opened
	peer_may:    u64, // how many it may have opened, as last told: as many as are done with, and STREAMS more
	peer_retired: u64, // of those it opened, how many are done with
	limit_due:   bool,
	due:         [dynamic]^Stream, // with something to say about themselves
	classes:     [8]Class,
	held:        int, // bytes written and not yet acknowledged, all streams together

	// Flow control of the link as a whole.
	out_total:   u64, // the sum, over streams, of the highest offset sent
	out_max:     u64, // the peer's permission
	in_total:    u64, // the sum of the highest offsets received
	in_given:    u64, // the sum of offsets delivered
	in_max:      u64, // our permission, as last told
	in_window:   u64,
	in_moved:    Time, // when it was last moved

	// Sending.
	datagrams:   [dynamic][]byte, // owned
	sent:        [dynamic]Sent, // consecutive packet numbers from sent_base, after some done with
	sent_head:   int,
	sent_base:   u64,
	chunks:      [dynamic]Chunk, // of what packets carried, numbered on from chunk_base, after some done with
	chunk_head:  int,
	chunk_base:  u64,
	in_flight:   int,
	largest_acked: u64,
	acked_any:   bool,
	waiting:     Time, // since when, for word of what is in flight: more being sent is none
	probes:      int,
	quiet_since: Time, // since when nothing was heard of what is in flight, while probing
	want_probe:  bool,
	closing:     bool,

	// The path, as measured. Rates are bytes per microsecond.
	srtt, rttvar: f64,
	rtt_min:     f64,
	rtt_min_at:  Time,
	delivered:   u64,
	delivered_at: Time,
	rates:       [8]f64, // best of each recent round
	round:       u64,
	round_ends:  u64, // when this much has been delivered
	round_lost:  int,
	round_sent:  int,
	starting:    bool, // still doubling
	plateau:     int, // rounds since the rate last grew by a quarter
	best:        f64, // when it did
	ceiling:     f64, // a bound on the window imposed by heavy loss
	window:      f64,

	// Receiving.
	seen:        [dynamic]Range, // packet numbers, newest last
	seen_floor:  u64, // below this, every packet is as good as seen
	largest_at:  Time, // when the newest of them came
	ack_due:     Time,
	ack_count:   int,
	early:       int, // pieces held, all streams together
	release:     bool, // stream 0 has moved on: what waited for it may not need to

	// Where bytes go.
	data:        rawptr,
	on_stream:   proc(l: ^Link, id: u64, bytes: []byte, event: Stream_Event),
	on_datagram: proc(l: ^Link, bytes: []byte),
}

Stream :: struct {
	id:          u64,
	urgency:     u8,

	// Sending.
	out:         [dynamic]byte, // written and not yet acknowledged, after some that are done with
	out_head:    int, // how many
	out_base:    u64, // the offset of out[out_head]
	out_next:    u64, // the first offset never sent
	out_limit:   u64, // the peer's permission
	lost:        [dynamic]Range, // to send again
	done:        [dynamic]Range, // acknowledged beyond out_base
	fin:         enum u8 {None, Wanted, Sent, Acked},
	fin_lost:    bool, // to be said again
	reset:       enum u8 {None, Due, Sent, Acked},
	headed:      bool, // its first bytes, the header, are written
	head_after:  Maybe(u64), // what the header is to say of stream 0

	// Receiving.
	in_next:     u64, // delivered, header included
	in_high:     u64, // the highest offset received
	in_limit:    u64, // our permission, as last told
	in_window:   u64,
	in_moved:    Time,
	in_end:      u64, // when ended
	ended:       bool, // its final size is known
	told:        bool, // its end, Fin or Reset, has been told
	stopped:     bool, // what comes is unwanted, and dropped
	stop_due:    bool,
	window_due:  bool,
	listed_due:  bool, // in Link.due
	pieces:      [dynamic]Early, // ascending by offset
	head:        [MAX_HEADER]byte,
	head_size:   int,
	after:       u64, // of stream 0, to be delivered first
	ready:       bool, // its header has come, and that much of stream 0

	// Its turn.
	list:        enum u8 {None, New, Old},
	deficit:     int,
}

Range :: struct {
	lo, hi: u64,
}

@(private)
Class :: struct {
	fresh, old: [dynamic]^Stream,
}

@(private)
Sent :: struct {
	time:   Time, // zero once settled
	size:   i32,
	probe:  bool, // of the path's size: its loss says nothing about congestion
	idle:   bool, // sent with nothing queued behind it, so no measure of the path's rate
	delivered: u64, // at the time of sending
	delivered_at: Time,
	chunk:  u64, // the first of its chunks
	chunks: u16,
}

// Something a packet carried that must come again if the packet does not arrive.
@(private)
Chunk :: struct {
	id:     u64,
	lo, hi: u64,
	kind:   enum u8 {Data, Fin, Reset, Stop, Window, Limit},
}

@(private)
Early :: struct {
	offset: u64,
	bytes:  [dynamic]byte,
}

@(private)
link_init :: proc(l: ^Link) {
	b: [4]byte
	crypto.rand_bytes(b[:])
	l.local = endian.unchecked_get_u32le(b[:])
	l.mtu = PACKET
	l.window = 10 * PACKET
	l.starting = true
	l.ceiling = 1e12
	l.out_max = LINK_WINDOW
	l.in_max = LINK_WINDOW
	l.in_window = LINK_WINDOW
	l.may_open = STREAMS
	l.peer_may = STREAMS
	l.srtt = 200_000
	l.rttvar = 100_000
	l.rtt_min = 1e12
	stream_new(l, 0)
}

link_dial :: proc(l: ^Link, secret, peer, space: zsp.Key32, now: u64 = 1) -> bool {
	link_init(l)
	l.dialler = true
	l.first = zsp.handshake_start(&l.handshake, secret, peer, space, nil, now) or_return
	l.channel.peer = peer
	return true
}

// The peer behind a first message, without committing to anything.
link_answer :: proc(l: ^Link, secret, space: zsp.Key32, packet: []byte) -> bool {
	if len(packet) != FIRST_SIZE || Type(packet[0]) != .First {
		return false
	}
	second, channel, ok := zsp.handshake_answer(secret, space, packet[5:])
	if !ok {
		return false
	}
	link_init(l)
	l.state = .Waiting
	l.remote = endian.unchecked_get_u32le(packet[1:])
	copy(l.first[:], packet[5:])
	l.second, l.channel = second, channel
	return true
}

// Whether a first message is the one this link already answered.
@(require_results)
link_answers :: proc(l: ^Link, packet: []byte) -> bool {
	return l.state == .Waiting && len(packet) == FIRST_SIZE && string(packet[5:]) == string(l.first[:])
}

link_destroy :: proc(l: ^Link) {
	for s in l.streams {
		stream_free(l, s)
	}
	delete(l.streams)
	delete(l.peer_done)
	delete(l.due)
	for &c in l.classes {
		delete(c.fresh)
		delete(c.old)
	}
	for d in l.datagrams {
		delete(d)
	}
	delete(l.datagrams)
	delete(l.sent)
	delete(l.chunks)
	delete(l.seen)
	crypto.zero_explicit(l, size_of(Link))
}

// The handshake packet to (re)send while not open.
@(require_results)
link_hello :: proc(l: ^Link, into: []byte) -> []byte {
	#partial switch l.state {
	case .Dialling:
		into[0] = byte(Type.First)
		endian.unchecked_put_u32le(into[1:], l.local)
		copy(into[5:], l.first[:])
		return into[:FIRST_SIZE]
	case .Waiting:
		into[0] = byte(Type.Second)
		endian.unchecked_put_u32le(into[1:], l.local)
		endian.unchecked_put_u32le(into[5:], l.remote)
		copy(into[9:], l.second[:])
		return into[:SECOND_SIZE]
	}
	return nil
}

// Which link a packet is for, when it says.
@(require_results)
packet_receiver :: proc(packet: []byte) -> (id: u32, ok: bool) {
	if len(packet) < HEAD {
		return
	}
	#partial switch Type(packet[0]) {
	case .Second:
		return endian.unchecked_get_u32le(packet[5:]), len(packet) == SECOND_SIZE
	case .Data:
		return endian.unchecked_get_u32le(packet[1:]), true
	}
	return
}

// ---------------------------------------------------------------- streams, for whoever uses the link

// Opens a stream, to be delivered after `after` bytes of stream 0, or by default all that has yet been
// written to it. Fails while the peer lets no more be opened.
@(require_results)
link_open :: proc(l: ^Link, urgency: u8, after: Maybe(u64) = nil) -> (id: u64, ok: bool) {
	if l.state == .Closed || l.closing || l.opened >= l.may_open {
		return
	}
	l.opened += 1
	id = l.opened * 2 + (0 if l.dialler else 1) - (0 if l.dialler else 2)
	s := stream_new(l, id)
	s.urgency = min(urgency, 7)
	s.head_after = after
	stream_head(l, s)
	return id, true
}

// Says how much of stream 0 must be delivered before what this end sends on a stream the peer opened: by
// default, all that has been written to it by the time this end first writes to the stream.
link_after :: proc(l: ^Link, id: u64, after: u64) {
	if s := stream_find(l, id); s != nil && !s.headed {
		s.head_after = after
	}
}

// How urgent a stream is, as its opener said.
@(require_results)
link_urgency :: proc(l: ^Link, id: u64) -> u8 {
	s := stream_find(l, id)
	return s.urgency if s != nil else 3
}

// How many more bytes are worth handing a stream now: what the peer permits, of what the link is willing to
// hold. An interactive stream always has some, however much bulk is queued.
@(require_results)
link_room :: proc(l: ^Link, id: u64 = 0) -> int {
	s := stream_find(l, id)
	if s == nil || l.state != .Open || l.closing || s.fin != .None || s.reset != .None {
		return 0
	}
	// Two windows' worth keeps the pipe full and what is already promised short.
	total := clamp(int(l.window) * 2, 16 << 10, SEND_BUFFER)
	permitted := int(min(s.out_limit - min(s.out_limit, stream_end(s)), 1 << 30))
	held := int(stream_end(s) - s.out_base)
	room := min(total - l.held, permitted)
	if s.urgency <= URGENT || s.id == 0 {
		room = max(room, min(16 << 10 - held, permitted))
	}
	return max(room, 0)
}

// Hands a stream bytes to send, as many as link_room says there is room for, or more.
link_write :: proc(l: ^Link, id: u64, bytes: []byte) -> bool {
	s := stream_find(l, id)
	if s == nil || s.fin != .None || s.reset != .None || l.state == .Closed {
		return false
	}
	if len(bytes) == 0 {
		return true
	}
	stream_head(l, s)
	append(&s.out, ..bytes)
	l.held += len(bytes)
	stream_wake(l, s)
	return true
}

// There will be no more to send on a stream.
link_finish :: proc(l: ^Link, id: u64) {
	s := stream_find(l, id)
	if s == nil || id == 0 || s.fin != .None || s.reset != .None {
		return
	}
	stream_head(l, s)
	s.fin = .Wanted
	stream_wake(l, s)
}

// Gives up on sending a stream: what is unsent is never sent, and the peer hears so.
link_reset :: proc(l: ^Link, id: u64) {
	s := stream_find(l, id)
	if s == nil || id == 0 || s.reset != .None || s.fin == .Acked {
		return
	}
	stream_give_up(l, s)
}

// Wants no more of a stream: what comes is dropped, and the peer is asked to stop.
link_stop :: proc(l: ^Link, id: u64) {
	s := stream_find(l, id)
	if s == nil || id == 0 || s.stopped || s.told {
		return
	}
	s.stopped = true
	s.stop_due = true
	stream_drop_pieces(l, s)
	stream_due(l, s)
	stream_check_end(l, s)
}

// Whether a stream is still open, either way.
@(require_results)
link_has :: proc(l: ^Link, id: u64) -> bool {
	return stream_find(l, id) != nil
}

link_datagram :: proc(l: ^Link, bytes: []byte) -> bool {
	if l.state != .Open || len(bytes) > l.mtu - HEAD - zsp.TAG - 4 || len(l.datagrams) > 16 {
		return false
	}
	b := make([]byte, len(bytes))
	copy(b, bytes)
	append(&l.datagrams, b)
	return true
}

// Whether all that was written has arrived, and every stream's end been heard.
@(require_results)
link_quiet :: proc(l: ^Link) -> bool {
	if l.held > 0 || len(l.due) > 0 {
		return false
	}
	for s in l.streams {
		if s.fin == .Wanted || s.fin == .Sent || s.reset == .Due || s.reset == .Sent {
			return false
		}
	}
	return true
}

// Says something that must be answered, so that a link to nobody is found out.
link_poke :: proc(l: ^Link) {
	if l.in_flight == 0 {
		l.want_probe = true
	}
}

// Whether link_poke would do anything: an open link with nothing in flight, whose silence a probe would ask after.
link_pokeable :: proc(l: ^Link) -> bool {
	return l.state == .Open && l.in_flight == 0
}

link_close :: proc(l: ^Link) {
	l.closing = true
}

// ---------------------------------------------------------------- stream state

@(private)
stream_new :: proc(l: ^Link, id: u64) -> ^Stream {
	s := new(Stream)
	s.id = id
	s.urgency = 3
	s.out_limit = STREAM_WINDOW
	s.in_limit = STREAM_WINDOW
	s.in_window = STREAM_WINDOW
	s.ready = id == 0
	s.headed = id == 0
	at := len(l.streams)
	for at > 0 && l.streams[at - 1].id > id {
		at -= 1
	}
	inject_at(&l.streams, at, s)
	return s
}

@(private)
stream_free :: proc(l: ^Link, s: ^Stream) {
	stream_drop_pieces(l, s)
	delete(s.out)
	delete(s.lost)
	delete(s.done)
	delete(s.pieces)
	free(s)
}

@(private)
stream_find :: proc(l: ^Link, id: u64) -> ^Stream {
	lo, hi := 0, len(l.streams)
	for lo < hi {
		mid := (lo + hi) / 2
		if l.streams[mid].id < id {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return l.streams[lo] if lo < len(l.streams) && l.streams[lo].id == id else nil
}

@(private)
stream_mine :: proc(l: ^Link, id: u64) -> bool {
	return id != 0 && (id % 2 == 0) == l.dialler
}

// Counting from 1, the how-manyth stream its opener opened.
@(private)
stream_number :: proc(id: u64) -> u64 {
	return id / 2 if id % 2 == 0 else (id + 1) / 2
}

// The end of what has been written.
@(private)
stream_end :: proc(s: ^Stream) -> u64 {
	return s.out_base + u64(len(s.out) - s.out_head)
}

// Writes the header that begins a stream each way, before anything else written to it.
@(private)
stream_head :: proc(l: ^Link, s: ^Stream) {
	if s.headed {
		return
	}
	s.headed = true
	zero := l.streams[0]
	head: [MAX_HEADER]byte
	head[0] = s.urgency
	n := 1
	v := s.head_after.? or_else stream_end(zero)
	for v >= 0x80 {
		head[n] = byte(v) | 0x80
		v >>= 7
		n += 1
	}
	head[n] = byte(v)
	n += 1
	append(&s.out, ..head[:n])
	l.held += n
}

@(private)
stream_give_up :: proc(l: ^Link, s: ^Stream) {
	l.held -= int(stream_end(s) - s.out_base)
	clear(&s.out)
	shrink(&s.out)
	clear(&s.lost)
	clear(&s.done)
	s.out_head = 0
	s.out_base = s.out_next // the final size: all that was ever sent
	s.fin = .None
	s.fin_lost = false
	s.reset = .Due
	stream_due(l, s)
}

@(private)
stream_drop_pieces :: proc(l: ^Link, s: ^Stream) {
	for e in s.pieces {
		delete(e.bytes)
	}
	l.early -= len(s.pieces)
	clear(&s.pieces)
	shrink(&s.pieces)
}

// Notes that a stream has a frame about itself to send: a reset, a stop or a window.
@(private)
stream_due :: proc(l: ^Link, s: ^Stream) {
	if !s.listed_due {
		s.listed_due = true
		append(&l.due, s)
	}
}

// Puts a stream that may have something to send in line for its turn.
@(private)
stream_wake :: proc(l: ^Link, s: ^Stream) {
	if s.list != .None || s.reset != .None {
		return
	}
	s.list = .New
	s.deficit = QUANTUM
	append(&l.classes[s.urgency].fresh, s)
}

@(private)
stream_unlist :: proc(l: ^Link, s: ^Stream) {
	c := &l.classes[s.urgency]
	list := &c.fresh if s.list == .New else &c.old
	for x, i in list {
		if x == s {
			ordered_remove(list, i)
			break
		}
	}
	s.list = .None
}

// How far a stream may send new bytes: what was written, what the peer permits of it and of the link.
@(private)
stream_allowed :: proc(l: ^Link, s: ^Stream) -> u64 {
	link := l.out_max
	if s.urgency > URGENT && s.id != 0 {
		link = link - RESERVE if link > RESERVE else 0
	}
	credit := link - l.out_total if link > l.out_total else 0
	return min(stream_end(s), s.out_limit, s.out_next + credit)
}

@(private)
stream_sendable :: proc(l: ^Link, s: ^Stream) -> bool {
	if s.reset != .None {
		return false
	}
	stream_prune_lost(s)
	if len(s.lost) > 0 || s.out_next < stream_allowed(l, s) {
		return true
	}
	// The end, once all before it is on its way.
	return (s.fin == .Wanted && s.out_next == stream_end(s)) || s.fin_lost
}

// Drops what a later copy already delivered from what is to be sent again.
@(private)
stream_prune_lost :: proc(s: ^Stream) {
	for len(s.lost) > 0 {
		r := &s.lost[0]
		r.lo = max(r.lo, s.out_base)
		for d in s.done {
			if d.lo <= r.lo && r.lo < d.hi {
				r.lo = d.hi
			}
		}
		if r.lo < r.hi {
			return
		}
		ordered_remove(&s.lost, 0)
	}
}

// Up to n bytes to send: what was lost first, then what was never sent.
@(private)
stream_take :: proc(l: ^Link, s: ^Stream, n: int) -> (r: Range, fin: bool) {
	stream_prune_lost(s)
	if len(s.lost) > 0 {
		r = s.lost[0]
		if r.hi - r.lo > u64(n) {
			r.hi = r.lo + u64(n)
			s.lost[0].lo = r.hi
		} else {
			ordered_remove(&s.lost, 0)
		}
	} else if allowed := stream_allowed(l, s); s.out_next < allowed {
		r = {s.out_next, min(allowed, s.out_next + u64(n))}
		l.out_total += r.hi - r.lo
		s.out_next = r.hi
	} else {
		r = {s.out_next, s.out_next}
	}
	if s.fin != .None && r.hi == stream_end(s) && s.out_next == stream_end(s) && (s.fin == .Wanted || s.fin_lost) {
		fin = true
		s.fin = .Sent
		s.fin_lost = false
	}
	return
}

// The stream is done with, both ways: let it go, and let the peer open another in its place.
@(private)
stream_finished :: proc(s: ^Stream) -> bool {
	if s.id == 0 {
		return false
	}
	sent := s.reset == .Acked || (s.fin == .Acked && s.out_base == s.out_next && len(s.out) == s.out_head)
	return sent && s.told
}

// A stream the peer opened is done with: joined to the runs of those that are, and the floor raised past them.
@(private)
peer_done_add :: proc(l: ^Link, n: u64) {
	i := 0
	for i < len(l.peer_done) && l.peer_done[i][1] < n {
		i += 1
	}
	after := i > 0 && l.peer_done[i - 1][1] + 1 == n
	before := i < len(l.peer_done) && l.peer_done[i][0] == n + 1
	switch {
	case after && before:
		l.peer_done[i - 1][1] = l.peer_done[i][1]
		ordered_remove(&l.peer_done, i)
	case after:
		l.peer_done[i - 1][1] = n
	case before:
		l.peer_done[i][0] = n
	case:
		inject_at(&l.peer_done, i, [2]u64{n, n})
	}
	if len(l.peer_done) > 0 && l.peer_done[0][0] == l.peer_floor + 1 {
		l.peer_floor = l.peer_done[0][1]
		ordered_remove(&l.peer_done, 0)
	}
}

@(private)
link_sweep :: proc(l: ^Link) {
	#reverse for s, i in l.streams {
		if !stream_finished(s) || s.listed_due {
			continue
		}
		if s.list != .None {
			stream_unlist(l, s)
		}
		if !stream_mine(l, s.id) {
			peer_done_add(l, stream_number(s.id))
			l.peer_retired += 1
			if l.peer_retired + STREAMS >= l.peer_may + STREAMS / 4 {
				l.limit_due = true
			}
		}
		ordered_remove(&l.streams, i)
		stream_free(l, s)
	}
}

// ---------------------------------------------------------------- receiving

// Processes one packet, decrypting it in place. True when it was genuine and the newest yet: only then is
// its sender's address the one to answer, for anyone can send an old packet again from anywhere.
link_input :: proc(l: ^Link, packet: []byte, now: Time) -> bool {
	if l.state == .Closed || len(packet) < 1 {
		return false
	}
	l.now = now
	#partial switch Type(packet[0]) {
	case .Second:
		if l.state != .Dialling || len(packet) != SECOND_SIZE {
			return false
		}
		l.channel = zsp.handshake_finish(&l.handshake, packet[9:], l.channel.peer) or_return
		crypto.zero_explicit(&l.handshake, size_of(l.handshake))
		l.remote = endian.unchecked_get_u32le(packet[1:])
		l.state = .Open
		l.want_probe = true // confirms the link to the other side
		return true
	case .Data:
		if len(packet) < HEAD + zsp.TAG || l.state == .Dialling {
			return false
		}
		number := endian.unchecked_get_u64le(packet[5:])
		plain := zsp.channel_open_at(&l.channel, number, packet[HEAD:], packet[:HEAD]) or_return
		if l.state == .Waiting {
			l.state = .Open
		}
		if number < l.seen_floor || number == max(u64) || range_contains(l.seen[:], number) {
			return false
		}
		newest := len(l.seen) == 0 || number >= l.seen[len(l.seen) - 1].hi
		gap := len(l.seen) > 0 && number != l.seen[len(l.seen) - 1].hi
		eliciting, kept := link_frames(l, plain, now)
		link_release(l)
		defer link_sweep(l)
		if !kept {
			return false // as though it were lost: it will come again, and is no proof of anything meanwhile
		}
		range_add(&l.seen, number)
		if newest {
			l.largest_at = now
		}
		if len(l.seen) > 32 {
			ordered_remove(&l.seen, 0)
			l.seen_floor = l.seen[0].lo
		}
		if eliciting {
			l.ack_count += 1
			if l.ack_count >= 2 || gap {
				l.ack_due = now
			} else if l.ack_due == 0 {
				l.ack_due = now + ACK_DELAY
			}
		}
		return newest
	}
	return false
}

// Returns whether the packet deserves an acknowledgement, and whether there was room for all of it.
@(private)
link_frames :: proc(l: ^Link, plain: []byte, now: Time) -> (eliciting: bool, kept := true) {
	r := zsp.Reader{buf = plain}
	said: [8][]byte // datagrams, told once the packet is taken
	datagrams := 0
	for r.pos < len(r.buf) && !r.bad && l.state != .Closed {
		frame := Frame(zsp.read_u8(&r))
		eliciting ||= frame != .Ack && frame != .Pad
		switch frame {
		case .Pad:
			r.pos = len(r.buf)
		case .Ping:
		case .Ack:
			link_acked(l, &r, now)
		case .Stream, .Fin:
			id := zsp.read_varint(&r)
			offset := zsp.read_varint(&r)
			bytes := zsp.read_bytes(&r)
			if !r.bad {
				kept &&= link_stream(l, id, offset, bytes, frame == .Fin)
			}
		case .Datagram:
			bytes := zsp.read_bytes(&r)
			if !r.bad && datagrams < len(said) {
				// Told once the packet is known to be taken whole: an untaken one comes again.
				said[datagrams] = bytes
				datagrams += 1
			}
		case .Close:
			l.state = .Closed
			return
		case .Reset:
			id := zsp.read_varint(&r)
			size := zsp.read_varint(&r)
			if !r.bad {
				kept &&= link_reset_heard(l, id, size)
			}
		case .Stop:
			id := zsp.read_varint(&r)
			if s := stream_find(l, id); !r.bad && s != nil && s.reset == .None && s.fin != .Acked && id != 0 {
				stream_give_up(l, s)
				if l.on_stream != nil {
					l.on_stream(l, id, nil, .Stopped)
				}
			}
		case .Window:
			id := zsp.read_varint(&r)
			limit := zsp.read_varint(&r)
			if s := stream_find(l, id); !r.bad && s != nil && limit > s.out_limit {
				s.out_limit = limit
				stream_wake(l, s)
			}
		case .Limit:
			most := zsp.read_varint(&r)
			streams := zsp.read_varint(&r)
			if !r.bad {
				l.may_open = max(l.may_open, streams)
				if most > l.out_max {
					l.out_max = most
					for s in l.streams {
						stream_wake(l, s)
					}
				}
			}
		case:
			return false, false // not understood: not acknowledged, and nothing of it told
		}
	}
	// What cannot be read is not acknowledged: it may be a frame of a later version, but it is never data dropped.
	kept &&= !r.bad
	if kept && l.on_datagram != nil {
		for d in said[:datagrams] {
			l.on_datagram(l, d)
		}
	}
	return
}

// The stream a frame is about, opening it if the peer may and has not already been done with it. Nil, and
// fine, for one that is over; nil, and not fine, for one that may not be.
@(private)
stream_heard :: proc(l: ^Link, id: u64) -> (s: ^Stream, ok: bool) {
	if s = stream_find(l, id); s != nil {
		return s, true
	}
	if stream_mine(l, id) {
		return nil, stream_number(id) <= l.opened // over, or never was
	}
	n := stream_number(id)
	if n <= l.peer_floor {
		return nil, true
	}
	for run in l.peer_done {
		if n < run[0] {
			break
		}
		if n <= run[1] {
			return nil, true
		}
	}
	if n > l.peer_may {
		return nil, false // more than it was let open
	}
	l.peer_opened = max(l.peer_opened, n)
	return stream_new(l, id), true
}

@(private)
link_stream :: proc(l: ^Link, id: u64, offset: u64, bytes: []byte, fin: bool) -> bool {
	s, ok := stream_heard(l, id)
	if s == nil {
		return ok
	}
	end := offset + u64(len(bytes))
	if end < offset || end > s.in_limit || (s.ended && (end > s.in_end || (fin && end != s.in_end))) || (fin && end < s.in_high) {
		return false // beyond what was permitted, or what it said before
	}
	if end > s.in_high {
		if l.in_total + (end - s.in_high) > l.in_max {
			return false
		}
		l.in_total += end - s.in_high
		s.in_high = end
	}
	if fin {
		s.ended, s.in_end = true, end
	}
	if s.told {
		return true // it has said all it will
	}
	if s.stopped {
		stream_consumed(l, s, max(s.in_next, end) - s.in_next)
		stream_check_end(l, s)
		return true
	}
	if offset <= s.in_next && len(s.pieces) == 0 {
		skip := min(s.in_next - offset, u64(len(bytes)))
		if !stream_deliver(l, s, bytes[skip:]) {
			return false
		}
	} else if !stream_hold(l, s, offset, bytes) {
		return false
	}
	stream_drain(l, s)
	return true
}

// Keeps what came out of order, without overlap, so that what is held never exceeds what was permitted; and all
// of it is, or the packet goes unacknowledged, for what is acknowledged does not come again. Pieces that touch are
// joined, so that there are about as many as there are gaps, however small the packets.
@(private)
stream_hold :: proc(l: ^Link, s: ^Stream, offset: u64, bytes: []byte, again := false) -> bool {
	offset, bytes := offset, bytes
	if offset < s.in_next {
		skip := min(s.in_next - offset, u64(len(bytes)))
		offset += skip
		bytes = bytes[skip:]
	}
	for len(bytes) > 0 {
		at := len(s.pieces)
		for at > 0 && s.pieces[at - 1].offset > offset {
			at -= 1
		}
		before := &s.pieces[at - 1] if at > 0 else nil
		if before != nil {
			if end := before.offset + u64(len(before.bytes)); end > offset {
				skip := min(end - offset, u64(len(bytes)))
				offset += skip
				bytes = bytes[skip:]
				continue
			}
		}
		n := u64(len(bytes))
		if at < len(s.pieces) {
			n = min(n, s.pieces[at].offset - offset)
		}
		after := &s.pieces[at] if at < len(s.pieces) && s.pieces[at].offset == offset + n else nil
		switch {
		case before != nil && before.offset + u64(len(before.bytes)) == offset:
			append(&before.bytes, ..bytes[:n])
			if after != nil {
				append(&before.bytes, ..after.bytes[:])
				delete(after.bytes)
				ordered_remove(&s.pieces, at)
				l.early -= 1
			}
		case after != nil:
			joined := make([dynamic]byte, 0, int(n) + len(after.bytes))
			append(&joined, ..bytes[:n])
			append(&joined, ..after.bytes[:])
			delete(after.bytes)
			after^ = {offset, joined}
		case:
			if !again && l.early >= (MAX_EARLY if s.urgency <= URGENT || s.id == 0 else MAX_EARLY * 3 / 4) {
				return false
			}
			copied := make([dynamic]byte, 0, n)
			append(&copied, ..bytes[:n])
			inject_at(&s.pieces, at, Early{offset, copied})
			l.early += 1
		}
		offset += n
		bytes = bytes[n:]
	}
	return true
}

// Delivers what is held that has become next, for as long as the stream may be delivered.
@(private)
stream_drain :: proc(l: ^Link, s: ^Stream) {
	for len(s.pieces) > 0 && s.pieces[0].offset <= s.in_next && (s.ready || !stream_headed(s)) && !s.told {
		e := s.pieces[0]
		ordered_remove(&s.pieces, 0)
		l.early -= 1
		skip := min(s.in_next - e.offset, u64(len(e.bytes)))
		stream_deliver(l, s, e.bytes[skip:], again = true) // what must wait goes back, in the place this left
		delete(e.bytes)
	}
	stream_check_end(l, s)
}

// Whether the header that begins a stream has all come.
@(private)
stream_headed :: proc(s: ^Stream) -> bool {
	return s.id == 0 || (s.head_size > 1 && (s.head[s.head_size - 1] < 0x80 || s.head_size == MAX_HEADER))
}

// Bytes that come next in a stream: its header, then for whoever reads it once stream 0 has caught up. False if
// what must wait could not be kept.
@(private)
stream_deliver :: proc(l: ^Link, s: ^Stream, bytes: []byte, again := false) -> bool {
	bytes := bytes
	for len(bytes) > 0 && !stream_headed(s) {
		s.head[s.head_size] = bytes[0]
		s.head_size += 1
		stream_consumed(l, s, 1)
		bytes = bytes[1:]
		if stream_headed(s) {
			// Its urgency is its opener's to say: a header on one this end opened says nothing of it. One the peer
			// opened, if already in line, moves to the line of its urgency.
			if urgency := min(s.head[0], 7); !stream_mine(l, s.id) && urgency != s.urgency {
				listed := s.list != .None
				if listed {
					stream_unlist(l, s)
				}
				s.urgency = urgency
				if listed {
					stream_wake(l, s)
				}
			}
			r := zsp.Reader{buf = s.head[1:s.head_size]}
			s.after = zsp.read_varint(&r)
		}
	}
	if len(bytes) == 0 {
		return true
	}
	if !stream_check_ready(l, s) {
		return stream_hold(l, s, s.in_next, bytes, again) // put back where it was, if it was held: no more is held
	}
	stream_consumed(l, s, u64(len(bytes)))
	if l.on_stream != nil {
		l.on_stream(l, s.id, bytes, .Data)
	}
	if s.id == 0 {
		l.release = true // streams waiting for this much of stream 0 may go on
	}
	return true
}

// Delivers what waited for stream 0 and need wait no longer.
@(private)
link_release :: proc(l: ^Link) {
	for l.release {
		l.release = false
		for i := 0; i < len(l.streams); i += 1 {
			x := l.streams[i]
			if x.id != 0 && !x.ready && stream_headed(x) && stream_check_ready(l, x) {
				stream_drain(l, x)
			}
		}
	}
}

@(private)
stream_check_ready :: proc(l: ^Link, s: ^Stream) -> bool {
	if !s.ready && stream_headed(s) && l.streams[0].in_next >= s.after {
		s.ready = true
	}
	return s.ready
}

// Bytes have been delivered, or dropped: the peer may send as many more, and the windows grow while they are
// what holds it back.
@(private)
stream_consumed :: proc(l: ^Link, s: ^Stream, n: u64) {
	if n == 0 {
		return
	}
	s.in_next += n
	l.in_given += n
	if s.in_limit - s.in_next < s.in_window / 2 && !s.ended {
		if s.in_moved != 0 && l.now - s.in_moved < Time(2 * l.srtt) && s.in_window < STREAM_WINDOW_MAX {
			s.in_window *= 2
		}
		s.in_moved = l.now
		s.in_limit = s.in_next + s.in_window
		s.window_due = true
		stream_due(l, s)
	}
	if l.in_max - l.in_given < l.in_window / 2 {
		if l.in_moved != 0 && l.now - l.in_moved < Time(2 * l.srtt) && l.in_window < LINK_WINDOW_MAX {
			l.in_window *= 2
		}
		l.in_moved = l.now
		l.in_max = l.in_given + l.in_window
		l.limit_due = true
	}
}

// Tells of a stream's end once all before it is delivered.
@(private)
stream_check_end :: proc(l: ^Link, s: ^Stream) {
	if !s.ended || s.told {
		return
	}
	if s.stopped {
		// Nothing of it is wanted: it is over once its size is known, and what never came is as good as delivered.
		s.told = true
		stream_consumed(l, s, s.in_end - min(s.in_next, s.in_end))
		return
	}
	// Its end, like its bytes, waits for what stream 0 had to say before it.
	if s.in_next == s.in_end && (s.id == 0 || stream_check_ready(l, s)) {
		s.told = true
		if l.on_stream != nil {
			l.on_stream(l, s.id, nil, .Fin)
		}
	}
}

@(private)
link_reset_heard :: proc(l: ^Link, id: u64, size: u64) -> bool {
	s, ok := stream_heard(l, id)
	if s == nil || id == 0 {
		return ok && id != 0
	}
	if size < s.in_high || size > s.in_limit || (s.ended && size != s.in_end) {
		return false
	}
	if l.in_total + (size - s.in_high) > l.in_max {
		return false
	}
	l.in_total += size - s.in_high
	s.in_high = size
	s.ended, s.in_end = true, size
	if s.told {
		return true
	}
	s.told = true
	stream_drop_pieces(l, s)
	// What never came is as good as delivered, for the windows' sake.
	stream_consumed(l, s, size - s.in_next)
	if !s.stopped && l.on_stream != nil {
		l.on_stream(l, id, nil, .Reset)
	}
	return true
}

// ---------------------------------------------------------------- acknowledgements

@(private)
link_acked :: proc(l: ^Link, r: ^zsp.Reader, now: Time) {
	largest := zsp.read_varint(r)
	delay := Time(zsp.read_varint(r))
	if largest >= link_next(l) {
		r.bad = true // nothing so numbered was ever sent
		return
	}
	hi := largest + 1
	newest: Time
	any := false
	for {
		run := zsp.read_varint(r)
		if r.bad || run > hi {
			r.bad = true
			return
		}
		for number in max(hi - run, l.sent_base) ..< min(hi, link_next(l)) {
			p := &link_sent(l)[number - l.sent_base]
			if p.time == 0 {
				continue
			}
			any = true
			if number == largest {
				newest = p.time
			}
			l.in_flight -= int(p.size)
			if p.probe {
				l.mtu = max(l.mtu, PACKET_MAX)
			} else {
				link_measure(l, p, now)
			}
			for c in link_chunks(l, p) {
				chunk_acked(l, c)
			}
			p^ = {}
		}
		gap := zsp.read_varint(r)
		if gap == 0 || r.bad {
			break
		}
		if gap > hi - run {
			r.bad = true
			return
		}
		hi -= run + gap
	}
	if !any {
		return
	}
	l.probes, l.waiting = 0, now
	if newest != 0 {
		rtt := max(f64(now - newest), 1)
		// Remeasure the empty path now and then, lest a route change go unnoticed.
		if rtt <= l.rtt_min || now - l.rtt_min_at > 10_000 * MS {
			l.rtt_min, l.rtt_min_at = rtt, now
		}
		// Less what the peer says it sat on, as RFC 9002 has it, but never below the least ever seen.
		if held := f64(min(delay, MAX_ACK_DELAY)); rtt - held >= l.rtt_min {
			rtt -= held
		}
		if !l.acked_any {
			l.srtt, l.rttvar = rtt, rtt / 2
		} else {
			l.rttvar = 0.75 * l.rttvar + 0.25 * abs(l.srtt - rtt)
			l.srtt = 0.875 * l.srtt + 0.125 * rtt
		}
	}
	l.acked_any = true
	l.largest_acked = max(l.largest_acked, largest)
	link_detect_loss(l, now)
	link_model(l, now)
	link_settle(l)
}

// Lets go of the records of packets that are settled.
@(private)
link_settle :: proc(l: ^Link) {
	for l.sent_head < len(l.sent) && l.sent[l.sent_head].time == 0 {
		l.sent_head += 1
		l.sent_base += 1
	}
	if l.sent_head * 2 > len(l.sent) {
		remove_range(&l.sent, 0, l.sent_head)
		l.sent_head = 0
	}
	// Chunks are kept for the oldest packet unsettled, and those after.
	keep := l.chunk_base + u64(len(l.chunks) - l.chunk_head)
	for p in link_sent(l) {
		if p.time != 0 && p.chunks > 0 {
			keep = p.chunk
			break
		}
	}
	l.chunk_head += int(keep - l.chunk_base)
	l.chunk_base = keep
	if l.chunk_head * 2 > len(l.chunks) {
		remove_range(&l.chunks, 0, l.chunk_head)
		l.chunk_head = 0
	}
}

@(private)
link_chunks :: proc(l: ^Link, p: ^Sent) -> []Chunk {
	if p.chunks == 0 || p.chunk < l.chunk_base {
		return nil
	}
	at := l.chunk_head + int(p.chunk - l.chunk_base)
	return l.chunks[at:][:p.chunks]
}

@(private)
chunk_acked :: proc(l: ^Link, c: Chunk) {
	if c.kind == .Limit {
		return
	}
	s := stream_find(l, c.id)
	if s == nil {
		return
	}
	switch c.kind {
	case .Data, .Fin:
		if s.reset != .None {
			return
		}
		if c.lo < c.hi {
			range_insert(&s.done, {c.lo, c.hi})
		}
		if c.kind == .Fin {
			s.fin = .Acked
			s.fin_lost = false
		}
		// Advance past what is wholly acknowledged, moving memory only once half of it is done with.
		if len(s.done) > 0 && s.done[0].lo <= s.out_base {
			n := int(s.done[0].hi - s.out_base)
			s.out_head += n
			l.held -= n
			s.out_base = s.done[0].hi
			ordered_remove(&s.done, 0)
			if s.out_head == len(s.out) {
				clear(&s.out)
				s.out_head = 0
				if cap(s.out) > 64 << 10 {
					shrink(&s.out)
				}
			} else if s.out_head > 4096 && s.out_head * 2 > len(s.out) {
				remove_range(&s.out, 0, s.out_head)
				s.out_head = 0
			}
		}
	case .Reset:
		if s.reset == .Sent {
			s.reset = .Acked
		}
	case .Stop, .Window, .Limit:
	}
}

@(private)
chunk_lost :: proc(l: ^Link, c: Chunk) {
	if c.kind == .Limit {
		l.limit_due = true
		return
	}
	s := stream_find(l, c.id)
	if s == nil {
		return
	}
	switch c.kind {
	case .Data, .Fin:
		if s.reset != .None {
			return
		}
		if c.lo < c.hi {
			append(&s.lost, Range{c.lo, c.hi})
		}
		if c.kind == .Fin && s.fin == .Sent {
			s.fin_lost = true
		}
		stream_wake(l, s)
	case .Reset:
		if s.reset == .Sent {
			s.reset = .Due
			stream_due(l, s)
		}
	case .Stop:
		if !s.told {
			s.stop_due = true
			stream_due(l, s)
		}
	case .Window:
		if !s.ended {
			s.window_due = true
			stream_due(l, s)
		}
	case .Limit:
	}
}

@(private)
link_sent :: proc(l: ^Link) -> []Sent {
	return l.sent[l.sent_head:]
}

@(private)
link_next :: proc(l: ^Link) -> u64 {
	return l.sent_base + u64(len(l.sent) - l.sent_head)
}

@(private)
link_detect_loss :: proc(l: ^Link, now: Time) {
	patience := link_patience(l)
	for &p, i in link_sent(l) {
		number := l.sent_base + u64(i)
		if number >= l.largest_acked {
			break
		}
		if p.time != 0 && (l.largest_acked - number >= 3 || now - p.time > patience) {
			link_lose(l, &p)
		}
	}
}

@(private)
link_patience :: proc(l: ^Link) -> Time {
	return Time(1.125 * l.srtt) + MS
}

@(private)
link_lose :: proc(l: ^Link, p: ^Sent) {
	l.in_flight -= int(p.size)
	for c in link_chunks(l, p) {
		chunk_lost(l, c)
	}
	if !p.probe {
		l.round_lost += int(p.size)
	}
	p^ = {}
}

// A delivery rate sample: what arrived since this packet left, over how long that took.
@(private)
link_measure :: proc(l: ^Link, p: ^Sent, now: Time) {
	l.delivered += u64(p.size)
	l.delivered_at = now
	span := f64(max(now - p.delivered_at, now - p.time, 1))
	rate := f64(l.delivered - p.delivered) / span
	best := &l.rates[l.round % len(l.rates)]
	if !p.idle || rate > best^ {
		best^ = max(best^, rate)
	}
}

@(private)
link_model :: proc(l: ^Link, now: Time) {
	rate: f64
	for r in l.rates {
		rate = max(rate, r)
	}
	if l.delivered >= l.round_ends {
		heavy := l.round_lost * 8 > l.round_sent // more than an eighth
		if heavy {
			l.ceiling = max(min(l.window, l.ceiling) * 0.7, 4 * link_floor(l))
		} else if l.ceiling < 1e12 {
			l.ceiling *= 1.25
		}
		if rate > l.best * 1.25 {
			l.best, l.plateau = rate, 0
		} else {
			l.plateau += 1
		}
		if l.starting && (l.plateau >= 3 || heavy) {
			l.starting = false
		}
		l.round += 1
		l.round_ends = l.delivered + u64(l.in_flight)
		l.round_lost, l.round_sent = 0, 0
		l.rates[l.round % len(l.rates)] = 0
	}
	product := rate * l.rtt_min
	gain := 1.25
	switch {
	case l.starting:
		gain = 2.9
	case l.round % 8 == 0:
		gain = 1.75 // is there more to be had?
	case now - l.rtt_min_at > 9_000 * MS:
		gain = 0.75 // let the queue drain, to see the empty path
	}
	target := product * gain + 6 * f64(l.mtu)
	if l.starting {
		target = max(target, l.window)
	}
	l.window = max(min(target, l.ceiling), 4 * link_floor(l))
}

// ---------------------------------------------------------------- sending

// The next packet to send, or nil. Call until nil after input, writes, or a deadline. A packet is as large as
// the path allows, and no larger than `into`.
@(require_results)
link_output :: proc(l: ^Link, into: []byte, now: Time) -> []byte {
	if l.state != .Open {
		return nil
	}
	l.now = now
	if l.closing {
		l.state = .Closed
		into[HEAD] = byte(Frame.Close)
		return link_seal(l, into, HEAD + 1)
	}
	link_expire(l, now)
	if l.state != .Open {
		return nil
	}

	limit := min(l.mtu, len(into)) - zsp.TAG
	w := zsp_writer(into[:limit])
	w.pos = HEAD
	eliciting := false
	p: Sent
	p.chunk = l.chunk_base + u64(len(l.chunks) - l.chunk_head)
	// One packet at least, with nothing in flight, whatever the window: else a window smaller than a packet sends nothing,
	// and nothing ever comes to open it.
	room := l.in_flight == 0 || l.in_flight + limit < int(l.window) || l.want_probe
	acking := l.ack_due != 0 && (now >= l.ack_due || link_sendable(l))
	if acking {
		link_put_ack(l, &w, now)
	}
	// What streams have to say of themselves is small, and rides along with acknowledgements.
	if room || acking {
		eliciting ||= link_put_control(l, &w, &p)
	}
	if room && len(l.datagrams) > 0 {
		d := l.datagrams[0]
		if w.pos + 4 + len(d) <= limit {
			put(&w, byte(Frame.Datagram))
			put_varint(&w, u64(len(d)))
			put_bytes(&w, d)
			delete(d)
			ordered_remove(&l.datagrams, 0)
			eliciting = true
		}
	}
	if room {
		eliciting ||= link_put_streams(l, &w, &p)
	}
	if !eliciting && l.want_probe {
		put(&w, byte(Frame.Ping))
		eliciting = true
	}
	if l.want_probe && eliciting {
		l.want_probe = false
	}
	if !eliciting && l.path_probes < MAX_PATH_PROBES && l.mtu < PACKET_MAX && l.acked_any && l.in_flight == 0 && len(into) >= PACKET_MAX && w.pos == HEAD {
		// While otherwise idle: does the path carry full-size packets?
		l.path_probes += 1
		p.probe = true
		eliciting = true
		put(&w, byte(Frame.Ping))
		w.buf = into[:PACKET_MAX - zsp.TAG]
		for w.pos < len(w.buf) {
			put(&w, byte(Frame.Pad))
		}
	}
	if w.pos == HEAD {
		return nil
	}
	out := link_seal(l, into, w.pos)
	p.time = now if eliciting else 0
	p.size = i32(len(out)) if eliciting else 0
	if l.in_flight == 0 {
		l.delivered_at = now
	}
	p.delivered, p.delivered_at = l.delivered, l.delivered_at
	p.idle = !link_sendable(l)
	append(&l.sent, p)
	if !eliciting {
		link_settle(l) // nothing to wait for of it: forgotten at once, if nothing before it is waited for
	}
	if eliciting {
		if l.in_flight == 0 {
			l.waiting = now
		}
		l.in_flight += len(out)
		l.round_sent += len(out)
	}
	return out
}

@(private)
link_chunk :: proc(l: ^Link, p: ^Sent, c: Chunk) {
	append(&l.chunks, c)
	p.chunks += 1
}

// Resets, stops, windows and the link's limits that are due. True if any was said.
@(private)
link_put_control :: proc(l: ^Link, w: ^Writer, p: ^Sent) -> (said: bool) {
	if l.limit_due && len(w.buf) - w.pos >= 21 && p.chunks < max(u16) {
		l.limit_due = false
		l.peer_may = l.peer_retired + STREAMS
		put(w, byte(Frame.Limit))
		put_varint(w, l.in_max)
		put_varint(w, l.peer_may)
		link_chunk(l, p, {kind = .Limit})
		said = true
	}
	for len(l.due) > 0 && len(w.buf) - w.pos >= 64 && p.chunks < max(u16) - 3 {
		s := l.due[0]
		ordered_remove(&l.due, 0)
		s.listed_due = false
		if s.reset == .Due {
			s.reset = .Sent
			put(w, byte(Frame.Reset))
			put_varint(w, s.id)
			put_varint(w, s.out_next)
			link_chunk(l, p, {id = s.id, kind = .Reset})
			said = true
		}
		if s.stop_due {
			s.stop_due = false
			put(w, byte(Frame.Stop))
			put_varint(w, s.id)
			link_chunk(l, p, {id = s.id, kind = .Stop})
			said = true
		}
		if s.window_due {
			s.window_due = false
			put(w, byte(Frame.Window))
			put_varint(w, s.id)
			put_varint(w, s.in_limit)
			link_chunk(l, p, {id = s.id, kind = .Window})
			said = true
		}
	}
	return
}

// Fills the rest of a packet from streams, the most urgent first, and within an urgency those that have lately
// had nothing to say before those that never stop. True if anything was.
@(private)
link_put_streams :: proc(l: ^Link, w: ^Writer, p: ^Sent) -> (said: bool) {
	for &c in l.classes {
		for len(c.fresh) + len(c.old) > 0 {
			space := len(w.buf) - w.pos - 32 // frame type, id, offset, length
			if space <= 0 || p.chunks >= max(u16) {
				return
			}
			fresh := len(c.fresh) > 0
			s := c.fresh[0] if fresh else c.old[0]
			if !stream_sendable(l, s) {
				ordered_remove(&c.fresh if fresh else &c.old, 0)
				s.list = .None
				continue
			}
			if s.deficit <= 0 {
				// Its turn is over: to the back of the line, with another.
				ordered_remove(&c.fresh if fresh else &c.old, 0)
				s.deficit += QUANTUM
				s.list = .Old
				append(&c.old, s)
				continue
			}
			r, fin := stream_take(l, s, min(space, max(s.deficit, 64)))
			if r.lo == r.hi && !fin {
				// Nothing it may send after all.
				ordered_remove(&c.fresh if fresh else &c.old, 0)
				s.list = .None
				continue
			}
			put(w, byte(Frame.Fin if fin else Frame.Stream))
			put_varint(w, s.id)
			put_varint(w, r.lo)
			put_varint(w, r.hi - r.lo)
			put_bytes(w, s.out[s.out_head:][r.lo - s.out_base:r.hi - s.out_base])
			link_chunk(l, p, {id = s.id, lo = r.lo, hi = r.hi, kind = .Fin if fin else .Data})
			s.deficit -= int(r.hi - r.lo) + 8
			said = true
		}
	}
	return
}

@(private)
link_sendable :: proc(l: ^Link) -> bool {
	if len(l.datagrams) > 0 || len(l.due) > 0 || l.limit_due {
		return true
	}
	for &c in l.classes {
		for s in c.fresh {
			if stream_sendable(l, s) {
				return true
			}
		}
		for s in c.old {
			if stream_sendable(l, s) {
				return true
			}
		}
	}
	return false
}

@(private)
link_expire :: proc(l: ^Link, now: Time) {
	if l.in_flight == 0 {
		return
	}
	if l.acked_any {
		link_detect_loss(l, now)
	}
	if l.in_flight == 0 || now < link_timeout(l) {
		return
	}
	if l.probes == 0 {
		l.quiet_since = l.waiting
	}
	l.probes += 1
	if l.probes > MAX_PROBES && now - l.quiet_since >= LINK_DEAD {
		l.state = .Closed
		return
	}
	l.waiting = now
	l.want_probe = true
	// Send the oldest unacknowledged again.
	for &p in link_sent(l) {
		if p.time != 0 {
			size, probe := p.size, p.probe
			link_lose(l, &p)
			if !probe {
				l.round_lost -= int(size) // a timeout is no measure of congestion
			}
			if l.probes > 2 {
				l.window = 2 * link_floor(l)
			}
			break
		}
	}
	link_settle(l) // what was lost is waited for no more
}

// A packet of this link's, as large as its path takes: what its window is never let fall below a few of.
@(private)
link_floor :: proc(l: ^Link) -> f64 {
	return f64(max(l.mtu, PACKET))
}

@(private)
link_timeout :: proc(l: ^Link) -> Time {
	pto := Time(l.srtt + max(4 * l.rttvar, 1000)) + ACK_DELAY
	return l.waiting + max(min(pto << uint(min(l.probes, 20)), PROBE_MOST), pto) + 1
}

// When link_output must next be called, absent other reasons; zero for never.
@(require_results)
link_deadline :: proc(l: ^Link) -> (t: Time) {
	if l.state != .Open {
		return 0
	}
	t = l.ack_due
	if l.in_flight > 0 {
		out := link_timeout(l)
		if l.acked_any && l.largest_acked > l.sent_base {
			for &p, i in link_sent(l) {
				if l.sent_base + u64(i) >= l.largest_acked {
					break
				}
				if p.time != 0 {
					out = min(out, p.time + link_patience(l) + 1)
					break
				}
			}
		}
		t = out if t == 0 else min(t, out)
	}
	return
}

@(private)
link_put_ack :: proc(l: ^Link, w: ^Writer, now: Time) {
	l.ack_due = 0
	l.ack_count = 0
	put(w, byte(Frame.Ack))
	n := len(l.seen)
	put_varint(w, l.seen[n - 1].hi - 1)
	put_varint(w, u64(max(now - l.largest_at, 0)))
	for i := n - 1;; i -= 1 {
		put_varint(w, l.seen[i].hi - l.seen[i].lo)
		if i == 0 || w.pos > 400 {
			put_varint(w, 0)
			break
		}
		put_varint(w, l.seen[i].lo - l.seen[i - 1].hi)
	}
}

@(private)
link_seal :: proc(l: ^Link, into: []byte, size: int) -> []byte {
	number := link_next(l)
	into[0] = byte(Type.Data)
	endian.unchecked_put_u32le(into[1:], l.remote)
	endian.unchecked_put_u64le(into[5:], number)
	zsp.channel_seal_in_place(&l.channel, number, into[HEAD:size + zsp.TAG], into[:HEAD])
	return into[:size + zsp.TAG]
}

// ---------------------------------------------------------------- small things

@(private)
Writer :: struct {
	buf: []byte,
	pos: int,
}

@(private)
zsp_writer :: proc(buf: []byte) -> Writer {
	return {buf, 0}
}

@(private)
put :: proc(w: ^Writer, b: byte) {
	w.buf[w.pos] = b
	w.pos += 1
}

@(private)
put_varint :: proc(w: ^Writer, v: u64) {
	v := v
	for v >= 0x80 {
		put(w, byte(v) | 0x80)
		v >>= 7
	}
	put(w, byte(v))
}

@(private)
put_bytes :: proc(w: ^Writer, b: []byte) {
	w.pos += copy(w.buf[w.pos:], b)
}

@(private)
range_contains :: proc(rs: []Range, v: u64) -> bool {
	#reverse for r in rs {
		if v >= r.lo {
			return v < r.hi
		}
	}
	return false
}

@(private)
range_add :: proc(rs: ^[dynamic]Range, v: u64) {
	range_insert(rs, {v, v + 1})
}

// Inserts into ascending disjoint ranges, joining what touches.
@(private)
range_insert :: proc(rs: ^[dynamic]Range, r: Range) {
	r := r
	i := len(rs)
	for i > 0 && rs[i - 1].hi >= r.lo {
		i -= 1
	}
	j := i
	for j < len(rs) && rs[j].lo <= r.hi {
		r.lo = min(r.lo, rs[j].lo)
		r.hi = max(r.hi, rs[j].hi)
		j += 1
	}
	if j == i {
		inject_at(rs, i, r)
	} else {
		rs[i] = r
		remove_range(rs, i + 1, j)
	}
}
