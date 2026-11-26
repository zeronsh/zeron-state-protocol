package host

import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import "../pipe"
import "../zsp"

// The public says all it will before the connection to the port is made: the port is told so once it is.
@(test)
public_end_before_connected :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	ts: Test_Space
	test_space(t, &ts)
	defer test_space_destroy(&ts)
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	ts.space.ports = new(Ports)
	ts.space.ports.space = &ts.space
	defer ports_close(&ts.space)
	defer delete(ts.space.bridges)
	p := ts.space.ports

	append(&p.exposures, Exposure{port = u16(e.port), label = strings.clone("end-early")})
	first := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&first, transmute([]byte)string("end-early"))
	from := pipe.address_v4(192, 0, 2, 1, 4000)
	append(&first, ..from.ip[:])
	append(&first, 0x0f, 0xa0)
	h, fault := public_called(&ts.space, 99, {relay = true}, 0, first[:])
	testing.expect(t, h != nil && fault == {})
	c := (^Public_In)(h)
	c.on_end(&c.handler, c.call) // before the dial is done
	for i := 0; i < 200 && (c.forward == nil || !c.forward.shut); i += 1 {
		nbio.tick(10 * time.Millisecond)
	}
	// The port has been told (with no call behind this one, nothing comes back to end it: so it is cut off).
	testing.expect(t, c.forward != nil && c.forward.shut)
	if c.forward != nil {
		forward_close(c.forward)
	}
	for i := 0; i < 50 && len(p.public) > 0; i += 1 {
		nbio.tick(10 * time.Millisecond)
	}
	testing.expect_value(t, len(p.public), 0)
}

// A 40 Expose that is not sound throughout changes nothing at the relay: not what it held, not partly what was asked.
@(test)
expose_frame_whole_or_not_at_all :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts)
	defer test_space_destroy(&ts)
	ts.host.expose = "expose.test"
	ts.host.public.have_http = true
	defer {
		for l in ts.host.public.labels {
			delete(l.label)
		}
		delete(ts.host.public.labels)
	}
	s: zsp.Session
	s.id, s.peer, s.node = 7, ts.keys[1].device, &ts.space.node
	defer delete(s.out)
	frame :: proc(prefixes: ..string) -> []byte {
		w := make([dynamic]byte, context.temp_allocator)
		zsp.write_varint(&w, u64(len(prefixes)))
		for p, i in prefixes {
			zsp.write_bytes(&w, transmute([]byte)p)
			nonce: [zsp.EXPOSE_NONCE]byte
			nonce[0] = byte(i + 1)
			append(&w, ..nonce[:])
		}
		return w[:]
	}
	public_exposed(&ts.space, &s, frame("web"))
	testing.expect_value(t, len(ts.host.public.labels), 1)
	held := strings.clone(ts.host.public.labels[0].label, context.temp_allocator)
	for bad in ([][]byte{frame("ok", "BAD"), frame("ok", strings.repeat("x", 21, context.temp_allocator))}) {
		public_exposed(&ts.space, &s, bad)
		testing.expectf(t, len(ts.host.public.labels) == 1 && ts.host.public.labels[0].label == held, "%d labels, the first %q", len(ts.host.public.labels), ts.host.public.labels[0].label if len(ts.host.public.labels) > 0 else "")
	}
	trailing := make([dynamic]byte, context.temp_allocator)
	append(&trailing, ..frame("ok"))
	append(&trailing, 0)
	public_exposed(&ts.space, &s, trailing[:])
	testing.expect(t, len(ts.host.public.labels) == 1 && ts.host.public.labels[0].label == held)
}

// What a device's connection through an offer marked proxy says first is in temporary memory, as the host's
// proxy_prelude is to give it: whoever asks copies it, and nothing of it is left behind.
@(test)
proxy_prelude_is_temporary :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts, {"", "desk", ""})
	defer test_space_destroy(&ts)
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	header: []byte
	{
		context.allocator = mem.tracking_allocator(&track)
		header = port_proxy_header(&ts.space, ts.keys[1].device, 8080)
	}
	testing.expect(t, len(header) > 16 && string(header[:12]) == "\r\n\r\n\x00\r\nQUIT\n")
	testing.expect_value(t, len(track.allocation_map), 0)
}

// A space closes with a connection from the public joined to its port: let go once, by its bridge, and nothing of
// it touched after.
@(test)
public_closed_with_its_space :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	{
		testing.expect(t, nbio.acquire_thread_event_loop() == nil)
		defer nbio.release_thread_event_loop()
		ts: Test_Space
		test_space(t, &ts)
		defer test_space_destroy(&ts)
		e: Echo
		testing.expect(t, echo_start(&e))
		defer echo_stop(&e)
		ts.space.ports = new(Ports)
		ts.space.ports.space = &ts.space
		p := ts.space.ports
		append(&p.exposures, Exposure{port = u16(e.port), label = strings.clone("closing")})
		first := make([dynamic]byte, context.temp_allocator)
		zsp.write_bytes(&first, transmute([]byte)string("closing"))
		from := pipe.address_v4(192, 0, 2, 1, 4000)
		append(&first, ..from.ip[:])
		append(&first, 0x0f, 0xa0)
		h, _ := public_called(&ts.space, 99, {relay = true}, 0, first[:])
		c := (^Public_In)(h)
		for i := 0; i < 200 && c.forward == nil; i += 1 {
			nbio.tick(10 * time.Millisecond)
		}
		testing.expect(t, c.forward != nil)
		ports_close(&ts.space) // as space_close does: ports, then bridges
		bridges_close(&ts.space)
		for _ in 0 ..< 5 {
			nbio.tick(0)
		}
	}
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad frees", len(track.bad_free_array))
}

// What is written to a public that reads slowly goes from what is kept as it is written, not only once all of it is:
// else what this end adds while it waits (TLS's KeyUpdates) would pile up for ever behind what has gone.
@(test)
public_out_kept_written_goes :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	reader, derr := net.dial_tcp(at)
	testing.expect(t, derr == nil)
	defer net.close(reader)
	socket, _, aerr := net.accept_tcp(listener)
	testing.expect(t, aerr == nil)
	net.set_blocking(socket, false)
	h: Host
	c := new(Public_Out)
	c.h, c.socket = &h, socket
	defer {
		if c.writing != nil {
			nbio.remove(c.writing)
		}
		if c.stall != nil {
			nbio.remove(c.stall)
		}
		net.close(socket)
		delete(c.out)
		free(c)
	}
	block := make([]byte, 1 << 20, context.temp_allocator)
	added := 0
	for _ in 0 ..< 32 {
		append(&c.out, ..block)
		added += len(block)
		if c.writing != nil {
			nbio.remove(c.writing)
			c.writing = nil
		}
		public_out_flush(c)
		// The reader takes some, as a slow one does.
		buf: [256 << 10]byte
		net.set_option(reader, .Receive_Timeout, 50 * time.Millisecond)
		net.recv_tcp(reader, buf[:])
	}
	// Of what is kept, what has been written is never more than a little.
	testing.expectf(t, c.sent < 64 << 10, "kept %d already written (of %d kept, %d added)", c.sent, len(c.out), added)
	testing.expect(t, len(c.out) < added) // and some has been written
}

// A space closes while a device is kept up with what it is offered: the watch's call goes first, and nothing of the
// watch is touched once it is freed.
@(test)
watch_closed_with_its_space :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	{
		ts: Test_Space
		test_space(t, &ts)
		defer test_space_destroy(&ts)
		ts.space.ports = new(Ports)
		ts.space.ports.space = &ts.space
		first := make([dynamic]byte, context.temp_allocator)
		zsp.write_varint(&first, 600)
		h, fault := ports_called(&ts.space, 77, {device = ts.keys[1].device}, 1, first[:])
		testing.expect(t, h != nil && fault == {})
		append(&ts.space.calls, Host_Call{call = 77, handler = h})
		ports_close(&ts.space) // as space_close does: ports, then calls
		calls_close(&ts.space)
	}
	testing.expectf(t, len(track.bad_free_array) == 0, "%d bad frees", len(track.bad_free_array))
}

// A space closes while a refused connection's reply is still being drained: the connection is let go with it, not
// waited on for ever.
@(test)
bridges_close_lets_go_of_the_refused :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	ts: Test_Space
	test_space(t, &ts)
	defer test_space_destroy(&ts)
	ln, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	defer net.close(ln)
	at, _ := net.bound_endpoint(ln)
	client, cerr := net.dial_tcp(at)
	testing.expect(t, cerr == nil)
	defer net.close(client)
	accepted, _, aerr := net.accept_tcp(ln)
	testing.expect(t, aerr == nil)
	f := bridge(&ts.space, 0, accepted)
	testing.expect(t, f != nil)
	if f == nil {
		return
	}
	forward_reject(f, transmute([]byte)string("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n"))
	buf: [256]byte
	n, _ := net.recv_tcp(client, buf[:]) // the reply is read, and the client stays: the refused is drained
	testing.expect(t, n > 0)
	testing.expect_value(t, len(ts.space.bridges), 1)
	bridges_close(&ts.space) // as space_close does
	testing.expect_value(t, len(ts.space.bridges), 0)
	n, _ = net.recv_tcp(client, buf[:])
	testing.expect_value(t, n, 0) // and closed
}

// What a relay says of an exposure is kept only as a relay would say it (a URL of its own, not megabytes), and only
// while this device is linked to that relay.
@(test)
exposures_heard_bounded :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts)
	defer test_space_destroy(&ts)
	ts.space.ports = new(Ports)
	ts.space.ports.space = &ts.space
	defer ports_close(&ts.space)
	p := ts.space.ports
	append(&p.exposures, Exposure{port = 8080, label = strings.clone("app-demo")})
	say :: proc(sp: ^Space, relay: byte, url: string) {
		s := zsp.Session{peer_relay = true}
		s.peer[0] = relay
		w := make([dynamic]byte, context.temp_allocator)
		zsp.write_varint(&w, 1)
		zsp.write_bytes(&w, transmute([]byte)string("app-demo"))
		append(&w, 0)
		zsp.write_bytes(&w, transmute([]byte)url)
		exposures_heard(sp, &s, w[:])
	}
	say(&ts.space, 1, strings.repeat("x", 265_000, context.temp_allocator))
	say(&ts.space, 2, "javascript:alert(1)")
	testing.expect_value(t, len(p.exposures[0].heard), 0)
	for i in 1 ..= 40 {
		say(&ts.space, byte(i), "https://app-demo.expose.test")
	}
	testing.expect_value(t, len(p.exposures[0].heard), 16) // MAX_HEARD
	exposures_tell(p) // and none of those relays is linked to this device
	testing.expect_value(t, len(p.exposures[0].heard), 0)
}

// A device back on a new session, while the relay still has its last, exposes what it exposes: its own label is not
// taken from it, and the last session's going takes nothing of it.
@(test)
public_exposed_by_a_device_come_back :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts)
	defer test_space_destroy(&ts)
	ts.host.expose = "expose.test"
	ts.host.public.have_http = true
	ts.host.expose_http = net.Endpoint{net.IP4_Loopback, 8080}
	defer {
		for l in ts.host.public.labels {
			delete(l.label)
		}
		delete(ts.host.public.labels)
	}
	frame := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&frame, 1)
	zsp.write_bytes(&frame, transmute([]byte)string("app"))
	append(&frame, ..make([]byte, zsp.EXPOSE_NONCE, context.temp_allocator))
	status_of :: proc(s: ^zsp.Session) -> u8 {
		r := zsp.Reader{buf = s.out[:]}
		body := zsp.read_take(&r, int(zsp.read_varint(&r)))
		b := zsp.Reader{buf = body[1:]}
		_ = zsp.read_varint(&b)
		_ = zsp.read_bytes(&b)
		return zsp.read_u8(&b)
	}
	last, now: zsp.Session
	last.id, last.peer, last.node = 10, ts.keys[1].device, &ts.space.node
	now.id, now.peer, now.node = 11, ts.keys[1].device, &ts.space.node
	defer delete(last.out)
	defer delete(now.out)
	public_exposed(&ts.space, &last, frame[:])
	testing.expect_value(t, status_of(&last), 0)
	public_exposed(&ts.space, &now, frame[:])
	testing.expect_value(t, status_of(&now), 0) // its own, not taken
	public_session_closed(&ts.host, &ts.space, last.id)
	testing.expect_value(t, len(ts.host.public.labels), 1)
	if len(ts.host.public.labels) == 1 {
		testing.expect_value(t, ts.host.public.labels[0].session, now.id)
	}
}
