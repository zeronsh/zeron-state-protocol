package host

import "core:nbio"
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
