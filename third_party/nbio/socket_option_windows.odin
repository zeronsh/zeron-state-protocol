#+build windows
package nbio

import "core:net"
import "core:time"
import win "core:sys/windows"

@(private="file")
name :: proc(option: Socket_Option) -> (level, opt: i32, ok: bool) {
	switch option {
	case .Reuse_Address:       return win.SOL_SOCKET, win.SO_REUSEADDR, true
	case .Reuse_Port:          return 0, 0, false // Windows shares a port by SO_REUSEADDR
	case .Broadcast:           return win.SOL_SOCKET, win.SO_BROADCAST, true
	case .TCP_Nodelay:         return win.IPPROTO_TCP, win.TCP_NODELAY, true
	case .Receive_Buffer_Size: return win.SOL_SOCKET, win.SO_RCVBUF, true
	case .Receive_Buffer_Size_Forced: return 0, 0, false // Linux's
	case .Send_Buffer_Size:    return win.SOL_SOCKET, win.SO_SNDBUF, true
	case .Receive_Timeout:     return win.SOL_SOCKET, win.SO_RCVTIMEO, true
	}
	return 0, 0, false
}

// Windows wants a BOOL (an int) for each flag, an int for a size, and a DWORD of milliseconds for a timeout.
@(private="package")
_set_socket_option :: proc(s: net.Socket, option: Socket_Option, value: Socket_Option_Value) -> (err: Socket_Option_Error, code: int) {
	level, opt, ok := name(option)
	if !ok { return .Unsupported, 0 }
	res: i32
	switch v in value {
	case bool:
		x := win.BOOL(v)
		res = win.setsockopt(win.SOCKET(s), level, opt, &x, size_of(x))
	case int:
		x := i32(v)
		res = win.setsockopt(win.SOCKET(s), level, opt, &x, size_of(x))
	case time.Duration:
		x := win.DWORD(min(v / time.Millisecond, time.Duration(max(u32))))
		res = win.setsockopt(win.SOCKET(s), level, opt, &x, size_of(x))
	}
	if res != 0 { return .System, int(win.WSAGetLastError()) }
	return .None, 0
}

@(private="package")
_socket_option :: proc(s: net.Socket, option: Socket_Option) -> (value: Socket_Option_Value, err: Socket_Option_Error, code: int) {
	level, opt, ok := name(option)
	if !ok { return nil, .Unsupported, 0 }
	x: i32
	n := i32(size_of(x))
	if win.getsockopt(win.SOCKET(s), level, opt, ([^]u8)(&x), &n) != 0 {
		return nil, .System, int(win.WSAGetLastError())
	}
	switch option {
	case .Reuse_Address, .Reuse_Port, .Broadcast, .TCP_Nodelay: value = x != 0
	case .Receive_Buffer_Size, .Receive_Buffer_Size_Forced, .Send_Buffer_Size: value = int(x)
	case .Receive_Timeout:                                      value = time.Duration(u32(x)) * time.Millisecond
	}
	return
}
