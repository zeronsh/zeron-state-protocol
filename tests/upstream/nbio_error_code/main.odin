// Reproduces core:nbio keeping no system error code with an operation (no upstream issue).
// Platform: windows
//
// A failed operation's error keeps only a category: what the system said of it is not kept, and the last error read
// in the callback is whatever the system said last, which on Windows is the loop's own wait's. Here a dial of a port
// nothing listens at is refused, WSAECONNREFUSED (10061), and its callback reads the last error.
//
// Prints one line and exits 0: "BROKEN: ..." if the callback cannot tell 10061, or "FIXED: ..." if it can. Anything
// else is the repro's own failure. Our nbio keeps the code with the operation instead (Operation.system_error), so this
// is run against stock core:nbio only. Run by .github/workflows/upstream.yml, through tests/upstream/run.sh.
#+build windows
package nbio_error_code

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:time"
import win "core:sys/windows"

Dial :: struct {
	done: bool,
	err:  net.Network_Error,
	last: int,
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
	net.close(listener) // a port nothing listens at
	d: Dial
	nbio.dial_poly(at, &d, proc(op: ^nbio.Operation, d: ^Dial) {
		d^ = {true, op.dial.err, int(win.WSAGetLastError())}
		if op.dial.err == nil {
			net.close(op.dial.socket)
		}
	})
	start := time.tick_now()
	for !d.done && time.tick_since(start) < 10 * time.Second {
		nbio.tick(10 * time.Millisecond)
	}
	if !d.done || d.err == nil {
		fmt.eprintfln("the dial of a port nothing listens at ended %v, with %v", d.done, d.err)
		os.exit(2)
	}
	fmt.printfln("%s: a refused dial ended with %v; the last error read in its callback was %d, the refusal 10061",
		"FIXED" if d.last == 10061 else "BROKEN", d.err, d.last)
}
