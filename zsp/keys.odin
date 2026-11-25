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

// Appends which key, ciphertext and tag.
@(private)
seal_append :: proc(w: ^[dynamic]byte, k: ^Scope_Keys, iv: ^[24]byte, bind, plain: []byte, epoch := 0) {
	epoch := epoch if epoch != 0 else len(k.epochs)
	write_u32(w, k.ids[epoch - 1])
	aead_append(w, k.epochs[epoch - 1], iv, bind, plain)
}

@(private)
open_append :: proc(w: ^[dynamic]byte, k: ^Scope_Keys, iv: ^[24]byte, bind, sealed: []byte) -> bool {
	r := Reader{buf = sealed}
	id := read_u32(&r)
	if r.bad {
		return false
	}
	#reverse for other, i in k.ids {
		if other == id && k.epochs[i] != {} {
			return aead_open(w, k.epochs[i], iv, bind, sealed[r.pos:])
		}
	}
	return false
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
// index in the roster precedes the seal and a signature follows it. The epoch is the latest unless given.
@(require_results)
cell_seal :: proc(k: ^Keyring, r: ^Roster, c: ^Cell, epoch := 0) -> bool {
	scope := row_scope(c.row)
	keys, info := keyring_scope(k, scope), roster_scope(r, scope)
	if keys == nil || info == nil || keys.epochs[(epoch if epoch != 0 else len(keys.epochs)) - 1] == {} {
		return false
	}
	n := clear_size(c.kind, c.body)
	iv := aead_nonce(c.stamp, c.slot, u8(c.kind))
	w := make([dynamic]byte, 0, len(c.body) + TAG + SIGNATURE + 10, context.temp_allocator)
	append(&w, ..c.body[:n])
	if .Signed in info.flags {
		write_varint(&w, author_index(k, r) or_return)
	}
	seal_append(&w, keys, &iv, cell_bind(c), c.body[n:], epoch)
	if .Signed in info.flags {
		sign_append(&w, k, cell_signed(c, w[:])) or_return
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

// Whether a sealed cell may exist. In a signed scope authority travels with the cell, and anyone, keys or
// no keys, can check it. In an unsigned one the key is the authority, and ends when its epoch did.
@(require_results)
cell_authentic :: proc(r: ^Roster, c: ^Cell) -> bool {
	cell_lawful(r, c) or_return
	if .Signed not_in roster_scope(r, row_scope(c.row)).flags {
		return true
	}
	rd := Reader{buf = c.body, pos = clear_size(c.kind, c.body)}
	author := read_varint(&rd)
	body := c.body[:len(c.body) - SIGNATURE]
	return ed25519_verify(r.members[author].signer, cell_signed(c, body), c.body[len(body):])
}

// As much of that as can change once a cell has been found authentic.
@(private)
cell_lawful :: proc(r: ^Roster, c: ^Cell) -> bool {
	scope := row_scope(c.row)
	info := roster_scope(r, scope)
	if info == nil {
		return false
	}
	rd := Reader{buf = c.body, pos = clear_size(c.kind, c.body)}
	if .Signed in info.flags {
		author := read_varint(&rd)
		if rd.bad || len(c.body) - rd.pos < SIGNATURE || !author_allowed(r, author, scope, c.stamp) {
			return false
		}
	}
	epoch := key_epoch(info, read_u32(&rd))
	if rd.bad || epoch == 0 || epoch_void(info, epoch) {
		return false
	}
	return .Signed in info.flags || epoch == int(info.epoch) || c.stamp.time <= info.closed[epoch - 1]
}

// The epoch, counted from one, whose key this names; or zero.
@(private)
key_epoch :: proc(info: ^Scope_Info, id: u32) -> int {
	#reverse for c, i in info.commits {
		if key_id(c) == id {
			return i + 1
		}
	}
	return 0
}

// What a cell calls its key by: rosters drawn up at once may number theirs alike.
@(private)
key_id :: proc(commit: Key32) -> u32 {
	commit := commit
	return get_u32(commit[:])
}

@(private)
author_allowed :: proc(r: ^Roster, author: u64, scope: Scope, stamp: Stamp) -> bool {
	if author >= u64(len(r.members)) {
		return false
	}
	for g in r.members[author].grants {
		if g.scope == scope && .Write in g.rights && (g.until == 0 || stamp.time <= g.until) {
			return true
		}
	}
	return false
}

// A signature by this device, with the index others will know it by.
@(private)
author_index :: proc(k: ^Keyring, r: ^Roster) -> (index: u64, ok: bool) {
	for m, i in r.members {
		if m.device == k.device {
			return u64(i), true
		}
	}
	return
}

@(private)
sign_append :: proc(w: ^[dynamic]byte, k: ^Keyring, message: []byte) -> bool {
	sk: ed25519.Private_Key
	ed25519.private_key_set_bytes(&sk, k.seed[:]) or_return
	defer ed25519.private_key_clear(&sk)
	sig: [SIGNATURE]byte
	ed25519.sign(&sk, message, sig[:])
	append(w, ..sig[:])
	return true
}
