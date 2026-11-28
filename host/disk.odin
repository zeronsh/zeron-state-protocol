/*
Package host runs nodes on a real machine: files, sockets, one thread, one event loop.
*/
package host

import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "../find"
import "../zsp"

// Segments are files named by number; pages live in one file, mapped for reading so that the
// operating system decides what stays in memory.
File_Disk :: struct {
	dir:     string, // owned
	tree:    ^os.File,
	mapped:  []byte,
	active:  ^os.File, // the segment being appended to
	number:  u64,
	reading: ^os.File, // the segment last read, if another
	read_no: u64,
	dirty:   bool,
	hold:    bool, // the directory, from before anything in it is read or written: see hold.odin
	lock:    Maybe(Dir_Lock),
	look:    bool, // only: nothing is made, nor opened to be written
	host:    ^Host, // whose loop makes its fsyncs without waiting for them; none to make them as they are asked
	rolled:  [dynamic]Rolled, // segments the log has gone on from, written since last synced: made durable with it
	released: [dynamic]Rolled, // segments' files let go of, that the host's thread may still have something to do of
	unremoved: [dynamic]u64, // segments dropped whose files could not yet be removed, as on Windows one open elsewhere
}

@(private)
Rolled :: struct {
	number: u64,
	file:   ^os.File,
}

// Nothing is created until there is something to keep: merely asking about a space leaves no trace. With `hold`, the
// directory is held from then on, until the disk is closed, as by whoever keeps a store there; without, as by a command
// that only looks, it is not. What was opened of it is let go of should opening fail.
file_disk_open :: proc(d: ^File_Disk, dir: string, hold := false) -> bool {
	d.dir = strings.clone(dir)
	d.number = max(u64)
	d.read_no = max(u64)
	d.hold = hold
	if os.exists(dir) && !file_disk_make(d) {
		file_disk_close(d)
		return false
	}
	return true
}

file_disk_make :: proc(d: ^File_Disk) -> bool {
	if d.tree != nil {
		return true
	}
	path, _ := filepath.join({d.dir, "tree"}, context.temp_allocator)
	err: os.Error
	if d.look {
		if !os.exists(path) {
			return true // no pages, and perhaps a log
		}
		d.tree, err = os.open(path, {.Read})
		if err != nil {
			d.tree = nil
			return false
		}
		return file_remap(d)
	}
	if d.hold && d.lock == nil {
		d.lock = dir_hold(d.dir) or_return // which makes it
	} else if err = os.make_directory_all(d.dir); err != nil && !os.is_dir(d.dir) {
		return false
	}
	d.tree, err = os.open(path, {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		d.tree = nil
		return false
	}
	return file_remap(d)
}

@(private)
file_remap :: proc(d: ^File_Disk) -> bool {
	if d.mapped != nil {
		virtual.unmap_file(d.mapped)
		d.mapped = nil
	}
	size, err := os.file_size(d.tree)
	if err != nil || size == 0 {
		return err == nil
	}
	merr: virtual.Map_File_Error
	d.mapped, merr = virtual.map_file_from_file(d.tree, {.Read})
	return merr == .None
}

@(private)
segment_path :: proc(d: ^File_Disk, number: u64) -> string {
	// Eight hex digits, and more when there are more, in order either way until there are.
	name: [20]byte
	at := len(name) - 4
	copy(name[at:], ".log")
	for n := number; n > 0 || at > len(name) - 12; n >>= 4 {
		at -= 1
		digit := byte(n & 15)
		name[at] = digit + ('0' if digit < 10 else 'a' - 10)
	}
	path, _ := filepath.join({d.dir, string(name[at:])}, context.temp_allocator)
	return path
}

@(private)
segment_number :: proc(name: string) -> (number: u64, ok: bool) {
	if !strings.has_suffix(name, ".log") {
		return
	}
	return strconv.parse_u64_of_base(name[:len(name) - 4], 16)
}

@(private)
segment_file :: proc(d: ^File_Disk, number: u64) -> ^os.File {
	if number == d.number {
		return d.active
	}
	if number == d.read_no {
		return d.reading
	}
	if d.reading != nil {
		os.close(d.reading)
		d.reading, d.read_no = nil, max(u64)
	}
	f, err := os.open(segment_path(d, number), {.Read})
	if err != nil {
		return nil
	}
	d.reading, d.read_no = f, number
	return f
}

// Lets go of the files of segments from `first` on, before they go: one still open would be written to nothing, its
// writes lost with a sync to say they were kept, or read from as though it were still there; and Windows removes no file
// that is open.
@(private)
segments_close :: proc(d: ^File_Disk, first: u64, last := max(u64)) {
	if d.active != nil && d.number >= first && d.number <= last {
		segment_let_go(d, d.number, d.active)
		d.active, d.number, d.dirty = nil, max(u64), false // what it held is not wanted
	}
	if d.reading != nil && d.read_no >= first && d.read_no <= last {
		os.close(d.reading)
		d.reading, d.read_no = nil, max(u64)
	}
}

// Closes a file of the disk's, once the host's thread has done all asked of it, if it is the host's to do.
@(private)
file_let_go :: proc(d: ^File_Disk, f: ^os.File) {
	if d.host != nil {
		disk_release(d.host, f)
	} else {
		os.close(f)
	}
}

// The same, of a segment's file, which is waited for before the segment is removed.
@(private)
segment_let_go :: proc(d: ^File_Disk, number: u64, f: ^os.File) {
	if d.host != nil && disk_busy(d.host, f) {
		append(&d.released, Rolled{number, f})
	}
	file_let_go(d, f)
}

// Waits for all asked of a file to be done, before it is synced now: what failed of it fails this.
@(private)
file_drained :: proc(d: ^File_Disk, f: ^os.File) -> bool {
	return d.host == nil || disk_drain(d.host, f)
}

// Removes the file of a segment dropped, once nothing is asked of it; or later, at a settle, if it cannot be now.
@(private)
segment_remove :: proc(d: ^File_Disk, number: u64) {
	path := segment_path(d, number)
	#reverse for r, i in d.released {
		// Its handles' last fsyncs made, and the handles closed, as they are once none is left: so that the file goes.
		if r.number == number || !disk_known(d.host, r.file) {
			if r.number == number {
				disk_drain_closing(d.host, r.file)
			}
			unordered_remove(&d.released, i)
		}
	}
	if os.remove(path) != nil && os.exists(path) {
		append(&d.unremoved, number)
	}
}

// As a settle begins: removes what could not be removed before.
file_disk_settle :: proc(d: ^File_Disk) {
	#reverse for number, i in d.unremoved {
		path := segment_path(d, number)
		if os.remove(path) == nil || !os.exists(path) {
			unordered_remove(&d.unremoved, i)
		}
	}
}

// An fsync made now, by the loop, as a sync that must be had at once is.
@(private)
disk_sync :: proc(d: ^File_Disk, f: ^os.File, kind: Tick_Disk) -> bool {
	since := ticks_now()
	defer ticks_disk(kind, since)
	ok := os.sync(f) == nil
	if ok && d.host != nil && d.host.disk.synced != nil {
		d.host.disk.synced(d.host, f) // a test's, as in disk_power_test.odin
	}
	return ok
}

@(require_results)
file_disk :: proc(d: ^File_Disk) -> zsp.Disk {
	disk := file_disk_waiting(d)
	if d.host != nil {
		disk.log_sync_start = proc(data: rawptr, token: u64) -> bool {
			d := (^File_Disk)(data)
			since := ticks_now()
			defer ticks_disk(.Log_Sync_Start, since)
			// Every segment the log went on from since, then the one it goes on in: all, as one sync, for one token.
			files := make([dynamic]^os.File, context.temp_allocator)
			for r in d.rolled {
				append(&files, r.file)
			}
			if d.active != nil && d.dirty {
				append(&files, d.active)
				d.dirty = false // what is written from now on is for the next
			}
			disk_sync_ask(d.host, token, ..files[:])
			for r in d.rolled {
				segment_let_go(d, r.number, r.file) // closed once it is durable
			}
			clear(&d.rolled)
			return true
		}
		disk.page_sync_start = proc(data: rawptr, token: u64) -> bool {
			d := (^File_Disk)(data)
			since := ticks_now()
			defer ticks_disk(.Page_Sync_Start, since)
			if d.tree == nil {
				disk_sync_ask(d.host, token)
				return true
			}
			// Read from the mapping from now on, durable or not: so it must reach every page written.
			size, err := os.file_size(d.tree)
			if err != nil || (int(size) != len(d.mapped) && !file_remap(d)) {
				return false
			}
			disk_sync_ask(d.host, token, d.tree)
			return true
		}
	}
	return disk
}

@(private)
file_disk_waiting :: proc(d: ^File_Disk) -> zsp.Disk {
	return {
		data = d,
		log_write = proc(data: rawptr, off: u64, bytes: []byte) -> bool {
			d := (^File_Disk)(data)
			if !file_disk_make(d) {
				return false
			}
			number := off / zsp.SEGMENT
			if number != d.number {
				if d.active != nil {
					switch {
					case !d.dirty:
						file_let_go(d, d.active)
					case d.host != nil:
						// Made durable with the next sync of the log, which is begun, not waited for: until then nothing
						// written to it is counted on, as nothing written since the last sync is.
						append(&d.rolled, Rolled{d.number, d.active})
					case !disk_sync(d, d.active, .Roll_Sync):
						return false
					case:
						os.close(d.active)
					}
				}
				f, err := os.open(segment_path(d, number), {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
				if err != nil {
					d.active, d.number = nil, max(u64)
					return false
				}
				d.active, d.number = f, number
			}
			since := ticks_now()
			n, err := os.write_at(d.active, bytes, i64(off % zsp.SEGMENT))
			ticks_disk(.Log_Write, since)
			disk_noted(d.host, d.active, i64(off % zsp.SEGMENT), bytes[:max(n, 0)])
			d.dirty = true
			return err == nil && n == len(bytes)
		},
		log_read = proc(data: rawptr, off: u64, into: []byte) -> bool {
			f := segment_file((^File_Disk)(data), off / zsp.SEGMENT)
			if f == nil {
				return false
			}
			n, _ := os.read_at(f, into, i64(off % zsp.SEGMENT))
			return n == len(into)
		},
		log_replayed = proc(data: rawptr, from: u64) {
			d := (^File_Disk)(data)
			// Each segment from there on, made durable by the next sync of the log, as one the log has gone on from is.
			files, _ := os.read_all_directory_by_path(d.dir, context.temp_allocator)
			for f in files {
				if number, ok := segment_number(f.name); ok && number >= from / zsp.SEGMENT {
					if g, err := os.open(f.fullpath, {.Read, .Write}); err == nil {
						append(&d.rolled, Rolled{number, g})
					}
				}
			}
		},
		log_end = proc(data: rawptr) -> (end: u64) {
			d := (^File_Disk)(data)
			files, _ := os.read_all_directory_by_path(d.dir, context.temp_allocator)
			for f in files {
				if number, ok := segment_number(f.name); ok && f.size > 0 {
					end = max(end, number * zsp.SEGMENT + u64(f.size))
				}
			}
			return
		},
		log_drop = proc(data: rawptr, segment: u64) {
			d := (^File_Disk)(data)
			segments_close(d, segment, segment)
			segment_remove(d, segment)
		},
		log_truncate = proc(data: rawptr, off: u64) {
			d := (^File_Disk)(data)
			last := off / zsp.SEGMENT
			segments_close(d, last + 1)
			files, _ := os.read_all_directory_by_path(d.dir, context.temp_allocator)
			for f in files {
				if number, ok := segment_number(f.name); ok && number > last {
					os.remove(segment_path(d, number))
				}
			}
			if last == d.number {
				os.truncate(d.active, i64(off % zsp.SEGMENT))
				disk_noted(d.host, d.active, i64(off % zsp.SEGMENT), nil, truncated = true)
			} else if f, err := os.open(segment_path(d, last), {.Write}); err == nil {
				os.truncate(f, i64(off % zsp.SEGMENT))
				disk_noted(d.host, f, i64(off % zsp.SEGMENT), nil, truncated = true)
				os.close(f)
			}
		},
		log_sync = proc(data: rawptr) -> bool {
			d := (^File_Disk)(data)
			for len(d.rolled) > 0 {
				f := d.rolled[0].file
				if !file_drained(d, f) || !disk_sync(d, f, .Roll_Sync) {
					return false
				}
				ordered_remove(&d.rolled, 0)
				file_let_go(d, f)
			}
			if d.active == nil || !d.dirty {
				return d.active == nil || file_drained(d, d.active)
			}
			if !file_drained(d, d.active) || !disk_sync(d, d.active, .Log_Sync) {
				return false
			}
			d.dirty = false
			return true
		},
		page = proc(data: rawptr, no: zsp.Page_No) -> ^zsp.Page {
			d := (^File_Disk)(data)
			if no >= u64(len(d.mapped) / zsp.PAGE_SIZE) {
				return nil
			}
			return (^zsp.Page)(raw_data(d.mapped[int(no) * zsp.PAGE_SIZE:]))
		},
		page_write = proc(data: rawptr, no: zsp.Page_No, bytes: []byte) -> bool {
			d := (^File_Disk)(data)
			if !file_disk_make(d) {
				return false
			}
			block: [zsp.PAGE_SIZE]byte
			copy(block[:], bytes)
			since := ticks_now()
			n, err := os.write_at(d.tree, block[:], i64(no) * zsp.PAGE_SIZE)
			ticks_disk(.Page_Write, since)
			disk_noted(d.host, d.tree, i64(no) * zsp.PAGE_SIZE, block[:max(n, 0)])
			return err == nil && n == len(block)
		},
		page_sync = proc(data: rawptr) -> bool {
			d := (^File_Disk)(data)
			if d.tree == nil {
				return true
			}
			if !file_drained(d, d.tree) || !disk_sync(d, d.tree, .Page_Sync) {
				return false
			}
			size, err := os.file_size(d.tree)
			return err == nil && (int(size) == len(d.mapped) || file_remap(d))
		},
		close = proc(data: rawptr) {
			file_disk_close((^File_Disk)(data))
		},
	}
}

// Lets go of all a disk has open, and last of its directory, if held.
file_disk_close :: proc(d: ^File_Disk) {
	if d.mapped != nil {
		virtual.unmap_file(d.mapped)
	}
	for f in ([]^os.File{d.tree, d.active}) {
		if f != nil {
			file_let_go(d, f)
		}
	}
	if d.reading != nil {
		os.close(d.reading)
	}
	for r in d.rolled {
		file_let_go(d, r.file) // what was not synced was not counted on
	}
	delete(d.rolled)
	delete(d.released)
	file_disk_settle(d)
	delete(d.unremoved)
	if lock, held := d.lock.?; held {
		dir_unlock(lock)
	}
	delete(d.dir)
	d^ = {}
}

// The latest stamp time a store nobody is running has seen, as its pages and log say: only looked at, nothing made.
clock_of :: proc(dir: string) -> u64 {
	d: File_Disk
	d.look = true
	if !os.exists(dir) || !file_disk_open(&d, dir) {
		return 0
	}
	disk := file_disk(&d)
	defer disk.close(disk.data)
	return zsp.store_clock(disk)
}

// Where an index rests. It can always be made again, so nothing about it need be careful.
Pages_File :: struct {
	path:   string, // owned
	file:   ^os.File,
	mapped: []byte,
	size:   int, // as far as it has been written
}

pages_file :: proc(p: ^Pages_File, dir: string) -> find.Disk {
	p.path, _ = filepath.join({dir, "find"})
	return {
		data = p,
		view = proc(data: rawptr, no: u32) -> []byte {
			p := (^Pages_File)(data)
			if p.file == nil && (!os.exists(p.path) || !pages_make(p)) {
				return nil
			}
			end := (int(no) + 1) * find.PAGE_SIZE
			if end > p.size {
				return nil
			}
			if end > len(p.mapped) {
				if p.mapped != nil {
					virtual.unmap_file(p.mapped)
				}
				err: virtual.Map_File_Error
				p.mapped, err = virtual.map_file_from_file(p.file, {.Read})
				if err != .None {
					p.mapped = nil
					return nil
				}
			}
			return p.mapped[end - find.PAGE_SIZE:end] if end <= len(p.mapped) else nil
		},
		write = proc(data: rawptr, no: u32, bytes: []byte) -> bool {
			p := (^Pages_File)(data)
			if p.file == nil && !pages_make(p) {
				return false
			}
			at := int(no) * find.PAGE_SIZE
			when ODIN_OS == .Windows {
				// A file does not grow there while it is mapped.
				if at + len(bytes) > p.size && p.mapped != nil {
					virtual.unmap_file(p.mapped)
					p.mapped = nil
				}
			}
			n, err := os.write_at(p.file, bytes, i64(at))
			p.size = max(p.size, at + n)
			return err == nil && n == len(bytes)
		},
		sync = proc(data: rawptr) -> bool {
			p := (^Pages_File)(data)
			return p.file == nil || os.sync(p.file) == nil
		},
		close = proc(data: rawptr) {
			p := (^Pages_File)(data)
			if p.mapped != nil {
				virtual.unmap_file(p.mapped)
			}
			if p.file != nil {
				os.close(p.file)
			}
			delete(p.path)
			p^ = {}
		},
	}
}

@(private)
pages_make :: proc(p: ^Pages_File) -> bool {
	err: os.Error
	p.file, err = os.open(p.path, {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		p.file = nil
		return false
	}
	size, serr := os.file_size(p.file)
	p.size = int(size)
	return serr == nil
}
