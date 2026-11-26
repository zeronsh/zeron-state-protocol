package host

import "core:testing"
import "../pipe"
import "../zsp"

// Each a reproduction from adversarial review, kept so that what it found stays found.

// A local client of a space's node, let in with these grants.
@(private)
open_local_session :: proc(t: ^testing.T, sp: ^Space, space: zsp.Key32, grants: []zsp.Grant) -> ^zsp.Session {
	grants := grants
	sp.node.host.authenticate = proc(data: rawptr, s: ^zsp.Session, _: []byte) {
		zsp.session_accept(s, (^[]zsp.Grant)(context.user_ptr)^)
	}
	context.user_ptr = &grants
	local := zsp.session_open(&sp.node, .Open, false)
	hello := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&hello, .Hello)
	append(&hello, zsp.VERSION, 0)
	space := space
	append(&hello, ..space[:])
	zsp.write_varint(&hello, 0)
	zsp.write_bytes(&hello, nil)
	zsp.frame_end(&hello, at)
	testing.expect(t, zsp.session_input(local, hello[:]))
	sp.node.host.authenticate = space_authenticate
	zsp.session_sent(local, len(zsp.session_output(local)))
	return local
}

// A local client's call, as frames.
@(private)
local_call :: proc(local: ^zsp.Session, id: u64, device: zsp.Key32, scope: zsp.Scope, method: string, first: []byte, urgency: u8 = zsp.URGENCY) -> bool {
	cf := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&cf, .Call)
	zsp.write_varint(&cf, id)
	device := device
	append(&cf, ..device[:])
	zsp.write_varint(&cf, u64(scope))
	zsp.write_bytes(&cf, transmute([]byte)method)
	zsp.write_bytes(&cf, nil)
	zsp.write_u8(&cf, urgency)
	append(&cf, ..first)
	zsp.frame_end(&cf, at)
	return zsp.session_input(local, cf[:])
}

// A knock through a relay is heard once: a newer one from the same device neither disturbs a live link nor is stood in
// the way of by it, and an old one heard again opens nothing.
@(test)
review_relayed_knocks :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	b := world_space(&w, 2)
	l1: pipe.Link
	defer pipe.link_destroy(&l1)
	testing.expect(t, pipe.link_dial(&l1, w.hosts[1].secret, w.keys[2].device, w.space, 100))
	first1_buf: [pipe.FIRST_SIZE]byte
	first1 := pipe.link_hello(&l1, first1_buf[:])
	saved1 := make([]byte, len(first1))
	defer delete(saved1)
	copy(saved1, first1)
	relayed_input(b, 0, w.keys[1].device, first1)
	testing.expect_value(t, len(b.relayed), 1)
	orig := b.relayed[0]
	// Answered, and heard from over it: a live link.
	second_buf: [pipe.SECOND_SIZE + pipe.FIRST_SIZE]byte
	testing.expect(t, pipe.link_input(&l1, pipe.link_hello(orig.link, second_buf[:]), now_us()))
	testing.expect(t, pipe.link_write(&l1, 0, transmute([]byte)string("hello")))
	out_buf: [RELAY_PACKET]byte
	packet := pipe.link_output(&l1, out_buf[:], now_us())
	testing.expect(t, packet != nil)
	relayed_input(b, 0, w.keys[1].device, packet)
	testing.expect(t, orig.proven, "the link was not heard from")
	l2: pipe.Link
	defer pipe.link_destroy(&l2)
	testing.expect(t, pipe.link_dial(&l2, w.hosts[1].secret, w.keys[2].device, w.space, 200))
	first2_buf: [pipe.FIRST_SIZE]byte
	first2 := pipe.link_hello(&l2, first2_buf[:])
	relayed_input(b, 0, w.keys[1].device, first2)
	still := false
	for r in b.relayed {
		still ||= r == orig
	}
	for len(b.relayed) > 0 {
		relayed_drop(pop(&b.relayed))
	}
	relayed_input(b, 0, w.keys[1].device, saved1)
	replayed := len(b.relayed) > 0
	testing.expectf(t, still && !replayed, "the live link stayed %v; an old knock was heard again %v", still, replayed)
}

// However many knocks come through a relay from one device, they open one link at a time, not one each.
@(test)
review_knocks_open_one_link_at_a_time :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	b := world_space(&w, 2)
	relay_id := b.node.sessions[0].id
	wire: [pipe.FIRST_SIZE]byte
	for i in 0 ..< 200 {
		client: pipe.Link
		testing.expect(t, pipe.link_dial(&client, w.hosts[1].secret, w.keys[2].device, w.space, u64(i + 1)))
		relayed_input(b, relay_id, w.keys[1].device, pipe.link_hello(&client, wire[:]))
		pipe.link_destroy(&client)
	}
	testing.expectf(t, len(b.relayed) <= 2, "%d links for one device", len(b.relayed))
}
