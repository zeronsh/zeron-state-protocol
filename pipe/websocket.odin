package pipe

import "core:crypto"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:strings"

// RFC 6455, both ends, binary messages only.

Opcode :: enum u8 {
	Continue = 0,
	Text     = 1,
	Binary   = 2,
	Close    = 8,
	Ping     = 9,
	Pong     = 10,
}

Ws_Result :: enum {
	More, // the buffer holds less than a message
	Message,
	Broken,
}

MAX_MESSAGE :: 8 << 20
CONTROL_MAX :: 125 // a control frame's payload, at most (RFC 6455 5.5)

@(private)
ws_key :: proc() -> string {
	b: [16]byte
	crypto.rand_bytes(b[:])
	return base64.encode(b[:], allocator = context.temp_allocator)
}

// Temporary memory.
@(require_results)
ws_request :: proc(host, path: string) -> string {
	return strings.concatenate(
		{
			"GET ", path, " HTTP/1.1\r\nHost: ", host,
			"\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ", ws_key(),
			"\r\n\r\n",
		},
		context.temp_allocator,
	)
}

// Temporary memory.
@(require_results)
ws_response :: proc(key: string) -> string {
	ctx: sha1.Context
	digest: [sha1.DIGEST_SIZE]byte
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]byte)key)
	sha1.update(&ctx, transmute([]byte)string("258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	sha1.final(&ctx, digest[:])
	return strings.concatenate(
		{
			"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ",
			base64.encode(digest[:], allocator = context.temp_allocator),
			"\r\n\r\n",
		},
		context.temp_allocator,
	)
}

Http :: struct {
	first:  string, // the request or status line
	key:    string,
	origin: string,
	size:   int, // of the whole head
}

// The head of an HTTP message, when it has all arrived.
@(require_results)
http_head :: proc(buf: []byte) -> (h: Http, ok: bool) {
	text := string(buf)
	h.size = strings.index(text, "\r\n\r\n")
	if h.size < 0 {
		return
	}
	lines := text[:h.size]
	h.size += 4
	first := true
	for line in strings.split_iterator(&lines, "\r\n") {
		if first {
			h.first = line
			first = false
			continue
		}
		colon := strings.index_byte(line, ':')
		if colon < 0 {
			continue
		}
		value := strings.trim_space(line[colon + 1:])
		if strings.equal_fold(line[:colon], "sec-websocket-key") {
			h.key = value
		} else if strings.equal_fold(line[:colon], "origin") {
			h.origin = value
		}
	}
	return h, true
}

// The path of a GET request.
@(require_results)
http_path :: proc(h: ^Http) -> (path: string, ok: bool) {
	parts := strings.fields(h.first, context.temp_allocator)
	if len(parts) < 2 || parts[0] != "GET" {
		return
	}
	return parts[1], true
}

// Takes one frame off the front of a buffer, unmasking it in place. One whose payload would be larger than `most` is
// broken, known so from its head alone, before any of it need be held.
@(require_results)
ws_take :: proc(buf: []byte, most := MAX_MESSAGE) -> (op: Opcode, payload: []byte, used: int, fin: bool, result: Ws_Result) {
	if len(buf) < 2 {
		return
	}
	op = Opcode(buf[0] & 15)
	switch op {
	case .Continue, .Text, .Binary, .Close, .Ping, .Pong:
	case:
		result = .Broken // reserved, for extensions never negotiated
		return
	}
	masked := buf[1] & 0x80 != 0
	n := int(buf[1] & 0x7f)
	at := 2
	if n == 126 {
		if len(buf) < 4 {
			return
		}
		n = int(endian.unchecked_get_u16be(buf[2:]))
		at = 4
	} else if n == 127 {
		if len(buf) < 10 {
			return
		}
		long := endian.unchecked_get_u64be(buf[2:])
		if long > u64(most) {
			result = .Broken
			return
		}
		n = int(long)
		at = 10
	}
	fin = buf[0] & 0x80 != 0
	// Reserved bits are never negotiated, and control frames are never in pieces, nor long.
	if n > most || buf[0] & 0x70 != 0 || (op >= .Close && (!fin || n > CONTROL_MAX)) {
		result = .Broken
		return
	}
	mask: [4]byte
	if masked {
		if len(buf) < at + 4 {
			return
		}
		copy(mask[:], buf[at:])
		at += 4
	}
	if len(buf) < at + n {
		return
	}
	payload = buf[at:][:n]
	if masked {
		ws_mask(payload, mask)
	}
	return op, payload, at + n, fin, .Message
}

ws_put :: proc(w: ^[dynamic]byte, op: Opcode, payload: []byte, client: bool) {
	at := ws_begin(w, op, len(payload), client)
	append(w, ..payload)
	ws_end(w, at, client)
}

// Begins a message whose payload of known size the caller appends itself.
@(require_results)
ws_begin :: proc(w: ^[dynamic]byte, op: Opcode, size: int, client: bool) -> int {
	bit := byte(0x80) if client else 0
	append(w, byte(op) | 0x80)
	switch {
	case size < 126:
		append(w, byte(size) | bit)
	case size < 1 << 16:
		append(w, 126 | bit, byte(size >> 8), byte(size))
	case:
		append(w, 127 | bit)
		b: [8]byte
		endian.unchecked_put_u64be(b[:], u64(size))
		append(w, ..b[:])
	}
	if client {
		mask: [4]byte
		crypto.rand_bytes(mask[:])
		append(w, ..mask[:])
	}
	return len(w)
}

ws_end :: proc(w: ^[dynamic]byte, at: int, client: bool) {
	if client {
		mask: [4]byte
		copy(mask[:], w[at - 4:])
		ws_mask(w[at:], mask)
	}
}

@(private)
ws_mask :: proc(b: []byte, mask: [4]byte) {
	m := mask
	wide := u64(transmute(u32)m)
	wide |= wide << 32
	i := 0
	for ; i + 8 <= len(b); i += 8 {
		endian.unchecked_put_u64le(b[i:], endian.unchecked_get_u64le(b[i:]) ~ u64(u64le(wide)))
	}
	for ; i < len(b); i += 1 {
		b[i] ~= m[i & 3]
	}
}

Url :: struct {
	secure: bool,
	host:   string, // with port, as given
	name:   string, // without
	port:   int,
	path:   string,
}

// ws://host[:port]/path and wss://, the host a name or an address, an IPv6 one in brackets. Nothing in it may be a
// space or a control character, which would end the request line or a header it is put in.
@(require_results)
url_parse :: proc(url: string) -> (u: Url, ok: bool) {
	for c in transmute([]byte)url {
		if c <= ' ' || c == 0x7f {
			return
		}
	}
	rest := url
	switch {
	case strings.has_prefix(url, "wss://"):
		u.secure = true
		u.port = 443
		rest = url[6:]
	case strings.has_prefix(url, "ws://"):
		u.port = 80
		rest = url[5:]
	case:
		return
	}
	slash := strings.index_byte(rest, '/')
	u.path = "/"
	u.host = rest
	if slash >= 0 {
		u.host, u.path = rest[:slash], rest[slash:]
	}
	if strings.index_any(u.host, "?#@") >= 0 {
		return // a query or a fragment with no path before it, or a user: none is a host
	}
	u.name = u.host
	port := ""
	has_port := false
	if strings.has_prefix(u.host, "[") {
		end := strings.index_byte(u.host, ']')
		if end < 0 {
			return
		}
		u.name = u.host[1:end]
		if after := u.host[end + 1:]; after != "" {
			if after[0] != ':' {
				return
			}
			port, has_port = after[1:], true
		}
		if strings.index_any(u.name, "[]") >= 0 || strings.index_byte(u.name, ':') < 0 {
			return
		}
	} else if colon := strings.index_byte(u.host, ':'); colon >= 0 {
		u.name, port, has_port = u.host[:colon], u.host[colon + 1:], true
		if strings.index_any(u.host, "[]") >= 0 || strings.index_byte(port, ':') >= 0 {
			return // an IPv6 address, which only brackets would tell from a port
		}
	}
	if has_port {
		u.port = 0
		for c in port {
			if c < '0' || c > '9' {
				return
			}
			u.port = u.port * 10 + int(c - '0')
			if u.port > 65535 {
				return // and so before it can wrap
			}
		}
	}
	return u, len(u.name) > 0 && u.port > 0
}
