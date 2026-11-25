package find

import "core:time"
import "../zsp"

// Texts that are being edited, kept open: what is written in one is put in it, and what it changes is said, without the rest
// being read. Few are kept, and none for long.

HOT :: 4
HOT_LEAST :: #config(ZSP_FIND_HOT, 16 << 10) // bytes a text takes, below which it is as well read again
HOT_MOST :: 4 << 20 // bytes of all of them
HOT_FOR :: 60 * time.Second // since it was last written in

@(private)
Hot :: struct {
	id:    zsp.Id,
	slot:  zsp.Slot,
	text:  zsp.Text,
	level: bool, // it is what the index was last told of
	used:  time.Tick,
}

// Pieces of one text that have come, and bundles.
@(private)
Arrived :: struct {
	slot:   zsp.Slot,
	count:  int, // more than there is room for: it is not known which
	cells:  [8]struct {
		stamp: zsp.Stamp,
		kind:  zsp.Kind,
	},
}

@(private)
hot_find :: proc(x: ^Index, id: zsp.Id, slot: zsp.Slot) -> ^Hot {
	for h in x.hot {
		if h.id == id && h.slot == slot {
			return h
		}
	}
	return nil
}

@(private)
hot_drop :: proc(x: ^Index, h: ^Hot) {
	for other, i in x.hot {
		if other == h {
			unordered_remove(&x.hot, i)
			break
		}
	}
	zsp.text_destroy(&h.text)
	free(h)
}

@(private)
hot_clear :: proc(x: ^Index) {
	for len(x.hot) > 0 {
		hot_drop(x, x.hot[0])
	}
}

// Keeps a text, whose it then is.
@(private)
hot_keep :: proc(x: ^Index, id: zsp.Id, slot: zsp.Slot, text: ^zsp.Text) {
	size := zsp.text_size(text)
	if size < HOT_LEAST || size > HOT_MOST {
		zsp.text_destroy(text)
		return
	}
	all := size
	for h in x.hot {
		all += zsp.text_size(&h.text)
	}
	for len(x.hot) > 0 && (all > HOT_MOST || len(x.hot) == HOT) {
		oldest := x.hot[0]
		for h in x.hot {
			if time.tick_diff(h.used, oldest.used) > 0 {
				oldest = h
			}
		}
		all -= zsp.text_size(&oldest.text)
		hot_drop(x, oldest)
	}
	h := new(Hot)
	h^ = {id, slot, text^, true, time.tick_now()}
	append(&x.hot, h)
	text^ = {}
}

// Lets go of those that nobody has written in for a while. Returns when the next will have to be.
index_cool :: proc(x: ^Index, now: time.Tick) -> (next: Maybe(time.Tick)) {
	#reverse for h in x.hot {
		due := time.tick_add(h.used, HOT_FOR)
		if time.tick_diff(now, due) <= 0 {
			hot_drop(x, h)
		} else if n, some := next.?; !some || time.tick_diff(due, n) > 0 {
			next = due
		}
	}
	return
}

// Rows are about to be read again where these slots have changed: what is kept of those is not as they are, until it is
// told what has come.
@(private)
hot_unsettle :: proc(x: ^Index, id: zsp.Id, slots: ^Slots) {
	for h in x.hot {
		if h.id == id && slots[h.slot >> 6] >> (u64(h.slot) & 63) & 1 != 0 {
			h.level = false
		}
	}
}

@(private)
hot_settle :: proc(x: ^Index, id: zsp.Id, there: bool) {
	#reverse for h in x.hot {
		if h.id == id && (!h.level || !there) {
			hot_drop(x, h)
		}
	}
}

// Words of a text that were, and are no more, or are now and were not.
@(private)
Delta :: struct {
	key: Key,
	by:  int,
}

@(private)
delta_add :: proc(all: ^[dynamic]Delta, text: []byte, by: int) {
	it := words(text)
	for w in words_next(&it) {
		w := w
		k, _ := bytes_key(w.bytes[:w.len])
		append(all, Delta{k, by})
	}
}

@(private)
text_deltas :: proc(text: ^zsp.Text, all: ^[dynamic]Delta) {
	zsp.text_changes(text, all, proc(data: rawptr, was, now: []byte) {
		all := (^[dynamic]Delta)(data)
		delta_add(all, was, -1)
		delta_add(all, now, 1)
	})
}

// What has changed in the words of a text, from what has come, where that can be told. Temporary memory.
@(private)
text_delta :: proc(h: ^Held, r: ^Row, hash: u64) -> (all: [dynamic]Delta, ok: bool) {
	x := h.scope.x
	new := r.new
	hot := hot_find(x, r.id, h.slot)
	if new == nil || new.slot != h.slot || new.count > len(new.cells) {
		return
	}
	come := new.cells[:new.count]
	all = make([dynamic]Delta, context.temp_allocator)
	if hot != nil {
		if hot.level {
			return // told already, for another column
		}
		zsp.text_follow(&hot.text)
		for c in come {
			// What is gone already went into a bundle, which has come too.
			cell := zsp.store_cell(&x.n.store, r.id, h.slot, c.kind, c.stamp) or_continue
			if !zsp.cell_open(x.n.keys, &x.n.roster, &cell) {
				return
			}
			if zsp.text_apply(&hot.text, &cell) == .Rebuild {
				return
			}
		}
		text_deltas(&hot.text, &all)
		hot.level, hot.used = true, time.tick_now()
		return all, true
	}

	// What it was is what there is without what has come, if that comes to what was read of it.
	text: zsp.Text
	defer zsp.text_destroy(&text)
	late := make([dynamic]zsp.Cell, context.temp_allocator)
	scan := zsp.row_scan(&x.n.store, r.id, h.slot, h.slot)
	for c in zsp.row_next(&x.n.store, &scan) {
		c := c
		is_late := false
		for l in come {
			is_late ||= l.stamp == c.stamp && l.kind == c.kind
		}
		if is_late && c.kind != .Piece {
			return // what it has in it was here before
		}
		if !zsp.cell_open(x.n.keys, &x.n.roster, &c) {
			continue
		}
		if is_late {
			c.body = make_copy(c.body)
			append(&late, c)
		} else {
			zsp.text_apply(&text, &c)
		}
	}
	was := make([dynamic]byte, context.temp_allocator)
	zsp.text_read(&text, &was)
	if words_hash(was[:]) != hash {
		return
	}
	zsp.text_follow(&text)
	for &c in late {
		if zsp.text_apply(&text, &c) == .Rebuild {
			return
		}
	}
	text_deltas(&text, &all)
	hot_keep(x, r.id, h.slot, &text)
	return all, true
}

@(private)
make_copy :: proc(b: []byte) -> []byte {
	out := make([]byte, len(b), context.temp_allocator)
	copy(out, b)
	return out
}

// Which words there are in a text, and how often, whatever their order: what each adds to it, it can be taken from.
@(private)
words_hash :: proc(text: []byte) -> (hash: u64) {
	it := words(text)
	for w in words_next(&it) {
		w := w
		k, _ := bytes_key(w.bytes[:w.len])
		hash += word_hash(k)
	}
	return
}

@(private)
word_hash :: #force_inline proc(k: Key) -> u64 {
	mix :: #force_inline proc(v: u64) -> u64 {
		v := v
		v = (v ~ v >> 30) * 0xbf58476d1ce4e5b9
		v = (v ~ v >> 27) * 0x94d049bb133111eb
		return v ~ v >> 31
	}
	return mix(mix(k.hi + 0x9e3779b97f4a7c15) ~ k.lo)
}
