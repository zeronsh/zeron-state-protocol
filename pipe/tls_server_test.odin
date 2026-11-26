#+build !js
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

// Records a server put out: how many, as the client would count them.
@(private = "file")
records :: proc(w: []byte) -> (n: int) {
	for i := 0; i + 5 <= len(w); i += 5 + (int(w[i + 3]) << 8 | int(w[i + 4])) {
		n += 1
	}
	return
}

// Where the last record a client put out begins.
@(private = "file")
last_record :: proc(w: []byte) -> (at: int) {
	for i := 0; i + 5 <= len(w); i += 5 + (int(w[i + 3]) << 8 | int(w[i + 4])) {
		at = i
	}
	return
}

@(private = "file")
opened :: proc(t: ^testing.T, c: ^Tls, s: ^Tls_Server, id: ^Tls_Identity, name := "a.expose.test") {
	to_s, to_c, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
	tls_start(c, name, &to_s)
	testing.expect(t, tls_accept(s, to_s[:], &plain, &to_c, find, id))
	clear(&to_s)
	testing.expect(t, tls_input(c, to_c[:], &plain, &to_s))
	clear(&to_c)
	testing.expect(t, tls_accept(s, to_s[:], &plain, &to_c, find, id))
	testing.expect_value(t, s.state, Tls_Server_State.Open)
}

// However many times the client asks for new keys at once, it is answered once (RFC 8446 §4.6.3): what it sends
// costs it as much as what it is sent costs this end, and nothing piles up for a client that does not read.
@(test)
tls_server_updates_once :: proc(t: ^testing.T) {
	id: Tls_Identity
	testing.expect(t, tls_identity_load(&id, #load("../tests/certs/p256.pem"), #load("../tests/certs/p256.key")))
	defer tls_identity_destroy(&id)
	c: Tls
	s: Tls_Server
	defer tls_destroy(&c)
	defer tls_server_destroy(&s)
	opened(t, &c, &s, &id)
	to_s, to_c, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
	for _ in 0 ..< 100 {
		tls_seal(&c.send, 22, {24, 0, 0, 1, 1}, &to_s)
		c.client_app = tls_expand(c.client_app, "traffic upd", nil)
		tls_key(&c.send, c.client_app)
	}
	tls_write(&c, transmute([]byte)string("after"), &to_s)
	testing.expect(t, tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
	testing.expect_value(t, string(plain[:]), "after")
	testing.expect_value(t, records(to_c[:]), 1)
	tls_server_write(&s, transmute([]byte)string("too"), &to_c)
	clear(&plain)
	clear(&to_s)
	testing.expect(t, tls_input(&c, to_c[:], &plain, &to_s))
	testing.expect_value(t, string(plain[:]), "too")
}

// What comes before a change of keys ends its record (RFC 8446 §5.1): a KeyUpdate followed by anything, or a Finished
// followed by a KeyUpdate, in one record, ends the connection.
@(test)
tls_server_keys_change_at_records :: proc(t: ^testing.T) {
	id: Tls_Identity
	testing.expect(t, tls_identity_load(&id, #load("../tests/certs/p256.pem"), #load("../tests/certs/p256.key")))
	defer tls_identity_destroy(&id)
	{
		c: Tls
		s: Tls_Server
		defer tls_destroy(&c)
		defer tls_server_destroy(&s)
		opened(t, &c, &s, &id)
		to_s, to_c, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
		tls_seal(&c.send, 22, {24, 0, 0, 1, 1, 24, 0, 0, 1, 1}, &to_s)
		testing.expect(t, !tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
		testing.expect_value(t, s.alert, 10)
	}
	{
		c: Tls
		s: Tls_Server
		defer tls_destroy(&c)
		defer tls_server_destroy(&s)
		to_s, to_c, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
		tls_start(&c, "a.expose.test", &to_s)
		testing.expect(t, tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
		clear(&to_s)
		testing.expect(t, tls_input(&c, to_c[:], &plain, &to_s))
		// The client's Finished, its last record, opened and sealed again with a KeyUpdate after it in the same record.
		at := last_record(to_s[:])
		k := Tls_Key{aes = c.send.aes}
		tls_key(&k, c.client_hs)
		inner, ok := tls_open(&k, to_s[at + 5:], to_s[at:][:5])
		testing.expect(t, ok && len(inner) > 0 && inner[len(inner) - 1] == 22)
		again := make([dynamic]byte, context.temp_allocator)
		append(&again, ..inner[:len(inner) - 1])
		append(&again, 24, 0, 0, 1, 0)
		resize(&to_s, at)
		tls_key(&k, c.client_hs)
		tls_seal(&k, 22, again[:], &to_s)
		clear(&to_c)
		testing.expect(t, !tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
		testing.expect_value(t, s.alert, 10)
	}
}

// Asked again for X25519 (a HelloRetryRequest), a client sends the same name as before, in whatever case it did.
@(test)
tls_server_retries_any_case :: proc(t: ^testing.T) {
	id: Tls_Identity
	testing.expect(t, tls_identity_load(&id, #load("../tests/certs/p256.pem"), #load("../tests/certs/p256.key")))
	defer tls_identity_destroy(&id)
	c: Tls
	s: Tls_Server
	defer tls_destroy(&c)
	defer tls_server_destroy(&s)
	first, out, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
	tls_start(&c, "Web.Expose.Test", &first)
	for i in 5 ..< len(first) - 4 { // its X25519 share made a P-256 one, so that the server asks again
		if first[i] == 0 && first[i + 1] == 29 && first[i + 2] == 0 && first[i + 3] == 32 {
			first[i + 1] = 23
		}
	}
	testing.expect(t, tls_accept(&s, first[:], &plain, &out, find, &id))
	testing.expect_value(t, s.state, Tls_Server_State.Retried)
	c2: Tls
	defer tls_destroy(&c2)
	second := make([dynamic]byte, context.temp_allocator)
	tls_start(&c2, "Web.Expose.Test", &second)
	testing.expect(t, tls_accept(&s, second[:], &plain, &out, find, &id))
	testing.expect_value(t, s.state, Tls_Server_State.Flight)
}

// One change_cipher_spec is taken, for middleboxes' sake; another is not: a client cannot keep the server busy with
// records that say nothing.
@(test)
tls_server_one_change_cipher_spec :: proc(t: ^testing.T) {
	id: Tls_Identity
	testing.expect(t, tls_identity_load(&id, #load("../tests/certs/p256.pem"), #load("../tests/certs/p256.key")))
	defer tls_identity_destroy(&id)
	c: Tls
	s: Tls_Server
	defer tls_destroy(&c)
	defer tls_server_destroy(&s)
	to_s, to_c, plain := make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator), make([dynamic]byte, context.temp_allocator)
	tls_start(&c, "a.expose.test", &to_s)
	testing.expect(t, tls_accept(&s, to_s[:], &plain, &to_c, find, &id))
	testing.expect(t, tls_accept(&s, {20, 3, 3, 0, 1, 1}, &plain, &to_c, find, &id))
	testing.expect(t, !tls_accept(&s, {20, 3, 3, 0, 1, 1}, &plain, &to_c, find, &id))
	testing.expect_value(t, s.alert, 10)
}
