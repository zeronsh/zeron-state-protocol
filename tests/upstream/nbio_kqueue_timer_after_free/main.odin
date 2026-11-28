// Reproduces core:nbio's kqueue loop handing back an operation it freed, whose timer kqueue still had (no upstream
// issue).
// Platform: darwin
// Crash: BROKEN
// Ours: FIXED
//
// An operation with a timeout is done while the changes held for kqueue have overflowed what one call gives it, and
// its timer is due before the call that would delete it: cleanup puts the operation back in its pool at once, and the
// timer, firing, hands the loop an operation freed: `assert(op.type != .None)`. Built with
// -define:ODIN_NBIO_QUEUE_SIZE=256, as tests/upstream/run.sh builds every repro; any size shows it.
//
// Prints one line and exits 0: "FIXED: ..." if the read and every timeout came. A crash, as stock core:nbio ends with
// (that assertion), is BROKEN. Run by .github/workflows/upstream.yml, through tests/upstream/run.sh, against stock
// core:nbio and against ours.
package nbio_kqueue_timer_after_free

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"

State :: struct {
	read, later: int,
}
N :: 3 * #config(ODIN_NBIO_QUEUE_SIZE, 2048) + 7

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}
	context.logger.lowest_level = .Error // the loop warns of each change it holds back
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	if lerr != nil {
		fmt.eprintln("listen failed:", lerr)
		os.exit(2)
	}
	at, _ := net.bound_endpoint(listener)
	peer, _ := net.dial_tcp(at)
	socket, _, _ := net.accept_tcp(listener)
	nbio.associate_socket(socket)
	s: State
	buf: [64]byte
	nbio.recv_poly(socket, {buf[:]}, &s, proc(op: ^nbio.Operation, s: ^State) {
		s.read = op.recv.received
		for _ in 0 ..< N { // more changes than one kevent call takes
			nbio.timeout_poly(50 * time.Millisecond, s, proc(_: ^nbio.Operation, s: ^State) { s.later += 1 })
		}
		time.sleep(350 * time.Millisecond) // and the read's timer due before that call
	}, timeout = 300 * time.Millisecond)
	nbio.tick(0)
	net.send_tcp(peer, {1, 2, 3})
	start := time.tick_now()
	for s.later < N && time.tick_since(start) < 5 * time.Second {
		nbio.tick(0)
	}
	if s.read != 3 || s.later != N {
		fmt.eprintfln("read %d bytes; %d of %d timeouts came", s.read, s.later, N)
		os.exit(2)
	}
	fmt.printfln("FIXED: read 3 bytes; %d of %d timeouts came", s.later, N)
}
