package zsp

import "core:crypto/sha2"

// HMAC and HKDF over SHA-256 alone; core:crypto/hkdf would compile every hash there is.

sha256 :: proc(parts: ..[]byte) -> (out: Key32) {
	ctx: sha2.Context_256 = ---
	sha2.init_256(&ctx)
	for p in parts {
		sha2.update(&ctx, p)
	}
	sha2.final(&ctx, out[:])
	return
}

hmac256 :: proc(key: []byte, parts: ..[]byte) -> (out: Key32) {
	assert(len(key) <= 64)
	ipad, opad: [64]byte
	copy(ipad[:], key)
	copy(opad[:], key)
	for i in 0 ..< 64 {
		ipad[i] ~= 0x36
		opad[i] ~= 0x5c
	}
	ctx: sha2.Context_256 = ---
	sha2.init_256(&ctx)
	sha2.update(&ctx, ipad[:])
	for p in parts {
		sha2.update(&ctx, p)
	}
	inner: Key32
	sha2.final(&ctx, inner[:])
	return sha256(opad[:], inner[:])
}

// One block of HKDF output.
hkdf256 :: proc(salt, secret, info: []byte) -> Key32 {
	zero: Key32
	prk := hmac256(salt if salt != nil else zero[:], secret)
	return hmac256(prk[:], info, {1})
}
