package find

import "core:unicode"
import "core:unicode/utf8"
import "../zsp"

// Words, as they are looked for: without case, without the marks over common letters, and where a script
// writes no spaces, in pairs of characters.

WORD_MAX :: 64 // bytes of a word that count

Word :: struct {
	bytes: [WORD_MAX]byte,
	len:   int,
}

Words :: struct {
	s:    []byte,
	pos:  int,
	last: rune, // of an unspaced script, when there was one just before
	lone: bool, // and it has not yet been in a pair
}

words :: proc(s: []byte) -> Words {
	return {s = s}
}

@(private)
is_word :: proc(r: rune) -> bool {
	return r < 128 && ((r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')) || (r >= 128 && (unicode.is_letter(r) || unicode.is_digit(r)))
}

@(private)
is_mark :: proc(r: rune) -> bool {
	return r >= 0x300 && r <= 0x36f
}

// Scripts written without spaces between words.
@(private)
is_unspaced :: proc(r: rune) -> bool {
	switch r {
	case 0x0e00 ..= 0x0eff, 0x1000 ..= 0x109f, 0x1780 ..= 0x17ff, 0x3040 ..= 0x30ff, 0x3400 ..= 0x4dbf, 0x4e00 ..= 0x9fff, 0xf900 ..= 0xfaff, 0xff66 ..= 0xff9d, 0x20000 ..= 0x3ffff:
		return true
	}
	return false
}

// À Á Â Ã Ä Å Æ Ç …, from 0xc0, as what they are without their marks; a dot where they are not that.
@(private)
LATIN :: "AAAAAA.CEEEEIIII.NOOOOO.OUUUUY..aaaaaa.ceeeeiiii.nooooo.ouuuuy.yAaAaAaCcCcCcCcDdDdEeEeEeEeEeGgGgGgGgHhHhIiIiIiIiIi..JjKk.LlLlLlLlLlNnNnNn...OoOoOo..RrRrRrSsSsSsSsTtTtTtUuUuUuUuUuUuWwYyYZzZzZz."

@(private)
rune_fold :: proc(r: rune) -> rune {
	r := r
	switch {
	case r < 128:
		return r + 32 if r >= 'A' && r <= 'Z' else r
	case r >= 0xc0 && int(r) < 0xc0 + len(LATIN):
		latin := LATIN
		if c := latin[r - 0xc0]; c != '.' {
			r = rune(c)
		}
	case r >= 0xff01 && r <= 0xff5e:
		r -= 0xfee0 // full width
	}
	return unicode.to_lower(r)
}

@(private)
word_push :: proc(w: ^Word, r: rune) {
	b, n := utf8.encode_rune(r)
	if w.len + n <= WORD_MAX {
		copy(w.bytes[w.len:], b[:n])
		w.len += n
	}
}

@(require_results)
words_next :: proc(it: ^Words) -> (w: Word, ok: bool) {
	for it.pos < len(it.s) {
		r, n := utf8.decode_rune(it.s[it.pos:])
		if is_unspaced(r) && is_word(r) || (is_unspaced(r) && it.last != 0) {
			r = rune_fold(r)
			it.pos += n
			was := it.last
			it.last = r
			if was != 0 {
				it.lone = false
				word_push(&w, was)
				word_push(&w, r)
				return w, true
			}
			it.lone = true
			continue
		}
		if it.last != 0 {
			was, lone := it.last, it.lone
			it.last, it.lone = 0, false
			if lone {
				word_push(&w, was)
				return w, true
			}
		}
		if !is_word(r) {
			it.pos += n
			continue
		}
		for it.pos < len(it.s) {
			r, n = utf8.decode_rune(it.s[it.pos:])
			inside := is_word(r) && !is_unspaced(r)
			// An apostrophe between letters is not the end of the word, and not a part of it.
			if (r == '\'' || r == 0x2019) && it.pos + n < len(it.s) {
				next, _ := utf8.decode_rune(it.s[it.pos + n:])
				if is_word(next) && !is_unspaced(next) {
					it.pos += n
					continue
				}
			}
			if !inside && !is_mark(r) {
				break
			}
			if inside {
				word_push(&w, rune_fold(r))
			}
			it.pos += n
		}
		return w, true
	}
	if it.last != 0 {
		was, lone := it.last, it.lone
		it.last, it.lone = 0, false
		if lone {
			word_push(&w, was)
			return w, true
		}
	}
	return
}

// Text without case or marks, for comparing.
fold :: proc(s: []byte, into: ^[dynamic]byte) {
	for pos := 0; pos < len(s); {
		if s[pos] < 128 {
			append(into, s[pos] + 32 if s[pos] >= 'A' && s[pos] <= 'Z' else s[pos])
			pos += 1
			continue
		}
		r, n := utf8.decode_rune(s[pos:])
		if r == utf8.RUNE_ERROR && n == 1 {
			append(into, s[pos]) // not text, and left as it is
		} else if !is_mark(r) {
			b, m := utf8.encode_rune(rune_fold(r))
			append(into, ..b[:m])
		}
		pos += n
	}
}

// The first sixteen bytes, as a key; and whether that is not all there is to it.
@(require_results)
bytes_key :: proc(s: []byte) -> (k: Key, long: bool) {
	b: [16]byte
	n := copy(b[:], s)
	// Trailing zeroes look like the end.
	long = len(s) > 16 || (n > 0 && s[n - 1] == 0)
	return {zsp.get_u64(b[:]), zsp.get_u64(b[8:])}, long
}
