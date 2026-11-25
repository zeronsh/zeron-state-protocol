package find

// Values by number, eight bytes each, in pages found by a tree: what is asked for by the thousand is had without
// being looked for. Zero is nothing.

Array :: struct {
	blocks: Tree, // number of the block, and its page
}

@(private)
PER_PAGE :: LEAF_ROOM / 8

@(private)
array_page :: proc(p: ^Pager, a: Array, block: u32) -> ^Page {
	no, ok := tree_get(p, a.blocks, {u64(block), 0}, 0)
	return page_get(p, u32(no)) if ok else nil
}

@(private)
array_values :: proc(pg: ^Page) -> []u64 {
	return ([^]u64)(&pg.data)[:PER_PAGE]
}

@(require_results)
array_get :: proc(p: ^Pager, a: Array, i: u32) -> u64 {
	pg := array_page(p, a, i / PER_PAGE)
	return array_values(pg)[i % PER_PAGE] if pg != nil else 0
}

array_set :: proc(p: ^Pager, a: ^Array, i: u32, v: u64) {
	key := Key{u64(i / PER_PAGE), 0}
	no, ok := tree_get(p, a.blocks, key, 0)
	pg: ^Page
	owned: u32
	if ok {
		owned, pg = page_own(p, u32(no))
	} else {
		owned, pg = page_new(p)
	}
	array_values(pg)[i % PER_PAGE] = v
	if !ok || owned != u32(no) {
		tree_apply(p, &a.blocks, {{entry = {key, 0, u64(owned)}}})
	}
}

array_clear :: proc(p: ^Pager, a: ^Array) {
	pages := make([dynamic]u32)
	defer delete(pages)
	array_pages(p, a^, &pages)
	for no in pages {
		page_drop(p, no)
	}
	tree_clear(p, &a.blocks)
}

@(private)
array_pages :: proc(p: ^Pager, a: Array, out: ^[dynamic]u32) {
	tree_each(p, a.blocks, KEY_MIN, KEY_MAX, out, proc(data: rawptr, e: ^Entry) {
		append((^[dynamic]u32)(data), u32(e.val))
	})
}

// The low halves of the values of many, less one, in a set; and those that are nothing left out.
array_rows :: proc(p: ^Pager, a: Array, of: ^Set, out: ^Set) {
	it := set_iterator(of)
	values: []u64
	block := max(u32)
	for i in set_next(&it) {
		if i / PER_PAGE != block {
			block = i / PER_PAGE
			pg := array_page(p, a, block)
			values = array_values(pg) if pg != nil else nil
		}
		if values != nil {
			if v := values[i % PER_PAGE]; v != 0 {
				set_put(out, u32(v) - 1)
			}
		}
	}
	set_settle(out)
}
