package pipe

import "core:crypto"
import "core:crypto/chacha20poly1305"
import "core:crypto/sha2"
import "core:encoding/endian"
import "../zsp"

// A TLS 1.3 client (RFC 8446), for reaching WebSockets where only port 443 gets through.
//
// It offers one suite and does not judge certificates, because nothing here rests on them: the Noise
// channel inside authenticates the relay by its key, which came with the space's roster, and carries
// every secret. TLS is the envelope that middleboxes expect to see.

Tls :: struct {
	state:      Tls_State,
	secret:     zsp.Key32,
	transcript: sha2.Context_256,
	hs, master: zsp.Key32,
	client_hs:  zsp.Key32,
	server_hs:  zsp.Key32,
	client_app: zsp.Key32,
	server_app: zsp.Key32,
	send, recv: Tls_Key,
	input:      [dynamic]byte, // an incomplete record
	messages:   [dynamic]byte, // an incomplete handshake message
}

Tls_State :: enum {
	Hello, // awaiting the server's
	Flight, // and the rest of its first flight
	Open,
	Closed,
}

@(private)
Tls_Key :: struct {
	key: zsp.Key32,
	iv:  [12]byte,
	n:   u64,
}

TLS_RECORD :: 16384

tls_destroy :: proc(t: ^Tls) {
	delete(t.input)
	delete(t.messages)
	crypto.zero_explicit(t, size_of(Tls))
}

@(private)
hello_head := [?]byte{0x03, 0x03}

// Appends the client's hello.
tls_start :: proc(t: ^Tls, name: string, w: ^[dynamic]byte) {
	crypto.rand_bytes(t.secret[:])
	public := zsp.x25519_public(t.secret)
	sha2.init_256(&t.transcript)

	random, session: zsp.Key32
	crypto.rand_bytes(random[:])
	crypto.rand_bytes(session[:])
	m := make([dynamic]byte, context.temp_allocator)
	append(&m, 1, 0, 0, 0) // client_hello
	append(&m, ..hello_head[:])
	append(&m, ..random[:])
	append(&m, 32)
	append(&m, ..session[:])
	append(&m, 0, 2, 0x13, 0x03) // TLS_CHACHA20_POLY1305_SHA256
	append(&m, 1, 0)
	ext := len(m)
	append(&m, 0, 0)
	// server_name
	n := len(name)
	append(&m, 0, 0, byte((n + 5) >> 8), byte(n + 5), byte((n + 3) >> 8), byte(n + 3), 0, byte(n >> 8), byte(n))
	append(&m, name)
	append(&m, 0, 10, 0, 4, 0, 2, 0, 29) // supported_groups: x25519
	append(&m, 0, 13, 0, 14, 0, 12, 4, 3, 8, 4, 8, 5, 8, 7, 4, 1, 5, 3) // signature_algorithms
	append(&m, 0, 16, 0, 11, 0, 9, 8) // ALPN
	append(&m, "http/1.1")
	append(&m, 0, 43, 0, 3, 2, 3, 4) // supported_versions: 1.3
	append(&m, 0, 45, 0, 2, 1, 1) // psk_key_exchange_modes
	append(&m, 0, 51, 0, 38, 0, 36, 0, 29, 0, 32) // key_share
	append(&m, ..public[:])
	put_u16(m[ext:], len(m) - ext - 2)
	put_u24(m[1:], len(m) - 4)

	sha2.update(&t.transcript, m[:])
	append(w, 22, 3, 1, byte(len(m) >> 8), byte(len(m)))
	append(w, ..m[:])
}

// Consumes bytes from the wire. Plaintext is appended to `plain`, replies to `w`.
tls_input :: proc(t: ^Tls, bytes: []byte, plain, w: ^[dynamic]byte) -> bool {
	append(&t.input, ..bytes)
	used := 0
	defer {
		copy(t.input[:], t.input[used:])
		resize(&t.input, len(t.input) - used)
		if len(t.input) == 0 && cap(t.input) > 4096 {
			shrink(&t.input)
		}
	}
	for t.state != .Closed {
		rest := t.input[used:]
		if len(rest) < 5 {
			return true
		}
		n := int(endian.unchecked_get_u16be(rest[3:]))
		if n > TLS_RECORD + 256 {
			return false
		}
		if len(rest) < 5 + n {
			return true
		}
		type, body := rest[0], rest[5:][:n]
		used += 5 + n
		if type == 20 {
			continue // change_cipher_spec, for appearances
		}
		if t.state != .Hello {
			if type != 23 {
				return false
			}
			ok: bool
			body, ok = tls_open(&t.recv, body, rest[:5])
			if !ok {
				return false
			}
			for len(body) > 0 && body[len(body) - 1] == 0 {
				body = body[:len(body) - 1]
			}
			if len(body) == 0 {
				return false
			}
			type = body[len(body) - 1]
			body = body[:len(body) - 1]
		}
		switch type {
		case 21:
			t.state = .Closed
			return len(body) == 2 && body[1] == 0
		case 22:
			append(&t.messages, ..body)
			tls_messages(t, w) or_return
		case 23:
			if t.state != .Open {
				return false
			}
			append(plain, ..body)
		case:
			return false
		}
	}
	return true
}

// Appends plaintext as records.
tls_write :: proc(t: ^Tls, plain: []byte, w: ^[dynamic]byte) {
	plain := plain
	for len(plain) > 0 {
		n := min(len(plain), TLS_RECORD)
		tls_seal(&t.send, 23, plain[:n], w)
		plain = plain[n:]
	}
}

@(private)
tls_messages :: proc(t: ^Tls, w: ^[dynamic]byte) -> bool {
	used := 0
	defer {
		copy(t.messages[:], t.messages[used:])
		resize(&t.messages, len(t.messages) - used)
	}
	for {
		rest := t.messages[used:]
		if len(rest) < 4 {
			return true
		}
		n := int(rest[1]) << 16 | int(rest[2]) << 8 | int(rest[3])
		if n > 1 << 18 {
			return false
		}
		if len(rest) < 4 + n {
			return true
		}
		m := rest[:4 + n]
		used += len(m)
		switch t.state {
		case .Hello:
			if m[0] != 2 {
				return false
			}
			tls_server_hello(t, m) or_return
		case .Flight:
			if m[0] == 20 {
				tls_finished(t, m, w) or_return
			} else {
				sha2.update(&t.transcript, m)
			}
		case .Open:
			if m[0] == 24 && n == 1 { // key_update
				t.server_app = tls_expand(t.server_app, "traffic upd", nil)
				tls_key(&t.recv, t.server_app)
				if m[4] == 1 {
					tls_seal(&t.send, 22, {24, 0, 0, 1, 0}, w)
					t.client_app = tls_expand(t.client_app, "traffic upd", nil)
					tls_key(&t.send, t.client_app)
				}
			} // else a session ticket, not wanted
		case .Closed:
			return false
		}
	}
}

@(private)
tls_server_hello :: proc(t: ^Tls, m: []byte) -> bool {
	r := zsp.Reader{buf = m, pos = 4 + 2 + 32}
	_ = zsp.read_take(&r, int(zsp.read_u8(&r)))
	suite := zsp.read_take(&r, 2)
	_ = zsp.read_u8(&r)
	ext := zsp.Reader{buf = zsp.read_take(&r, tls_u16(&r))}
	share: zsp.Key32
	have, modern := false, false
	for ext.pos < len(ext.buf) && !ext.bad {
		type := tls_u16(&ext)
		body := zsp.read_take(&ext, tls_u16(&ext))
		switch {
		case type == 43 && len(body) == 2:
			modern = body[0] == 3 && body[1] == 4
		case type == 51 && len(body) == 36 && body[1] == 29:
			copy(share[:], body[4:])
			have = true
		}
	}
	if r.bad || ext.bad || !have || !modern || suite[0] != 0x13 || suite[1] != 0x03 {
		return false
	}
	sha2.update(&t.transcript, m)
	hash := tls_hash(t)
	shared := zsp.x25519_shared(t.secret, share) or_return
	crypto.zero_explicit(&t.secret, 32)
	zero: zsp.Key32
	empty := zsp.sha256()
	early := zsp.hmac256(zero[:], zero[:])
	salt := tls_expand(early, "derived", empty[:])
	t.hs = zsp.hmac256(salt[:], shared[:])
	t.client_hs = tls_expand(t.hs, "c hs traffic", hash[:])
	t.server_hs = tls_expand(t.hs, "s hs traffic", hash[:])
	salt = tls_expand(t.hs, "derived", empty[:])
	t.master = zsp.hmac256(salt[:], zero[:])
	tls_key(&t.send, t.client_hs)
	tls_key(&t.recv, t.server_hs)
	t.state = .Flight
	return true
}

@(private)
tls_finished :: proc(t: ^Tls, m: []byte, w: ^[dynamic]byte) -> bool {
	hash := tls_hash(t)
	key := tls_expand(t.server_hs, "finished", nil)
	want := zsp.hmac256(key[:], hash[:])
	if len(m) != 36 || crypto.compare_constant_time(want[:], m[4:]) != 1 {
		return false
	}
	sha2.update(&t.transcript, m)
	hash = tls_hash(t)
	t.client_app = tls_expand(t.master, "c ap traffic", hash[:])
	t.server_app = tls_expand(t.master, "s ap traffic", hash[:])

	append(w, 20, 3, 3, 0, 1, 1)
	key = tls_expand(t.client_hs, "finished", nil)
	mac := zsp.hmac256(key[:], hash[:])
	out: [36]byte
	out[0], out[3] = 20, 32
	copy(out[4:], mac[:])
	tls_seal(&t.send, 22, out[:], w)
	tls_key(&t.send, t.client_app)
	tls_key(&t.recv, t.server_app)
	t.state = .Open
	return true
}

@(private)
tls_hash :: proc(t: ^Tls) -> (out: zsp.Key32) {
	ctx := t.transcript
	sha2.final(&ctx, out[:])
	return
}

// HKDF-Expand-Label to 32 bytes.
@(private)
tls_expand :: proc(secret: zsp.Key32, label: string, ctx: []byte) -> zsp.Key32 {
	return tls_expand_to(secret, label, ctx, 32)
}

@(private)
tls_expand_to :: proc(secret: zsp.Key32, label: string, ctx: []byte, size: u8) -> zsp.Key32 {
	secret := secret
	return zsp.hmac256(
		secret[:],
		{0, size, byte(6 + len(label))},
		transmute([]byte)string("tls13 "),
		transmute([]byte)label,
		{byte(len(ctx))},
		ctx,
		{1},
	)
}

@(private)
tls_key :: proc(k: ^Tls_Key, secret: zsp.Key32) {
	k.key = tls_expand(secret, "key", nil)
	iv := tls_expand_to(secret, "iv", nil, 12)
	copy(k.iv[:], iv[:])
	k.n = 0
}

@(private)
tls_nonce :: proc(k: ^Tls_Key) -> (iv: [12]byte) {
	iv = k.iv
	endian.unchecked_put_u64be(iv[4:], endian.unchecked_get_u64be(iv[4:]) ~ k.n)
	k.n += 1
	return
}

@(private)
tls_seal :: proc(k: ^Tls_Key, type: byte, plain: []byte, w: ^[dynamic]byte) {
	n := len(plain) + 1 + zsp.TAG
	at := len(w)
	append(w, 23, 3, 3, byte(n >> 8), byte(n))
	append(w, ..plain)
	append(w, type)
	resize(w, at + 5 + n)
	iv := tls_nonce(k)
	ctx: chacha20poly1305.Context = ---
	chacha20poly1305.init(&ctx, k.key[:])
	body := w[at + 5:][:len(plain) + 1]
	chacha20poly1305.seal(&ctx, body, w[at + 5 + len(body):], iv[:], w[at:][:5], body)
}

@(private)
tls_open :: proc(k: ^Tls_Key, sealed, ad: []byte) -> (plain: []byte, ok: bool) {
	n := len(sealed) - zsp.TAG
	if n < 0 {
		return
	}
	iv := tls_nonce(k)
	ctx: chacha20poly1305.Context = ---
	chacha20poly1305.init(&ctx, k.key[:])
	ok = chacha20poly1305.open(&ctx, sealed[:n], iv[:], ad, sealed[:n], sealed[n:])
	return sealed[:n], ok
}

@(private)
tls_u16 :: proc(r: ^zsp.Reader) -> int {
	hi := int(zsp.read_u8(r))
	return hi << 8 | int(zsp.read_u8(r))
}

@(private)
put_u16 :: proc(b: []byte, v: int) {
	b[0], b[1] = byte(v >> 8), byte(v)
}

@(private)
put_u24 :: proc(b: []byte, v: int) {
	b[0], b[1], b[2] = byte(v >> 16), byte(v >> 8), byte(v)
}
