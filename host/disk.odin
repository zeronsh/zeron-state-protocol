/*
Package host runs nodes on a real machine: files, sockets, one thread, one event loop.
*/
package host

import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
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
}

file_disk_open :: proc(d: ^File_Disk, dir: string) -> bool {
	d.dir = strings.clone(dir)
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		return false
	}
	path, _ := filepath.join({dir, "tree"}, context.temp_allocator)
	err: os.Error
	d.tree, err = os.open(path, {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return false
	}
	d.number = max(u64)
	d.read_no = max(u64)
	file_remap(d)
	return true
}

@(private)
file_remap :: proc(d: ^File_Disk) {
	if d.mapped != nil {
		virtual.unmap_file(d.mapped)
		d.mapped = nil
	}
	if size, err := os.file_size(d.tree); err == nil && size > 0 {
		d.mapped, _ = virtual.map_file_from_file(d.tree, {.Read})
	}
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

@(private)
disk_sync :: proc(f: ^os.File) -> bool {
	return os.sync(f) == nil
}

@(require_results)
file_disk :: proc(d: ^File_Disk) -> zsp.Disk {
	return {
		data = d,
		log_write = proc(data: rawptr, off: u64, bytes: []byte) -> bool {
			d := (^File_Disk)(data)
			number := off / zsp.SEGMENT
			if number != d.number {
				if d.active != nil {
					if d.dirty && !disk_sync(d.active) {
						return false
					}
					os.close(d.active)
				}
				f, err := os.open(segment_path(d, number), {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
				if err != nil {
					d.active, d.number = nil, max(u64)
					return false
				}
				d.active, d.number = f, number
			}
			n, err := os.write_at(d.active, bytes, i64(off % zsp.SEGMENT))
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
			if segment == d.read_no {
				os.close(d.reading)
				d.reading, d.read_no = nil, max(u64)
			}
			os.remove(segment_path(d, segment))
		},
		log_truncate = proc(data: rawptr, off: u64) {
			d := (^File_Disk)(data)
			files, _ := os.read_all_directory_by_path(d.dir, context.temp_allocator)
			for f in files {
				if number, ok := segment_number(f.name); ok && number > off / zsp.SEGMENT {
					os.remove(segment_path(d, number))
				}
			}
			if f, err := os.open(segment_path(d, off / zsp.SEGMENT), {.Write}); err == nil {
				os.truncate(f, i64(off % zsp.SEGMENT))
				os.close(f)
			}
		},
		log_sync = proc(data: rawptr) -> bool {
			d := (^File_Disk)(data)
			if d.active == nil || !d.dirty {
				return true
			}
			d.dirty = false
			return disk_sync(d.active)
		},
		page = proc(data: rawptr, no: u32) -> ^zsp.Page {
			d := (^File_Disk)(data)
			at := int(no) * zsp.PAGE_SIZE
			if at + size_of(zsp.Page) > len(d.mapped) {
				return nil
			}
			return (^zsp.Page)(raw_data(d.mapped[at:]))
		},
		page_write = proc(data: rawptr, no: u32, bytes: []byte) -> bool {
			d := (^File_Disk)(data)
			block: [zsp.PAGE_SIZE]byte
			copy(block[:], bytes)
			n, err := os.write_at(d.tree, block[:], i64(no) * zsp.PAGE_SIZE)
			return err == nil && n == len(block)
		},
		page_sync = proc(data: rawptr) -> bool {
			d := (^File_Disk)(data)
			ok := disk_sync(d.tree)
			if size, err := os.file_size(d.tree); err != nil || int(size) != len(d.mapped) {
				file_remap(d)
			}
			return ok
		},
		close = proc(data: rawptr) {
			d := (^File_Disk)(data)
			if d.mapped != nil {
				virtual.unmap_file(d.mapped)
			}
			for f in ([]^os.File{d.tree, d.active, d.reading}) {
				if f != nil {
					os.close(f)
				}
			}
			delete(d.dir)
			d^ = {}
		},
	}
}
