package zsp

import "base:intrinsics"
import "core:crypto"
import "core:encoding/endian"
import "core:simd"
import "core:sys/info"

_ :: info // only on amd64

// Poly1305 (RFC 8439), as core:crypto/poly1305 computes it, and faster: in 26-bit limbs, with what is long enough
// taken four blocks at a time in vector lanes, each lane a quarter of the blocks, carried along by r⁴ and brought
// together at the end by r⁴, r³, r² and r. Every step takes the same time whatever the key and the message: no branch
// and no index depends on either. What it computes is held equal to core:crypto/poly1305 by the tests, on RFC 8439's
// vectors and on random keys and messages of every length.

POLY_TAG :: 16

@(private = "file")
MASK26 :: 0x3ffffff

// Blocks taken in lanes once at least this many come together; fewer are cheaper one at a time, the powers of r
// being made for them first.
@(private = "file")
POLY_LANES_FROM :: 16

Poly1305 :: struct {
	r:        [5]u64, // in 26-bit limbs
	r_pow:    [3][5]u64, // r², r³, r⁴, once wanted
	powered:  bool,
	h:        [5]u64,
	pad:      [2]u64,
	buf:      [16]byte,
	left:     int,
	portable: bool, // only the code every target has, for tests to hold it to the rest
}

poly_init :: proc(p: ^Poly1305, key: []byte) {
	assert(len(key) == 32)
	p^ = {}
	p.r[0] = u64(endian.unchecked_get_u32le(key[0:])) & 0x3ffffff
	p.r[1] = u64(endian.unchecked_get_u32le(key[3:]) >> 2) & 0x3ffff03
	p.r[2] = u64(endian.unchecked_get_u32le(key[6:]) >> 4) & 0x3ffc0ff
	p.r[3] = u64(endian.unchecked_get_u32le(key[9:]) >> 6) & 0x3f03fff
	p.r[4] = u64(endian.unchecked_get_u32le(key[12:]) >> 8) & 0x00fffff
	p.pad[0] = endian.unchecked_get_u64le(key[16:])
	p.pad[1] = endian.unchecked_get_u64le(key[24:])
}

poly_update :: proc(p: ^Poly1305, data: []byte) {
	msg := data
	if p.left > 0 {
		want := min(16 - p.left, len(msg))
		copy(p.buf[p.left:], msg[:want])
		p.left += want
		msg = msg[want:]
		if p.left < 16 {
			return
		}
		poly_blocks(p, p.buf[:], 1 << 24)
		p.left = 0
	}
	whole := len(msg) &~ 15
	if whole > 0 {
		blocks := msg[:whole]
		if whole >= POLY_LANES_FROM * 16 {
			lanes := whole &~ 63
			poly_lanes(p, blocks[:lanes])
			blocks = blocks[lanes:]
		}
		if len(blocks) > 0 {
			poly_blocks(p, blocks, 1 << 24)
		}
		msg = msg[whole:]
	}
	if len(msg) > 0 {
		copy(p.buf[:], msg)
		p.left = len(msg)
	}
}

// Pads what is left with zeros to a block's end, as ChaCha20-Poly1305 does between its parts.
poly_pad16 :: proc(p: ^Poly1305) {
	if p.left > 0 {
		for i in p.left ..< 16 {
			p.buf[i] = 0
		}
		poly_blocks(p, p.buf[:], 1 << 24)
		p.left = 0
	}
}

poly_final :: proc(p: ^Poly1305, tag: []byte) {
	assert(len(tag) == POLY_TAG)
	if p.left > 0 {
		p.buf[p.left] = 1
		for i in p.left + 1 ..< 16 {
			p.buf[i] = 0
		}
		poly_blocks(p, p.buf[:], 0)
	}
	h0, h1, h2, h3, h4 := p.h[0], p.h[1], p.h[2], p.h[3], p.h[4]
	c: u64
	c = h1 >> 26; h1 &= MASK26; h2 += c
	c = h2 >> 26; h2 &= MASK26; h3 += c
	c = h3 >> 26; h3 &= MASK26; h4 += c
	c = h4 >> 26; h4 &= MASK26; h0 += c * 5
	c = h0 >> 26; h0 &= MASK26; h1 += c
	// h - p, and whichever of the two is fully reduced, chosen without a branch.
	g0 := h0 + 5; c = g0 >> 26; g0 &= MASK26
	g1 := h1 + c; c = g1 >> 26; g1 &= MASK26
	g2 := h2 + c; c = g2 >> 26; g2 &= MASK26
	g3 := h3 + c; c = g3 >> 26; g3 &= MASK26
	g4 := h4 + c - (1 << 26)
	keep_g := (g4 >> 63) - 1 // all ones when g4 did not go below zero
	keep_h := ~keep_g
	h0 = (h0 & keep_h) | (g0 & keep_g)
	h1 = (h1 & keep_h) | (g1 & keep_g)
	h2 = (h2 & keep_h) | (g2 & keep_g)
	h3 = (h3 & keep_h) | (g3 & keep_g)
	h4 = (h4 & keep_h) | (g4 & keep_g & MASK26)
	lo := h0 | h1 << 26 | h2 << 52
	hi := h2 >> 12 | h3 << 14 | h4 << 40
	sum, carry := intrinsics.overflow_add(lo, p.pad[0])
	endian.unchecked_put_u64le(tag[0:], sum)
	endian.unchecked_put_u64le(tag[8:], hi + p.pad[1] + u64(carry))
	crypto.zero_explicit(p, size_of(p^))
}

// One block at a time: h = (h + m) · r.
@(private = "file")
poly_blocks :: proc(p: ^Poly1305, m: []byte, hibit: u64) {
	r0, r1, r2, r3, r4 := p.r[0], p.r[1], p.r[2], p.r[3], p.r[4]
	s1, s2, s3, s4 := r1 * 5, r2 * 5, r3 * 5, r4 * 5
	h0, h1, h2, h3, h4 := p.h[0], p.h[1], p.h[2], p.h[3], p.h[4]
	for at := 0; at < len(m); at += 16 {
		b := m[at:]
		h0 += u64(endian.unchecked_get_u32le(b[0:])) & MASK26
		h1 += u64(endian.unchecked_get_u32le(b[3:]) >> 2) & MASK26
		h2 += u64(endian.unchecked_get_u32le(b[6:]) >> 4) & MASK26
		h3 += u64(endian.unchecked_get_u32le(b[9:]) >> 6) & MASK26
		h4 += u64(endian.unchecked_get_u32le(b[12:]) >> 8) | hibit
		d0 := h0 * r0 + h1 * s4 + h2 * s3 + h3 * s2 + h4 * s1
		d1 := h0 * r1 + h1 * r0 + h2 * s4 + h3 * s3 + h4 * s2
		d2 := h0 * r2 + h1 * r1 + h2 * r0 + h3 * s4 + h4 * s3
		d3 := h0 * r3 + h1 * r2 + h2 * r1 + h3 * r0 + h4 * s4
		d4 := h0 * r4 + h1 * r3 + h2 * r2 + h3 * r1 + h4 * r0
		c: u64
		c = d0 >> 26; h0 = d0 & MASK26; d1 += c
		c = d1 >> 26; h1 = d1 & MASK26; d2 += c
		c = d2 >> 26; h2 = d2 & MASK26; d3 += c
		c = d3 >> 26; h3 = d3 & MASK26; d4 += c
		c = d4 >> 26; h4 = d4 & MASK26; h0 += c * 5
		c = h0 >> 26; h0 &= MASK26; h1 += c
	}
	p.h = {h0, h1, h2, h3, h4}
}

// a · b, carried so that every limb is below 2²⁶ but the second, a little above at most.
@(private = "file")
poly_mul :: proc(a, b: [5]u64) -> (out: [5]u64) {
	s1, s2, s3, s4 := b[1] * 5, b[2] * 5, b[3] * 5, b[4] * 5
	d0 := a[0] * b[0] + a[1] * s4 + a[2] * s3 + a[3] * s2 + a[4] * s1
	d1 := a[0] * b[1] + a[1] * b[0] + a[2] * s4 + a[3] * s3 + a[4] * s2
	d2 := a[0] * b[2] + a[1] * b[1] + a[2] * b[0] + a[3] * s4 + a[4] * s3
	d3 := a[0] * b[3] + a[1] * b[2] + a[2] * b[1] + a[3] * b[0] + a[4] * s4
	d4 := a[0] * b[4] + a[1] * b[3] + a[2] * b[2] + a[3] * b[1] + a[4] * b[0]
	c: u64
	c = d0 >> 26; out[0] = d0 & MASK26; d1 += c
	c = d1 >> 26; out[1] = d1 & MASK26; d2 += c
	c = d2 >> 26; out[2] = d2 & MASK26; d3 += c
	c = d3 >> 26; out[3] = d3 & MASK26; d4 += c
	c = d4 >> 26; out[4] = d4 & MASK26; out[0] += c * 5
	c = out[0] >> 26; out[0] &= MASK26; out[1] += c
	return
}

// A run of whole blocks, a multiple of four, at least POLY_LANES_FROM of them.
@(private = "file")
poly_lanes :: proc(p: ^Poly1305, m: []byte) {
	if !p.powered {
		r2 := poly_mul(p.r, p.r)
		r3 := poly_mul(r2, p.r)
		p.r_pow = {r2, r3, poly_mul(r3, p.r)}
		p.powered = true
	}
	when ODIN_ARCH == .amd64 {
		if !p.portable && info.cpu_features() >= (info.CPU_Features{.avx, .avx2}) {
			poly_lanes_avx2(p, m)
			return
		}
	}
	poly_lanes_any(p, m)
}

when ODIN_ARCH == .amd64 {
	@(private = "file", enable_target_feature = "avx,avx2")
	poly_lanes_avx2 :: proc(p: ^Poly1305, m: []byte) {
		poly_lanes_vec(p, m)
	}
}

@(private = "file")
poly_lanes_any :: proc(p: ^Poly1305, m: []byte) {
	poly_lanes_vec(p, m)
}

@(private = "file")
U64x4 :: #simd[4]u64

// The four lanes: each takes every fourth block, h·r⁴ + m, the first beginning from h; then each is brought on by
// the power of r that it is short of, and they are added.
@(private = "file")
poly_lanes_vec :: #force_inline proc "contextless" (p: ^Poly1305, m: []byte) {
	mask26 := U64x4(MASK26)
	r4 := p.r_pow[2]
	R0, R1, R2, R3, R4 := U64x4(r4[0]), U64x4(r4[1]), U64x4(r4[2]), U64x4(r4[3]), U64x4(r4[4])
	S1, S2, S3, S4 := R1 * 5, R2 * 5, R3 * 5, R4 * 5

	// The limbs of four blocks, a block a lane.
	load :: #force_inline proc "contextless" (b: []byte) -> (l0, l1, l2, l3, l4: U64x4) {
		v1 := intrinsics.unaligned_load(cast(^U64x4)raw_data(b))
		v2 := intrinsics.unaligned_load(cast(^U64x4)raw_data(b[32:]))
		when ODIN_ENDIAN == .Big {
			v1 = simd.byte_swap(v1)
			v2 = simd.byte_swap(v2)
		}
		lo := simd.shuffle(v1, v2, 0, 2, 4, 6)
		hi := simd.shuffle(v1, v2, 1, 3, 5, 7)
		mask26 := U64x4(MASK26)
		l0 = lo & mask26
		l1 = simd.shr(lo, U64x4(26)) & mask26
		l2 = (simd.shr(lo, U64x4(52)) | simd.shl(hi, U64x4(12))) & mask26
		l3 = simd.shr(hi, U64x4(14)) & mask26
		l4 = simd.shr(hi, U64x4(40)) | U64x4(1 << 24)
		return
	}
	// Lane by lane, the low 32 bits of each times the low 32 bits of each: what one multiply of a vector does.
	mul :: #force_inline proc "contextless" (a, b: U64x4) -> U64x4 {
		low32 := U64x4(0xffffffff)
		return (a & low32) * (b & low32)
	}

	H0, H1, H2, H3, H4 := load(m)
	H0 += simd.replace(U64x4(0), 0, p.h[0])
	H1 += simd.replace(U64x4(0), 0, p.h[1])
	H2 += simd.replace(U64x4(0), 0, p.h[2])
	H3 += simd.replace(U64x4(0), 0, p.h[3])
	H4 += simd.replace(U64x4(0), 0, p.h[4])
	for at := 64; at < len(m); at += 64 {
		D0 := mul(H0, R0) + mul(H1, S4) + mul(H2, S3) + mul(H3, S2) + mul(H4, S1)
		D1 := mul(H0, R1) + mul(H1, R0) + mul(H2, S4) + mul(H3, S3) + mul(H4, S2)
		D2 := mul(H0, R2) + mul(H1, R1) + mul(H2, R0) + mul(H3, S4) + mul(H4, S3)
		D3 := mul(H0, R3) + mul(H1, R2) + mul(H2, R1) + mul(H3, R0) + mul(H4, S4)
		D4 := mul(H0, R4) + mul(H1, R3) + mul(H2, R2) + mul(H3, R1) + mul(H4, R0)
		C: U64x4
		C = simd.shr(D0, U64x4(26)); H0 = D0 & mask26; D1 += C
		C = simd.shr(D1, U64x4(26)); H1 = D1 & mask26; D2 += C
		C = simd.shr(D2, U64x4(26)); H2 = D2 & mask26; D3 += C
		C = simd.shr(D3, U64x4(26)); H3 = D3 & mask26; D4 += C
		C = simd.shr(D4, U64x4(26)); H4 = D4 & mask26; H0 += C * 5
		C = simd.shr(H0, U64x4(26)); H0 &= mask26; H1 += C
		M0, M1, M2, M3, M4 := load(m[at:])
		H0 += M0
		H1 += M1
		H2 += M2
		H3 += M3
		H4 += M4
	}
	// Lane j by r^(4-j): r⁴, r³, r², r.
	r3, r2, r1 := p.r_pow[1], p.r_pow[0], p.r
	P0 := U64x4{r4[0], r3[0], r2[0], r1[0]}
	P1 := U64x4{r4[1], r3[1], r2[1], r1[1]}
	P2 := U64x4{r4[2], r3[2], r2[2], r1[2]}
	P3 := U64x4{r4[3], r3[3], r2[3], r1[3]}
	P4 := U64x4{r4[4], r3[4], r2[4], r1[4]}
	Q1, Q2, Q3, Q4 := P1 * 5, P2 * 5, P3 * 5, P4 * 5
	D0 := mul(H0, P0) + mul(H1, Q4) + mul(H2, Q3) + mul(H3, Q2) + mul(H4, Q1)
	D1 := mul(H0, P1) + mul(H1, P0) + mul(H2, Q4) + mul(H3, Q3) + mul(H4, Q2)
	D2 := mul(H0, P2) + mul(H1, P1) + mul(H2, P0) + mul(H3, Q4) + mul(H4, Q3)
	D3 := mul(H0, P3) + mul(H1, P2) + mul(H2, P1) + mul(H3, P0) + mul(H4, Q4)
	D4 := mul(H0, P4) + mul(H1, P3) + mul(H2, P2) + mul(H3, P1) + mul(H4, P0)
	// Added across the lanes, each sum under 2⁶⁴, then carried.
	d0, d1, d2, d3, d4 := simd.reduce_add_ordered(D0), simd.reduce_add_ordered(D1), simd.reduce_add_ordered(D2), simd.reduce_add_ordered(D3), simd.reduce_add_ordered(D4)
	c: u64
	c = d0 >> 26; d0 &= MASK26; d1 += c
	c = d1 >> 26; d1 &= MASK26; d2 += c
	c = d2 >> 26; d2 &= MASK26; d3 += c
	c = d3 >> 26; d3 &= MASK26; d4 += c
	c = d4 >> 26; d4 &= MASK26; d0 += c * 5
	c = d0 >> 26; d0 &= MASK26; d1 += c
	p.h = {d0, d1, d2, d3, d4}
}
