package host

import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:sync"
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
	keep:         zsp.Keep, // if not, what to keep of what local clients no longer watch: see zsp/retain.odin
	relay:        bool, // hold no keys and serve any space the authenticator lets in
	listen:       Maybe(net.Endpoint), // WebSockets
	udp_port:     Maybe(int), // links, on this port or any if zero
	stun:         string, // host:port to ask for this machine's outside address
	credential:   string, // presented to relays
	// Authentication, which is wholly the embedder's: see zsp.Host.authenticate. `data` is passed back.
	data:         rawptr,
	authenticate: proc(data: rawptr, s: ^zsp.Session, credential: []byte),
	// On a relay, whether it serves a space at all: asked before anything is opened for it, or said to whoever asks for
	// it. Nil for any.
	serves:       proc(data: rawptr, space: zsp.Key32) -> bool,
}

Host :: struct {
	using config: Config,
	secret:       zsp.Key32,
	device:       zsp.Key32,
	spaces:       [dynamic]^Space,
	streams:      [dynamic]^Stream,
	handshaking:  int, // of them, with no session ready yet
	listener:     net.TCP_Socket,
	dialers:      [dynamic]^Dialer,
	udp:          Udp,
	shared:       []byte, // everything is received into this
	sync_due:     time.Tick,
	syncing:      bool, // sync_due is set
	stopping:     bool, // atomic, as host_stop may be called from anywhere
	loop:         ^nbio.Event_Loop,
	methods:      map[string]Host_Method, // that the host answers itself, in-process: see host_serve
	accepting:    ^nbio.Operation,
}

Space :: struct {
	host: ^Host,
	node: zsp.Node,
	keys: zsp.Keyring,
	disk: File_Disk,
	dir:  string,
	seen: u64, // events already noticed by links_poke
	admitted: u64, // the roster whose members links were last held to: see peers_admitted
	warned: bool, // of a clock
	found: ^Found, // while anyone is asking anything
	retaining: bool, // has more to let go of at once
	calls: [dynamic]Host_Call, // whose end is the host
	relayed: [dynamic]^Relayed, // links through relays
	knocked: map[zsp.Key32]u64, // the newest knock heard from each device through relays: its dialler's stamp time
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
	if data, read := read_file(path, context.temp_allocator); read {
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
	if werr != nil || serr != nil || !replace_file(partial, path) {
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
		if kept, read := read_file(file_in(s.dir, "keys"), context.temp_allocator); read {
			zsp.keyring_load(keys, kept)
		}
	}
	s.node.now = now_ms()
	if !zsp.node_init(&s.node, file_disk(&s.disk), id, keys, h.full || h.relay) {
		free(s)
		return nil
	}
	if s.node.becoming {
		report(.Info, "this store was a full replica's: it is one until it is level with another, and partial from then on")
	}
	zsp.node_keep(&s.node, h.keep)
	if bytes, read := read_file(file_in(s.dir, "roster"), context.temp_allocator); read {
		before, _ := read_file(file_in(s.dir, "roster.old"), context.temp_allocator)
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
			// Keys learnt and not kept are lost at the next start, and with them all sealed under them: storage has
			// failed, as the node is told, so that it writes no checkpoint and the host stops before anything more is
			// said, an acknowledgement least of all.
			s := (^Space)(data)
			if !file_disk_make(&s.disk) || !save(file_in(s.dir, "keys"), bytes) {
				report(.Error, "could not keep the keys; stopping rather than going on with what may be lost")
				s.node.failed = true
			}
		},
		roster       = proc(data: rawptr, bytes: []byte) {
			s := (^Space)(data)
			if s.node.failed {
				return // nor a roster whose keys were not kept, which would be held to at the next start without them
			}
			made := file_disk_make(&s.disk)
			if _, ok := roster_keep(s.dir, s.node.space, bytes); !made || !ok {
				report(.Error, "could not keep the roster; stopping rather than going on with what may be lost")
				s.node.failed = true
				return
			}
			if serial, ok := zsp.roster_claims(bytes, s.node.space); ok && debugging() {
				report(.Debug, "roster ", fmt.tprintf("%x", serial), " taken and kept")
			}
			dialers_refresh(s.host)
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
		flush        = stream_push_for,
	}
	if !h.relay {
		s.node.host.questions = questions(s)
	}
	append(&h.spaces, s)
	return s
}

// Keeps a space's roster in its directory, and the one it follows as roster.old, unless what is kept there is it already,
// or later: as when whoever handed it over kept it first, or a later one is on its way to the node. Never the other way,
// which would make roster.old the newer, or keep one older than is had. Whether the roster kept is this one, and false
// for `ok` if what was to be written could not be.
roster_keep :: proc(dir: string, space: zsp.Key32, bytes: []byte) -> (this, ok: bool) {
	serial := zsp.roster_claims(bytes, space) or_return
	path := file_in(dir, "roster")
	if old, read := read_file(path, context.temp_allocator); read {
		if kept, sound := zsp.roster_claims(old, space); sound && kept >= serial {
			return string(old) == string(bytes), true
		}
		save(file_in(dir, "roster.old"), old) or_return
	}
	this = save(path, bytes)
	return this, this
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
	calls_close(s)
	relayed_close(s)
	if s.node.failed {
		// Its last checkpoint stands, and what it has kept: nothing is written to say more was.
		zsp.node_destroy(&s.node)
		zsp.keyring_destroy(&s.keys)
		delete(s.dir)
		free(s)
		return
	}
	if !zsp.store_sync(&s.node.store) {
		report(.Error, "could not sync the log")
	}
	// Leaving a short tail to replay is cheaper than writing pages for it, for a relay; a device's, however little was
	// written since, for what it let go of, and when lists were last watched, are written down only so.
	if s.node.keys != nil || zsp.store_tail(&s.node.store) - s.node.checkpoint > 1 << 20 {
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
	h.loop = nbio.current_thread_event_loop()
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
	return true
}

host_run :: proc(h: ^Host) -> bool {
	dialers_refresh(h)
	for !sync.atomic_load(&h.stopping) {
		host_settle(h)
		wait := nbio.NO_TIMEOUT
		if due, ok := host_deadline(h); ok {
			wait = max(time.tick_diff(time.tick_now(), due), 0)
		}
		if loop_held_back() {
			wait = 0 // what it holds back goes to the system only by a tick that does not wait
		}
		if err := nbio.tick(wait); err != nil {
			report(.Error, "the event loop failed")
			return false
		}
		free_all(context.temp_allocator)
	}
	return true
}

// Has host_run return once what it is doing is done, from any thread, as one that hears a signal to stop: host_destroy
// then lets go of everything, writing down what was kept, as a process that stops politely should.
host_stop :: proc(h: ^Host) {
	sync.atomic_store(&h.stopping, true)
	nbio.wake_up(h.loop)
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
	for method in h.methods {
		delete(method)
	}
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
	report(.Debug, fmt.tprint("a session ended: ", session.role, " ", session.fault))
	zsp.session_close(session)
}

// Everything that follows from the events of one tick, once.
@(private)
host_settle :: proc(h: ^Host) {
	now := time.tick_now()
	ms := now_ms()
	// First, and then nothing more: whatever has failed may have let the store count as durable what is not, and what
	// would be said of it is not said.
	for s in h.spaces {
		if s.node.failed {
			report(.Error, "storage failed; stopping rather than going on with what may be lost")
			h.stopping = true
			return
		}
	}
	if h.syncing && time.tick_diff(h.sync_due, now) >= 0 {
		h.syncing = false
		for s in h.spaces {
			if !zsp.node_sync(&s.node) {
				report(.Error, "storage failed; stopping rather than acknowledging what may be lost")
				h.stopping = true
				return
			}
		}
	}
	dialers_run(h, now)
	links_run(h)
	for s in h.spaces {
		s.node.now = ms
		s.retaining = false
		if due := zsp.node_retain_due(&s.node); due != 0 && due <= ms {
			s.retaining = zsp.node_retain(&s.node) // a step at a time, others' turns between
		}
		found_run(s, now)
		relayed_run(s, now)
	}
	links_flush(h)
	for s in h.spaces {
		#reverse for r, i in s.relayed {
			relayed_flush(r)
			if r.link.state == .Closed {
				ordered_remove(&s.relayed, i) // given up, or closed, as it sent: let go now, not when next looked at
				relayed_drop(r)
			}
		}
	}
	// Last, so that what links had to say through relays goes out at once.
	#reverse for s in h.streams {
		if s.due != {} && !stream_due(s, now) {
			stream_close(s)
			continue
		}
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
		if s.retaining {
			earliest(&due, &ok, time.tick_now())
		} else if at := zsp.node_retain_due(&s.node); at != 0 {
			ms := now_ms()
			wait := min(at - min(at, ms), 24 * 3600 * 1000) // and looked at again in a day, which is soon enough
			earliest(&due, &ok, time.tick_add(time.tick_now(), time.Duration(wait) * time.Millisecond))
		}
	}
	if h.handshaking > 0 {
		for s in h.streams {
			if s.due != {} {
				earliest(&due, &ok, s.due)
			}
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
