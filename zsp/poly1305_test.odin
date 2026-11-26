#+build !js
package zsp

import "core:crypto/chacha20poly1305"
import "core:crypto/poly1305"
import "core:encoding/hex"
import "core:math/rand"
import "core:testing"

@(private = "file")
unhex :: proc(s: string) -> []byte {
	b, ok := hex.decode(transmute([]byte)s, context.temp_allocator)
	assert(ok)
	return b
}

@(test)
poly1305_rfc8439 :: proc(t: ^testing.T) {
	// §2.5.2
	key := unhex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
	msg := "Cryptographic Forum Research Group"
	tag: [16]byte
	p: Poly1305
	poly_init(&p, key)
	poly_update(&p, transmute([]byte)msg)
	poly_final(&p, tag[:])
	testing.expect_value(t, string(hex.encode(tag[:], context.temp_allocator)), "a8061dc1305136c6c22b8baf0c0127a9")
	// A.3, #11: what is carried at the end wraps past 2¹³⁰ - 5, and #6 and #7: h comes out at p and just past it.
	cases := [?][3]string {
		{
			"0100000000000000040000000000000000000000000000000000000000000000",
			"e33594d7505e43b900000000000000003394d7505e4379cd01000000000000000000000000000000000000000000000001000000000000000000000000000000",
			"14000000000000005500000000000000",
		},
		{
			"0200000000000000000000000000000000000000000000000000000000000000",
			"ffffffffffffffffffffffffffffffff",
			"03000000000000000000000000000000",
		},
		{
			"02000000000000000000000000000000ffffffffffffffffffffffffffffffff",
			"02000000000000000000000000000000",
			"03000000000000000000000000000000",
		},
		{
			"0100000000000000000000000000000000000000000000000000000000000000",
			"fffffffffffffffffffffffffffffffff0ffffffffffffffffffffffffffffff11000000000000000000000000000000",
			"05000000000000000000000000000000",
		},
		{
			"0100000000000000000000000000000000000000000000000000000000000000",
			"fffffffffffffffffffffffffffffffffbfefefefefefefefefefefefefefefe01010101010101010101010101010101",
			"00000000000000000000000000000000",
		},
		{
			"0200000000000000000000000000000000000000000000000000000000000000",
			"fdffffffffffffffffffffffffffffff",
			"faffffffffffffffffffffffffffffff",
		},
	}
	for c in cases {
		poly_init(&p, unhex(c[0]))
		poly_update(&p, unhex(c[1]))
		poly_final(&p, tag[:])
		testing.expect_value(t, string(hex.encode(tag[:], context.temp_allocator)), c[2])
	}
}

@(test)
chacha_rfc8439 :: proc(t: ^testing.T) {
	// §2.8.2
	key := unhex("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
	iv := unhex("070000004041424344454647")
	ad := unhex("50515253c0c1c2c3c4c5c6c7")
	plain := "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it."
	out := make([]byte, len(plain), context.temp_allocator)
	tag: [16]byte
	chacha_seal(key, iv, out, tag[:], ad, transmute([]byte)plain)
	testing.expect_value(
		t,
		string(hex.encode(out, context.temp_allocator)),
		"d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116",
	)
	testing.expect_value(t, string(hex.encode(tag[:], context.temp_allocator)), "1ae10b594f09e26a7e902ecbd0600691")
	back := make([]byte, len(plain), context.temp_allocator)
	testing.expect(t, chacha_open(key, iv, back, ad, out, tag[:]))
	testing.expect_value(t, string(back), plain)
	tag[3] ~= 1
	testing.expect(t, !chacha_open(key, iv, back, ad, out, tag[:]))
	testing.expect(t, all_zero(back))
}

@(private = "file")
all_zero :: proc(b: []byte) -> bool {
	for x in b {
		if x != 0 {
			return false
		}
	}
	return true
}

// A key or message of random bytes, or now and then of all ones, all zeros, or nearly all ones, so that the limbs
// come as near their bounds as they can.
@(private = "file")
fill :: proc(b: []byte, r: ^rand.Generator) {
	switch rand.int_max(8, r^) {
	case 0:
		for &x in b {x = 0xff}
	case 1:
		for &x in b {x = 0}
	case 2:
		for &x in b {x = 0xff - byte(rand.int_max(2, r^))}
	case:
		for &x in b {x = byte(rand.uint32(r^))}
	}
}

@(test)
poly1305_as_core :: proc(t: ^testing.T) {
	state := rand.create(0x9017_1305)
	r := rand.default_random_generator(&state)
	buf := make([]byte, 4200, context.temp_allocator)
	key: [32]byte
	for round in 0 ..< 6000 {
		n := round < 1100 ? round : rand.int_max(len(buf), r)
		msg := buf[:n]
		fill(key[:], &r)
		fill(msg, &r)
		want, got: [16]byte
		poly1305.sum(want[:], msg, key[:])
		// In pieces of random lengths, so that every way a block can be split across updates is met.
		p: Poly1305
		poly_init(&p, key[:])
		p.portable = round % 2 == 1
		rest := msg
		for len(rest) > 0 {
			piece := min(len(rest), rand.int_max(4, r) == 0 ? rand.int_max(40, r) : rand.int_max(len(rest) + 1, r))
			poly_update(&p, rest[:piece])
			rest = rest[piece:]
		}
		poly_final(&p, got[:])
		if want != got {
			testing.expectf(t, false, "round %d, %d bytes, key %x: %x, not %x", round, n, key, got, want)
			return
		}
	}
}

@(test)
chacha_as_core :: proc(t: ^testing.T) {
	state := rand.create(0xc4ac_4a20)
	r := rand.default_random_generator(&state)
	plain := make([]byte, 3000, context.temp_allocator)
	sealed := make([]byte, len(plain), context.temp_allocator)
	theirs := make([]byte, len(plain), context.temp_allocator)
	ad := make([]byte, 300, context.temp_allocator)
	key: [32]byte
	iv: [24]byte
	for round in 0 ..< 3000 {
		n := round < 600 ? round : rand.int_max(len(plain), r)
		a := rand.int_max(4, r) == 0 ? 0 : rand.int_max(len(ad), r)
		x := rand.int_max(2, r) == 0
		ivn := x ? 24 : 12
		fill(key[:], &r)
		fill(iv[:], &r)
		fill(plain[:n], &r)
		fill(ad[:a], &r)
		ctx: chacha20poly1305.Context
		if x {
			chacha20poly1305.init_xchacha(&ctx, key[:])
		} else {
			chacha20poly1305.init(&ctx, key[:])
		}
		want, got: [16]byte
		chacha20poly1305.seal(&ctx, theirs[:n], want[:], iv[:ivn], ad[:a], plain[:n])
		chacha_seal(key[:], iv[:ivn], sealed[:n], got[:], ad[:a], plain[:n])
		if want != got || string(theirs[:n]) != string(sealed[:n]) {
			testing.expectf(t, false, "round %d: %d bytes, %d of ad, iv of %d: not as core", round, n, a, ivn)
			return
		}
		// Opened in place, and refused, its bytes zeroed, when any one bit of it, its ad or its tag is wrong.
		testing.expect(t, chacha_open(key[:], iv[:ivn], sealed[:n], ad[:a], sealed[:n], got[:]))
		testing.expect(t, string(sealed[:n]) == string(plain[:n]))
		copy(sealed, theirs[:n])
		which := rand.int_max(3, r)
		switch {
		case which == 0 && n > 0:
			sealed[rand.int_max(n, r)] ~= 1 << uint(rand.int_max(8, r))
		case which == 1 && a > 0:
			ad[rand.int_max(a, r)] ~= 1 << uint(rand.int_max(8, r))
		case:
			got[rand.int_max(16, r)] ~= 1 << uint(rand.int_max(8, r))
		}
		testing.expect(t, !chacha_open(key[:], iv[:ivn], sealed[:n], ad[:a], sealed[:n], got[:]))
		testing.expect(t, all_zero(sealed[:n]))
	}
}
