package host

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:time"
import "../pipe"
import "../zsp"

// One thread, one event loop, no polling: between events the process is asleep in the kernel, and the
// only clock it ever sets is the nearest deadline something in flight has asked for.

SYNC_DELAY :: 100 * time.Millisecond // how long commits may wait to share an fsync
SHARED_BUFFER :: 64 << 10

Config :: struct {
	dir:          string,
	full:         bool, // replicate everything
	relay:        bool, // hold no keys and serve any space the authenticator lets in
	listen:       Maybe(net.Endpoint), // WebSockets
	udp_port:     Maybe(int), // links, on this port or any if zero
	stun:         string, // host:port to ask for this machine's outside address
	credential:   string, // presented to relays
	// Authentication, which is wholly the embedder's: see zsp.Host.authenticate. `data` is passed back.
	data:         rawptr,
	authenticate: proc(data: rawptr, s: ^zsp.Session, credential: []byte),
	// Whether a caller may reach a TCP port through this device (zsp.tcp), and whether to tell the port who it
	// is first, by what proxy_prelude says. Nil denies every port.
	port_permitted: proc(sp: ^Space, caller: zsp.Key32, scope: zsp.Scope, port: u16, target: string) -> (ok: bool, proxy: bool),
	// The bytes written to a port before anything else, when port_permitted asked for them (a PROXY header), in
	// temporary memory: they are copied.
	proxy_prelude:  proc(sp: ^Space, from: Caller, port: u16, target: string) -> []byte,
	// The ports offered to a caller in a scope, for zsp.services to list (temporary memory).
	ports_offered:  proc(sp: ^Space, from: Caller, scope: zsp.Scope) -> []Port_Offer,
}

Host :: struct {
	using config: Config,
	secret:       zsp.Key32,
	device:       zsp.Key32,
	spaces:       [dynamic]^Space,
	streams:      [dynamic]^Stream,
	listener:     net.TCP_Socket,
	dialers:      [dynamic]^Dialer,
	udp:          Udp,
	shared:       []byte, // everything is received into this
	sync_due:     time.Tick,
	syncing:      bool, // sync_due is set
	stopping:     bool,
	methods:      map[string]Host_Method, // that the host serves itself
	accepting:    ^nbio.Operation,
}

Space :: struct {
	host: ^Host,
	node: zsp.Node,
	keys: zsp.Keyring,
	disk: File_Disk,
	dir:  string,
	seen: u64, // events already noticed by links_poke
	warned: bool, // of a clock
	found: ^Found, // while anyone is asking anything
	calls: [dynamic]Host_Call, // whose end is the host
	bridges: [dynamic]^Bridge, // of calls to TCP connections
	relayed: [dynamic]^Relayed, // links through relays
	shares: [dynamic]Share, // what this device lets others do on it
	services: [dynamic]^Service_Call, // calls to them, which a change may end
	audit: Audit_Log,
}

@(private)
file_in :: proc(dir, name: string) -> string {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

// This machine's secret, created on first use.
@(require_results)
device_secret :: proc(dir: string) -> (secret: zsp.Key32, ok: bool) {
	path := file_in(dir, "device.key")
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		copy(secret[:], data)
		return secret, len(data) == 32
	}
	if err := os.make_directory_all(dir); err != nil && !os.is_dir(dir) {
		return
	}
	crypto.rand_bytes(secret[:])
	return secret, save(path, secret[:])
}

save :: proc(path: string, bytes: []byte) -> bool {
	// Whole or not at all.
	partial := path_with(path, ".new")
	f, err := os.open(partial, {.Write, .Create, .Trunc}, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		return false
	}
	_, werr := os.write(f, bytes)
	serr := os.sync(f)
	os.close(f)
	if werr != nil || serr != nil || os.rename(partial, path) != nil {
		return false
	}
	when ODIN_OS != .Windows {
		// The name is the directory's to remember.
		if dir, derr := os.open(filepath.dir(path), {.Read}); derr == nil {
			os.sync(dir)
			os.close(dir)
		}
	}
	return true
}

@(private)
path_with :: proc(path, suffix: string) -> string {
	b := make([]byte, len(path) + len(suffix), context.temp_allocator)
	copy(b, path)
	copy(b[len(path):], suffix)
	return string(b)
}

// Opens a space held by this machine. On a relay, any space may be opened by name.
space_open :: proc(h: ^Host, id: zsp.Key32) -> ^Space {
	id := id
	for s in h.spaces {
		if s.node.space == id {
			return s
		}
	}
	s := new(Space)
	s.host = h
	name := string(hex.encode(id[:], context.temp_allocator))
	s.dir, _ = filepath.join({h.dir, name})
	if !file_disk_open(&s.disk, s.dir) {
		free(s)
		return nil
	}
	keys: ^zsp.Keyring
	if !h.relay {
		zsp.keyring_init(&s.keys, h.secret)
		keys = &s.keys
		if kept, err := os.read_entire_file(file_in(s.dir, "keys"), context.temp_allocator); err == nil {
			zsp.keyring_load(keys, kept)
		}
	}
	s.node.now = now_ms()
	if !zsp.node_init(&s.node, file_disk(&s.disk), id, keys, h.full || h.relay) {
		free(s)
		return nil
	}
	if bytes, err := os.read_entire_file(file_in(s.dir, "roster"), context.temp_allocator); err == nil {
		before, _ := os.read_entire_file(file_in(s.dir, "roster.old"), context.temp_allocator)
		if !zsp.node_resume(&s.node, before, bytes) {
			report(.Warning, "the saved roster is not sound")
		} else if !h.relay && !zsp.node_member(&s.node) {
			report(.Warning, "this device does not belong to the space")
		}
	}
	s.node.host = {
		data         = s,
		authenticate = space_authenticate,
		keep         = proc(data: rawptr, bytes: []byte) {
			s := (^Space)(data)
			file_disk_make(&s.disk)
			save(file_in(s.dir, "keys"), bytes)
		},
		roster       = proc(data: rawptr, bytes: []byte) {
			s := (^Space)(data)
			file_disk_make(&s.disk)
			if old, err := os.read_entire_file(file_in(s.dir, "roster"), context.temp_allocator); err == nil {
				save(file_in(s.dir, "roster.old"), old)
			}
			save(file_in(s.dir, "roster"), bytes)
			dialers_refresh(s.host)
			// Rights may have gone: whatever they allowed ends.
			services_recheck(s)
			forwards_recheck(s)
		},
		signal       = links_signalled,
		presence     = proc(data: rawptr, online: []zsp.Key32) {
			links_greet((^Space)(data), online)
		},
		method       = host_method,
		flow         = host_flow,
		reach        = relayed_reach,
		link         = relayed_input,
		backlog      = stream_backlog,
	}
	if !h.relay {
		s.node.host.questions = questions(s)
		shares_load(s)
	}
	append(&h.spaces, s)
	return s
}

@(private)
space_authenticate :: proc(data: rawptr, s: ^zsp.Session, credential: []byte) {
	h := (^Space)(data).host
	switch {
	case h.authenticate != nil:
		h.authenticate(h.data, s, credential)
	case s.role != .Open:
		zsp.session_accept(s)
	case:
		zsp.session_refuse(s)
	}
}

space_close :: proc(s: ^Space) {
	found_close(s)
	bridges_close(s)
	calls_close(s)
	relayed_close(s)
	shares_close(s)
	audit_close(s)
	if !zsp.store_sync(&s.node.store) {
		report(.Error, "could not sync the log")
	}
	// Leaving a short tail to replay is cheaper than writing pages for it.
	if zsp.store_tail(&s.node.store) - s.node.checkpoint > 1 << 20 {
		zsp.store_checkpoint(&s.node.store)
	}
	zsp.node_destroy(&s.node)
	zsp.keyring_destroy(&s.keys)
	delete(s.dir)
	free(s)
}

@(require_results)
now_ms :: proc() -> u64 {
	return u64(time.time_to_unix_nano(time.now()) / 1_000_000)
}

@(private)
now_us :: proc() -> pipe.Time {
	return pipe.Time(time.tick_now()._nsec / 1000)
}

host_init :: proc(h: ^Host, config: Config) -> bool {
	h.config = config
	h.secret = device_secret(h.dir) or_return
	h.device = zsp.x25519_public(h.secret)
	h.shared = make([]byte, SHARED_BUFFER)
	// The event loop's first failure is its last, for the thread: so whether it can be made is found out first. Where it
	// is a ring the kernel keeps, one let go of by a process that has just ended may still count against what may be
	// kept, a while, and so many starting at once, as tests do, may wait for it.
	for tries := 0; !ring_free() && tries < 40; tries += 1 {
		time.sleep(50 * time.Millisecond)
	}
	if err := nbio.acquire_thread_event_loop(); err != nil {
		report(.Error, "the event loop failed: ", fmt.tprint(err))
		return false
	}
	if at, ok := h.listen.?; ok {
		// core:net's listener may reuse a port its last owner died holding; core:nbio's may not.
		listener, err := net.listen_tcp(at)
		for tries := 0; err == net.Bind_Error.Address_In_Use && tries < 20; tries += 1 {
			// A process that died is still letting go of its ring.
			time.sleep(50 * time.Millisecond)
			listener, err = net.listen_tcp(at)
		}
		if err != nil {
			report(.Error, "could not listen there")
			return false
		}
		if aerr := nbio.associate_socket(listener); aerr != nil {
			report(.Error, "could not listen there")
			return false
		}
		h.listener = listener
		h.accepting = nbio.accept_poly(listener, h, stream_accepted)
	}
	if port, ok := h.udp_port.?; ok {
		udp_open(h, port) or_return
	}
	host_serve_builtin(h)
	return true
}

host_run :: proc(h: ^Host) -> bool {
	dialers_refresh(h)
	for !h.stopping {
		host_settle(h)
		wait := nbio.NO_TIMEOUT
		if due, ok := host_deadline(h); ok {
			wait = max(time.tick_diff(time.tick_now(), due), 0)
		}
		if err := nbio.tick(wait); err != nil {
			report(.Error, "the event loop failed")
			return false
		}
		free_all(context.temp_allocator)
	}
	return true
}

host_destroy :: proc(h: ^Host) {
	if h.accepting != nil {
		nbio.remove(h.accepting)
		net.close(h.listener)
	}
	for len(h.streams) > 0 {
		stream_close(h.streams[0])
	}
	udp_close(h)
	for len(h.spaces) > 0 {
		space_close(pop(&h.spaces))
	}
	for d in h.dialers {
		dialer_free(d)
	}
	delete(h.streams)
	delete(h.spaces)
	delete(h.dialers)
	delete(h.shared)
	delete(h.methods)
	nbio.release_thread_event_loop()
}

@(private)
session_end :: proc(session: ^zsp.Session) {
	s := (^Space)(session.node.host.data)
	if session.fault == .Clock && !s.warned {
		s.warned = true // once is enough: dialling again is all there is to do until it is set
		report(.Warning, "this machine's clock and another's differ by more than a quarter of an hour: nothing passes between them")
	}
	zsp.session_close(session)
}

// Everything that follows from the events of one tick, once.
@(private)
host_settle :: proc(h: ^Host) {
	now := time.tick_now()
	ms := now_ms()
	if h.syncing && time.tick_diff(h.sync_due, now) >= 0 {
		h.syncing = false
		for s in h.spaces {
			if !zsp.node_sync(&s.node) {
				report(.Error, "storage failed; stopping rather than acknowledging what may be lost")
				h.stopping = true
			}
		}
	}
	for s in h.spaces {
		if s.node.failed {
			report(.Error, "storage failed; stopping rather than going on with what may be lost")
			h.stopping = true
		}
	}
	dialers_run(h, now)
	links_run(h)
	for s in h.spaces {
		s.node.now = ms
		found_run(s, now)
		relayed_run(s, now)
	}
	links_flush(h)
	for s in h.spaces {
		for r in s.relayed {
			relayed_flush(r)
		}
	}
	// Last, so that what links had to say through relays goes out at once.
	#reverse for s in h.streams {
		stream_flush(s)
	}
	if h.relay {
		// A space nobody is in costs nothing.
		#reverse for s, i in h.spaces {
			busy := len(s.node.sessions) > 0
			for x in h.streams {
				busy ||= x.space == s
			}
			if !busy {
				unordered_remove(&h.spaces, i)
				space_close(s)
			}
		}
	}
	for s in h.spaces {
		zsp.store_flush(&s.node.store)
		if zsp.store_unsynced(&s.node.store) && !h.syncing {
			h.syncing = true
			h.sync_due = time.tick_add(now, SYNC_DELAY)
		}
	}
}

@(private)
host_deadline :: proc(h: ^Host) -> (due: time.Tick, ok: bool) {
	earliest :: proc(due: ^time.Tick, ok: ^bool, t: time.Tick) {
		if !ok^ || t._nsec < due._nsec {
			due^ = t
			ok^ = true
		}
	}
	if h.syncing {
		earliest(&due, &ok, h.sync_due)
	}
	for d in h.dialers {
		if t, set := dialer_deadline(d); set {
			earliest(&due, &ok, t)
		}
	}
	for s in h.spaces {
		if t, set := found_deadline(s, time.tick_now()); set {
			earliest(&due, &ok, t)
		}
	}
	if t := links_deadline(h); t != 0 {
		earliest(&due, &ok, time.Tick{i64(t) * 1000})
	}
	for s in h.spaces {
		if t := relayed_deadline(s); t != 0 {
			earliest(&due, &ok, time.Tick{i64(t) * 1000})
		}
	}
	return
}
