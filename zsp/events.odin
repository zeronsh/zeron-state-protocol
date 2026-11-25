package zsp

// A bounded ring of recent changes. Sessions tail it with a single cursor, so a session costs no
// queue; one that falls off the back reconciles its windows by fingerprint instead.

Event :: struct {
	row:    Id,
	slot:   Slot,
	kind:   Kind,
	stamp:  Stamp,
	origin: u32, // session the change came from
}

Change :: struct {
	using event: Event,
	before:      []Key,
	after:       []Key,
}

Ring :: struct {
	items: []Slotted,
	first: u64, // oldest retained
	next:  u64,
	spill: map[u64][]Key, // keys of the rare events with more than INLINE_KEYS of them
}

INLINE_KEYS :: 2

@(private)
Slotted :: struct {
	using event: Event,
	keys:        [INLINE_KEYS]Key,
	old, new:    u8,
}

ring_init :: proc(r: ^Ring, size: int) {
	r.items = make([]Slotted, size)
}

ring_destroy :: proc(r: ^Ring) {
	ring_clear(r)
	delete(r.items)
	delete(r.spill)
}

ring_clear :: proc(r: ^Ring) {
	for _, k in r.spill {
		delete(k)
	}
	clear(&r.spill)
	r.first = r.next
}

ring_push :: proc(r: ^Ring, e: Event, before, after: ^Places) {
	if r.next - r.first == u64(len(r.items)) {
		if k, ok := r.spill[r.first]; ok {
			delete(k)
			delete_key(&r.spill, r.first)
		}
		r.first += 1
	}
	it := &r.items[r.next % u64(len(r.items))]
	it.event = e
	it.old, it.new = u8(before.count), u8(after.count)
	// An unmoved row stores its keys once.
	same := before.count == after.count && before.keys == after.keys
	if same {
		it.old = 0xff
	}
	n := after.count + (0 if same else before.count)
	into := it.keys[:]
	if n > INLINE_KEYS {
		into = make([]Key, n)
		r.spill[r.next] = into
	}
	copy(into, after.keys[:after.count])
	if !same {
		copy(into[after.count:], before.keys[:before.count])
	}
	r.next += 1
}

@(require_results)
ring_at :: proc(r: ^Ring, i: u64) -> (c: Change) {
	it := &r.items[i % u64(len(r.items))]
	c.event = it.event
	keys := r.spill[i] or_else it.keys[:]
	c.after = keys[:it.new]
	c.before = c.after if it.old == 0xff else keys[it.new:][:it.old]
	return
}
