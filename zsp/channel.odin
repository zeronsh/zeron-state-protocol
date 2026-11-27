package zsp

import "core:crypto"
import "core:crypto/x25519"
import "core:encoding/endian"

// Every untrusted byte pipe is wrapped in Noise_IK_25519_ChaChaPoly_SHA256, whose one round trip
// authenticates both ends. The prologue binds the channel to one space. Payloads are empty.
//
// core:crypto/noise is complete, and compiling all of it dominates the build; this is the one
// pattern, checked against it.

NOISE :: "Noise_IK_25519_ChaChaPoly_SHA256"
HANDSHAKE_1 :: 104 // e, es, s, ss: 32 + (32 + 16) + (8 + 16)
HANDSHAKE_2 :: 48 // e, ee, se:    32 + 16

Handshake :: struct {
	hash, chain, key: Key32,
	n:                u64,
	secret, eph:      Key32,
}

// Transport keys, small and plain so that a hibernating host can persist them.
Channel :: struct {
	send, recv:     Key32,
	send_n, recv_n: u64,
	peer:           Key32,
	began: u64, // when the initiator says it did
}

@(require_results)
x25519_public :: proc(secret: Key32) -> (public: Key32) {
	secret := secret
	x25519.scalarmult_basepoint(public[:], secret[:])
	return
}

@(require_results)
x25519_shared :: proc(secret, public: Key32) -> (shared: Key32, ok: bool) {
	secret, public := secret, public
	x25519.scalarmult(shared[:], secret[:], public[:])
	ok = crypto.is_zero_constant_time(shared[:]) == 0
	return
}

// Whether a public key is one a secret can be shared with: not one of the few points of small order, with which
// every secret shares nothing. They are as libsodium lists them. Public, so not in constant time.
@(require_results)
x25519_sound :: proc "contextless" (public: Key32) -> bool {
	ORDER_8 :: [2]Key32 {
		{0xe0, 0xeb, 0x7a, 0x7c, 0x3b, 0x41, 0xb8, 0xae, 0x16, 0x56, 0xe3, 0xfa, 0xf1, 0x9f, 0xc4, 0x6a, 0xda, 0x09, 0x8d, 0xeb, 0x9c, 0x32, 0xb1, 0xfd, 0x86, 0x62, 0x05, 0x16, 0x5f, 0x49, 0xb8, 0x00},
		{0x5f, 0x9c, 0x95, 0xbc, 0xa3, 0x50, 0x8c, 0x24, 0xb1, 0xd0, 0xb1, 0x55, 0x9c, 0x83, 0xef, 0x5b, 0x04, 0x44, 0x5c, 0xc4, 0x58, 0x1c, 0x8e, 0x86, 0xd8, 0x22, 0x4e, 0xdd, 0xd0, 0x9f, 0x11, 0x57},
	}
	k := public
	k[31] &= 0x7f // not part of the number
	zeros, ones := true, true
	for b in k[1:31] {
		zeros &&= b == 0
		ones &&= b == 0xff
	}
	if zeros && k[31] == 0 && k[0] <= 1 {
		return false // 0 and 1
	}
	if ones && k[31] == 0x7f && k[0] >= 0xec && k[0] <= 0xee {
		return false // p - 1, p and p + 1, which are -1, 0 and 1
	}
	return k != ORDER_8[0] && k != ORDER_8[1]
}

@(private)
handshake_init :: proc(h: ^Handshake, secret, responder, space: Key32) {
	space, responder := space, responder
	copy(h.hash[:], NOISE)
	h.chain = h.hash
	h.hash = sha256(h.hash[:], transmute([]byte)string("zsp-1"), space[:])
	h.hash = sha256(h.hash[:], responder[:])
	h.secret = secret
}

@(private)
handshake_mix_hash :: proc(h: ^Handshake, data: []byte) {
	h.hash = sha256(h.hash[:], data)
}

@(private)
handshake_mix_dh :: proc(h: ^Handshake, secret, public: Key32) -> bool {
	shared := x25519_shared(secret, public) or_return
	h.chain, h.key = handshake_hkdf(h, shared[:])
	h.n = 0
	return true
}

@(private)
handshake_hkdf :: proc(h: ^Handshake, input: []byte) -> (a, b: Key32) {
	prk := hmac256(h.chain[:], input)
	a = hmac256(prk[:], {1})
	b = hmac256(prk[:], a[:], {2})
	return
}

@(private)
handshake_seal :: proc(h: ^Handshake, out: []byte, plain: []byte) {
	iv := channel_nonce(h.n)
	h.n += 1
	chacha_seal(h.key[:], iv[:], out[:len(plain)], out[len(plain):], h.hash[:], plain)
	handshake_mix_hash(h, out)
}

@(private)
handshake_open :: proc(h: ^Handshake, out: []byte, sealed: []byte) -> bool {
	iv := channel_nonce(h.n)
	h.n += 1
	chacha_open(h.key[:], iv[:], out, h.hash[:], sealed[:len(out)], sealed[len(out):]) or_return
	handshake_mix_hash(h, sealed)
	return true
}

@(private)
handshake_split :: proc(h: ^Handshake, initiator: bool) -> (c: Channel) {
	c.send, c.recv = handshake_hkdf(h, nil)
	if !initiator {
		c.send, c.recv = c.recv, c.send
	}
	return
}

// The initiator's half. `peer` is the responder's expected key. Where an old first message may be sent again by
// anyone, `when_` tells it from a new one.
@(require_results)
handshake_start :: proc(h: ^Handshake, secret, peer, space: Key32, eph: Maybe(Key32) = nil, when_: u64 = 0) -> (first: [HANDSHAKE_1]byte, ok: bool) {
	handshake_init(h, secret, peer, space)
	if e, given := eph.?; given {
		h.eph = e
	} else {
		crypto.rand_bytes(h.eph[:])
	}
	e, s := x25519_public(h.eph), x25519_public(secret)
	copy(first[:], e[:])
	handshake_mix_hash(h, e[:])
	handshake_mix_dh(h, h.eph, peer) or_return
	handshake_seal(h, first[32:80], s[:])
	handshake_mix_dh(h, secret, peer) or_return
	said: [8]byte
	put_u64(said[:], when_)
	handshake_seal(h, first[80:], said[:])
	return first, true
}

@(require_results)
handshake_finish :: proc(h: ^Handshake, second: []byte, peer: Key32) -> (c: Channel, ok: bool) {
	if len(second) != HANDSHAKE_2 {
		return
	}
	h := h^ // a forged answer must not spoil the real one
	re: Key32
	copy(re[:], second)
	handshake_mix_hash(&h, re[:])
	handshake_mix_dh(&h, h.eph, re) or_return
	handshake_mix_dh(&h, h.secret, re) or_return
	handshake_open(&h, nil, second[32:]) or_return
	c = handshake_split(&h, true)
	c.peer = peer
	return c, true
}

// The responder's whole part.
@(require_results)
handshake_answer :: proc(secret, space: Key32, first: []byte, eph: Maybe(Key32) = nil) -> (second: [HANDSHAKE_2]byte, c: Channel, ok: bool) {
	if len(first) != HANDSHAKE_1 {
		return
	}
	h: Handshake
	defer crypto.zero_explicit(&h, size_of(h))
	handshake_init(&h, secret, x25519_public(secret), space)
	re, rs: Key32
	copy(re[:], first)
	handshake_mix_hash(&h, re[:])
	handshake_mix_dh(&h, secret, re) or_return
	handshake_open(&h, rs[:], first[32:80]) or_return
	handshake_mix_dh(&h, secret, rs) or_return
	said: [8]byte
	handshake_open(&h, said[:], first[80:]) or_return

	if e, given := eph.?; given {
		h.eph = e
	} else {
		crypto.rand_bytes(h.eph[:])
	}
	e := x25519_public(h.eph)
	copy(second[:], e[:])
	handshake_mix_hash(&h, e[:])
	handshake_mix_dh(&h, h.eph, re) or_return
	handshake_mix_dh(&h, h.eph, rs) or_return
	handshake_seal(&h, second[32:], nil)
	c = handshake_split(&h, false)
	c.peer = rs
	c.began = get_u64(said[:])
	return second, c, true
}

@(private)
channel_nonce :: proc(n: u64) -> (iv: [12]byte) {
	endian.unchecked_put_u64le(iv[4:], n)
	return
}

// Appends ciphertext and tag for the next message in order.
channel_seal :: proc(c: ^Channel, w: ^[dynamic]byte, plain: []byte, ad: []byte = nil) {
	channel_seal_at(c, w, c.send_n, plain, ad)
	c.send_n += 1
}

channel_seal_at :: proc(c: ^Channel, w: ^[dynamic]byte, n: u64, plain, ad: []byte) {
	at := len(w)
	resize(w, at + len(plain) + TAG)
	iv := channel_nonce(n)
	chacha_seal(c.send[:], iv[:], w[at:][:len(plain)], w[at + len(plain):], ad, plain)
}

// Seals all but the last TAG bytes of `buf` where they lie, and puts the tag after them.
channel_seal_in_place :: proc(c: ^Channel, n: u64, buf, ad: []byte) {
	body := buf[:len(buf) - TAG]
	iv := channel_nonce(n)
	chacha_seal(c.send[:], iv[:], body, buf[len(body):], ad, body)
}

// Opens the next message in order, in place.
@(require_results)
channel_open :: proc(c: ^Channel, sealed: []byte, ad: []byte = nil) -> (plain: []byte, ok: bool) {
	plain = channel_open_at(c, c.recv_n, sealed, ad) or_return
	c.recv_n += 1
	return plain, true
}

@(require_results)
channel_open_at :: proc(c: ^Channel, n: u64, sealed, ad: []byte) -> (plain: []byte, ok: bool) {
	size := len(sealed) - TAG
	if size < 0 {
		return
	}
	iv := channel_nonce(n)
	chacha_open(c.recv[:], iv[:], sealed[:size], ad, sealed[:size], sealed[size:]) or_return
	return sealed[:size], true
}
