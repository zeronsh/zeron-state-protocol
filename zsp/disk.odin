package zsp

// What the store needs from the outside world. Every call is synchronous; errors are fatal to the
// store and surface as `false`, because a log that cannot be written must not be acknowledged.
Disk :: struct {
	data:       rawptr,
	// Append-only segments of SEGMENT bytes, addressed by a flat 64-bit offset.
	log_write:  proc(data: rawptr, off: u64, bytes: []byte) -> bool,
	log_read:   proc(data: rawptr, off: u64, into: []byte) -> bool,
	log_end:    proc(data: rawptr) -> u64, // one past the last byte that may have been written
	log_drop:   proc(data: rawptr, segment: u64), // delete a whole segment
	log_truncate: proc(data: rawptr, off: u64), // forget everything from here on
	log_sync:   proc(data: rawptr) -> bool,
	// Pages of PAGE_SIZE bytes. `page` returns memory valid until the next `page_sync`.
	page:       proc(data: rawptr, no: Page_No) -> ^Page,
	page_write: proc(data: rawptr, no: Page_No, bytes: []byte) -> bool,
	page_sync:  proc(data: rawptr) -> bool,
	close:      proc(data: rawptr),
	// Storage that may answer "not yet", as a cache over object storage does: a page that is not yet here reads as
	// EMPTY_PAGE, log_read returns false, and this counts both. Nil for storage that always answers. See lazy.odin.
	missed:     proc(data: rawptr) -> int,
	// Storage that can make what was written to the log durable without the caller waiting, as log_sync does with it:
	// begins that, for everything written to the log so far, and says whether it could. Whoever drives the store then
	// says how it ended, by store_disk_synced with the same token, once it has: never before this returns. Nil where
	// a sync is had only by waiting for it. See Flight.
	log_sync_start: proc(data: rawptr, token: u64) -> bool,
	// The same, for pages written: what `page` returned is no longer valid once this returns, and every page written is
	// read by it from then on, durable or not. Nil where there is no log_sync_start, or a page sync must be waited for.
	page_sync_start: proc(data: rawptr, token: u64) -> bool,
}

// A disk in memory, which can also forget everything that was not synced.
Memory_Disk :: struct {
	log:         map[u64][dynamic]byte, // by segment
	pages:       map[Page_No]^Page,
	writes:      int,
	bytes:       int,
	syncs:       int,
	kept:        u64, // the log's end when it was last synced
	fail:        bool, // writes and syncs, from now on
}

memory_disk :: proc(m: ^Memory_Disk) -> Disk {
	return {
		data = m,
		log_write = proc(data: rawptr, off: u64, bytes: []byte) -> bool {
			m := (^Memory_Disk)(data)
			if m.fail {
				return false
			}
			seg := off / SEGMENT
			if seg not_in m.log {
				m.log[seg] = make([dynamic]byte)
			}
			at := int(off % SEGMENT)
			b := &m.log[seg]
			if len(b) < at + len(bytes) {
				resize(b, at + len(bytes))
			}
			copy(b[at:], bytes)
			m.writes += 1
			m.bytes += len(bytes)
			return true
		},
		log_read = proc(data: rawptr, off: u64, into: []byte) -> bool {
			m := (^Memory_Disk)(data)
			b, ok := m.log[off / SEGMENT]
			at := int(off % SEGMENT)
			if !ok || at > len(b) {
				return false
			}
			return copy(into, b[at:]) == len(into)
		},
		log_end = proc(data: rawptr) -> u64 {
			return memory_disk_end((^Memory_Disk)(data))
		},
		log_drop = proc(data: rawptr, segment: u64) {
			m := (^Memory_Disk)(data)
			if segment in m.log {
				delete(m.log[segment])
				delete_key(&m.log, segment)
			}
		},
		log_truncate = proc(data: rawptr, off: u64) {
			m := (^Memory_Disk)(data)
			for seg, &b in m.log {
				if seg == off / SEGMENT {
					resize(&b, min(len(b), int(off % SEGMENT)))
				} else if seg > off / SEGMENT {
					clear(&b)
				}
			}
		},
		log_sync = proc(data: rawptr) -> bool {
			m := (^Memory_Disk)(data)
			m.syncs += 1
			m.kept = memory_disk_end(m)
			return !m.fail
		},
		page = proc(data: rawptr, no: Page_No) -> ^Page {
			return (^Memory_Disk)(data).pages[no]
		},
		page_write = proc(data: rawptr, no: Page_No, bytes: []byte) -> bool {
			m := (^Memory_Disk)(data)
			pg, ok := m.pages[no]
			if !ok {
				pg = new(Page)
				m.pages[no] = pg
			}
			copy(([^]byte)(pg)[:size_of(Page)], bytes)
			m.writes += 1
			m.bytes += len(bytes)
			return true
		},
		page_sync = proc(data: rawptr) -> bool {
			m := (^Memory_Disk)(data)
			m.syncs += 1
			return !m.fail
		},
		close = proc(data: rawptr) {},
	}
}

@(private)
memory_disk_end :: proc(m: ^Memory_Disk) -> (end: u64) {
	for seg, b in m.log {
		end = max(end, seg * SEGMENT + u64(len(b)))
	}
	return
}

memory_disk_destroy :: proc(m: ^Memory_Disk) {
	for _, b in m.log {
		delete(b)
	}
	for _, pg in m.pages {
		free(pg)
	}
	delete(m.log)
	delete(m.pages)
}
