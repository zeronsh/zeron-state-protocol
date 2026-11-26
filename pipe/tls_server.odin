package pipe

import "core:crypto"
import "core:crypto/ecdsa"
import chash "core:crypto/hash"
import "core:crypto/rsa"
import "core:crypto/sha2"
import "core:encoding/endian"
import "core:encoding/pem"
import "../zsp"

// A TLS 1.3 server (RFC 8446), for the public's way in to what a device exposes through a relay: so that a browser,
// or anything that speaks TLS, reaches it by name with a certificate it trusts. Both suites every client has
// (AES-128-GCM, which is required, and ChaCha20-Poly1305), over X25519, asked for again (HelloRetryRequest) when a
// client did not guess it; certificates whose key is ECDSA on P-256 or P-384, or RSA, signed with PSS. Neither
// resumption nor early data: nothing is remembered between connections. No I/O.

TLS_AES_128_GCM :: 0x1301
TLS_CHACHA20 :: 0x1303

Tls_Identity :: struct {
	chain:  [dynamic][]byte, // DER, the leaf first; owned
	scheme: u16, // 0x0403 ECDSA P-256 SHA-256, 0x0503 ECDSA P-384 SHA-384, 0x0804 RSA-PSS SHA-256
	ec:     ecdsa.Private_Key,
	rsa:    rsa.Private_Key,
}

Tls_Server_State :: enum {
	Hello, // awaiting the client's hello
	Retried, // asked it again for X25519
	Flight, // our flight is sent: awaiting its Finished
	Open,
	Closed,
}

Tls_Server :: struct {
	state:      Tls_Server_State,
	transcript: sha2.Context_256,
	send, recv: Tls_Key,
	suite:      u16,
	client_hs:  zsp.Key32,
	server_hs:  zsp.Key32,
	master:     zsp.Key32,
	client_app: zsp.Key32,
	server_app: zsp.Key32,
	input:      [dynamic]byte, // an incomplete record
	messages:   [dynamic]byte, // an incomplete handshake message
	name:       [255]byte, // what it asked for, SNI, in lower case
	name_len:   int,
	session:    [32]byte, // echoed, as middleboxes expect
	session_len: int,
	alert:      u8, // why it ended, if it was this end's doing
}

// What a server says for a name: the identity to prove, or nil to refuse.
Tls_Find :: proc(data: rawptr, name: string) -> ^Tls_Identity

tls_server_name :: proc(t: ^Tls_Server) -> string {
	return string(t.name[:t.name_len])
}

tls_server_destroy :: proc(t: ^Tls_Server) {
	delete(t.input)
	delete(t.messages)
	crypto.zero_explicit(t, size_of(Tls_Server))
}

tls_identity_destroy :: proc(id: ^Tls_Identity) {
	for c in id.chain {
		delete(c)
	}
	delete(id.chain)
	ecdsa.private_key_clear(&id.ec)
	rsa.private_key_clear(&id.rsa)
	id^ = {}
}

// Reads a certificate chain and its private key, as PEM: CERTIFICATE blocks, the leaf first; and PRIVATE KEY (PKCS #8),
// EC PRIVATE KEY (SEC 1) or RSA PRIVATE KEY (PKCS #1).
@(require_results)
tls_identity_load :: proc(id: ^Tls_Identity, chain_pem, key_pem: []byte) -> bool {
	rest := chain_pem
	for {
		block, more, err := pem.decode(rest, context.temp_allocator)
		if err != nil || block == nil {
			break
		}
		rest = more
		if block.label == "CERTIFICATE" {
			c := make([]byte, len(pem.block_bytes(block)))
			copy(c, pem.block_bytes(block))
			append(&id.chain, c)
		}
	}
	if len(id.chain) == 0 {
		return false
	}
	block, _, err := pem.decode(key_pem, context.temp_allocator)
	if err != nil || block == nil {
		return false
	}
	der := pem.block_bytes(block)
	defer crypto.zero_explicit(raw_data(der), len(der))
	switch block.label {
	case "PRIVATE KEY":
		return pkcs8_key(id, der)
	case "EC PRIVATE KEY":
		return sec1_key(id, der, nil)
	case "RSA PRIVATE KEY":
		return pkcs1_key(id, der)
	}
	return false
}

// ---------------------------------------------------------------- keys, from DER

@(private = "file")
Der :: struct {
	buf: []byte,
	pos: int,
	bad: bool,
}

// One element: its tag and contents.
@(private = "file")
der_next :: proc(d: ^Der) -> (tag: byte, body: []byte) {
	if d.pos + 2 > len(d.buf) {
		d.bad = true
		return
	}
	tag = d.buf[d.pos]
	n := int(d.buf[d.pos + 1])
	d.pos += 2
	if n & 0x80 != 0 {
		count := n & 0x7f
		if count == 0 || count > 3 || d.pos + count > len(d.buf) {
			d.bad = true
			return
		}
		n = 0
		for _ in 0 ..< count {
			n = n << 8 | int(d.buf[d.pos])
			d.pos += 1
		}
	}
	if d.pos + n > len(d.buf) {
		d.bad = true
		return
	}
	body = d.buf[d.pos:][:n]
	d.pos += n
	return
}

@(private = "file")
der_in :: proc(d: ^Der, want: byte) -> Der {
	tag, body := der_next(d)
	if tag != want {
		d.bad = true
	}
	return {buf = body}
}

// An INTEGER's magnitude, without the sign's leading zero.
@(private = "file")
der_uint :: proc(d: ^Der) -> []byte {
	tag, body := der_next(d)
	if tag != 0x02 || len(body) == 0 {
		d.bad = true
		return nil
	}
	for len(body) > 1 && body[0] == 0 {
		body = body[1:]
	}
	return body
}

@(private = "file")
OID_EC := []byte{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01}
@(private = "file")
OID_RSA := []byte{0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01}
@(private = "file")
OID_P256 := []byte{0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07}
@(private = "file")
OID_P384 := []byte{0x2b, 0x81, 0x04, 0x00, 0x22}

@(private = "file")
pkcs8_key :: proc(id: ^Tls_Identity, der: []byte) -> bool {
	outer := Der{buf = der}
	seq := der_in(&outer, 0x30)
	_ = der_uint(&seq)
	alg := der_in(&seq, 0x30)
	_, oid := der_next(&alg)
	_, params := der_next(&alg)
	_, key := der_next(&seq)
	if seq.bad || alg.bad {
		return false
	}
	switch {
	case string(oid) == string(OID_EC):
		return sec1_key(id, key, params)
	case string(oid) == string(OID_RSA):
		return pkcs1_key(id, key)
	}
	return false
}

@(private = "file")
sec1_key :: proc(id: ^Tls_Identity, der: []byte, curve_oid: []byte) -> bool {
	outer := Der{buf = der}
	seq := der_in(&outer, 0x30)
	_ = der_uint(&seq)
	tag, secret := der_next(&seq)
	curve := curve_oid
	for !seq.bad && seq.pos < len(seq.buf) {
		t, body := der_next(&seq)
		if t == 0xa0 { // [0] the curve
			inner := Der{buf = body}
			_, curve = der_next(&inner)
		}
	}
	if seq.bad || tag != 0x04 {
		return false
	}
	switch string(curve) {
	case string(OID_P256):
		id.scheme = 0x0403
		return ecdsa.private_key_set_bytes(&id.ec, .SECP256R1, secret)
	case string(OID_P384):
		id.scheme = 0x0503
		return ecdsa.private_key_set_bytes(&id.ec, .SECP384R1, secret)
	}
	return false
}

@(private = "file")
pkcs1_key :: proc(id: ^Tls_Identity, der: []byte) -> bool {
	outer := Der{buf = der}
	seq := der_in(&outer, 0x30)
	_ = der_uint(&seq)
	n, e, d, p, q := der_uint(&seq), der_uint(&seq), der_uint(&seq), der_uint(&seq), der_uint(&seq)
	dp, dq, iq := der_uint(&seq), der_uint(&seq), der_uint(&seq)
	if seq.bad || len(n) < 256 {
		return false // RSA under 2048 bits is not to be had
	}
	id.scheme = 0x0804
	return rsa.private_key_set_bytes(&id.rsa, n, e, d, p, q, dp, dq, iq)
}

// ---------------------------------------------------------------- the handshake

@(private = "file")
RETRY := [32]byte{
	0xcf, 0x21, 0xad, 0x74, 0xe5, 0x9a, 0x61, 0x11, 0xbe, 0x1d, 0x8c, 0x02, 0x1e, 0x65, 0xb8, 0x91,
	0xc2, 0xa2, 0x11, 0x16, 0x7a, 0xbb, 0x8c, 0x5e, 0x07, 0x9e, 0x09, 0xe2, 0xc8, 0xa8, 0x33, 0x9c,
} // SHA-256("HelloRetryRequest"), as a ServerHello's random

// Consumes bytes from the wire: plaintext is appended to `plain`, what to send back to `w`. False when the connection is
// over, after an alert, if any, has been put in `w`.
tls_accept :: proc(t: ^Tls_Server, bytes: []byte, plain, w: ^[dynamic]byte, find: Tls_Find, data: rawptr) -> bool {
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
		if rest[0] < 20 || rest[0] > 23 || rest[1] != 3 {
			return tls_fail(t, 10, w) // not TLS: plain HTTP to the wrong port, say
		}
		if n > TLS_RECORD + 256 || n == 0 {
			return tls_fail(t, 22, w) // record_overflow
		}
		if len(rest) < 5 + n {
			return true
		}
		type, body := rest[0], rest[5:][:n]
		used += 5 + n
		if type == 20 {
			if t.state != .Flight && t.state != .Retried || n != 1 || body[0] != 1 {
				return tls_fail(t, 10, w) // unexpected_message
			}
			continue // change_cipher_spec, for appearances
		}
		if t.state == .Flight || t.state == .Open {
			ok: bool
			if type != 23 {
				return tls_fail(t, 10, w)
			}
			body, ok = tls_open(&t.recv, body, rest[:5])
			if !ok {
				return tls_fail(t, 20, w) // bad_record_mac
			}
			for len(body) > 0 && body[len(body) - 1] == 0 {
				body = body[:len(body) - 1]
			}
			if len(body) == 0 {
				return tls_fail(t, 10, w)
			}
			type = body[len(body) - 1]
			body = body[:len(body) - 1]
		}
		switch type {
		case 21:
			t.state = .Closed
			return false
		case 22:
			append(&t.messages, ..body)
			tls_server_messages(t, w, find, data) or_return
		case 23:
			if t.state != .Open {
				return tls_fail(t, 10, w)
			}
			append(plain, ..body)
		case:
			return tls_fail(t, 10, w)
		}
	}
	return t.state != .Closed
}

// Appends plaintext as records.
tls_server_write :: proc(t: ^Tls_Server, plain: []byte, w: ^[dynamic]byte) {
	plain := plain
	for len(plain) > 0 {
		n := min(len(plain), TLS_RECORD)
		tls_seal(&t.send, 23, plain[:n], w)
		plain = plain[n:]
	}
}

// Says that nothing more will come from this end.
tls_server_close :: proc(t: ^Tls_Server, w: ^[dynamic]byte) {
	if t.state == .Open {
		tls_seal(&t.send, 21, {1, 0}, w)
	}
}

// Ends with an alert, in the open while there are no keys yet. Always false.
@(private = "file")
tls_fail :: proc(t: ^Tls_Server, alert: u8, w: ^[dynamic]byte) -> bool {
	if t.state == .Closed {
		return false
	}
	t.alert = alert
	if t.state == .Hello || t.state == .Retried {
		append(w, 21, 3, 3, 0, 2, 2, alert)
	} else {
		tls_seal(&t.send, 21, {2, alert}, w)
	}
	t.state = .Closed
	return false
}

@(private = "file")
tls_server_messages :: proc(t: ^Tls_Server, w: ^[dynamic]byte, find: Tls_Find, data: rawptr) -> bool {
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
		if n > 1 << 16 {
			return tls_fail(t, 50, w) // decode_error
		}
		if len(rest) < 4 + n {
			return true
		}
		m := rest[:4 + n]
		used += len(m)
		switch t.state {
		case .Hello, .Retried:
			if m[0] != 1 {
				return tls_fail(t, 10, w)
			}
			tls_client_hello(t, m, w, find, data) or_return
		case .Flight:
			if m[0] != 20 {
				return tls_fail(t, 10, w)
			}
			hash := tls_hash_of(&t.transcript)
			key := tls_expand(t.client_hs, "finished", nil)
			want := zsp.hmac256(key[:], hash[:])
			if n != 32 || crypto.compare_constant_time(want[:], m[4:]) != 1 {
				return tls_fail(t, 51, w) // decrypt_error
			}
			sha2.update(&t.transcript, m)
			tls_key(&t.recv, t.client_app)
			t.state = .Open
		case .Open:
			switch {
			case m[0] == 24 && n == 1 && m[4] <= 1: // key_update
				t.client_app = tls_expand(t.client_app, "traffic upd", nil)
				tls_key(&t.recv, t.client_app)
				if m[4] == 1 {
					tls_seal(&t.send, 22, {24, 0, 0, 1, 0}, w)
					t.server_app = tls_expand(t.server_app, "traffic upd", nil)
					tls_key(&t.send, t.server_app)
				}
			case:
				return tls_fail(t, 10, w) // nothing else is asked of a server once open
			}
		case .Closed:
			return false
		}
	}
}

@(private = "file")
tls_hash_of :: proc(c: ^sha2.Context_256) -> (out: zsp.Key32) {
	ctx := c^
	sha2.final(&ctx, out[:])
	return
}

@(private = "file")
tls_client_hello :: proc(t: ^Tls_Server, m: []byte, w: ^[dynamic]byte, find: Tls_Find, data: rawptr) -> bool {
	r := zsp.Reader{buf = m, pos = 4}
	_ = zsp.read_take(&r, 2 + 32)
	session := zsp.read_take(&r, int(zsp.read_u8(&r)))
	suites := zsp.Reader{buf = zsp.read_take(&r, tls_u16(&r))}
	_ = zsp.read_take(&r, int(zsp.read_u8(&r)))
	ext := zsp.Reader{buf = zsp.read_take(&r, tls_u16(&r))}
	if r.bad || len(session) > 32 {
		return tls_fail(t, 50, w)
	}
	suite := u16(0)
	for !suites.bad && suites.pos + 2 <= len(suites.buf) {
		s := u16(tls_u16(&suites))
		if (s == TLS_AES_128_GCM || s == TLS_CHACHA20) && suite == 0 {
			suite = s // the client's first choice of the two
		}
	}
	modern, x25519, alpn := false, false, false
	share: Maybe(zsp.Key32)
	schemes := zsp.Reader{}
	name := ""
	for !ext.bad && ext.pos < len(ext.buf) {
		type := tls_u16(&ext)
		body := zsp.Reader{buf = zsp.read_take(&ext, tls_u16(&ext))}
		switch type {
		case 0: // server_name
			list := zsp.Reader{buf = zsp.read_take(&body, tls_u16(&body))}
			for !list.bad && list.pos < len(list.buf) {
				kind := zsp.read_u8(&list)
				host := zsp.read_take(&list, tls_u16(&list))
				if kind == 0 && !list.bad {
					name = string(host)
				}
			}
		case 10: // supported_groups
			list := zsp.Reader{buf = zsp.read_take(&body, tls_u16(&body))}
			for !list.bad && list.pos + 2 <= len(list.buf) {
				group := tls_u16(&list) // read first: ||= would not, once it holds
				x25519 ||= group == 29
			}
		case 13: // signature_algorithms
			schemes = zsp.Reader{buf = zsp.read_take(&body, tls_u16(&body))}
		case 16: // ALPN
			list := zsp.Reader{buf = zsp.read_take(&body, tls_u16(&body))}
			for !list.bad && list.pos < len(list.buf) {
				protocol := string(zsp.read_take(&list, int(zsp.read_u8(&list))))
				alpn ||= protocol == "http/1.1"
			}
		case 43: // supported_versions
			list := zsp.Reader{buf = zsp.read_take(&body, int(zsp.read_u8(&body)))}
			for !list.bad && list.pos + 2 <= len(list.buf) {
				version := tls_u16(&list)
				modern ||= version == 0x0304
			}
		case 51: // key_share
			list := zsp.Reader{buf = zsp.read_take(&body, tls_u16(&body))}
			for !list.bad && list.pos < len(list.buf) {
				group := tls_u16(&list)
				key := zsp.read_take(&list, tls_u16(&list))
				if group == 29 && len(key) == 32 && !list.bad {
					k: zsp.Key32
					copy(k[:], key)
					share = k
				}
			}
		}
		if body.bad {
			return tls_fail(t, 50, w)
		}
	}
	if ext.bad {
		return tls_fail(t, 50, w)
	}
	if !modern {
		return tls_fail(t, 70, w) // protocol_version: nothing older than 1.3 is spoken here
	}
	if suite == 0 || !x25519 {
		return tls_fail(t, 40, w) // handshake_failure
	}
	if t.state == .Retried && (name != tls_server_name(t) || suite != t.suite || share == nil) {
		return tls_fail(t, 47, w) // illegal_parameter
	}
	// Which name, and whether it has an identity here.
	if len(name) > len(t.name) {
		return tls_fail(t, 112, w) // unrecognized_name
	}
	for c, i in transmute([]byte)name {
		t.name[i] = c + 32 if c >= 'A' && c <= 'Z' else c
	}
	t.name_len = len(name)
	id := find(data, tls_server_name(t))
	if id == nil {
		return tls_fail(t, 112, w)
	}
	scheme_ok := false
	for !schemes.bad && schemes.pos + 2 <= len(schemes.buf) {
		scheme := u16(tls_u16(&schemes))
		scheme_ok ||= scheme == id.scheme
	}
	if !scheme_ok {
		return tls_fail(t, 40, w)
	}
	if t.state == .Hello {
		sha2.init_256(&t.transcript)
		copy(t.session[:], session)
		t.session_len = len(session)
		t.suite = suite
	}
	theirs, guessed := share.?
	if !guessed {
		// It offered X25519 but did not guess it: ask again. The first hello is remembered by its hash alone.
		first := zsp.sha256(m)
		sha2.update(&t.transcript, {254, 0, 0, 32})
		sha2.update(&t.transcript, first[:])
		hrr := server_hello(t, RETRY, nil)
		sha2.update(&t.transcript, hrr)
		append(w, 22, 3, 3, byte(len(hrr) >> 8), byte(len(hrr)))
		append(w, ..hrr)
		if t.session_len > 0 {
			append(w, 20, 3, 3, 0, 1, 1)
		}
		t.state = .Retried
		return true
	}
	sha2.update(&t.transcript, m)

	secret: zsp.Key32
	crypto.rand_bytes(secret[:])
	defer crypto.zero_explicit(&secret, 32)
	public := zsp.x25519_public(secret)
	shared, ok := zsp.x25519_shared(secret, theirs)
	if !ok {
		return tls_fail(t, 47, w)
	}
	random: [32]byte
	crypto.rand_bytes(random[:])
	hello := server_hello(t, random, &public)
	sha2.update(&t.transcript, hello)
	append(w, 22, 3, 3, byte(len(hello) >> 8), byte(len(hello)))
	append(w, ..hello)
	if t.session_len > 0 && t.state == .Hello {
		append(w, 20, 3, 3, 0, 1, 1)
	}

	hash := tls_hash_of(&t.transcript)
	zero: zsp.Key32
	empty := zsp.sha256()
	early := zsp.hmac256(zero[:], zero[:])
	salt := tls_expand(early, "derived", empty[:])
	hs := zsp.hmac256(salt[:], shared[:])
	t.client_hs = tls_expand(hs, "c hs traffic", hash[:])
	t.server_hs = tls_expand(hs, "s hs traffic", hash[:])
	salt = tls_expand(hs, "derived", empty[:])
	t.master = zsp.hmac256(salt[:], zero[:])
	t.send.aes, t.recv.aes = suite == TLS_AES_128_GCM, suite == TLS_AES_128_GCM
	tls_key(&t.send, t.server_hs)
	tls_key(&t.recv, t.client_hs)

	// The encrypted flight: extensions, the chain, a signature of all so far, and Finished.
	flight := make([dynamic]byte, context.temp_allocator)
	msg :: proc(flight: ^[dynamic]byte, t: ^Tls_Server, type: byte, body: []byte) {
		at := len(flight)
		append(flight, type, 0, 0, 0)
		append(flight, ..body)
		put_u24(flight[at + 1:], len(body))
		sha2.update(&t.transcript, flight[at:])
	}
	ee := make([dynamic]byte, context.temp_allocator)
	if alpn {
		append(&ee, 0, 16, 0, 11, 0, 9, 8) // ALPN: http/1.1, for whatever is behind speaks it
		append(&ee, "http/1.1")
	}
	ext_len := len(ee)
	inject_at(&ee, 0, byte(ext_len >> 8), byte(ext_len))
	msg(&flight, t, 8, ee[:])
	cert := make([dynamic]byte, context.temp_allocator)
	append(&cert, 0, 0, 0, 0)
	for c in id.chain {
		append(&cert, byte(len(c) >> 16), byte(len(c) >> 8), byte(len(c)))
		append(&cert, ..c)
		append(&cert, 0, 0)
	}
	put_u24(cert[1:], len(cert) - 4)
	msg(&flight, t, 11, cert[:])
	signed := make([dynamic]byte, context.temp_allocator)
	for _ in 0 ..< 64 {
		append(&signed, 0x20)
	}
	append(&signed, "TLS 1.3, server CertificateVerify")
	append(&signed, 0)
	digest := tls_hash_of(&t.transcript)
	append(&signed, ..digest[:])
	sig: []byte
	switch id.scheme {
	case 0x0403:
		sig, ok = ecdsa.sign_asn1(&id.ec, .SHA256, signed[:], context.temp_allocator)
	case 0x0503:
		sig, ok = ecdsa.sign_asn1(&id.ec, .SHA384, signed[:], context.temp_allocator)
	case 0x0804:
		sig = make([]byte, rsa.private_key_size(&id.rsa), context.temp_allocator)
		ok = rsa.sign_pss(&id.rsa, chash.Algorithm.SHA256, 32, signed[:], sig)
	}
	if !ok {
		return tls_fail(t, 80, w) // internal_error
	}
	verify := make([dynamic]byte, context.temp_allocator)
	append(&verify, byte(id.scheme >> 8), byte(id.scheme), byte(len(sig) >> 8), byte(len(sig)))
	append(&verify, ..sig)
	msg(&flight, t, 15, verify[:])
	hash = tls_hash_of(&t.transcript)
	key := tls_expand(t.server_hs, "finished", nil)
	mac := zsp.hmac256(key[:], hash[:])
	msg(&flight, t, 20, mac[:])
	for at := 0; at < len(flight); at += TLS_RECORD {
		tls_seal(&t.send, 22, flight[at:min(at + TLS_RECORD, len(flight))], w)
	}
	hash = tls_hash_of(&t.transcript)
	t.client_app = tls_expand(t.master, "c ap traffic", hash[:])
	t.server_app = tls_expand(t.master, "s ap traffic", hash[:])
	tls_key(&t.send, t.server_app)
	t.state = .Flight
	return true
}

// A ServerHello, or with `share` nil, a HelloRetryRequest naming X25519.
@(private = "file")
server_hello :: proc(t: ^Tls_Server, random: [32]byte, share: ^zsp.Key32) -> []byte {
	random := random
	m := make([dynamic]byte, context.temp_allocator)
	append(&m, 2, 0, 0, 0, 3, 3)
	append(&m, ..random[:])
	append(&m, byte(t.session_len))
	append(&m, ..t.session[:t.session_len])
	append(&m, byte(t.suite >> 8), byte(t.suite), 0)
	ext := len(m)
	append(&m, 0, 0)
	append(&m, 0, 43, 0, 2, 3, 4) // supported_versions: 1.3
	if share != nil {
		append(&m, 0, 51, 0, 36, 0, 29, 0, 32) // key_share
		append(&m, ..share[:])
	} else {
		append(&m, 0, 51, 0, 2, 0, 29) // key_share: X25519, please
	}
	put_u16(m[ext:], len(m) - ext - 2)
	put_u24(m[1:], len(m) - 4)
	return m[:]
}
