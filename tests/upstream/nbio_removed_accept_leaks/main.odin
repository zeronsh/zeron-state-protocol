// Reproduces core:nbio leaving open what a removed accept accepted (no upstream issue).
// Platform: linux, darwin
// Ours: FIXED
//
// An accept removed after the system has accepted for it: nobody is handed what was accepted, and nobody closes it,
// so the peer is never told its connection has gone. On kqueue the loop accepts for the removed operation in the tick
// it was ready; on io_uring the kernel accepted before the removal took.
//
// Prints one line and exits 0: "BROKEN: ..." if the peer's read waited out 2 s (the connection left open), or
// "FIXED: ..." if it saw an end or a reset. Anything else is the repro's own failure. Run by
// .github/workflows/upstream.yml, through tests/upstream/run.sh, against stock core:nbio and against ours.
package nbio_removed_accept_leaks

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}
	listener, lerr := nbio.listen_tcp({net.IP4_Loopback, 0})
	if lerr != nil {
		fmt.eprintln("listen failed:", lerr)
		os.exit(2)
	}
	at, _ := net.bound_endpoint(listener)
	called := false
	accepting := nbio.accept_poly(listener, &called, proc(op: ^nbio.Operation, called: ^bool) {
		called^ = true
		if op.accept.err == nil { net.close(op.accept.client) }
	})
	nbio.tick(0) // given to the system
	peer, derr := net.dial_tcp(at)
	if derr != nil {
		fmt.eprintln("dial failed:", derr)
		os.exit(2)
	}
	time.sleep(20 * time.Millisecond) // accepted there
	nbio.remove(accepting)
	for _ in 0 ..< 10 { nbio.tick(5 * time.Millisecond) }
	net.close(listener)
	for _ in 0 ..< 3 { nbio.tick(0) }
	if called {
		fmt.eprintln("a removed accept called back")
		os.exit(2)
	}
	net.set_option(peer, .Receive_Timeout, 2 * time.Second)
	b: [8]byte
	n, err := net.recv_tcp(peer, b[:])
	open := err == .Timeout || err == .Would_Block // what core:net says of SO_RCVTIMEO run out
	fmt.printfln("%s: the peer of a removed accept read %d bytes, %v", "BROKEN" if open else "FIXED", n, err)
}
