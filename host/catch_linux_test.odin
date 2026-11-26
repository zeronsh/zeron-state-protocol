#+build linux
package host

import "core:net"
import "core:testing"

// The catch probe is among the addresses caught, 127.a.b.2–127.a.255.255, whatever b is.
@(test)
catch_probe_in_range :: proc(t: ^testing.T) {
	for base in ([][2]byte{{77, 0}, {77, 1}, {200, 254}}) {
		probe := catch_probe(base).address.(net.IP4_Address)
		testing.expectf(t, probe[0] == 127 && probe[1] == base[0] && probe[2] >= base[1] && probe[3] >= 2, "%v for %v", probe, base)
	}
}
