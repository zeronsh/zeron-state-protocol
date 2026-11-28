package nbio

import "core:net"
import "core:time"

// ZSP: socket options, set as the system takes each, and read back. core:net's set_option sets the wrong value of
// every integer option, and of `bool` and `b8` ones: its type switch lists several types in one case, where the value
// stays an `any`, and it copies the low bytes of that any's data pointer into the option rather than the value
// (core/net/socket_windows.odin:305-351, socket_posix.odin:294-329, socket_linux.odin:368-402, at e28f5d1). So a
// receive buffer of 1 MiB was given whatever those bytes said, and TCP_NODELAY `false` was set on. Here each option
// is given the C type the system wants, on every platform. Only the options this repository sets are here.
Socket_Option :: enum {
	Reuse_Address,       // bool
	Reuse_Port,          // bool, where the system has it apart from Reuse_Address (macOS, the BSDs)
	Broadcast,           // bool
	TCP_Nodelay,         // bool
	Receive_Buffer_Size, // int, bytes: what the system grants may differ (see socket_option)
	Receive_Buffer_Size_Forced, // int, bytes: Linux only, SO_RCVBUFFORCE, beyond net.core.rmem_max; needs CAP_NET_ADMIN
	Send_Buffer_Size,    // int, bytes
	Receive_Timeout,     // time.Duration, of blocking reads
	IPv6_Only,           // bool, of an IPv6 socket, set before it is bound: it takes no IPv4, so that one of its own may share the port
}

Socket_Option_Value :: union {
	bool,
	int,
	time.Duration,
}

Socket_Option_Error :: enum {
	None,
	Unsupported,   // the option, on this platform
	Wrong_Kind,    // a value of the wrong type for the option, or out of its range
	System,        // the system refused it: see the code returned with it
}

@(private="file")
kind :: proc(option: Socket_Option) -> typeid {
	switch option {
	case .Reuse_Address, .Reuse_Port, .Broadcast, .TCP_Nodelay, .IPv6_Only: return bool
	case .Receive_Buffer_Size, .Receive_Buffer_Size_Forced, .Send_Buffer_Size: return int
	case .Receive_Timeout:                                      return time.Duration
	}
	return nil
}

// Sets an option of a socket to the value given, of the option's own type. code is the system's, where it refused.
set_socket_option :: proc(s: net.Any_Socket, option: Socket_Option, value: Socket_Option_Value) -> (err: Socket_Option_Error, code: int) {
	switch v in value {
	case bool:
		if kind(option) != bool { return .Wrong_Kind, 0 }
	case int:
		if kind(option) != int || v < 0 || v > int(max(i32)) { return .Wrong_Kind, 0 }
	case time.Duration:
		if kind(option) != time.Duration || v < 0 { return .Wrong_Kind, 0 }
	case:
		return .Wrong_Kind, 0
	}
	return _set_socket_option(net.any_socket_to_socket(s), option, value)
}

// What an option of a socket holds, as the system says. A buffer size is what the system granted, which may differ
// from what was asked: Linux grants twice what it is asked (for its own bookkeeping), up to twice net.core.rmem_max or
// wmem_max; macOS and Windows what is asked, within their limits.
socket_option :: proc(s: net.Any_Socket, option: Socket_Option) -> (value: Socket_Option_Value, err: Socket_Option_Error, code: int) {
	return _socket_option(net.any_socket_to_socket(s), option)
}
