#+build !js
package find

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math/rand"
import "core:slice"
import "core:strings"
import "core:testing"
import "../zsp"

// Everything the index says is held against what the cells say.

@(private)
World :: struct {
	disk:   zsp.Memory_Disk,
	node:   zsp.Node,
	keys:   zsp.Keyring,
	secret: zsp.Key32,
	space:  zsp.Key32,
	root:   zsp.Key32,
	roster: []byte,
	pages:  Memory_Disk,
	x:      Index,
	rows:   [dynamic]zsp.Id, // of both scopes, some gone
}

WORDS := []string{"apple", "apples", "apply", "banana", "band", "cherry", "Crème", "déjà", "elephant", "elegant", "fig", "grape", "grapefruit", "house", "mouse", "东京", "京都大学", "x", "don't", "counterrevolutionaries", "counterrevolutionary", "a"}
TAGS := []string{"apple", "a long name that", "exactly sixteen!", "exactly sixteen!!", "exactly sixteen?", "a long name that goes on", "a long name that goes off"}
NAMES := []string{"a\x00b", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xfe", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff", "\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\xff\x01", "", "a", "A", "ab", "Ab", "abc", "Zoë", "zoe", "exactly sixteen!", "exactly sixteen!!", "exactly sixteen?", "EXACTLY SIXTEEN!", "a long name that goes on", "a long name that goes off", "n\x00", "n"}

@(private)
world_make :: proc(t: ^testing.T, w: ^World, partial: ^World = nil, flags := zsp.Scope_Flags{}) {
	root: zsp.Key32
	for &b in root {
		b = byte(rand.uint32())
	}
	for &b in w.secret {
		b = byte(rand.uint32())
	}
	zsp.keyring_init(&w.keys, w.secret)
	if partial != nil {
		for &b in partial.secret {
			b = byte(rand.uint32())
		}
		zsp.keyring_init(&partial.keys, partial.secret)
	}
	none: zsp.Roster
	d := zsp.draft_from(&none, 1)
	for i in 0 ..< 2 {
		scope := zsp.draft_scope(&d, flags + (zsp.Scope_Flags{.Signed} if i == 0 else {})) // whose what is, the first says
		m := zsp.draft_grant(&d, w.keys.device, w.keys.signer, scope, {.Write, .Vouch})
		m.owner, m.subject = true, transmute([]byte)string("whoever")
		if partial != nil {
			zsp.draft_grant(&d, partial.keys.device, partial.keys.signer, scope, {.Read, .Write})
		}
	}
	ok: bool
	w.roster, ok = zsp.roster_sign(&w.keys, root, &d)
	testing.expect(t, ok)
	w.space, w.root = zsp.ed25519_public(root), root
	world_start(t, w)
	if partial != nil {
		partial.roster, partial.space = slice.clone(w.roster), w.space
		world_start(t, partial, false)
	}
}

@(private)
world_start :: proc(t: ^testing.T, w: ^World, full := true) {
	testing.expect(t, zsp.node_init(&w.node, zsp.memory_disk(&w.disk), w.space, &w.keys, full, 64))
	testing.expect(t, zsp.node_adopt(&w.node, w.roster))
	w.node.now = 1_700_000_000_000
	index_open(&w.x, &w.node, memory_disk(&w.pages), w.secret)
}

@(private)
world_stop :: proc(w: ^World) {
	index_close(&w.x)
	zsp.store_flush(&w.node.store)
	zsp.node_destroy(&w.node)
}

@(private)
world_destroy :: proc(w: ^World) {
	world_stop(w)
	zsp.keyring_destroy(&w.keys)
	zsp.memory_disk_destroy(&w.disk)
	memory_disk_destroy(&w.pages)
	delete(w.roster)
	delete(w.rows)
}

@(private)
some_text :: proc() -> string {
	b := make([dynamic]byte, context.temp_allocator)
	many := rand.int_max(12)
	for i in 0 ..< many {
		if i > 0 {
			append(&b, " ")
		}
		append(&b, rand.choice(WORDS))
	}
	return string(b[:])
}

@(private)
list_of :: proc(scope: zsp.Scope, i: int) -> zsp.List {
	return {u64(scope) << 32 | 9, u64(i)}
}

@(private)
world_write :: proc(t: ^testing.T, w: ^World) {
	n := &w.node
	n.now += u64(rand.int_max(3000))
	cells := make([dynamic]zsp.Cell, context.temp_allocator)
	put :: proc(cells: ^[dynamic]zsp.Cell, slot: int, kind: zsp.Kind, body: []byte) {
		append(cells, zsp.Cell{slot = zsp.Slot(slot), kind = kind, body = body})
	}
	place :: proc(cells: ^[dynamic]zsp.Cell, scope: zsp.Scope) {
		b := make([]byte, 24, context.temp_allocator)
		l := list_of(scope, rand.int_max(3))
		zsp.put_u64(b, l[0])
		zsp.put_u64(b[8:], l[1])
		zsp.put_u64(b[16:], u64(rand.int_max(50)))
		put(cells, 1 + rand.int_max(2), .Place, b)
	}
	id: zsp.Id
	if len(w.rows) == 0 || rand.int_max(3) == 0 {
		id = zsp.node_id(n, zsp.Scope(1 + rand.int_max(2)))
		append(&w.rows, id)
		place(&cells, zsp.row_scope(id))
	} else {
		id = rand.choice(w.rows[:])
		switch rand.int_max(40) {
		case 0:
			put(&cells, 0, .Grave, nil)
		case 1 ..= 4:
			place(&cells, zsp.row_scope(id))
		}
	}
	many_2 := rand.int_max(4)
	for _ in 0 ..< many_2 {
		if len(cells) > 0 && cells[0].kind == .Grave {
			break
		}
		switch rand.int_max(6) {
		case 0:
			put(&cells, 16, .Value, transmute([]byte)rand.choice(NAMES))
		case 1:
			b := make([]byte, 8, context.temp_allocator)
			zsp.put_u64(b, transmute(u64)(f64(rand.int_max(21) - 10) / 2))
			put(&cells, 17, .Value, b)
		case 2:
			b := make([]byte, 1, context.temp_allocator)
			b[0] = byte(rand.int_max(2))
			put(&cells, 18, .Value, b)
		case 3:
			other := rand.choice(w.rows[:]) if rand.int_max(2) == 0 else w.rows[rand.int_max(min(2, len(w.rows)))] // some far more than others
			b := make([]byte, 16, context.temp_allocator)
			zsp.put_u64(b, other[0])
			zsp.put_u64(b[8:], other[1])
			put(&cells, 19, .Value, b)
		case 4:
			text := some_text()
			if rand.int_max(2) == 0 {
				put(&cells, 20, .Value, transmute([]byte)text)
			} else {
				b := make([dynamic]byte, context.temp_allocator)
				zsp.write_u64(&b, rand.uint64() | 1)
				append(&b, 1, 0, 0)
				zsp.write_bytes(&b, transmute([]byte)fmt.tprint(text, ""))
				put(&cells, 20, .Piece, b[:])
			}
		case 5:
			json := fmt.tprintf(`{{"\u006e":%v,"t\u0061gs":["%s","%s","%s"],"deep":{{"on":%v,"name":"%s"}},"skip":[{{"n":9}}]}}`, rand.int_max(5), rand.choice(TAGS), rand.choice(TAGS), rand.choice(TAGS), rand.int_max(2) == 0, rand.choice(WORDS[:4]))
			put(&cells, 21, .Value, transmute([]byte)(json if rand.int_max(10) > 0 else "not json"))
		}
	}
	// One cell to a slot: the rest of a burst would only be refused.
	n_cells := 0
	for c, i in cells {
		again := false
		for other in cells[:i] {
			again ||= other.slot == c.slot
		}
		if !again {
			cells[n_cells] = c
			n_cells += 1
		}
	}
	for &c in cells[:n_cells] {
		c.row = id
		c.stamp = zsp.node_stamp(n)
	}
	as := rand.choice(NAMES[2:]) if rand.int_max(2) == 0 else ""
	testing.expect(t, zsp.node_write(n, cells[:n_cells], transmute([]byte)as))
}

// The roster has the one who writes go by another name, or be believed about others, or not.
@(private)
world_rename :: proc(t: ^testing.T, w: ^World) {
	d := zsp.draft_from(&w.node.roster, max(w.node.clock, w.node.now << 16))
	if rand.int_max(2) == 0 {
		for &m in d.members {
			if m.device == w.keys.device {
				m.subject = transmute([]byte)rand.choice(NAMES)
			}
		}
	} else {
		zsp.draft_grant(&d, w.keys.device, w.keys.signer, 1, {.Write, .Vouch} if rand.int_max(2) == 0 else {.Write})
	}
	bytes, ok := zsp.roster_sign(&w.keys, w.root, &d)
	testing.expect(t, ok && zsp.node_adopt(&w.node, bytes))
	delete(w.roster)
	w.roster = bytes
}

// ---------------------------------------------------------------- questions

@(private)
Ask :: struct {
	w:   ^World,
	out: ^[dynamic]byte,
}

@(private)
ask_column :: proc(out: ^[dynamic]byte, kinds: bit_set[Kind]) -> Kind {
	for {
		k := Kind(1 + rand.int_max(len(Kind)))
		if k not_in kinds {
			continue
		}
		slot, path := u8(16), ""
		#partial switch k {
		case .Number:
			slot = 17
			if rand.int_max(3) == 0 {
				slot, path = 21, "n"
			}
		case .Bool:
			slot = 18
			if rand.int_max(3) == 0 {
				slot, path = 21, "deep.on"
			}
		case .Id:
			slot = 19
		case .Words:
			slot = 20
			if rand.int_max(4) == 0 {
				slot, path = 21, "tags"
			}
		case .Bytes, .Fold:
			switch rand.int_max(4) {
			case 0:
				slot, path = 21, "tags"
			case 1:
				slot, path = 21, "deep.name"
			case 2:
				slot = 20
			}
		}
		append(out, u8(k))
		#partial switch k {
		case .Order:
			l := list_of(1, rand.int_max(3))
			zsp.write_u64(out, l[0])
			zsp.write_u64(out, l[1])
		case .Created, .Modified:
		case .Author:
			append(out, u8(16 + rand.int_max(5)))
		case:
			append(out, slot)
			zsp.write_bytes(out, transmute([]byte)path)
		}
		return k
	}
}

@(private)
ask_value :: proc(a: ^Ask, k: Kind) {
	out := a.out
	eight :: proc(out: ^[dynamic]byte, v: u64) {
		zsp.write_varint(out, 8)
		zsp.write_u64(out, v)
	}
	switch k {
	case .Bytes, .Fold, .Author:
		zsp.write_bytes(out, transmute([]byte)(rand.choice(NAMES) if rand.int_max(2) == 0 else rand.choice(WORDS) if rand.int_max(2) == 0 else rand.choice(TAGS)))
	case .Number:
		eight(out, transmute(u64)(f64(rand.int_max(21) - 10) / 2))
	case .Bool:
		append(out, 1, byte(rand.int_max(2)))
	case .Id:
		id := rand.choice(a.w.rows[:])
		zsp.write_varint(out, 16)
		zsp.write_u64(out, id[0])
		zsp.write_u64(out, id[1])
	case .Created, .Modified:
		id := rand.choice(a.w.rows[:])
		eight(out, transmute(u64)f64(u32(id[0])))
	case .Order:
		eight(out, u64(rand.int_max(50)))
	case .Words:
	}
}

@(private)
ask_pred :: proc(a: ^Ask, depth: int) {
	out := a.out
	SORTED :: bit_set[Kind]{.Bytes, .Fold, .Number, .Bool, .Id, .Created, .Modified, .Order, .Author}
	op := Op(rand.int_max(14))
	if depth > 3 && (op == .And || op == .Or || op == .Not || op == .Ref || op == .Back) {
		op = .Range
	}
	append(out, u8(op))
	switch op {
	case .All:
	case .And, .Or:
		n := rand.int_max(4)
		zsp.write_varint(out, u64(n))
		for _ in 0 ..< n {
			ask_pred(a, depth + 1)
		}
	case .Not:
		ask_pred(a, depth + 1)
	case .Range:
		k := ask_column(out, SORTED)
		flags := byte(rand.int_max(16))
		append(out, flags)
		if flags == 15 && rand.int_max(2) == 0 {
			v := make([dynamic]byte, context.temp_allocator)
			b := Ask{a.w, &v}
			ask_value(&b, k)
			append(out, ..v[:])
			append(out, ..v[:])
			break
		}
		if flags & 1 != 0 {
			ask_value(a, k)
		}
		if flags & 2 != 0 {
			ask_value(a, k)
		}
	case .In:
		k := ask_column(out, SORTED)
		n := rand.int_max(4)
		zsp.write_varint(out, u64(n))
		for _ in 0 ..< n {
			ask_value(a, k)
		}
	case .Prefix, .Has:
		ask_column(out, {.Bytes, .Fold, .Author})
		s := rand.choice(NAMES) if rand.int_max(2) == 0 else rand.choice(WORDS)
		zsp.write_bytes(out, transmute([]byte)s[:rand.int_max(len(s) + 1)])
	case .Exists:
		ask_column(out, SORTED)
	case .List:
		l := list_of(1, rand.int_max(3))
		zsp.write_u64(out, l[0])
		zsp.write_u64(out, l[1])
	case .Match:
		ask_column(out, {.Words})
		append(out, byte(rand.int_max(3)), byte(rand.int_max(16)))
		text := make([dynamic]byte, context.temp_allocator)
		many_3 := rand.int_max(3)
		for _ in 0 ..< many_3 {
			word := rand.choice(WORDS)
			if rand.int_max(3) == 0 {
				word = word[:rand.int_max(len(word)) + 1]
			}
			append(&text, word)
			append(&text, " ")
		}
		zsp.write_bytes(out, text[:])
	case .Ids:
		n := rand.int_max(5)
		zsp.write_varint(out, u64(n))
		for _ in 0 ..< n {
			id := rand.choice(a.w.rows[:])
			zsp.write_u64(out, id[0])
			zsp.write_u64(out, id[1])
		}
	case .Ref, .Back:
		append(out, u8(Kind.Id), 19, 0)
		zsp.write_varint(out, u64(1 + rand.int_max(2)))
		if op == .Back {
			least := u64(rand.int_max(3))
			zsp.write_varint(out, least)
			zsp.write_varint(out, least + u64(rand.int_max(3)) if rand.int_max(2) == 0 else max(u64))
		}
		ask_pred(a, depth + 1)
	}
}

@(private)
ask :: proc(w: ^World) -> []byte {
	out := make([dynamic]byte, context.temp_allocator)
	a := Ask{w, &out}
	zsp.write_varint(&out, 1)
	ask_pred(&a, 0)
	n := rand.int_max(4)
	zsp.write_varint(&out, u64(n))
	for _ in 0 ..< n {
		by := rand.int_max(3)
		append(&out, byte(by), byte(rand.int_max(2)))
		if by == 0 {
			ask_column(&out, {.Bytes, .Fold, .Number, .Bool, .Id, .Created, .Modified, .Order, .Author})
		}
	}
	append(&out, byte(rand.int_max(2)))
	zsp.write_varint(&out, u64(rand.int_max(20)))
	zsp.write_varint(&out, u64(rand.int_max(30)))
	totals := rand.int_max(4)
	zsp.write_varint(&out, u64(totals))
	for _ in 0 ..< totals {
		fn := Fn(1 + rand.int_max(5))
		append(&out, u8(fn))
		ask_column(&out, {.Number} if fn == .Sum else {.Bytes, .Fold, .Number, .Bool, .Id, .Created, .Modified, .Order, .Author})
		zsp.write_varint(&out, u64(rand.int_max(5)))
	}
	return out[:]
}

// ---------------------------------------------------------------- answers

// The same questions answered by something that shares no code with what is tested: slowly, and one way only.
@(private)
Plain :: struct {
	number: f64,
	bytes:  string,
	is_number: bool,
}

@(private)
plain_values :: proc(w: ^World, id: zsp.Id, c: ^Column) -> []Plain {
	out := make([dynamic]Plain, context.temp_allocator)
	n := &w.node
	switch c.kind {
	case .Created:
		append(&out, Plain{number = f64(id[0] & 0xffff_ffff), is_number = true})
	case .Modified:
		latest: u64
		scan := zsp.row_scan(&n.store, id)
		for cell in zsp.row_next(&n.store, &scan) {
			latest = max(latest, cell.stamp.time)
		}
		append(&out, Plain{number = f64(latest / 65536) / 1000, is_number = true})
	case .Order:
		scan := zsp.row_scan(&n.store, id, zsp.PLACE, zsp.PLACE_LAST)
		for cell in zsp.row_next(&n.store, &scan) {
			cell := cell
			if zsp.cell_list(&cell) == c.list {
				append(&out, Plain{number = f64(zsp.cell_order(&cell)), is_number = true})
			}
		}
	case .Author:
		scan := zsp.row_scan(&n.store, id, c.slot, c.slot)
		for cell in zsp.row_next(&n.store, &scan) {
			cell := cell
			by: zsp.By
			if !zsp.cell_open(&w.keys, &n.roster, &cell, &by) || by.member == 0 {
				continue
			}
			m := n.roster.members[by.member - 1]
			name := string(m.subject)
			for g in m.grants {
				if len(by.as) > 0 && .Vouch in g.rights && g.scope == zsp.row_scope(id) && (g.until == 0 || cell.stamp.time <= g.until) {
					name = string(by.as)
				}
			}
			if name != "" {
				append(&out, Plain{bytes = name})
			}
		}
	case .Bytes, .Fold, .Number, .Bool, .Id, .Words:
		raw, have := plain_slot(w, id, c.slot)
		if !have {
			return nil
		}
		take :: proc(out: ^[dynamic]Plain, k: Kind, raw: string) {
			#partial switch k {
			case .Bytes, .Words:
				append(out, Plain{bytes = raw})
			case .Fold:
				b := make([dynamic]byte, context.temp_allocator)
				fold(transmute([]byte)raw, &b)
				append(out, Plain{bytes = string(b[:])})
			case .Number:
				if len(raw) == 8 {
					append(out, Plain{number = transmute(f64)zsp.get_u64(transmute([]byte)raw), is_number = true})
				}
			case .Bool:
				if len(raw) == 1 {
					append(out, Plain{number = f64(min(raw[0], 1)), is_number = true})
				}
			case .Id:
				if len(raw) == 16 {
					append(out, Plain{bytes = raw})
				}
			}
		}
		if c.path == "" {
			take(&out, c.kind, raw)
			return out[:]
		}
		v, err := json.parse(transmute([]byte)raw, allocator = context.temp_allocator)
		if err != nil {
			return nil
		}
		reach :: proc(out: ^[dynamic]Plain, k: Kind, v: json.Value, path: string) {
			#partial switch x in v {
			case json.Array:
				for e in x {
					reach(out, k, e, path)
				}
			case json.Object:
				if path != "" {
					at := strings.index_byte(path, '.')
					name := path if at < 0 else path[:at]
					if e, ok := x[name]; ok {
						reach(out, k, e, "" if at < 0 else path[at + 1:])
					}
				}
			case json.String:
				if path == "" && (k == .Bytes || k == .Fold || k == .Words) {
					take(out, k, x)
				}
			case json.Float:
				if path == "" && k == .Number {
					append(out, Plain{number = x, is_number = true})
				}
			case json.Integer:
				if path == "" && k == .Number {
					append(out, Plain{number = f64(x), is_number = true})
				}
			case json.Boolean:
				if path == "" && k == .Bool {
					append(out, Plain{number = 1 if x else 0, is_number = true})
				}
			}
		}
		reach(&out, c.kind, v, c.path)
	}
	return out[:]
}

@(private)
plain_slot :: proc(w: ^World, id: zsp.Id, slot: zsp.Slot) -> (s: string, have: bool) {
	text: zsp.Text
	defer zsp.text_destroy(&text)
	scan := zsp.row_scan(&w.node.store, id, slot, slot)
	n := 0
	only: zsp.Cell
	for c in zsp.row_next(&w.node.store, &scan) {
		c := c
		if !zsp.cell_open(&w.keys, &w.node.roster, &c) {
			continue
		}
		n += 1
		only = c
		if slot == 20 {
			zsp.text_apply(&text, &c)
		}
	}
	if n == 0 {
		return
	}
	if slot != 20 {
		return string(only.body), true
	}
	out := make([dynamic]byte, context.temp_allocator)
	zsp.text_read(&text, &out)
	return string(out[:]), true
}

@(private)
plain_key :: proc(k: Kind, b: ^Bound) -> Plain {
	#partial switch k {
	case .Bytes, .Fold, .Author:
		return {bytes = string(b.bytes)}
	case .Id:
		return {bytes = string(b.bytes)}
	case .Bool:
		return {number = f64(b.key.hi), is_number = true}
	case .Order:
		return {number = f64(b.key.hi), is_number = true}
	}
	return {number = key_number(b.key), is_number = true}
}

@(private)
plain_less :: proc(a, b: Plain) -> bool {
	return a.number < b.number if a.is_number else a.bytes < b.bytes
}

@(private)
plain_same :: proc(a, b: Plain) -> bool {
	return a.number == b.number && a.bytes == b.bytes
}

@(private)
plain_edits :: proc(a, b: string) -> int {
	// Letters in or out, changed, or swapped with the next.
	if len(a) == 0 || len(b) == 0 {
		return len(a) + len(b)
	}
	d := make([][]int, len(a) + 1, context.temp_allocator)
	for &r, i in d {
		r = make([]int, len(b) + 1, context.temp_allocator)
		r[0] = i
	}
	for j in 0 ..= len(b) {
		d[0][j] = j
	}
	for i in 1 ..= len(a) {
		for j in 1 ..= len(b) {
			d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + int(a[i - 1] != b[j - 1]))
			if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
				d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
			}
		}
	}
	return d[len(a)][len(b)]
}

@(private)
plain_match :: proc(w: ^Word_Query, texts: []Plain) -> bool {
	if len(w.words) == 0 {
		return true
	}
	said := make([dynamic]string, context.temp_allocator)
	for t in texts {
		it := words(transmute([]byte)t.bytes)
		for x in words_next(&it) {
			x := x
			append(&said, strings.clone(string(x.bytes[:x.len]), context.temp_allocator))
		}
	}
	answers :: proc(w: ^Word_Query, i: int, said: string) -> bool {
		asked := string(w.words[i].bytes[:w.words[i].len])
		allowed := int(w.flags.edits)
		if len(asked) < 3 {
			allowed = 0
		} else if len(asked) < 6 {
			allowed = min(allowed, 1)
		}
		return said == asked || (w.flags.prefix && i == len(w.words) - 1 && strings.has_prefix(said, asked)) || (w.flags.inside && strings.contains(said, asked)) || (allowed > 0 && plain_edits(asked, said) <= allowed)
	}
	if w.mode == .Phrase {
		for at := 0; at + len(w.words) <= len(said); at += 1 {
			all := true
			for i in 0 ..< len(w.words) {
				all &&= answers(w, i, said[at + i])
			}
			if all {
				return true
			}
		}
		return false
	}
	some, every := false, true
	for i in 0 ..< len(w.words) {
		hit := false
		for s in said {
			hit ||= answers(w, i, s)
		}
		some ||= hit
		every &&= hit
	}
	return some if w.mode == .Any else every
}

@(private)
plain_holds :: proc(w: ^World, p: ^Pred, id: zsp.Id) -> bool {
	switch p.op {
	case .All:
		return true
	case .And:
		for &k in p.kids {
			if !plain_holds(w, &k, id) {
				return false
			}
		}
		return true
	case .Or:
		for &k in p.kids {
			if plain_holds(w, &k, id) {
				return true
			}
		}
		return false
	case .Not:
		return !plain_holds(w, &p.kids[0], id)
	case .Range:
		b := &p.range
		for v in plain_values(w, id, &p.col) {
			lo, hi := plain_key(p.col.kind, &b.lo), plain_key(p.col.kind, &b.hi)
			if b.has_lo && (plain_less(v, lo) || (!b.lo_in && plain_same(v, lo))) {
				continue
			}
			if b.has_hi && (plain_less(hi, v) || (!b.hi_in && plain_same(v, hi))) {
				continue
			}
			return true
		}
	case .In:
		for v in plain_values(w, id, &p.col) {
			for &b in p.set {
				if plain_same(v, plain_key(p.col.kind, &b)) {
					return true
				}
			}
		}
	case .Prefix:
		for v in plain_values(w, id, &p.col) {
			if strings.has_prefix(v.bytes, string(p.bytes)) {
				return true
			}
		}
	case .Has:
		for v in plain_values(w, id, &p.col) {
			if strings.contains(v.bytes, string(p.bytes)) {
				return true
			}
		}
	case .Exists:
		return len(plain_values(w, id, &p.col)) > 0
	case .Match:
		return plain_match(&p.words, plain_values(w, id, &p.col))
	case .List:
		c := Column{kind = .Order, list = p.list}
		return len(plain_values(w, id, &c)) > 0
	case .Ids:
		return slice.contains(p.ids, id)
	case .Ref:
		for v in plain_values(w, id, &p.col) {
			for other in w.rows {
				if zsp.row_scope(other) == p.scope && plain_there(w, other) && v.bytes == plain_id(other) && plain_holds(w, &p.kids[0], other) {
					return true
				}
			}
		}
	case .Back:
		n: u64
		for other in w.rows {
			if zsp.row_scope(other) == p.scope && plain_there(w, other) {
				for v in plain_values(w, other, &p.col) {
					if v.bytes == plain_id(id) && plain_holds(w, &p.kids[0], other) {
						n += 1
					}
				}
			}
		}
		return n >= p.min && n <= p.max
	}
	return false
}

@(private)
plain_id :: proc(id: zsp.Id) -> string {
	b := make([]byte, 16, context.temp_allocator)
	zsp.put_u64(b, id[0])
	zsp.put_u64(b[8:], id[1])
	return string(b)
}

@(private)
plain_there :: proc(w: ^World, id: zsp.Id) -> bool {
	placed := false
	scan := zsp.row_scan(&w.node.store, id)
	for c in zsp.row_next(&w.node.store, &scan) {
		if c.kind == .Grave {
			return false
		}
		placed ||= c.kind == .Place
	}
	return placed
}

// How two rows stand, from what they hold.
@(private)
plain_compare :: proc(w: ^World, q: ^Query, a, b: ^Sorted) -> int {
	for &o in q.order {
		c := 0
		switch o.by {
		case .Relevance:
			c = -1 if a.hit.score > b.hit.score else 1 if a.hit.score < b.hit.score else 0
		case .Created:
			c = -1 if id_less(a.hit.id, b.hit.id) else 1 if id_less(b.hit.id, a.hit.id) else 0
		case .Column:
			if o.col.kind == .Created {
				c = -1 if id_less(a.hit.id, b.hit.id) else 1 if id_less(b.hit.id, a.hit.id) else 0
				break
			}
			pick :: proc(all: []Plain, most: bool) -> (best: Plain) {
				for v, i in all {
					if i == 0 || (plain_less(best, v) if most else plain_less(v, best)) {
						best = v
					}
				}
				return
			}
			va, vb := plain_values(w, a.hit.id, &o.col), plain_values(w, b.hit.id, &o.col)
			if len(va) == 0 || len(vb) == 0 {
				if len(va) != len(vb) && (len(va) == 0) != (len(vb) == 0) {
					return 1 if len(va) == 0 else -1
				}
				continue
			}
			x, y := pick(va, o.desc), pick(vb, o.desc)
			c = -1 if plain_less(x, y) else 1 if plain_less(y, x) else 0
		}
		if c != 0 {
			return -c if o.desc else c
		}
	}
	return -1 if id_less(a.hit.id, b.hit.id) else 1 if id_less(b.hit.id, a.hit.id) else 0
}

@(private)
check_index :: proc(t: ^testing.T, w: ^World) {
	for s in w.x.scopes {
		there := 0
		for id in w.rows {
			if zsp.row_scope(id) != s.id {
				continue
			}
			row, known := row_number(s, id)
			testing.expect_value(t, known, id_there(&w.node, id))
			there += 1 if known else 0
			if !known {
				continue
			}
			back, ok := row_id(s, row)
			testing.expect(t, ok && back == id && set_has(&s.all, row))
			for h in s.columns {
				runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
				r := Row{n = &w.node, id = id}
				if h.kind != .Words {
					got, want := held_values(h, row), row_values(&r, h)
					testing.expectf(t, slice.equal(got, want), "%v: %v is not %v", h.column, got, want)
				}
			}
		}
		testing.expect_value(t, s.all.count, there)
		testing.expect_value(t, tree_total(&w.x, s.ids).count, there)
		testing.expect_value(t, tree_total(&w.x, s.rows).count, there)
		for h in s.columns {
			if h.kind != .Words {
				testing.expect_value(t, tree_total(&w.x, h.by_row).count, tree_total(&w.x, h.by_key).count)
			}
			Ghosts :: struct {
				s: ^Scope,
				n: int,
			}
			g := Ghosts{s = s}
			tree_each(&w.x, h.by_row, KEY_MIN, KEY_MAX, &g, proc(data: rawptr, e: ^Entry) {
				g := (^Ghosts)(data)
				g.n += 0 if set_has(&g.s.all, u32(e.key.hi >> 32)) else 1
			})
			testing.expect_value(t, g.n, 0)
		}
	}
	testing.expect(t, !w.x.failed)
}

@(private)
check_query :: proc(t: ^testing.T, w: ^World, source: []byte) -> bool {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	q, ok := query_parse(source)
	testing.expect(t, ok)
	index_follow(&w.x)
	query_prepare(&w.x, &q)
	// Going over everything may be in the middle of being changed.
	for !index_step(&w.x, 1 + rand.int_max(40)) {
		if rand.int_max(6) == 0 {
			world_write(t, w)
		}
	}
	testing.expect(t, query_ready(&w.x, &q))
	s := index_scope(&w.x, q.scope)
	got := pred_rows(s, &q.where_)
	defer set_destroy(&got)
	want := make([dynamic]zsp.Id, context.temp_allocator)
	for id in w.rows {
		if zsp.row_scope(id) != q.scope || !id_there(&w.node, id) {
			continue
		}
		r := Row{n = &w.node, id = id}
		holds := plain_holds(w, &q.where_, id)
		testing.expect_value(t, pred_cells(&q.where_, &r), holds)
		if holds {
			append(&want, id)
		}
		row, _ := row_number(s, id)
		if set_has(&got, row) != holds || pred_holds(s, &q.where_, row) != holds {
			testing.expectf(t, false, "of %v: the cells say %v, the index %v, and asked of the row %v", q.where_, holds, set_has(&got, row), pred_holds(s, &q.where_, row))
			return false
		}
	}
	testing.expect_value(t, got.count, len(want))
	testing.expect(t, pred_most(s, &q.where_) >= len(want))

	// Order, against the same order put on all of them from the cells.
	scores := make(map[u32]f32, context.temp_allocator)
	for o in q.order {
		if o.by == .Relevance {
			rows_scores(s, &q, &got, &scores)
			break
		}
	}
	all := make([]Sorted, len(want), context.temp_allocator)
	for id, i in want {
		row, _ := row_number(s, id)
		all[i].hit = {row, id, scores[row]}
	}
	Both :: struct {
		w: ^World,
		q: ^Query,
	}
	both := Both{w, &q}
	context.user_ptr = &both
	slice.sort_by(all, proc(a, b: Sorted) -> bool {
		x := (^Both)(context.user_ptr)
		a, b := a, b
		return plain_compare(x.w, x.q, &a, &b) < 0
	})
	first := q.offset
	if q.from_end {
		first = max(len(all) - q.offset - q.limit, 0)
	}
	last := min(first + q.limit, len(all))
	if q.from_end {
		last = max(len(all) - q.offset, 0)
	}
	page := query_page(s, &q, &got)
	expected := all[min(first, len(all)):max(last, min(first, len(all)))]
	if len(page) != len(expected) {
		testing.expectf(t, false, "a page of %d, not %d: %v", len(page), len(expected), q.order)
		return false
	}
	for hit, i in page {
		if hit.id != expected[i].hit.id {
			testing.expectf(t, false, "page differs at %d of %d, of %d: order %v from_end %v offset %v", i, len(page), len(all), q.order, q.from_end, q.offset)
			return false
		}
	}

	totals := query_totals(s, &q, &got)
	for &a, i in q.totals {
		sum: f64
		least, most: Key
		n, have := 0, 0
		tally := make(map[Key]int, context.temp_allocator)
		strings := make(map[string]int, context.temp_allocator)
		least_of, most_of: string
		for id in want {
			r := Row{n = &w.node, id = id}
			values := row_values(&r, &a.col)
			have += 1 if len(values) > 0 else 0
			if kind_long(a.col.kind) {
				seen := make(map[string]bool, context.temp_allocator)
				for b in row_bytes(&r, &a.col) {
					if string(b) in seen {
						continue
					}
					seen[string(b)] = true
					first := len(strings) == 0
					strings[string(b)] += 1
					least_of = string(b) if first || string(b) < least_of else least_of
					most_of = string(b) if first || string(b) > most_of else most_of
				}
			}
			for v in values {
				sum += key_number(v.key)
				least = v.key if n == 0 || key_less(v.key, least) else least
				most = v.key if n == 0 || key_less(most, v.key) else most
				tally[v.key] += 1
				n += 1
			}
		}
		out := totals[i]
		good := false
		if a.held != nil && kind_long(a.col.kind) && (a.fn == .Min || a.fn == .Max || a.fn == .Facet) {
			good = out.some == (n > 0)
			least_count := max(int)
			for f in out.facets {
				v := string(facet_bytes(s, &a, f))
				if a.fn == .Facet {
					good &&= strings[v] == f.count && f.count <= least_count
					least_count = f.count
					continue
				}
				good &&= v == (least_of if a.fn == .Min else most_of)
			}
			if a.fn == .Facet {
				good &&= int(out.number) == len(strings) && len(out.facets) == min(a.top, len(strings))
			} else {
				good &&= len(out.facets) == (1 if n > 0 else 0)
			}
			if !good {
				testing.expectf(t, false, "%v: %v is not right (%v)", a.fn, out, strings)
				return false
			}
			continue
		}
		switch a.fn {
		case .Sum:
			good = abs(out.number - sum) < 1e-6 && out.some == (n > 0)
		case .Min:
			good = out.some == (n > 0) && (n == 0 || out.facets[0].key == least)
		case .Max:
			good = out.some == (n > 0) && (n == 0 || out.facets[0].key == most)
		case .Count:
			good = int(out.number) == have
		case .Facet:
			good = int(out.number) == len(tally)
			for f, j in out.facets {
				good &&= tally[f.key] == f.count && (j == 0 || out.facets[j - 1].count >= f.count)
			}
			good &&= len(out.facets) == min(a.top, len(tally))
		}
		if !good {
			testing.expectf(t, false, "%v: %v is not right (sum %v, %d have it)", a, out, sum, have)
			return false
		}
	}
	return true
}

@(test)
answers_match_the_cells :: proc(t: ^testing.T) {
	SEEDS :: #config(ZSP_FIND_SEEDS, 6)
	FIRST :: #config(ZSP_FIND_FIRST, 0)
	for seed in FIRST ..< FIRST + SEEDS {
		state := rand.create(u64(seed) + 1000)
		context.random_generator = rand.default_random_generator(&state)
		w: World
		world_make(t, &w)
		defer world_destroy(&w)
		for _ in 0 ..< 20 {
			world_write(t, &w)
		}
		big := seed % 3 == 2
		for step in 0 ..< 120 {
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
			many_4 := (1 + rand.int_max(400 if big && step % 20 == 0 else 12))
			for _ in 0 ..< many_4 {
				world_write(t, &w)
			}
			source := ask(&w)
			if !check_query(t, &w, source) {
				fmt.println("seed", seed, "step", step, "big", big)
				return
			}
			switch rand.int_max(25) {
			case 0:
				index_finish(&w.x)
				check_index(t, &w)
			case 1:
				testing.expect(t, zsp.store_sync(&w.node.store))
				index_finish(&w.x)
				testing.expect(t, index_save(&w.x))
			case 2:
				// A stop, and a start from what was last saved, whenever that was.
				kept := w.x.generation
				world_stop(&w)
				world_start(t, &w)
				testing.expect_value(t, w.x.generation, kept) // what was saved is found
			case 3:
				testing.expect(t, zsp.store_checkpoint(&w.node.store))
			case 5, 6:
				world_rename(t, &w)
			case 4:
				// A column nobody asks of any longer.
				for s in w.x.scopes {
					if len(s.columns) > 0 {
						index_drop(&w.x, rand.choice(s.columns[:]))
						break
					}
				}
			}
			if testing.failed(t) {
				fmt.println("seed", seed, "step", step)
				return
			}
		}
		index_finish(&w.x)
		check_index(t, &w)
	}
}
