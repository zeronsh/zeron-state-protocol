package zsp

import "core:crypto/chacha20poly1305"
import "core:crypto/ed25519"

// Key derivation, and the sealing of cells and frames.

Key32 :: [32]byte

TAG :: 16
SIGNATURE :: 64

@(require_results)
derive :: proc(key: Key32, info: string) -> Key32 {
	key := key
	return hkdf256(nil, key[:], transmute([]byte)info)
}

@(private)
history_key :: proc(key: Key32) -> Key32 {
	return derive(key, "zsp-history")
}

@(private)
wrap_key :: proc(secret, public, eph, device: Key32) -> (out: Key32, ok: bool) {
	eph, device := eph, device
	shared := x25519_shared(secret, public) or_return
	salt: [64]byte
	copy(salt[:], eph[:])
	copy(salt[32:], device[:])
	salt_hash := sha256(salt[:])
	return hkdf256(salt_hash[:], shared[:], transmute([]byte)string("zsp-wrap")), true
}

// Each wrapping key seals a handful of messages under distinct counters.
@(private)
append_sealed :: proc(w: ^[dynamic]byte, key: Key32, n: u64, secret: Key32) {
	key, secret := key, secret
	iv: [12]byte
	put_u64(iv[4:], n)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key[:])
	out: [48]byte
	chacha20poly1305.seal(&ctx, out[:32], out[32:], iv[:], nil, secret[:])
	append(w, ..out[:])
}

@(private)
open_key :: proc(key: Key32, n: u64, sealed: []byte) -> (out: Key32, ok: bool) {
	key := key
	iv: [12]byte
	put_u64(iv[4:], n)
	ctx: chacha20poly1305.Context
	chacha20poly1305.init(&ctx, key[:])
	ok = chacha20poly1305.open(&ctx, out[:], iv[:], nil, sealed[:32], sealed[32:])
	return
}

// The opaque tag of a named list.
@(require_results)
list_tag :: proc(keys: ^Scope_Keys, name: string) -> List {
	h := sha256(keys.list_key[:], transmute([]byte)name)
	return {u64(keys.scope) << 32 | u64(get_u32(h[:])), get_u64(h[4:])}
}

// XChaCha20-Poly1305 under a stamp that is never reused. `bind` is authenticated, not hidden.
@(private)
aead_nonce :: proc(stamp: Stamp, slot: Slot, kind: u8) -> (iv: [24]byte) {
	put_u64(iv[0:], stamp.time)
	put_u64(iv[8:], stamp.salt)
	iv[16] = byte(slot)
	iv[17] = kind
	return
}

// Appends epoch, ciphertext and tag.
@(private)
seal_append :: proc(w: ^[dynamic]byte, k: ^Scope_Keys, iv: ^[24]byte, bind, plain: []byte) {
	epoch := len(k.epochs)
	write_varint(w, u64(epoch))
	aead_append(w, k.epochs[epoch - 1], iv, bind, plain)
}

@(private)
open_append :: proc(w: ^[dynamic]byte, k: ^Scope_Keys, iv: ^[24]byte, bind, sealed: []byte) -> bool {
	r := Reader{buf = sealed}
	epoch := read_varint(&r)
	if r.bad || epoch == 0 || epoch > u64(len(k.epochs)) {
		return false
	}
	return aead_open(w, k.epochs[epoch - 1], iv, bind, sealed[r.pos:])
}

@(private)
aead_append :: proc(w: ^[dynamic]byte, key: Key32, iv: ^[24]byte, bind, plain: []byte) {
	key := key
	at := len(w)
	resize(w, at + len(plain) + TAG)
	ctx: chacha20poly1305.Context = ---
	chacha20poly1305.init_xchacha(&ctx, key[:])
	chacha20poly1305.seal(&ctx, w[at:][:len(plain)], w[at + len(plain):], iv[:], bind, plain)
}

@(private)
aead_open :: proc(w: ^[dynamic]byte, key: Key32, iv: ^[24]byte, bind, sealed: []byte) -> bool {
	key := key
	n := len(sealed) - TAG
	if n < 0 {
		return false
	}
	at := len(w)
	resize(w, at + n)
	ctx: chacha20poly1305.Context = ---
	chacha20poly1305.init_xchacha(&ctx, key[:])
	if !chacha20poly1305.open(&ctx, w[at:], iv[:], bind, sealed[:n], sealed[n:]) {
		resize(w, at)
		return false
	}
	return true
}

@(private)
cell_bind :: proc(c: ^Cell) -> []byte {
	n := clear_size(c.kind, c.body)
	buf := make([]byte, 18 + n, context.temp_allocator)
	put_u64(buf[0:], c.row[0])
	put_u64(buf[8:], c.row[1])
	buf[16] = byte(c.slot)
	buf[17] = byte(c.kind)
	copy(buf[18:], c.body[:n])
	return buf
}

// What a signature covers: the cell's identity, then its whole body short of the signature.
@(private)
cell_signed :: proc(c: ^Cell, body: []byte) -> []byte {
	m := make([]byte, 34 + len(body), context.temp_allocator)
	put_u64(m[0:], c.row[0])
	put_u64(m[8:], c.row[1])
	m[16] = byte(c.slot)
	m[17] = byte(c.kind)
	put_u64(m[18:], c.stamp.time)
	put_u64(m[26:], c.stamp.salt)
	copy(m[34:], body)
	return m
}

// Replaces an open body with a sealed one, in temporary memory. In a signed scope the author's
// index in the roster precedes the seal and a signature follows it.
@(require_results)
cell_seal :: proc(k: ^Keyring, r: ^Roster, c: ^Cell) -> bool {
	scope := row_scope(c.row)
	keys, info := keyring_scope(k, scope), roster_scope(r, scope)
	if keys == nil || info == nil {
		return false
	}
	n := clear_size(c.kind, c.body)
	iv := aead_nonce(c.stamp, c.slot, u8(c.kind))
	w := make([dynamic]byte, 0, len(c.body) + TAG + SIGNATURE + 10, context.temp_allocator)
	append(&w, ..c.body[:n])
	if .Signed in info.flags {
		author := -1
		for m, i in r.members {
			if m.device == k.device {
				author = i
			}
		}
		write_varint(&w, u64(author))
	}
	seal_append(&w, keys, &iv, cell_bind(c), c.body[n:])
	if .Signed in info.flags {
		sk: ed25519.Private_Key
		ed25519.private_key_set_bytes(&sk, k.seed[:]) or_return
		sig: [SIGNATURE]byte
		ed25519.sign(&sk, cell_signed(c, w[:]), sig[:])
		ed25519.private_key_clear(&sk)
		append(&w, ..sig[:])
	}
	c.body = w[:]
	return true
}

// Replaces a sealed body with an open one, in temporary memory.
@(require_results)
cell_open :: proc(k: ^Keyring, r: ^Roster, c: ^Cell) -> bool {
	scope := row_scope(c.row)
	keys, info := keyring_scope(k, scope), roster_scope(r, scope)
	if keys == nil || info == nil {
		return false
	}
	n := clear_size(c.kind, c.body)
	sealed := c.body[n:]
	if .Signed in info.flags {
		rd := Reader{buf = sealed}
		_ = read_varint(&rd)
		if rd.bad || len(sealed) - rd.pos < SIGNATURE {
			return false
		}
		sealed = sealed[rd.pos:len(sealed) - SIGNATURE]
	}
	iv := aead_nonce(c.stamp, c.slot, u8(c.kind))
	w := make([dynamic]byte, 0, len(c.body), context.temp_allocator)
	append(&w, ..c.body[:n])
	open_append(&w, keys, &iv, cell_bind(c), sealed) or_return
	c.body = w[:]
	return true
}

// Whether a sealed cell may exist: in a signed scope, authority travels with the cell, and anyone,
// keys or no keys, can check it.
@(require_results)
cell_authentic :: proc(r: ^Roster, c: ^Cell) -> bool {
	scope := row_scope(c.row)
	info := roster_scope(r, scope)
	if info == nil {
		return false
	}
	if .Signed not_in info.flags {
		return true
	}
	rd := Reader{buf = c.body, pos = clear_size(c.kind, c.body)}
	author := read_varint(&rd)
	if rd.bad || author >= u64(len(r.members)) || len(c.body) - rd.pos < SIGNATURE {
		return false
	}
	m := &r.members[author]
	allowed := false
	for g in m.grants {
		if g.scope == scope && .Write in g.rights {
			allowed = g.until == 0 || c.stamp.time <= g.until
		}
	}
	body := c.body[:len(c.body) - SIGNATURE]
	return allowed && ed25519_verify(m.signer, cell_signed(c, body), c.body[len(body):])
}
