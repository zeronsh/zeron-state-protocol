/*
Package find answers questions about what a node holds: filters, search, order, joins and sums, live.

It is made from the store and adds nothing to it. An index is local, sealed, never replicated and never in
the log; deleting one costs the time to make it again, and one that nobody asks of costs nothing.
*/
package find

import "base:runtime"
import "core:crypto"
import "core:crypto/aead"
import "core:crypto/aegis"
import "../zsp"

// Pages of an index, copied on write and sealed where they rest. A few are kept open.

PAGE_SIZE :: 4096
@(private)
NONCE :: 16
@(private)
TAG :: 16
CACHE :: 256 // pages kept open, at most, besides those being written

// Where pages rest. Nothing need survive: what is lost is made again.
Disk :: struct {
	data:  rawptr,
	// A page as it rests, good until the next write; or nil.
	view:  proc(data: rawptr, no: u32) -> []byte,
	write: proc(data: rawptr, no: u32, bytes: []byte) -> bool,
	sync:  proc(data: rawptr) -> bool,
	close: proc(data: rawptr),
}

@(private)
Page :: struct #align (8) {
	nonce: [NONCE]byte,
	tag:   [TAG]byte,
	level: u16, // zero for leaves
	count: u16, // branches: children. Leaves: restarts
	used:  u16,
	_:     u16,
	data:  [PAGE_SIZE - 40]byte,
}
#assert(size_of(Page) == PAGE_SIZE)

@(private)
Frame :: struct {
	page:       Page,
	no:         u32,
	prev, next: ^Frame, // by when they were last asked for; nil in those being written
}

Pager :: struct {
	disk:    Disk,
	key:     zsp.Key32,
	salt:    [16]byte, // of this index, and never of another
	cipher:  aead.Context, // of headers,
	pages:   aead.Context, // and of everything else
	marks:   [dynamic]u32, // of each page as it was last written: one that was written before is not it
	altered: map[u32]bool, // stretches of those since they were last kept
	open:    map[u32]^Frame, // as they rest on the disk
	newest, oldest: ^Frame,
	dirty:   map[u32]^Frame, // not there yet
	next:    u32, // the first page never used
	free:    [dynamic]u32, // may be used now,
	pending: [dynamic]u32, // and once the next commit is made
	fresh:   Set, // made since the last: nothing that was committed leads to them
	spare:   [dynamic]^Frame, // to be had again
	failed:  bool,
	unwritten: bool, // for there was no writing
}

@(private)
pager_open :: proc(p: ^Pager, disk: Disk, key: zsp.Key32) {
	key := key
	p.disk = disk
	p.key = key
	aead.init(&p.cipher, .AEGIS_128L, key[:aegis.KEY_SIZE_128L])
	p.next = HEADERS
	pager_salt(p)
}

// Takes a salt, or a new one, and with it what pages are sealed by.
@(private)
pager_salt :: proc(p: ^Pager, salt: Maybe([16]byte) = nil) {
	s, given := salt.?
	if !given {
		crypto.rand_bytes(s[:])
	}
	p.salt = s
	key := zsp.hkdf256(p.salt[:], p.key[:], transmute([]byte)string("zsp-pages"))
	aead.reset(&p.pages)
	aead.init(&p.pages, .AEGIS_128L, key[:aegis.KEY_SIZE_128L])
	crypto.zero_explicit(&key, size_of(key))
	clear(&p.marks)
	clear(&p.altered)
}

@(private)
pager_close :: proc(p: ^Pager) {
	for frames in ([]map[u32]^Frame{p.open, p.dirty}) {
		for _, f in frames {
			crypto.zero_explicit(f, size_of(Frame))
			free(f)
		}
		delete(frames)
	}
	for f in p.spare {
		free(f)
	}
	delete(p.spare)
	delete(p.free)
	delete(p.pending)
	set_destroy(&p.fresh)
	aead.reset(&p.cipher)
	aead.reset(&p.pages)
	delete(p.marks)
	delete(p.altered)
	if p.disk.close != nil {
		p.disk.close(p.disk.data)
	}
	p^ = {}
}

@(private)
page_bind :: proc(no: u32) -> (b: [4]byte) {
	zsp.put_u32(b[:], no)
	return
}

// A page for reading. It stays where it is while fewer than CACHE others are asked for.
@(private)
page_get :: proc(p: ^Pager, no: u32) -> ^Page {
	if len(p.dirty) > 0 {
		if f, ok := p.dirty[no]; ok {
			return &f.page
		}
	}
	if f, ok := p.open[no]; ok {
		if f != p.newest {
			frame_unlink(p, f)
			frame_link(p, f)
		}
		return &f.page
	}
	f: ^Frame
	if len(p.open) < CACHE {
		f = frame_new(p)
	} else {
		f = p.oldest
		frame_unlink(p, f)
		delete_key(&p.open, f.no)
	}
	f.no = no
	mark: Maybe(u32)
	if no >= HEADERS {
		mark = p.marks[no] if int(no) < len(p.marks) else 0
	}
	if !page_read(p, no, mark, &f.page) {
		p.failed = true
	}
	p.open[no] = f
	frame_link(p, f)
	return &f.page
}

// A page from where it rests, if that is it. Where a mark is given, it is the one that was written under that.
@(private)
page_read :: proc(p: ^Pager, no: u32, mark: Maybe(u32), into: ^Page) -> bool {
	bind := page_bind(no)
	body := ([^]byte)(into)[NONCE + TAG:PAGE_SIZE]
	rests := p.disk.view(p.disk.data, no)
	ok := len(rests) == PAGE_SIZE
	if m, given := mark.?; ok && given {
		ok = zsp.get_u32(rests) == m && m != 0
	}
	if !ok || !aead.open(&p.pages if no >= HEADERS else &p.cipher, body, rests[:NONCE], bind[:], rests[NONCE + TAG:], rests[NONCE:][:TAG]) {
		into^ = {}
		return false
	}
	return true
}

// Writes a page, and says what marks it.
@(private)
page_write :: proc(p: ^Pager, no: u32, pg: ^Page) -> (mark: u32, ok: bool) {
	sealed := new(Page, context.temp_allocator)
	sealed^ = pg^
	for mark == 0 {
		crypto.rand_bytes(sealed.nonce[:])
		mark = zsp.get_u32(sealed.nonce[:])
	}
	bytes := ([^]byte)(sealed)[:PAGE_SIZE]
	bind := page_bind(no)
	body := bytes[NONCE + TAG:]
	aead.seal(&p.pages if no >= HEADERS else &p.cipher, body, sealed.tag[:], sealed.nonce[:], bind[:], body)
	if !p.disk.write(p.disk.data, no, bytes) {
		p.failed, p.unwritten = true, true
		return 0, false
	}
	return mark, true
}

MARKS :: 1000 // to a page

// Notes what marks a page.
@(private)
mark_set :: proc(p: ^Pager, no, mark: u32) {
	if int(no) >= len(p.marks) {
		reserve(&p.marks, (int(no) | 0x3fff) + 1) // a step at a time, neither copied for each nor doubled
		resize(&p.marks, int(no) + 1)
	}
	p.marks[no] = mark
	p.altered[no / MARKS] = true
}

@(private)
frame_link :: proc(p: ^Pager, f: ^Frame) {
	f.prev, f.next = p.newest, nil
	if p.newest != nil {
		p.newest.next = f
	} else {
		p.oldest = f
	}
	p.newest = f
}

@(private)
frame_unlink :: proc(p: ^Pager, f: ^Frame) {
	if f.prev != nil {
		f.prev.next = f.next
	} else {
		p.oldest = f.next
	}
	if f.next != nil {
		f.next.prev = f.prev
	} else {
		p.newest = f.prev
	}
}

@(private)
frame_new :: proc(p: ^Pager) -> ^Frame {
	if len(p.spare) == 0 {
		return new(Frame)
	}
	f := pop(&p.spare)
	f^ = {}
	return f
}

@(private)
frame_free :: proc(p: ^Pager, no: u32) {
	if f, ok := p.open[no]; ok {
		frame_unlink(p, f)
		delete_key(&p.open, no)
		append(&p.spare, f)
	}
}

@(private)
page_new :: proc(p: ^Pager) -> (no: u32, pg: ^Page) {
	no = page_take(p)
	f := frame_new(p)
	f.no = no
	p.dirty[no] = f
	set_add(&p.fresh, no)
	return no, &f.page
}

// A page that nothing is kept of here.
@(private)
page_take :: proc(p: ^Pager) -> (no: u32) {
	if len(p.free) > 0 {
		no = pop(&p.free)
	} else {
		no = p.next
		p.next += 1
	}
	frame_free(p, no) // what it was before it was given up
	return
}

@(private)
page_drop :: proc(p: ^Pager, no: u32) {
	if f, ok := p.dirty[no]; ok {
		delete_key(&p.dirty, no)
		append(&p.spare, f)
	}
	if set_remove(&p.fresh, no) {
		append(&p.free, no)
	} else {
		append(&p.pending, no)
	}
}

// Writes what is new. The caller then says where it begins.
@(private)
pager_write :: proc(p: ^Pager) -> bool {
	for no, f in p.dirty {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		mark := page_write(p, no, &f.page) or_return
		if no >= HEADERS {
			mark_set(p, no, mark)
		}
	}
	for _, f in p.dirty {
		append(&p.spare, f)
	}
	clear(&p.dirty)
	return true
}

// ---------------------------------------------------------------- a disk in memory

Memory_Disk :: struct {
	pages:  map[u32]^[PAGE_SIZE]byte,
	writes: int,
}

memory_disk :: proc(m: ^Memory_Disk) -> Disk {
	return {
		data = m,
		view = proc(data: rawptr, no: u32) -> []byte {
			pg, ok := (^Memory_Disk)(data).pages[no]
			return pg[:] if ok else nil
		},
		write = proc(data: rawptr, no: u32, bytes: []byte) -> bool {
			m := (^Memory_Disk)(data)
			pg, ok := m.pages[no]
			if !ok {
				pg = new([PAGE_SIZE]byte)
				m.pages[no] = pg
			}
			copy(pg[:], bytes)
			m.writes += 1
			return true
		},
		sync = proc(data: rawptr) -> bool {return true},
		close = nil,
	}
}

memory_disk_destroy :: proc(m: ^Memory_Disk) {
	for _, pg in m.pages {
		free(pg)
	}
	delete(m.pages)
}
