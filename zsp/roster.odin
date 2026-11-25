package zsp

import "core:crypto"
import "core:crypto/ed25519"
import "core:slice"

// Who may do what, as a document.
//
// A space is named by an Ed25519 public key. Its roster, signed by that key, lists scopes and the
// members granted rights in them, and carries each scope's sealing key wrapped for each reader.
// A relay can verify and enforce a roster while unwrapping nothing.
//
// The protocol proves that a peer holds a key and enforces what the roster grants that key. Deciding
// that a key belongs to some person, or that a person may use some relay, is authentication, and is
// the host's: see Host.authenticate.

Right :: enum u8 {
	Read,
	Write, // implies Read
	Call, // make and answer calls; needs neither, yet comes with Read, as every grant does
}
Rights :: distinct bit_set[Right;u8]

Grant :: struct {
	scope:  Scope,
	rights: Rights,
	until:  u64, // when revoked, the stamp time past which the member's cells are refused; else zero
}

Member :: struct {
	device:  Key32, // X25519: proves itself to peers, unwraps keys
	signer:  Key32, // Ed25519: signs cells in signed scopes
	admin:   bool, // holds the space's signing key
	subject: []byte, // whom the host says this is; opaque here
	grants:  []Grant,
}

Scope_Flag :: enum u8 {
	// Every cell is signed by its writer. Only such scopes may have members who read but do not
	// write: elsewhere, holding the sealing key is what it means to be a writer.
	Signed,
}
Scope_Flags :: distinct bit_set[Scope_Flag;u8]

Scope_Info :: struct {
	id:    Scope,
	flags: Scope_Flags,
	epoch: u32,
}

Relay :: struct {
	key: Key32,
	url: string,
}

Roster :: struct {
	bytes:   []byte, // owned; subjects and urls point into it
	space:   Key32,
	serial:  u64, // the higher wins
	scopes:  []Scope_Info, // owned, ascending
	// Never shrinks, so that a signed cell's author is an index that stays valid.
	members: []Member, // owned, as are their grants
	relays:  []Relay, // owned
	eph:     Key32,
	wraps:   []byte,
	history: []byte,
}

Keyring :: struct {
	secret: Key32, // this device's X25519 private key
	device: Key32,
	seed:   Key32, // its Ed25519 seed, derived from the secret
	signer: Key32,
	scopes: [dynamic]Scope_Keys,
	root:   Maybe(Key32), // the space's signing seed, on admin devices
}

Scope_Keys :: struct {
	scope:    Scope,
	list_key: Key32,
	epochs:   [dynamic]Key32, // sealing keys, by epoch - 1
}

keyring_init :: proc(k: ^Keyring, secret: Key32) {
	k.secret = secret
	k.device = x25519_public(secret)
	k.seed = derive(secret, "zsp-sign")
	k.signer = ed25519_public(k.seed)
}

keyring_destroy :: proc(k: ^Keyring) {
	keyring_clear(k)
	delete(k.scopes)
	crypto.zero_explicit(k, size_of(Keyring))
}

@(private)
keyring_clear :: proc(k: ^Keyring) {
	for &s in k.scopes {
		crypto.zero_explicit(raw_data(s.epochs), len(s.epochs) * size_of(Key32))
		delete(s.epochs)
	}
	clear(&k.scopes)
}

@(require_results)
keyring_scope :: proc(k: ^Keyring, scope: Scope) -> ^Scope_Keys {
	for &s in k.scopes {
		if s.scope == scope {
			return &s
		}
	}
	return nil
}

@(require_results)
ed25519_public :: proc(seed: Key32) -> (public: Key32) {
	seed := seed
	sk: ed25519.Private_Key
	if ed25519.private_key_set_bytes(&sk, seed[:]) {
		ed25519.private_key_public_bytes(&sk, public[:])
	}
	ed25519.private_key_clear(&sk)
	return
}

@(require_results)
ed25519_verify :: proc(public: Key32, msg, sig: []byte) -> bool {
	public := public
	pk: ed25519.Public_Key
	ed25519.public_key_set_bytes(&pk, public[:]) or_return
	return ed25519.verify(&pk, msg, sig)
}

@(require_results)
roster_parse :: proc(bytes: []byte, space: Key32) -> (r: Roster, ok: bool) {
	if len(bytes) < 64 {
		return
	}
	body, sig := bytes[:len(bytes) - 64], bytes[len(bytes) - 64:]
	ed25519_verify(space, body, sig) or_return

	defer if !ok {
		roster_destroy(&r)
	}
	r.bytes = slice.clone(bytes)
	rd := Reader{buf = r.bytes[:len(body)]}
	if string(read_take(&rd, 6)) != "zsp-r1" || read_key32(&rd) != space {
		return
	}
	r.space = space
	r.serial = read_varint(&rd)
	history, wraps := 0, 0

	r.scopes = make([]Scope_Info, read_count(&rd))
	last: Scope
	for &s in r.scopes {
		s.id = Scope(read_varint(&rd))
		s.flags = transmute(Scope_Flags)read_u8(&rd)
		s.epoch = u32(read_varint(&rd))
		if rd.bad || s.id <= last || s.id == max(Scope) || s.epoch == 0 {
			return
		}
		last = s.id
		history += int(s.epoch - 1)
	}
	r.members = make([]Member, read_count(&rd))
	for &m in r.members {
		m.device = read_key32(&rd)
		m.signer = read_key32(&rd)
		m.admin = read_u8(&rd) != 0
		m.subject = read_bytes(&rd)
		m.grants = make([]Grant, read_count(&rd))
		for &g in m.grants {
			g.scope = Scope(read_varint(&rd))
			g.rights = transmute(Rights)read_u8(&rd)
			g.until = read_varint(&rd)
			info := roster_scope(&r, g.scope)
			if rd.bad || info == nil || .Read not_in g.rights {
				return
			}
			if .Write not_in g.rights && .Signed not_in info.flags {
				return
			}
			if g.until == 0 {
				wraps += 1
			}
		}
		if m.admin {
			wraps += 1
		}
	}
	r.relays = make([]Relay, read_count(&rd))
	for &l in r.relays {
		l.key = read_key32(&rd)
		l.url = string(read_bytes(&rd))
	}
	r.eph = read_key32(&rd)
	r.wraps = read_take(&rd, 48 * wraps)
	r.history = read_take(&rd, 48 * history)
	ok = read_done(&rd) && r.serial > 0
	return
}

roster_destroy :: proc(r: ^Roster) {
	for m in r.members {
		delete(m.grants)
	}
	delete(r.bytes)
	delete(r.scopes)
	delete(r.members)
	delete(r.relays)
	r^ = {}
}

@(require_results)
roster_scope :: proc(r: ^Roster, scope: Scope) -> ^Scope_Info {
	for &s in r.scopes {
		if s.id == scope {
			return &s
		}
	}
	return nil
}

@(require_results)
roster_member :: proc(r: ^Roster, device: Key32) -> ^Member {
	for &m in r.members {
		if m.device == device {
			return &m
		}
	}
	return nil
}

@(require_results)
member_rights :: proc(m: ^Member, scope: Scope) -> Rights {
	for g in m.grants {
		if g.scope == scope && g.until == 0 {
			return g.rights
		}
	}
	return {}
}

@(require_results)
member_active :: proc(m: ^Member) -> bool {
	if m.admin {
		return true
	}
	for g in m.grants {
		if g.until == 0 {
			return true
		}
	}
	return false
}

// What an admin intends the next roster to say.
Draft :: struct {
	serial:  u64,
	scopes:  [dynamic]Draft_Scope,
	members: [dynamic]Member,
	relays:  [dynamic]Relay,
}

Draft_Scope :: struct {
	id:     Scope,
	flags:  Scope_Flags,
	rotate: bool, // draw a new sealing key
}

// The current roster as a draft, in temporary memory.
@(require_results)
draft_from :: proc(r: ^Roster, allocator := context.temp_allocator) -> (d: Draft) {
	d.serial = r.serial + 1
	d.scopes = make([dynamic]Draft_Scope, allocator)
	d.members = make([dynamic]Member, allocator)
	d.relays = make([dynamic]Relay, allocator)
	for s in r.scopes {
		append(&d.scopes, Draft_Scope{s.id, s.flags, false})
	}
	for m in r.members {
		m := m
		m.grants = slice.clone(m.grants, allocator)
		append(&d.members, m)
	}
	append(&d.relays, ..r.relays)
	return
}

draft_scope :: proc(d: ^Draft, flags: Scope_Flags = {}) -> (id: Scope) {
	for s in d.scopes {
		id = max(id, s.id)
	}
	id += 1
	append(&d.scopes, Draft_Scope{id, flags, false})
	return
}

// Gives a device rights in a scope, admitting it to the space if need be.
draft_grant :: proc(d: ^Draft, device, signer: Key32, scope: Scope, rights: Rights, allocator := context.temp_allocator) -> ^Member {
	m: ^Member
	for &x in d.members {
		if x.device == device {
			m = &x
		}
	}
	if m == nil {
		append(&d.members, Member{device = device, signer = signer})
		m = &d.members[len(d.members) - 1]
	}
	for &g in m.grants {
		if g.scope == scope {
			g.rights, g.until = rights + {.Read}, 0
			return m
		}
	}
	grants := make([dynamic]Grant, 0, len(m.grants) + 1, allocator)
	append(&grants, ..m.grants)
	append(&grants, Grant{scope, rights + {.Read}, 0})
	m.grants = grants[:]
	return m
}

// Ends a device's rights in a scope, or everywhere, as of a stamp time, and rotates what it could read.
draft_revoke :: proc(d: ^Draft, device: Key32, now: u64, scope: Scope = 0) {
	for &m in d.members {
		if m.device != device {
			continue
		}
		if scope == 0 {
			m.admin = false
		}
		for &g in m.grants {
			if g.until != 0 || (scope != 0 && g.scope != scope) {
				continue
			}
			g.until = max(now, 1)
			for &s in d.scopes {
				if s.id == g.scope {
					s.rotate = true
				}
			}
		}
	}
}

// Signs a draft. The keyring must hold every existing scope's keys.
@(require_results)
roster_sign :: proc(k: ^Keyring, root: Key32, d: ^Draft, allocator := context.allocator) -> (bytes: []byte, ok: bool) {
	root := root
	sk: ed25519.Private_Key
	ed25519.private_key_set_bytes(&sk, root[:]) or_return
	defer ed25519.private_key_clear(&sk)
	space, eph_secret: Key32
	ed25519.private_key_public_bytes(&sk, space[:])
	crypto.rand_bytes(eph_secret[:])
	defer crypto.zero_explicit(&eph_secret, 32)
	eph := x25519_public(eph_secret)

	current := make(map[Scope]Key32, context.temp_allocator)
	w := make([dynamic]byte, allocator)
	defer if !ok {
		delete(w)
	}
	append(&w, "zsp-r1")
	append(&w, ..space[:])
	write_varint(&w, d.serial)
	write_varint(&w, u64(len(d.scopes)))
	for s in d.scopes {
		held := keyring_scope(k, s.id)
		epochs := len(held.epochs) if held != nil else 0
		if epochs == 0 || s.rotate {
			fresh: Key32
			crypto.rand_bytes(fresh[:])
			current[s.id] = fresh
			epochs += 1
		} else {
			current[s.id] = held.epochs[epochs - 1]
		}
		write_varint(&w, u64(s.id))
		write_u8(&w, transmute(u8)s.flags)
		write_varint(&w, u64(epochs))
	}
	write_varint(&w, u64(len(d.members)))
	for m in d.members {
		device, signer := m.device, m.signer
		append(&w, ..device[:])
		append(&w, ..signer[:])
		write_u8(&w, 1 if m.admin else 0)
		write_bytes(&w, m.subject)
		write_varint(&w, u64(len(m.grants)))
		for g in m.grants {
			write_varint(&w, u64(g.scope))
			write_u8(&w, transmute(u8)g.rights)
			write_varint(&w, g.until)
		}
	}
	write_varint(&w, u64(len(d.relays)))
	for l in d.relays {
		key := l.key
		append(&w, ..key[:])
		write_bytes(&w, transmute([]byte)l.url)
	}
	append(&w, ..eph[:])
	for m in d.members {
		if !m.admin && len(m.grants) == 0 {
			continue
		}
		wrap := wrap_key(eph_secret, m.device, eph, m.device) or_return
		for g in m.grants {
			if g.until == 0 {
				append_sealed(&w, wrap, u64(g.scope), current[g.scope])
			}
		}
		if m.admin {
			append_sealed(&w, wrap, 0, root)
		}
	}
	for s in d.scopes {
		held := keyring_scope(k, s.id)
		if held == nil {
			continue
		}
		key := history_key(current[s.id])
		n := len(held.epochs) if s.rotate else len(held.epochs) - 1
		for old, i in held.epochs[:n] {
			append_sealed(&w, key, u64(i), old)
		}
	}
	sig: [64]byte
	ed25519.sign(&sk, w[:], sig[:])
	append(&w, ..sig[:])
	return w[:], true
}

// Recovers this device's keys from a verified roster. False if it is no longer a member.
@(require_results)
roster_unwrap :: proc(k: ^Keyring, r: ^Roster) -> bool {
	me := roster_member(r, k.device)
	if me == nil || !member_active(me) {
		return false
	}
	wrap := wrap_key(k.secret, r.eph, r.eph, k.device) or_return
	at := 0
	for &m in r.members {
		if &m == me {
			break
		}
		for g in m.grants {
			at += 48 if g.until == 0 else 0
		}
		at += 48 if m.admin else 0
	}
	keyring_clear(k)
	k.root = nil
	for g in me.grants {
		if g.until != 0 {
			continue
		}
		current := open_key(wrap, u64(g.scope), r.wraps[at:][:48]) or_return
		at += 48
		sealed := 0
		for s in r.scopes {
			if s.id != g.scope {
				sealed += 48 * int(s.epoch - 1)
				continue
			}
			keys := Scope_Keys{scope = s.id}
			key := history_key(current)
			for i in 0 ..< int(s.epoch - 1) {
				append(&keys.epochs, open_key(key, u64(i), r.history[sealed + i * 48:][:48]) or_return)
			}
			append(&keys.epochs, current)
			// List tags outlive rotation: they hang off the first epoch.
			keys.list_key = derive(keys.epochs[0], "zsp-list")
			append(&k.scopes, keys)
			break
		}
	}
	if me.admin {
		k.root = open_key(wrap, 0, r.wraps[at:][:48]) or_return
	}
	return true
}

@(private)
read_key32 :: proc(r: ^Reader) -> (k: Key32) {
	copy(k[:], read_take(r, 32))
	return
}
