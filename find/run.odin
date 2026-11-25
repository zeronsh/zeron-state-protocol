package find

import "base:runtime"
import "core:bytes"
import "core:math"
import "core:slice"
import "../zsp"

// Answering from the index. How many rows each part of a question holds for is known before anything is read,
// exactly, so the part that leaves least is done first, and the rest are asked of what it leaves.

// Has the index keep whatever a question needs. Level with the store, please.
query_prepare :: proc(x: ^Index, q: ^Query) {
	pred_prepare(x, q.scope, &q.where_)
	for &s in q.order {
		if s.by == .Column && s.col.kind != .Created {
			s.held = index_want(x, q.scope, &s.col)
		}
	}
	for &a in q.totals {
		if a.col.kind != .Created {
			a.held = index_want(x, q.scope, &a.col)
		}
	}
	index_want_scope(x, q.scope)
}

// Says that a question is asking of its columns, or no longer is.
query_uses :: proc(q: ^Query, by: int) {
	preds :: proc(p: ^Pred, by: int) {
		if p.held != nil {
			p.held.uses += by
		}
		for &k in p.kids {
			preds(&k, by)
		}
	}
	preds(&q.where_, by)
	for o in q.order {
		if o.held != nil {
			o.held.uses += by
		}
	}
	for a in q.totals {
		if a.held != nil {
			a.held.uses += by
		}
	}
}

// Whether all that a question needs is whole.
@(require_results)
query_ready :: proc(x: ^Index, q: ^Query) -> bool {
	ready :: proc(x: ^Index, scope: zsp.Scope, p: ^Pred) -> bool {
		if s := index_scope(x, scope); s == nil || !s.built || (p.held != nil && !p.held.built) {
			return false
		}
		for &k in p.kids {
			ready(x, p.scope if p.op == .Ref || p.op == .Back else scope, &k) or_return
		}
		return true
	}
	ready(x, q.scope, &q.where_) or_return
	for o in q.order {
		if o.held != nil && !o.held.built {
			return false
		}
	}
	for a in q.totals {
		if a.held != nil && !a.held.built {
			return false
		}
	}
	return true
}

@(private)
pred_prepare :: proc(x: ^Index, scope: zsp.Scope, p: ^Pred) {
	switch p.op {
	case .All, .List, .Ids:
	case .And, .Or, .Not:
		for &k in p.kids {
			pred_prepare(x, scope, &k)
		}
	case .Range, .In, .Prefix, .Has, .Exists, .Match:
		if p.col.kind != .Created {
			p.held = index_want(x, scope, &p.col)
		}
	case .Ref:
		p.held = index_want(x, scope, &p.col)
		index_want_scope(x, p.scope)
		pred_prepare(x, p.scope, &p.kids[0])
	case .Back:
		index_want_scope(x, p.scope)
		p.held = index_want(x, p.scope, &p.col)
		pred_prepare(x, p.scope, &p.kids[0])
	}
}

// ---------------------------------------------------------------- how many

// A range of keys that has in it every value a predicate can hold for.
@(private)
leaf_span :: proc(p: ^Pred) -> (lo, hi: Key) {
	lo, hi = KEY_MIN, KEY_MAX
	#partial switch p.op {
	case .Range:
		if p.range.has_lo {
			lo = p.range.lo.key
		}
		if p.range.has_hi {
			hi = key_next(p.range.hi.key) if p.range.hi.key != KEY_MAX else KEY_MAX
		}
	case .In:
		if len(p.set) == 0 {
			return KEY_MAX, KEY_MIN
		}
		lo, hi = p.set[0].key, p.set[len(p.set) - 1].key
		hi = key_next(hi) if hi != KEY_MAX else KEY_MAX
	case .Prefix:
		b: [16]byte
		n := copy(b[:], p.bytes)
		lo = {zsp.get_u64(b[:]), zsp.get_u64(b[8:])}
		for i in n ..< 16 {
			b[i] = 0xff
		}
		hi = {zsp.get_u64(b[:]), zsp.get_u64(b[8:])}
		hi = key_next(hi) if hi != KEY_MAX else KEY_MAX
	}
	return
}

// Seconds as the keys of row ids.
@(private)
created_span :: proc(p: ^Pred) -> (lo, hi: Key) {
	to :: proc(k: Key) -> Key {
		v := key_number(k)
		if !(v > 0) {
			return KEY_MIN
		}
		return {u64(min(v, f64(max(u32)))) << 32, 0}
	}
	lo, hi = leaf_span(p)
	lo = to(lo) if lo != KEY_MIN else KEY_MIN
	if hi != KEY_MAX {
		k := to(hi)
		hi = {k.hi + 1 << 32, 0} if k.hi < u64(max(u32)) << 32 else KEY_MAX
	}
	return
}

// At most how many rows a predicate holds for.
@(private)
pred_most :: proc(s: ^Scope, p: ^Pred) -> int {
	x := s.x
	all := s.all.count
	switch p.op {
	case .All, .Not:
		return all
	case .And:
		least := all
		for &k in p.kids {
			least = min(least, pred_most(s, &k))
		}
		return least
	case .Or:
		sum := 0
		for &k in p.kids {
			sum += pred_most(s, &k)
		}
		return min(sum, all)
	case .Range, .Prefix, .Has, .Exists:
		if p.held == nil {
			lo, hi := created_span(p)
			return tree_between(x, s.ids, lo, hi).count
		}
		lo, hi := leaf_span(p)
		return min(all, tree_between(x, p.held.by_key, lo, hi).count)
	case .In:
		if p.held == nil {
			return all
		}
		sum := 0
		for b in p.set {
			sum += tree_between(x, p.held.by_key, b.key, key_next(b.key) if b.key != KEY_MAX else KEY_MAX).count
		}
		return min(sum, all)
	case .List:
		return min(all, zsp.store_range(&x.n.store, zsp.list_lo(p.list), zsp.list_hi(p.list)).count)
	case .Match:
		w := &p.words
		if len(w.words) == 0 {
			return all
		}
		least, sum := all, 0
		for &word, i in w.words {
			n := all
			if word_plain(w, i) {
				k, _ := bytes_key(word.bytes[:word.len])
				n = tree_between(x, p.held.by_key, k, key_next(k)).count
			} else if w.flags.prefix && w.flags.edits == 0 && !w.flags.inside {
				lo, hi := word_span(&word)
				n = tree_between(x, p.held.by_key, lo, hi).count
			}
			least = min(least, n)
			sum += n
		}
		return least if w.mode != .Any else min(all, sum)
	case .Ids:
		return len(p.ids)
	case .Ref, .Back:
		return all
	}
	return all
}

// A word asked for just as it is.
@(private)
word_plain :: proc(w: ^Word_Query, i: int) -> bool {
	f := w.flags
	return !f.inside && !(f.prefix && i == len(w.words) - 1) && edits_allowed(f.edits, w.words[i].len) == 0
}

@(private)
word_span :: proc(w: ^Word) -> (lo, hi: Key) {
	p := Pred{op = .Prefix, bytes = w.bytes[:w.len]}
	return leaf_span(&p)
}

// ---------------------------------------------------------------- which

// The rows a predicate holds for.
@(require_results)
pred_rows :: proc(s: ^Scope, p: ^Pred) -> (out: Set) {
	x := s.x
	switch p.op {
	case .All:
		return set_clone(&s.all)
	case .Not:
		out = set_clone(&s.all)
		not := pred_rows(s, &p.kids[0])
		defer set_destroy(&not)
		set_and_not(&out, &not)
	case .Or:
		for &k in p.kids {
			some := pred_rows(s, &k)
			defer set_destroy(&some)
			set_or(&out, &some)
		}
	case .And:
		if len(p.kids) == 0 {
			return set_clone(&s.all)
		}
		Part :: struct {
			p:    ^Pred,
			most: int,
			not:  bool,
		}
		parts := make([]Part, len(p.kids), context.temp_allocator)
		for &k, i in p.kids {
			if k.op == .Not {
				parts[i] = {&k.kids[0], max(int), true}
			} else {
				parts[i] = {&k, pred_most(s, &k), false}
			}
		}
		slice.sort_by(parts, proc(a, b: Part) -> bool {return a.most < b.most})
		rest := parts
		if parts[0].not {
			out = set_clone(&s.all)
		} else {
			out = pred_rows(s, parts[0].p)
			rest = parts[1:]
		}
		for part in rest {
			if out.count == 0 {
				return
			}
			most := part.most if !part.not else pred_most(s, part.p)
			// To ask it of each row that is left, or to find all that it holds for?
			if most / ASK_COST > out.count {
				gone: [dynamic]u32
				defer delete(gone)
				it := set_iterator(&out)
				for row in set_next(&it) {
					runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
					if pred_holds(s, part.p, row) == part.not {
						append(&gone, row)
					}
				}
				for row in gone {
					set_remove(&out, row)
				}
				continue
			}
			other := pred_rows(s, part.p)
			defer set_destroy(&other)
			if part.not {
				set_and_not(&out, &other)
			} else {
				set_and(&out, &other)
			}
		}
	case .Range, .Prefix, .Has, .Exists, .In:
		return leaf_rows(s, p)
	case .Match:
		return match_rows(s, p)
	case .List:
		scan := zsp.tree_scan(&x.n.store, x.n.shelf, zsp.list_lo(p.list), zsp.list_hi(p.list))
		for leaf in zsp.tree_next(&scan) {
			if row, ok := row_number(s, zsp.key_row(leaf.key)); ok {
				set_add(&out, row)
			}
		}
	case .Ids:
		for id in p.ids {
			if row, ok := row_number(s, id); ok {
				set_add(&out, row)
			}
		}
	case .Ref:
		other := index_scope(x, p.scope)
		some := pred_rows(other, &p.kids[0])
		defer set_destroy(&some)
		it := set_iterator(&some)
		if some.count * ASK_COST < tree_total(x, p.held.by_key).count {
			for row in set_next(&it) {
				id, _ := row_id(other, row)
				key := Key{id[0], id[1]}
				tree_subs(x, p.held.by_key, key, key_next(key), &out)
			}
			return
		}
		c := cursor_make(x, p.held.by_key, context.allocator)
		defer cursor_destroy(&c)
		cursor_seek(&c, KEY_MIN)
		last: Key
		holds := false
		for e in cursor_next(&c) {
			if e.key != last {
				last = e.key
				row, ok := row_number(other, {e.key.hi, e.key.lo})
				holds = ok && set_has(&some, row)
			}
			if holds {
				set_add(&out, e.sub)
			}
		}
	case .Back:
		other := index_scope(x, p.scope)
		some := pred_rows(other, &p.kids[0])
		defer set_destroy(&some)
		// Those referring lie together, by whom they refer to.
		c := cursor_make(x, p.held.by_key, context.allocator)
		defer cursor_destroy(&c)
		cursor_seek(&c, {u64(s.id) << 32, 0})
		if p.min == 0 {
			out = set_clone(&s.all)
		}
		settle :: proc(s: ^Scope, p: ^Pred, out: ^Set, key: Key, count: u64) {
			if count == 0 {
				return
			}
			if row, ok := row_number(s, {key.hi, key.lo}); ok {
				if count >= p.min && count <= p.max {
					set_add(out, row)
				} else {
					set_remove(out, row)
				}
			}
		}
		last: Key
		count: u64
		for e in cursor_next(&c) {
			if e.key.hi >> 32 != u64(s.id) {
				break
			}
			if e.key != last {
				settle(s, p, &out, last, count)
				last, count = e.key, 0
			}
			count += 1 if set_has(&some, e.sub) else 0
		}
		settle(s, p, &out, last, count)
	}
	return
}

// Asking a row a question from the index costs about as much as reading so many entries in a row.
@(private)
ASK_COST :: #config(ZSP_FIND_ASK, 64)

@(private)
Gather :: struct {
	s:       ^Scope,
	p:       ^Pred,
	out:     Set,
	perhaps: [dynamic]u32,
}

@(private)
leaf_rows :: proc(s: ^Scope, p: ^Pred) -> Set {
	x := s.x
	if p.held == nil {
		// The time a row was made is in its id.
		g := Gather{s = s, p = p}
		lo, hi := created_span(p)
		tree_each(x, s.ids, lo, hi, &g, proc(data: rawptr, e: ^Entry) {
			g := (^Gather)(data)
			if leaf_answer(g.p, {key = number_key(f64(e.key.hi >> 32))}) == .Yes {
				set_add(&g.out, e.sub)
			}
		})
		return g.out
	}
	g := Gather{s = s, p = p}
	defer delete(g.perhaps)
	each :: proc(data: rawptr, e: ^Entry) {
		g := (^Gather)(data)
		switch leaf_answer(g.p, {e.key, e.val != 0}) {
		case .Yes:
			set_add(&g.out, e.sub)
		case .Perhaps:
			append(&g.perhaps, e.sub)
		case .No:
		}
	}
	if p.op == .In {
		for b, i in p.set {
			if i == 0 || p.set[i - 1].key != b.key {
				tree_each(x, p.held.by_key, b.key, key_next(b.key) if b.key != KEY_MAX else KEY_MAX, &g, each)
			}
		}
	} else {
		lo, hi := leaf_span(p)
		if p.op == .Range || p.op == .Exists {
			// Only what lies at a bound needs judging; all that lies between holds.
			inner_lo, inner_hi := lo, hi
			if p.range.has_lo && lo != KEY_MAX {
				inner_lo = key_next(lo)
				tree_each(x, p.held.by_key, lo, inner_lo, &g, each)
			}
			if p.range.has_hi && hi != KEY_MAX {
				inner_hi = p.range.hi.key
				if !key_less(inner_hi, inner_lo) {
					tree_each(x, p.held.by_key, inner_hi, hi, &g, each)
				}
			}
			if key_less(inner_lo, inner_hi) && !(p.range.has_lo && lo == KEY_MAX) {
				tree_subs(x, p.held.by_key, inner_lo, inner_hi, &g.out)
			}
		} else {
			tree_each(x, p.held.by_key, lo, hi, &g, each)
		}
	}
	for row in g.perhaps {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		if !set_has(&g.out, row) && row_cells(s, p, row) {
			set_add(&g.out, row)
		}
	}
	return g.out
}

// What the cells themselves say.
@(private)
row_cells :: proc(s: ^Scope, p: ^Pred, row: u32) -> bool {
	id, ok := row_id(s, row)
	r := Row{n = s.x.n, id = id}
	return ok && leaf_cells(p, &r)
}

// Whether a predicate holds for one row. Temporary memory.
@(require_results)
pred_holds :: proc(s: ^Scope, p: ^Pred, row: u32) -> bool {
	x := s.x
	switch p.op {
	case .All:
		return true
	case .And:
		for &k in p.kids {
			if !pred_holds(s, &k, row) {
				return false
			}
		}
		return true
	case .Or:
		for &k in p.kids {
			if pred_holds(s, &k, row) {
				return true
			}
		}
		return false
	case .Not:
		return !pred_holds(s, &p.kids[0], row)
	case .Range, .In, .Prefix, .Has, .Exists:
		if p.held == nil {
			return row_cells(s, p, row)
		}
		perhaps := false
		for v in held_values(p.held, row) {
			switch leaf_answer(p, v) {
			case .Yes:
				return true
			case .Perhaps:
				perhaps = true
			case .No:
			}
		}
		return perhaps && row_cells(s, p, row)
	case .Match:
		return match_holds(s, p, row)
	case .List:
		id, ok := row_id(s, row)
		if !ok {
			return false
		}
		places := zsp.row_places(&x.n.store, id)
		for k in places.keys[:places.count] {
			if zsp.key_list(k) == p.list {
				return true
			}
		}
		return false
	case .Ids:
		id, ok := row_id(s, row)
		if !ok {
			return false
		}
		_, found := slice.binary_search_by(p.ids, id, proc(a, b: zsp.Id) -> slice.Ordering {
			return .Less if id_less(a, b) else .Greater if id_less(b, a) else .Equal
		})
		return found
	case .Ref:
		other := index_scope(x, p.scope)
		for v in held_values(p.held, row) {
			if to, ok := row_number(other, {v.key.hi, v.key.lo}); ok && pred_holds(other, &p.kids[0], to) {
				return true
			}
		}
		return false
	case .Back:
		other := index_scope(x, p.scope)
		id, ok := row_id(s, row)
		if !ok {
			return false
		}
		key := Key{id[0], id[1]}
		c := cursor_make(x, p.held.by_key)
		defer cursor_destroy(&c)
		cursor_seek(&c, key)
		count: u64
		for e in cursor_next(&c) {
			if e.key != key {
				break
			}
			count += 1 if pred_holds(other, &p.kids[0], e.sub) else 0
			if count > p.max {
				return false
			}
		}
		return count >= p.min
	}
	return false
}

// ---------------------------------------------------------------- words

// The keys of the lexicon that a word asked for may be. Temporary memory.
@(private)
word_keys :: proc(h: ^Held, w: ^Word_Query, i: int) -> []Key {
	out := make([dynamic]Key, context.temp_allocator)
	asked := &w.words[i]
	k, _ := bytes_key(asked.bytes[:asked.len])
	if word_plain(w, i) {
		append(&out, k)
		return out[:]
	}
	Look :: struct {
		w:   ^Word_Query,
		i:   int,
		out: ^[dynamic]Key,
	}
	look := Look{w, i, &out}
	lo, hi := KEY_MIN, KEY_MAX
	if !w.flags.inside && edits_allowed(w.flags.edits, asked.len) == 0 {
		lo, hi = word_span(asked)
	}
	tree_each(h.scope.x, h.lexicon, lo, hi, &look, proc(data: rawptr, e: ^Entry) {
		l := (^Look)(data)
		b: [16]byte = ---
		zsp.put_u64(b[:], e.key.hi)
		zsp.put_u64(b[8:], e.key.lo)
		n := 16
		for n > 0 && b[n - 1] == 0 {
			n -= 1
		}
		// A word that fills its key may go on: whether it answers is then for the text to say.
		if n == 16 || word_answers(l.w, l.i, b[:n]) {
			append(l.out, e.key)
		}
	})
	return out[:]
}

// Whether what postings say of a word is all there is to it.
@(private)
word_sure :: proc(h: ^Held, w: ^Word_Query, i: int, keys: []Key) -> bool {
	asked := &w.words[i]
	if asked.len >= 16 {
		return false
	}
	for k in keys {
		if k.lo & 0xff != 0 {
			return false
		}
	}
	return true
}

// Texts that have any of these words. `sums` gathers what each makes a text worth.
@(private)
word_texts :: proc(h: ^Held, keys: []Key) -> Set {
	out: Set
	for k in keys {
		tree_subs(h.scope.x, h.by_key, k, key_next(k), &out)
	}
	return out
}

@(private)
match_texts :: proc(s: ^Scope, p: ^Pred) -> (out: Set, sure: bool) {
	h, w := p.held, &p.words
	sure = w.mode != .Phrase
	order := make([]int, len(w.words), context.temp_allocator)
	for &o, i in order {
		o = i
	}
	keys := make([][]Key, len(w.words), context.temp_allocator)
	counts := make([]int, len(w.words), context.temp_allocator)
	for i in 0 ..< len(w.words) {
		keys[i] = word_keys(h, w, i)
		for k in keys[i] {
			counts[i] += tree_between(s.x, h.by_key, k, key_next(k)).count
		}
		sure &&= word_sure(h, w, i, keys[i])
	}
	for i in 1 ..< len(order) {
		for j := i; j > 0 && counts[order[j]] < counts[order[j - 1]]; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	for i, n in order {
		if n == 0 || w.mode == .Any {
			some := word_texts(h, keys[i])
			if n == 0 {
				out = some
			} else {
				set_or(&out, &some)
				set_destroy(&some)
			}
			continue
		}
		if out.count == 0 {
			return
		}
		if counts[i] / ASK_COST > out.count && len(keys[i]) == 1 {
			gone: [dynamic]u32
			defer delete(gone)
			it := set_iterator(&out)
			for text in set_next(&it) {
				if _, has := tree_get(s.x, h.by_key, keys[i][0], text); !has {
					append(&gone, text)
				}
			}
			for text in gone {
				set_remove(&out, text)
			}
			continue
		}
		some := word_texts(h, keys[i])
		set_and(&out, &some)
		set_destroy(&some)
	}
	return
}

@(private)
match_rows :: proc(s: ^Scope, p: ^Pred) -> (out: Set) {
	if len(p.words.words) == 0 {
		return set_clone(&s.all)
	}
	texts, sure := match_texts(s, p)
	defer set_destroy(&texts)
	array_rows(s.x, p.held.texts, &texts, &out)
	if !sure {
		gone: [dynamic]u32
		defer delete(gone)
		it := set_iterator(&out)
		for row in set_next(&it) {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			if !row_cells(s, p, row) {
				append(&gone, row)
			}
		}
		for row in gone {
			set_remove(&out, row)
		}
	}
	return
}

@(private)
match_holds :: proc(s: ^Scope, p: ^Pred, row: u32) -> bool {
	w, h := &p.words, p.held
	if len(w.words) == 0 {
		return true
	}
	plain := w.mode != .Phrase
	for &word, i in w.words {
		plain &&= word_plain(w, i) && word.len < 16
	}
	if !plain {
		return row_cells(s, p, row)
	}
	text, ok := held_text(h, row)
	if !ok {
		return false
	}
	for &word in w.words {
		k, _ := bytes_key(word.bytes[:word.len])
		_, has := tree_get(s.x, h.by_key, k, text)
		if has == (w.mode == .Any) {
			return has
		}
	}
	return w.mode != .Any
}

// ---------------------------------------------------------------- how well

// Every Match that counts towards how well a row answers.
@(private)
pred_matches :: proc(p: ^Pred, out: ^[dynamic]^Pred) {
	#partial switch p.op {
	case .Match:
		append(out, p)
	case .And, .Or:
		for &k in p.kids {
			pred_matches(&k, out)
		}
	}
}

// How well rows answer (BM25): words count for more the rarer they are and the shorter the text, and for less
// the more often they are said.
@(private)
rows_scores :: proc(s: ^Scope, q: ^Query, rows: ^Set, scores: ^map[u32]f32) {
	matches := make([dynamic]^Pred, context.temp_allocator)
	pred_matches(&q.where_, &matches)
	for p in matches {
		h := p.held
		docs := f64(max(h.alive, 1))
		mean := max(f64(h.length) / docs, 1)
		keys := make([dynamic]Key, context.temp_allocator)
		postings := 0
		for i in 0 ..< len(p.words.words) {
			for k in word_keys(h, &p.words, i) {
				append(&keys, k)
				postings += tree_between(s.x, h.by_key, k, key_next(k)).count
			}
		}
		// A word asked for twice counts twice; one that answers two ways, once for each.
		one := rows.count * len(keys) * 8 < postings
		texts := make(map[u32]Scored)
		defer delete(texts)
		it := set_iterator(rows)
		for row in set_next(&it) {
			if text, ok := held_text(h, row); ok {
				t, _ := text_entry(h, text)
				texts[text] = {row, f32(0.25 + 0.75 * f64(t.length) / mean), 0}
			}
		}
		for k in keys {
			have := f64(tree_between(s.x, h.by_key, k, key_next(k)).count)
			rarity := f32(math.ln(1 + (docs - min(have, docs) + 0.5) / (have + 0.5)))
			if one {
				for text, &t in texts {
					if often, says := tree_get(s.x, h.by_key, k, text); says {
						t.worth += rarity * worth(often, t.size)
					}
				}
				continue
			}
			Add :: struct {
				texts:  ^map[u32]Scored,
				rarity: f32,
			}
			a := Add{&texts, rarity}
			tree_each(s.x, h.by_key, k, key_next(k), &a, proc(data: rawptr, e: ^Entry) {
				a := (^Add)(data)
				if t := &a.texts[e.sub]; t != nil {
					t.worth += a.rarity * worth(e.val, t.size)
				}
			})
		}
		for _, t in texts {
			if t.worth > 0 {
				scores[t.row] += t.worth
			}
		}
	}
}

@(private)
Scored :: struct {
	row:   u32,
	size:  f32, // how long the text is, against the others
	worth: f32,
}

@(private)
worth :: proc(often: u64, size: f32) -> f32 {
	n := f32(often)
	return n * 2.2 / (n + 1.2 * size)
}

// ---------------------------------------------------------------- in what order

Hit :: struct {
	row:   u32,
	id:    zsp.Id,
	score: f32,
}


// What a row is ordered by: its first value that way, or that it has none, which is last either way.
@(private)
Sort_Key :: struct {
	key:  Key,
	long: bool,
	none: bool,
}

@(private)
Sorted :: struct {
	hit:  Hit,
	keys: []Sort_Key,
}

@(private)
sort_keys :: proc(s: ^Scope, q: ^Query, hit: ^Hit) -> []Sort_Key {
	keys := make([]Sort_Key, len(q.order), context.temp_allocator)
	for &o, i in q.order {
		if o.by != .Column || o.held == nil {
			continue
		}
		values := held_values(o.held, hit.row)
		if len(values) == 0 {
			keys[i].none = true
			continue
		}
		v := values[len(values) - 1] if o.desc else values[0]
		keys[i] = {v.key, v.long, false}
	}
	return keys
}

// Less than zero when `a` comes first. Made in the same breath, the earlier id comes first, unless it is asked
// otherwise.
@(private)
sorted_compare :: proc(s: ^Scope, q: ^Query, a, b: ^Sorted) -> int {
	for &o, i in q.order {
		c := 0
		switch {
		case o.by == .Relevance:
			c = -1 if a.hit.score > b.hit.score else 1 if a.hit.score < b.hit.score else 0
			if o.desc {
				c = -c
			}
			if c != 0 {
				return c
			}
			continue
		case o.by == .Created || o.held == nil:
			c = -1 if id_less(a.hit.id, b.hit.id) else 1 if id_less(b.hit.id, a.hit.id) else 0
		case:
			ka, kb := a.keys[i], b.keys[i]
			if ka.none || kb.none {
				if ka.none != kb.none {
					return 1 if ka.none else -1
				}
				continue
			}
			switch {
			case ka.key != kb.key:
				c = -1 if key_less(ka.key, kb.key) else 1
			case ka.long || kb.long:
				c = long_compare(s, &o, a.hit.id, b.hit.id)
			}
		}
		if c != 0 {
			return -c if o.desc else c
		}
	}
	return -1 if id_less(a.hit.id, b.hit.id) else 1 if id_less(b.hit.id, a.hit.id) else 0
}

// Values whose keys are alike, in full.
@(private)
long_compare :: proc(s: ^Scope, o: ^Sort, a, b: zsp.Id) -> int {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	best :: proc(s: ^Scope, o: ^Sort, id: zsp.Id) -> (out: []byte) {
		r := Row{n = s.x.n, id = id}
		for v, i in row_bytes(&r, &o.col) {
			if i == 0 || (bytes.compare(v, out) < 0) != o.desc {
				out = v
			}
		}
		return
	}
	return bytes.compare(best(s, o, a), best(s, o, b))
}

@(private)
Ranker :: struct {
	s: ^Scope,
	q: ^Query,
}

@(private)
rank :: proc(s: ^Scope, q: ^Query, all: []Sorted) {
	ranker := Ranker{s, q}
	context.user_ptr = &ranker
	slice.sort_by(all, proc(a, b: Sorted) -> bool {
		r := (^Ranker)(context.user_ptr)
		a, b := a, b
		return sorted_compare(r.s, r.q, &a, &b) < 0
	})
}

// So few rows are best put in order.
@(private)
WALK :: #config(ZSP_FIND_WALK, 64)

// A stretch of the rows, in order. Temporary memory.
@(require_results)
query_page :: proc(s: ^Scope, q: ^Query, rows: ^Set) -> []Hit {
	out := make([dynamic]Hit, context.temp_allocator)
	first := q.offset
	if q.from_end {
		first = max(rows.count - q.offset - q.limit, 0)
	}
	count := min(q.limit, max(rows.count - first, 0))
	if q.from_end {
		count = min(q.limit, max(rows.count - q.offset, 0))
	}
	if count <= 0 {
		return nil
	}
	// From whichever end is nearer.
	backward := first + count / 2 > rows.count / 2
	skip := rows.count - first - count if backward else first

	relevance := false
	for o in q.order {
		relevance ||= o.by == .Relevance
	}
	scores := make(map[u32]f32)
	defer delete(scores)
	if relevance {
		rows_scores(s, q, rows, &scores)
	}

	lead := q.order[0] if len(q.order) > 0 else Sort{by = .Created}
	// Looking for them in order reads all that lies between; having them all reads each.
	between := (skip + count) * s.all.count / max(rows.count, 1)
	walk := !relevance && rows.count > WALK && between / ASK_COST < rows.count
	if !walk {
		// All of them, put in order.
		all := make([]Sorted, rows.count, context.temp_allocator)
		n := 0
		it := set_iterator(rows)
		for row in set_next(&it) {
			id, _ := row_id(s, row)
			all[n].hit = {row, id, scores[row]}
			all[n].keys = sort_keys(s, q, &all[n].hit)
			n += 1
		}
		rank(s, q, all)
		for x in all[first:][:count] {
			append(&out, x.hit)
		}
		return out[:]
	}

	if lead.by == .Created || lead.held == nil {
		// Ids are in that order already, and no two are alike.
		desc := lead.desc != backward
		c := cursor_make(s.x, s.ids, context.allocator)
		defer cursor_destroy(&c)
		cursor_seek(&c, KEY_MAX if desc else KEY_MIN, max(u32) if desc else 0)
		for len(out) < count {
			e := cursor_prev(&c) or_break if desc else cursor_next(&c) or_break
			if !set_has(rows, e.sub) {
				continue
			}
			if skip > 0 {
				skip -= 1
				continue
			}
			append(&out, Hit{e.sub, {u64(s.id) << 32 | e.key.hi >> 32, e.key.hi << 32 | e.key.lo >> 32}, 0})
		}
		if backward {
			slice.reverse(out[:])
		}
		return out[:]
	}

	// By the first thing it is ordered by, a group of equals at a time; those without it are last.
	h := lead.held
	desc := lead.desc != backward
	many := false // a row may come up more than once
	seen: Set
	defer set_destroy(&seen)
	many = h.path != "" || h.kind == .Order
	group := make([dynamic]Sorted)
	defer delete(group)

	without :: proc(s: ^Scope, q: ^Query, h: ^Held, rows: ^Set, group: ^[dynamic]Sorted) {
		none := set_clone(rows)
		defer set_destroy(&none)
		tree_each(s.x, h.by_row, KEY_MIN, KEY_MAX, &none, proc(data: rawptr, e: ^Entry) {
			set_remove((^Set)(data), u32(e.key.hi >> 32))
		})
		it := set_iterator(&none)
		for row in set_next(&it) {
			id, _ := row_id(s, row)
			append(group, Sorted{hit = {row, id, 0}})
		}
	}
	take :: proc(s: ^Scope, q: ^Query, group: ^[dynamic]Sorted, out: ^[dynamic]Hit, skip: ^int, count: int, backward: bool) {
		defer clear(group)
		if skip^ >= len(group) {
			skip^ -= len(group)
			return
		}
		if len(group) > 1 {
			for &g in group {
				if g.hit.id == {} {
					g.hit.id, _ = row_id(s, g.hit.row)
				}
				g.keys = sort_keys(s, q, &g.hit)
			}
			rank(s, q, group[:])
			if backward {
				slice.reverse(group[:])
			}
		}
		for &g in group[skip^:] {
			if len(out) == count {
				break
			}
			if g.hit.id == {} {
				g.hit.id, _ = row_id(s, g.hit.row)
			}
			append(out, g.hit)
		}
		skip^ = 0
	}

	if backward {
		without(s, q, h, rows, &group)
		take(s, q, &group, &out, &skip, count, backward)
	}
	if many && backward {
		// Where a row has several values the one it is ordered by comes last this way: have it the plain way.
		clear(&out)
		return query_all(s, q, rows, first, count)
	}
	c := cursor_make(s.x, h.by_key, context.allocator)
	defer cursor_destroy(&c)
	cursor_seek(&c, KEY_MAX if desc else KEY_MIN, max(u32) if desc else 0)
	last: Key
	for len(out) < count {
		e := cursor_prev(&c) or_break if desc else cursor_next(&c) or_break
		if !set_has(rows, e.sub) || (many && !set_add(&seen, e.sub)) {
			continue
		}
		if len(group) > 0 && e.key != last {
			take(s, q, &group, &out, &skip, count, backward)
		}
		last = e.key
		append(&group, Sorted{hit = {row = e.sub}})
	}
	if len(out) < count {
		take(s, q, &group, &out, &skip, count, backward)
	}
	if len(out) < count && !backward {
		without(s, q, h, rows, &group)
		take(s, q, &group, &out, &skip, count, backward)
	}
	if backward {
		slice.reverse(out[:])
	}
	return out[:]
}

@(private)
query_all :: proc(s: ^Scope, q: ^Query, rows: ^Set, first, count: int) -> []Hit {
	all := make([]Sorted, rows.count, context.temp_allocator)
	n := 0
	it := set_iterator(rows)
	for row in set_next(&it) {
		id, _ := row_id(s, row)
		all[n].hit = {row, id, 0}
		all[n].keys = sort_keys(s, q, &all[n].hit)
		n += 1
	}
	rank(s, q, all)
	out := make([]Hit, count, context.temp_allocator)
	for x, i in all[first:][:count] {
		out[i] = x.hit
	}
	return out
}

// ---------------------------------------------------------------- what they come to

Facet :: struct {
	key:   Key,
	count: int,
	row:   u32, // one that has it, should the key not be all of it
}

Sum_Of :: struct {
	number: f64, // or how many
	some:   bool,
	facets: []Facet,
}

// Temporary memory.
@(require_results)
query_totals :: proc(s: ^Scope, q: ^Query, rows: ^Set) -> []Sum_Of {
	out := make([]Sum_Of, len(q.totals), context.temp_allocator)
	for &a, i in q.totals {
		out[i] = aggregate(s, &a, rows)
	}
	return out
}

@(private)
aggregate :: proc(s: ^Scope, a: ^Aggregate, rows: ^Set) -> (out: Sum_Of) {
	x := s.x
	if a.held == nil {
		// When rows were made: every row has it once, and ids are in its order.
		out.some = rows.count > 0
		#partial switch a.fn {
		case .Count:
			out.number = f64(rows.count)
		case .Min, .Max:
			c := cursor_make(x, s.ids)
			defer cursor_destroy(&c)
			most := a.fn == .Max
			cursor_seek(&c, KEY_MAX if most else KEY_MIN, max(u32) if most else 0)
			for {
				e := cursor_prev(&c) or_break if most else cursor_next(&c) or_break
				if set_has(rows, e.sub) {
					out.number = f64(e.key.hi >> 32)
					break
				}
			}
		}
		return
	}
	h := a.held
	every := rows.count == s.all.count
	switch a.fn {
	case .Sum:
		if every {
			t := tree_total(x, h.by_key)
			return {t.sum, t.count > 0, nil}
		}
		Add :: struct {
			rows: ^Set,
			sum:  f64,
			some: bool,
		}
		add := Add{rows = rows}
		if rows.count * ASK_COST < tree_total(x, h.by_row).count {
			it := set_iterator(rows)
			for row in set_next(&it) {
				runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
				for v in held_values(h, row) {
					add.sum += key_number(v.key)
					add.some = true
				}
			}
		} else {
			tree_each(x, h.by_key, KEY_MIN, KEY_MAX, &add, proc(data: rawptr, e: ^Entry) {
				add := (^Add)(data)
				if set_has(add.rows, e.sub) {
					add.sum += key_number(e.key)
					add.some = true
				}
			})
		}
		return {add.sum, add.some, nil}
	case .Min, .Max:
		c := cursor_make(x, h.by_key)
		defer cursor_destroy(&c)
		most := a.fn == .Max
		cursor_seek(&c, KEY_MAX if most else KEY_MIN, max(u32) if most else 0)
		for {
			e := cursor_prev(&c) or_break if most else cursor_next(&c) or_break
			if set_has(rows, e.sub) {
				out.facets = make([]Facet, 1, context.temp_allocator)
				out.facets[0] = {e.key, 1, e.sub}
				out.number, out.some = key_number(e.key), true
				return
			}
		}
	case .Count:
		have: Set
		defer set_destroy(&have)
		Both :: struct {
			rows, have: ^Set,
		}
		b := Both{rows, &have}
		tree_each(x, h.by_row, KEY_MIN, KEY_MAX, &b, proc(data: rawptr, e: ^Entry) {
			b := (^Both)(data)
			if row := u32(e.key.hi >> 32); set_has(b.rows, row) {
				set_add(b.have, row)
			}
		})
		return {f64(have.count), have.count > 0, nil}
	case .Facet:
		Tally :: struct {
			rows: ^Set,
			top:  int,
			best: [dynamic]Facet,
			now:  Facet,
			kinds: int,
		}
		t := Tally{rows = rows, top = a.top, best = make([dynamic]Facet, context.temp_allocator)}
		settle :: proc(t: ^Tally) {
			if t.now.count == 0 {
				return
			}
			t.kinds += 1
			at := len(t.best)
			for at > 0 && t.best[at - 1].count < t.now.count {
				at -= 1
			}
			if at < t.top {
				inject_at(&t.best, at, t.now)
				if len(t.best) > t.top {
					pop(&t.best)
				}
			}
			t.now = {}
		}
		tree_each(x, h.by_key, KEY_MIN, KEY_MAX, &t, proc(data: rawptr, e: ^Entry) {
			t := (^Tally)(data)
			if t.now.count > 0 && t.now.key != e.key {
				settle(t)
			}
			if set_has(t.rows, e.sub) {
				if t.now.count == 0 {
					t.now.key, t.now.row = e.key, e.sub
				}
				t.now.count += 1
			}
		})
		settle(&t)
		return {f64(t.kinds), t.kinds > 0, t.best[:]}
	}
	return
}
