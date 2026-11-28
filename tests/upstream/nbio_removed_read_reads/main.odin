// Reproduces core:nbio's kqueue loop reading for a read removed in the tick it was ready (no upstream issue).
// Platform: darwin
// Ours: FIXED
//
// Two reads ready in the same tick, the first removing the second in its callback: the second, removed, reads all the
// same, into a buffer its owner may have let go of, and what was sent for it is gone from the socket.
//
// Prints one line and exits 0: "BROKEN: ..." if the removed read's socket no longer has what was sent it, or
// "FIXED: ..." if it does. Anything else is the repro's own failure. Run by .github/workflows/upstream.yml, through
// tests/upstream/run.sh, against stock core:nbio and against ours.
package nbio_removed_read_reads

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"

Pair :: struct {
	peer, socket: net.TCP_Socket,
	read:         ^nbio.Operation,
	buf:          [16]byte,
	other:        ^Pair,
	called:       bool,
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
	pairs: [2]Pair
	for &p, i in pairs {
		p.peer, _ = net.dial_tcp(at)
		p.socket, _, _ = net.accept_tcp(listener)
		nbio.associate_socket(p.socket)
		p.other = &pairs[1 - i]
	}
	for &p in pairs {
		p.read = nbio.recv_poly(p.socket, {p.buf[:]}, &p, proc(op: ^nbio.Operation, p: ^Pair) {
			p.called = true
			p.read = nil
			if p.other.read != nil {
				nbio.remove(p.other.read)
				p.other.read = nil
			}
		})
	}
	nbio.tick(0)
	for p in pairs { net.send_tcp(p.peer, transmute([]byte)string("there")) }
	time.sleep(20 * time.Millisecond) // both ready, for the same tick
	for _ in 0 ..< 5 { nbio.tick(5 * time.Millisecond) }
	if pairs[0].called == pairs[1].called {
		fmt.eprintfln("the reads called back %v and %v: not one and only one", pairs[0].called, pairs[1].called)
		os.exit(2)
	}
	for &p in pairs {
		if p.called { continue }
		net.set_blocking(p.socket, false)
		b: [16]byte
		n, err := net.recv_tcp(p.socket, b[:])
		kept := err == nil && string(b[:n]) == "there"
		fmt.printfln("%s: the removed read's socket has %q (%d bytes, %v); its buffer holds %q",
			"FIXED" if kept else "BROKEN", string(b[:n]), n, err, string(p.buf[:5]))
	}
}
