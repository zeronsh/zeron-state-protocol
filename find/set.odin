package find

import "core:math/bits"
import "core:slice"

// Sets of small numbers: in chunks of 65,536, each a list while it is sparse and a bitmap once it is not.
// A set costs what is in it, and two are combined sixty-four members at a time.

@(private)
SPARSE :: 4096

@(private)
Chunk :: struct {
	list:  [dynamic]u16, // ascending
	dense: ^[1024]u64, // instead, when not nil
	count: int,
}

Set :: struct {
	chunks: [dynamic]Chunk,
	count:  int,
}

set_destroy :: proc(s: ^Set) {
	for &c in s.chunks {
		chunk_free(&c)
	}
	delete(s.chunks)
	s^ = {}
}

@(private)
chunk_free :: proc(c: ^Chunk) {
	delete(c.list)
	free(c.dense)
	c^ = {}
}

set_clone :: proc(s: ^Set) -> (out: Set) {
	out.count = s.count
	resize(&out.chunks, len(s.chunks))
	for &c, i in s.chunks {
		o := &out.chunks[i]
		o.count = c.count
		if c.dense != nil {
			o.dense = new_clone(c.dense^)
		} else {
			append(&o.list, ..c.list[:])
		}
	}
	return
}

@(require_results)
set_has :: proc(s: ^Set, v: u32) -> bool {
	if int(v >> 16) >= len(s.chunks) {
		return false
	}
	c := &s.chunks[v >> 16]
	low := u16(v)
	if c.dense != nil {
		return c.dense[low >> 6] >> (low & 63) & 1 != 0
	}
	_, found := slice.binary_search(c.list[:], low)
	return found
}

// Whether it was not there.
set_add :: proc(s: ^Set, v: u32) -> bool {
	for int(v >> 16) >= len(s.chunks) {
		append(&s.chunks, Chunk{})
	}
	c := &s.chunks[v >> 16]
	low := u16(v)
	if c.dense == nil {
		n := len(c.list)
		if n == 0 || c.list[n - 1] < low {
			if n < SPARSE {
				append(&c.list, low)
				c.count += 1
				s.count += 1
				return true
			}
		} else {
			at, found := slice.binary_search(c.list[:], low)
			if found {
				return false
			}
			if n < SPARSE {
				inject_at(&c.list, at, low)
				c.count += 1
				s.count += 1
				return true
			}
		}
		chunk_thicken(c)
	}
	bit := u64(1) << (low & 63)
	if c.dense[low >> 6] & bit != 0 {
		return false
	}
	c.dense[low >> 6] |= bit
	c.count += 1
	s.count += 1
	return true
}

// Everything below `n`, in an empty set.
set_fill :: proc(s: ^Set, n: u32) {
	resize(&s.chunks, int((n + 0xffff) >> 16))
	for &c, i in s.chunks {
		c.count = int(min(n - u32(i) << 16, 1 << 16))
		c.dense = new([1024]u64)
		for &w, j in c.dense {
			have := c.count - j * 64
			w = max(u64) if have >= 64 else (1 << uint(have) - 1 if have > 0 else 0)
		}
		chunk_thin(&c)
	}
	s.count = int(n)
}

// As set_add, for many: counts are not kept until set_settle.
@(private)
set_put :: #force_inline proc(s: ^Set, v: u32) #no_bounds_check {
	if int(v >> 16) < len(s.chunks) {
		c := &s.chunks[v >> 16]
		if c.dense != nil {
			c.dense[u16(v) >> 6] |= 1 << (v & 63)
			return
		}
	}
	set_add(s, v)
}

@(private)
set_settle :: proc(s: ^Set) {
	s.count = 0
	for &c in s.chunks {
		if c.dense != nil {
			chunk_count(&c)
		}
		s.count += c.count
	}
}

// Whether it was there.
set_remove :: proc(s: ^Set, v: u32) -> bool {
	if int(v >> 16) >= len(s.chunks) {
		return false
	}
	c := &s.chunks[v >> 16]
	low := u16(v)
	if c.dense != nil {
		bit := u64(1) << (low & 63)
		if c.dense[low >> 6] & bit == 0 {
			return false
		}
		c.dense[low >> 6] &~= bit
	} else {
		at, found := slice.binary_search(c.list[:], low)
		if !found {
			return false
		}
		ordered_remove(&c.list, at)
	}
	c.count -= 1
	s.count -= 1
	chunk_thin(c)
	return true
}

@(private)
chunk_thicken :: proc(c: ^Chunk) {
	c.dense = new([1024]u64)
	for v in c.list {
		c.dense[v >> 6] |= 1 << (v & 63)
	}
	delete(c.list)
	c.list = {}
}

@(private)
chunk_thin :: proc(c: ^Chunk) {
	if c.dense == nil || c.count > SPARSE / 2 {
		return
	}
	for w, i in c.dense {
		w := w
		for w != 0 {
			append(&c.list, u16(i << 6 + int(bits.trailing_zeros(w))))
			w &= w - 1
		}
	}
	free(c.dense)
	c.dense = nil
}

@(private)
chunk_count :: proc(c: ^Chunk) {
	c.count = 0
	for w in c.dense {
		c.count += int(bits.count_ones(w))
	}
}

// Keeps what is in both.
set_and :: proc(s, o: ^Set) {
	s.count = 0
	for &c, i in s.chunks {
		if i >= len(o.chunks) || o.chunks[i].count == 0 {
			chunk_free(&c)
			continue
		}
		d := &o.chunks[i]
		switch {
		case c.dense != nil && d.dense != nil:
			for &w, j in c.dense {
				w &= d.dense[j]
			}
			chunk_count(&c)
			chunk_thin(&c)
		case c.dense != nil:
			kept: [dynamic]u16
			for v in d.list {
				if c.dense[v >> 6] >> (v & 63) & 1 != 0 {
					append(&kept, v)
				}
			}
			free(c.dense)
			c.dense, c.list, c.count = nil, kept, len(kept)
		case:
			n, j := 0, 0
			for v in c.list {
				has: bool
				if d.dense != nil {
					has = d.dense[v >> 6] >> (v & 63) & 1 != 0
				} else {
					for j < len(d.list) && d.list[j] < v {
						j += 1
					}
					has = j < len(d.list) && d.list[j] == v
				}
				if has {
					c.list[n] = v
					n += 1
				}
			}
			resize(&c.list, n)
			c.count = n
		}
		s.count += c.count
	}
}

// Adds what is in the other.
set_or :: proc(s, o: ^Set) {
	for len(s.chunks) < len(o.chunks) {
		append(&s.chunks, Chunk{})
	}
	for &d, i in o.chunks {
		c := &s.chunks[i]
		if d.count == 0 {
			continue
		}
		s.count -= c.count
		if c.dense == nil && (d.dense != nil || c.count + d.count > SPARSE) {
			chunk_thicken(c)
		}
		switch {
		case c.dense != nil && d.dense != nil:
			for &w, j in c.dense {
				w |= d.dense[j]
			}
			chunk_count(c)
		case c.dense != nil:
			for v in d.list {
				c.dense[v >> 6] |= 1 << (v & 63)
			}
			chunk_count(c)
			chunk_thin(c)
		case:
			merged := make([dynamic]u16, 0, c.count + d.count)
			a, b := 0, 0
			for a < len(c.list) || b < len(d.list) {
				switch {
				case b == len(d.list) || (a < len(c.list) && c.list[a] < d.list[b]):
					append(&merged, c.list[a])
					a += 1
				case a == len(c.list) || d.list[b] < c.list[a]:
					append(&merged, d.list[b])
					b += 1
				case:
					append(&merged, c.list[a])
					a += 1
					b += 1
				}
			}
			delete(c.list)
			c.list, c.count = merged, len(merged)
		}
		s.count += c.count
	}
}

// Takes away what is in the other.
set_and_not :: proc(s, o: ^Set) {
	for &c, i in s.chunks[:min(len(s.chunks), len(o.chunks))] {
		d := &o.chunks[i]
		if c.count == 0 || d.count == 0 {
			continue
		}
		s.count -= c.count
		if c.dense != nil {
			if d.dense != nil {
				for &w, j in c.dense {
					w &~= d.dense[j]
				}
			} else {
				for v in d.list {
					c.dense[v >> 6] &~= 1 << (v & 63)
				}
			}
			chunk_count(&c)
			chunk_thin(&c)
		} else {
			n, j := 0, 0
			for v in c.list {
				has: bool
				if d.dense != nil {
					has = d.dense[v >> 6] >> (v & 63) & 1 != 0
				} else {
					for j < len(d.list) && d.list[j] < v {
						j += 1
					}
					has = j < len(d.list) && d.list[j] == v
				}
				if !has {
					c.list[n] = v
					n += 1
				}
			}
			resize(&c.list, n)
			c.count = n
		}
		s.count += c.count
	}
}

// Walks a set in order.
Set_Iterator :: struct {
	s:     ^Set,
	chunk: int,
	at:    int, // in the list, or the word
	word:  u64,
	begun: bool,
}

@(require_results)
set_iterator :: proc(s: ^Set) -> Set_Iterator {
	return {s = s}
}

@(require_results)
set_next :: proc(it: ^Set_Iterator) -> (v: u32, ok: bool) {
	for it.chunk < len(it.s.chunks) {
		c := &it.s.chunks[it.chunk]
		high := u32(it.chunk) << 16
		if c.dense == nil {
			if it.at < len(c.list) {
				it.at += 1
				return high | u32(c.list[it.at - 1]), true
			}
		} else {
			if !it.begun {
				it.begun = true
				it.word = c.dense[0]
			}
			for it.word == 0 && it.at < 1023 {
				it.at += 1
				it.word = c.dense[it.at]
			}
			if it.word != 0 {
				low := u32(it.at) << 6 + u32(bits.trailing_zeros(it.word))
				it.word &= it.word - 1
				return high | low, true
			}
		}
		it.chunk += 1
		it.at, it.begun = 0, false
	}
	return
}
