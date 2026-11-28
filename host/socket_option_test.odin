package host

import "core:net"
import "core:testing"
import "core:time"
import "../third_party/nbio"

// Every socket option set here, read back after it is set: what was asked, or what the system documents granting for
// it. core:net's set_option set each integer option, and bool ones, to the low bytes of a pointer: TCP_NODELAY asked
// off was left on, and a receive buffer asked for 4 KiB or 1 MiB was the same, the system's most.
@(test)
socket_options_hold_what_was_asked :: proc(t: ^testing.T) {
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	tcp, derr := net.dial_tcp(at)
	testing.expect(t, derr == nil)
	defer net.close(tcp)
	udp, uerr := net.make_unbound_udp_socket(.IP4)
	testing.expect(t, uerr == nil)
	defer net.close(udp)

	flag :: proc(t: ^testing.T, s: net.Any_Socket, option: nbio.Socket_Option, want: bool, loc := #caller_location) {
		err, code := nbio.set_socket_option(s, option, want)
		testing.expectf(t, err == nil, "%v set %v: %v, %d", option, want, err, code, loc = loc)
		got, gerr, _ := nbio.socket_option(s, option)
		testing.expectf(t, gerr == nil && got == want, "%v set %v reads back %v (%v)", option, want, got, gerr, loc = loc)
	}
	for want in ([]bool{false, true, false, true}) {
		flag(t, tcp, .TCP_Nodelay, want)
		flag(t, udp, .Reuse_Address, want)
		flag(t, udp, .Broadcast, want)
		when ODIN_OS == .Darwin || ODIN_OS == .FreeBSD || ODIN_OS == .OpenBSD || ODIN_OS == .NetBSD {
			flag(t, udp, .Reuse_Port, want)
		}
	}
	when ODIN_OS == .Linux || ODIN_OS == .Windows {
		rerr, _ := nbio.set_socket_option(udp, .Reuse_Port, true)
		testing.expectf(t, rerr == .Unsupported, "Reuse_Port where Reuse_Address shares a port: %v", rerr)
	}

	// Sizes: what the system grants for each asked.
	for want in ([]int{4096, 64 << 10, UDP_RECEIVE_BUFFER}) {
		for option in ([]nbio.Socket_Option{.Receive_Buffer_Size, .Send_Buffer_Size}) {
			err, code := nbio.set_socket_option(udp, option, want)
			testing.expectf(t, err == nil, "%v set %d: %v, %d", option, want, err, code)
			got, gerr, _ := nbio.socket_option(udp, option)
			expect := granted(option, want)
			testing.expectf(t, gerr == nil && got == expect, "%v asked %d reads back %v, not %d as the system documents (%v)", option, want, got, expect, gerr)
		}
	}

	// A timeout, of blocking reads.
	want := 200 * time.Millisecond
	terr, tcode := nbio.set_socket_option(tcp, .Receive_Timeout, want)
	testing.expectf(t, terr == nil, "Receive_Timeout set: %v, %d", terr, tcode)
	got, gerr, _ := nbio.socket_option(tcp, .Receive_Timeout)
	d, _ := got.(time.Duration)
	// Linux keeps it in jiffies: within one of them (at least 100 a second).
	testing.expectf(t, gerr == nil && abs(d - want) <= 10 * time.Millisecond, "Receive_Timeout set %v reads back %v (%v)", want, got, gerr)

	// Values of the wrong kind are refused, not set.
	werr, _ := nbio.set_socket_option(tcp, .TCP_Nodelay, 1)
	testing.expect_value(t, werr, nbio.Socket_Option_Error.Wrong_Kind)
	werr, _ = nbio.set_socket_option(udp, .Receive_Buffer_Size, true)
	testing.expect_value(t, werr, nbio.Socket_Option_Error.Wrong_Kind)
	werr, _ = nbio.set_socket_option(udp, .Receive_Buffer_Size, -1)
	testing.expect_value(t, werr, nbio.Socket_Option_Error.Wrong_Kind)
}
