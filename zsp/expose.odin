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
	alphabet := "abcdefghijklmnopqrstuvwxyz234567"
	id: [16]byte
	bits, have, at := u32(0), 0, 0
	for b in sum[:10] {
		bits = bits << 8 | u32(b)
		have += 8
		for have >= 5 {
			have -= 5
			id[at] = alphabet[(bits >> uint(have)) & 31]
			at += 1
		}
	}
	if prefix == "" {
		return strings.clone(string(id[:]), allocator)
	}
	return strings.concatenate({prefix, "-", string(id[:])}, allocator)
}
