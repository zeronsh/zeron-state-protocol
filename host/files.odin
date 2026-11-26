package host

import "core:crypto/sha2"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "../zsp"

// Files of a share, by name: listed (zsp.list), fetched (zsp.get) and sent (zsp.put), any size, resumed after a break
// from where it left off, and checked end to end. A path is the share's name and then the path within it, with '/'
// between, whatever the system; nothing in it may lead out of the share, by '..' or by a link, which is judged by
// where a file opened really is.
//
// A file is hashed in chunks of a MiB, each chunk by SHA-256, and the file by SHA-256 of its chunks' hashes in order:
// so what was checked before a break is never read again to check it after. Each chunk's hash follows its bytes. A
// transfer is resumed at a chunk's end, and only if the file is the one it was: the same size, time, and identity on
// its disk (FILE_ID); otherwise it begins again.
//
//     get:  path bytes ‖ offset varint ‖ identity bytes          → status ‖ size varint ‖ modified (ms) varint ‖ identity bytes ‖ from varint
//     put:  path bytes ‖ size varint ‖ modified varint ‖ identity bytes ‖ flags (1: 1 replace, 2 make the folders)
//                                                                → status ‖ from varint
//     then, from whoever has the file:   1 ‖ bytes · 2 ‖ the hash of the chunk just ended (32) · 3 ‖ status ‖ [the file's hash (32)]
//     put ends with the receiver's verdict: status (1), once the sender has ended.
//     list: path bytes                                          → status, then messages of entries, then the end
//           entry = kind (1: 1 file, 2 folder, 3 other) ‖ name bytes ‖ size varint ‖ modified varint

CHUNK :: 1 << 20
FILE_READ :: 64 << 10 // at most, in one message
PART :: ".zsp-part" // what a file being received is called until it is whole
SYNC_EVERY :: 16 * CHUNK // a part is made durable this often, so that a crash loses no more

@(private)
Hashing :: struct {
	chunk:  sha2.Context_256, // of the chunk under way
	filled: int, // bytes of it
	file:   sha2.Context_256, // of the chunks' hashes
}

@(private)
hashing_init :: proc(h: ^Hashing) {
	sha2.init_256(&h.chunk)
	sha2.init_256(&h.file)
	h.filled = 0
}

// Feeds bytes; returns how many were taken before a chunk ended, and whether one did.
@(private)
hashing_feed :: proc(h: ^Hashing, bytes: []byte) -> (taken: int, ended: bool) {
	taken = min(len(bytes), CHUNK - h.filled)
	sha2.update(&h.chunk, bytes[:taken])
	h.filled += taken
	return taken, h.filled == CHUNK
}

// Ends the chunk under way, if any of it is; its hash goes into the file's.
@(private)
hashing_chunk :: proc(h: ^Hashing) -> (hash: [32]byte) {
	sha2.final(&h.chunk, hash[:])
	sha2.update(&h.file, hash[:])
	sha2.init_256(&h.chunk)
	h.filled = 0
	return
}

// ---------------------------------------------------------------- paths

// The share named first in a path, and where the rest of it is here: if the caller may, and it stays within.
@(private)
files_resolve :: proc(sp: ^Space, from: Caller, scope: zsp.Scope, path: string, write: bool) -> (share: ^Share, root, full: string, status: Status) {
	name, rest := path, ""
	if slash := strings.index_byte(path, '/'); slash >= 0 {
		name, rest = path[:slash], path[slash + 1:]
	}
	share, status = share_for(sp, from, scope, .Files, name, write)
	if status != .Ok {
		return
	}
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	append(&parts, share.path)
	for part in strings.split_iterator(&rest, "/") {
		if part == "" {
			continue
		}
		if part == "." || part == ".." || strings.contains_any(part, "\x00\\:") || strings.has_suffix(part, PART) {
			return nil, "", "", .Denied
		}
		append(&parts, part)
	}
	root_real, ok := path_real(share.path)
	if !ok {
		return nil, "", "", .Not_Found
	}
	full, _ = filepath.join(parts[:], context.temp_allocator)
	return share, root_real, full, .Ok
}

// Whether a file opened is within the share, wherever its path led.
@(private)
files_within :: proc(f: ^os.File, root: string) -> bool {
	real, ok := file_real(f)
	if !ok {
		return false
	}
	return real == root || (strings.has_prefix(real, root) && (real[len(root)] == PATH_SEPARATOR || strings.has_suffix(root, "/") || strings.has_suffix(root, "\\")))
}

// What says a file is the one it was: its size, when it was last written, and which it is on its disk.
@(private)
file_identity :: proc(f: ^os.File) -> (identity: []byte, info: os.File_Info, ok: bool) {
	err: os.Error
	info, err = os.fstat(f, context.temp_allocator)
	if err != nil {
		return
	}
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&w, u64(info.size))
	zsp.write_varint(&w, u64(time.time_to_unix_nano(info.modification_time)))
	zsp.write_varint(&w, u64(info.inode))
	zsp.write_varint(&w, u64(info.inode >> 64))
	zsp.write_varint(&w, info.device)
	return w[:], info, true
}

@(private)
unix_ms :: proc(t: time.Time) -> u64 {
	return u64(max(time.time_to_unix_nano(t), 0) / 1_000_000)
}

// ---------------------------------------------------------------- list

@(private)
serve_list :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	r := zsp.Reader{buf = first}
	path := string(zsp.read_bytes(&r))
	if r.bad {
		status_send(sp, call, .Malformed)
		return refused_handler(), .Cancelled
	}
	w := make([dynamic]byte, 0, 4096, context.temp_allocator)
	flush :: proc(sp: ^Space, call: u64, w: ^[dynamic]byte) {
		if len(w) > 0 {
			call_send(sp, call, w[:])
			clear(w)
		}
	}
	entry :: proc(sp: ^Space, call: u64, w: ^[dynamic]byte, kind: u8, name: string, size: u64, modified: u64) {
		if len(w) + len(name) + 32 > FILE_READ {
			flush(sp, call, w)
		}
		append(w, kind)
		zsp.write_bytes(w, transmute([]byte)name)
		zsp.write_varint(w, size)
		zsp.write_varint(w, modified)
	}
	if path == "" {
		// The shares of files, as folders.
		status_send(sp, call, .Ok)
		for s in sp.shares {
			if _, status := share_for(sp, from, scope, .Files, s.name); s.kind == .Files && s.scope == scope && status == .Ok {
				entry(sp, call, &w, 2, s.name, 0, 0)
			}
		}
		flush(sp, call, &w)
		call_end(sp, call)
		return refused_handler(), .Cancelled
	}
	share, root, full, status := files_resolve(sp, from, scope, path, false)
	if status != .Ok {
		audit(sp, {device = from.device, subject = string(from.who), scope = scope, service = "files", detail = path, event = .Denied})
		status_send(sp, call, status)
		return refused_handler(), .Cancelled
	}
	_ = share
	f, err := os.open(full, {.Read})
	if err != nil {
		status_send(sp, call, .Not_Found)
		return refused_handler(), .Cancelled
	}
	defer os.close(f)
	if !files_within(f, root) {
		status_send(sp, call, .Denied)
		return refused_handler(), .Cancelled
	}
	// Listed as it is read, a message at a time, so that a folder of a million names costs no more than one.
	status_send(sp, call, .Ok)
	it := os.read_directory_iterator_create(f)
	defer os.read_directory_iterator_destroy(&it)
	for info in os.read_directory_iterator(&it) {
		if strings.has_suffix(info.name, PART) || strings.has_suffix(info.name, PART + ".meta") {
			continue
		}
		kind: u8 = 1 if info.type == .Regular else 2 if info.type == .Directory else 3
		entry(sp, call, &w, kind, info.name, u64(max(info.size, 0)), unix_ms(info.modification_time))
	}
	flush(sp, call, &w)
	call_end(sp, call)
	return refused_handler(), .Cancelled
}

// ---------------------------------------------------------------- get

@(private)
Get :: struct {
	using handler: Call_Handler,
	sp:      ^Space,
	call:    u64,
	f:       ^os.File,
	path:    string, // owned, as asked for
	caller:  zsp.Key32,
	scope:   zsp.Scope,
	size:    u64,
	at:      u64, // the next byte to send
	from:    u64,
	hashing: Hashing,
	identity: []byte, // owned
	over:    bool,
}

@(private)
serve_get :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	r := zsp.Reader{buf = first}
	path := string(zsp.read_bytes(&r))
	offset := zsp.read_varint(&r)
	known := zsp.read_bytes(&r)
	if r.bad {
		status_send(sp, call, .Malformed)
		return refused_handler(), .Cancelled
	}
	_, root, full, status := files_resolve(sp, from, scope, path, false)
	if status != .Ok {
		audit(sp, {device = from.device, subject = string(from.who), scope = scope, service = "files", detail = path, event = .Denied})
		status_send(sp, call, status)
		return refused_handler(), .Cancelled
	}
	f, err := os.open(full, {.Read})
	if err != nil {
		status_send(sp, call, .Not_Found)
		return refused_handler(), .Cancelled
	}
	identity, info, ok := file_identity(f)
	if !ok || !files_within(f, root) || info.type != .Regular {
		os.close(f)
		status_send(sp, call, .Denied if ok && info.type == .Regular else .Not_Found)
		return refused_handler(), .Cancelled
	}
	g := new(Get)
	g.sp, g.call, g.f, g.caller, g.scope = sp, call, f, from.device, scope
	g.path = strings.clone(path)
	g.identity = make([]byte, len(identity))
	copy(g.identity, identity)
	g.size = u64(info.size)
	// From where it broke off, if it is the file it was, and the break at a chunk's end.
	if offset > 0 && offset % CHUNK == 0 && offset <= g.size && string(known) == string(identity) {
		g.from = offset
	}
	g.at = g.from
	hashing_init(&g.hashing)
	g.data = g
	g.on_room = proc(h: ^Call_Handler, call: u64) {get_pump((^Get)(h.data))}
	g.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {
		g := (^Get)(h.data)
		g.over = true
		get_free(g)
	}
	g.on_end = proc(h: ^Call_Handler, call: u64) {
		g := (^Get)(h.data)
		if g.over {
			get_free(g) // ours was said already
		}
	}
	g.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {return true}
	audit(sp, {device = from.device, subject = string(from.who), scope = scope, service = "files", detail = strings.concatenate({"get ", path}, context.temp_allocator), event = .Open})
	more := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&more, g.size)
	zsp.write_varint(&more, unix_ms(info.modification_time))
	zsp.write_bytes(&more, g.identity)
	zsp.write_varint(&more, g.from)
	status_send(sp, call, .Ok, more = more[:])
	service_begin(sp, call, from, scope, .Files, path[:strings.index_byte(path, '/') if strings.contains_rune(path, '/') else len(path)], false, false, g, proc(data: rawptr) {
		g := (^Get)(data)
		g.over = true
		get_free(g)
	})
	get_pump(g)
	return &g.handler, .Cancelled
}

// Sends as much as credit allows: bytes, and after each chunk its hash; at the end, the verdict and the file's hash.
@(private)
get_pump :: proc(g: ^Get) {
	if g.over {
		return
	}
	buf: [1 + FILE_READ]byte
	for {
		room := call_room(g.sp, g.call)
		if room < 1 + 32 + 1 + 32 {
			return // on_room says when to go on
		}
		if g.at < g.size {
			n := min(room - 1, FILE_READ, int(g.size - g.at), CHUNK - g.hashing.filled)
			got, err := os.read_at(g.f, buf[1:][:n], i64(g.at))
			if err != nil || got == 0 {
				get_finish(g, .Changed) // it shrank, or went
				return
			}
			buf[0] = 1
			call_send(g.sp, g.call, buf[:1 + got])
			hashing_feed(&g.hashing, buf[1:][:got])
			g.at += u64(got)
			if g.hashing.filled < CHUNK && g.at < g.size {
				continue
			}
		}
		if g.hashing.filled > 0 {
			hash := hashing_chunk(&g.hashing)
			w: [33]byte
			w[0] = 2
			copy(w[1:], hash[:])
			call_send(g.sp, g.call, w[:])
		}
		if g.at == g.size {
			// Still the file it was, all the while?
			identity, _, ok := file_identity(g.f)
			get_finish(g, .Ok if ok && string(identity) == string(g.identity) else .Changed)
			return
		}
	}
}

@(private)
get_finish :: proc(g: ^Get, status: Status) {
	w: [2 + 32]byte
	w[0], w[1] = 3, u8(status)
	n := 2
	if status == .Ok && g.from == 0 {
		hash: [32]byte
		sha2.final(&g.hashing.file, hash[:])
		copy(w[2:], hash[:])
		n += 32
	}
	call_send(g.sp, g.call, w[:n])
	audit(g.sp, {device = g.caller, scope = g.scope, service = "files", detail = strings.concatenate({"get ", g.path}, context.temp_allocator), event = .Close, bytes_out = g.at - g.from, peer = "" if status == .Ok else "changed while sent"})
	g.over = true
	service_end(g.sp, g.call)
	call := g.call
	sp := g.sp
	if host_call_find(sp, call) != nil {
		heard := host_call_find(sp, call).heard_end
		call_end(sp, call)
		if heard {
			get_free(g)
		}
	} else {
		get_free(g)
	}
}

@(private)
get_free :: proc(g: ^Get) {
	if g.f == nil {
		return
	}
	service_end(g.sp, g.call)
	os.close(g.f)
	g.f = nil
	delete(g.path)
	delete(g.identity)
	free(g)
}

// ---------------------------------------------------------------- put

@(private)
Put :: struct {
	using handler: Call_Handler,
	sp:       ^Space,
	call:     u64,
	caller:   zsp.Key32,
	scope:    zsp.Scope,
	path:     string, // owned, as asked for
	target:   string, // owned, here
	part:     ^os.File,
	meta:     ^os.File, // the source's identity, and the hashes of the chunks taken
	size:     u64,
	modified: u64,
	at:       u64,
	from:     u64,
	synced:   u64,
	hashing:  Hashing,
	pending:  [32]byte, // the hash of the chunk just ended, awaiting the sender's
	awaiting: bool,
	done:     bool, // the file is whole and in place, or failed
	status:   Status,
	freed:    bool,
}

@(private)
serve_put :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	r := zsp.Reader{buf = first}
	path := string(zsp.read_bytes(&r))
	size := zsp.read_varint(&r)
	modified := zsp.read_varint(&r)
	source := zsp.read_bytes(&r)
	flags := zsp.read_u8(&r)
	if r.bad || len(source) > 64 || !strings.contains_rune(path, '/') {
		status_send(sp, call, .Malformed)
		return refused_handler(), .Cancelled
	}
	_, root, full, status := files_resolve(sp, from, scope, path, true)
	if status == .Ok && strings.trim_suffix(path, "/") == path[:strings.index_byte(path, '/')] {
		status = .Denied // the share itself is no file
	}
	if status != .Ok {
		audit(sp, {device = from.device, subject = string(from.who), scope = scope, service = "files", detail = strings.concatenate({"put ", path}, context.temp_allocator), event = .Denied})
		status_send(sp, call, status)
		return refused_handler(), .Cancelled
	}
	dir := filepath.dir(full)
	if flags & 2 != 0 && !os.exists(dir) {
		if !files_mkdirs(dir, root) {
			status_send(sp, call, .Denied)
			return refused_handler(), .Cancelled
		}
	}
	if os.exists(full) && flags & 1 == 0 {
		status_send(sp, call, .Exists)
		return refused_handler(), .Cancelled
	}
	part_path := path_with(full, PART)
	meta_path := path_with(part_path, ".meta")
	part, perr := os.open(part_path, {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
	if perr != nil {
		status_send(sp, call, .Not_Found if !os.exists(dir) else .Failed, "cannot write there")
		return refused_handler(), .Cancelled
	}
	if !files_within(part, root) {
		os.close(part)
		status_send(sp, call, .Denied)
		return refused_handler(), .Cancelled
	}
	p := new(Put)
	p.sp, p.call, p.caller, p.scope, p.part = sp, call, from.device, scope, part
	p.path = strings.clone(path)
	p.target = strings.clone(full)
	p.size, p.modified = size, modified
	hashing_init(&p.hashing)
	// What was taken before from this same source, chunk by chunk, if anything was.
	if kept, err := os.read_entire_file(meta_path, context.temp_allocator); err == nil {
		mr := zsp.Reader{buf = kept}
		was := zsp.read_bytes(&mr)
		was_size := zsp.read_varint(&mr)
		chunks := (len(kept) - mr.pos) / 32
		part_size, _ := os.file_size(part)
		if !mr.bad && string(was) == string(source) && was_size == size && u64(chunks) * CHUNK <= size && i64(chunks) * CHUNK <= part_size {
			chunks = part_good_chunks(part, kept[mr.pos:][:chunks * 32])
			for i in 0 ..< chunks {
				sha2.update(&p.hashing.file, kept[mr.pos + i * 32:][:32])
			}
			p.from = u64(chunks) * CHUNK
		}
	}
	if p.from == 0 {
		os.truncate(part, 0)
	} else {
		os.truncate(part, i64(p.from))
	}
	p.at, p.synced = p.from, p.from
	meta, merr := os.open(meta_path, {.Read, .Write, .Create} if p.from > 0 else {.Read, .Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if merr != nil {
		put_free(p)
		status_send(sp, call, .Failed, "cannot write there")
		return refused_handler(), .Cancelled
	}
	p.meta = meta
	if p.from == 0 {
		w := make([dynamic]byte, context.temp_allocator)
		zsp.write_bytes(&w, source)
		zsp.write_varint(&w, size)
		os.write(meta, w[:])
	} else {
		at, _ := os.file_size(meta)
		chunks := p.from / CHUNK
		// Keep exactly the header and the hashes of the chunks kept.
		mr := zsp.Reader{buf = make([]byte, at, context.temp_allocator)}
		os.read_at(meta, mr.buf, 0)
		_ = zsp.read_bytes(&mr)
		_ = zsp.read_varint(&mr)
		os.truncate(meta, i64(mr.pos) + i64(chunks) * 32)
		os.seek(meta, 0, .End)
	}
	p.data = p
	p.on_data = put_on_data
	p.on_end = put_on_end
	p.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {
		p := (^Put)(h.data)
		put_sync(p) // what came is kept, for a resumption
		put_free(p)
	}
	audit(sp, {device = from.device, subject = string(from.who), scope = scope, service = "files", detail = strings.concatenate({"put ", path}, context.temp_allocator), event = .Open})
	more := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&more, p.from)
	status_send(sp, call, .Ok, more = more[:])
	service_begin(sp, call, from, scope, .Files, path[:strings.index_byte(path, '/')], true, false, p, proc(data: rawptr) {
		p := (^Put)(data)
		put_sync(p)
		put_free(p)
	})
	return &p.handler, .Cancelled
}

// Makes the folders on the way to `dir`, each checked to be within the share as it is made.
@(private)
files_mkdirs :: proc(dir, root: string) -> bool {
	if os.exists(dir) {
		real, ok := path_real(dir)
		return ok && (real == root || strings.has_prefix(real, root))
	}
	parent := filepath.dir(dir)
	if parent == dir || !files_mkdirs(parent, root) {
		return false
	}
	if os.make_directory(dir) != nil {
		return false
	}
	real, ok := path_real(dir)
	return ok && strings.has_prefix(real, root)
}

@(private)
put_on_data :: proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
	p := (^Put)(h.data)
	if p.done || len(bytes) == 0 {
		return true
	}
	payload := bytes[1:]
	switch bytes[0] {
	case 1:
		if p.awaiting || p.at + u64(len(payload)) > p.size {
			put_fail(p, .Malformed)
			return true
		}
		for len(payload) > 0 {
			taken, ended := hashing_feed(&p.hashing, payload)
			if n, err := os.write_at(p.part, payload[:taken], i64(p.at)); err != nil || n != taken {
				put_fail(p, .Failed)
				return true
			}
			p.at += u64(taken)
			payload = payload[taken:]
			if ended || p.at == p.size {
				p.pending = hashing_chunk(&p.hashing)
				p.awaiting = true
				if len(payload) > 0 {
					put_fail(p, .Malformed) // a chunk's hash comes between its bytes and the next chunk's
					return true
				}
			}
		}
	case 2:
		if !p.awaiting || len(payload) != 32 || string(payload) != string(p.pending[:]) {
			put_fail(p, .Changed)
			return true
		}
		p.awaiting = false
		os.write(p.meta, payload) // taken, and known good
		if p.at - p.synced >= SYNC_EVERY {
			put_sync(p)
		}
	case 3:
		if p.awaiting || p.at != p.size || len(payload) < 1 || Status(payload[0]) != .Ok {
			put_fail(p, .Changed if len(payload) > 0 && Status(payload[0]) == .Changed else .Malformed)
			return true
		}
		whole: [32]byte
		sha2.final(&p.hashing.file, whole[:])
		if len(payload) == 33 && string(payload[1:]) != string(whole[:]) {
			put_fail(p, .Changed)
			return true
		}
		put_commit(p)
	case:
		put_fail(p, .Malformed)
	}
	return true
}

// Whole and checked: made durable, put in place, its time set as the sender's, its record of progress let go.
@(private)
put_commit :: proc(p: ^Put) {
	p.done = true
	put_sync(p)
	os.close(p.part)
	p.part = nil
	os.close(p.meta)
	p.meta = nil
	part_path := path_with(p.target, PART)
	modified := time.unix(i64(p.modified / 1000), i64(p.modified % 1000) * 1_000_000)
	os.change_times(part_path, modified, modified)
	if os.rename(part_path, p.target) != nil {
		p.status = .Failed
	} else {
		os.remove(path_with(part_path, ".meta"))
		p.status = .Ok
	}
	audit(p.sp, {device = p.caller, scope = p.scope, service = "files", detail = strings.concatenate({"put ", p.path}, context.temp_allocator), event = .Close, bytes_in = p.at - p.from})
}

@(private)
put_fail :: proc(p: ^Put, status: Status) {
	p.done = true
	p.status = status
	audit(p.sp, {device = p.caller, scope = p.scope, service = "files", detail = strings.concatenate({"put ", p.path}, context.temp_allocator), event = .Close, bytes_in = p.at - p.from, peer = "failed"})
	if status == .Changed || status == .Malformed {
		// What came cannot be trusted to resume from.
		if p.meta != nil {
			os.truncate(p.meta, 0)
		}
	}
	w := [1]byte{u8(status)}
	call_send(p.sp, p.call, w[:])
	call_end(p.sp, p.call)
}

@(private)
put_on_end :: proc(h: ^Call_Handler, call: u64) {
	p := (^Put)(h.data)
	if !p.done {
		put_fail(p, .Malformed) // it ended before the file did
	} else if c := host_call_find(p.sp, call); c != nil && !c.ended {
		w := [1]byte{u8(p.status)}
		call_send(p.sp, call, w[:])
		call_end(p.sp, call)
	}
	put_free(p)
}

@(private)
put_sync :: proc(p: ^Put) {
	if p.part != nil {
		os.sync(p.part)
	}
	if p.meta != nil {
		os.sync(p.meta)
	}
	p.synced = p.at
}

@(private)
put_free :: proc(p: ^Put) {
	if p.freed {
		return
	}
	p.freed = true
	service_end(p.sp, p.call)
	if p.part != nil {
		os.close(p.part)
	}
	if p.meta != nil {
		os.close(p.meta)
	}
	delete(p.path)
	delete(p.target)
	free(p)
}

// How many of a part's first chunks are what their recorded hashes say, read again here: what was checked as it came
// may have been changed since on this disk, and nothing is taken up from that it does not still prove.
@(private)
part_good_chunks :: proc(part: ^os.File, hashes: []byte) -> int {
	buf := make([]byte, FILE_READ, context.temp_allocator)
	for i in 0 ..< len(hashes) / 32 {
		h: sha2.Context_256
		sha2.init_256(&h)
		for at := 0; at < CHUNK; at += FILE_READ {
			got, err := os.read_at(part, buf, i64(i * CHUNK + at))
			if err != nil || got != FILE_READ {
				return i
			}
			sha2.update(&h, buf)
		}
		hash: [32]byte
		sha2.final(&h, hash[:])
		if string(hash[:]) != string(hashes[i * 32:][:32]) {
			return i
		}
	}
	return len(hashes) / 32
}
