// Reproduces core:nbio linking a second timeout over an operation's first (no upstream issue).
// Platform: windows
// Crash: BROKEN
// Ours: FIXED
//
// A receive of all, with a timeout, that comes in two pieces is executed again for the rest, and link_timeout links it
// a second timeout in the first's place: the first, left in the tree, fires at the operation once it is done with,
// and fails `assert(target._impl.timeout == op)`.
//
// Prints one line and exits 0: "FIXED: ..." if the read ended with all of it and nothing fired at it past its timeout.
// A crash, as stock core:nbio ends with (that assertion), is BROKEN. Run by .github/workflows/upstream.yml, through
// tests/upstream/run.sh, against stock core:nbio and against ours.
package nbio_second_timeout

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"

Read :: struct {
	done, error: bool,
	n:           int,
}

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	if lerr != nil {
		fmt.eprintln("listen failed:", lerr)
		os.exit(2)
	}
	at, _ := net.bound_endpoint(listener)
	peer, _ := net.dial_tcp(at)
	socket, _, _ := net.accept_tcp(listener)
	nbio.associate_socket(socket)
	r: Read
	buf: [10]byte
	submitted := time.tick_now()
	nbio.recv_poly(socket, {buf[:]}, &r, proc(op: ^nbio.Operation, r: ^Read) {
		r^ = {true, op.recv.err != nil, op.recv.received}
	}, all = true, timeout = time.Second)
	nbio.tick(0)
	net.send_tcp(peer, {1, 2, 3, 4, 5})
	for _ in 0 ..< 5 {
		nbio.tick(10 * time.Millisecond)
	}
	net.send_tcp(peer, {6, 7, 8, 9, 10})
	for !r.done && time.tick_since(submitted) < 2 * time.Second {
		nbio.tick(10 * time.Millisecond)
	}
	if !r.done || r.error || r.n != 10 {
		fmt.eprintfln("the read of all ended %v, with an error %v, %d bytes", r.done, r.error, r.n)
		os.exit(2)
	}
	for time.tick_since(submitted) < 1300 * time.Millisecond {
		nbio.tick(10 * time.Millisecond)
	}
	fmt.println("FIXED: a read of all in two pieces ended with all of it, and nothing fired at it past its timeout")
}
