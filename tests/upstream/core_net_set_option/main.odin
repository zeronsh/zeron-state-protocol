// Reproduces core:net's set_option setting integer and bool options to the bytes of a pointer (no upstream issue).
// Platform: linux, darwin, windows
//
// _set_option's type switch lists several types in one case (`case i8, u8:` ... `case int, uint:`, `case bool, b8:`),
// where the value stays an `any`, and copies the low bytes of that any's data pointer into the option rather than the
// value. Here TCP_NODELAY is set off, then on, then off, and a receive buffer of 4 KiB and then of 1 MiB, each read
// back from the system with our own nbio.socket_option.
//
// Prints one line and exits 0: "BROKEN: ..." if any option read back otherwise than asked (for a buffer, two sizes
// asked alike, as Linux grants within its limit, or one differing from what was asked elsewhere), or "FIXED: ..." if
// each held. Run by .github/workflows/upstream.yml, through tests/upstream/run.sh, against stock core:net.
package core_net_set_option

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import nbio "../../../third_party/nbio"

main :: proc() {
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	if lerr != nil {
		fmt.eprintln("listen failed:", lerr)
		os.exit(2)
	}
	at, _ := net.bound_endpoint(listener)
	s, derr := net.dial_tcp(at)
	if derr != nil {
		fmt.eprintln("dial failed:", derr)
		os.exit(2)
	}
	said: [dynamic]string
	broken := false
	for want in ([]bool{false, true, false}) {
		net.set_option(s, .TCP_Nodelay, want)
		got, err, _ := nbio.socket_option(s, .TCP_Nodelay)
		append(&said, fmt.tprintf("TCP_Nodelay %v reads %v", want, got))
		broken ||= err != nil || got != want
	}
	sizes: [2]int
	for want, i in ([]int{4096, 1 << 20}) {
		net.set_option(s, .Receive_Buffer_Size, i32(want))
		got, _, _ := nbio.socket_option(s, .Receive_Buffer_Size)
		sizes[i], _ = got.(int)
		append(&said, fmt.tprintf("Receive_Buffer_Size %d reads %v", want, got))
	}
	when ODIN_OS == .Linux {
		broken ||= sizes[0] == sizes[1] || sizes[0] != 2 * 4096
	} else {
		broken ||= sizes[0] != 4096 || sizes[1] != 1 << 20
	}
	fmt.printfln("%s: %s", "BROKEN" if broken else "FIXED", strings.join(said[:], "; ", context.temp_allocator))
}
