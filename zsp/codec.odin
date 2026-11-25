package zsp

// Writers append to a dynamic array. Readers never fail mid-way: they latch `bad` and yield zeroes,
// so a decoder checks once at the end.

Reader :: struct {
	buf: []byte,
	pos: int,
	bad: bool,
}

write_u8 :: proc(w: ^[dynamic]byte, v: u8) {
	append(w, v)
}

write_u64 :: proc(w: ^[dynamic]byte, v: u64) {
	b: [8]byte = ---
	put_u64(b[:], v)
	append(w, ..b[:])
}

write_pair :: proc(w: ^[dynamic]byte, v: $T/[2]u64) {
	write_u64(w, v[0])
	write_u64(w, v[1])
}

write_stamp :: proc(w: ^[dynamic]byte, s: Stamp) {
	write_u64(w, s.time)
	write_u64(w, s.salt)
}

write_varint :: proc(w: ^[dynamic]byte, v: u64) {
	v := v
	for v >= 0x80 {
		append(w, byte(v) | 0x80)
		v >>= 7
	}
	append(w, byte(v))
}

write_bytes :: proc(w: ^[dynamic]byte, b: []byte) {
	write_varint(w, u64(len(b)))
	append(w, ..b)
}

// Keys travel as a length and that many leading bytes; trailing zeroes are implied.
// The length 0xff is KEY_MAX.
write_key :: proc(w: ^[dynamic]byte, k: Key) {
	if k == KEY_MAX {
		append(w, 0xff)
		return
	}
	b: [40]byte = ---
	for v, i in k {
		put_u64(b[i * 8:], v)
	}
	n := 40
	for n > 0 && b[n - 1] == 0 {
		n -= 1
	}
	append(w, byte(n))
	append(w, ..b[:n])
}

// A key as the number of leading bytes it shares with the previous one, and the rest.
write_key_delta :: proc(w: ^[dynamic]byte, prev, k: Key) {
	a, b: [40]byte = ---, ---
	for i in 0 ..< 5 {
		put_u64(a[i * 8:], prev[i])
		put_u64(b[i * 8:], k[i])
	}
	n := 0
	for n < 40 && a[n] == b[n] {
		n += 1
	}
	append(w, byte(n))
	append(w, ..b[n:])
}

@(require_results)
read_key_delta :: proc(r: ^Reader, prev: Key) -> (k: Key) {
	b: [40]byte = ---
	for v, i in prev {
		put_u64(b[i * 8:], v)
	}
	n := int(read_u8(r))
	if n > 40 {
		r.bad = true
		return
	}
	copy(b[n:], read_take(r, 40 - n))
	for &v, i in k {
		v = get_u64(b[i * 8:])
	}
	return
}

write_cell :: proc(w: ^[dynamic]byte, c: ^Cell, same_row: bool) {
	append(w, byte(c.kind) | (0x80 if same_row else 0))
	if !same_row {
		write_pair(w, c.row)
	}
	append(w, byte(c.slot))
	write_stamp(w, c.stamp)
	write_bytes(w, c.body)
}

// Frames are a varint length and then that many bytes, the first of which is the message type.
@(require_results)
frame_begin :: proc(w: ^[dynamic]byte, type: Message) -> int {
	// Four bytes hold any length up to MAX_FRAME; padding a LEB128 varint is legal.
	append(w, 0, 0, 0, 0, byte(type))
	return len(w) - 1
}

frame_end :: proc(w: ^[dynamic]byte, start: int) {
	n := len(w) - start
	assert(n <= MAX_FRAME)
	if n < 0x80 { // the common case, tightened to one byte
		copy(w[start - 3:], w[start:])
		resize(w, len(w) - 3)
		w[start - 4] = byte(n)
		return
	}
	w[start - 4] = byte(n) | 0x80
	w[start - 3] = byte(n >> 7) | 0x80
	w[start - 2] = byte(n >> 14) | 0x80
	w[start - 1] = byte(n >> 21)
}

@(require_results)
read_take :: proc(r: ^Reader, n: int) -> []byte {
	if r.bad || n < 0 || n > len(r.buf) - r.pos {
		r.bad = true
		return nil
	}
	defer r.pos += n
	return r.buf[r.pos:][:n]
}

@(require_results)
read_u8 :: proc(r: ^Reader) -> u8 {
	b := read_take(r, 1)
	return b[0] if b != nil else 0
}

@(require_results)
read_u64 :: proc(r: ^Reader) -> u64 {
	b := read_take(r, 8)
	return get_u64(b) if b != nil else 0
}

@(require_results)
read_pair :: proc(r: ^Reader, $T: typeid/[2]u64) -> T {
	hi := read_u64(r)
	lo := read_u64(r)
	return {hi, lo}
}

@(require_results)
read_stamp :: proc(r: ^Reader) -> Stamp {
	time := read_u64(r)
	salt := read_u64(r)
	return {time, salt}
}

@(require_results)
read_varint :: proc(r: ^Reader) -> (v: u64) {
	for shift := uint(0); shift < 64; shift += 7 {
		b := read_u8(r)
		v |= u64(b & 0x7f) << shift
		if b < 0x80 {
			return v
		}
	}
	r.bad = true
	return 0
}

// A varint bounded by the bytes that remain, for counts and lengths.
@(require_results)
read_count :: proc(r: ^Reader) -> int {
	v := read_varint(r)
	if v > u64(len(r.buf) - r.pos) {
		r.bad = true
		return 0
	}
	return int(v)
}

@(require_results)
read_bytes :: proc(r: ^Reader) -> []byte {
	return read_take(r, read_count(r))
}

@(require_results)
read_key :: proc(r: ^Reader) -> (k: Key) {
	n := read_u8(r)
	if n == 0xff {
		return KEY_MAX
	}
	if n > 40 {
		r.bad = true
		return
	}
	b: [40]byte
	copy(b[:], read_take(r, int(n)))
	for &v, i in k {
		v = get_u64(b[i * 8:])
	}
	return
}

// Decodes the cell following one that belonged to `prev`.
@(require_results)
read_cell :: proc(r: ^Reader, prev: Id) -> (c: Cell, ok: bool) {
	tag := read_u8(r)
	c.kind = Kind(tag & 0x7f)
	c.row = prev if tag & 0x80 != 0 else read_pair(r, Id)
	c.slot = Slot(read_u8(r))
	c.stamp = read_stamp(r)
	c.body = read_bytes(r)
	ok = !r.bad && cell_valid(&c)
	r.bad = !ok
	return
}

@(require_results)
read_done :: proc(r: ^Reader) -> bool {
	return !r.bad && r.pos == len(r.buf)
}
