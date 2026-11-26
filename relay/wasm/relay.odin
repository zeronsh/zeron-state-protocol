/*
The relay as a WebAssembly module: package zsp, and nothing but, behind a handful of exports. The host
gives it storage, a clock, entropy and an opinion on who may connect; it gives back bytes to send.

Storage is two-tier (zsp/remote.odin): the host's own, synchronous, which holds the log's tail, a manifest and a
cache; and object storage, asynchronous, which holds everything else. Operations on object storage are handed to
the host with `start` and answered with `done`, whenever, in any order; after each, `settle` again.
*/
package relay

import "base:runtime"
import "core:crypto"
import "../../zsp"

foreign import host "host"

@(default_calling_convention = "contextless")
foreign host {
	// The host's own storage. Whether it was kept: storage may be full.
	log_write :: proc(off: f64, ptr: [^]byte, len: int) -> bool ---
	log_read :: proc(off: f64, ptr: [^]byte, len: int) -> bool ---
	log_end :: proc() -> f64 ---
	log_cut :: proc(lo, hi: f64) ---
	manifest_size :: proc() -> int --- // -1 for none
	manifest_read :: proc(ptr: [^]byte) ---
	manifest_write :: proc(ptr: [^]byte, len: int) -> bool ---
	cache_get :: proc(kind: u8, key: f64, ptr: [^]byte, len: int) -> bool ---
	cache_put :: proc(kind: u8, key: f64, ptr: [^]byte, len: int) ---
	cache_drop :: proc(kind: u8, lo, hi: f64) ---
	// Object storage: copy what `ptr` points at before returning (a pack's bytes, or Remote_Objects), and answer with `done`.
	start :: proc(id: u32, kind: u8, number, off, len: f64, ptr: [^]byte, size: int) ---
	save_roster :: proc(ptr: [^]byte, len: int) ---
	// Answered by `verdict`, now or later.
	authenticate :: proc(conn: u32, device: ^zsp.Key32, ptr: [^]byte, len: int) ---
	now :: proc() -> f64 ---
	// A label is exposed here now, or no longer: the host has the public's way in to it lead here.
	label_claim :: proc(ptr: [^]byte, len: int) ---
	label_release :: proc(ptr: [^]byte, len: int) ---
	// What a device says in a call from the public: kind (zsp.Flow), and the message.
	public_flow :: proc(call: f64, kind: u8, ptr: [^]byte, len: int) ---
}

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
remote: zsp.Remote
secret: zsp.Key32
domain: string // where the public reaches what devices expose: <label>.<domain>; "" for nowhere
labels: [dynamic]Label

Label :: struct {
	label:  string, // owned
	conn:   u32,
	device: zsp.Key32,
}
conns: map[u32]^Conn
message: [dynamic]byte // handed in and out

@(export)
init :: proc "c" (space_ptr, secret_ptr: ^zsp.Key32, before: [^]byte, before_len: int, roster: [^]byte, roster_len: int, page_budget, block_budget: int, local_keep, local_most, quiet_tail: f64) -> bool {
	context = runtime.default_context()
	secret = secret_ptr^
	h := zsp.Remote_Host {
		log_write = proc(_: rawptr, off: u64, bytes: []byte) -> bool {
			return log_write(f64(off), raw_data(bytes), len(bytes))
		},
		log_read = proc(_: rawptr, off: u64, into: []byte) -> bool {
			return log_read(f64(off), raw_data(into), len(into))
		},
		log_end = proc(_: rawptr) -> u64 {return u64(log_end())},
		log_cut = proc(_: rawptr, lo, hi: u64) {log_cut(f64(lo), f64(hi))},
		// What is written is durable before anything leaves, and before any operation starts: the host sees to it.
		log_sync = proc(_: rawptr) -> bool {return true},
		manifest_read = proc(_: rawptr) -> []byte {
			n := manifest_size()
			if n < 0 {
				return nil
			}
			b := make([]byte, n, context.temp_allocator)
			manifest_read(raw_data(b))
			return b
		},
		manifest_write = proc(_: rawptr, bytes: []byte) -> bool {
			return manifest_write(raw_data(bytes), len(bytes))
		},
		cache_get = proc(_: rawptr, kind: zsp.Cached, key: u64, into: []byte) -> bool {
			return cache_get(u8(kind), f64(key), raw_data(into), len(into))
		},
		cache_put = proc(_: rawptr, kind: zsp.Cached, key: u64, bytes: []byte) {
			cache_put(u8(kind), f64(key), raw_data(bytes), len(bytes))
		},
		cache_drop = proc(_: rawptr, kind: zsp.Cached, lo, hi: u64) {
			cache_drop(u8(kind), f64(lo), f64(hi))
		},
		start = proc(_: rawptr, op: ^zsp.Remote_Op) {
			ptr, size := raw_data(op.body), len(op.body)
			if op.kind == .Delete {
				ptr, size = ([^]byte)(raw_data(op.objects)), len(op.objects) * size_of(zsp.Remote_Object)
			}
			start(op.id, u8(op.kind), f64(op.number), f64(op.off), f64(op.len), ptr, size)
		},
		now = proc(_: rawptr) -> u64 {return u64(now())},
	}
	zsp.remote_open(&remote, h, page_budget, block_budget, u64(local_keep), u64(local_most)) or_return
	if quiet_tail > 0 {
		remote.quiet_tail = u64(quiet_tail)
	}
	node.store.remote = &remote
	disk := zsp.remote_disk(&remote)
	node.now = u64(now())
	zsp.node_init(&node, disk, space_ptr^, nil, true) or_return
	remote.store = &node.store
	if roster_len > 0 {
		zsp.node_resume(&node, before[:before_len], roster[:roster_len])
	}
	node.host.roster = proc(_: rawptr, bytes: []byte) {
		save_roster(raw_data(bytes), len(bytes))
	}
	node.host.exposure = proc(_: rawptr, s: ^zsp.Session, type: u8, payload: []byte) {
		if type == zsp.EXPOSE {
			exposed(s, payload)
		}
	}
	node.host.flow = proc(_: rawptr, call: u64, kind: zsp.Flow, payload: []byte) {
		public_flow(f64(call), u8(kind), raw_data(payload), len(payload))
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

// Whether storage has failed, as when it is full: nothing more can be kept, and what was not kept was not acknowledged.
@(export)
failed :: proc "c" () -> bool {
	return node.store.failed
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
	labels_drop(id)
	if c.session != nil {
		zsp.session_close(c.session)
	}
	free(c)
}

// ---------------------------------------------------------------- exposure (§17)

// Where the public reaches what devices expose: a domain, whose names <label>.<domain> lead to this relay.
@(export)
expose_domain :: proc "c" (size: int) {
	context = runtime.default_context()
	delete(domain)
	domain = string(clone_bytes(message[:size]))
}

@(private)
clone_bytes :: proc(b: []byte) -> []byte {
	c := make([]byte, len(b))
	copy(c, b)
	return c
}

// 40 Expose, from a device: all it exposes here, replacing what it said before. Answered with 41 Exposed.
@(private)
exposed :: proc(s: ^zsp.Session, payload: []byte) {
	id: u32
	for k, c in conns {
		if c.session == s {
			id = k
		}
	}
	if id == 0 || !zsp.expose_frame_sound(payload, 16) {
		return // nothing of a frame that is not all sound is taken: it changes nothing
	}
	for _, c in conns {
		if c.session != nil && c.session.peer == s.peer && c.session.id > s.id && c.session.ready && !c.session.closing {
			return // late, on a connection it has since come back from: what it says on its newest is what holds
		}
	}
	r := zsp.Reader{buf = payload}
	n := zsp.read_varint(&r)
	// What it no longer exposes is let go, and what is new is claimed: what it says again is left as it is, for a release
	// and a claim of the same label could reach the label's own object either way round.
	// All the device exposes here, on whichever connection said it: one it has come back on while the last is not yet
	// known to be gone says what it exposes for both, and the last one's going takes nothing of it.
	before := make([dynamic]string, context.temp_allocator)
	#reverse for l, i in labels {
		if l.device == s.peer {
			append(&before, l.label)
			unordered_remove(&labels, i)
		}
	}
	w := make([dynamic]byte, context.temp_allocator)
	zsp.write_varint(&w, n)
	kept := make([dynamic]string, context.temp_allocator)
	for _ in 0 ..< n {
		prefix := string(zsp.read_bytes(&r))
		nonce_bytes := zsp.read_take(&r, zsp.EXPOSE_NONCE)
		nonce: [zsp.EXPOSE_NONCE]byte
		copy(nonce[:], nonce_bytes)
		label := zsp.exposure_label(node.space, s.peer, prefix, nonce)
		status := u8(1 if domain == "" else 0)
		for l in labels {
			if l.label == label {
				status = 2
			}
		}
		if status == 0 && len(labels) >= 4096 {
			status = 3
		}
		url := ""
		if status == 0 {
			append(&labels, Label{zsp_clone(label), id, s.peer})
			was := false
			for b in before {
				was ||= b == label
			}
			if !was {
				label_claim(raw_data(label), len(label))
			}
			append(&kept, label)
			url = zsp_concat("https://", label, ".", domain)
		}
		zsp.write_bytes(&w, transmute([]byte)label)
		append(&w, status)
		zsp.write_bytes(&w, transmute([]byte)url)
	}
	for b in before {
		gone := true
		for k in kept {
			gone &&= k != b
		}
		if gone {
			label_release(raw_data(b), len(b))
		}
		delete(b)
	}
	zsp.session_say(s, zsp.EXPOSE + 1, w[:])
}

@(private)
zsp_clone :: proc(s: string) -> string {
	return string(clone_bytes(transmute([]byte)s))
}

@(private)
zsp_concat :: proc(parts: ..string) -> string {
	w := make([dynamic]byte, context.temp_allocator)
	for p in parts {
		append(&w, p)
	}
	return string(w[:])
}

// A connection has gone: what it exposed is reached here no longer. The label's own object still leads here, which is
// harmless (it leads nowhere else, and here nobody answers for it) and right when the device comes back, as it will.
@(private)
labels_drop :: proc(id: u32) {
	#reverse for l, i in labels {
		if l.conn == id {
			delete(l.label)
			unordered_remove(&labels, i)
		}
	}
}

// Calls the device whose label is in the buffer, for the public at an address (16 bytes, then the port, big-endian)
// after it: label bytes ‖ address (18). The call, or zero if the label is nobody's here or the call cannot be made.
@(export)
public_open :: proc "c" (size: int) -> f64 {
	context = runtime.default_context()
	r := zsp.Reader{buf = message[:size]}
	label := string(zsp.read_bytes(&r))
	_ = zsp.read_take(&r, 18)
	if !zsp.read_done(&r) {
		return 0
	}
	for l in labels {
		if l.label == label {
			node.now = u64(now())
			return f64(zsp.node_call_method(&node, l.device, 0, "zsp.public", message[:size]))
		}
	}
	return 0
}

// How much may be said in a call yet.
@(export)
public_room :: proc "c" (call: f64) -> int {
	context = runtime.default_context()
	return zsp.node_granted(&node, u64(call))
}

// Says what is in the buffer in a call: within its room, or nothing.
@(export)
public_send :: proc "c" (call: f64, size: int) -> bool {
	context = runtime.default_context()
	if size > zsp.node_granted(&node, u64(call)) {
		return false
	}
	zsp.node_flow(&node, u64(call), .Data, message[:size])
	return true
}

// 1 End, 3 Cancel; or 4 Credit for so many bytes taken.
@(export)
public_say :: proc "c" (call: f64, kind: u8, credit: int) {
	context = runtime.default_context()
	switch kind {
	case 1:
		zsp.node_flow(&node, u64(call), .End)
	case 3:
		zsp.node_flow(&node, u64(call), .Cancel)
	case 4:
		w := make([dynamic]byte, context.temp_allocator)
		zsp.write_varint(&w, u64(credit))
		zsp.node_flow(&node, u64(call), .Credit, w[:])
	}
}

// Makes what has been accepted durable, goes on with whatever waited for what has come, and starts whatever is due.
// Call after each burst of input and after each `done`, before taking output. 1 if there is more to do at once, and
// it should be called again soon, rather than when something comes.
@(export)
settle :: proc "c" () -> int {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)
	if !node.store.replaying {
		zsp.store_sync(&node.store)
	}
	zsp.node_retry(&node)
	zsp.remote_work(&remote)
	zsp.remote_ops(&remote)
	return 1 if node.store.more else 0
}

// Whether a checkpoint would be worth one should nothing more happen: if so, the host calls `quiet` once nothing has
// for a while, and settles.
@(export)
quiet_due :: proc "c" () -> bool {
	context = runtime.default_context()
	return zsp.remote_quiet_due(&remote)
}

@(export)
quiet :: proc "c" () {
	context = runtime.default_context()
	zsp.remote_quiet(&remote)
}

// Starts fetching what producing output wanted. Call after taking output, before resting.
@(export)
ops :: proc "c" () {
	context = runtime.default_context()
	zsp.remote_ops(&remote)
	free_all(context.temp_allocator)
}

// An operation `start` began has finished; for a get, what it read lies in the buffer.
@(export)
done :: proc "c" (id: u32, ok, absent: bool, size: int) {
	context = runtime.default_context()
	zsp.remote_done(&remote, id, ok, absent, message[:size])
	free_all(context.temp_allocator)
}

// What it has cost so far, and where its log stands, into the buffer: sixteen numbers.
@(export)
stats :: proc "c" () -> int {
	context = runtime.default_context()
	clear(&message)
	st := remote.stats
	for v in ([?]u64{u64(st.gets), u64(st.puts), u64(st.deletes), st.got, st.put, u64(st.checkpoints), u64(st.extents), u64(st.fetched_pages), u64(st.local_hits), u64(st.relocated), u64(len(node.store.dirty)), u64(st.log_gets), remote.uploaded, remote.local_from, zsp.store_tail(&node.store) if !node.store.replaying else 0, node.store.checkpoint}) {
		zsp.write_u64(&message, v)
	}
	return len(message)
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
	// What it exposes, which it has no reason to say again when this wakes.
	count := 0
	for l in labels {
		count += 1 if l.conn == id else 0
	}
	zsp.write_varint(&message, u64(count))
	for &l in labels {
		if l.conn == id {
			zsp.write_bytes(&message, transmute([]byte)l.label)
			append(&message, ..l.device[:])
		}
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
	exposed := make([dynamic]Label, context.temp_allocator)
	count := min(zsp.read_varint(&r), 16) // read once: a range's bound is looked at again each time round
	for _ in 0 ..< count {
		label := string(zsp.read_bytes(&r))
		device: zsp.Key32
		copy(device[:], zsp.read_take(&r, 32))
		append(&exposed, Label{label, id, device})
	}
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
	for l in exposed {
		append(&labels, Label{zsp_clone(l.label), id, l.device})
	}
	return true
}

// Between bursts: temporary memory, and what is least lately used past the budget.
@(export)
rest :: proc "c" () {
	context = runtime.default_context()
	free_all(context.temp_allocator)
	zsp.remote_rest(&remote)
	if cap(message) > 64 << 10 {
		delete(message)
		message = {}
	}
}
