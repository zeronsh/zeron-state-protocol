package find

import "base:runtime"
import "core:mem/virtual"
import "core:slice"
import "core:time"
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
	ended:   bool | 1, // is asked no longer, as was wished
	_:       u8   | 3,
}

Finder :: struct {
	x:       Index,
	n:       ^zsp.Node,
	live:    [dynamic]^Live,
	by_value: map[Anchor][dynamic]^Live, // questions that can only hold where a column has a value
	others:  [dynamic]^Live,
	anchors: [dynamic]^Held, // columns such questions turn on, each once
	backs:   [dynamic]^Held, // columns by which questions ask what refers to a row, each once
	before:  map[u32][dynamic]Anchor, // what rows being gone over had there
	changed: [dynamic]Changed,
	settled: bool, // this node is a full replica
	again:   [dynamic]^zsp.Session, // to be told everything afresh
	calls:   [dynamic]Called, // questions from partial replicas, not yet looked at
	pace:    bool, // an answer dear to find is not found again at once
	wake:    Maybe(time.Tick), // when one held back will be
}

@(private)
Called :: struct {
	call:   u64,
	device: zsp.Key32,
	body:   []byte,
}

// A partial replica has a full one answer, and answers from what it holds itself while none does.
@(private)
Far :: struct {
	call:   u64, // under way, if not 0
	before: u64, // by which what this replaces was asked, until this is
	device: zsp.Key32,
	source: []byte, // the question
	tried:  [dynamic]zsp.Key32, // and would not
	over:   Maybe(u8), // the call is, with this fault if not 0
	next:   []byte, // the last said, not yet looked at, if any
	spent:  int, // bytes heard since credit was last given
	answer: []byte, // the last answer
	due:    bool, // which has yet to be passed on, there being rows in it still to come
	have:   bool, // what is shown is an answer of theirs
	keys:   [dynamic]zsp.Key, // the places of its rows, which are wanted here
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
	id:    zsp.Id,
	slots: Slots,
	gone:  bool,
}

Live :: struct {
	f:       ^Finder,
	id:      u64,
	session: ^zsp.Session, // whose client asks; or
	call:    u64, // the call a partial replica does by,
	device:  zsp.Key32, // and which
	far:     Far,
	arena:   virtual.Arena, // the question
	q:       Query,
	anchor:  Maybe(Anchor),
	ready:   bool, // answered at least once
	joined:  bool, // what it holds for turns on other rows too
	rows:    Set,
	shown:   [dynamic]zsp.Id, // in order
	lives:   [dynamic][2]zsp.Key, // where those are, so that what is typed there comes here
	moved:   bool, // one of those may be elsewhere
	due:     time.Tick, // it may be found again
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
	delete(f.backs)
	for _, a in f.before {
		delete(a)
	}
	delete(f.before)
	delete(f.changed)
	delete(f.again)
	for c in f.calls {
		delete(c.body)
	}
	delete(f.calls)
	index_close(&f.x)
	f^ = {}
}

// How many questions a session, or a device, has asked.
@(private)
finder_many :: proc(f: ^Finder, s: ^zsp.Session, device: zsp.Key32) -> (many: int) {
	for l in f.live {
		many += 1 if l.session == s && l.device == device else 0
	}
	return
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
		old := live_find(f, s, id)
		if finder_many(f, s, {}) >= 1024 && old == nil {
			return false
		}
		l := new(Live)
		l.f, l.id, l.session = f, id, s
		if live_start(l, r.buf[r.pos:]) && old != nil {
			// The client holds what was shown until it is answered anew.
			l.shown, old.shown = old.shown, nil
			l.lives, old.lives = old.lives, nil
			l.far.keys, old.far.keys = old.far.keys, nil
			l.far.before, old.far.call = old.far.call, 0
			l.moved = true
		}
		if old != nil {
			live_free(old)
		}
	case UNASK:
		// Said back, since until then its rows are held, and an answer may count on that.
		if l := live_find(f, s, id); l != nil {
			live_free(l)
		}
		w := make([dynamic]byte, context.temp_allocator)
		zsp.write_varint(&w, id)
		append(&w, flag_byte({ended = true}))
		zsp.session_post(s, ANSWER, w[:])
	}
	return true
}

@(private)
live_start :: proc(l: ^Live, source: []byte) -> bool {
	f := l.f
	append(&f.live, l)
	ok: bool
	l.q, ok = query_parse(source, virtual.arena_allocator(&l.arena))
	if !ok {
		answer_flag(l, {faulty = true})
		live_free(l)
		return false
	}
	if !live_allowed(l) {
		answer_flag(l, {denied = true})
		live_free(l)
		return false
	}
	if l.session != nil && !f.settled {
		l.far.source = slice.clone(source)
	}
	index_follow(&f.x)
	query_prepare(&f.x, &l.q)
	query_uses(&l.q, 1)
	live_place(l)
	l.renew = true
	if query_ready(&f.x, &l.q) {
		// Where another asks the same, in whatever order and whatever part of it, it is known already which.
		for other in f.live {
			if other != l && other.ready && !other.renew && !other.far.have && string(other.q.which) == string(l.q.which) {
				l.rows = set_clone(&other.rows)
				l.ready, l.renew, l.stale, l.moved = true, false, true, true
				break
			}
		}
	}
	return true
}

// A partial replica asks. It is answered, later, by a full one.
finder_called :: proc(f: ^Finder, call: u64, device: zsp.Key32, body: []byte) {
	append(&f.calls, Called{call, device, slice.clone(body)})
}

// Something is said in a call, by whoever is at its other end.
finder_flow :: proc(f: ^Finder, call: u64, kind: zsp.Flow, payload: []byte) {
	for l in f.live {
		if l.call == call {
			#partial switch kind {
			case .End, .Fault, .Cancel:
				l.call = 0 // it is let go of when next gone over
			case .Credit:
				l.stale = true // what there was no room for can be said
			}
			return
		}
		if l.far.call != call {
			continue
		}
		#partial switch kind {
		case .Data:
			delete(l.far.next)
			l.far.next = slice.clone(payload)
			l.far.spent += len(payload)
		case .End, .Cancel:
			l.far.over = 0
		case .Fault:
			l.far.over = payload[0] if len(payload) > 0 else 0
		}
		return
	}
	for c, i in f.calls {
		if c.call == call && (kind == .End || kind == .Fault || kind == .Cancel) {
			delete(c.body)
			ordered_remove(&f.calls, i)
			return
		}
	}
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
		n := l.f.n
		rights := zsp.session_rights(l.session, scope) if l.session != nil else zsp.device_rights(n, l.device, scope)
		return .Read in rights && zsp.keyring_scope(n.keys, scope) != nil
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
		finder_backs(f)
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
	if l.joined {
		finder_backs(f)
	}
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
	if l.call != 0 {
		zsp.node_flow(f.n, l.call, .Fault, {u8(zsp.Call_Fault.Unserved)})
	}
	query_uses(&l.q, -1)
	set_destroy(&l.rows)
	for at in l.lives {
		zsp.session_unwants(l.session, at[0], at[1])
	}
	delete(l.lives)
	far_drop(l)
	delete(l.far.source)
	delete(l.far.tried)
	delete(l.far.next)
	delete(l.far.answer)
	delete(l.far.keys)
	delete(l.shown)
	delete(l.said)
	virtual.arena_destroy(&l.arena)
	free(l)
}

// ---------------------------------------------------------------- what changes

@(private)
finder_before :: proc(data: rawptr, s: ^Scope, row: u32) {
	f := (^Finder)(data)
	for list, i in ([]^[dynamic]^Held{&f.anchors, &f.backs}) {
		for h in list {
			if h.scope != s || !h.built || (i == 1 && slice.contains(f.anchors[:], h)) {
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
}

@(private)
finder_after :: proc(data: rawptr, s: ^Scope, row: u32, id: zsp.Id, slots: ^Slots, gone: bool) {
	f := (^Finder)(data)
	append(&f.changed, Changed{s, row, id, slots^, gone})
}

// A batch has been gone over: questions are asked of the rows in it.
@(private)
finder_done :: proc(data: rawptr) {
	f := (^Finder)(data)
	if len(f.changed) > 0 {
		for l in f.others {
			if l.joined {
				live_touched(l)
			}
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
	if !l.ready || l.renew || l.far.have {
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
	l.moved ||= now && c.slots[0] & 0xffff != 0
	// Where it stands among the others, or what they come to, may have changed all the same.
	l.stale ||= l.moved || now != was || (now && live_ordered(l, c))
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

// Asks a question again of the rows it may hold for, or not, because of others that have changed.
@(private)
live_touched :: proc(l: ^Live) {
	if !l.ready || l.renew || l.far.have || !query_ready(&l.f.x, &l.q) {
		return
	}
	s := index_scope(&l.f.x, l.q.scope)
	touched: Set
	defer set_destroy(&touched)
	if !pred_touched(l.f, s, &l.q.where_, &touched) {
		l.renew = true
		return
	}
	it := set_iterator(&touched)
	for row in set_next(&it) {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		was := set_has(&l.rows, row)
		now := set_has(&s.all, row) && pred_holds(s, &l.q.where_, row)
		if now && !was {
			set_add(&l.rows, row)
		} else if was && !now {
			set_remove(&l.rows, row)
		}
		l.stale ||= now != was
	}
}

// The rows a predicate reaches what has changed from, by what they refer to or what refers to them. False if they are so
// many that it is as well asked of all.
@(private)
pred_touched :: proc(f: ^Finder, s: ^Scope, p: ^Pred, out: ^Set) -> bool {
	if p.op != .Ref && p.op != .Back {
		for &k in p.kids {
			pred_touched(f, s, &k, out) or_return
		}
		return true
	}
	x := &f.x
	other := index_scope(x, p.scope)
	inner: Set
	defer set_destroy(&inner)
	pred_touched(f, other, &p.kids[0], &inner) or_return
	cost := 0
	refers :: proc(x: ^Index, p: ^Pred, id: zsp.Id, out: ^Set, cost: ^int) -> bool {
		key := Key{id[0], id[1]}
		cost^ += tree_between(x, p.held.by_key, key, key_next(key)).count
		if cost^ > TOUCHED + p.held.scope.all.count / 64 {
			return false
		}
		tree_subs(x, p.held.by_key, key, key_next(key), out)
		return true
	}
	referred :: proc(s: ^Scope, key: Key, out: ^Set) {
		if row, ok := row_number(s, {key.hi, key.lo}); ok {
			set_add(out, row)
		}
	}
	for &c in f.changed {
		if c.s != other {
			continue
		}
		if p.op == .Ref {
			refers(x, p, c.id, out, &cost) or_return
			continue
		}
		for v in held_values(p.held, c.row) {
			referred(s, v.key, out)
		}
		for a in f.before[c.row] {
			if a.held == p.held {
				referred(s, a.key, out)
			}
		}
	}
	it := set_iterator(&inner)
	for row in set_next(&it) {
		if p.op == .Ref {
			id := row_id(other, row) or_continue
			refers(x, p, id, out, &cost) or_return
			continue
		}
		for v in held_values(p.held, row) {
			referred(s, v.key, out)
		}
	}
	return true
}

@(private)
TOUCHED :: #config(ZSP_FIND_TOUCHED, 64)

// The columns by which some live question asks what refers to a row.
@(private)
finder_backs :: proc(f: ^Finder) {
	look :: proc(f: ^Finder, p: ^Pred) {
		if p.op == .Back && p.held != nil && !slice.contains(f.backs[:], p.held) {
			append(&f.backs, p.held)
		}
		for &k in p.kids {
			look(f, &k)
		}
	}
	clear(&f.backs)
	for l in f.others {
		if l.joined {
			look(f, &l.q.where_)
		}
	}
}

PACE :: 9 // an answer that took so long is let be for so many times as long,
PACE_OVER :: time.Millisecond // if it took that,
PACE_MOST :: 2 * time.Second // and for no longer

// Does some of what there is to do, and says whatever follows from it. True when there is nothing left.
finder_run :: proc(f: ^Finder, budget := 500) -> bool {
	for c in f.calls {
		if !f.settled {
			zsp.node_flow(f.n, c.call, .Fault, {u8(zsp.Call_Fault.Unserved)})
		} else if finder_many(f, nil, c.device) >= 1024 {
			zsp.node_flow(f.n, c.call, .Fault, {u8(zsp.Call_Fault.Busy)})
		} else {
			l := new(Live)
			l.f, l.call, l.device = f, c.call, c.device
			live_start(l, c.body)
		}
		delete(c.body)
	}
	clear(&f.calls)
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
			l.said, l.stale, l.far.due = nil, true, l.far.due || l.far.have
			l.due = {}
		}
	}
	clear(&f.again)
	local := false
	#reverse for l in f.live {
		if l.session == nil && (l.call == 0 || !live_allowed(l)) {
			if l.call != 0 {
				zsp.node_flow(f.n, l.call, .Fault, {u8(zsp.Call_Fault.Denied)})
			}
			live_free(l)
			continue
		}
		if l.far.source != nil {
			far_run(l)
		}
		local ||= !l.far.have
	}
	level := !local || index_step(&f.x, budget)
	for l in f.live {
		// A column may be being made again, and what was asked of it meanwhile means nothing.
		l.renew ||= l.ready && !query_ready(&f.x, &l.q)
	}
	f.wake = nil
	now := time.tick_now()
	for l in f.live {
		if l.far.have {
			continue
		}
		if f.pace && (l.stale || l.renew) && time.tick_diff(now, l.due) > 0 {
			if w, some := f.wake.?; !some || time.tick_diff(l.due, w) > 0 {
				f.wake = l.due
			}
			continue
		}
		if !l.ready || l.renew {
			if !f.x.tailing || f.x.checking || !query_ready(&f.x, &l.q) {
				if !l.ready {
					answer_wait(l)
				}
				continue
			}
			set_destroy(&l.rows)
			l.rows = pred_rows(index_scope(&f.x, l.q.scope), &l.q.where_)
			l.ready, l.renew, l.stale, l.moved = true, false, true, true
		}
		if l.stale {
			l.stale = false
			answer_send(l)
			then := time.tick_now()
			if took := time.tick_diff(now, then); took > PACE_OVER {
				l.due = time.tick_add(then, min(PACE * took, PACE_MOST))
			}
			now = then
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
	answer_begin(l, &w, flags)
	answer_post(l, w[:])
}

@(private)
answer_begin :: proc(l: ^Live, w: ^[dynamic]byte, flags: Answer_Flags) {
	if l.session != nil {
		zsp.write_varint(w, l.id)
	}
	append(w, flag_byte(flags))
}

// False if there is not yet room to.
@(private)
answer_post :: proc(l: ^Live, w: []byte) -> bool {
	if l.session != nil {
		zsp.session_post(l.session, ANSWER, w)
		return true
	}
	if len(w) > zsp.CALL_WINDOW {
		zsp.node_flow(l.f.n, l.call, .Fault, {u8(zsp.Call_Fault.Overrun)})
		l.call = 0
		return true
	}
	if len(w) > zsp.node_granted(l.f.n, l.call) {
		return false
	}
	zsp.node_flow(l.f.n, l.call, .Data, w)
	return true
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
	answer_begin(l, &w, {waiting = true})
	append(&w, u8(min(done, 99)))
	answer_post(l, w[:])
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
	answer_begin(l, &w, {settled = f.settled})
	zsp.write_varint(&w, u64(l.rows.count))
	first := max(l.rows.count - l.q.offset - len(page), 0) if l.q.from_end else min(l.q.offset, l.rows.count)
	zsp.write_varint(&w, u64(first))
	zsp.write_varint(&w, u64(len(page)))
	for hit in page {
		if l.session == nil {
			zsp.write_key(&w, live_key(l, hit.id)) // so that it can be watched there
			continue
		}
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
	ids := make([]zsp.Id, len(page), context.temp_allocator)
	for hit, i in page {
		ids[i] = hit.id
	}
	if l.session != nil {
		live_wants(l, ids)
	}
	l.moved = false
	answer_say(l, ids, w[:])
}

@(private)
answer_say :: proc(l: ^Live, ids: []zsp.Id, w: []byte) {
	if string(l.said) == string(w) {
		return
	}
	if l.session != nil {
		for id in ids {
			if !slice.contains(l.shown[:], id) && !finder_shows(l.f, l.session, id) {
				zsp.session_show(l.session, id)
			}
		}
	}
	if !answer_post(l, w) {
		return // credit will come, and whatever is so by then is said
	}
	clear(&l.shown)
	append(&l.shown, ..ids)
	delete(l.said)
	l.said = slice.clone(w)
}

// Where a row is, or if nowhere, somewhere it never will be.
@(private)
live_key :: proc(l: ^Live, id: zsp.Id) -> zsp.Key {
	places := zsp.row_places(&l.f.n.store, id)
	if places.count > 0 {
		return places.keys[0]
	}
	return {id[0] & 0xffff_ffff_0000_0000, 0, 0, id[0], id[1]}
}

// ---------------------------------------------------------------- answers from afar

@(private)
far_run :: proc(l: ^Live) {
	f, far := l.f, &l.far
	if fault, over := far.over.?; over {
		far.over, far.call = nil, 0
		if zsp.Call_Fault(fault) != .Lost {
			append(&far.tried, far.device)
		}
		far_drop(l)
	}
	reach := zsp.node_reach(f.n)
	#reverse for device, i in far.tried {
		if !slice.contains(reach, device) {
			unordered_remove(&far.tried, i) // it may come back otherwise minded
		}
	}
	if far.call == 0 {
		for device in reach {
			if slice.contains(far.tried[:], device) {
				continue
			}
			if far.call = zsp.node_call(f.n, device, l.q.scope, far.source); far.call != 0 {
				far.device = device
				break
			}
		}
	}
	far_past(l)
	if far.call != 0 && far.spent > zsp.CALL_WINDOW / 2 {
		w := make([dynamic]byte, context.temp_allocator)
		zsp.write_varint(&w, u64(far.spent))
		zsp.node_flow(f.n, far.call, .Credit, w[:])
		far.spent = 0
	}
	if far.next != nil {
		next := far.next
		far.next = nil
		defer delete(next)
		r := zsp.Reader{buf = next}
		flags := Answer_Flags(zsp.read_u8(&r))
		switch {
		case flags.waiting: // what is here will do until it is done
		case flags.denied || flags.faulty || !far_wants(l, &r):
			zsp.node_flow(f.n, far.call, .Cancel)
			far.call = 0
			append(&far.tried, far.device)
			far_drop(l)
		case:
			delete(far.answer)
			far.answer, next = next, nil
			far.due = true
		}
	}
	if far.due && far_whole(l) {
		far.due, far.have = false, true
		far_say(l)
	}
}

// Reads where the rows of an answer are, and wants what is there.
@(private)
far_wants :: proc(l: ^Live, r: ^zsp.Reader) -> bool {
	_, _ = zsp.read_varint(r), zsp.read_varint(r) // how many in all, and where these come among them
	n := int(zsp.read_varint(r) & 0xffff)
	if r.bad || n > 1000 || (len(r.buf) - r.pos) < n * 40 {
		return false
	}
	keys := make([dynamic]zsp.Key, 0, n)
	new := make(map[zsp.Key]bool, context.temp_allocator)
	for _ in 0 ..< n {
		k := zsp.read_key(r)
		if zsp.key_scope(k) != l.q.scope || zsp.row_scope(zsp.key_row(k)) != l.q.scope || k in new {
			delete(keys)
			return false
		}
		append(&keys, k)
		new[k] = true
	}
	for k in l.far.keys {
		if k in new {
			delete_key(&new, k)
		} else {
			zsp.session_unwants(l.session, k, zsp.key_next(k), true)
		}
	}
	for k in keys {
		if k in new {
			zsp.session_wants(l.session, k, zsp.key_next(k), true)
		}
	}
	delete(l.far.keys)
	l.far.keys = keys
	return true
}

// Whether all the rows of an answer are here. One that moves or goes before it comes is answered for anew, and one
// that is nowhere never comes.
@(private)
far_whole :: proc(l: ^Live) -> bool {
	for k in l.far.keys {
		if zsp.row_places(&l.f.n.store, zsp.key_row(k)).count == 0 && !zsp.is_graveyard(zsp.key_list(k)) {
			return false
		}
	}
	return true
}

@(private)
far_say :: proc(l: ^Live) {
	r := zsp.Reader{buf = l.far.answer}
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&w, l.id)
	append(&w, zsp.read_u8(&r))
	zsp.write_varint(&w, zsp.read_varint(&r))
	zsp.write_varint(&w, zsp.read_varint(&r))
	n := int(zsp.read_varint(&r))
	zsp.write_varint(&w, u64(n))
	ids := make([]zsp.Id, n, context.temp_allocator)
	for &id in ids {
		id = zsp.key_row(zsp.read_key(&r))
		zsp.write_u64(&w, id[0])
		zsp.write_u64(&w, id[1])
	}
	append(&w, ..r.buf[r.pos:])
	live_wants(l, nil) // the places themselves are
	answer_say(l, ids, w[:])
}

// Only now that what replaces it has been asked: it may be answered from what was found for that.
@(private)
far_past :: proc(l: ^Live) {
	if l.far.before != 0 {
		zsp.node_flow(l.f.n, l.far.before, .Cancel)
		l.far.before = 0
	}
}

// What was answered from afar is no longer known to be so.
@(private)
far_drop :: proc(l: ^Live) {
	far := &l.far
	far_past(l)
	if far.call != 0 {
		zsp.node_flow(l.f.n, far.call, .Cancel)
		far.call = 0
	}
	for k in far.keys {
		zsp.session_unwants(l.session, k, zsp.key_next(k), true)
	}
	clear(&far.keys)
	if far.have {
		l.renew, l.moved = true, true
	}
	delete(far.next)
	far.next = nil
	far.have, far.due, far.spent = false, false, 0
}


LIVE_LISTS :: 16

// Asks for live text where the rows about to be shown are: a stretch of each list they are in, or where those are
// many, one of everything between.
@(private)
live_wants :: proc(l: ^Live, page: []zsp.Id) {
	same := len(page) == len(l.shown) && !l.moved
	for hit, i in page {
		same = same && hit == l.shown[i]
	}
	if same {
		return
	}
	l.moved = false
	n := l.f.n
	want: [LIVE_LISTS + 1][2]zsp.Key
	count := 0
	all := [2]zsp.Key{zsp.KEY_MAX, zsp.KEY_MIN}
	for hit in page {
		places := zsp.row_places(&n.store, hit)
		if places.count == 0 || zsp.is_graveyard(zsp.key_list(places.keys[0])) {
			continue
		}
		lo := places.keys[0]
		hi := zsp.key_next(lo)
		at := 0
		for at < count && zsp.key_list(want[at][0]) != zsp.key_list(lo) {
			at += 1
		}
		if at == count && count <= LIVE_LISTS {
			want[at] = {lo, hi}
			count += 1
		}
		for r in ([]^[2]zsp.Key{&all, &want[min(at, LIVE_LISTS)]}) {
			r[0] = lo if zsp.key_less(lo, r[0]) else r[0]
			r[1] = hi if zsp.key_less(r[1], hi) else r[1]
		}
	}
	if count > LIVE_LISTS {
		want[0], count = all, 1
	}
	// What was asked for already will do, unless it is of much else.
	#reverse for old, i in l.lives {
		keep := false
		for w, j in want[:count] {
			if !zsp.key_less(w[0], old[0]) && !zsp.key_less(old[1], w[1]) && zsp.store_range(&n.store, old[0], old[1]).count <= 64 + 4 * len(page) {
				keep = true
				count -= 1
				want[j] = want[count]
				break
			}
		}
		if !keep {
			zsp.session_unwants(l.session, old[0], old[1])
			unordered_remove(&l.lives, i)
		}
	}
	for w in want[:count] {
		zsp.session_wants(l.session, w[0], w[1])
		append(&l.lives, w)
	}
}
