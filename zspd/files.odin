package main

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "../host"
import "../zsp"

// Files of another device's shares (§16): listed (ls), fetched (get) and sent (put), a file, or a folder and all in
// it. A path there is a share's name and the path within it, with '/' between, whatever either system.
//
// Each file goes by a call of its own, one at a time, through host/transfer.odin, as the host's own transfers do: a
// file being fetched is kept beside where it is going as `<name>.zsp-part` until it is whole, and fetching it again
// takes up from the last chunk still proved, if the file there is still the one it was. A file already here as it is
// there, of the same size and time (a fetch gives a file the time it has there, and a send likewise), is not fetched
// again, nor one there sent again: so a folder, too, takes up where it stopped.
//
// Where a path names where something goes, it is that thing; but one ending in '/', a share alone, or for a file a
// folder that is there already, is where it goes into, under its own name.

Entry :: struct {
	kind:     u8, // 1 file, 2 folder, 3 other
	name:     string,
	size:     u64,
	modified: u64, // ms since 1970
}

ENTRY_FILE :: 1
ENTRY_FOLDER :: 2
NOT_KNOWN :: max(u64) // the size of what is not plainly a file, which no file here matches

// The entries of a listing, after its status.
@(private = "file")
entries_of :: proc(a: ^Ask) -> (entries: [dynamic]Entry, ok: bool) {
	entries = make([dynamic]Entry, context.temp_allocator)
	for reply, i in a.replies {
		r := zsp.Reader{buf = reply[1:] if i == 0 else reply}
		for r.pos < len(r.buf) {
			e: Entry
			e.kind = zsp.read_u8(&r)
			e.name = string(zsp.read_bytes(&r))
			e.size = zsp.read_varint(&r)
			e.modified = zsp.read_varint(&r)
			if r.bad {
				return
			}
			append(&entries, e)
		}
	}
	return entries, true
}

@(private = "file")
unix_ms :: proc(t: time.Time) -> u64 {
	return u64(max(time.time_to_unix_nano(t), 0) / 1_000_000)
}

// A path there, and one within it.
@(private = "file")
remote_join :: proc(base, rel: string) -> string {
	if rel == "" {
		return base
	}
	if base == "" {
		return rel
	}
	return strings.concatenate({base, "/", rel}, context.temp_allocator)
}

// A path here, and one within it, given with '/' between.
@(private = "file")
local_join :: proc(base, rel: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	append(&parts, base)
	rest := rel
	for part in strings.split_iterator(&rest, "/") {
		append(&parts, part)
	}
	joined, _ := filepath.join(parts[:], context.temp_allocator)
	return joined
}

// What comes after the last '/'.
@(private = "file")
last_part :: proc(path: string) -> string {
	return path[strings.last_index_byte(path, '/') + 1:]
}

// ---------------------------------------------------------------- ls

@(private = "file")
Listing :: struct {
	device: zsp.Key32,
	scope:  zsp.Scope,
	path:   string,
	ok:     bool,
}

// zspd ls <dir> <device> [path] [--scope=N]: a folder there, sorted; with no path, the shares of files.
ls :: proc(dir: string, args: []string) -> int {
	line, ok := command_line(args, {.Scope}, 2)
	if !ok || len(line.words) < 1 || len(line.words) > 2 {
		return usage()
	}
	device, found := device_named(dir, line.words[0])
	if !found {
		return 1
	}
	job := Listing{device = device, scope = line.scope}
	if len(line.words) == 2 {
		job.path = strings.trim_right(line.words[1], "/")
	}
	c := new(Client)
	defer free(c)
	c.data, c.target = &job, device
	c.begin = proc(c: ^Client) {
		job := (^Listing)(c.data)
		ask(c, job.device, job.scope, "zsp.list", list_first(job.path), proc(a: ^Ask) {
			job := (^Listing)(a.c.data)
			defer ask_free(a)
			if why := ask_failure(a); why != "" {
				say(os.stderr, job.path, ": ", why, "\n")
				client_stop(a.c)
				return
			}
			entries, sound := entries_of(a)
			if !sound {
				say(os.stderr, "the listing makes no sense\n")
				client_stop(a.c)
				return
			}
			if len(entries) > 0 || !strings.contains(job.path, "/") {
				entries_print(entries[:])
				job.ok = true
				client_stop(a.c)
				return
			}
			// Nothing in it: an empty folder, or a file, which its folder's listing tells apart.
			parent := job.path[:strings.last_index_byte(job.path, '/')]
			ask(a.c, job.device, job.scope, "zsp.list", list_first(parent), proc(a: ^Ask) {
				job := (^Listing)(a.c.data)
				defer ask_free(a)
				entries, sound := entries_of(a)
				if ask_failure(a) == "" && sound {
					for e in entries {
						if e.name == last_part(job.path) && e.kind != ENTRY_FOLDER {
							entries_print({e})
						}
					}
				}
				job.ok = true
				client_stop(a.c)
			})
		})
	}
	if !client_open(c, dir) {
		say(os.stderr, c.failure, "\n")
		return 1
	}
	if !client_run(c) {
		say(os.stderr, c.failure, "\n")
		return 1
	}
	return 0 if job.ok else 1
}

@(private = "file")
list_first :: proc(path: string) -> []byte {
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&w, transmute([]byte)path)
	return w[:]
}

// A line each: size, time, name, a folder's with '/' after it.
@(private = "file")
entries_print :: proc(entries: []Entry) {
	slice.sort_by(entries, proc(a, b: Entry) -> bool {return a.name < b.name})
	b := strings.builder_make(context.temp_allocator)
	for e in entries {
		size := "-"
		if e.kind == ENTRY_FILE {
			buf := make([]byte, 20, context.temp_allocator)
			size = strconv.write_uint(buf, e.size, 10)
		}
		for _ in len(size) ..< 12 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, size)
		strings.write_string(&b, "  ")
		strings.write_string(&b, time_text(e.modified))
		strings.write_string(&b, "  ")
		strings.write_string(&b, e.name)
		strings.write_string(&b, "/\n" if e.kind == ENTRY_FOLDER else "\n")
	}
	say(os.stdout, strings.to_string(b))
}

// A time as "2026-11-26 06:48", in UTC; or "-" where there is none.
@(private = "file")
time_text :: proc(ms: u64) -> string {
	if ms == 0 {
		return "               -"
	}
	t := time.unix(i64(ms / 1000), 0)
	year, month, day := time.date(t)
	hour, minute, _ := time.clock_from_time(t)
	digits :: proc(b: ^strings.Builder, v, width: int) {
		buf: [20]byte
		s := strconv.write_int(buf[:], i64(v), 10)
		for _ in len(s) ..< width {
			strings.write_byte(b, '0')
		}
		strings.write_string(b, s)
	}
	b := strings.builder_make(context.temp_allocator)
	digits(&b, year, 4)
	strings.write_byte(&b, '-')
	digits(&b, int(month), 2)
	strings.write_byte(&b, '-')
	digits(&b, day, 2)
	strings.write_byte(&b, ' ')
	digits(&b, hour, 2)
	strings.write_byte(&b, ':')
	digits(&b, minute, 2)
	return strings.to_string(b)
}

// ---------------------------------------------------------------- get and put

Files_Job :: struct {
	c:        ^Client,
	device:   zsp.Key32,
	scope:    zsp.Scope,
	put:      bool,
	replace:  bool,
	remote:   string, // the file or folder there
	local:    string, // and here
	asked:    string, // where a fetch was asked to go, if anywhere
	probed:   Maybe(Entry), // what the remote path is, as its folder lists it
	then:     proc(j: ^Files_Job), // what comes next: the job itself, once it can begin, or what follows a probe
	folders:  [dynamic]string, // there, within remote, yet to be listed
	listing:  string, // the one being listed
	there:    map[string]Entry, // files there, by their path within remote: for put, what need not be sent
	files:    [dynamic]Job_File, // to carry, by their path within remote and local
	next:     int,
	failed:   bool,
}

Job_File :: struct {
	path:     string, // within remote and local, '/' between; "" when they are the file itself
	size:     u64,
	modified: u64,
}

// zspd get <dir> <device> <remote> [local] [--scope=N]
get :: proc(dir: string, args: []string) -> int {
	line, ok := command_line(args, {.Scope}, 3)
	if !ok || len(line.words) < 2 || len(line.words) > 3 || line.words[1] == "" {
		return usage()
	}
	j := new(Files_Job)
	device, found := device_named(dir, line.words[0])
	if !found {
		return 1
	}
	j.device, j.scope = device, line.scope
	j.remote = strings.trim_right(line.words[1], "/")
	j.asked = line.words[2] if len(line.words) == 3 else ""
	return files_job(dir, j, proc(j: ^Files_Job) {
		if !strings.contains(j.remote, "/") {
			get_folder(j) // a share
			return
		}
		files_probe(j, proc(j: ^Files_Job) {
			e, there := j.probed.?
			switch {
			case !there:
				say(os.stderr, j.remote, ": not found\n")
				j.failed = true
				client_stop(j.c)
			case e.kind == ENTRY_FOLDER:
				get_folder(j)
			case:
				// A file; or something else, a link perhaps, which there is judged by where it leads.
				j.local = j.asked
				name := last_part(j.remote)
				if j.local == "" {
					j.local = name
				} else if strings.has_suffix(j.local, "/") || strings.has_suffix(j.local, filepath.SEPARATOR_STRING) || os.is_dir(j.local) {
					j.local = local_join(j.local, name)
				}
				j.local = strings.clone(j.local)
				append(&j.files, Job_File{"", e.size if e.kind == ENTRY_FILE else NOT_KNOWN, e.modified})
				files_next(j)
			}
		})
	})
}

@(private = "file")
get_folder :: proc(j: ^Files_Job) {
	name := last_part(j.remote)
	j.local = j.asked
	if j.local == "" {
		j.local = name
	} else if strings.has_suffix(j.local, "/") || strings.has_suffix(j.local, filepath.SEPARATOR_STRING) {
		j.local = local_join(j.local, name)
	}
	j.local = strings.clone(j.local)
	append(&j.folders, "")
	files_list(j)
}

// zspd put <dir> <device> <local> <remote> [--scope=N] [--replace]
put :: proc(dir: string, args: []string) -> int {
	line, ok := command_line(args, {.Scope, .Replace}, 3)
	if !ok || len(line.words) != 3 || line.words[1] == "" || line.words[2] == "" {
		return usage()
	}
	j := new(Files_Job)
	device, found := device_named(dir, line.words[0])
	if !found {
		return 1
	}
	j.device, j.scope, j.put, j.replace = device, line.scope, true, line.replace
	local := line.words[1]
	for len(local) > 1 && (strings.has_suffix(local, "/") || strings.has_suffix(local, filepath.SEPARATOR_STRING)) {
		local = local[:len(local) - 1]
	}
	j.local = local
	info, err := os.stat(local, context.temp_allocator)
	if err != nil || (info.type != .Regular && info.type != .Directory) {
		say(os.stderr, local, ": no such file or folder here\n")
		return 1
	}
	remote := line.words[2]
	if !strings.contains(strings.trim_right(remote, "/"), "/") || strings.has_suffix(remote, "/") {
		remote = remote_join(strings.trim_right(remote, "/"), local_name(local))
	}
	j.remote = strings.clone(remote)
	if info.type == .Directory {
		if !files_walk(j, "") {
			return 1
		}
		slice.sort_by(j.files[:], proc(a, b: Job_File) -> bool {return a.path < b.path})
		return files_job(dir, j, proc(j: ^Files_Job) {
			append(&j.folders, "")
			files_list(j)
		})
	}
	append(&j.files, Job_File{"", u64(info.size), unix_ms(info.modification_time)})
	return files_job(dir, j, proc(j: ^Files_Job) {
		files_probe(j, proc(j: ^Files_Job) {
			if e, there := j.probed.?; there && e.kind == ENTRY_FOLDER {
				// A folder: the file goes into it, and what is there by that name is what counts.
				j.remote = strings.clone(remote_join(j.remote, local_name(j.local)))
				files_probe(j, put_probed)
				return
			}
			put_probed(j)
		})
	})
}

// The name of a file or folder here, as it is to be called there: "." is called as the folder it is.
@(private = "file")
local_name :: proc(path: string) -> string {
	name := filepath.base(path)
	if name == "." || name == ".." {
		if absolute, err := os.get_absolute_path(path, context.temp_allocator); err == nil {
			name = filepath.base(absolute)
		}
	}
	return name
}

@(private = "file")
put_probed :: proc(j: ^Files_Job) {
	if e, there := j.probed.?; there && e.kind == ENTRY_FILE {
		j.there[""] = e
	}
	files_next(j)
}

// Every file in a folder here, and in its folders, as what to send.
@(private = "file")
files_walk :: proc(j: ^Files_Job, rel: string) -> bool {
	f, err := os.open(local_join(j.local, rel))
	if err != nil {
		say(os.stderr, local_join(j.local, rel), ": cannot be read\n")
		return false
	}
	defer os.close(f)
	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)
	for info in os.read_directory_iterator(&it) {
		if strings.has_suffix(info.name, host.PART) || strings.has_suffix(info.name, host.PART + ".meta") {
			continue // halves of what is being fetched here
		}
		path := strings.clone(remote_join(rel, info.name))
		kind, size, modified := info.type, info.size, info.modification_time
		if kind == .Symlink {
			// Followed to a file; never to a folder, which could lead round in a circle.
			if target, serr := os.stat(info.fullpath, context.temp_allocator); serr == nil && target.type == .Regular {
				kind, size, modified = .Regular, target.size, target.modification_time
			}
		}
		#partial switch kind {
		case .Regular:
			append(&j.files, Job_File{path, u64(size), unix_ms(modified)})
		case .Directory:
			files_walk(j, path) or_return
		case:
			say(os.stderr, local_join(j.local, path), ": neither a file nor a folder, and left out\n")
		}
	}
	return true
}

// Runs a job: `begin` once the device can be called; then whatever each step leads to, until it stops.
@(private = "file")
files_job :: proc(dir: string, j: ^Files_Job, begin: proc(j: ^Files_Job)) -> int {
	c := new(Client)
	defer free(c)
	j.c = c
	j.then = begin
	c.data, c.target = j, j.device
	c.begin = proc(c: ^Client) {
		j := (^Files_Job)(c.data)
		j.then(j)
	}
	if !client_open(c, dir) {
		say(os.stderr, c.failure, "\n")
		return 1
	}
	if !client_run(c) {
		say(os.stderr, c.failure, "\n")
		return 1
	}
	return 1 if j.failed else 0
}

// What the remote path is, as its folder lists it; then `then`.
@(private = "file")
files_probe :: proc(j: ^Files_Job, then: proc(j: ^Files_Job)) {
	j.then = then
	j.probed = nil
	slash := strings.last_index_byte(j.remote, '/')
	ask(j.c, j.device, j.scope, "zsp.list", list_first(j.remote[:max(slash, 0)]), proc(a: ^Ask) {
		j := (^Files_Job)(a.c.data)
		defer ask_free(a)
		entries, sound := entries_of(a)
		why := ask_failure(a)
		if why == "" && !sound {
			why = "the listing makes no sense"
		}
		if why != "" && !(len(a.replies) > 0 && len(a.replies[0]) > 0 && host.Status(a.replies[0][0]) == .Not_Found) {
			say(os.stderr, j.remote, ": ", why, "\n")
			j.failed = true
			client_stop(a.c)
			return
		}
		for e in entries {
			if e.name == last_part(j.remote) {
				kept := e
				kept.name = strings.clone(e.name)
				j.probed = kept
			}
		}
		j.then(j)
	})
}

// How deep a folder is fetched or sent, at most.
@(private = "file")
MAX_DEPTH :: 64

// Whether a listed name is one name: not one that would lead elsewhere, on any system, were it joined to a path.
@(private = "file")
entry_name_sound :: proc(name: string) -> bool {
	return name != "" && name != "." && name != ".." && !strings.contains_any(name, "/\\:\x00")
}

// Lists the next folder there, if any is yet to be listed; else carries the files.
@(private = "file")
files_list :: proc(j: ^Files_Job) {
	if len(j.folders) == 0 {
		files_next(j)
		return
	}
	delete(j.listing)
	j.listing = pop_front(&j.folders)
	ask(j.c, j.device, j.scope, "zsp.list", list_first(remote_join(j.remote, j.listing)), proc(a: ^Ask) {
		j := (^Files_Job)(a.c.data)
		rel := j.listing
		defer ask_free(a)
		entries, sound := entries_of(a)
		why := ask_failure(a)
		if why == "" && !sound {
			why = "the listing makes no sense"
		}
		if why != "" {
			// For a send, a folder not there yet is one there is nothing in.
			if !(j.put && len(a.replies) > 0 && len(a.replies[0]) > 0 && host.Status(a.replies[0][0]) == .Not_Found) {
				say(os.stderr, remote_join(j.remote, rel), ": ", why, "\n")
				j.failed = true
			}
			files_list(j)
			return
		}
		for e in entries {
			// A name is one name, within the folder it is in: nothing that leads out of it, here or there, nor any
			// deeper than a folder can sensibly be.
			if !entry_name_sound(e.name) || strings.count(rel, "/") >= MAX_DEPTH {
				say(os.stderr, remote_join(j.remote, rel), ": the listing makes no sense: ", e.name, "\n")
				j.failed = true
				continue
			}
			path := strings.clone(remote_join(rel, e.name))
			switch {
			case e.kind == ENTRY_FOLDER:
				append(&j.folders, path)
			case e.kind == ENTRY_FILE && j.put:
				kept := e
				kept.name = path
				j.there[path] = kept
			case e.kind == ENTRY_FILE:
				append(&j.files, Job_File{path, e.size, e.modified})
			case !j.put:
				append(&j.files, Job_File{path, NOT_KNOWN, e.modified}) // a link perhaps, judged there by where it leads
			}
		}
		files_list(j)
	})
}

// Carries the next file that is not where it is going already; once all are, stops.
@(private = "file")
files_next :: proc(j: ^Files_Job) {
	for j.next < len(j.files) {
		f := j.files[j.next]
		j.next += 1
		remote := remote_join(j.remote, f.path)
		local := local_join(j.local, f.path) if f.path != "" else j.local
		if j.put {
			if e, there := j.there[f.path]; there && e.size == f.size && e.modified == f.modified {
				say(os.stdout, remote, "  there already\n")
				continue
			}
		} else {
			if info, err := os.stat(local, context.temp_allocator); err == nil && info.type == .Regular && u64(info.size) == f.size && unix_ms(info.modification_time) == f.modified {
				say(os.stdout, local, "  here already\n")
				continue
			}
			if dir := filepath.dir(local); dir != "" && !os.is_dir(dir) {
				os.make_directory_all(dir)
			}
		}
		if files_carry(j, local, remote) {
			return
		}
	}
	client_stop(j.c)
}

// ---------------------------------------------------------------- one file, by a call of its own

@(private = "file")
Carried :: struct {
	using handler: host.Call_Handler,
	j:    ^Files_Job,
	call: u64,
	t:    ^host.Transfer,
	name: string, // as it is spoken of: here for a fetch, there for a send; owned
}

// Begins carrying a file. False if it could not even begin, which is said.
@(private = "file")
files_carry :: proc(j: ^Files_Job, local, remote: string) -> bool {
	x := new(Carried)
	x.j = j
	x.name = strings.clone(remote if j.put else local)
	port := host.Port {
		data = x,
		send = proc(data: rawptr, bytes: []byte) -> bool {
			x := (^Carried)(data)
			return client_send(x.j.c, x.call, bytes)
		},
		room = proc(data: rawptr) -> int {
			x := (^Carried)(data)
			return client_room(x.j.c, x.call)
		},
		end = proc(data: rawptr) {
			x := (^Carried)(data)
			client_end(x.j.c, x.call)
		},
		consumed = proc(data: rawptr, n: int) {
			x := (^Carried)(data)
			client_consumed(x.j.c, x.call, n)
		},
	}
	first: []byte
	if j.put {
		x.t, first = host.transfer_put(local, remote, j.replace, true, port, carried_done, x)
	} else {
		x.t, first = host.transfer_get(remote, local, port, carried_done, x)
	}
	if x.t == nil {
		say(os.stderr, local, ": cannot be read\n")
		j.failed = true
		delete(x.name)
		free(x)
		return false
	}
	x.data = x
	x.on_data = proc(h: ^host.Call_Handler, call: u64, bytes: []byte) -> bool {
		return host.transfer_on_data((^Carried)(h.data).t, bytes)
	}
	x.on_room = proc(h: ^host.Call_Handler, call: u64) {
		host.transfer_pump((^Carried)(h.data).t)
	}
	x.on_end = proc(h: ^host.Call_Handler, call: u64) {
		x := (^Carried)(h.data)
		host.transfer_on_end(x.t)
		client_end(x.j.c, call)
		carried_free(x)
	}
	x.on_fault = proc(h: ^host.Call_Handler, call: u64, fault: zsp.Call_Fault) {
		x := (^Carried)(h.data)
		host.transfer_on_fault(x.t, fault)
		carried_free(x)
	}
	x.call = client_call(j.c, j.device, j.scope, "zsp.put" if j.put else "zsp.get", first, &x.handler)
	if x.call == 0 {
		say(os.stderr, x.name, ": the call cannot be made\n")
		j.failed = true
		host.transfer_free(x.t)
		delete(x.name)
		free(x)
		return false
	}
	return true
}

// How a file went, once that is known: a line on standard output, or why not on standard error.
@(private = "file")
carried_done :: proc(data: rawptr, t: ^host.Transfer) {
	x := (^Carried)(data)
	result := t.result
	if result.status != .Ok {
		why := status_text(result.status)
		if result.status == .Exists {
			why = "there already, and not as it is here: --replace sends it over what is there"
		}
		if result.reason != "" {
			why = strings.concatenate({why, ": ", result.reason}, context.temp_allocator)
		}
		say(os.stderr, x.name, ": ", why, "\n")
		x.j.failed = true
		return
	}
	buf: [20]byte
	say(os.stdout, x.name, "  ", strconv.write_uint(buf[:], result.bytes, 10), " bytes")
	if result.resumed > 0 {
		say(os.stdout, ", taken up at ", strconv.write_uint(buf[:], result.resumed, 10))
	}
	say(os.stdout, "\n")
}

// The call is over: the next file goes.
@(private = "file")
carried_free :: proc(x: ^Carried) {
	j := x.j
	host.transfer_free(x.t)
	delete(x.name)
	free(x)
	files_next(j)
}
