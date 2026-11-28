package host

import "core:net"
import "core:testing"
import "core:time"
import "../nbio"

// More at once than the event loop can give the system (a full io_uring ring, too many kqueue changes): what it
// holds back is given all the same, without waiting for something else to wake it.
@(test)
loop_gives_what_it_held_back :: proc(t: ^testing.T) {
	testing.expect(t, nbio.acquire_thread_event_loop() == nil)
	defer nbio.release_thread_event_loop()
	listener, err := net.listen_tcp({net.IP4_Loopback, 0}, 4096)
	testing.expect(t, err == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	// Sockets that say nothing, each polled: the operations that fill what the loop gives the system, and stay.
	// More than io_uring's ring holds, as the tests build it (256), on Linux; elsewhere fewer, within what the system
	// lets wait to be accepted and a test may have open, each accepted as it comes.
	IDLE :: 300 when ODIN_OS == .Linux else 60
	idle, accepted: [IDLE]net.TCP_Socket
	polls: [IDLE]^nbio.Operation
	for &s, i in idle {
		s, err = net.dial_tcp(at)
		testing.expect(t, err == nil)
		accepted[i], _, _ = net.accept_tcp(listener)
	}
	defer for s, i in idle {
		net.close(s)
		net.close(accepted[i])
	}
	for s, i in idle {
		polls[i] = nbio.poll_poly(s, .Receive, &polls[i], proc(op: ^nbio.Operation, p: ^^nbio.Operation) {
			p^ = nil
		})
	}
	defer for p in polls {
		if p != nil {
			nbio.remove(p)
		}
	}
	// And then one more, which nothing else will wake the loop for.
	dialled := false
	nbio.dial_poly(at, &dialled, proc(op: ^nbio.Operation, d: ^bool) {
		d^ = true
		if op.dial.err == nil {
			net.close(op.dial.socket)
		}
	}, timeout = 10 * time.Second)
	start := time.tick_now()
	for !dialled && time.tick_since(start) < 20 * time.Second {
		wait := time.Second // as host_run waits, but never for ever
		if loop_held_back() {
			wait = 0
		}
		testing.expect(t, nbio.tick(wait) == nil)
	}
	took := time.tick_since(start)
	testing.expectf(t, dialled && took < 900 * time.Millisecond, "took %v: what was held back waited for a wake", took)
	for _ in 0 ..< 3 {
		nbio.tick(0)
	}
}
