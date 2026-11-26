package host

import "core:crypto/sha2"
import "core:os"
import "core:strings"
import "core:time"
import "../zsp"

// The other end of zsp.get and zsp.put: a file fetched from a device, or sent to one, resumed after a break from
// where it left off and checked chunk by chunk and whole. A file being fetched is kept, until it is whole, beside where
// it is going, as `<name>.zsp-part`, with what is known of it in `<name>.zsp-part.meta`: which file it is there, and the
// hashes of the chunks taken, so that a fetch begun again takes up where the last stopped, as long as the file there
// is the one it was.
//
// A transfer speaks through a Port: a call made by the host (host_port) or by a local client.

Port :: struct {
	data:     rawptr,
	send:     proc(data: rawptr, bytes: []byte) -> bool,
	room:     proc(data: rawptr) -> int,
	end:      proc(data: rawptr),
	consumed: proc(data: rawptr, n: int),
}

Transfer_Result :: struct {
	status:   Status, // Ok, or what went wrong there or here
	reason:   string,
	bytes:    u64, // carried this time
	resumed:  u64, // where it took up from
	hash:     [32]byte, // of the file, when whole
}

Transfer :: struct {
	port:     Port,
	put:      bool,
	local:    string, // owned
	remote:   string, // owned
	f:        ^os.File, // a part being fetched, or the file being sent
	meta:     ^os.File,
	size:     u64,
	modified: u64,
	at:       u64,
	from:     u64,
	hashing:  Hashing,
	pending:  [32]byte,
	awaiting: bool,
	begun:    bool, // the status came
	sent_all: bool,
	result:   Transfer_Result,
	finished: bool,
	done:     proc(data: rawptr, t: ^Transfer),
	done_data: rawptr,
}

// The first message of a fetch, and a transfer ready to take its answer.
transfer_get :: proc(remote, local: string, port: Port, done: proc(data: rawptr, t: ^Transfer), data: rawptr) -> (t: ^Transfer, first: []byte) {
	t = new(Transfer)
	t.port, t.done, t.done_data = port, done, data
	t.local = strings.clone(local)
	t.remote = strings.clone(remote)
	hashing_init(&t.hashing)
	part := path_with(local, PART)
	known: []byte
	if kept, err := os.read_entire_file(path_with(part, ".meta"), context.temp_allocator); err == nil {
		r := zsp.Reader{buf = kept}
		identity := zsp.read_bytes(&r)
		chunks := (len(kept) - r.pos) / 32
		info, serr := os.stat(part, context.temp_allocator)
		if !r.bad && serr == nil && i64(chunks) * CHUNK <= info.size {
			if f, ferr := os.open(part, {.Read}); ferr == nil {
				chunks = part_good_chunks(f, kept[r.pos:][:chunks * 32])
				os.close(f)
				known = identity
				t.from = u64(chunks) * CHUNK
			}
		}
	}
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&w, transmute([]byte)remote)
	zsp.write_varint(&w, t.from if known != nil else 0)
	zsp.write_bytes(&w, known)
	return t, w[:]
}

// The first message of a send, and a transfer ready to take its answer. Nil if the file cannot be read.
transfer_put :: proc(local, remote: string, replace, folders: bool, port: Port, done: proc(data: rawptr, t: ^Transfer), data: rawptr) -> (t: ^Transfer, first: []byte) {
	f, err := os.open(local, {.Read})
	if err != nil {
		return
	}
	identity, info, ok := file_identity(f)
	if !ok || info.type != .Regular {
		os.close(f)
		return
	}
	t = new(Transfer)
	t.put, t.f, t.port, t.done, t.done_data = true, f, port, done, data
	t.local = strings.clone(local)
	t.remote = strings.clone(remote)
	t.size = u64(info.size)
	t.modified = unix_ms(info.modification_time)
	hashing_init(&t.hashing)
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&w, transmute([]byte)remote)
	zsp.write_varint(&w, t.size)
	zsp.write_varint(&w, t.modified)
	zsp.write_bytes(&w, identity)
	append(&w, (1 if replace else 0) | (2 if folders else 0))
	return t, w[:]
}

// A message of the call. True when it is done with.
transfer_on_data :: proc(t: ^Transfer, bytes: []byte) -> bool {
	if t.finished || len(bytes) == 0 {
		return true
	}
	if !t.begun {
		t.begun = true
		status := Status(bytes[0])
		if status != .Ok {
			transfer_finish(t, status, string(bytes[1:]))
			return true
		}
		r := zsp.Reader{buf = bytes[1:]}
		if t.put {
			from := zsp.read_varint(&r)
			if r.bad || from % CHUNK != 0 || from > t.size {
				transfer_finish(t, .Malformed, "")
				return true
			}
			// What the other end has, it has checked; its hashes, here, are read again, for the file's.
			t.from, t.at = from, 0
			t.result.resumed = from
			buf := make([]byte, FILE_READ, context.temp_allocator)
			for t.at < from {
				n := min(FILE_READ, int(from - t.at), CHUNK - t.hashing.filled)
				got, err := os.read_at(t.f, buf[:n], i64(t.at))
				if err != nil || got != n {
					transfer_finish(t, .Failed, "cannot read the file")
					return true
				}
				if _, ended := hashing_feed(&t.hashing, buf[:got]); ended {
					hashing_chunk(&t.hashing)
				}
				t.at += u64(got)
			}
			transfer_pump(t)
			return true
		}
		t.size = zsp.read_varint(&r)
		t.modified = zsp.read_varint(&r)
		identity := zsp.read_bytes(&r)
		from := zsp.read_varint(&r)
		if r.bad || from > t.size || from % CHUNK != 0 || (from != 0 && from != t.from) {
			transfer_finish(t, .Malformed, "")
			return true
		}
		if !transfer_part_open(t, identity, from) {
			transfer_finish(t, .Failed, "cannot write the file")
			return true
		}
		if t.size == 0 {
			t.awaiting = false
		}
		return true
	}
	if t.put {
		// The verdict, once all is sent.
		transfer_finish(t, Status(bytes[0]), "")
		return true
	}
	payload := bytes[1:]
	switch bytes[0] {
	case 1:
		if t.awaiting || t.at + u64(len(payload)) > t.size {
			transfer_fail(t, .Malformed)
			return true
		}
		for len(payload) > 0 {
			taken, ended := hashing_feed(&t.hashing, payload)
			if n, err := os.write_at(t.f, payload[:taken], i64(t.at)); err != nil || n != taken {
				transfer_fail(t, .Failed)
				return true
			}
			t.at += u64(taken)
			payload = payload[taken:]
			if ended || t.at == t.size {
				t.pending = hashing_chunk(&t.hashing)
				t.awaiting = true
				if len(payload) > 0 {
					transfer_fail(t, .Malformed)
					return true
				}
			}
		}
	case 2:
		if !t.awaiting || len(payload) != 32 || string(payload) != string(t.pending[:]) {
			transfer_fail(t, .Changed)
			return true
		}
		t.awaiting = false
		os.write(t.meta, payload)
	case 3:
		if len(payload) < 1 || Status(payload[0]) != .Ok {
			transfer_fail(t, Status(payload[0]) if len(payload) > 0 else .Malformed)
			return true
		}
		if t.awaiting || t.at != t.size {
			transfer_fail(t, .Malformed)
			return true
		}
		sha2.final(&t.hashing.file, t.result.hash[:])
		if len(payload) == 33 && string(payload[1:]) != string(t.result.hash[:]) {
			transfer_fail(t, .Changed)
			return true
		}
		transfer_commit(t)
	case:
		transfer_fail(t, .Malformed)
	}
	return true
}

// The part, taken up where it was if it is the same file there, or begun afresh.
@(private)
transfer_part_open :: proc(t: ^Transfer, identity: []byte, from: u64) -> bool {
	part := path_with(t.local, PART)
	f, err := os.open(part, {.Read, .Write, .Create}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return false
	}
	t.f = f
	meta_path := path_with(part, ".meta")
	if from == 0 {
		os.truncate(f, 0)
		meta, merr := os.open(meta_path, {.Read, .Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
		if merr != nil {
			return false
		}
		t.meta = meta
		w := make([dynamic]byte, context.temp_allocator)
		zsp.write_bytes(&w, identity)
		os.write(meta, w[:])
	} else {
		meta, merr := os.open(meta_path, {.Read, .Write})
		if merr != nil {
			return false
		}
		t.meta = meta
		kept, _ := os.read_entire_file(meta_path, context.temp_allocator)
		r := zsp.Reader{buf = kept}
		_ = zsp.read_bytes(&r)
		chunks := int(from / CHUNK)
		for i in 0 ..< chunks {
			sha2.update(&t.hashing.file, kept[r.pos + i * 32:][:32])
		}
		os.truncate(meta, i64(r.pos + chunks * 32))
		os.seek(meta, 0, .End)
		os.truncate(f, i64(from))
	}
	t.from, t.at = from, from
	t.result.resumed = from
	return true
}

// Sends as much of the file as credit allows, each chunk followed by its hash; then the end.
transfer_pump :: proc(t: ^Transfer) {
	if !t.put || !t.begun || t.finished || t.sent_all {
		return
	}
	buf: [1 + FILE_READ]byte
	for {
		room := t.port.room(t.port.data)
		if room < 1 + 32 + 2 + 32 {
			return
		}
		if t.at < t.size {
			n := min(room - 1, FILE_READ, int(t.size - t.at), CHUNK - t.hashing.filled)
			got, err := os.read_at(t.f, buf[1:][:n], i64(t.at))
			if err != nil || got == 0 {
				transfer_fail(t, .Changed)
				return
			}
			buf[0] = 1
			t.port.send(t.port.data, buf[:1 + got])
			hashing_feed(&t.hashing, buf[1:][:got])
			t.at += u64(got)
			t.result.bytes += u64(got)
			if t.hashing.filled < CHUNK && t.at < t.size {
				continue
			}
		}
		if t.hashing.filled > 0 {
			hash := hashing_chunk(&t.hashing)
			w: [33]byte
			w[0] = 2
			copy(w[1:], hash[:])
			t.port.send(t.port.data, w[:])
		}
		if t.at == t.size {
			identity, _, ok := file_identity(t.f)
			_ = identity
			w: [34]byte
			w[0], w[1] = 3, u8(Status.Ok if ok else Status.Changed)
			sha2.final(&t.hashing.file, t.result.hash[:])
			copy(w[2:], t.result.hash[:])
			t.port.send(t.port.data, w[:])
			t.sent_all = true
			t.port.end(t.port.data)
			return
		}
	}
}

// The call ended from the other side: a fetch is done if its file is; a send waits for the verdict before it.
transfer_on_end :: proc(t: ^Transfer) {
	if !t.finished {
		transfer_finish(t, .Failed, "it ended early")
	}
}

transfer_on_fault :: proc(t: ^Transfer, fault: zsp.Call_Fault) {
	if !t.finished {
		transfer_finish(t, .Unreachable if fault == .Unreachable else .Denied if fault == .Denied else .Failed, fault_text(fault))
	}
}

@(private)
transfer_commit :: proc(t: ^Transfer) {
	os.sync(t.f)
	os.close(t.f)
	t.f = nil
	os.close(t.meta)
	t.meta = nil
	part := path_with(t.local, PART)
	modified := time.unix(i64(t.modified / 1000), i64(t.modified % 1000) * 1_000_000)
	os.change_times(part, modified, modified)
	if os.rename(part, t.local) != nil {
		transfer_finish(t, .Failed, "cannot put the file in place")
		return
	}
	os.remove(path_with(part, ".meta"))
	t.result.bytes = t.at - t.from
	transfer_finish(t, .Ok, "")
	t.port.end(t.port.data)
}

@(private)
transfer_fail :: proc(t: ^Transfer, status: Status) {
	if status == .Changed || status == .Malformed {
		if t.meta != nil {
			os.truncate(t.meta, 0) // nothing to take up from
		}
	}
	transfer_finish(t, status, "")
	t.port.end(t.port.data)
}

@(private)
transfer_finish :: proc(t: ^Transfer, status: Status, reason: string) {
	if t.finished {
		return
	}
	t.finished = true
	t.result.status = status
	t.result.reason = strings.clone(reason)
	if !t.put && t.f != nil {
		os.sync(t.f) // what came is kept, to take up from
	}
	if t.meta != nil {
		os.sync(t.meta)
	}
	if t.done != nil {
		t.done(t.done_data, t)
	}
}

transfer_free :: proc(t: ^Transfer) {
	if t.f != nil {
		os.close(t.f)
	}
	if t.meta != nil {
		os.close(t.meta)
	}
	delete(t.local)
	delete(t.remote)
	delete(t.result.reason)
	free(t)
}

// ---------------------------------------------------------------- by the host

// A transfer over a call the host makes: the Port, and the handler that feeds it.
@(private)
Host_Transfer :: struct {
	using handler: Call_Handler,
	sp:    ^Space,
	call:  u64,
	t:     ^Transfer,
}

// Fetches a file from a device; `done` is told how it went when that is known.
host_get :: proc(sp: ^Space, device: zsp.Key32, scope: zsp.Scope, remote, local: string, done: proc(data: rawptr, t: ^Transfer), data: rawptr) -> (call: u64) {
	ht := new(Host_Transfer)
	ht.sp = sp
	t, first := transfer_get(remote, local, host_port(ht), done, data)
	ht.t = t
	host_transfer_wire(ht)
	ht.call = host_call(sp, device, scope, "zsp.get", first, &ht.handler)
	if ht.call == 0 {
		transfer_free(t)
		free(ht)
	}
	return ht.call
}

// Sends a file to a device.
host_put :: proc(sp: ^Space, device: zsp.Key32, scope: zsp.Scope, local, remote: string, replace: bool, done: proc(data: rawptr, t: ^Transfer), data: rawptr) -> (call: u64) {
	ht := new(Host_Transfer)
	ht.sp = sp
	t, first := transfer_put(local, remote, replace, true, host_port(ht), done, data)
	if t == nil {
		free(ht)
		return 0
	}
	ht.t = t
	host_transfer_wire(ht)
	ht.call = host_call(sp, device, scope, "zsp.put", first, &ht.handler)
	if ht.call == 0 {
		transfer_free(t)
		free(ht)
	}
	return ht.call
}

@(private)
host_port :: proc(ht: ^Host_Transfer) -> Port {
	return {
		data = ht,
		send = proc(data: rawptr, bytes: []byte) -> bool {
			ht := (^Host_Transfer)(data)
			return call_send(ht.sp, ht.call, bytes)
		},
		room = proc(data: rawptr) -> int {
			ht := (^Host_Transfer)(data)
			return call_room(ht.sp, ht.call)
		},
		end = proc(data: rawptr) {
			ht := (^Host_Transfer)(data)
			call_end(ht.sp, ht.call)
		},
		consumed = proc(data: rawptr, n: int) {
			ht := (^Host_Transfer)(data)
			call_consumed(ht.sp, ht.call, n)
		},
	}
}

@(private)
host_transfer_wire :: proc(ht: ^Host_Transfer) {
	ht.data = ht
	ht.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		return transfer_on_data((^Host_Transfer)(h.data).t, bytes)
	}
	ht.on_room = proc(h: ^Call_Handler, call: u64) {
		transfer_pump((^Host_Transfer)(h.data).t)
	}
	ht.on_end = proc(h: ^Call_Handler, call: u64) {
		ht := (^Host_Transfer)(h.data)
		transfer_on_end(ht.t)
		call_end(ht.sp, call)
		transfer_free(ht.t)
		free(ht)
	}
	ht.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {
		ht := (^Host_Transfer)(h.data)
		transfer_on_fault(ht.t, fault)
		transfer_free(ht.t)
		free(ht)
	}
}

// Gives up on a transfer the host made: the call cancelled, the transfer told and let go. What a fetch had taken is
// kept, to take up from.
host_transfer_cancel :: proc(sp: ^Space, call: u64) {
	c := host_call_find(sp, call)
	if c == nil || c.handler == nil {
		return
	}
	ht := (^Host_Transfer)(c.handler.data)
	call_cancel(sp, call)
	transfer_finish(ht.t, .Failed, "cancelled")
	transfer_free(ht.t)
	free(ht)
}
