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
