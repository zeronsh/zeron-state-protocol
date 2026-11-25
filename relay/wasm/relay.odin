/*
The relay as a WebAssembly module: package zsp, and nothing but, behind a handful of exports. The host
gives it storage, a clock, entropy and an opinion on who may connect; it gives back bytes to send.
*/
package relay

import "base:runtime"
import "core:crypto"
import "../../zsp"

foreign import host "host"

@(default_calling_convention = "contextless")
foreign host {
	log_write :: proc(off: f64, ptr: [^]byte, len: int) ---
	log_read :: proc(off: f64, ptr: [^]byte, len: int) -> bool ---
	log_end :: proc() -> f64 ---
	log_drop :: proc(lo, hi: f64) ---
	log_truncate :: proc(off: f64) ---
	page_read :: proc(no: u32, ptr: rawptr) -> bool ---
	page_write :: proc(no: u32, ptr: [^]byte, len: int) ---
	save_roster :: proc(ptr: [^]byte, len: int) ---
	// Answered by `verdict`, now or later.
	authenticate :: proc(conn: u32, device: ^zsp.Key32, ptr: [^]byte, len: int) ---
	now :: proc() -> f64 ---
}

CHECKPOINT_TAIL :: 256 << 10 // what waking may have to replay
PAGES_KEPT :: 256
MAX_PLAIN :: 60 << 10

Conn :: struct {
	id:       u32,
	open:     bool, // the handshake is done
	channel:  zsp.Channel,
	session:  ^zsp.Session,
	greeting: [zsp.HANDSHAKE_2]byte,
	greet:    bool, // `greeting` is owed
}

node: zsp.Node
secret: zsp.Key32
conns: map[u32]^Conn
pages: map[u32]^zsp.Page
message: [dynamic]byte // handed in and out

@(export)
init :: proc "c" (space_ptr, secret_ptr: ^zsp.Key32, roster: [^]byte, roster_len: int) -> bool {
	context = runtime.default_context()
	secret = secret_ptr^
	disk := zsp.Disk {
		log_write = proc(_: rawptr, off: u64, bytes: []byte) -> bool {
			log_write(f64(off), raw_data(bytes), len(bytes))
			return true
		},
		log_read = proc(_: rawptr, off: u64, into: []byte) -> bool {
			return log_read(f64(off), raw_data(into), len(into))
		},
		log_end = proc(_: rawptr) -> u64 {return u64(log_end())},
		log_drop = proc(_: rawptr, segment: u64) {
			log_drop(f64(segment * zsp.SEGMENT), f64((segment + 1) * zsp.SEGMENT))
		},
		log_truncate = proc(_: rawptr, off: u64) {log_truncate(f64(off))},
		// Storage here is synchronous, and what leaves is held back until it is durable.
		log_sync = proc(_: rawptr) -> bool {return true},
		page = proc(_: rawptr, no: u32) -> ^zsp.Page {
			if pg, ok := pages[no]; ok {
				return pg
			}
			pg := new(zsp.Page)
			if !page_read(no, pg) {
				free(pg)
				return nil
			}
			pages[no] = pg
			return pg
		},
		page_write = proc(_: rawptr, no: u32, bytes: []byte) -> bool {
			if pg, ok := pages[no]; ok {
				free(pg)
				delete_key(&pages, no)
			}
			page_write(no, raw_data(bytes), len(bytes))
			return true
		},
		page_sync = proc(_: rawptr) -> bool {return true},
		close = proc(_: rawptr) {},
	}
	node.now = u64(now())
	zsp.node_init(&node, disk, space_ptr^, nil, true) or_return
	if roster_len > 0 {
		zsp.node_adopt(&node, roster[:roster_len])
	}
	node.host.roster = proc(_: rawptr, bytes: []byte) {
		save_roster(raw_data(bytes), len(bytes))
	}
	node.host.authenticate = proc(_: rawptr, s: ^zsp.Session, credential: []byte) {
		for id, c in conns {
			if c.session == s {
				authenticate(id, &s.peer, raw_data(credential), len(credential))
				return
			}
		}
		// Greeted while being opened, before anyone knows it by name: cannot be, for input comes later.
		zsp.session_refuse(s)
	}
	free_all(context.temp_allocator)
	return true
}

// Where the host should put bytes for the next call.
@(export)
buffer :: proc "c" (size: int) -> [^]byte {
	context = runtime.default_context()
	resize(&message, size)
	return raw_data(message)
}

@(export)
public :: proc "c" (secret_ptr, into: ^zsp.Key32) {
	context = runtime.default_context()
	into^ = zsp.x25519_public(secret_ptr^)
}

@(export)
opened :: proc "c" (id: u32) {
	context = runtime.default_context()
	c := new(Conn)
	c.id = id
	conns[id] = c
}

// A message from a connection lies in the buffer. False means close it.
@(export)
received :: proc "c" (id: u32, size: int) -> bool {
	context = runtime.default_context()
	c := conns[id] or_return
	node.now = u64(now())
	bytes := message[:size]
	if !c.open {
		ok: bool
		c.greeting, c.channel, ok = zsp.handshake_answer(secret, node.space, bytes)
		if !ok {
			return false
		}
		c.open, c.greet = true, true
		c.session = zsp.session_open(&node, .Peer, false, c.channel.peer)
		return true
	}
	plain := zsp.channel_open(&c.channel, bytes) or_return
	return zsp.session_input(c.session, plain)
}

// Some connections were lost while this slept: tells the rest.
@(export)
present :: proc "c" () {
	context = runtime.default_context()
	zsp.presence_send(&node)
}

@(export)
verdict :: proc "c" (id: u32, yes: bool) {
	context = runtime.default_context()
	c, ok := conns[id]
	if !ok || c.session == nil {
		return
	}
	if yes {
		zsp.session_accept(c.session)
	} else {
		zsp.session_refuse(c.session)
	}
}

@(export)
closed :: proc "c" (id: u32) {
	context = runtime.default_context()
	c, ok := conns[id]
	if !ok {
		return
	}
	delete_key(&conns, id)
	if c.session != nil {
		zsp.session_close(c.session)
	}
	free(c)
}

// Makes what has been accepted durable. Call once after each burst of input, before taking output.
@(export)
settle :: proc "c" () {
	context = runtime.default_context()
	zsp.store_sync(&node.store)
	if zsp.store_tail(&node.store) - node.checkpoint > CHECKPOINT_TAIL || zsp.store_wants_checkpoint(&node.store) {
		zsp.store_checkpoint(&node.store)
	}
}

// Takes the next message for a connection into the buffer; its size, zero for none, -1 to close.
@(export)
take :: proc "c" (id: u32) -> int {
	context = runtime.default_context()
	c, ok := conns[id]
	if !ok {
		return -1
	}
	clear(&message)
	if c.greet {
		c.greet = false
		append(&message, ..c.greeting[:])
		return len(message)
	}
	if c.session == nil {
		return 0
	}
	out := zsp.session_output(c.session)
	if len(out) == 0 {
		return -1 if c.session.closing else 0
	}
	n := min(len(out), MAX_PLAIN)
	zsp.channel_seal(&c.channel, &message, out[:n])
	zsp.session_sent(c.session, n)
	return len(message)
}

// The start of the buffer, which may have moved.
@(export)
data :: proc "c" () -> [^]byte {
	return raw_data(message)
}

// Everything needed to carry on with a connection after sleep, into the buffer; zero if nothing is.
@(export)
save :: proc "c" (id: u32) -> int {
	context = runtime.default_context()
	clear(&message)
	c, ok := conns[id]
	if !ok || !c.open || c.greet {
		return 0
	}
	append(&message, ..c.channel.send[:])
	append(&message, ..c.channel.recv[:])
	zsp.write_u64(&message, c.channel.send_n)
	zsp.write_u64(&message, c.channel.recv_n)
	if !zsp.session_save(c.session, &message) {
		return 0
	}
	return len(message)
}

// Revives a connection from what `save` gave.
@(export)
load :: proc "c" (id: u32, size: int) -> bool {
	context = runtime.default_context()
	r := zsp.Reader{buf = message[:size]}
	c := new(Conn)
	c.id = id
	c.open = true
	copy(c.channel.send[:], zsp.read_take(&r, 32))
	copy(c.channel.recv[:], zsp.read_take(&r, 32))
	c.channel.send_n = zsp.read_u64(&r)
	c.channel.recv_n = zsp.read_u64(&r)
	ok: bool
	c.session, ok = zsp.session_load(&node, r.buf[r.pos:])
	if r.bad || !ok {
		crypto.zero_explicit(c, size_of(Conn))
		free(c)
		return false
	}
	c.channel.peer = c.session.peer
	conns[id] = c
	return true
}

// Between bursts: temporary memory, and pages worth no longer keeping.
@(export)
rest :: proc "c" () {
	context = runtime.default_context()
	free_all(context.temp_allocator)
	if len(pages) > PAGES_KEPT {
		for _, pg in pages {
			free(pg)
		}
		clear(&pages)
	}
	if cap(message) > 64 << 10 {
		delete(message)
		message = {}
	}
}
