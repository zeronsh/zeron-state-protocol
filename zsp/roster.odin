package zsp

import "core:crypto"
import "core:crypto/ed25519"
import "core:slice"

// Who may do what, as a document.
//
// A space is named by an Ed25519 public key. Whoever holds the private one owns it, for good: nothing can
// take back a name. Owners sign a charter, which says who are its admins; and any admin may sign the roster,
// which lists scopes and the members granted rights in them, and carries each scope's sealing key wrapped
// for each reader. An admin can be unmade like any other member, by a new charter. A relay can verify and
// enforce it all while unwrapping nothing.
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
	owner:   bool, // holds the space's signing key, and keeps it
	admin:   bool, // may sign rosters
	subject: []byte, // whom the host says this is; opaque here
	// In the order given. At most one per scope is in force; the rest say what was once allowed, and so
	// what was rightly written.
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
	// When each earlier epoch ended, as stamp times. A key that was given up cannot seal what is later.
	closed: []u64, // owned
}

Relay :: struct {
	key: Key32,
	url: string,
}

// In the charter, so that no admin can leave one out.
Owner :: struct {
	device: Key32,
	signer: Key32,
	wrap:   []byte,
}

Roster :: struct {
	bytes:   []byte, // owned; subjects and urls point into it
	space:   Key32,
	serial:  u64, // the higher wins: see serial_next
	charter: []byte,
	term:    u64, // the charter's
	owners:  []Owner, // owned
	admins:  []Key32, // owned; signers
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
	root:   Maybe(Key32), // the space's signing seed, on owners' devices
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

// The serial a roster claims, unverified: enough to know that it is not news.
@(require_results)
roster_claims :: proc(bytes: []byte, space: Key32) -> (serial: u64, ok: bool) {
	rd := Reader{buf = bytes}
	if string(read_take(&rd, 6)) != "zsp-r1" || read_key32(&rd) != space {
		return
	}
	_ = read_bytes(&rd)
	serial = read_varint(&rd)
	return serial, !rd.bad
}

// What is already known to be genuine in a roster held need not be proven again.
@(require_results)
roster_parse :: proc(bytes: []byte, space: Key32, held: ^Roster = nil) -> (r: Roster, ok: bool) {
	if len(bytes) < 64 {
		return
	}
	defer if !ok {
		roster_destroy(&r)
	}
	r.bytes = slice.clone(bytes)
	body, sig := r.bytes[:len(bytes) - 64], r.bytes[len(bytes) - 64:]
	rd := Reader{buf = r.bytes[:len(body)]}
	if string(read_take(&rd, 6)) != "zsp-r1" || read_key32(&rd) != space {
		return
	}
	r.space = space
	charter := read_bytes(&rd)
	charter_parse(&r, charter, held != nil && held.charter != nil && string(held.charter) == string(charter)) or_return
	r.serial = read_varint(&rd)
	if rd.bad || r.serial >> TERM_SHIFT != r.term {
		return
	}
	history, wraps := 0, 0

	r.scopes = make([]Scope_Info, read_count(&rd))
	last: Scope
	for &s in r.scopes {
		s.id = Scope(read_varint(&rd))
		s.flags = transmute(Scope_Flags)read_u8(&rd)
		s.epoch = u32(read_varint(&rd))
		if rd.bad || s.id <= last || s.id == max(Scope) || s.epoch == 0 || int(s.epoch) > len(rd.buf) - rd.pos {
			return
		}
		s.closed = make([]u64, s.epoch - 1)
		for &c, i in s.closed {
			c = read_varint(&rd)
			if i > 0 && c < s.closed[i - 1] {
				return
			}
		}
		last = s.id
		history += int(s.epoch - 1)
	}
	r.members = make([]Member, read_count(&rd))
	for &m, i in r.members {
		m.device = read_key32(&rd)
		m.signer = read_key32(&rd)
		for other in r.members[:i] {
			if other.device == m.device {
				return
			}
		}
		m.admin = slice.contains(r.admins, m.signer)
		for &o in r.owners {
			m.owner ||= o.device == m.device
		}
		m.subject = read_bytes(&rd)
		m.grants = make([]Grant, read_count(&rd))
		for &g, j in m.grants {
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
				for other in m.grants[:j] {
					if other.scope == g.scope && other.until == 0 {
						return
					}
				}
			}
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
	by := read_varint(&rd)
	if !read_done(&rd) || by > u64(len(r.admins)) {
		return
	}
	ok = ed25519_verify(space if by == 0 else r.admins[by - 1], body, sig)
	return
}

@(private)
charter_parse :: proc(r: ^Roster, bytes: []byte, proven: bool) -> bool {
	if len(bytes) < 64 {
		return false
	}
	body, sig := bytes[:len(bytes) - 64], bytes[len(bytes) - 64:]
	if !proven && !ed25519_verify(r.space, charter_signed(r.space, body), sig) {
		return false
	}
	rd := Reader{buf = body}
	r.charter = bytes
	r.term = read_varint(&rd)
	_ = read_take(&rd, 32)
	r.owners = make([]Owner, read_count(&rd))
	for &o in r.owners {
		o.device = read_key32(&rd)
		o.signer = read_key32(&rd)
		o.wrap = read_take(&rd, 48)
	}
	r.admins = make([]Key32, read_count(&rd))
	for &a in r.admins {
		a = read_key32(&rd)
	}
	return read_done(&rd) && r.term > 0
}

@(private)
charter_signed :: proc(space: Key32, body: []byte) -> []byte {
	space := space
	m := make([dynamic]byte, context.temp_allocator)
	append(&m, "zsp-charter")
	append(&m, ..space[:])
	append(&m, ..body)
	return m[:]
}

TERM_SHIFT :: 44
COUNT_SHIFT :: 20

// The charter's term, then a count, then chance: of two rosters drawn up at once, all agree which it is.
@(private)
serial_next :: proc(term, last: u64) -> (serial: u64, ok: bool) {
	salt: [4]byte
	crypto.rand_bytes(salt[:])
	count := (last >> COUNT_SHIFT) & (1 << (TERM_SHIFT - COUNT_SHIFT) - 1) if last >> TERM_SHIFT == term else 0
	count += 1
	serial = term << TERM_SHIFT | count << COUNT_SHIFT | u64(get_u32(salt[:])) >> (32 - COUNT_SHIFT)
	return serial, term > 0 && term < 1 << (64 - TERM_SHIFT) && count < 1 << (TERM_SHIFT - COUNT_SHIFT)
}

roster_destroy :: proc(r: ^Roster) {
	for m in r.members {
		delete(m.grants)
	}
	for s in r.scopes {
		delete(s.closed)
	}
	delete(r.bytes)
	delete(r.scopes)
	delete(r.members)
	delete(r.relays)
	delete(r.owners)
	delete(r.admins)
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
	if m.owner || m.admin {
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
	last:    u64, // the serial it follows
	space:   Key32,
	charter: []byte, // the one in force, while nothing about it changes
	term:    u64,
	owners:  []Owner,
	admins:  []Key32,
	now:     u64, // stamp time at which this takes effect
	scopes:  [dynamic]Draft_Scope,
	members: [dynamic]Member,
	relays:  [dynamic]Relay,
}

Draft_Scope :: struct {
	id:     Scope,
	flags:  Scope_Flags,
	rotate: bool, // draw a new sealing key
	closed: []u64,
	known:  bool, // there is one already
}

// The current roster as a draft, in temporary memory. `now` should be no less than any stamp the admin
// has seen: what others wrote before then stands.
@(require_results)
draft_from :: proc(r: ^Roster, now: u64, allocator := context.temp_allocator) -> (d: Draft) {
	d.space, d.last, d.charter, d.term, d.owners, d.admins = r.space, r.serial, r.charter, r.term, r.owners, r.admins
	d.now = max(now, 1)
	d.scopes = make([dynamic]Draft_Scope, allocator)
	d.members = make([dynamic]Member, allocator)
	d.relays = make([dynamic]Relay, allocator)
	for s in r.scopes {
		append(&d.scopes, Draft_Scope{s.id, s.flags, false, s.closed, true})
	}
	for m in r.members {
		m := m
		m.grants = slice.clone(m.grants, allocator)
		append(&d.members, m)
	}
	for o in r.owners {
		if roster_member(r, o.device) == nil {
			append(&d.members, Member{device = o.device, signer = o.signer, owner = true})
		}
	}
	append(&d.relays, ..r.relays)
	return
}

draft_scope :: proc(d: ^Draft, flags: Scope_Flags = {}) -> (id: Scope) {
	for s in d.scopes {
		id = max(id, s.id)
	}
	id += 1
	append(&d.scopes, Draft_Scope{id = id, flags = flags})
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
		if g.scope != scope || g.until != 0 {
			continue
		}
		if .Write in g.rights && .Write not_in rights {
			g.until = d.now // ended, not unmade: what it allowed stays allowed
			break
		}
		g.rights = rights + {.Read}
		return m
	}
	grants := make([dynamic]Grant, 0, len(m.grants) + 1, allocator)
	append(&grants, ..m.grants)
	append(&grants, Grant{scope, rights + {.Read}, 0})
	m.grants = grants[:]
	return m
}

// Ends a device's rights in a scope, or everywhere, and rotates what it could read. An owner can be left
// with no rights, but still owns the space.
draft_revoke :: proc(d: ^Draft, device: Key32, scope: Scope = 0) {
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
			g.until = d.now
			for &s in d.scopes {
				if s.id == g.scope {
					s.rotate = true
				}
			}
		}
	}
}

// Whether these keys may sign the next roster after this one.
@(require_results)
keyring_rules :: proc(k: ^Keyring, r: ^Roster) -> bool {
	return k.root != nil || slice.contains(r.admins, k.signer)
}

// Signs a draft: as an owner, given the space's seed, and otherwise as an admin. Only an owner may change
// who are owners and admins. The keyring must hold every existing scope's keys.
@(require_results)
roster_sign :: proc(k: ^Keyring, root: Maybe(Key32), d: ^Draft, allocator := context.allocator) -> (bytes: []byte, ok: bool) {
	for s in d.scopes {
		held := keyring_scope(k, s.id)
		if s.known && (held == nil || len(held.epochs) != len(s.closed) + 1) {
			return
		}
	}
	seed, owner := root.?
	if !owner {
		seed = k.seed
	}
	sk: ed25519.Private_Key
	ed25519.private_key_set_bytes(&sk, seed[:]) or_return
	defer ed25519.private_key_clear(&sk)
	space, signer, eph_secret: Key32
	ed25519.private_key_public_bytes(&sk, signer[:])
	crypto.rand_bytes(eph_secret[:])
	defer crypto.zero_explicit(&eph_secret, 32)
	eph := x25519_public(eph_secret)

	charter, admins := d.charter, d.admins
	term := d.term
	if draft_recharters(d) {
		if !owner {
			return
		}
		term += 1
		charter, admins = charter_sign(&sk, signer, seed, d, term) or_return
	}
	by: u64
	if owner {
		space = signer
	} else {
		i := slice.linear_search(admins, signer) or_return
		by = u64(i) + 1
		space = d.space
	}
	serial := serial_next(term, d.last) or_return

	current := make(map[Scope]Key32, context.temp_allocator)
	w := make([dynamic]byte, allocator)
	defer if !ok {
		delete(w)
	}
	append(&w, "zsp-r1")
	append(&w, ..space[:])
	write_bytes(&w, charter)
	write_varint(&w, serial)
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
		last: u64
		for c in s.closed {
			write_varint(&w, c)
			last = c
		}
		if len(s.closed) < epochs - 1 {
			write_varint(&w, max(d.now, last))
		}
	}
	write_varint(&w, u64(len(d.members)))
	for m in d.members {
		device, theirs := m.device, m.signer
		append(&w, ..device[:])
		append(&w, ..theirs[:])
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
		if len(m.grants) == 0 {
			continue
		}
		wrap := wrap_key(eph_secret, m.device, eph, m.device) or_return
		for g in m.grants {
			if g.until == 0 {
				append_sealed(&w, wrap, u64(g.scope), current[g.scope])
			}
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
	write_varint(&w, by)
	sig: [64]byte
	ed25519.sign(&sk, w[:], sig[:])
	append(&w, ..sig[:])
	return w[:], true
}

@(private)
draft_recharters :: proc(d: ^Draft) -> bool {
	owners, admins := 0, 0
	for m in d.members {
		if m.owner {
			owners += 1
			was := false
			for o in d.owners {
				was ||= o.device == m.device
			}
			if !was {
				return true
			}
		}
		if m.admin {
			admins += 1
			if !slice.contains(d.admins, m.signer) {
				return true
			}
		}
	}
	return d.charter == nil || owners != len(d.owners) || admins != len(d.admins)
}

@(private)
charter_sign :: proc(sk: ^ed25519.Private_Key, space, root: Key32, d: ^Draft, term: u64) -> (bytes: []byte, admins: []Key32, ok: bool) {
	eph_secret: Key32
	crypto.rand_bytes(eph_secret[:])
	defer crypto.zero_explicit(&eph_secret, 32)
	eph := x25519_public(eph_secret)
	w := make([dynamic]byte, context.temp_allocator)
	list := make([dynamic]Key32, context.temp_allocator)
	write_varint(&w, term)
	append(&w, ..eph[:])
	count: u64
	for m in d.members {
		count += 1 if m.owner else 0
	}
	write_varint(&w, count)
	for m in d.members {
		if !m.owner {
			continue
		}
		device, signer := m.device, m.signer
		append(&w, ..device[:])
		append(&w, ..signer[:])
		append_sealed(&w, wrap_key(eph_secret, device, eph, device) or_return, 0, root)
	}
	for m in d.members {
		if m.admin {
			append(&list, m.signer)
		}
	}
	write_varint(&w, u64(len(list)))
	for &a in list {
		append(&w, ..a[:])
	}
	sig: [64]byte
	ed25519.sign(sk, charter_signed(space, w[:]), sig[:])
	append(&w, ..sig[:])
	return w[:], list[:], true
}

// Recovers this device's keys from a verified roster. False if it is no longer a member.
@(require_results)
roster_unwrap :: proc(k: ^Keyring, r: ^Roster) -> bool {
	// Ownership does not hang on membership, so that no admin can end it.
	k.root = nil
	for o in r.owners {
		if o.device == k.device {
			rd := Reader{buf = r.charter}
			_ = read_varint(&rd)
			eph := read_key32(&rd)
			wrap := wrap_key(k.secret, eph, eph, k.device) or_return
			k.root = open_key(wrap, 0, o.wrap) or_return
		}
	}
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
	}
	keyring_clear(k)
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
	return true
}

@(private)
read_key32 :: proc(r: ^Reader) -> (k: Key32) {
	copy(k[:], read_take(r, 32))
	return
}
