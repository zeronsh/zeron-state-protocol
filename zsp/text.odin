package zsp

import "core:slice"

// A collaborative text column: a sequence CRDT over UTF-8 bytes.
//
// A piece is an append-only stream of operations by one writer. Because it only ever grows, a piece
// still being written can be streamed as suffixes (live frames) and integrated as they arrive; when it
// is sealed into a cell, whatever was already integrated is skipped. A text is a pure function of the
// set of pieces in its slot, plus at most one Value beneath them.
//
// Placement is Fugue's: every element hangs in a tree, by nothing but what its own operation says, and the text is
// the tree read in order. So concurrent runs never interleave, and whatever anyone says of neighbours, the text is
// the same for everyone who has the same pieces.

Ref :: struct {
	piece:  u64, // zero for the edge of the document
	offset: u32,
}

@(private)
NO_REF :: Ref{}

@(private)
Op :: enum u8 {
	Insert = 1, // left, right, bytes
	Extend = 2, // bytes, continuing this piece's last insertion
	Delete = 3, // first, count
}

// An element, by its piece's number. Number zero is the edge of the document.
@(private)
Spot :: struct {
	piece:  u32,
	offset: u32,
}

@(private)
Mark :: enum u32 {
	Dead,
	New, // since changes began to be followed,
	Killed, // and so
}

// A run of elements of one piece, one after another both there and in the document.
@(private)
Span :: struct {
	using id: Spot, // of its first byte; the rest follow
	len:   u32,
	at:    u32, // in Text.data
	run:   u32, // that it is of
	block: ^Block, // where it is in the document
	marks: bit_set[Mark;u32],
}

// Elements made at once: the first hangs beneath what its operation says, and each of the rest beneath the one before,
// on its right. The start of the document is the root, at depth 0.
@(private)
Run :: struct {
	using id: Spot, // of its first element
	parent: Spot, // of the first
	right:  bool, // the side of it the first hangs on
	depth:  u32, // of the first
	hops:   u32, // runs between it and the root, and one
	up:     u32, // the run that holds its parent; NONE for the root
	jump:   u32, // a run further up, so that any ancestor is a few steps away; NONE for the root
}

// Some of the spans, in document order, dead ones included.
@(private)
Block :: struct {
	at:      int, // among the blocks
	visible: int, // bytes
	count:   int,
	items:   [BLOCK]u32,
}
@(private)
BLOCK :: 64

// No span; as a place in the document, its end.
@(private)
NONE :: max(u32)

Text :: struct {
	data:    [dynamic]byte,
	spans:   [dynamic]Span, // by number, as they came to be; each a run, or part of one
	runs:    [dynamic]Run, // by number, as they came to be
	blocks:  [dynamic]^Block,
	visible: int, // bytes
	pieces:  [dynamic]Piece, // by number; the first is no piece
	numbers: map[u64]u32, // of pieces, by id
	waiting: [dynamic]Waiting, // pieces whose references have not arrived
	base:    Stamp, // of the Value beneath
	// The piece being written here.
	open:    u64,
	ops:     [dynamic]byte,
	flushed: int,
	// Changes, when they are followed.
	follow:  bool,
	touched: [dynamic]u32, // spans that are new or killed
}

Piece :: struct {
	id:    u64,
	stamp: Stamp, // zero while only live
	last:  Spot, // the last insertion's right neighbour
	count: u32, // bytes inserted so far
	fed:   u32, // bytes of the operation stream consumed
	shown: ^[dynamic]byte, // what was consumed while only live, to hold the sealed piece to
	spans: Few, // by offset
}

// Numbers, the first without a list to put it in: most pieces have one span.
@(private)
Few :: struct {
	one:  u32,
	len:  u32,
	list: [dynamic]u32,
}

@(private)
Waiting :: struct {
	piece: u32,
	rest:  []byte, // owned
	at:    int,
}

text_destroy :: proc(t: ^Text) {
	delete(t.data)
	delete(t.spans)
	delete(t.runs)
	for b in t.blocks {
		free(b)
	}
	delete(t.blocks)
	for &p in t.pieces {
		delete(p.spans.list)
		shown_free(&p)
	}
	delete(t.pieces)
	delete(t.numbers)
	for w in t.waiting {
		delete(w.rest)
	}
	delete(t.waiting)
	delete(t.ops)
	delete(t.touched)
	t^ = {}
}

// Bytes it takes to hold a text, more or less.
@(require_results)
text_size :: proc(t: ^Text) -> int {
	return cap(t.data) + cap(t.spans) * size_of(Span) + cap(t.runs) * size_of(Run) + len(t.blocks) * size_of(Block) + cap(t.pieces) * size_of(Piece) + cap(t.numbers) * 16
}

// How many runs it is in.
@(require_results)
text_runs :: proc(t: ^Text) -> int {
	return len(t.spans)
}

Text_Result :: enum {
	Same,
	Changed,
	Waiting, // for a piece it refers to
	Rebuild, // apply everything again to an empty text, in stamp order
}

// Applies the open body of a cell in this text's slot.
text_apply :: proc(t: ^Text, c: ^Cell) -> Text_Result {
	if !stamp_less(t.base, c.stamp) {
		return .Same
	}
	#partial switch c.kind {
	case .Value:
		if len(t.pieces) > 1 {
			return .Rebuild
		}
		t.base = c.stamp
		no := piece_make(t, max(c.stamp.salt, 1))
		t.pieces[no].stamp = c.stamp
		if len(c.body) > 0 {
			text_insert_run(t, no, c.body, {}, {})
		}
		return .Changed
	case .Piece:
		if len(c.body) < 8 {
			return .Same
		}
		return text_piece(t, get_u64(c.body), c.stamp, c.body[8:])
	case .Bundle:
		r := Reader{buf = c.body, pos = clear_size(.Bundle, c.body)}
		out := Text_Result.Same
		for r.pos < len(r.buf) {
			stamp := read_stamp(&r)
			id := read_u64(&r)
			ops := read_bytes(&r)
			if r.bad {
				break
			}
			if !stamp_less(t.base, stamp) {
				continue
			}
			switch text_piece(t, id, stamp, ops) {
			case .Rebuild:
				return .Rebuild
			case .Changed:
				out = .Changed
			case .Waiting:
				out = .Waiting if out == .Same else out
			case .Same:
			}
		}
		return out
	}
	return .Same
}

// Applies a suffix of a piece still being written. Gaps are ignored: the sealed piece will follow.
text_live :: proc(t: ^Text, piece: u64, offset: int, bytes: []byte) -> Text_Result {
	no, known := t.numbers[piece]
	p: Piece
	if known {
		p = t.pieces[no]
	}
	if p.stamp != {} || piece == t.open || piece == 0 || offset > int(p.fed) || offset + len(bytes) <= int(p.fed) {
		return .Same
	}
	if !known {
		no = piece_make(t, piece)
	}
	if text_ops(t, no, bytes[int(p.fed) - offset:]) == 0 {
		if !known { // none of it could be put anywhere, so there is none of it
			delete_key(&t.numbers, piece)
			pop(&t.pieces)
		}
		return .Same
	}
	text_retry(t)
	return .Changed
}

@(private)
piece_make :: proc(t: ^Text, id: u64) -> (no: u32) {
	if len(t.pieces) == 0 {
		append(&t.pieces, Piece{})
	}
	no = u32(len(t.pieces))
	append(&t.pieces, Piece{id = id})
	t.numbers[id] = no
	return
}

@(private)
shown_free :: proc(p: ^Piece) {
	if p.shown != nil {
		delete(p.shown^)
		free(p.shown)
		p.shown = nil
	}
}

@(private)
text_piece :: proc(t: ^Text, id: u64, stamp: Stamp, ops: []byte) -> Text_Result {
	id := id
	if id == 0 {
		return .Same // the edge of the document is nobody's piece
	}
	no, known := t.numbers[id]
	if known && t.pieces[no].stamp == stamp {
		return .Same
	}
	if known && t.pieces[no].stamp != {} {
		// Two writers were once one machine. The earlier stamp keeps the name.
		if stamp_less(stamp, t.pieces[no].stamp) {
			return .Rebuild
		}
		id = stamp.salt
		if id == 0 || id in t.numbers {
			return .Same
		}
		known = false
	}
	if !known {
		no = piece_make(t, id)
	}
	p := &t.pieces[no]
	if int(p.fed) > len(ops) || (p.fed > 0 && string(p.shown[:]) != string(ops[:p.fed])) {
		return .Rebuild // what was seen live is not what was sealed
	}
	shown_free(p)
	p.stamp = stamp
	fed := int(p.fed)
	at := fed + text_ops(t, no, ops[fed:])
	if at < len(ops) {
		rest := make([]byte, len(ops) - at)
		copy(rest, ops[at:])
		append(&t.waiting, Waiting{no, rest, 0})
	}
	text_retry(t)
	for w in t.waiting {
		if w.piece == no {
			return .Waiting
		}
	}
	return .Changed
}

// Resumes pieces that were waiting for one another.
@(private)
text_retry :: proc(t: ^Text) {
	for i := 0; i < len(t.waiting); {
		w := &t.waiting[i]
		n := text_ops(t, w.piece, w.rest[w.at:])
		w.at += n
		if w.at == len(w.rest) {
			delete(w.rest)
			unordered_remove(&t.waiting, i)
		}
		i = 0 if n > 0 else i + 1
	}
}

// Integrates operations in order until one refers to what is not here yet. Returns the bytes consumed.
@(private)
text_ops :: proc(t: ^Text, no: u32, ops: []byte) -> int {
	r := Reader{buf = ops}
	id := t.pieces[no].id
	done := 0
	for r.pos < len(r.buf) {
		op := Op(read_u8(&r))
		first, right: Ref
		count: u32
		bytes: []byte
		extends := false
		switch op {
		case .Insert:
			first, right = read_ref(&r, id), read_ref(&r, id)
			bytes = read_bytes(&r)
			count = 1
		case .Extend:
			extends = true
			r.bad ||= t.pieces[no].count == 0
			bytes = read_bytes(&r)
		case .Delete:
			first = read_ref(&r, id)
			n := read_varint(&r)
			count = u32(n)
			r.bad ||= first.piece == 0 || n > 1 << 30
		case:
			r.bad = true
		}
		if r.bad {
			break
		}
		a, b: Spot
		if extends {
			a, b = {no, t.pieces[no].count - 1}, t.pieces[no].last
		} else {
			have: bool
			if a, have = text_spot(t, first, count); !have {
				break
			}
			if b, have = text_spot(t, right, 1); !have {
				break
			}
		}
		if op == .Delete {
			text_kill(t, a, count)
		} else if len(bytes) > 0 {
			text_insert_run(t, no, bytes, a, b)
		}
		p := &t.pieces[no]
		if p.stamp == {} && id != t.open {
			if p.shown == nil {
				p.shown = new([dynamic]byte)
			}
			append(p.shown, ..ops[done:r.pos])
		}
		p.fed += u32(r.pos - done)
		done = r.pos
	}
	return done
}

// Where elements are, if they are here.
@(private)
text_spot :: proc(t: ^Text, ref: Ref, n: u32) -> (s: Spot, ok: bool) {
	if ref.piece == 0 {
		return {}, true
	}
	no := t.numbers[ref.piece] or_return
	return {no, ref.offset}, u64(ref.offset) + u64(n) <= u64(t.pieces[no].count)
}

@(private)
read_ref :: proc(r: ^Reader, id: u64) -> (ref: Ref) {
	switch tag := read_u8(r); tag {
	case 0:
	case 1, 2:
		ref.piece = id if tag == 1 else read_u64(r)
		offset := read_varint(r)
		ref.offset = u32(offset)
		r.bad ||= ref.piece == 0 || offset > 1 << 30
	case:
		r.bad = true
	}
	return
}

@(private)
write_ref :: proc(t: ^Text, w: ^[dynamic]byte, s: Spot) {
	id := t.pieces[s.piece].id if s.piece != 0 else 0
	switch id {
	case 0:
		append(w, 0)
	case t.open:
		append(w, 1)
		write_varint(w, u64(s.offset))
	case:
		append(w, 2)
		write_u64(w, id)
		write_varint(w, u64(s.offset))
	}
}

// ---------------------------------------------------------------- where spans are

@(private)
few_at :: #force_inline proc(f: ^Few, i: int) -> u32 {
	return f.one if f.list == nil else f.list[i]
}

@(private)
few_put :: proc(f: ^Few, i: int, no: u32) {
	if f.len == 0 {
		f.one, f.len = no, 1
		return
	}
	if f.list == nil {
		append(&f.list, f.one)
	}
	inject_at(&f.list, i, no)
	f.len += 1
}

// Which of a piece's spans holds an element that is known to exist, and its place among them.
@(private)
text_find :: proc(t: ^Text, s: Spot) -> (no: u32, at: int) {
	f := &t.pieces[s.piece].spans
	lo, hi := 0, int(f.len)
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if t.spans[few_at(f, mid)].offset <= s.offset {
			lo = mid
		} else {
			hi = mid
		}
	}
	return few_at(f, lo), lo
}

// Where a span is in the document: greater than that of any before it.
@(private)
span_place :: proc(t: ^Text, no: u32) -> int {
	b := t.spans[no].block
	return b.at * BLOCK + span_index(b, no)
}

@(private)
span_index :: #force_inline proc(b: ^Block, no: u32) -> int {
	for x, i in b.items[:b.count] {
		if x == no {
			return i
		}
	}
	return -1
}

@(private)
span_next :: proc(t: ^Text, no: u32) -> u32 {
	b := t.spans[no].block
	if i := span_index(b, no) + 1; i < b.count {
		return b.items[i]
	}
	return t.blocks[b.at + 1].items[0] if b.at + 1 < len(t.blocks) else NONE
}

@(private)
span_prev :: proc(t: ^Text, no: u32) -> u32 {
	if no == NONE {
		if len(t.blocks) == 0 {
			return NONE
		}
		b := t.blocks[len(t.blocks) - 1]
		return b.items[b.count - 1]
	}
	b := t.spans[no].block
	if i := span_index(b, no); i > 0 {
		return b.items[i - 1]
	}
	if b.at == 0 {
		return NONE
	}
	b = t.blocks[b.at - 1]
	return b.items[b.count - 1]
}

@(private)
span_visible :: #force_inline proc(s: ^Span) -> int {
	return int(s.len) if .Dead not_in s.marks else 0
}

// Puts a span before another, or at the end.
@(private)
span_put :: proc(t: ^Text, no: u32, before: u32) {
	b: ^Block
	i: int
	switch {
	case len(t.blocks) == 0:
		b = new(Block)
		append(&t.blocks, b)
	case before == NONE:
		b = t.blocks[len(t.blocks) - 1]
		i = b.count
	case:
		b = t.spans[before].block
		i = span_index(b, before)
	}
	if b.count == BLOCK {
		// What is written at the end fills blocks, and elsewhere halves them.
		keep := BLOCK if i == BLOCK else BLOCK / 2
		more := new(Block)
		more.at = b.at + 1
		more.count = copy(more.items[:], b.items[keep:])
		b.count = keep
		for x in more.items[:more.count] {
			t.spans[x].block = more
			more.visible += span_visible(&t.spans[x])
		}
		b.visible -= more.visible
		inject_at(&t.blocks, more.at, more)
		for &x, at in t.blocks[more.at + 1:] {
			x.at = more.at + 1 + at
		}
		if i >= keep {
			b, i = more, i - keep
		}
	}
	copy(b.items[i + 1:b.count + 1], b.items[i:b.count])
	b.items[i] = no
	b.count += 1
	s := &t.spans[no]
	s.block = b
	b.visible += span_visible(s)
}

// Splits a span so that its first n bytes stand alone. Returns what follows them.
@(private)
text_split :: proc(t: ^Text, no: u32, n: u32) -> u32 {
	s := &t.spans[no]
	if n == 0 || n >= s.len {
		return span_next(t, no)
	}
	after := span_next(t, no)
	tail := s^
	tail.offset += n
	tail.len -= n
	tail.at += n
	if .Dead not_in s.marks {
		s.block.visible -= int(tail.len)
	}
	s.len = n
	piece := s.piece
	_, at := text_find(t, {piece, tail.offset - 1})
	more := u32(len(t.spans))
	append(&t.spans, tail)
	few_put(&t.pieces[piece].spans, at + 1, more)
	span_put(t, more, after)
	if t.follow && card(tail.marks & {.New, .Killed}) > 0 {
		append(&t.touched, more)
	}
	return more
}

// The span ending with an element, split so that one does; NONE for the document's start.
@(private)
text_left :: proc(t: ^Text, s: Spot) -> u32 {
	if s.piece == 0 {
		return NONE
	}
	no, _ := text_find(t, s)
	_ = text_split(t, no, s.offset - t.spans[no].offset + 1)
	return no
}

// The span beginning with an element; NONE for the document's end.
@(private)
text_right :: proc(t: ^Text, s: Spot) -> u32 {
	if s.piece == 0 {
		return NONE
	}
	no, _ := text_find(t, s)
	if n := s.offset - t.spans[no].offset; n > 0 {
		return text_split(t, no, n)
	}
	return no
}

// ---------------------------------------------------------------- the tree

@(private)
run_find :: proc(t: ^Text, s: Spot) -> u32 {
	no, _ := text_find(t, s)
	return t.spans[no].run
}

@(private)
text_depth :: proc(t: ^Text, s: Spot) -> u32 {
	if s.piece == 0 {
		return 0
	}
	r := &t.runs[run_find(t, s)]
	return r.depth + s.offset - r.offset
}

// Steps taken in finding places, which tests count.
@(private, thread_local)
text_steps: int

// What an element hangs beneath at a depth no greater than its own. A few steps, however deep it is.
@(private)
text_ancestor :: proc(t: ^Text, s: Spot, depth: u32) -> Spot {
	if depth == 0 {
		return {}
	}
	r := run_find(t, s)
	for t.runs[r].depth > depth {
		when ODIN_TEST {
			text_steps += 1
		}
		j := t.runs[r].jump
		r = j if j != NONE && t.runs[j].depth > depth else t.runs[r].up
	}
	x := &t.runs[r]
	return {x.piece, x.offset + depth - x.depth}
}

// Whether one element hangs beneath another, however far down; everything hangs beneath the start, and nothing
// beneath the end.
@(private)
text_below :: proc(t: ^Text, x, a: Spot) -> bool {
	if x.piece == 0 {
		return false
	}
	if a.piece == 0 {
		return true
	}
	dx, da := text_depth(t, x), text_depth(t, a)
	return dx > da && text_ancestor(t, x, da) == a
}

@(private)
first_span :: proc(t: ^Text) -> u32 {
	return t.blocks[0].items[0] if len(t.blocks) > 0 else NONE
}

// Which way a span stands to an insertion among the siblings it will have.
@(private)
Probe :: struct {
	parent: Spot,
	depth:  u32, // of the parent
	key:    Spot, // the first element of what is inserted
	right:  bool, // the side it goes on
}

// Whether a span is beneath the parent, beneath a sibling that comes before what is inserted on the right, or after it
// on the left. A span is of one run, and hangs where its first element does. Going away from the parent such spans come
// first, and then none: the siblings come in order, and what is beneath each is all in one stretch.
@(private)
probe :: proc(t: ^Text, no: u32, q: ^Probe) -> bool {
	when ODIN_TEST {
		text_steps += 1
	}
	e := t.spans[no].id
	if !text_below(t, e, q.parent) {
		return false
	}
	c := text_ancestor(t, e, q.depth + 1)
	return text_key_less(t, c, q.key) if q.right else text_key_less(t, q.key, c)
}

// The first span from one on of which the probe is false, or NONE: by doubling and halving, in a few steps however far.
@(private)
seek_forward :: proc(t: ^Text, i: u32, q: ^Probe) -> u32 {
	if i == NONE || !probe(t, i, q) {
		return i
	}
	b := t.spans[i].block
	x := b
	lo, hi := span_index(b, i), b.count - 1
	if probe(t, b.items[hi], q) {
		at, step := b.at, 1
		for at + step < len(t.blocks) && probe(t, t.blocks[at + step].items[t.blocks[at + step].count - 1], q) {
			at += step
			step *= 2
		}
		top := min(at + step, len(t.blocks))
		for top - at > 1 {
			mid := (at + top) / 2
			if probe(t, t.blocks[mid].items[t.blocks[mid].count - 1], q) {
				at = mid
			} else {
				top = mid
			}
		}
		if top == len(t.blocks) {
			return NONE
		}
		x = t.blocks[top]
		lo, hi = -1, x.count - 1
	}
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if probe(t, x.items[mid], q) {
			lo = mid
		} else {
			hi = mid
		}
	}
	return x.items[hi]
}

// The last span from one back of which the probe is false, or NONE.
@(private)
seek_back :: proc(t: ^Text, i: u32, q: ^Probe) -> u32 {
	if i == NONE || !probe(t, i, q) {
		return i
	}
	b := t.spans[i].block
	x := b
	lo, hi := 0, span_index(b, i)
	if probe(t, b.items[0], q) {
		at, step := b.at, 1
		for at - step >= 0 && probe(t, t.blocks[at - step].items[0], q) {
			at -= step
			step *= 2
		}
		bottom := max(at - step, -1)
		for at - bottom > 1 {
			mid := (at + bottom) / 2
			if probe(t, t.blocks[mid].items[0], q) {
				at = mid
			} else {
				bottom = mid
			}
		}
		if bottom == -1 {
			return NONE
		}
		x = t.blocks[bottom]
		lo, hi = 0, x.count
	}
	for hi - lo > 1 {
		mid := (lo + hi) / 2
		if probe(t, x.items[mid], q) {
			hi = mid
		} else {
			lo = mid
		}
	}
	return x.items[lo]
}

// Siblings go by piece and then by number.
@(private)
text_key_less :: proc(t: ^Text, a, b: Spot) -> bool {
	ia, ib := t.pieces[a.piece].id, t.pieces[b.piece].id
	return ia < ib || (ia == ib && a.offset < b.offset)
}

@(private)
text_insert_run :: proc(t: ^Text, piece: u32, bytes: []byte, left, right: Spot) {
	p := &t.pieces[piece]
	first := Spot{piece, p.count}
	run := Span {
		id    = first,
		len   = u32(len(bytes)),
		at    = u32(len(t.data)),
		marks = {.New} if t.follow else {},
	}
	append(&t.data, ..bytes)
	p.count += run.len
	p.last = right

	// Beneath the right neighbour if that is beneath the left, and otherwise beneath the left.
	under := text_below(t, right, left) && right != left
	parent := right if under else left
	side := !under
	if !(side && parent == {piece, first.offset - 1}) {
		up := run_find(t, parent) if parent.piece != 0 else NONE
		x := Run{id = first, parent = parent, right = side, depth = text_depth(t, parent) + 1, up = up, jump = up}
		// Myers' jump pointers: the jumps of a path double and merge.
		if up != NONE {
			x.hops = t.runs[up].hops + 1
			if j := t.runs[up].jump; j != NONE {
				jj := t.runs[j].jump
				if t.runs[up].hops - t.runs[j].hops == t.runs[j].hops - (t.runs[jj].hops if jj != NONE else 0) {
					x.jump = jj
				}
			}
		} else {
			x.hops = 1
		}
		append(&t.runs, x)
		run.run = u32(len(t.runs) - 1)
	} else {
		run.run = run_find(t, parent)
	}

	// Among its siblings, each with all that hangs beneath it: on the right, after the parent; on the left, before it.
	q := Probe{parent, text_depth(t, parent), first, side}
	before: u32
	if side {
		l := text_left(t, parent)
		before = seek_forward(t, span_next(t, l) if l != NONE else first_span(t), &q)
	} else {
		i := seek_back(t, span_prev(t, text_right(t, parent)), &q)
		before = span_next(t, i) if i != NONE else first_span(t)
	}
	// A run that continues the one before it, in the tree, the document and memory, joins it.
	if at := span_prev(t, before); at != NONE {
		b := &t.spans[at]
		if side && parent == {piece, first.offset - 1} && b.piece == piece && b.offset + b.len == first.offset && b.at + b.len == run.at && b.marks == run.marks {
			b.len += run.len
			b.block.visible += int(run.len)
			t.visible += int(run.len)
			return
		}
	}
	no := u32(len(t.spans))
	append(&t.spans, run)
	f := &t.pieces[piece].spans
	few_put(f, int(f.len), no)
	span_put(t, no, before)
	t.visible += int(run.len)
	if t.follow {
		append(&t.touched, no)
	}
}

@(private)
span_kill :: proc(t: ^Text, no: u32) {
	s := &t.spans[no]
	if .Dead in s.marks {
		return
	}
	s.marks += {.Dead}
	s.block.visible -= int(s.len)
	t.visible -= int(s.len)
	if t.follow {
		s.marks += {.Killed}
		append(&t.touched, no)
	}
}

@(private)
text_kill :: proc(t: ^Text, first: Spot, count: u32) {
	first, count := first, count
	for count > 0 {
		no := text_right(t, first)
		_ = text_split(t, no, count)
		span_kill(t, no)
		n := t.spans[no].len
		first.offset += n
		count -= n
	}
}

// The visible text, appended.
text_read :: proc(t: ^Text, into: ^[dynamic]byte) {
	reserve(into, len(into) + t.visible)
	for b in t.blocks {
		for no in b.items[:b.count] {
			if s := &t.spans[no]; .Dead not_in s.marks {
				append(into, ..t.data[s.at:][:s.len])
			}
		}
	}
}

@(require_results)
text_len :: proc(t: ^Text) -> (n: int) {
	return t.visible
}

// ---------------------------------------------------------------- what changes

// From now on, notes where the text changes.
text_follow :: proc(t: ^Text) {
	t.follow = true
}

// Says what has changed since, stretch by stretch, each from one white space to another: what was there, and what is.
// Temporary memory. And then changes are no longer followed.
text_changes :: proc(t: ^Text, data: rawptr, each: proc(data: rawptr, was, now: []byte)) {
	white :: proc(b: byte) -> bool {
		return b == ' ' || b == '\n' || b == '\t' || b == '\r'
	}
	At :: struct {
		place: int,
		no:    u32,
	}
	all := make([]At, len(t.touched), context.temp_allocator)
	for no, i in t.touched {
		all[i] = {span_place(t, no), no}
	}
	slice.sort_by(all, proc(a, b: At) -> bool {return a.place < b.place})
	was := make([dynamic]byte, context.temp_allocator)
	now := make([dynamic]byte, context.temp_allocator)
	after := -1 // what has been said reaches here
	for x in all {
		if x.place <= after {
			continue
		}
		// Back to white space that was there, and is.
		from, skip := x.no, 0
		for {
			before := span_prev(t, from)
			if before == NONE {
				break
			}
			from = before
			s := &t.spans[from]
			if s.marks != {} {
				continue
			}
			found := false
			bytes := t.data[s.at:][:s.len]
			#reverse for b, i in bytes {
				if white(b) {
					skip, found = i + 1, true
					break
				}
			}
			if found {
				break
			}
		}
		// And on to the next.
		clear(&was)
		clear(&now)
		past := false
		for no := from; no != NONE; no = span_next(t, no) {
			s := &t.spans[no]
			bytes := t.data[s.at:][:s.len]
			if no == x.no {
				past = true
			}
			if s.marks == {} {
				end := len(bytes)
				start := skip if no == from else 0
				if past {
					for b, i in bytes {
						if white(b) {
							end = i
							break
						}
					}
				}
				append(&was, ..bytes[start:end])
				append(&now, ..bytes[start:end])
				if end < len(bytes) {
					break
				}
				continue
			}
			if .New not_in s.marks && (.Dead not_in s.marks || .Killed in s.marks) {
				append(&was, ..bytes)
			}
			if .Dead not_in s.marks {
				append(&now, ..bytes)
			}
			after = span_place(t, no)
		}
		each(data, was[:], now[:])
	}
	for no in t.touched {
		t.spans[no].marks -= {.New, .Killed}
	}
	clear(&t.touched)
	t.follow = false
}

// ---------------------------------------------------------------- writing

// The span a visible position lies in or at the end of, and how far in.
@(private)
text_seek :: proc(t: ^Text, pos: int) -> (no: u32, into: int) {
	left := pos
	for b in t.blocks {
		if left > b.visible {
			left -= b.visible
			continue
		}
		for x in b.items[:b.count] {
			n := span_visible(&t.spans[x])
			if n > 0 && left <= n {
				return x, left
			}
			left -= n
		}
	}
	return NONE, 0
}

// Types bytes at a visible position. `fresh` names the piece this begins, if none is open.
text_insert :: proc(t: ^Text, pos: int, bytes: []byte, fresh: u64) {
	if len(bytes) == 0 {
		return
	}
	text_begin(t, fresh)
	// The element before the position, and whatever follows it, living or dead.
	left, right: Spot
	next := NONE
	if pos <= 0 {
		next = t.blocks[0].items[0] if len(t.blocks) > 0 else NONE
	} else if no, into := text_seek(t, pos); no != NONE {
		next = text_split(t, no, u32(into))
		s := &t.spans[no]
		left = {s.piece, s.offset + s.len - 1}
	}
	if next != NONE {
		right = t.spans[next].id
	}
	open := t.numbers[t.open]
	p := &t.pieces[open]
	if p.count > 0 && left == {open, p.count - 1} && right == p.last {
		append(&t.ops, byte(Op.Extend))
	} else {
		append(&t.ops, byte(Op.Insert))
		write_ref(t, &t.ops, left)
		write_ref(t, &t.ops, right)
	}
	write_bytes(&t.ops, bytes)
	text_insert_run(t, open, bytes, left, right)
}

// Deletes visible bytes.
text_delete :: proc(t: ^Text, pos, count: int, fresh: u64) {
	if count <= 0 {
		return
	}
	text_begin(t, fresh)
	left := min(count, t.visible - pos)
	for left > 0 {
		// Up to the position is kept; what follows it goes.
		no, into := text_seek(t, pos + 1)
		if no == NONE {
			return
		}
		if into > 1 {
			no = text_split(t, no, u32(into - 1))
		}
		_ = text_split(t, no, u32(left))
		s := t.spans[no]
		append(&t.ops, byte(Op.Delete))
		write_ref(t, &t.ops, s.id)
		write_varint(&t.ops, u64(s.len))
		span_kill(t, no)
		left -= int(s.len)
	}
}

@(private)
text_begin :: proc(t: ^Text, fresh: u64) {
	if t.open == 0 {
		t.open = fresh
		_ = piece_make(t, fresh)
	}
}

// What has been written since the last call, as a live suffix.
@(require_results)
text_flush :: proc(t: ^Text) -> (piece: u64, offset: int, bytes: []byte) {
	defer t.flushed = len(t.ops)
	return t.open, t.flushed, t.ops[t.flushed:]
}

// Ends the open piece, yielding the open body of its cell, in temporary memory.
@(require_results)
text_close :: proc(t: ^Text, stamp: Stamp) -> (body: []byte, ok: bool) {
	if t.open == 0 {
		return
	}
	w := make([dynamic]byte, 0, len(t.ops) + 8, context.temp_allocator)
	write_u64(&w, t.open)
	append(&w, ..t.ops[:])
	p := &t.pieces[t.numbers[t.open]]
	p.stamp = stamp
	p.fed = u32(len(t.ops))
	t.open = 0
	t.flushed = 0
	clear(&t.ops)
	return w[:], true
}

// Absorbs pieces and bundles of one slot into a single bundle with an open body. It kills exactly
// what it names, so it is safe at any time, whatever else is in flight.
@(require_results)
text_bundle :: proc(cells: []Cell, allocator := context.allocator) -> (out: Cell) {
	Inner :: struct {
		stamp: Stamp,
		id:    u64,
		ops:   []byte,
	}
	inner := make([dynamic]Inner, context.temp_allocator)
	names := make([dynamic]Stamp, context.temp_allocator)
	for &c in cells {
		#partial switch c.kind {
		case .Piece:
			append(&names, c.stamp)
			append(&inner, Inner{c.stamp, get_u64(c.body), c.body[8:]})
		case .Bundle:
			append(&names, c.stamp)
			for i in 0 ..< int(get_u32(c.body)) {
				append(&names, bundle_at(c.body, i))
			}
			r := Reader{buf = c.body, pos = clear_size(.Bundle, c.body)}
			for r.pos < len(r.buf) {
				stamp := read_stamp(&r)
				id := read_u64(&r)
				append(&inner, Inner{stamp, id, read_bytes(&r)})
			}
		}
		out.row, out.slot = c.row, c.slot
	}
	slice.sort_by(names[:], proc(a, b: Stamp) -> bool {return stamp_less(a, b)})
	slice.sort_by(inner[:], proc(a, b: Inner) -> bool {return stamp_less(a.stamp, b.stamp)})
	unique := slice.unique(names[:])
	w := make([dynamic]byte, allocator)
	resize(&w, 4)
	put_u32(w[:], u32(len(unique)))
	for n in unique {
		write_stamp(&w, n)
	}
	last: Stamp
	for i in inner {
		if i.stamp == last {
			continue
		}
		last = i.stamp
		write_stamp(&w, i.stamp)
		write_u64(&w, i.id)
		write_bytes(&w, i.ops)
	}
	out.kind = .Bundle
	out.body = w[:]
	return
}
