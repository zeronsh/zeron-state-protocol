/*
Package pipe carries sessions between machines: an encrypted reliable stream over UDP, WebSocket
framing, and enough TLS to reach a WebSocket on port 443. Like package zsp it performs no I/O; time
and bytes are arguments, so every protocol here runs under simulation.
*/
package pipe

import "core:crypto"
import "core:encoding/endian"
import "../zsp"

// A link is one ordered reliable byte stream plus unreliable datagrams, between two devices that
// know each other's keys. Loss recovery follows RFC 9002. Congestion control models the path, after
// BBR: it keeps about one bandwidth-delay product in flight, and loss alone does not frighten it.
//
// An idle link sends nothing, ever. It has no timers unless data is in flight.

PACKET :: 1200 // until a probe proves more
PACKET_MAX :: 1452
HEAD :: 13 // type, receiver, counter
MIN_WINDOW :: 2 * PACKET
RECV_WINDOW :: 1 << 20
SEND_BUFFER :: 1 << 20
ACK_DELAY :: 5 * MS
MAX_PROBES :: 6
MAX_PATH_PROBES :: 3

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
	Ack      = 2, // largest, first run, gap/run pairs, highest stream offset permitted
	Stream   = 3, // offset, bytes
	Datagram = 4, // bytes
	Close    = 5,
}

Time :: distinct i64 // microseconds; zero is never

MS :: Time(1000)

Link_State :: enum {
	Dialling, // sent the first message
	Waiting, // answered it; unconfirmed until data arrives
	Open,
	Closed,
}

Link :: struct {
	state:       Link_State,
	channel:     zsp.Channel,
	handshake:   zsp.Handshake,
	first:       [zsp.HANDSHAKE_1]byte,
	second:      [zsp.HANDSHAKE_2]byte,
	local:       u32, // how the peer addresses this link
	remote:      u32,
	mtu:         int,
	path_probes: int,

	// Sending.
	out:         [dynamic]byte, // unacknowledged and unsent stream bytes, after some that are done with
	out_head:    int, // how many
	out_base:    u64, // stream offset of out[out_head]
	out_next:    u64, // first offset never sent
	out_limit:   u64, // the peer's permission
	lost:        [dynamic]Range, // to send again
	done:        [dynamic]Range, // acknowledged beyond out_base
	datagrams:   [dynamic][]byte, // owned
	sent:        [dynamic]Sent, // consecutive packet numbers from sent_base, after some done with
	sent_head:   int,
	sent_base:   u64,
	in_flight:   int,
	largest_acked: u64,
	acked_any:   bool,
	last_sent:   Time,
	probes:      int,
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
	ack_due:     Time,
	ack_count:   int,
	in_next:     u64,
	in_limit:    u64,
	early:       [dynamic]Early, // ascending by offset

	// Where bytes go.
	data:        rawptr,
	on_stream:   proc(data: rawptr, bytes: []byte),
	on_datagram: proc(data: rawptr, bytes: []byte),
}

Range :: struct {
	lo, hi: u64,
}

@(private)
Sent :: struct {
	time:   Time, // zero once settled
	size:   i32,
	probe:  bool, // of the path's size: its loss says nothing about congestion
	idle:   bool, // sent with nothing queued behind it, so no measure of the path's rate
	delivered: u64, // at the time of sending
	delivered_at: Time,
	stream: Range,
}

@(private)
Early :: struct {
	offset: u64,
	bytes:  []byte, // owned
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
	l.out_limit = RECV_WINDOW
	l.in_limit = RECV_WINDOW
	l.srtt = 200_000
	l.rttvar = 100_000
	l.rtt_min = 1e12
}

link_dial :: proc(l: ^Link, secret, peer, space: zsp.Key32) -> bool {
	link_init(l)
	l.first = zsp.handshake_start(&l.handshake, secret, peer, space) or_return
	l.channel.peer = peer
	return true
}

// The peer behind a first message, without committing to anything.
link_answer :: proc(l: ^Link, secret, space: zsp.Key32, packet: []byte) -> bool {
	if len(packet) != FIRST_SIZE || Type(packet[0]) != .First {
		return false
	}
	link_init(l)
	l.state = .Waiting
	l.remote = endian.unchecked_get_u32le(packet[1:])
	copy(l.first[:], packet[5:])
	l.second, l.channel = zsp.handshake_answer(secret, space, packet[5:]) or_return
	return true
}

// Whether a first message is the one this link already answered.
@(require_results)
link_answers :: proc(l: ^Link, packet: []byte) -> bool {
	return l.state == .Waiting && len(packet) == FIRST_SIZE && string(packet[5:]) == string(l.first[:])
}

link_destroy :: proc(l: ^Link) {
	delete(l.out)
	delete(l.lost)
	delete(l.done)
	for d in l.datagrams {
		delete(d)
	}
	delete(l.datagrams)
	delete(l.sent)
	delete(l.seen)
	for e in l.early {
		delete(e.bytes)
	}
	delete(l.early)
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

// How many more stream bytes are worth handing over now.
@(require_results)
link_room :: proc(l: ^Link) -> int {
	if l.state != .Open || l.closing {
		return 0
	}
	// Two windows' worth keeps the pipe full and what is already promised short.
	return clamp(int(l.window) * 2, 16 << 10, SEND_BUFFER) - link_held(l)
}

@(private)
link_held :: proc(l: ^Link) -> int {
	return len(l.out) - l.out_head
}

@(private)
link_sent :: proc(l: ^Link) -> []Sent {
	return l.sent[l.sent_head:]
}

@(private)
link_next :: proc(l: ^Link) -> u64 {
	return l.sent_base + u64(len(l.sent) - l.sent_head)
}

link_write :: proc(l: ^Link, bytes: []byte) {
	append(&l.out, ..bytes)
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

link_close :: proc(l: ^Link) {
	l.closing = true
}

// Processes one packet, decrypting it in place. True when it was genuine: the sender's address is
// then the one to answer.
link_input :: proc(l: ^Link, packet: []byte, now: Time) -> bool {
	if l.state == .Closed || len(packet) < 1 {
		return false
	}
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
		if range_contains(l.seen[:], number) {
			return true
		}
		gap := len(l.seen) > 0 && number != l.seen[len(l.seen) - 1].hi
		range_add(&l.seen, number)
		if len(l.seen) > 32 {
			ordered_remove(&l.seen, 0)
		}
		if link_frames(l, plain, now) {
			l.ack_count += 1
			if l.ack_count >= 2 || gap {
				l.ack_due = now
			} else if l.ack_due == 0 {
				l.ack_due = now + ACK_DELAY
			}
		}
		return true
	}
	return false
}

// Returns whether the packet deserves an acknowledgement.
@(private)
link_frames :: proc(l: ^Link, plain: []byte, now: Time) -> (eliciting: bool) {
	r := zsp.Reader{buf = plain}
	for r.pos < len(r.buf) && !r.bad {
		switch Frame(zsp.read_u8(&r)) {
		case .Pad:
			r.pos = len(r.buf)
		case .Ping:
			eliciting = true
		case .Ack:
			link_acked(l, &r, now)
		case .Stream:
			offset := zsp.read_varint(&r)
			bytes := zsp.read_bytes(&r)
			if !r.bad {
				link_stream(l, offset, bytes)
			}
			eliciting = true
		case .Datagram:
			bytes := zsp.read_bytes(&r)
			if !r.bad && l.on_datagram != nil {
				l.on_datagram(l.data, bytes)
			}
			eliciting = true
		case .Close:
			l.state = .Closed
			return
		case:
			return
		}
	}
	return
}

@(private)
link_stream :: proc(l: ^Link, offset: u64, bytes: []byte) {
	offset, bytes := offset, bytes
	if offset > l.in_limit || offset + u64(len(bytes)) > l.in_limit {
		return // beyond what was permitted
	}
	if offset <= l.in_next {
		skip := min(l.in_next - offset, u64(len(bytes)))
		link_deliver(l, bytes[skip:])
		for len(l.early) > 0 && l.early[0].offset <= l.in_next {
			e := l.early[0]
			ordered_remove(&l.early, 0)
			skip = min(l.in_next - e.offset, u64(len(e.bytes)))
			link_deliver(l, e.bytes[skip:])
			delete(e.bytes)
		}
		return
	}
	at := len(l.early)
	for at > 0 && l.early[at - 1].offset >= offset {
		at -= 1
	}
	if at < len(l.early) && l.early[at].offset == offset && len(l.early[at].bytes) >= len(bytes) {
		return
	}
	copied := make([]byte, len(bytes))
	copy(copied, bytes)
	inject_at(&l.early, at, Early{offset, copied})
}

@(private)
link_deliver :: proc(l: ^Link, bytes: []byte) {
	if len(bytes) == 0 {
		return
	}
	l.in_next += u64(len(bytes))
	l.in_limit = l.in_next + RECV_WINDOW
	if l.on_stream != nil {
		l.on_stream(l.data, bytes)
	}
}

@(private)
link_acked :: proc(l: ^Link, r: ^zsp.Reader, now: Time) {
	largest := zsp.read_varint(r)
	hi := largest + 1
	newest: Time
	any := false
	for i := 0;; i += 1 {
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
				l.mtu = PACKET_MAX
			} else {
				link_measure(l, p, now)
			}
			if p.stream.lo < p.stream.hi {
				range_insert(&l.done, p.stream)
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
	l.out_limit = max(l.out_limit, zsp.read_varint(r))
	if !any {
		return
	}
	l.probes = 0
	if newest != 0 {
		rtt := max(f64(now - newest), 1)
		if !l.acked_any {
			l.srtt, l.rttvar = rtt, rtt / 2
		} else {
			l.rttvar = 0.75 * l.rttvar + 0.25 * abs(l.srtt - rtt)
			l.srtt = 0.875 * l.srtt + 0.125 * rtt
		}
		// Remeasure the empty path now and then, lest a route change go unnoticed.
		if rtt <= l.rtt_min || now - l.rtt_min_at > 10_000 * MS {
			l.rtt_min, l.rtt_min_at = rtt, now
		}
	}
	l.acked_any = true
	l.largest_acked = max(l.largest_acked, largest)
	link_detect_loss(l, now)
	link_model(l, now)

	// Advance past what is wholly acknowledged, moving memory only once half of it is done with.
	if len(l.done) > 0 && l.done[0].lo <= l.out_base {
		l.out_head += int(l.done[0].hi - l.out_base)
		l.out_base = l.done[0].hi
		ordered_remove(&l.done, 0)
		if l.out_head == len(l.out) {
			clear(&l.out)
			l.out_head = 0
			if cap(l.out) > 64 << 10 {
				shrink(&l.out)
			}
		} else if l.out_head > 4096 && l.out_head * 2 > len(l.out) {
			remove_range(&l.out, 0, l.out_head)
			l.out_head = 0
		}
	}
	for l.sent_head < len(l.sent) && l.sent[l.sent_head].time == 0 {
		l.sent_head += 1
		l.sent_base += 1
	}
	if l.sent_head * 2 > len(l.sent) {
		remove_range(&l.sent, 0, l.sent_head)
		l.sent_head = 0
	}
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
	if p.stream.lo < p.stream.hi {
		append(&l.lost, p.stream)
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
			l.ceiling = max(min(l.window, l.ceiling) * 0.7, 4 * PACKET)
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
	l.window = max(min(target, l.ceiling), f64(4 * PACKET))
}

// The next packet to send, or nil. Call until nil after input, writes, or a deadline.
@(require_results)
link_output :: proc(l: ^Link, into: []byte, now: Time) -> []byte {
	if l.state != .Open {
		return nil
	}
	if l.closing {
		l.state = .Closed
		into[HEAD] = byte(Frame.Close)
		return link_seal(l, into, HEAD + 1)
	}
	link_expire(l, now)
	if l.state != .Open {
		return nil
	}

	limit := l.mtu - zsp.TAG
	w := zsp_writer(into[:limit])
	w.pos = HEAD
	eliciting := false
	p: Sent
	if l.ack_due != 0 && (now >= l.ack_due || link_sendable(l)) {
		link_put_ack(l, &w)
	}
	room := l.in_flight + limit < int(l.window) || l.want_probe
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
		p.stream = link_take(l, limit - w.pos - 14)
		if p.stream.lo < p.stream.hi {
			put(&w, byte(Frame.Stream))
			put_varint(&w, p.stream.lo)
			put_varint(&w, p.stream.hi - p.stream.lo)
			put_bytes(&w, l.out[l.out_head:][p.stream.lo - l.out_base:p.stream.hi - l.out_base])
			eliciting = true
		}
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
	if eliciting {
		l.in_flight += len(out)
		l.round_sent += len(out)
		l.last_sent = now
	}
	return out
}

@(private)
link_sendable :: proc(l: ^Link) -> bool {
	return len(l.datagrams) > 0 || len(l.lost) > 0 || l.out_next < min(l.out_base + u64(link_held(l)), l.out_limit)
}

@(private)
link_take :: proc(l: ^Link, n: int) -> (r: Range) {
	for len(l.lost) > 0 {
		r = l.lost[0]
		if r.lo < l.out_base {
			r.lo = l.out_base
		}
		// Skip what a later copy already delivered.
		for d in l.done {
			if d.lo <= r.lo && r.lo < d.hi {
				r.lo = d.hi
			}
		}
		if r.lo >= r.hi {
			ordered_remove(&l.lost, 0)
			continue
		}
		if r.hi - r.lo > u64(n) {
			r.hi = r.lo + u64(n)
			l.lost[0].lo = r.hi
		} else {
			ordered_remove(&l.lost, 0)
		}
		return
	}
	end := min(l.out_base + u64(link_held(l)), l.out_limit)
	if l.out_next < end {
		r = {l.out_next, min(end, l.out_next + u64(n))}
		l.out_next = r.hi
		return
	}
	return {}
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
	l.probes += 1
	if l.probes > MAX_PROBES {
		l.state = .Closed
		return
	}
	l.last_sent = now
	l.want_probe = true
	// Send the oldest unacknowledged bytes again.
	for &p in link_sent(l) {
		if p.time != 0 {
			if p.stream.lo < p.stream.hi {
				inject_at(&l.lost, 0, p.stream)
			}
			l.in_flight -= int(p.size)
			p = {}
			if l.probes > 2 {
				l.window = MIN_WINDOW
			}
			break
		}
	}
}

@(private)
link_timeout :: proc(l: ^Link) -> Time {
	pto := Time(l.srtt + max(4 * l.rttvar, 1000)) + ACK_DELAY
	return l.last_sent + pto << uint(l.probes) + 1
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
link_put_ack :: proc(l: ^Link, w: ^Writer) {
	l.ack_due = 0
	l.ack_count = 0
	put(w, byte(Frame.Ack))
	n := len(l.seen)
	put_varint(w, l.seen[n - 1].hi - 1)
	for i := n - 1;; i -= 1 {
		put_varint(w, l.seen[i].hi - l.seen[i].lo)
		if i == 0 || w.pos > 400 {
			put_varint(w, 0)
			break
		}
		put_varint(w, l.seen[i].lo - l.seen[i - 1].hi)
	}
	put_varint(w, l.in_limit)
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
	if len(rs) == 32 && v < rs[0].lo {
		return true // too old to tell: a replay, or as good as one
	}
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
