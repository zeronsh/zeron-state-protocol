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

	// Forced (Linux): granted twice what is asked, where privileged; refused otherwise, and the size asked stands.
	when ODIN_OS == .Linux {
		ferr, fcode := nbio.set_socket_option(udp, .Receive_Buffer_Size_Forced, 3 << 20)
		fgot, _, _ := nbio.socket_option(udp, .Receive_Buffer_Size)
		if ferr == nil {
			testing.expectf(t, fgot == 2 * (3 << 20), "Receive_Buffer_Size_Forced 3 MiB reads back %v", fgot)
		} else {
			testing.expectf(t, ferr == .System && fcode == 1, "Receive_Buffer_Size_Forced refused otherwise than EPERM: %v, %d", ferr, fcode)
			// The last size asked of the plain option, above.
			stands := granted(.Receive_Buffer_Size, UDP_RECEIVE_BUFFER)
			testing.expectf(t, fgot == stands, "Receive_Buffer_Size_Forced refused, and the size asked before it reads back %v, not %d", fgot, stands)
		}
		// Read back as itself, it is the receive buffer, as the system keeps it.
		forced, frerr, _ := nbio.socket_option(udp, .Receive_Buffer_Size_Forced)
		testing.expectf(t, frerr == nil && forced == fgot, "Receive_Buffer_Size_Forced reads back %v (%v), not the receive buffer's %v", forced, frerr, fgot)
	} else {
		ferr, _ := nbio.set_socket_option(udp, .Receive_Buffer_Size_Forced, 3 << 20)
		testing.expect_value(t, ferr, nbio.Socket_Option_Error.Unsupported)
		_, frerr, _ := nbio.socket_option(udp, .Receive_Buffer_Size_Forced)
		testing.expect_value(t, frerr, nbio.Socket_Option_Error.Unsupported)
	}

	// A timeout, of blocking reads.
	want := 200 * time.Millisecond
	terr, tcode := nbio.set_socket_option(tcp, .Receive_Timeout, want)
	testing.expectf(t, terr == nil, "Receive_Timeout set: %v, %d", terr, tcode)
	got, gerr, _ := nbio.socket_option(tcp, .Receive_Timeout)
	d, _ := got.(time.Duration)
	// Linux keeps it in jiffies: within one of them (at least 100 a second).
	testing.expectf(t, gerr == nil && abs(d - want) <= 10 * time.Millisecond, "Receive_Timeout set %v reads back %v (%v)", want, got, gerr)
	// None is none; and none positive is none, however short (0 being a read that waits for ever): Windows counts
	// milliseconds and POSIX microseconds, so each is rounded up to one, within a jiffy on Linux.
	for short in ([]time.Duration{0, 500 * time.Microsecond, 500 * time.Nanosecond, 1}) {
		serr, scode := nbio.set_socket_option(tcp, .Receive_Timeout, short)
		testing.expectf(t, serr == nil, "Receive_Timeout set %v: %v, %d", short, serr, scode)
		sgot, sgerr, _ := nbio.socket_option(tcp, .Receive_Timeout)
		sd, _ := sgot.(time.Duration)
		if short == 0 {
			testing.expectf(t, sgerr == nil && sd == 0, "Receive_Timeout set 0 reads back %v (%v)", sgot, sgerr)
		} else {
			testing.expectf(t, sgerr == nil && sd > 0 && sd <= 10 * time.Millisecond, "Receive_Timeout set %v reads back %v (%v): a read would wait for ever", short, sgot, sgerr)
		}
	}
	// And the longest there is held to the most the system takes, not wrapped round to something short.
	lerr2, lcode := nbio.set_socket_option(tcp, .Receive_Timeout, max(time.Duration))
	testing.expectf(t, lerr2 == nil, "Receive_Timeout set %v: %v, %d", max(time.Duration), lerr2, lcode)
	lgot, lgerr, _ := nbio.socket_option(tcp, .Receive_Timeout)
	ld, _ := lgot.(time.Duration)
	when ODIN_OS == .Windows {
		testing.expectf(t, lgerr == nil && ld == time.Duration(max(u32)) * time.Millisecond, "Receive_Timeout set %v reads back %v (%v), not a DWORD's most", max(time.Duration), lgot, lgerr)
	} else when ODIN_OS == .Linux {
		// Linux holds one beyond what its timer counts as for ever, and says so as none.
		testing.expectf(t, lgerr == nil && (ld == 0 || ld >= 24 * time.Hour), "Receive_Timeout set %v reads back %v (%v)", max(time.Duration), lgot, lgerr)
	} else {
		testing.expectf(t, lgerr == nil && ld >= 24 * time.Hour, "Receive_Timeout set %v reads back %v (%v)", max(time.Duration), lgot, lgerr)
	}

	// Values of the wrong kind are refused, not set.
	werr, _ := nbio.set_socket_option(tcp, .TCP_Nodelay, 1)
	testing.expect_value(t, werr, nbio.Socket_Option_Error.Wrong_Kind)
	werr, _ = nbio.set_socket_option(udp, .Receive_Buffer_Size, true)
	testing.expect_value(t, werr, nbio.Socket_Option_Error.Wrong_Kind)
	werr, _ = nbio.set_socket_option(udp, .Receive_Buffer_Size, -1)
	testing.expect_value(t, werr, nbio.Socket_Option_Error.Wrong_Kind)
}
