package zsp

// A copy-on-write B+tree whose branches carry the count and fingerprint sum of their subtrees.
//
// One pager hosts several trees. Pages are never modified on disk: a changed page moves to a free
// page number, and the header flip at checkpoint makes the new roots durable atomically.

PAGE_SIZE :: 4096
LEAF_CAP :: 72
BRANCH_CAP :: 63

Page :: struct #align (8) {
	level:   u16, // zero for leaves
	count:   u16,
	_:       u32,
	_:       u64,
	using _: struct #raw_union {
		leaf:   [LEAF_CAP]Leaf,
		branch: [BRANCH_CAP]Branch,
	},
}
#assert(size_of(Page) <= PAGE_SIZE)

Leaf :: struct {
	key: Key,
	val: Print,
}

Branch :: struct {
	key:   Key, // smallest key the child may hold; the first is never consulted
	sum:   Print,
	count: u32,
	child: u32,
}

Sum :: struct {
	count: int,
	print: Print,
}

Pager :: struct {
	disk:    Disk,
	dirty:   map[u32]^Page,
	free:    [dynamic]u32, // reusable now
	pending: [dynamic]u32, // reusable once the checkpoint that abandoned them is durable
	next:    u32, // first page number never used
}

Tree :: struct {
	root: u32, // zero when empty
}

@(require_results)
page :: #force_inline proc(p: ^Pager, no: u32) -> ^Page {
	if len(p.dirty) != 0 {
		if pg, ok := p.dirty[no]; ok {
			return pg
		}
	}
	return p.disk.page(p.disk.data, no)
}

@(private)
page_new :: proc(p: ^Pager, level: u16) -> (no: u32, pg: ^Page) {
	if len(p.free) > 0 {
		no = pop(&p.free)
	} else {
		no = p.next
		p.next += 1
	}
	pg = new(Page)
	pg.level = level
	p.dirty[no] = pg
	return
}

@(private)
page_drop :: proc(p: ^Pager, no: u32) {
	if pg, ok := p.dirty[no]; ok {
		free(pg)
		delete_key(&p.dirty, no)
		append(&p.free, no)
	} else {
		append(&p.pending, no)
	}
}

// A writable version of the page, which may live under a new number.
@(private)
page_own :: proc(p: ^Pager, no: u32) -> (u32, ^Page) {
	if pg, ok := p.dirty[no]; ok {
		return no, pg
	}
	old := p.disk.page(p.disk.data, no)
	fresh, pg := page_new(p, 0)
	pg^ = old^
	append(&p.pending, no)
	return fresh, pg
}

// First leaf index whose key is not less than `key`.
@(private)
leaf_find :: proc(pg: ^Page, key: ^Key) -> int #no_bounds_check {
	lo, hi := 0, int(pg.count)
	for lo < hi {
		mid := (lo + hi) / 2
		if key_cmp(&pg.leaf[mid].key, key) < 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo
}

// Index of the child that would hold `key`.
@(private)
branch_find :: proc(pg: ^Page, key: ^Key) -> int #no_bounds_check {
	lo, hi := 1, int(pg.count)
	for lo < hi {
		mid := (lo + hi) / 2
		if key_cmp(&pg.branch[mid].key, key) <= 0 {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}

@(private)
page_sum :: proc(pg: ^Page) -> (s: Sum) #no_bounds_check {
	if pg.level == 0 {
		for &e in pg.leaf[:pg.count] {
			s.print += e.val
		}
		s.count = int(pg.count)
	} else {
		for &e in pg.branch[:pg.count] {
			s.print += e.sum
			s.count += int(e.count)
		}
	}
	return
}

@(private)
branch_of :: proc(key: Key, no: u32, pg: ^Page) -> Branch {
	s := page_sum(pg)
	return {key, s.print, u32(s.count), no}
}

@(require_results)
tree_get :: proc(p: ^Pager, t: Tree, key: Key) -> (val: Print, ok: bool) #no_bounds_check {
	key := key
	if t.root == 0 {
		return
	}
	pg := page(p, t.root)
	for pg.level > 0 {
		pg = page(p, pg.branch[branch_find(pg, &key)].child)
	}
	i := leaf_find(pg, &key)
	if i < int(pg.count) && pg.leaf[i].key == key {
		return pg.leaf[i].val, true
	}
	return
}

// Inserts or replaces.
tree_put :: proc(p: ^Pager, t: ^Tree, key: Key, val: Print) {
	key := key
	if t.root == 0 {
		no, pg := page_new(p, 0)
		pg.leaf[0] = {key, val}
		pg.count = 1
		t.root = no
		return
	}
	left, split, right := put(p, t.root, &key, val)
	t.root = left
	if right.child != 0 {
		no, pg := page_new(p, page(p, left).level + 1)
		pg.branch[0] = branch_of({}, left, page(p, left))
		pg.branch[1] = right
		pg.branch[1].key = split
		pg.count = 2
		t.root = no
	}
}

@(private)
put :: proc(p: ^Pager, no: u32, key: ^Key, val: Print) -> (left: u32, split: Key, right: Branch) {
	pg: ^Page
	left, pg = page_own(p, no)

	if pg.level == 0 {
		i := leaf_find(pg, key)
		n := int(pg.count)
		if i < n && pg.leaf[i].key == key^ {
			pg.leaf[i].val = val
			return
		}
		if n < LEAF_CAP {
			copy(pg.leaf[i + 1:n + 1], pg.leaf[i:n])
			pg.leaf[i] = {key^, val}
			pg.count += 1
			return
		}
		// Appending at the right edge leaves the full page full.
		at := n if i == n else n / 2
		r_no, r := page_new(p, 0)
		r.count = u16(copy(r.leaf[:], pg.leaf[at:n]))
		pg.count = u16(at)
		into, j := pg, i
		if i >= at {
			into, j = r, i - at
		}
		m := int(into.count)
		copy(into.leaf[j + 1:m + 1], into.leaf[j:m])
		into.leaf[j] = {key^, val}
		into.count += 1
		split = r.leaf[0].key
		right = branch_of(split, r_no, r)
		return
	}

	i := branch_find(pg, key)
	child, child_split, child_right := put(p, pg.branch[i].child, key, val)
	pg.branch[i] = branch_of(pg.branch[i].key, child, page(p, child))
	if child_right.child == 0 {
		return
	}
	child_right.key = child_split
	i += 1
	n := int(pg.count)
	if n < BRANCH_CAP {
		copy(pg.branch[i + 1:n + 1], pg.branch[i:n])
		pg.branch[i] = child_right
		pg.count += 1
		return
	}
	at := n if i == n else n / 2
	r_no, r := page_new(p, pg.level)
	r.count = u16(copy(r.branch[:], pg.branch[at:n]))
	pg.count = u16(at)
	into, j := pg, i
	if i >= at && (i > at || at == n) {
		into, j = r, i - at
	}
	m := int(into.count)
	copy(into.branch[j + 1:m + 1], into.branch[j:m])
	into.branch[j] = child_right
	into.count += 1
	split = r.branch[0].key
	right = branch_of(split, r_no, r)
	return
}

tree_delete :: proc(p: ^Pager, t: ^Tree, key: Key) -> bool {
	key := key
	if _, ok := tree_get(p, t^, key); !ok {
		return false
	}
	t.root = del(p, t.root, &key)
	for t.root != 0 {
		pg := page(p, t.root)
		if pg.count == 0 {
			page_drop(p, t.root)
			t.root = 0
		} else if pg.level > 0 && pg.count == 1 {
			child := pg.branch[0].child
			page_drop(p, t.root)
			t.root = child
		} else {
			break
		}
	}
	return true
}

@(private)
del :: proc(p: ^Pager, old: u32, key: ^Key) -> u32 {
	no, pg := page_own(p, old)
	if pg.level == 0 {
		i := leaf_find(pg, key)
		n := int(pg.count)
		copy(pg.leaf[i:n - 1], pg.leaf[i + 1:n])
		pg.count -= 1
		return no
	}

	i := branch_find(pg, key)
	child := del(p, pg.branch[i].child, key)
	cp := page(p, child)
	pg.branch[i] = branch_of(pg.branch[i].key, child, cp)

	cap := LEAF_CAP if cp.level == 0 else BRANCH_CAP
	if int(cp.count) >= cap / 4 {
		return no
	}
	if cp.count == 0 {
		page_drop(p, child)
		branch_remove(pg, i)
		return no
	}
	// Merge with a neighbour when both fit with room to spare.
	l := i - 1 if i > 0 else i
	if l + 1 >= int(pg.count) {
		return no
	}
	a, b := pg.branch[l].child, pg.branch[l + 1].child
	if int(page(p, a).count) + int(page(p, b).count) > cap * 3 / 4 {
		return no
	}
	a_no, ap := page_own(p, a)
	bp := page(p, b)
	n := int(ap.count)
	if ap.level == 0 {
		copy(ap.leaf[n:], bp.leaf[:bp.count])
	} else {
		copy(ap.branch[n:], bp.branch[:bp.count])
		ap.branch[n].key = pg.branch[l + 1].key
	}
	ap.count += bp.count
	page_drop(p, b)
	pg.branch[l] = branch_of(pg.branch[l].key, a_no, ap)
	branch_remove(pg, l + 1)
	return no
}

@(private)
branch_remove :: proc(pg: ^Page, i: int) {
	n := int(pg.count)
	copy(pg.branch[i:n - 1], pg.branch[i + 1:n])
	pg.count -= 1
}

// Count and fingerprint of every key less than `key`.
@(require_results)
tree_prefix :: proc(p: ^Pager, t: Tree, key: Key) -> (s: Sum) #no_bounds_check {
	key := key
	if t.root == 0 {
		return
	}
	pg := page(p, t.root)
	for pg.level > 0 {
		i := branch_find(pg, &key)
		for &e in pg.branch[:i] {
			s.count += int(e.count)
			s.print += e.sum
		}
		pg = page(p, pg.branch[i].child)
	}
	i := leaf_find(pg, &key)
	for &e in pg.leaf[:i] {
		s.print += e.val
	}
	s.count += i
	return
}

// Count and fingerprint of lo <= key < hi.
@(require_results)
tree_range :: proc(p: ^Pager, t: Tree, lo, hi: Key) -> Sum {
	if !key_less(lo, hi) {
		return {}
	}
	a, b := tree_prefix(p, t, lo), tree_prefix(p, t, hi)
	return {b.count - a.count, b.print - a.print}
}

// The key with exactly `rank` keys below it.
@(require_results)
tree_select :: proc(p: ^Pager, t: Tree, rank: int) -> (key: Key, ok: bool) {
	if t.root == 0 || rank < 0 {
		return
	}
	rank := rank
	pg := page(p, t.root)
	for pg.level > 0 {
		i := 0
		for ; i < int(pg.count) && rank >= int(pg.branch[i].count); i += 1 {
			rank -= int(pg.branch[i].count)
		}
		if i == int(pg.count) {
			return
		}
		pg = page(p, pg.branch[i].child)
	}
	if rank >= int(pg.count) {
		return
	}
	return pg.leaf[rank].key, true
}

MAX_DEPTH :: 8 // 63^7 leaves

// An ordered walk. Invalidated by mutation.
Cursor :: struct {
	pager: ^Pager,
	hi:    Key,
	path:  [MAX_DEPTH]struct {
		pg: ^Page,
		i:  int,
	},
	depth: int,
}

@(require_results)
tree_scan :: proc(p: ^Pager, t: Tree, lo, hi: Key) -> (c: Cursor) {
	lo := lo
	c.pager = p
	c.hi = hi
	if t.root == 0 {
		return
	}
	pg := page(p, t.root)
	for pg.level > 0 {
		i := branch_find(pg, &lo)
		c.path[c.depth] = {pg, i}
		c.depth += 1
		pg = page(p, pg.branch[i].child)
	}
	c.path[c.depth] = {pg, leaf_find(pg, &lo)}
	c.depth += 1
	return
}

@(require_results)
tree_next :: proc(c: ^Cursor) -> (leaf: Leaf, ok: bool) {
	for c.depth > 0 {
		top := &c.path[c.depth - 1]
		if top.i < int(top.pg.count) {
			if top.pg.level == 0 {
				leaf = top.pg.leaf[top.i]
				top.i += 1
				return leaf, key_cmp(&leaf.key, &c.hi) < 0
			}
			c.path[c.depth] = {page(c.pager, top.pg.branch[top.i].child), 0}
			c.depth += 1
			continue
		}
		c.depth -= 1
		if c.depth > 0 {
			c.path[c.depth - 1].i += 1
		}
	}
	return
}
