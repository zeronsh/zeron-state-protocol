package find

import "core:slice"
import "core:strconv"
import "core:unicode/utf8"
import "../zsp"

// What can be asked about: a slot read some way, or something true of every row.

Kind :: enum u8 {
	Bytes    = 1, // compared as they are
	Fold     = 2, // as text, without case or marks
	Number   = 3, // eight bytes, big-endian, or a number in JSON
	Bool     = 4,
	Id       = 5, // of another row
	Words    = 6, // text, to be searched
	Created  = 7, // seconds, from the row's id
	Modified = 8, // seconds, from its latest stamp
	Order    = 9, // its place in a list
	Author   = 10, // whose what is in a slot is: whom those who wrote it go by
}

// A path reaches into JSON: names with dots between. An array along the way stands for all it holds.
Column :: struct {
	kind: Kind,
	slot: zsp.Slot,
	path: string,
	list: zsp.List, // of Order
}

@(require_results)
column_same :: proc(a, b: ^Column) -> bool {
	return a.kind == b.kind && a.slot == b.slot && a.path == b.path && a.list == b.list
}

@(require_results)
column_sorted :: proc(k: Kind) -> bool {
	return k != .Words
}

Value :: struct {
	key:  Key,
	rest: u64, // 0 if that is all there is of it; or else, a hash of the whole; or SEVERAL, of which one or more are longer
}

SEVERAL :: 1

// Whether a column's keys may be only how its values begin.
@(private)
kind_long :: proc(k: Kind) -> bool {
	return k == .Bytes || k == .Fold || k == .Author
}

// Whether what changed in a slot may change a column.
@(private)
column_reads :: proc(c: ^Column, slot: zsp.Slot) -> bool {
	switch c.kind {
	case .Bytes, .Fold, .Number, .Bool, .Id, .Words, .Author:
		return c.slot == slot
	case .Modified:
		return true
	case .Created:
		return false
	case .Order:
		return slot < zsp.DATA
	}
	return false
}

// A row's cells, opened as they are asked for. Temporary memory.
Row :: struct {
	n:     ^zsp.Node,
	x:     ^Index, // which may have some of it open
	id:    zsp.Id,
	slots: [8]struct {
		slot:  zsp.Slot,
		bytes: []byte,
		have:  bool,
	}, // lately read
	next:  int,
	new:   ^Arrived, // pieces that have come since it was last read, where that is known
}

// What a slot holds, as bytes: a value, or a text as it stands. Temporary memory.
row_slot :: proc(r: ^Row, slot: zsp.Slot) -> (bytes: []byte, have: bool) {
	for &s in r.slots[:min(r.next, len(r.slots))] {
		if s.slot == slot {
			return s.bytes, s.have
		}
	}
	if r.x != nil {
		if hot := hot_find(r.x, r.id, slot); hot != nil && hot.level {
			out := make([dynamic]byte, context.temp_allocator)
			zsp.text_read(&hot.text, &out)
			r.slots[r.next % len(r.slots)] = {slot, out[:], true}
			r.next += 1
			return out[:], true
		}
	}
	scan := zsp.row_scan(&r.n.store, r.id, slot, slot)
	only: zsp.Cell
	count := 0
	text: zsp.Text
	for c in zsp.row_next(&r.n.store, &scan) {
		c := c
		if !zsp.cell_open(r.n.keys, &r.n.roster, &c) {
			continue
		}
		count += 1
		if count == 1 {
			only = c
			continue
		}
		if count == 2 {
			zsp.text_apply(&text, &only)
		}
		zsp.text_apply(&text, &c)
	}
	switch {
	case count == 0:
	case count == 1 && only.kind == .Value:
		bytes, have = only.body, true
	case:
		if count == 1 {
			zsp.text_apply(&text, &only)
		}
		out := make([dynamic]byte, context.temp_allocator)
		zsp.text_read(&text, &out)
		bytes, have = out[:], true
	}
	zsp.text_destroy(&text)
	r.slots[r.next % len(r.slots)] = {slot, bytes, have}
	r.next += 1
	return
}

// Whom those who wrote what is in a slot go by, perhaps more than once. Temporary memory.
row_authors :: proc(r: ^Row, slot: zsp.Slot) -> [][]byte {
	out := make([dynamic][]byte, context.temp_allocator)
	scan := zsp.row_scan(&r.n.store, r.id, slot, slot)
	for c in zsp.row_next(&r.n.store, &scan) {
		c := c
		by: zsp.By
		if !zsp.cell_open(r.n.keys, &r.n.roster, &c, &by) {
			continue
		}
		_, subject, _ := zsp.cell_author(&r.n.roster, &c, by) or_continue
		if len(subject) > 0 {
			append(&out, slice.clone(subject, context.temp_allocator))
		}
	}
	return out[:]
}

// The values a row has in a column: none, one, or for what reaches into arrays any number. Ascending, each
// once. Temporary memory.
row_values :: proc(r: ^Row, c: ^Column) -> []Value {
	out := make([dynamic]Value, context.temp_allocator)
	switch c.kind {
	case .Created:
		append(&out, Value{key = number_key(f64(u32(r.id[0])))})
	case .Modified:
		latest: u64
		scan := zsp.row_scan(&r.n.store, r.id)
		for leaf in zsp.tree_next(&scan) {
			latest = max(latest, leaf.key[3])
		}
		append(&out, Value{key = number_key(f64(latest >> 16) / 1000)})
	case .Order:
		places := zsp.row_places(&r.n.store, r.id)
		for k in places.keys[:places.count] {
			if zsp.key_list(k) == c.list {
				append(&out, Value{key = {k[2], 0}})
			}
		}
	case .Words:
	case .Author:
		for subject in row_authors(r, c.slot) {
			append(&out, bytes_value(subject))
		}
	case .Bytes, .Fold, .Number, .Bool, .Id:
		bytes, have := row_slot(r, c.slot)
		if !have {
			return nil
		}
		if c.path == "" {
			value_add(&out, c.kind, bytes)
		} else {
			json_each(bytes, c.path, proc(data: rawptr, kind: Json, raw: []byte, c: ^Column) {
				json_value((^[dynamic]Value)(data), c.kind, kind, raw)
			}, &out, c)
		}
	}
	if len(out) > 1 {
		slice.sort_by(out[:], proc(a, b: Value) -> bool {return key_less(a.key, b.key)})
		n := 0
		for v in out {
			if n == 0 || out[n - 1].key != v.key {
				out[n] = v
				n += 1
			} else {
				out[n - 1].rest = v.rest if out[n - 1].rest == v.rest else SEVERAL
			}
		}
		resize(&out, n)
	}
	return out[:]
}

// What a value written by a client comes to. False when it is not one of its kind.
@(require_results)
value_key :: proc(kind: Kind, bytes: []byte) -> (v: Value, ok: bool) {
	switch kind {
	case .Bytes, .Author:
		v = bytes_value(bytes)
		return v, true
	case .Fold:
		folded := make([dynamic]byte, 0, len(bytes), context.temp_allocator)
		fold(bytes, &folded)
		v = bytes_value(folded[:])
		return v, true
	case .Number, .Created, .Modified:
		if len(bytes) == 8 {
			return {key = number_key(transmute(f64)zsp.get_u64(bytes))}, true
		}
	case .Bool:
		if len(bytes) == 1 {
			return {key = {1 if bytes[0] != 0 else 0, 0}}, true
		}
	case .Id:
		if len(bytes) == 16 {
			return {key = {zsp.get_u64(bytes), zsp.get_u64(bytes[8:])}}, true
		}
	case .Order:
		if len(bytes) == 8 {
			return {key = {zsp.get_u64(bytes), 0}}, true
		}
	case .Words:
	}
	return
}

@(private)
value_add :: proc(out: ^[dynamic]Value, kind: Kind, bytes: []byte) {
	if v, ok := value_key(kind, bytes); ok {
		append(out, v)
	}
}

// ---------------------------------------------------------------- JSON

Json :: enum u8 {
	String, // between its quotes, still escaped
	Number,
	True,
	False,
	Null,
	Object,
	Array,
}

// Calls `each` for every value a path reaches. What is not JSON reaches nothing.
json_each :: proc(s: []byte, path: string, each: proc(data: rawptr, kind: Json, raw: []byte, c: ^Column), data: rawptr, c: ^Column) {
	j := Json_Reader{s = s}
	json_walk(&j, path, each, data, c, 0)
}

@(private)
Json_Reader :: struct {
	s:   []byte,
	pos: int,
	bad: bool,
}

@(private)
json_space :: proc(j: ^Json_Reader) -> byte {
	for j.pos < len(j.s) {
		switch j.s[j.pos] {
		case ' ', '\t', '\n', '\r':
			j.pos += 1
		case:
			return j.s[j.pos]
		}
	}
	return 0
}

@(private)
json_string :: proc(j: ^Json_Reader) -> []byte {
	j.pos += 1
	from := j.pos
	for j.pos < len(j.s) {
		switch j.s[j.pos] {
		case '"':
			j.pos += 1
			return j.s[from:j.pos - 1]
		case '\\':
			j.pos += 1
		}
		j.pos += 1
	}
	j.bad = true
	return nil
}

@(private)
json_walk :: proc(j: ^Json_Reader, path: string, each: proc(data: rawptr, kind: Json, raw: []byte, c: ^Column), data: rawptr, c: ^Column, depth: int) {
	if depth > 64 {
		j.bad = true
	}
	first := json_space(j)
	if j.bad {
		return
	}
	// `path` is what remains to be reached, or a NUL when this is only being stepped over.
	skip := path == "\x00"
	switch first {
	case '{':
		j.pos += 1
		name, rest := path, ""
		for i in 0 ..< len(path) {
			if path[i] == '.' {
				name, rest = path[:i], path[i + 1:]
				break
			}
		}
		for !j.bad {
			switch json_space(j) {
			case '}':
				j.pos += 1
				return
			case ',':
				j.pos += 1
				continue
			case '"':
			case:
				j.bad = true
				return
			}
			key := json_string(j)
			if json_space(j) != ':' {
				j.bad = true
				return
			}
			j.pos += 1
			hit := !skip && path != "" && string(json_unescape(key)) == name
			json_walk(j, rest if hit else "\x00", each, data, c, depth + 1)
		}
	case '[':
		j.pos += 1
		for !j.bad {
			switch json_space(j) {
			case ']':
				j.pos += 1
				return
			case ',':
				j.pos += 1
				continue
			}
			json_walk(j, path, each, data, c, depth + 1)
		}
	case '"':
		raw := json_string(j)
		if !j.bad && path == "" {
			each(data, .String, raw, c)
		}
	case 0:
		j.bad = true
	case:
		from := j.pos
		for j.pos < len(j.s) {
			b := j.s[j.pos]
			if b == ',' || b == '}' || b == ']' || b == ' ' || b == '\n' || b == '\r' || b == '\t' {
				break
			}
			j.pos += 1
		}
		raw := j.s[from:j.pos]
		if len(raw) == 0 {
			j.bad = true
			return
		}
		if path != "" {
			return
		}
		switch string(raw) {
		case "true":
			each(data, .True, raw, c)
		case "false":
			each(data, .False, raw, c)
		case "null":
			each(data, .Null, raw, c)
		case:
			each(data, .Number, raw, c)
		}
	}
}

@(private)
json_value :: proc(out: ^[dynamic]Value, kind: Kind, is: Json, raw: []byte) {
	#partial switch is {
	case .String:
		text := json_unescape(raw)
		if kind == .Bytes || kind == .Fold || kind == .Id {
			value_add(out, kind, text)
		}
	case .Number:
		if v, ok := strconv.parse_f64(string(raw)); ok && kind == .Number {
			append(out, Value{key = number_key(v)})
		}
	case .True, .False:
		if kind == .Bool {
			append(out, Value{key = {1 if is == .True else 0, 0}})
		}
	}
}

// Temporary memory, when there was anything to unescape.
@(private)
json_unescape :: proc(raw: []byte) -> []byte {
	if !slice.contains(raw, '\\') {
		return raw
	}
	out := make([dynamic]byte, 0, len(raw), context.temp_allocator)
	hex4 :: proc(s: []byte) -> (r: rune, ok: bool) {
		if len(s) < 4 {
			return
		}
		v := strconv.parse_u64_of_base(string(s[:4]), 16) or_return
		return rune(v), true
	}
	for i := 0; i < len(raw); i += 1 {
		if raw[i] != '\\' || i + 1 >= len(raw) {
			append(&out, raw[i])
			continue
		}
		i += 1
		switch raw[i] {
		case 'n':
			append(&out, '\n')
		case 't':
			append(&out, '\t')
		case 'r':
			append(&out, '\r')
		case 'b':
			append(&out, '\b')
		case 'f':
			append(&out, '\f')
		case 'u':
			r, ok := hex4(raw[i + 1:])
			if !ok {
				continue
			}
			i += 4
			if r >= 0xd800 && r < 0xdc00 && i + 6 < len(raw) && raw[i + 1] == '\\' && raw[i + 2] == 'u' {
				if low, paired := hex4(raw[i + 3:]); paired && low >= 0xdc00 && low < 0xe000 {
					r = 0x10000 + (r - 0xd800) << 10 + (low - 0xdc00)
					i += 6
				}
			}
			b, n := utf8.encode_rune(r)
			append(&out, ..b[:n])
		case:
			append(&out, raw[i])
		}
	}
	return out[:]
}
