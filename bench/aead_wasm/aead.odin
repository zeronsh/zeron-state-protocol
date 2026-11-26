// ChaCha20-Poly1305 in WebAssembly, as the relay runs it: zsp's held to core's on random keys, ivs and messages, and
// each timed. Built and run by run.mjs: node bench/aead_wasm/run.mjs [simd]
package aead_wasm

import "base:runtime"
import "core:crypto/chacha20poly1305"
import "core:math/rand"
import "../../zsp"

buf: [1 << 17]byte
other: [1 << 17]byte
key: [32]byte
iv: [12]byte

// Whether zsp's seal and open agree with core's on `rounds` random cases.
@(export)
check :: proc "c" (seed: u64, rounds: int) -> bool {
	context = runtime.default_context()
	state := rand.create(seed)
	r := rand.default_random_generator(&state)
	ad: [64]byte
	for round in 0 ..< rounds {
		n := round < 1100 ? round : rand.int_max(len(buf) - 16, r)
		a := rand.int_max(len(ad), r)
		x := rand.int_max(2, r) == 0
		ivb: [24]byte
		for &b in key {b = byte(rand.uint32(r))}
		for &b in ivb {b = byte(rand.uint32(r))}
		for &b in ad[:a] {b = byte(rand.uint32(r))}
		for &b in buf[:n] {b = byte(rand.uint32(r))}
		ivn := 24 if x else 12
		ctx: chacha20poly1305.Context
		if x {
			chacha20poly1305.init_xchacha(&ctx, key[:])
		} else {
			chacha20poly1305.init(&ctx, key[:])
		}
		want, got: [16]byte
		chacha20poly1305.seal(&ctx, other[:n], want[:], ivb[:ivn], ad[:a], buf[:n])
		zsp.chacha_seal(key[:], ivb[:ivn], buf[:n], got[:], ad[:a], buf[:n])
		if want != got || string(other[:n]) != string(buf[:n]) {
			return false
		}
		if !zsp.chacha_open(key[:], ivb[:ivn], buf[:n], ad[:a], buf[:n], got[:]) {
			return false
		}
	}
	return true
}

@(export)
seal_zsp :: proc "c" (n, times: int) {
	context = runtime.default_context()
	for _ in 0 ..< times {
		zsp.chacha_seal(key[:], iv[:], buf[:n], buf[n:][:16], nil, buf[:n])
	}
}

@(export)
seal_core :: proc "c" (n, times: int) {
	context = runtime.default_context()
	for _ in 0 ..< times {
		ctx: chacha20poly1305.Context = ---
		chacha20poly1305.init(&ctx, key[:])
		chacha20poly1305.seal(&ctx, buf[:n], buf[n:][:16], iv[:], nil, buf[:n])
	}
}
