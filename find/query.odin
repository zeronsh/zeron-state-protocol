package find

import "core:bytes"
import "core:slice"
import "core:strings"
import "../zsp"

// A question: which rows of a scope, in what order, which stretch of them, and what they come to together.

Op :: enum u8 {
	All    = 0,
	And    = 1,
	Or     = 2,
	Not    = 3,
	Range  = 4, // a value between bounds
	In     = 5, // a value that is one of these
	Prefix = 6,
	Has    = 7, // a value that has this inside it
	Exists = 8,
	List   = 9, // in a list
	Match  = 10, // words
	Ids    = 11,
	Ref    = 12, // refers to a row that …
	Back   = 13, // is referred to by so many rows that …
}

Pred :: struct {
	op:    Op,
	col:   Column,
	held:  ^Held, // when the index has it
	kids:  []Pred,
	range: Bounds,
	set:   []Bound, // ascending
	bytes: []byte, // as compared: folded where that is how
	list:  zsp.List,
	words: Word_Query,
	ids:   []zsp.Id, // ascending
	scope: zsp.Scope, // of the rows `kids[0]` is about
	min, max: u64,
}

Bound :: struct {
	using value: Value,
	bytes: []byte, // in full, as compared
}

Bounds :: struct {
	lo, hi: Bound,
	has_lo, has_hi: bool,
	lo_in, hi_in: bool, // itself included
}

Word_Mode :: enum u8 {
	Every  = 0, // each of the words
	Any    = 1, // at least one
	Phrase = 2, // in a row
}

Word_Flags :: bit_field u8 {
	prefix: bool | 1, // the last word may be only begun
	inside: bool | 1, // words may be inside others
	edits:  u8   | 2, // letters that may be wrong
	_:      u8   | 4,
}

Word_Query :: struct {
	mode:  Word_Mode,
	flags: Word_Flags,
	words: []Word,
}

Sort :: struct {
	by:   enum u8 {
		Column    = 0,
		Relevance = 1,
		Created   = 2, // and, rows made in the same second, by their ids: an order in full
	},
	desc: bool,
	col:  Column,
	held: ^Held,
}

Fn :: enum u8 {
	Sum   = 1,
	Min   = 2,
	Max   = 3,
	Count = 4, // rows that have a value
	Facet = 5, // the commonest values, and how many rows have each
}

Aggregate :: struct {
	fn:   Fn,
	col:  Column,
	held: ^Held,
	top:  int,
}

Query :: struct {
	scope:  zsp.Scope,
	where_: Pred,
	which:  []byte, // what says so, and of which scope
	order:  []Sort,
	from_end: bool,
	offset: int,
	limit:  int,
	totals: []Aggregate,
	// Everything above lies in here.
	source: []byte,
}

MAX_DEPTH :: 32
MAX_PREDS :: 4096
MAX_LIMIT :: 1000

// Reads a question. All it holds is made with the allocator.
query_parse :: proc(source: []byte, allocator := context.temp_allocator) -> (q: Query, ok: bool) {
	context.allocator = allocator
	q.source = slice.clone(source)
	r := zsp.Reader{buf = q.source}
	q.scope = scope_parse(&r)
	left := MAX_PREDS
	q.where_ = pred_parse(&r, 0, &left)
	q.which = q.source[:r.pos]
	orders := zsp.read_count(&r)
	if orders > 8 {
		return
	}
	q.order = make([]Sort, orders)
	for &s in q.order {
		by := zsp.read_u8(&r)
		if by > u8(max(type_of(s.by))) {
			return
		}
		s.by = type_of(s.by)(by)
		s.desc = zsp.read_u8(&r) != 0
		if s.by == .Column {
			s.col = column_parse(&r)
			if !r.bad && !column_sorted(s.col.kind) {
				return
			}
		}
	}
	q.from_end = zsp.read_u8(&r) != 0
	q.offset = int(min(zsp.read_varint(&r), u64(max(i32))))
	q.limit = int(min(zsp.read_varint(&r), MAX_LIMIT))
	totals := zsp.read_count(&r)
	if totals > 64 {
		return
	}
	q.totals = make([]Aggregate, totals)
	for &a in q.totals {
		fn := zsp.read_u8(&r)
		if fn < u8(min(Fn)) || fn > u8(max(Fn)) {
			return
		}
		a.fn = Fn(fn)
		a.col = column_parse(&r)
		a.top = int(min(zsp.read_varint(&r), MAX_LIMIT))
		if !r.bad && (!column_sorted(a.col.kind) || (a.fn == .Sum && a.col.kind != .Number)) {
			return
		}
	}
	return q, !r.bad && r.pos == len(r.buf) && q.scope != 0
}

@(private)
column_parse :: proc(r: ^zsp.Reader) -> (c: Column) {
	kind := zsp.read_u8(r)
	if kind < u8(min(Kind)) || kind > u8(max(Kind)) {
		r.bad = true
		return
	}
	c.kind = Kind(kind)
	switch c.kind {
	case .Bytes, .Fold, .Number, .Bool, .Id, .Words:
		c.slot = zsp.Slot(zsp.read_u8(r))
		c.path = string(zsp.read_bytes(r))
		if c.slot < zsp.DATA || strings.contains(c.path, "\x00") {
			r.bad = true
		}
	case .Order:
		c.list = {zsp.read_u64(r), zsp.read_u64(r)}
	case .Created, .Modified:
	}
	return
}

@(private)
bound_parse :: proc(r: ^zsp.Reader, kind: Kind) -> (b: Bound) {
	raw := zsp.read_bytes(r)
	v, ok := value_key(kind, raw)
	if r.bad || !ok {
		r.bad = true
		return
	}
	b.value = v
	b.bytes = compared(kind, raw)
	return
}

// Bytes as a kind compares them.
@(private)
compared :: proc(kind: Kind, raw: []byte) -> []byte {
	if kind != .Fold {
		return raw
	}
	out := make([dynamic]byte, 0, len(raw))
	fold(raw, &out)
	return out[:]
}

@(private)
scope_parse :: proc(r: ^zsp.Reader) -> zsp.Scope {
	v := zsp.read_varint(r)
	if v == 0 || v >= u64(max(zsp.Scope)) {
		r.bad = true
		return 0
	}
	return zsp.Scope(v)
}

@(private)
pred_parse :: proc(r: ^zsp.Reader, depth: int, left: ^int) -> (p: Pred) {
	left^ -= 1
	op := zsp.read_u8(r)
	if r.bad || op > u8(max(Op)) || depth > MAX_DEPTH || left^ < 0 {
		r.bad = true
		return
	}
	p.op = Op(op)
	switch p.op {
	case .All:
	case .And, .Or, .Not:
		n := 1 if p.op == .Not else zsp.read_count(r)
		if n > left^ {
			r.bad = true
			return
		}
		p.kids = make([]Pred, n)
		for &k in p.kids {
			k = pred_parse(r, depth + 1, left)
		}
	case .Range:
		p.col = column_parse(r)
		flags := zsp.read_u8(r)
		r.bad ||= p.col.kind == .Words
		b := &p.range
		b.has_lo, b.has_hi, b.lo_in, b.hi_in = flags & 1 != 0, flags & 2 != 0, flags & 4 != 0, flags & 8 != 0
		if b.has_lo {
			b.lo = bound_parse(r, p.col.kind)
		}
		if b.has_hi {
			b.hi = bound_parse(r, p.col.kind)
		}
	case .In:
		p.col = column_parse(r)
		p.set = make([]Bound, zsp.read_count(r))
		r.bad ||= p.col.kind == .Words
		for &b in p.set {
			b = bound_parse(r, p.col.kind)
		}
		slice.sort_by(p.set, proc(a, b: Bound) -> bool {return key_less(a.key, b.key)})
	case .Prefix, .Has:
		p.col = column_parse(r)
		p.bytes = compared(p.col.kind, zsp.read_bytes(r))
		if p.col.kind != .Bytes && p.col.kind != .Fold {
			r.bad = true
		}
	case .Exists:
		p.col = column_parse(r)
		r.bad ||= p.col.kind == .Words
	case .List:
		p.list = {zsp.read_u64(r), zsp.read_u64(r)}
	case .Match:
		p.col = column_parse(r)
		mode := zsp.read_u8(r)
		p.words.flags = Word_Flags(zsp.read_u8(r))
		text := zsp.read_bytes(r)
		if r.bad || p.col.kind != .Words || mode > u8(max(Word_Mode)) || len(text) > 4096 {
			r.bad = true
			return
		}
		p.words.mode = Word_Mode(mode)
		all := make([dynamic]Word)
		it := words(text)
		for w in words_next(&it) {
			append(&all, w)
		}
		p.words.words = all[:]
	case .Ids:
		n := zsp.read_count(r)
		if n > (len(r.buf) - r.pos) / 16 {
			r.bad = true
			return
		}
		p.ids = make([]zsp.Id, n)
		for &id in p.ids {
			id = {zsp.read_u64(r), zsp.read_u64(r)}
		}
		slice.sort_by(p.ids, id_less)
	case .Ref, .Back:
		p.col = column_parse(r)
		p.scope = scope_parse(r)
		if p.op == .Back {
			p.min, p.max = zsp.read_varint(r), zsp.read_varint(r)
		}
		p.kids = make([]Pred, 1)
		p.kids[0] = pred_parse(r, depth + 1, left)
		if p.col.kind != .Id {
			r.bad = true
		}
	}
	return
}

@(private)
id_less :: proc(a, b: zsp.Id) -> bool {
	return a[0] < b[0] || (a[0] == b[0] && a[1] < b[1])
}

// ---------------------------------------------------------------- straight from the cells

// What a value is to a predicate, judged by its key.
@(private)
Answer :: enum u8 {
	No,
	Yes,
	Perhaps, // the key does not say
}

// Whether a key is below, at or above a bound, as far as keys tell.
@(private)
bound_side :: proc(v: Value, b: ^Bound) -> (side: int, sure: bool) {
	if v.key != b.key {
		return -1 if key_less(v.key, b.key) else 1, true
	}
	switch {
	case v.rest == SEVERAL:
	case v.rest == 0 && b.rest == 0:
		return 0, true
	case v.rest == 0:
		return -1, true // it ends where the other goes on
	case b.rest == 0:
		return 1, true
	}
	return 0, false
}

@(private)
range_answer :: proc(b: ^Bounds, v: Value) -> Answer {
	perhaps := false
	if b.has_lo && b.has_hi && v.rest > SEVERAL && b.lo.value == b.hi.value && v.key == b.lo.key && v.rest != b.lo.rest {
		return .No
	}
	if b.has_lo {
		side, sure := bound_side(v, &b.lo)
		switch {
		case !sure:
			perhaps = true
		case side < 0 || (side == 0 && !b.lo_in):
			return .No
		}
	}
	if b.has_hi {
		side, sure := bound_side(v, &b.hi)
		switch {
		case !sure:
			perhaps = true
		case side > 0 || (side == 0 && !b.hi_in):
			return .No
		}
	}
	return .Perhaps if perhaps else .Yes
}

// The bytes of a row's values in a column, as compared. Temporary memory.
@(private)
row_bytes :: proc(r: ^Row, c: ^Column) -> [][]byte {
	Both :: struct {
		out:  [dynamic][]byte,
		kind: Kind,
	}
	b := Both{make([dynamic][]byte, context.temp_allocator), c.kind}
	raw, have := row_slot(r, c.slot)
	if !have {
		return nil
	}
	context.allocator = context.temp_allocator
	if c.path == "" {
		append(&b.out, compared(c.kind, raw))
	} else {
		json_each(raw, c.path, proc(data: rawptr, kind: Json, raw: []byte, _: ^Column) {
			if kind == .String {
				b := (^Both)(data)
				append(&b.out, compared(b.kind, json_unescape(raw)))
			}
		}, &b, nil)
	}
	return b.out[:]
}

// Judges a row by one predicate that says something of a value, reading what the key leaves open.
@(private)
leaf_cells :: proc(p: ^Pred, r: ^Row) -> bool {
	if p.op == .Match {
		return match_cells(p, r)
	}
	values := row_values(r, &p.col)
	if p.op == .Exists {
		return len(values) > 0
	}
	perhaps := false
	for v in values {
		switch leaf_answer(p, v) {
		case .Yes:
			return true
		case .Perhaps:
			perhaps = true
		case .No:
		}
	}
	if !perhaps {
		return false
	}
	for b in row_bytes(r, &p.col) {
		if leaf_bytes(p, b) {
			return true
		}
	}
	return false
}

@(private)
leaf_answer :: proc(p: ^Pred, v: Value) -> Answer {
	#partial switch p.op {
	case .Range:
		return range_answer(&p.range, v)
	case .In:
		lo, hi := 0, len(p.set)
		for lo < hi {
			mid := (lo + hi) / 2
			if key_less(p.set[mid].key, v.key) {
				lo = mid + 1
			} else {
				hi = mid
			}
		}
		answer := Answer.No
		for ; lo < len(p.set) && p.set[lo].key == v.key; lo += 1 {
			switch {
			case v.rest == 0 && p.set[lo].rest == 0:
				return .Yes
			case v.rest == p.set[lo].rest || v.rest == SEVERAL:
				answer = .Perhaps
			}
		}
		return answer
	case .Prefix:
		k: [16]byte
		zsp.put_u64(k[:], v.key.hi)
		zsp.put_u64(k[8:], v.key.lo)
		n := min(len(p.bytes), 16)
		if string(k[:n]) != string(p.bytes[:n]) {
			return .No
		}
		// Zeroes may be the value's, or only fill out the key.
		if v.rest == 0 {
			m := 16
			for m > 0 && k[m - 1] == 0 {
				m -= 1
			}
			return .Yes if m >= len(p.bytes) else .No
		}
		return .Perhaps if len(p.bytes) > 16 || (n > 0 && p.bytes[n - 1] == 0) else .Yes
	case .Has:
		if len(p.bytes) == 0 {
			return .Yes
		}
		if v.rest != 0 {
			return .Perhaps
		}
		k: [16]byte
		zsp.put_u64(k[:], v.key.hi)
		zsp.put_u64(k[8:], v.key.lo)
		n := 16
		for n > 0 && k[n - 1] == 0 {
			n -= 1
		}
		return .Yes if bytes.contains(k[:n], p.bytes) else .No
	case .Exists:
		return .Yes
	}
	return .No
}

@(private)
leaf_bytes :: proc(p: ^Pred, b: []byte) -> bool {
	#partial switch p.op {
	case .Range:
		if p.range.has_lo {
			lo := string(p.range.lo.bytes)
			if string(b) < lo || (string(b) == lo && !p.range.lo_in) {
				return false
			}
		}
		if p.range.has_hi {
			hi := string(p.range.hi.bytes)
			if string(b) > hi || (string(b) == hi && !p.range.hi_in) {
				return false
			}
		}
		return true
	case .In:
		for s in p.set {
			if string(s.bytes) == string(b) {
				return true
			}
		}
	case .Prefix:
		return len(b) >= len(p.bytes) && string(b[:len(p.bytes)]) == string(p.bytes)
	case .Has:
		return bytes.contains(b, p.bytes)
	}
	return false
}

// Whether a word of a text answers to one asked for.
@(private)
word_answers :: proc(w: ^Word_Query, i: int, text: []byte) -> bool {
	asked := &w.words[i]
	a := asked.bytes[:asked.len]
	if string(a) == string(text) {
		return true
	}
	if w.flags.prefix && i == len(w.words) - 1 && len(text) >= len(a) && string(text[:len(a)]) == string(a) {
		return true
	}
	if w.flags.inside && bytes.contains(text, a) {
		return true
	}
	if w.flags.edits > 0 {
		return within_edits(a, text, edits_allowed(w.flags.edits, len(a)))
	}
	return false
}

// Short words are not let be wrong as often: much would be taken for them.
@(private)
edits_allowed :: proc(asked: u8, length: int) -> int {
	return min(int(asked), 0 if length < 3 else 1 if length < 6 else 3)
}

@(private)
match_cells :: proc(p: ^Pred, r: ^Row) -> bool {
	w := &p.words
	if len(w.words) == 0 {
		return true
	}
	text: []byte
	if p.col.path == "" {
		have: bool
		text, have = row_slot(r, p.col.slot)
		if !have {
			return false
		}
	} else {
		raw, have := row_slot(r, p.col.slot)
		if !have {
			return false
		}
		all := make([dynamic]byte, context.temp_allocator)
		json_each(raw, p.col.path, proc(data: rawptr, kind: Json, raw: []byte, _: ^Column) {
			if kind == .String {
				all := (^[dynamic]byte)(data)
				append(all, ..json_unescape(raw))
				append(all, '\n')
			}
		}, &all, nil)
		text = all[:]
	}
	seen := make([]bool, len(w.words), context.temp_allocator)
	recent := make([]Word, len(w.words), context.temp_allocator) // the last so many words
	n := 0
	it := words(text)
	for word in words_next(&it) {
		word := word
		if w.mode == .Phrase {
			recent[n % len(recent)] = word
			n += 1
			if n < len(recent) {
				continue
			}
			all := true
			for i in 0 ..< len(recent) {
				x := &recent[(n + i) % len(recent)]
				all &&= word_answers(w, i, x.bytes[:x.len])
			}
			if all {
				return true
			}
			continue
		}
		for &s, i in seen {
			s ||= word_answers(w, i, word.bytes[:word.len])
			if s && w.mode == .Any {
				return true
			}
		}
	}
	if w.mode != .Every {
		return false
	}
	for s in seen {
		if !s {
			return false
		}
	}
	return true
}

// Whether one word becomes another by so many letters put in, left out, changed, or swapped with the next. Bytes
// of one letter count as one where the letters are ASCII.
@(private)
within_edits :: proc(a, b: []byte, k: int) -> bool {
	if abs(len(a) - len(b)) > k {
		return false
	}
	if k == 0 {
		return string(a) == string(b)
	}
	rows: [3][WORD_MAX + 1]int
	for j in 0 ..= len(b) {
		rows[0][j] = j
	}
	for i in 1 ..= len(a) {
		cur, up, up2 := &rows[i % 3], &rows[(i + 2) % 3], &rows[(i + 1) % 3]
		cur[0] = i
		least := i
		for j in 1 ..= len(b) {
			d := min(up[j] + 1, cur[j - 1] + 1, up[j - 1] + (0 if a[i - 1] == b[j - 1] else 1))
			if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
				d = min(d, up2[j - 2] + 1)
			}
			cur[j] = d
			least = min(least, d)
		}
		if least > k {
			return false
		}
	}
	return rows[len(a) % 3][len(b)] <= k
}

// Judges a row by everything, from the cells alone.
@(require_results)
pred_cells :: proc(p: ^Pred, r: ^Row) -> bool {
	switch p.op {
	case .All:
		return true
	case .And:
		for &k in p.kids {
			if !pred_cells(&k, r) {
				return false
			}
		}
		return true
	case .Or:
		for &k in p.kids {
			if pred_cells(&k, r) {
				return true
			}
		}
		return false
	case .Not:
		return !pred_cells(&p.kids[0], r)
	case .Range, .In, .Prefix, .Has, .Exists, .Match:
		return leaf_cells(p, r)
	case .List:
		places := zsp.row_places(&r.n.store, r.id)
		for k in places.keys[:places.count] {
			if zsp.key_list(k) == p.list {
				return true
			}
		}
		return false
	case .Ids:
		for id in p.ids {
			if id == r.id {
				return true
			}
		}
		return false
	case .Ref:
		for v in row_values(r, &p.col) {
			id := zsp.Id{v.key.hi, v.key.lo}
			if zsp.row_scope(id) == p.scope && id_there(r.n, id) {
				other := Row{n = r.n, x = r.x, id = id}
				if pred_cells(&p.kids[0], &other) {
					return true
				}
			}
		}
		return false
	case .Back:
		count: u64
		scan := zsp.tree_scan(&r.n.store, r.n.cells, {u64(p.scope) << 32, 0, 0, 0, 0}, {(u64(p.scope) + 1) << 32, 0, 0, 0, 0})
		last: zsp.Id
		for leaf in zsp.tree_next(&scan) {
			id := zsp.Id{leaf.key[0], leaf.key[1]}
			if id == last || !id_there(r.n, id) {
				continue
			}
			last = id
			other := Row{n = r.n, x = r.x, id = id}
			for v in row_values(&other, &p.col) {
				if v.key == {r.id[0], r.id[1]} && pred_cells(&p.kids[0], &other) {
					count += 1
					break
				}
			}
		}
		return count >= p.min && count <= p.max
	}
	return false
}

@(private)
id_there :: proc(n: ^zsp.Node, id: zsp.Id) -> bool {
	if _, dead := zsp.row_grave(&n.store, id); dead {
		return false
	}
	places := zsp.row_places(&n.store, id)
	return places.count > 0
}
