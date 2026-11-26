package pipe

import "core:strconv"
import "core:strings"

// What an application says to a proxy before it says anything else, read: SOCKS 5 (RFC 1928, without
// authentication) and HTTP's CONNECT and absolute-form requests (RFC 9110). No I/O.

Proxy_Result :: enum {
	More, // not all of it has come
	Done,
	Broken, // not this, or not allowed: refuse, and close
}

Proxy_Request :: struct {
	host:   string, // a name, or an address as written; points into what was read
	port:   u16,
	used:   int, // bytes of what was read that it took
	reply:  enum {
		Socks, // SOCKS 5, whose greeting has been answered
		Connect, // HTTP CONNECT: answer 200, then it is a tunnel
		Absolute, // an HTTP request for an absolute URI: pass it on, made relative
	},
	head:   []byte, // Absolute: the request as the target should have it, in temporary memory
}

SOCKS_GREETED :: [2]byte{5, 0} // version 5, no authentication

// Reads a SOCKS 5 greeting: whether it offers no authentication, and how much it was.
@(require_results)
socks_greeting :: proc(b: []byte) -> (used: int, result: Proxy_Result) {
	if len(b) < 2 {
		return 0, .More
	}
	if b[0] != 5 || b[1] == 0 {
		return 0, .Broken
	}
	n := int(b[1])
	if len(b) < 2 + n {
		return 0, .More
	}
	for m in b[2:2 + n] {
		if m == 0 {
			return 2 + n, .Done
		}
	}
	return 0, .Broken
}

// Reads a SOCKS 5 request, after the greeting: only CONNECT, to a name or an address.
@(require_results)
socks_request :: proc(b: []byte) -> (r: Proxy_Request, result: Proxy_Result) {
	r.reply = .Socks
	if len(b) < 5 {
		return r, .More
	}
	if b[0] != 5 || b[1] != 1 || b[2] != 0 {
		return r, .Broken
	}
	at := 4
	switch b[3] {
	case 1:
		if len(b) < at + 4 + 2 {
			return r, .More
		}
		r.host = strings.concatenate({itoa(b[at]), ".", itoa(b[at + 1]), ".", itoa(b[at + 2]), ".", itoa(b[at + 3])}, context.temp_allocator)
		at += 4
	case 3:
		n := int(b[4])
		if len(b) < at + 1 + n + 2 {
			return r, .More
		}
		if n == 0 {
			return r, .Broken
		}
		r.host = string(b[at + 1:at + 1 + n])
		at += 1 + n
	case:
		return r, .Broken // IPv6: nothing of this space has such an address
	}
	r.port = u16(b[at]) << 8 | u16(b[at + 1])
	r.used = at + 2
	return r, .Done
}

itoa :: proc(b: byte) -> string {
	buf := make([]byte, 3, context.temp_allocator)
	return strconv.write_uint(buf, u64(b), 10)
}

// The reply to a SOCKS 5 request: 0 succeeded, 2 not allowed, 4 unreachable, 5 refused, 7 not supported.
socks_reply :: proc(code: byte) -> [10]byte {
	return {5, code, 0, 1, 0, 0, 0, 0, 0, 0}
}

// Reads an HTTP request to a proxy: CONNECT host:port, or a request for http://host[:port]/..., which is passed on
// with its target made relative and the connection to close after it, since the next may be for another host.
@(require_results)
http_proxy_request :: proc(b: []byte) -> (r: Proxy_Request, result: Proxy_Result) {
	end := strings.index(string(b), "\r\n\r\n")
	if end < 0 {
		return r, .More if len(b) < 16 << 10 else .Broken
	}
	head := string(b[:end + 4])
	first, _, rest := strings.partition(head, "\r\n")
	method, _, tail := strings.partition(first, " ")
	target, _, version := strings.partition(tail, " ")
	if (version != "HTTP/1.1" && version != "HTTP/1.0") || method == "" || target == "" {
		return r, .Broken // a request line, exactly: a proxy that read it otherwise than the device's server would be no guard
	}
	r.used = end + 4
	if method == "CONNECT" {
		host, port, ok := split_host_port(target)
		if !ok {
			return r, .Broken
		}
		r.host, r.port, r.reply = host, port, .Connect
		return r, .Done
	}
	if !strings.has_prefix(target, "http://") {
		return r, .Broken // only a proxy's requests come here
	}
	authority := target[len("http://"):]
	path := "/"
	if slash := strings.index_byte(authority, '/'); slash >= 0 {
		authority, path = authority[:slash], authority[slash:]
	}
	host, port, ok := split_host_port(authority, 80)
	if !ok {
		return r, .Broken
	}
	r.host, r.port, r.reply = host, port, .Absolute
	w := strings.builder_make(context.temp_allocator)
	strings.write_string(&w, method)
	strings.write_byte(&w, ' ')
	strings.write_string(&w, path)
	strings.write_byte(&w, ' ')
	strings.write_string(&w, version)
	strings.write_string(&w, "\r\n")
	for line in strings.split_lines_iterator(&rest) {
		name, _, _ := strings.partition(line, ":")
		if line == "" || strings.equal_fold(name, "connection") || strings.equal_fold(name, "proxy-connection") || strings.equal_fold(name, "keep-alive") || strings.equal_fold(name, "proxy-authorization") {
			continue
		}
		strings.write_string(&w, line)
		strings.write_string(&w, "\r\n")
	}
	strings.write_string(&w, "Connection: close\r\n\r\n")
	r.head = w.buf[:]
	return r, .Done
}

@(require_results)
split_host_port :: proc(s: string, default_port := -1) -> (host: string, port: u16, ok: bool) {
	host = s
	p := default_port
	if colon := strings.last_index_byte(s, ':'); colon >= 0 && !strings.contains(s[colon:], "]") {
		v, parsed := strconv.parse_u64(s[colon + 1:], 10)
		if !parsed || v == 0 || v > 65535 {
			return
		}
		host, p = s[:colon], int(v)
	}
	if p <= 0 || host == "" {
		return
	}
	return host, u16(p), true
}
