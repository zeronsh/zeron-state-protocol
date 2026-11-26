#+build !js
package pipe

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
		l.in_limit = 1 << 20
		for i in 0 ..< 20 {
			append(&l.sent, Sent{time = Time(i + 1), size = 100, stream = {u64(i) * 50, u64(i) * 50 + 50}})
			l.in_flight += 100
		}
		resize(&l.out, 1000)
		l.out_next = 1000
		if len(b) > 0 {
			b[0] = 2 + b[0] % 3
		}
		link_frames(&l, b, 1000)
		buf: [PACKET_MAX]byte
		_ = link_output(&l, buf[:], 2000)
		link_destroy(&l)
		free_all(context.temp_allocator)
	}
}
