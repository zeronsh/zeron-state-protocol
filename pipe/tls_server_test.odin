package pipe

import "core:strings"
import "core:testing"

@(private = "file")
find :: proc(data: rawptr, name: string) -> ^Tls_Identity {
	return (^Tls_Identity)(data) if strings.has_suffix(name, ".expose.test") else nil
}

// A handshake and a conversation with this package's own client, for each kind of key a certificate may have.
@(test)
tls_server_talks :: proc(t: ^testing.T) {
	Pair :: struct {
		chain, key: []byte,
		scheme:     u16,
	}
	pairs := []Pair {
		{#load("../tests/certs/p256.pem"), #load("../tests/certs/p256.key"), 0x0403}, // PKCS #8
		{#load("../tests/certs/p384.pem"), #load("../tests/certs/p384.key"), 0x0503}, // SEC 1
		{#load("../tests/certs/rsa.pem"), #load("../tests/certs/rsa.key"), 0x0804}, // PKCS #1
	}
	for pair in pairs {
		id: Tls_Identity
		testing.expect(t, tls_identity_load(&id, pair.chain, pair.key))
		testing.expect_value(t, id.scheme, pair.scheme)
		defer tls_identity_destroy(&id)

		c: Tls
		s: Tls_Server
		defer tls_destroy(&c)
		defer tls_server_destroy(&s)
		to_s, to_c, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
		tls_start(&c, "Web.Expose.Test", &to_s)
		testing.expect(t, tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
		testing.expect_value(t, tls_server_name(&s), "web.expose.test")
		testing.expect_value(t, s.state, Tls_Server_State.Flight)
		clear(&to_s)
		testing.expect(t, tls_input(&c, to_c[:], &plain, &to_s))
		testing.expect_value(t, c.state, Tls_State.Open)
		clear(&to_c)
		testing.expect(t, tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
		testing.expect_value(t, s.state, Tls_Server_State.Open)

		// Both ways, in records of every size, a byte at a time.
		big := make([]byte, 40000, context.temp_allocator)
		for &b, i in big {
			b = byte(i * 13)
		}
		clear(&to_s)
		tls_write(&c, big, &to_s)
		for i in 0 ..< len(to_s) {
			testing.expect(t, tls_accept(&s, to_s[i:i + 1], &plain, &to_c, find, &id))
		}
		testing.expect(t, string(plain[:]) == string(big))
		clear(&plain)
		clear(&to_c)
		tls_server_write(&s, transmute([]byte)string("world"), &to_c)
		testing.expect(t, tls_input(&c, to_c[:], &plain, &to_s))
		testing.expect_value(t, string(plain[:]), "world")
		// The client asks for new keys, and is answered in kind.
		clear(&to_s)
		clear(&to_c)
		tls_seal(&c.send, 22, {24, 0, 0, 1, 1}, &to_s)
		c.client_app = tls_expand(c.client_app, "traffic upd", nil)
		tls_key(&c.send, c.client_app)
		tls_write(&c, transmute([]byte)string("after"), &to_s)
		clear(&plain)
		testing.expect(t, tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
		testing.expect_value(t, string(plain[:]), "after")
		tls_server_write(&s, transmute([]byte)string("too"), &to_c)
		clear(&plain)
		testing.expect(t, tls_input(&c, to_c[:], &plain, &to_s))
		testing.expect_value(t, string(plain[:]), "too")
		// A record tampered with ends it.
		clear(&to_s)
		tls_write(&c, transmute([]byte)string("x"), &to_s)
		to_s[len(to_s) - 1] ~= 1
		testing.expect(t, !tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
	}
}

@(test)
tls_server_refuses :: proc(t: ^testing.T) {
	id: Tls_Identity
	testing.expect(t, tls_identity_load(&id, #load("../tests/certs/p256.pem"), #load("../tests/certs/p256.key")))
	defer tls_identity_destroy(&id)
	hello :: proc(name: string) -> []byte {
		c: Tls
		w := make([dynamic]byte, context.temp_allocator)
		tls_start(&c, name, &w)
		tls_destroy(&c)
		return w[:]
	}
	// A name with no identity here.
	{
		s: Tls_Server
		defer tls_server_destroy(&s)
		out, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
		testing.expect(t, !tls_accept(&s, hello("other.example"), &plain, &out, find, &id))
		testing.expect(t, s.alert == 112 && len(out) == 7 && out[0] == 21 && out[6] == 112)
	}
	// Nothing older than 1.3.
	{
		h := hello("a.expose.test")
		s: Tls_Server
		defer tls_server_destroy(&s)
		for i in 5 ..< len(h) - 6 {
			if h[i] == 0 && h[i + 1] == 43 && h[i + 4] == 2 { // supported_versions
				h[i + 6] = 3 // 1.2
			}
		}
		out, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
		testing.expect(t, !tls_accept(&s, h, &plain, &out, find, &id))
		testing.expect_value(t, s.alert, 70)
	}
	// What is not a hello at all.
	{
		s: Tls_Server
		defer tls_server_destroy(&s)
		out, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
		testing.expect(t, !tls_accept(&s, transmute([]byte)string("GET / HTTP/1.1\r\n\r\n"), &plain, &out, find, &id))
	}
}
