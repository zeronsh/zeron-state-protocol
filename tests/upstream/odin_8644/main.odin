// Reproduces odin-lang/Odin#8644: on Windows, core:nbio's read or write of a connection its peer reset never ends.
//
// WSARecv and WSASend fail as they are made on such a connection, and leave the OVERLAPPED's Internal at
// STATUS_PENDING; no completion is ever queued for them. core:nbio took that for a call under way, and waited for ever.
// Here a connection's peer closes with what it was sent unread, and lingering for no time, either of which has the close
// go out as a reset (RST), not an end (FIN); and a read and then a write are made of it with core:nbio, each given 5 s
// to end.
//
// Prints one line and exits 0: "BROKEN: ..." if either never ended, or "FIXED: ..." if both ended, one at least with an
// error. If both ended with none, the connection was ended rather than reset, and that shows nothing: it exits 2, as it
// does for anything else that is the repro's own failure (a connection that could not be made, a crash). Meaningful on
// Windows, where it is run; elsewhere both end.
//
// Run by .github/workflows/upstream.yml, not by ./x test; tests/upstream/run.sh runs it. The copy third_party/nbio is
// dropped once a release has this fixed, with odin-lang/Odin#8642, #8645 and #8647.
package odin_8644

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"

Done :: struct {
	done:   bool,
	n:      int,
	err:    string,
	failed: bool,
}

wait :: proc(d: ^Done) {
	start := time.tick_now()
	for !d.done && time.tick_since(start) < 5 * time.Second {
		if err := nbio.tick(10 * time.Millisecond); err != nil {
			fmt.eprintln("tick failed:", err)
			os.exit(2)
		}
	}
}

must :: proc(ok: bool, what: string, err: any) {
	if !ok {
		fmt.eprintln(what, "failed:", err)
		os.exit(2)
	}
}

main :: proc() {
	lerr := nbio.acquire_thread_event_loop()
	must(lerr == nil, "acquire_thread_event_loop", lerr)
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	must(err == nil, "listen", err)
	at, _ := net.bound_endpoint(listener)
	peer, derr := net.dial_tcp(at)
	must(derr == nil, "dial", derr)
	s, _, aerr := net.accept_tcp(listener)
	must(aerr == nil, "accept", aerr)
	serr := nbio.associate_socket(s)
	must(serr == nil, "associate_socket", serr)

	// The peer closes with what it was sent unread, and lingering for no time: the connection is reset.
	_, werr := net.send_tcp(s, transmute([]byte)string("unread"))
	must(werr == nil, "send", werr)
	time.sleep(50 * time.Millisecond)
	lerr2 := net.set_option(peer, .Linger, time.Duration(0))
	must(lerr2 == nil, "set_option(.Linger, 0)", lerr2)
	net.close(peer)
	time.sleep(50 * time.Millisecond)

	buf: [64]byte
	r, w: Done
	nbio.recv_poly(s, {buf[:]}, &r, proc(op: ^nbio.Operation, d: ^Done) {
		d^ = {true, op.recv.received, fmt.aprint(op.recv.err), op.recv.err != nil}
	})
	wait(&r)
	nbio.send_poly(s, {buf[:]}, &w, proc(op: ^nbio.Operation, d: ^Done) {
		d^ = {true, op.send.sent, fmt.aprint(op.send.err), op.send.err != nil}
	})
	wait(&w)
	said :: proc(d: Done) -> string {
		return fmt.tprintf("ended, %d bytes, error %s", d.n, d.err) if d.done else "NOT ENDED after 5 s"
	}
	if r.done && w.done && !r.failed && !w.failed {
		fmt.eprintfln("inconclusive: the read %s, the write %s, neither failing: the connection was ended, not reset", said(r), said(w))
		os.exit(2)
	} else if r.done && w.done {
		fmt.printfln("FIXED: on a reset connection the read %s, the write %s", said(r), said(w))
	} else {
		fmt.printfln("BROKEN: on a reset connection the read %s, the write %s", said(r), said(w))
	}
}
