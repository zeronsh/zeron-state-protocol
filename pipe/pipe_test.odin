#+build !js
package pipe

import "core:crypto"
import "core:math/rand"
import "core:testing"

@(test)
websocket_round_trip :: proc(t: ^testing.T) {
	for size in ([]int{0, 5, 125, 126, 70_000}) {
		payload := make([]byte, size, context.temp_allocator)
		for &b, i in payload {
			b = byte(i * 7)
		}
		for client in ([]bool{false, true}) {
			w := make([dynamic]byte, context.temp_allocator)
			ws_put(&w, .Binary, payload, client)
			_, _, _, _, partial := ws_take(w[:len(w) - 1])
			testing.expect_value(t, partial, Ws_Result.More)
			op, got, used, fin, result := ws_take(w[:])
			testing.expect(t, fin && op == .Binary && result == .Message && used == len(w) && string(got) == string(payload))
		}
	}
	// The example in RFC 6455.
	response := ws_response("dGhlIHNhbXBsZSBub25jZQ==")
	h, ok := http_head(transmute([]byte)response)
	testing.expect(t, ok && h.size == len(response))
	found := false
	for i in 0 ..< len(response) - 28 {
		found ||= response[i:][:28] == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
	}
	testing.expect(t, found)
}

@(test)
urls :: proc(t: ^testing.T) {
	u, ok := url_parse("wss://relay.example.com/abc")
	testing.expect(t, ok && u.secure && u.port == 443 && u.name == "relay.example.com" && u.path == "/abc")
	u, ok = url_parse("ws://127.0.0.1:8787")
	testing.expect(t, ok && !u.secure && u.port == 8787 && u.name == "127.0.0.1" && u.host == "127.0.0.1:8787" && u.path == "/")
	_, ok = url_parse("http://x/")
	testing.expect(t, !ok)
	// An IPv6 address is named without its brackets, which are only the URL's, and kept in the Host header.
	u, ok = url_parse("ws://[::1]:8787/abc")
	testing.expect(t, ok && u.name == "::1" && u.port == 8787 && u.host == "[::1]:8787" && u.path == "/abc")
	u, ok = url_parse("wss://[2001:db8::1]")
	testing.expect(t, ok && u.name == "2001:db8::1" && u.port == 443 && u.path == "/")
	u, ok = url_parse("ws://example.com:65535/x?y")
	testing.expect(t, ok && u.port == 65535 && u.path == "/x?y")
	for bad in ([]string{
		"ws://example.com:18446744073709551696/abc", // 2^64 + 80, which wrapped to 80
		"ws://example.com:65536/",
		"ws://example.com:/",
		"ws://example.com:80:80/",
		"ws://::1:8787/",
		"ws://[::1/",
		"ws://[::1]8787/",
		"ws://[example.com]/",
		"ws://[]/",
		"ws://example.com/a\r\nX-Injected: 1",
		"ws://example.com\r\nX: 1/",
		"ws://example.com/a b",
		"ws://exa\x00mple.com/",
		"ws://example.com/\x7f",
		"ws://user@example.com/",
		"ws://example.com?x",
		"ws:///path",
	}) {
		_, ok = url_parse(bad)
		testing.expectf(t, !ok, "%q was taken", bad)
	}
}

@(test)
stun_round_trip :: proc(t: ^testing.T) {
	v6: Address
	for &b, i in v6.ip {
		b = byte(i + 1)
	}
	v6.port = 9999
	for want in ([]Address{address_v4(203, 0, 113, 9, 4242), v6}) {
		ask := stun_request()
		buf: [STUN_REPLY]byte
		got, ok := stun_address(ask[:], stun_answer(ask[:], want, buf[:]))
		testing.expect(t, ok && got == want)
	}
}

// Anyone can send a machine anything.
@(test)
parsers_survive_noise :: proc(t: ^testing.T) {
	state := rand.create(3)
	context.random_generator = rand.default_random_generator(&state)
	for _ in 0 ..< 4000 {
		b := make([]byte, rand.int_max(200), context.temp_allocator)
		for &x in b {
			x = byte(rand.uint32()) & (0xff if rand.int_max(3) == 0 else 0x13)
		}
		_, _, _, _, _ = ws_take(b)
		_, _ = http_head(b)
		_, _ = url_parse(string(b))
		ask := stun_request()
		if len(b) >= 20 {
			copy(b, []byte{1, 1})
			copy(b[4:], ask[4:])
		}
		_, _ = stun_address(ask[:], b)
		_, _ = packet_receiver(b)

		tls: Tls
		plain, w: [dynamic]byte
		tls_start(&tls, "x", &w)
		server := make([dynamic]byte, context.temp_allocator)
		append(&server, 22, 3, 3, 0, byte(len(b) + 4), 2, 0, 0, byte(len(b)))
		append(&server, ..b)
		tls_input(&tls, server[:], &plain, &w)
		tls_destroy(&tls)
		delete(plain)
		delete(w)

		// Frames from a genuine peer that has lost its mind.
		l: Link
		link_init(&l)
		l.state = .Open
		zero := l.streams[0]
		for i in 0 ..< 20 {
			append(&l.chunks, Chunk{id = 0, lo = u64(i) * 50, hi = u64(i) * 50 + 50, kind = .Data})
			append(&l.sent, Sent{time = Time(i + 1), size = 100, chunk = u64(i), chunks = 1})
			l.in_flight += 100
		}
		resize(&zero.out, 1000)
		zero.out_next = 1000
		l.held, l.out_total = 1000, 1000
		if len(b) > 0 {
			b[0] = 2 + b[0] % 9
		}
		link_frames(&l, b, 1000)
		buf: [PACKET_MAX]byte
		_ = link_output(&l, buf[:], 2000)
		link_destroy(&l)
		free_all(context.temp_allocator)
	}
}

// A control frame is short (RFC 6455 5.5), and an opcode nobody negotiated is no frame: either is broken from its head
// alone, as is any frame longer than its reader takes, before any of its payload need be held.
@(test)
websocket_frames_are_bounded :: proc(t: ^testing.T) {
	head :: proc(op: byte, n: u64) -> [10]byte {
		b: [10]byte
		b[0] = 0x80 | op
		b[1] = 127
		for i in 0 ..< 8 {
			b[2 + i] = byte(n >> uint(56 - 8 * i))
		}
		return b
	}
	for op in ([]Opcode{.Close, .Ping, .Pong}) {
		for size in ([]int{CONTROL_MAX, CONTROL_MAX + 1}) {
			w := make([dynamic]byte, context.temp_allocator)
			ws_put(&w, op, make([]byte, size, context.temp_allocator), true)
			_, _, _, _, result := ws_take(w[:])
			testing.expectf(t, result == (.Message if size <= CONTROL_MAX else .Broken), "%v of %d: %v", op, size, result)
		}
		big := head(u8(op), 1 << 20)
		_, _, _, _, result := ws_take(big[:])
		testing.expectf(t, result == .Broken, "%v of a mebibyte, by its head: %v", op, result)
	}
	for op in ([]byte{3, 7, 11, 15}) {
		b := [2]byte{0x80 | op, 0}
		_, _, _, _, result := ws_take(b[:])
		testing.expectf(t, result == .Broken, "opcode %d: %v", op, result)
	}
	long := head(u8(Opcode.Binary), 200)
	_, _, _, _, result := ws_take(long[:], most = 125)
	testing.expect_value(t, result, Ws_Result.Broken)
}

// A server that asks again and again for a key update, and reads nothing, is owed one update, sent before what is next
// written: not one record for every asking.
@(test)
tls_key_updates_are_answered_once :: proc(t: ^testing.T) {
	tls: Tls
	defer tls_destroy(&tls)
	crypto.rand_bytes(tls.client_app[:])
	crypto.rand_bytes(tls.server_app[:])
	tls_key(&tls.send, tls.client_app)
	tls_key(&tls.recv, tls.server_app)
	tls.state = .Open
	server, server_app := tls.recv, tls.server_app
	wire := make([dynamic]byte, context.temp_allocator)
	for _ in 0 ..< 1000 {
		tls_seal(&server, 22, {24, 0, 0, 1, 1}, &wire)
		server_app = tls_expand(server_app, "traffic upd", nil)
		tls_key(&server, server_app)
	}
	plain, w: [dynamic]byte
	defer delete(plain)
	defer delete(w)
	testing.expect(t, tls_input(&tls, wire[:], &plain, &w))
	testing.expectf(t, len(w) == 0, "%d bytes said before anything was written", len(w))
	tls_write(&tls, transmute([]byte)string("x"), &w)
	update := 5 + 5 + 1 + 16
	testing.expectf(t, len(w) == update + 5 + 1 + 1 + 16, "%d bytes for one update and one byte", len(w))
}

// A server reached by its address is not named in the hello: a name may not be an address (RFC 6066 3).
@(test)
tls_names_no_address :: proc(t: ^testing.T) {
	named, unnamed: Tls
	w, v: [dynamic]byte
	defer {
		tls_destroy(&named)
		tls_destroy(&unnamed)
		delete(w)
		delete(v)
	}
	tls_start(&named, "example.com", &w)
	tls_start(&unnamed, "", &v)
	testing.expect_value(t, len(w) - len(v), 9 + len("example.com"))
	// Each still says how long it is, as a record and as a message, rightly.
	for b in ([][dynamic]byte{w, v}) {
		testing.expect_value(t, int(b[3]) << 8 | int(b[4]), len(b) - 5)
		testing.expect_value(t, int(b[6]) << 16 | int(b[7]) << 8 | int(b[8]), len(b) - 9)
	}
}

// Nothing is sealed before the handshake gives a key to seal it with: not under the zeros a key is before then.
@(test)
tls_writes_nothing_before_open :: proc(t: ^testing.T) {
	tls: Tls
	w: [dynamic]byte
	defer {
		tls_destroy(&tls)
		delete(w)
	}
	tls_start(&tls, "x", &w)
	hello := len(w)
	tls_write(&tls, transmute([]byte)string("ping"), &w)
	testing.expectf(t, len(w) == hello && tls.send.n == 0, "%d bytes written in state %v", len(w) - hello, tls.state)
}

// An address packets can go to as to one peer: never port 0, nor nobody, nor a group, nor everyone.
@(test)
addresses_usable :: proc(t: ^testing.T) {
	v6: Address
	v6.ip = {0 = 0x20, 1 = 0x01, 15 = 1}
	v6.port = 9
	group := v6
	group.ip[0] = 0xff
	nobody: Address
	nobody.port = 9
	for a, i in ([]Address{address_v4(192, 168, 1, 2, 9), address_v4(127, 0, 0, 1, 1), v6}) {
		testing.expectf(t, address_usable(a), "%d: %v refused", i, a)
	}
	for a, i in ([]Address{address_v4(192, 168, 1, 2, 0), address_v4(0, 0, 0, 0, 9), address_v4(255, 255, 255, 255, 9), address_v4(224, 0, 0, 1, 9), group, nobody}) {
		testing.expectf(t, !address_usable(a), "%d: %v taken", i, a)
	}
}
