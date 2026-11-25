/*
Package find answers questions about what a node holds: filters, search, order, joins and sums, live.

It is made from the store and adds nothing to it. An index is local, sealed, never replicated and never in
the log; deleting one costs the time to make it again, and one that nobody asks of costs nothing.
*/
package find

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
	read:  proc(data: rawptr, no: u32, into: []byte) -> bool,
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
	cipher:  aead.Context,
	open:    map[u32]^Frame, // as they rest on the disk
	newest, oldest: ^Frame,
	dirty:   map[u32]^Frame, // not there yet
	next:    u32, // the first page never used
	free:    [dynamic]u32, // may be used now,
	pending: [dynamic]u32, // and once the next commit is made
	failed:  bool,
}

@(private)
pager_open :: proc(p: ^Pager, disk: Disk, key: zsp.Key32) {
	key := key
	p.disk = disk
	aead.init(&p.cipher, .AEGIS_128L, key[:aegis.KEY_SIZE_128L])
	p.next = HEADERS
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
	delete(p.free)
	delete(p.pending)
	aead.reset(&p.cipher)
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
		f = new(Frame)
	} else {
		f = p.oldest
		frame_unlink(p, f)
		delete_key(&p.open, f.no)
	}
	f.no = no
	bytes := ([^]byte)(&f.page)[:PAGE_SIZE]
	bind := page_bind(no)
	body := bytes[NONCE + TAG:]
	if !p.disk.read(p.disk.data, no, bytes) || !aead.open(&p.cipher, body, f.page.nonce[:], bind[:], body, f.page.tag[:]) {
		p.failed = true
		f.page = {}
	}
	p.open[no] = f
	frame_link(p, f)
	return &f.page
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
frame_free :: proc(p: ^Pager, no: u32) {
	if f, ok := p.open[no]; ok {
		frame_unlink(p, f)
		delete_key(&p.open, no)
		free(f)
	}
}

@(private)
page_new :: proc(p: ^Pager) -> (no: u32, pg: ^Page) {
	if len(p.free) > 0 {
		no = pop(&p.free)
	} else {
		no = p.next
		p.next += 1
	}
	frame_free(p, no) // what it was before it was given up
	f := new(Frame)
	f.no = no
	p.dirty[no] = f
	return no, &f.page
}

@(private)
page_drop :: proc(p: ^Pager, no: u32) {
	if f, ok := p.dirty[no]; ok {
		// Never written, so nothing that was committed points to it.
		delete_key(&p.dirty, no)
		free(f)
		append(&p.free, no)
		return
	}
	append(&p.pending, no)
}

// Writes what is new. The caller then says where it begins.
@(private)
pager_write :: proc(p: ^Pager) -> bool {
	sealed := new(Page, context.temp_allocator)
	for no, f in p.dirty {
		sealed^ = f.page
		crypto.rand_bytes(sealed.nonce[:])
		bytes := ([^]byte)(sealed)[:PAGE_SIZE]
		bind := page_bind(no)
		body := bytes[NONCE + TAG:]
		aead.seal(&p.cipher, body, sealed.tag[:], sealed.nonce[:], bind[:], body)
		if !p.disk.write(p.disk.data, no, bytes) {
			p.failed = true
			return false
		}
	}
	for _, f in p.dirty {
		free(f)
	}
	clear(&p.dirty)
	shrink(&p.dirty)
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
		read = proc(data: rawptr, no: u32, into: []byte) -> bool {
			pg := (^Memory_Disk)(data).pages[no] or_return
			copy(into, pg[:])
			return true
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
