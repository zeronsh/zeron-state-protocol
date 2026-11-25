package find

import "core:mem/virtual"
import "core:slice"
import "../zsp"

// Questions that stay asked. Each remembers which rows it holds for, so that a change costs no more than asking
// it of the row that changed; and questions that turn on one value are found by that value, so that those a
// change cannot matter to are not asked at all.

ASK :: 32 // id varint, question
UNASK :: 33 // id varint
ANSWER :: 34 // see answer_send

Answer_Flags :: bit_field u8 {
	settled: bool | 1, // a full replica says so
	denied:  bool | 1, // may not be asked, and is no longer
	faulty:  bool | 1, // makes no sense
	waiting: bool | 1, // an index is being made, and nothing else is said but how much of it is
	_:       u8   | 4,
}

Finder :: struct {
	x:       Index,
	n:       ^zsp.Node,
	live:    [dynamic]^Live,
	by_value: map[Anchor][dynamic]^Live, // questions that can only hold where a column has a value
	others:  [dynamic]^Live,
	anchors: [dynamic]^Held, // columns such questions turn on, each once
	before:  map[u32][dynamic]Anchor, // what rows being gone over had there
	changed: [dynamic]Changed,
	settled: bool, // this node is a full replica
	again:   [dynamic]^zsp.Session, // to be told everything afresh
}

@(private)
Anchor :: struct {
	held: ^Held,
	key:  Key,
}

@(private)
Changed :: struct {
	s:     ^Scope,
	row:   u32,
	slots: Slots,
	gone:  bool,
}

Live :: struct {
	f:       ^Finder,
	id:      u64,
	session: ^zsp.Session,
	arena:   virtual.Arena, // the question
	q:       Query,
	anchor:  Maybe(Anchor),
	ready:   bool, // answered at least once
	joined:  bool, // what it holds for turns on other rows too
	rows:    Set,
	shown:   [dynamic]zsp.Id, // in order
	first:   int,
	said:    []byte, // the last answer
	stale:   bool, // the page may have changed
	renew:   bool, // and so may all of it
	waited:  int, // the last said of how much of the index is made
}

finder_open :: proc(f: ^Finder, n: ^zsp.Node, disk: Disk, key: zsp.Key32) {
	f.n = n
	index_open(&f.x, n, disk, key)
	append(&f.x.watchers, Watcher{f, finder_before, finder_after, finder_done})
}

finder_close :: proc(f: ^Finder) {
	for len(f.live) > 0 {
		live_free(f.live[0])
	}
	delete(f.live)
	for _, l in f.by_value {
		delete(l)
	}
	delete(f.by_value)
	delete(f.others)
	delete(f.anchors)
	for _, a in f.before {
		delete(a)
	}
	delete(f.before)
	delete(f.changed)
	delete(f.again)
	index_close(&f.x)
	f^ = {}
}

// A message from a client. False if it makes no sense.
finder_asked :: proc(f: ^Finder, s: ^zsp.Session, type: u8, payload: []byte) -> bool {
	r := zsp.Reader{buf = payload}
	id := zsp.read_varint(&r)
	if r.bad {
		return false
	}
	switch type {
	case ASK:
		if l := live_find(f, s, id); l != nil {
			live_free(l)
		}
		many := 0
		for l in f.live {
			many += 1 if l.session == s else 0
		}
		if many >= 1024 {
			return false
		}
		l := new(Live)
		l.f, l.id, l.session = f, id, s
		append(&f.live, l)
		ok: bool
		l.q, ok = query_parse(r.buf[r.pos:], virtual.arena_allocator(&l.arena))
		if !ok {
			answer_flag(l, {faulty = true})
			live_free(l)
			return true
		}
		if !live_allowed(l) {
			answer_flag(l, {denied = true})
			live_free(l)
			return true
		}
		index_follow(&f.x)
		query_prepare(&f.x, &l.q)
		query_uses(&l.q, 1)
		live_place(l)
		l.renew = true
	case UNASK:
		if l := live_find(f, s, id); l != nil {
			live_free(l)
		}
	}
	return true
}

@(private)
live_find :: proc(f: ^Finder, s: ^zsp.Session, id: u64) -> ^Live {
	for l in f.live {
		if l.session == s && l.id == id {
			return l
		}
	}
	return nil
}

finder_ended :: proc(f: ^Finder, s: ^zsp.Session) {
	#reverse for l in f.live {
		if l.session == s {
			live_free(l)
		}
	}
	#reverse for other, i in f.again {
		if other == s {
			unordered_remove(&f.again, i)
		}
	}
}

finder_again :: proc(f: ^Finder, s: ^zsp.Session) {
	if !slice.contains(f.again[:], s) {
		append(&f.again, s)
	}
}

// Whether an answer a session has is showing a row.
finder_shows :: proc(f: ^Finder, s: ^zsp.Session, row: zsp.Id) -> bool {
	for l in f.live {
		if l.session == s && slice.contains(l.shown[:], row) {
			return true
		}
	}
	return false
}

// A client may ask about scopes it may read, in every part of a question.
@(private)
live_allowed :: proc(l: ^Live) -> bool {
	may :: proc(l: ^Live, scope: zsp.Scope) -> bool {
		return .Read in zsp.session_rights(l.session, scope) && zsp.keyring_scope(l.f.n.keys, scope) != nil
	}
	parts :: proc(l: ^Live, p: ^Pred) -> bool {
		if p.op == .Ref || p.op == .Back {
			may(l, p.scope) or_return
		}
		for &k in p.kids {
			parts(l, &k) or_return
		}
		return true
	}
	return may(l, l.q.scope) && parts(l, &l.q.where_)
}

// Finds the value a question turns on, if there is one.
@(private)
live_place :: proc(l: ^Live) {
	f := l.f
	best: Maybe(Anchor)
	look :: proc(p: ^Pred, best: ^Maybe(Anchor)) {
		#partial switch p.op {
		case .And:
			for &k in p.kids {
				look(&k, best)
			}
		case .Range:
			b := &p.range
			if best^ == nil && p.held != nil && b.has_lo && b.has_hi && b.lo_in && b.hi_in && b.lo.key == b.hi.key {
				best^ = Anchor{p.held, b.lo.key}
			}
		case .In:
			if best^ == nil && p.held != nil && len(p.set) == 1 {
				best^ = Anchor{p.held, p.set[0].key}
			}
		}
	}
	look(&l.q.where_, &best)
	joins :: proc(p: ^Pred) -> bool {
		if p.op == .Ref || p.op == .Back {
			return true
		}
		for &k in p.kids {
			if joins(&k) {
				return true
			}
		}
		return false
	}
	l.joined = joins(&l.q.where_)
	l.anchor = best
	if a, ok := best.?; ok && !l.joined {
		if a not_in f.by_value {
			f.by_value[a] = {}
		}
		append(&f.by_value[a], l)
		if !slice.contains(f.anchors[:], a.held) {
			append(&f.anchors, a.held)
		}
	} else {
		l.anchor = nil
		append(&f.others, l)
	}
}

@(private)
live_free :: proc(l: ^Live) {
	f := l.f
	take :: proc(from: ^[dynamic]^Live, l: ^Live) {
		for other, i in from {
			if other == l {
				unordered_remove(from, i)
				return
			}
		}
	}
	take(&f.live, l)
	take(&f.others, l)
	if a, ok := l.anchor.?; ok {
		if at := &f.by_value[a]; at != nil {
			take(at, l)
			if len(at) == 0 {
				delete(at^)
				delete_key(&f.by_value, a)
				used := false
				for other in f.by_value {
					used ||= other.held == a.held
				}
				if !used {
					for h, i in f.anchors {
						if h == a.held {
							unordered_remove(&f.anchors, i)
							break
						}
					}
				}
			}
		}
	}
	query_uses(&l.q, -1)
	set_destroy(&l.rows)
	delete(l.shown)
	delete(l.said)
	virtual.arena_destroy(&l.arena)
	free(l)
}

// ---------------------------------------------------------------- what changes

@(private)
finder_before :: proc(data: rawptr, s: ^Scope, row: u32) {
	f := (^Finder)(data)
	for h in f.anchors {
		if h.scope != s || !h.built {
			continue
		}
		for v in held_values(h, row) {
			if row not_in f.before {
				f.before[row] = {}
			}
			append(&f.before[row], Anchor{h, v.key})
		}
	}
}

@(private)
finder_after :: proc(data: rawptr, s: ^Scope, row: u32, slots: ^Slots, gone: bool) {
	f := (^Finder)(data)
	append(&f.changed, Changed{s, row, slots^, gone})
}

// A batch has been gone over: questions are asked of the rows in it.
@(private)
finder_done :: proc(data: rawptr) {
	f := (^Finder)(data)
	if len(f.changed) > 0 {
		for l in f.others {
			for &c in f.changed {
				live_changed(l, &c)
			}
		}
		for &c in f.changed {
			for h in f.anchors {
				if h.scope != c.s || !h.built || c.gone {
					continue
				}
				for v in held_values(h, c.row) {
					for l in f.by_value[Anchor{h, v.key}] {
						live_changed(l, &c)
					}
				}
			}
			// Those it may have been in, and is in no longer.
			for a in f.before[c.row] {
				for l in f.by_value[a] {
					live_changed(l, &c)
				}
			}
		}
	}
	clear(&f.changed)
	for _, a in f.before {
		delete(a)
	}
	clear(&f.before)
}

@(private)
live_changed :: proc(l: ^Live, c: ^Changed) {
	if !l.ready || l.renew {
		return
	}
	if l.joined {
		if live_reads(l, c) {
			l.renew = true
		}
		return
	}
	if c.s.id != l.q.scope {
		return
	}
	was := set_has(&l.rows, c.row)
	now := !c.gone && pred_holds(c.s, &l.q.where_, c.row)
	if now && !was {
		set_add(&l.rows, c.row)
	} else if was && !now {
		set_remove(&l.rows, c.row)
	}
	// Where it stands among the others, or what they come to, may have changed all the same.
	l.stale ||= now != was || (now && live_ordered(l, c))
}

@(private)
live_ordered :: proc(l: ^Live, c: ^Changed) -> bool {
	reads :: proc(col: ^Column, slots: ^Slots) -> bool {
		if col.kind == .Modified {
			return true
		}
		for slot in 0 ..= 255 {
			if slots[slot >> 6] >> (u64(slot) & 63) & 1 != 0 && column_reads(col, zsp.Slot(slot)) {
				return true
			}
		}
		return false
	}
	for &o in l.q.order {
		if o.by == .Relevance || (o.by == .Column && reads(&o.col, &c.slots)) {
			return true
		}
	}
	for &a in l.q.totals {
		if reads(&a.col, &c.slots) {
			return true
		}
	}
	return false
}

// Whether a change is to a scope that some part of a question is about.
@(private)
live_reads :: proc(l: ^Live, c: ^Changed) -> bool {
	about :: proc(p: ^Pred, id: zsp.Scope) -> bool {
		if (p.op == .Ref || p.op == .Back) && p.scope == id {
			return true
		}
		for &k in p.kids {
			if about(&k, id) {
				return true
			}
		}
		return false
	}
	return c.s.id == l.q.scope || about(&l.q.where_, c.s.id)
}

// Does some of what there is to do, and says whatever follows from it. True when there is nothing left.
finder_run :: proc(f: ^Finder, budget := 500) -> bool {
	if len(f.live) == 0 {
		return true
	}
	level := index_step(&f.x, budget)
	for l in f.live {
		// A column may be being made again, and what was asked of it meanwhile means nothing.
		l.renew ||= l.ready && !query_ready(&f.x, &l.q)
	}
	for s in f.again {
		#reverse for l in f.live {
			if l.session != s {
				continue
			}
			if !live_allowed(l) {
				answer_flag(l, {denied = true})
				live_free(l)
				continue
			}
			clear(&l.shown)
			delete(l.said)
			l.said, l.stale = nil, true
		}
	}
	clear(&f.again)
	for l in f.live {
		if !l.ready || l.renew {
			if !f.x.tailing || f.x.checking || !query_ready(&f.x, &l.q) {
				if !l.ready {
					answer_wait(l)
				}
				continue
			}
			set_destroy(&l.rows)
			l.rows = pred_rows(index_scope(&f.x, l.q.scope), &l.q.where_)
			l.ready, l.renew, l.stale = true, false, true
		}
		if l.stale {
			l.stale = false
			answer_send(l)
		}
	}
	return level
}

// ---------------------------------------------------------------- answers

@(private)
flag_byte :: proc(f: Answer_Flags) -> u8 {
	return u8(f)
}

@(private)
answer_flag :: proc(l: ^Live, flags: Answer_Flags) {
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&w, l.id)
	append(&w, flag_byte(flags))
	zsp.session_post(l.session, ANSWER, w[:])
}

// How much of what it needs is made, in hundredths.
@(private)
answer_wait :: proc(l: ^Live) {
	s := index_scope(&l.f.x, l.q.scope)
	done := 0
	if s != nil && s.built {
		parts, whole := 1, 1
		for h in s.columns {
			parts += 1
			if h.built {
				whole += 1
			} else if h.filling != nil && s.next > 0 {
				done += int(u64(h.filling.row) * 90 / u64(s.next))
			}
		}
		done = (done + whole * 100) / parts
	}
	if done == l.waited && l.waited != 0 {
		return
	}
	l.waited = done
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&w, l.id)
	append(&w, flag_byte({waiting = true}), u8(min(done, 99)))
	zsp.session_post(l.session, ANSWER, w[:])
}

// id varint, flags, how many rows there are in all, where the first shown comes, and the rows shown in order; then
// what each total comes to. Rows not shown before are sent, whole, ahead of it.
@(private)
answer_send :: proc(l: ^Live) {
	f := l.f
	s := index_scope(&f.x, l.q.scope)
	page := query_page(s, &l.q, &l.rows)
	totals := query_totals(s, &l.q, &l.rows)
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&w, l.id)
	append(&w, flag_byte({settled = f.settled}))
	zsp.write_varint(&w, u64(l.rows.count))
	first := max(l.rows.count - l.q.offset - len(page), 0) if l.q.from_end else min(l.q.offset, l.rows.count)
	zsp.write_varint(&w, u64(first))
	zsp.write_varint(&w, u64(len(page)))
	for hit in page {
		zsp.write_u64(&w, hit.id[0])
		zsp.write_u64(&w, hit.id[1])
	}
	zsp.write_varint(&w, u64(len(totals)))
	for t, i in totals {
		append(&w, 1 if t.some else 0)
		zsp.write_u64(&w, transmute(u64)t.number)
		zsp.write_varint(&w, u64(len(t.facets)))
		for facet in t.facets {
			zsp.write_varint(&w, u64(facet.count))
			zsp.write_bytes(&w, facet_bytes(s, &l.q.totals[i], facet))
		}
	}
	if string(l.said) == string(w[:]) {
		return
	}
	for hit in page {
		if !slice.contains(l.shown[:], hit.id) && !finder_shows(f, l.session, hit.id) {
			zsp.session_show(l.session, hit.id)
		}
	}
	clear(&l.shown)
	for hit in page {
		append(&l.shown, hit.id)
	}
	delete(l.said)
	l.said = slice.clone(w[:])
	zsp.session_post(l.session, ANSWER, w[:])
}

// A value as its kind is written.
@(private)
facet_bytes :: proc(s: ^Scope, a: ^Aggregate, facet: Facet) -> []byte {
	b := make([]byte, 16, context.temp_allocator)
	zsp.put_u64(b, facet.key.hi)
	zsp.put_u64(b[8:], facet.key.lo)
	switch a.col.kind {
	case .Bytes, .Fold:
		id, _ := row_id(s, facet.row)
		r := Row{n = s.x.n, id = id}
		for v in row_bytes(&r, &a.col) {
			if k, _ := bytes_key(v); k == facet.key {
				return v
			}
		}
		n := 16
		for n > 0 && b[n - 1] == 0 {
			n -= 1
		}
		return b[:n]
	case .Number, .Created, .Modified:
		zsp.put_u64(b, transmute(u64)key_number(facet.key))
		return b[:8]
	case .Bool:
		return b[7:8]
	case .Order:
		return b[:8]
	case .Id, .Words:
	}
	return b
}
