#+build !js
package zsp

// The text as simply as it can be put, to hold the other to.


// A collaborative text column: a sequence CRDT over UTF-8 bytes.
//
// A piece is an append-only stream of operations by one writer. Because it only ever grows, a piece
// still being written can be streamed as suffixes (live frames) and integrated as they arrive; when it
// is sealed into a cell, whatever was already integrated is skipped. A text is a pure function of the
// set of pieces in its slot, plus at most one Value beneath them.
//
// Placement is YjsMod/FugueMax: each run remembers its neighbours at birth, so concurrent runs never
// interleave.

Plain_Ref :: struct {
	piece:  u64, // zero for the edge of the document
	offset: u32,
}

@(private)
Plain_NO_REF :: Plain_Ref{}

@(private)
Plain_Op :: enum u8 {
	Insert = 1, // left, right, bytes
	Extend = 2, // bytes, continuing this piece's last insertion
	Delete = 3, // first, count
}

Plain_Span :: struct {
	id:   Plain_Ref, // of its first byte; the rest follow
	len:  u32,
	at:   u32, // in Plain_Text.data
	left: Plain_Ref, // neighbours of its first byte, when it was typed
	right: Plain_Ref,
	dead: bool,
}

Plain_Text :: struct {
	data:    [dynamic]byte,
	spans:   [dynamic]Plain_Span, // in document order, dead ones included
	pieces:  map[u64]Plain_Piece,
	waiting: [dynamic]Plain_Waiting, // pieces whose references have not arrived
	base:    Stamp, // of the Value beneath
	hint:    int, // a span near the last one touched
	// The piece being written here.
	open:    u64,
	ops:     [dynamic]byte,
	flushed: int,
}

Plain_Piece :: struct {
	count: u32, // bytes inserted so far
	last:  Plain_Ref, // the last insertion's right neighbour
	fed:   int, // bytes of the operation stream consumed
	stamp: Stamp, // zero while only live
	shown: [dynamic]byte, // what was consumed while only live, to hold the sealed piece to
}

@(private)
Plain_Waiting :: struct {
	piece: u64,
	rest:  []byte, // owned
	at:    int,
}

plain_text_destroy :: proc(t: ^Plain_Text) {
	delete(t.data)
	delete(t.spans)
	for _, p in t.pieces {
		delete(p.shown)
	}
	delete(t.pieces)
	for w in t.waiting {
		delete(w.rest)
	}
	delete(t.waiting)
	delete(t.ops)
	t^ = {}
}

Plain_Text_Result :: enum {
	Same,
	Changed,
	Waiting, // for a piece it refers to
	Rebuild, // apply everything again to an empty text, in stamp order
}

// Applies the open body of a cell in this text's slot.
plain_text_apply :: proc(t: ^Plain_Text, c: ^Cell) -> Plain_Text_Result {
	if !stamp_less(t.base, c.stamp) {
		return .Same
	}
	#partial switch c.kind {
	case .Value:
		if len(t.pieces) > 0 {
			return .Rebuild
		}
		t.base = c.stamp
		id := max(c.stamp.salt, 1)
		t.pieces[id] = {stamp = c.stamp}
		if len(c.body) > 0 {
			plain_text_insert_run(t, id, c.body, Plain_NO_REF, Plain_NO_REF)
		}
		return .Changed
	case .Piece:
		if len(c.body) < 8 {
			return .Same
		}
		return plain_text_piece(t, get_u64(c.body), c.stamp, c.body[8:])
	case .Bundle:
		r := Reader{buf = c.body, pos = clear_size(.Bundle, c.body)}
		out := Plain_Text_Result.Same
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
			switch plain_text_piece(t, id, stamp, ops) {
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
plain_text_live :: proc(t: ^Plain_Text, piece: u64, offset: int, bytes: []byte) -> Plain_Text_Result {
	p := t.pieces[piece]
	if p.stamp != {} || piece == t.open || piece == 0 || offset > p.fed || offset + len(bytes) <= p.fed {
		return .Same
	}
	if plain_text_ops(t, piece, bytes[p.fed - offset:]) == 0 {
		return .Same
	}
	plain_text_retry(t)
	return .Changed
}

@(private)
plain_text_piece :: proc(t: ^Plain_Text, id: u64, stamp: Stamp, ops: []byte) -> Plain_Text_Result {
	id := id
	if id == 0 {
		return .Same // the edge of the document is nobody's piece
	}
	p, known := t.pieces[id]
	if known && p.stamp == stamp {
		return .Same
	}
	if known && p.stamp != {} {
		// Two writers were once one machine. The earlier stamp keeps the name.
		if stamp_less(stamp, p.stamp) {
			return .Rebuild
		}
		id = stamp.salt
		if id == 0 || id in t.pieces {
			return .Same
		}
		p = {}
	}
	if p.fed > len(ops) || string(p.shown[:]) != string(ops[:p.fed]) {
		return .Rebuild // what was seen live is not what was sealed
	}
	delete(p.shown)
	p.shown = {}
	p.stamp = stamp
	t.pieces[id] = p
	at := p.fed + plain_text_ops(t, id, ops[p.fed:])
	if at < len(ops) {
		rest := make([]byte, len(ops) - at)
		copy(rest, ops[at:])
		append(&t.waiting, Plain_Waiting{id, rest, 0})
	}
	plain_text_retry(t)
	for w in t.waiting {
		if w.piece == id {
			return .Waiting
		}
	}
	return .Changed
}

// Resumes pieces that were waiting for one another.
@(private)
plain_text_retry :: proc(t: ^Plain_Text) {
	for i := 0; i < len(t.waiting); {
		w := &t.waiting[i]
		n := plain_text_ops(t, w.piece, w.rest[w.at:])
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
plain_text_ops :: proc(t: ^Plain_Text, id: u64, ops: []byte) -> int {
	r := Reader{buf = ops}
	done := 0
	for r.pos < len(r.buf) {
		op := Plain_Op(read_u8(&r))
		first, right: Plain_Ref
		count: u32
		bytes: []byte
		switch op {
		case .Insert:
			first, right = plain_read_ref(&r, id), plain_read_ref(&r, id)
			bytes = read_bytes(&r)
			count = 1
		case .Extend:
			p := t.pieces[id]
			r.bad ||= p.count == 0
			first, right = {id, p.count - 1}, p.last
			bytes = read_bytes(&r)
			count = 1
		case .Delete:
			first = plain_read_ref(&r, id)
			n := read_varint(&r)
			count = u32(n)
			r.bad ||= first.piece == 0 || n > 1 << 30
		case:
			r.bad = true
		}
		if r.bad || !plain_text_has(t, first, count) || !plain_text_has(t, right, 1) {
			break
		}
		if op == .Delete {
			plain_text_kill(t, first, count)
		} else if len(bytes) > 0 {
			plain_text_insert_run(t, id, bytes, first, right)
		}
		p := t.pieces[id]
		if p.stamp == {} && id != t.open {
			append(&p.shown, ..ops[done:r.pos])
		}
		p.fed += r.pos - done
		t.pieces[id] = p
		done = r.pos
	}
	return done
}

@(private)
plain_text_has :: proc(t: ^Plain_Text, ref: Plain_Ref, n: u32) -> bool {
	return ref.piece == 0 || u64(ref.offset) + u64(n) <= u64(t.pieces[ref.piece].count)
}

@(private)
plain_read_ref :: proc(r: ^Reader, id: u64) -> (ref: Plain_Ref) {
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
plain_write_ref :: proc(w: ^[dynamic]byte, id: u64, ref: Plain_Ref) {
	switch ref.piece {
	case 0:
		append(w, 0)
	case id:
		append(w, 1)
		write_varint(w, u64(ref.offset))
	case:
		append(w, 2)
		write_u64(w, ref.piece)
		write_varint(w, u64(ref.offset))
	}
}

// Index of the span holding an element that is known to exist.
@(private)
plain_text_find :: proc(t: ^Plain_Text, ref: Plain_Ref) -> int {
	holds :: #force_inline proc(s: ^Plain_Span, ref: Plain_Ref) -> bool {
		return s.id.piece == ref.piece && ref.offset - s.id.offset < s.len && ref.offset >= s.id.offset
	}
	// Edits cluster.
	for i in max(t.hint - 2, 0) ..< min(t.hint + 3, len(t.spans)) {
		if holds(&t.spans[i], ref) {
			return i
		}
	}
	for &s, i in t.spans {
		if holds(&s, ref) {
			t.hint = i
			return i
		}
	}
	return -1
}

// Splits span i so that its first n bytes stand alone.
@(private)
plain_text_split :: proc(t: ^Plain_Text, i: int, n: u32) {
	if n == 0 || n >= t.spans[i].len {
		return
	}
	s := t.spans[i]
	tail := s
	tail.id.offset += n
	tail.len -= n
	tail.at += n
	tail.left = {s.id.piece, s.id.offset + n - 1}
	t.spans[i].len = n
	inject_at(&t.spans, i + 1, tail)
}

// Index of the span ending with ref, split so that one does; -1 for the document's start.
@(private)
plain_text_left :: proc(t: ^Plain_Text, ref: Plain_Ref) -> int {
	if ref.piece == 0 {
		return -1
	}
	i := plain_text_find(t, ref)
	plain_text_split(t, i, ref.offset - t.spans[i].id.offset + 1)
	return i
}

// Index of the span beginning with ref; the number of spans for the document's end.
@(private)
plain_text_right :: proc(t: ^Plain_Text, ref: Plain_Ref) -> int {
	if ref.piece == 0 {
		return len(t.spans)
	}
	i := plain_text_find(t, ref)
	if n := ref.offset - t.spans[i].id.offset; n > 0 {
		plain_text_split(t, i, n)
		return i + 1
	}
	return i
}

@(private)
plain_text_insert_run :: proc(t: ^Plain_Text, id: u64, bytes: []byte, left, right: Plain_Ref) {
	p := t.pieces[id]
	run := Plain_Span {
		id    = {id, p.count},
		len   = u32(len(bytes)),
		at    = u32(len(t.data)),
		left  = left,
		right = right,
	}
	append(&t.data, ..bytes)
	p.count += run.len
	p.last = right
	t.pieces[id] = p

	l := plain_text_left(t, left)
	r := plain_text_right(t, right)
	l = plain_text_left(t, left) // what was split may have been before it
	at := l + 1
	scanning := false
	for i := at;; i += 1 {
		if !scanning {
			at = i
		}
		if i >= len(t.spans) || i == r {
			break
		}
		o := t.spans[i]
		ol := -1 if o.left.piece == 0 else plain_text_find(t, o.left)
		or := len(t.spans) if o.right.piece == 0 else plain_text_find(t, o.right)
		same_left := o.left == left
		if ol < l || (ol == l && !same_left) {
			break
		}
		if same_left {
			if o.right == right && id < o.id.piece {
				break
			}
			scanning = or < r
		}
	}
	// A run that continues the one before it, in the document and in memory, joins it.
	if at > 0 {
		b := &t.spans[at - 1]
		if b.id.piece == id && b.id.offset + b.len == run.id.offset && left == {id, run.id.offset - 1} && b.right == right && b.at + b.len == run.at && !b.dead {
			b.len += run.len
			t.hint = at - 1
			return
		}
	}
	inject_at(&t.spans, at, run)
	t.hint = at
}

@(private)
plain_text_kill :: proc(t: ^Plain_Text, first: Plain_Ref, count: u32) {
	first, count := first, count
	for count > 0 {
		i := plain_text_right(t, first)
		plain_text_split(t, i, count)
		s := &t.spans[i]
		s.dead = true
		first.offset += s.len
		count -= s.len
	}
}

// The visible text, appended.
plain_text_read :: proc(t: ^Plain_Text, into: ^[dynamic]byte) {
	for s in t.spans {
		if !s.dead {
			append(into, ..t.data[s.at:][:s.len])
		}
	}
}

@(require_results)
plain_text_len :: proc(t: ^Plain_Text) -> (n: int) {
	for s in t.spans {
		n += int(s.len) if !s.dead else 0
	}
	return
}

// ---------------------------------------------------------------- writing

// Types bytes at a visible position. `fresh` names the piece this begins, if none is open.
plain_text_insert :: proc(t: ^Plain_Text, pos: int, bytes: []byte, fresh: u64) {
	if len(bytes) == 0 {
		return
	}
	plain_text_begin(t, fresh)
	// The element before the position, and whatever follows it, living or dead.
	left, right: Plain_Ref
	seen := 0
	i := 0
	for ; i < len(t.spans) && seen < pos; i += 1 {
		s := &t.spans[i]
		if s.dead {
			continue
		}
		if seen + int(s.len) >= pos {
			plain_text_split(t, i, u32(pos - seen))
			s = &t.spans[i]
			left = {s.id.piece, s.id.offset + s.len - 1}
			seen = pos
			i += 1
			break
		}
		seen += int(s.len)
	}
	if i < len(t.spans) {
		right = t.spans[i].id
	}
	p := t.pieces[t.open]
	if p.count > 0 && left == {t.open, p.count - 1} && right == p.last {
		append(&t.ops, byte(Plain_Op.Extend))
	} else {
		append(&t.ops, byte(Plain_Op.Insert))
		plain_write_ref(&t.ops, t.open, left)
		plain_write_ref(&t.ops, t.open, right)
	}
	write_bytes(&t.ops, bytes)
	plain_text_insert_run(t, t.open, bytes, left, right)
}

// Deletes visible bytes.
plain_text_delete :: proc(t: ^Plain_Text, pos, count: int, fresh: u64) {
	if count <= 0 {
		return
	}
	plain_text_begin(t, fresh)
	pos, count := pos, count
	for i := 0; i < len(t.spans) && count > 0; i += 1 {
		s := &t.spans[i]
		if s.dead {
			continue
		}
		if pos >= int(s.len) {
			pos -= int(s.len)
			continue
		}
		if pos > 0 {
			plain_text_split(t, i, u32(pos))
			pos = 0
			continue
		}
		plain_text_split(t, i, u32(count))
		s = &t.spans[i]
		s.dead = true
		append(&t.ops, byte(Plain_Op.Delete))
		plain_write_ref(&t.ops, t.open, s.id)
		write_varint(&t.ops, u64(s.len))
		count -= int(s.len)
	}
}

@(private)
plain_text_begin :: proc(t: ^Plain_Text, fresh: u64) {
	if t.open == 0 {
		t.open = fresh
		t.pieces[fresh] = {}
	}
}

// What has been written since the last call, as a live suffix.
@(require_results)
plain_text_flush :: proc(t: ^Plain_Text) -> (piece: u64, offset: int, bytes: []byte) {
	defer t.flushed = len(t.ops)
	return t.open, t.flushed, t.ops[t.flushed:]
}

// Ends the open piece, yielding the open body of its cell, in temporary memory.
@(require_results)
plain_text_close :: proc(t: ^Plain_Text, stamp: Stamp) -> (body: []byte, ok: bool) {
	if t.open == 0 {
		return
	}
	w := make([dynamic]byte, 0, len(t.ops) + 8, context.temp_allocator)
	write_u64(&w, t.open)
	append(&w, ..t.ops[:])
	p := t.pieces[t.open]
	p.stamp = stamp
	p.fed = len(t.ops)
	t.pieces[t.open] = p
	t.open = 0
	t.flushed = 0
	clear(&t.ops)
	return w[:], true
}

