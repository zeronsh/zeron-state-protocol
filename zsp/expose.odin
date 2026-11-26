package zsp

import "core:crypto/sha2"
import "core:strings"

// What a device exposes to the public is reached through a relay at a name the relay works out, and the device too:
//
//   label = [prefix "-"] base32(SHA-256("zsp-expose" ‖ space ‖ device ‖ prefix bytes ‖ nonce)[0..10])
//
// in lower case, without padding. Nobody can be given another device's label, for it would take a second preimage of
// 80 bits to have one; a device draws a new nonce, and so a new name, each time it exposes a port again, so that a name
// once let go is nobody's for ever. The prefix is the device's to choose, for people to read.

EXPOSE_PREFIX_MAX :: 20
EXPOSE_NONCE :: 16

@(require_results)
exposure_prefix_valid :: proc(prefix: string) -> bool {
	return prefix == "" || len(prefix) <= EXPOSE_PREFIX_MAX && name_valid(prefix)
}

@(require_results)
exposure_label :: proc(space, device: Key32, prefix: string, nonce: [EXPOSE_NONCE]byte, allocator := context.temp_allocator) -> string {
	space, device, nonce := space, device, nonce
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	sha2.update(&ctx, transmute([]byte)string("zsp-expose"))
	sha2.update(&ctx, space[:])
	sha2.update(&ctx, device[:])
	n := [1]byte{byte(len(prefix))}
	sha2.update(&ctx, n[:]) // as bytes are written: a length first
	sha2.update(&ctx, transmute([]byte)prefix)
	sha2.update(&ctx, nonce[:])
	sum: [32]byte
	sha2.final(&ctx, sum[:])
	id := base32_80(sum[:10])
	if prefix == "" {
		return strings.clone(string(id[:]), allocator)
	}
	return strings.concatenate({prefix, "-", string(id[:])}, allocator)
}

// The name of a device that nobody chose (§17): the first ten bytes of its key in base32.
@(require_results)
name_id :: proc(device: Key32) -> [16]byte {
	device := device
	return base32_80(device[:10])
}

// Ten bytes as sixteen letters of RFC 4648 base32, in lower case: 80 bits, and no padding.
@(private, require_results)
base32_80 :: proc(ten: []byte) -> (out: [16]byte) {
	alphabet := "abcdefghijklmnopqrstuvwxyz234567"
	bits, have, at := u32(0), 0, 0
	for b in ten[:10] {
		bits = bits << 8 | u32(b)
		have += 8
		for have >= 5 {
			have -= 5
			out[at] = alphabet[(bits >> uint(have)) & 31]
			at += 1
		}
	}
	return
}

// Whether a 40 Expose is sound throughout: at most `most` exposures, each a valid prefix and a nonce, and nothing after.
// A relay takes all of one or none of it.
@(require_results)
expose_frame_sound :: proc(payload: []byte, most: int) -> bool {
	r := Reader{buf = payload}
	n := read_varint(&r)
	if r.bad || n > u64(most) {
		return false
	}
	for _ in 0 ..< n {
		prefix := string(read_bytes(&r))
		_ = read_take(&r, EXPOSE_NONCE)
		if r.bad || !exposure_prefix_valid(prefix) {
			return false
		}
	}
	return read_done(&r)
}
