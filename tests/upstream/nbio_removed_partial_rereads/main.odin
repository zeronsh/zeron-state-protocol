// Reproduces core:nbio's io_uring loop reading again for a read of all whose removal has been asked for (no upstream
// issue).
// Platform: linux
// Ours: FIXED
//
// A read of all of 10 bytes, 5 of which the kernel has read for it, is removed before the loop hears of the 5: when
// it does, it gives the ring the read again for the rest, after its removal was asked for, and with 5 more already
// there it reads them at once, into a buffer its owner may have let go of, for nobody.
//
// Prints one line and exits 0: "BROKEN: ..." if what was sent after the removal is gone from the socket, or
// "FIXED: ..." if it is there. Anything else is the repro's own failure. Run by .github/workflows/upstream.yml, through
// tests/upstream/run.sh, against stock core:nbio and against ours.
package nbio_removed_partial_rereads

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
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	if lerr != nil {
		fmt.eprintln("listen failed:", lerr)
		os.exit(2)
	}
	at, _ := net.bound_endpoint(listener)
	peer, _ := net.dial_tcp(at)
	socket, _, _ := net.accept_tcp(listener)
	nbio.associate_socket(socket)
	called := false
	buf: [10]byte
	reading := nbio.recv_poly(socket, {buf[:]}, &called, proc(_: ^nbio.Operation, called: ^bool) { called^ = true }, all = true)
	nbio.tick(0)
	net.send_tcp(peer, {1, 2, 3, 4, 5})
	time.sleep(20 * time.Millisecond)
	nbio.remove(reading)
	later := "later"
	net.send_tcp(peer, transmute([]byte)later)
	time.sleep(20 * time.Millisecond)
	for _ in 0 ..< 5 { nbio.tick(5 * time.Millisecond) }
	if called {
		fmt.eprintln("a removed read called back")
		os.exit(2)
	}
	net.set_blocking(socket, false)
	b: [16]byte
	got := 0
	for got < len(b) {
		n, rerr := net.recv_tcp(socket, b[got:])
		if rerr != nil || n == 0 { break }
		got += n
	}
	kept := got >= len(later) && string(b[got - len(later):got]) == later
	fmt.printfln("%s: what was sent after a removed read of all: the socket has %q", "FIXED" if kept else "BROKEN", string(b[:got]))
}
