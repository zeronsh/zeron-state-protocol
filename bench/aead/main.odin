// What sealing and opening cost, by message size: ChaCha20-Poly1305 as core:crypto does it and as zsp does it, the
// latter also as a channel seals and opens, with Poly1305 and ChaCha20 alone beside them: ./x bench aead. With a row's
// name, a size and a count it runs only that, so many times, for perf stat to count what it takes:
// ./x bench aead "core seal" 1452 100000
package main

import "core:crypto/chacha20"
import "core:crypto/chacha20poly1305"
import "core:crypto/poly1305"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import "../../zsp"

SIZES :: [?]int{64, 1200, 1452, 8192, 65536}

key := [32]byte{0 ..< 32 = 7}
channel := zsp.Channel {
	send = {0 ..< 32 = 7},
	recv = {0 ..< 32 = 7},
}

ad: [13]byte

Row :: struct {
	name: string,
	f:    proc(buf: []byte),
}

// Each is given a message and room for its tag after it.
ROWS := [?]Row {
	{"core seal", proc(buf: []byte) {
		body := buf[:len(buf) - zsp.TAG]
		iv: [12]byte
		ctx: chacha20poly1305.Context = ---
		chacha20poly1305.init(&ctx, key[:])
		chacha20poly1305.seal(&ctx, body, buf[len(body):], iv[:], nil, body)
	}},
	{"zsp seal", proc(buf: []byte) {
		body := buf[:len(buf) - zsp.TAG]
		iv: [12]byte
		zsp.chacha_seal(key[:], iv[:], body, buf[len(body):], nil, body)
	}},
	{"core seal + open", proc(buf: []byte) {
		body := buf[:len(buf) - zsp.TAG]
		iv: [12]byte
		ctx: chacha20poly1305.Context = ---
		chacha20poly1305.init(&ctx, key[:])
		chacha20poly1305.seal(&ctx, body, buf[len(body):], iv[:], ad[:], body)
		ok := chacha20poly1305.open(&ctx, body, iv[:], ad[:], body, buf[len(body):])
		assert(ok)
	}},
	{"zsp seal + open", proc(buf: []byte) {
		body := buf[:len(buf) - zsp.TAG]
		iv: [12]byte
		zsp.chacha_seal(key[:], iv[:], body, buf[len(body):], ad[:], body)
		ok := zsp.chacha_open(key[:], iv[:], body, ad[:], body, buf[len(body):])
		assert(ok)
	}},
	{"channel seal + open", proc(buf: []byte) {
		zsp.channel_seal_in_place(&channel, 1, buf, ad[:])
		_, ok := zsp.channel_open_at(&channel, 1, buf, ad[:])
		assert(ok)
	}},
	{"core poly1305", proc(buf: []byte) {
		tag: [16]byte
		poly1305.sum(tag[:], buf[:len(buf) - zsp.TAG], key[:])
	}},
	{"zsp poly1305", proc(buf: []byte) {
		tag: [16]byte
		p: zsp.Poly1305 = ---
		zsp.poly_init(&p, key[:])
		zsp.poly_update(&p, buf[:len(buf) - zsp.TAG])
		zsp.poly_final(&p, tag[:])
	}},
	{"chacha20", proc(buf: []byte) {
		iv: [12]byte
		ctx: chacha20.Context = ---
		chacha20.init(&ctx, key[:], iv[:])
		body := buf[:len(buf) - zsp.TAG]
		chacha20.xor_bytes(&ctx, body, body)
	}},
}

// Runs `f` over `size` bytes for about `budget`, the best of so many rounds: in ns per byte.
measure :: proc(size: int, f: proc(buf: []byte), budget := 400 * time.Millisecond, rounds := 10) -> f64 {
	buf := make([]byte, size + zsp.TAG)
	defer delete(buf)
	for &b, i in buf {
		b = byte(i * 7)
	}
	best := max(f64)
	for _ in 0 ..< rounds {
		// The clock read only every so often, as reading it may cost as much as sealing a small message.
		n := 0
		start := time.tick_now()
		for time.tick_since(start) < budget / time.Duration(rounds) {
			for _ in 0 ..< 64 {
				f(buf)
			}
			n += 64
		}
		best = min(best, f64(time.tick_since(start)) / f64(n * size))
	}
	return best
}

main :: proc() {
	if len(os.args) == 4 {
		size, _ := strconv.parse_int(os.args[2])
		count, _ := strconv.parse_int(os.args[3])
		buf := make([]byte, size + zsp.TAG)
		for r in ROWS {
			if r.name == os.args[1] {
				for _ in 0 ..< count {
					r.f(buf)
				}
				return
			}
		}
		fmt.eprintln("no such row:", os.args[1])
		os.exit(2)
	}
	fmt.println("  size      what                     ns/byte    GB/s")
	for size in SIZES {
		for r in ROWS {
			ns := measure(size, r.f)
			fmt.printfln("  %-8d  %-22s  %7.3f  %6.2f", size, r.name, ns, 1 / ns)
		}
	}
}
