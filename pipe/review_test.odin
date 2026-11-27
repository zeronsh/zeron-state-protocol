#+build !js
package pipe

import "core:encoding/endian"
import "core:math/rand"
import "core:testing"
import "../zsp"

// Each a reproduction from adversarial review, kept so that what it found stays found.

@(private)
seal_data_packet :: proc(from: ^Link, number: u64, plain: []byte, dst: []byte) -> []byte {
	dst[0] = u8(Type.Data)
	endian.unchecked_put_u32le(dst[1:], from.remote)
	endian.unchecked_put_u64le(dst[5:], number)
	out := make([dynamic]byte, 0, len(plain) + zsp.TAG, context.temp_allocator)
	zsp.channel_seal_at(&from.channel, &out, number, plain, dst[:HEAD])
	copy(dst[HEAD:], out[:])
	return dst[:HEAD + len(out)]
}

// A packet not wholly taken is no proof that its sender is where it came from, nor its datagrams anything but
// replayed, however often it comes.
@(test)
review_unkept_packet_is_not_newest :: proc(t: ^testing.T) {
	state := rand.create(1)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	datagrams := 0
	n.links[1].data = &datagrams
	n.links[1].on_datagram = proc(l: ^Link, bytes: []byte) {(^int)(l.data)^ += 1}
	plain := []byte{u8(Frame.Datagram), 2, 'h', 'i', u8(Frame.Stream)} // a stream frame cut short
	wire: [PACKET_MAX]byte
	pkt := seal_data_packet(&n.links[0], 1, plain, wire[:])
	buf: [PACKET_MAX]byte
	accepted := 0
	for _ in 0 ..< 3 {
		copy(buf[:len(pkt)], pkt)
		if link_input(&n.links[1], buf[:len(pkt)], n.now) {
			accepted += 1
		}
	}
	testing.expectf(t, accepted == 0, "an unkept packet was newest %d times (datagrams %d)", accepted, datagrams)
}

// The peer may open as many more streams as are done with, whichever they are: one long-lived stream does not
// hold up all the rest.
@(test)
review_stream_limit_with_an_early_stream_open :: proc(t: ^testing.T) {
	state := rand.create(4)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	first, ok0 := link_open(&n.links[0], urgency = 3)
	testing.expect(t, ok0)
	testing.expect(t, link_write(&n.links[0], first, transmute([]byte)string("keepopen")))
	for _ in 0 ..< STREAMS - 1 {
		id, ok := link_open(&n.links[0], urgency = 3)
		testing.expect(t, ok)
		testing.expect(t, link_write(&n.links[0], id, transmute([]byte)string("x")))
		link_finish(&n.links[0], id)
		for _ in 0 ..< 20 {
			if !net_step(&n) {
				break
			}
			if link_has(&n.links[1], id) {
				link_finish(&n.links[1], id)
			}
		}
	}
	for _ in 0 ..< 500 {
		if !net_step(&n) {
			break
		}
	}
	_, ok_next := link_open(&n.links[0], urgency = 3)
	testing.expectf(t, ok_next, "no stream could be opened with one open (opened %v, may %v)", n.links[0].opened, n.links[0].may_open)
}

// A stream whose header says it is bulk, put back to wait for stream 0 when held pieces are many: not lost.
@(test)
review_bulk_header_put_back_is_kept :: proc(t: ^testing.T) {
	state := rand.create(5)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	Recv :: struct {
		got: [dynamic]byte,
	}
	recv: Recv
	defer delete(recv.got)
	n.links[1].data = &recv
	n.links[1].on_stream = proc(l: ^Link, id: u64, bytes: []byte, event: Stream_Event) {
		if id == 2 && event == .Data {
			append(&(^Recv)(l.data).got, ..bytes)
		}
	}
	w := make([dynamic]byte, context.temp_allocator)
	number: u64 = 1
	wire: [PACKET_MAX]byte
	for i := 0; i < MAX_EARLY * 3 / 4 + 5; i += 1 {
		clear(&w)
		append(&w, u8(Frame.Stream))
		zsp.write_varint(&w, 0)
		zsp.write_varint(&w, u64(2 + i * 2))
		zsp.write_bytes(&w, []byte{'a'})
		_ = link_input(&n.links[1], seal_data_packet(&n.links[0], number, w[:], wire[:]), n.now)
		number += 1
	}
	clear(&w)
	append(&w, u8(Frame.Stream))
	zsp.write_varint(&w, 2)
	zsp.write_varint(&w, 100)
	zsp.write_bytes(&w, []byte{'Z'})
	_ = link_input(&n.links[1], seal_data_packet(&n.links[0], number, w[:], wire[:]), n.now)
	number += 1
	clear(&w)
	append(&w, u8(Frame.Stream))
	zsp.write_varint(&w, 2)
	zsp.write_varint(&w, 0)
	zsp.write_bytes(&w, []byte{6, 1, 'H', 'E', 'L', 'L', 'O'})
	_ = link_input(&n.links[1], seal_data_packet(&n.links[0], number, w[:], wire[:]), n.now)
	number += 1
	acked := range_contains(n.links[1].seen[:], number - 1)
	clear(&w)
	append(&w, u8(Frame.Stream))
	zsp.write_varint(&w, 0)
	zsp.write_varint(&w, 0)
	zsp.write_bytes(&w, []byte{'0'})
	_ = link_input(&n.links[1], seal_data_packet(&n.links[0], number, w[:], wire[:]), n.now)
	testing.expectf(t, !acked || string(recv.got[:]) == "HELLO", "acknowledged (%v), and got %q", acked, string(recv.got[:]))
}

// A stream stopped after its end came out of order and was acknowledged: let go of all the same.
@(test)
review_stop_after_an_acknowledged_end :: proc(t: ^testing.T) {
	state := rand.create(6)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	id, ok := link_open(&n.links[0], urgency = 3)
	testing.expect(t, ok)
	payload := make([]byte, 4000, context.temp_allocator)
	testing.expect(t, link_write(&n.links[0], id, payload))
	link_finish(&n.links[0], id)
	pkts: [dynamic][]byte
	defer {
		for p in pkts {
			delete(p)
		}
		delete(pkts)
	}
	for {
		buf: [PACKET_MAX]byte
		out := link_output(&n.links[0], buf[:], n.now)
		if out == nil {
			break
		}
		c := make([]byte, len(out))
		copy(c, out)
		append(&pkts, c)
	}
	for p in pkts[1:] {
		buf: [PACKET_MAX]byte
		copy(buf[:len(p)], p)
		_ = link_input(&n.links[1], buf[:len(p)], n.now)
	}
	n.now += 50 * MS
	for {
		buf: [PACKET_MAX]byte
		out := link_output(&n.links[1], buf[:], n.now)
		if out == nil {
			break
		}
		_ = link_input(&n.links[0], out, n.now)
	}
	link_stop(&n.links[1], id)
	link_finish(&n.links[1], id)
	for _ in 0 ..< 500 {
		if !net_step(&n) {
			break
		}
	}
	testing.expectf(t, !link_has(&n.links[1], id), "stream %v was never let go of", id)
}

// The last packet number there can be is not taken: past it, the range of what was seen would wrap.
@(test)
review_last_packet_number_refused :: proc(t: ^testing.T) {
	state := rand.create(3)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	wire: [PACKET_MAX]byte
	_ = link_input(&n.links[1], seal_data_packet(&n.links[0], max(u64), []byte{u8(Frame.Ping)}, wire[:]), n.now)
	for r in n.links[1].seen {
		testing.expectf(t, r.lo < r.hi, "seen wrapped: %v..%v", r.lo, r.hi)
	}
}

// A packet with a frame not understood is not acknowledged.
@(test)
review_unknown_frame_not_acknowledged :: proc(t: ^testing.T) {
	state := rand.create(2)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	wire: [PACKET_MAX]byte
	_ = link_input(&n.links[1], seal_data_packet(&n.links[0], 1, []byte{0x7f, u8(Frame.Ping)}, wire[:]), n.now)
	testing.expect(t, !range_contains(n.links[1].seen[:], 1), "a packet with an unknown frame was acknowledged")
}

// A timeout is no measure of congestion.
@(test)
review_timeout_is_not_congestion :: proc(t: ^testing.T) {
	state := rand.create(7)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	testing.expect(t, link_write(&n.links[0], 0, transmute([]byte)string("hello")))
	buf: [PACKET_MAX]byte
	testing.expect(t, link_output(&n.links[0], buf[:], n.now) != nil)
	n.now = link_deadline(&n.links[0])
	_ = link_output(&n.links[0], buf[:], n.now)
	testing.expectf(t, n.links[0].round_lost == 0, "a timeout counted as %d bytes lost", n.links[0].round_lost)
}

// A stream that is only its header and its end ends no earlier than stream 0 has delivered what it waits for.
@(test)
review_empty_stream_ends_after_stream_0 :: proc(t: ^testing.T) {
	state := rand.create(8)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	fin_at: u64 = max(u64)
	n.links[1].data = &fin_at
	n.links[1].on_stream = proc(l: ^Link, id: u64, bytes: []byte, event: Stream_Event) {
		if id == 2 && event == .Fin {
			(^u64)(l.data)^ = l.streams[0].in_next
		}
	}
	w := make([dynamic]byte, context.temp_allocator)
	append(&w, u8(Frame.Fin))
	zsp.write_varint(&w, 2)
	zsp.write_varint(&w, 0)
	zsp.write_bytes(&w, []byte{3, 10})
	wire: [PACKET_MAX]byte
	_ = link_input(&n.links[1], seal_data_packet(&n.links[0], 1, w[:], wire[:]), n.now)
	testing.expectf(t, fin_at == max(u64), "its end was told with stream 0 at %v, short of 10", fin_at)
}

// Round 2. Streams the peer has done with, beyond the first it has not, are remembered in runs: however many it opens
// and ends while one stays open, what is kept of them stays small.
@(test)
review_streams_done_with_are_kept_in_runs :: proc(t: ^testing.T) {
	state := rand.create(201)
	context.random_generator = rand.default_random_generator(&state)
	n: Net
	net_init(t, &n)
	defer net_destroy(&n)
	first, ok0 := link_open(&n.links[0], urgency = 3)
	testing.expect(t, ok0)
	testing.expect(t, link_write(&n.links[0], first, transmute([]byte)string("keep")))
	for _ in 0 ..< 4000 {
		id, ok := link_open(&n.links[0], urgency = 3)
		testing.expect(t, ok)
		testing.expect(t, link_write(&n.links[0], id, transmute([]byte)string("x")))
		link_finish(&n.links[0], id)
		for _ in 0 ..< 20 {
			if !net_step(&n) {
				break
			}
			if link_has(&n.links[1], id) {
				link_finish(&n.links[1], id)
			}
		}
	}
	for _ in 0 ..< 500 {
		if !net_step(&n) {
			break
		}
	}
	testing.expectf(t, len(n.links[1].peer_done) <= 2, "%d kept (floor %d, retired %d)", len(n.links[1].peer_done), n.links[1].peer_floor, n.links[1].peer_retired)
	testing.expectf(t, n.links[1].peer_retired >= 3900, "only %d retired", n.links[1].peer_retired)
}

// A link with its handshake done, both ends quiet.
@(private)
review_pair :: proc(t: ^testing.T, a, b: ^Link, now: Time) {
	a_sec := zsp.Key32{0 = 1}
	b_sec := zsp.Key32{0 = 2}
	space := zsp.Key32{0 = 3}
	buf: [PACKET_MAX]byte
	testing.expect(t, link_dial(a, a_sec, zsp.x25519_public(b_sec), space, 1))
	testing.expect(t, link_answer(b, b_sec, space, link_hello(a, buf[:])))
	testing.expect(t, link_input(a, link_hello(b, buf[:]), now))
	review_exchange(a, b, now)
}

// Each end sends what it has, until neither has anything.
@(private)
review_exchange :: proc(a, b: ^Link, now: Time) {
	buf: [PACKET_MAX]byte
	for {
		moved := false
		for p := link_output(a, buf[:], now); len(p) > 0; p = link_output(a, buf[:], now) {
			link_input(b, p, now)
			moved = true
		}
		for p := link_output(b, buf[:], now); len(p) > 0; p = link_output(b, buf[:], now) {
			link_input(a, p, now)
			moved = true
		}
		if !moved {
			return
		}
	}
}

// Round 4. A stream this end opened is of the urgency it gave it, whatever the peer's header says: nor is anything left
// of it in the classes it was scheduled in once it is let go.
@(test)
review_urgency_is_the_openers :: proc(t: ^testing.T) {
	a, b: Link
	defer link_destroy(&a)
	defer link_destroy(&b)
	now: Time = 1000
	review_pair(t, &a, &b, now)
	buf: [PACKET_MAX]byte
	id, ok := link_open(&a, 6)
	testing.expect(t, ok)
	payload := make([]byte, a.mtu - HEAD - zsp.TAG - 38, context.temp_allocator)
	testing.expect(t, link_write(&a, id, payload))
	link_finish(&a, id)
	pkt := link_output(&a, buf[:], now)
	testing.expect(t, len(pkt) > 0)
	testing.expect(t, len(a.classes[6].fresh) + len(a.classes[6].old) > 0)
	testing.expect(t, link_input(&b, pkt, now))
	// The peer answers with another urgency, its end, and word of all it was sent.
	bs := stream_find(&b, id)
	testing.expect(t, bs != nil)
	bs.urgency = 0
	link_finish(&b, id)
	b.ack_due = now
	reply := link_output(&b, buf[:], now)
	testing.expect(t, len(reply) > 0)
	testing.expect(t, link_input(&a, reply, now))
	testing.expectf(t, len(a.classes[6].fresh) == 0 && len(a.classes[6].old) == 0, "a stream let go of is still scheduled (%d, %d)", len(a.classes[6].fresh), len(a.classes[6].old))
	for c in a.classes {
		for s in c.fresh {
			testing.expect(t, stream_find(&a, s.id) == s, "a stream let go of is still scheduled")
		}
		for s in c.old {
			testing.expect(t, stream_find(&a, s.id) == s, "a stream let go of is still scheduled")
		}
	}
}

// Round 4. Packets that only acknowledge are not remembered for ever: a peer that makes this end acknowledge, and
// acknowledges that, leaves nothing growing here.
@(test)
review_acks_alone_are_forgotten :: proc(t: ^testing.T) {
	a, b: Link
	defer link_destroy(&a)
	defer link_destroy(&b)
	now: Time = 1000
	review_pair(t, &a, &b, now)
	buf: [PACKET_MAX]byte
	for _ in 0 ..< 4 {
		now += ACK_DELAY + 1
		review_exchange(&a, &b, now)
	}
	testing.expect_value(t, a.in_flight, 0)
	for _ in 0 ..< 2000 {
		now += 100
		testing.expect(t, link_datagram(&b, []byte{1}))
		pkt := link_output(&b, buf[:], now)
		testing.expect(t, len(pkt) > 0)
		testing.expect(t, link_input(&a, pkt, now))
		for ack := link_output(&a, buf[:], now); len(ack) > 0; ack = link_output(&a, buf[:], now) {
			testing.expect(t, link_input(&b, ack, now))
		}
	}
	testing.expectf(t, len(a.sent) - a.sent_head < 64, "%d remembered", len(a.sent) - a.sent_head)
}

// What a peer says it held an acknowledgement for is a count of microseconds, never negative: one with its top bit set
// neither lengthens the round trip to decades, nor wraps the time a probe is due to before now.
@(test)
review_ack_delay_is_unsigned :: proc(t: ^testing.T) {
	for delay in ([]u64{1 << 63, transmute(u64)i64(-1_000_000_000_000_000), max(u64)}) {
		a, b: Link
		defer link_destroy(&a)
		defer link_destroy(&b)
		now: Time = 1_000_000
		review_pair(t, &a, &b, now)
		buf: [PACKET_MAX]byte
		testing.expect(t, link_write(&a, 0, transmute([]byte)string("hello")))
		testing.expect(t, link_output(&a, buf[:], now) != nil)
		now += 10 * MS
		plain: [64]byte
		w := zsp_writer(plain[:])
		put(&w, u8(Frame.Ack))
		put_varint(&w, link_next(&a) - 1)
		put_varint(&w, delay)
		put_varint(&w, 1)
		put_varint(&w, 0)
		wire: [PACKET_MAX]byte
		testing.expect(t, link_input(&a, seal_data_packet(&b, 1000, plain[:w.pos], wire[:]), now))
		testing.expect(t, link_write(&a, 0, transmute([]byte)string("again")))
		testing.expect(t, link_output(&a, buf[:], now) != nil)
		due := link_deadline(&a)
		testing.expectf(t, a.srtt < 1e6 && due > now && due - now < PROBE_MOST, "delay %x: srtt %v µs, probe due in %v µs", delay, a.srtt, due - now)
	}
}

// A frame about a stream the peer may not have opened is refused, whatever its number: the last there is too, which
// counted from 1 is not the first.
@(test)
review_last_stream_id_refused :: proc(t: ^testing.T) {
	for dialler in ([]bool{true, false}) {
		a, b: Link
		defer link_destroy(&a)
		defer link_destroy(&b)
		now: Time = 1000
		review_pair(t, &a, &b, now)
		to, from := &a, &b
		if !dialler {
			to, from = &b, &a
		}
		plain := []byte{u8(Frame.Stream), 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0, 1, 'x'}
		wire: [PACKET_MAX]byte
		_ = link_input(to, seal_data_packet(from, 1000, plain, wire[:]), now)
		testing.expectf(t, !range_contains(to.seen[:], 1000), "dialler %v: a frame of stream %x was acknowledged", dialler, max(u64))
	}
}
