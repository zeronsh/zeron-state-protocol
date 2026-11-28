#+build linux, darwin, freebsd, openbsd, netbsd
package nbio

import "core:net"
import "core:sys/posix"
import "core:time"

@(private="file")
name :: proc(option: Socket_Option) -> (level: i32, opt: posix.Sock_Option, ok: bool) {
	switch option {
	case .Reuse_Address: return posix.SOL_SOCKET, .REUSEADDR, true
	case .Reuse_Port:
		when ODIN_OS == .Linux {
			return 0, nil, false // Linux shares a UDP port by SO_REUSEADDR (its SO_REUSEPORT balances, which is another thing)
		} else {
			return posix.SOL_SOCKET, posix.Sock_Option(0x0200), true // SO_REUSEPORT, on macOS and the BSDs alike
		}
	case .Broadcast:           return posix.SOL_SOCKET, .BROADCAST, true
	case .TCP_Nodelay:         return posix.IPPROTO_TCP, posix.Sock_Option(posix.TCP_NODELAY), true
	case .Receive_Buffer_Size: return posix.SOL_SOCKET, .RCVBUF, true
	case .Receive_Buffer_Size_Forced:
		when ODIN_OS == .Linux {
			return posix.SOL_SOCKET, posix.Sock_Option(33), true // SO_RCVBUFFORCE; read back, it is SO_RCVBUF
		} else {
			return 0, nil, false
		}
	case .Send_Buffer_Size:    return posix.SOL_SOCKET, .SNDBUF, true
	case .Receive_Timeout:     return posix.SOL_SOCKET, .RCVTIMEO, true
	}
	return 0, nil, false
}

// POSIX wants an int for each flag and for a size, and a timeval for a timeout.
@(private="package")
_set_socket_option :: proc(s: net.Socket, option: Socket_Option, value: Socket_Option_Value) -> (err: Socket_Option_Error, code: int) {
	level, opt, ok := name(option)
	if !ok { return .Unsupported, 0 }
	res: posix.result
	switch v in value {
	case bool:
		x := i32(1 if v else 0)
		res = posix.setsockopt(posix.FD(s), level, opt, &x, size_of(x))
	case int:
		x := i32(v)
		res = posix.setsockopt(posix.FD(s), level, opt, &x, size_of(x))
	case time.Duration:
		x := timeout_timeval(v)
		res = posix.setsockopt(posix.FD(s), level, opt, &x, size_of(x))
	}
	if res != .OK { return .System, int(posix.errno()) }
	return .None, 0
}

// A timeout as POSIX takes it, a timeval, where {0, 0} is none (a read waits for ever): a positive one is rounded up to
// the microsecond, so that none less than one becomes {0, 0}, and its seconds are held to what a time_t holds rather
// than wrapping.
@(private="file")
timeout_timeval :: proc "contextless" (v: time.Duration) -> posix.timeval {
	if v <= 0 {
		return {}
	}
	us := v / time.Microsecond
	if v % time.Microsecond != 0 {
		us += 1
	}
	return {
		tv_sec  = posix.time_t(min(us / 1_000_000, time.Duration(max(posix.time_t)))),
		tv_usec = posix.suseconds_t(us % 1_000_000),
	}
}

@(private="package")
_socket_option :: proc(s: net.Socket, option: Socket_Option) -> (value: Socket_Option_Value, err: Socket_Option_Error, code: int) {
	level, opt, ok := name(option)
	if !ok { return nil, .Unsupported, 0 }
	switch option {
	case .Receive_Timeout:
		x: posix.timeval
		n := posix.socklen_t(size_of(x))
		if posix.getsockopt(posix.FD(s), level, opt, &x, &n) != .OK { return nil, .System, int(posix.errno()) }
		// Held to the longest a Duration holds, as a timeout set to it reads back from Linux: not wrapped round.
		if time.Duration(x.tv_sec) > (max(time.Duration) - time.Second) / time.Second {
			value = max(time.Duration)
		} else {
			value = time.Duration(x.tv_sec) * time.Second + time.Duration(x.tv_usec) * time.Microsecond
		}
	case .Reuse_Address, .Reuse_Port, .Broadcast, .TCP_Nodelay, .Receive_Buffer_Size, .Receive_Buffer_Size_Forced, .Send_Buffer_Size:
		if option == .Receive_Buffer_Size_Forced {
			opt = .RCVBUF
		}
		x: i32
		n := posix.socklen_t(size_of(x))
		if posix.getsockopt(posix.FD(s), level, opt, &x, &n) != .OK { return nil, .System, int(posix.errno()) }
		if option == .Receive_Buffer_Size || option == .Receive_Buffer_Size_Forced || option == .Send_Buffer_Size {
			value = int(x)
		} else {
			value = x != 0
		}
	}
	return
}
