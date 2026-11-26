package zsp

import "base:intrinsics"
import "core:crypto"
import "core:crypto/chacha20"
import "core:encoding/endian"
import "core:simd"

// ChaCha20-Poly1305 (RFC 8439) and XChaCha20-Poly1305, byte for byte what core:crypto/chacha20poly1305 makes and
// takes, with this package's Poly1305 in place of core's: the iv's length says which, 12 bytes or 24. The tests hold
// the two equal, on RFC 8439's vectors and on random keys, ivs and lengths.

// Encrypts `plain` into `out`, of the same length (the two may be the same bytes), and writes the tag that binds it
// and `ad`.
chacha_seal :: proc(key: []byte, iv: []byte, out, tag, ad, plain: []byte) {
	ensure(len(out) == len(plain) && len(tag) == POLY_TAG)
	stream: chacha20.Context = ---
	mac: Poly1305 = ---
	ks: Keystream = ---
	chacha_begin(&stream, &mac, &ks, key, iv, len(plain))
	poly_update(&mac, ad)
	poly_pad16(&mac)
	chacha_xor(&stream, &ks, out, plain)
	chacha20.reset(&stream)
	chacha_end(&mac, len(ad), out, tag)
}

// Decrypts `sealed` into `out`, of the same length (the two may be the same bytes), if `tag` binds it and `ad`;
// if not, `out` is left zeroed.
@(require_results)
chacha_open :: proc(key: []byte, iv: []byte, out, ad, sealed, tag: []byte) -> bool {
	ensure(len(out) == len(sealed) && len(tag) == POLY_TAG)
	stream: chacha20.Context = ---
	mac: Poly1305 = ---
	ks: Keystream = ---
	chacha_begin(&stream, &mac, &ks, key, iv, len(sealed))
	defer chacha20.reset(&stream)
	poly_update(&mac, ad)
	poly_pad16(&mac)
	want: [POLY_TAG]byte
	chacha_end(&mac, len(ad), sealed, want[:])
	same := crypto.compare_constant_time(tag, want[:]) == 1
	crypto.zero_explicit(&want, size_of(want))
	if !same {
		crypto.zero_explicit(&ks.bytes, ks.made + 64)
		crypto.zero_explicit(raw_data(out), len(out))
		return false
	}
	chacha_xor(&stream, &ks, out, sealed)
	return true
}

// Keystream made at the start: block 0, the first half of which is Poly1305's key, and as many blocks after it as the
// message wants, up to so many. Made together they are made eight at a time, where one by one block 0 and the end
// would each be made alone.
@(private = "file")
CHACHA_FIRST :: 32

@(private = "file")
Keystream :: struct {
	bytes: [CHACHA_FIRST * 64]byte,
	made:  int, // past block 0
}

@(private = "file")
chacha_begin :: proc(stream: ^chacha20.Context, mac: ^Poly1305, ks: ^Keystream, key: []byte, iv: []byte, size: int) {
	ensure(len(key) == 32 && (len(iv) == 12 || len(iv) == 24))
	chacha20.init(stream, key, iv)
	stream._state._is_ietf_flavor = true
	blocks := min(1 + (size + 63) / 64, CHACHA_FIRST)
	chacha20.keystream_bytes(stream, ks.bytes[:blocks * 64])
	ks.made = (blocks - 1) * 64
	poly_init(mac, ks.bytes[:32])
}

// out = in ^ the keystream from block 1 on: what was made at the start first, the rest from the stream.
@(private = "file")
chacha_xor :: proc(stream: ^chacha20.Context, ks: ^Keystream, out, in_: []byte) {
	first := min(len(in_), ks.made)
	xor_into(out[:first], in_[:first], ks.bytes[64:][:first])
	crypto.zero_explicit(&ks.bytes, ks.made + 64)
	if first < len(in_) {
		chacha20.xor_bytes(stream, out[first:], in_[first:])
	}
}

// out = a ^ b, thirty-two bytes at a time; out may be a.
@(private = "file")
xor_into :: proc "contextless" (out, a, b: []byte) {
	U8x32 :: #simd[32]u8
	i := 0
	#no_bounds_check {
		for ; i + 32 <= len(out); i += 32 {
			x := intrinsics.unaligned_load(cast(^U8x32)&a[i])
			y := intrinsics.unaligned_load(cast(^U8x32)&b[i])
			intrinsics.unaligned_store(cast(^U8x32)&out[i], simd.bit_xor(x, y))
		}
		for ; i < len(out); i += 1 {
			out[i] = a[i] ~ b[i]
		}
	}
}

@(private = "file")
chacha_end :: proc(mac: ^Poly1305, ad_len: int, sealed, tag: []byte) {
	poly_update(mac, sealed)
	poly_pad16(mac)
	lengths: [16]byte
	endian.unchecked_put_u64le(lengths[0:], u64(ad_len))
	endian.unchecked_put_u64le(lengths[8:], u64(len(sealed)))
	poly_update(mac, lengths[:])
	poly_final(mac, tag)
}
