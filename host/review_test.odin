package host

import "base:runtime"
import "core:encoding/hex"
import "core:log"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../find"
import "../pipe"
import "../third_party/nbio"
import "../zsp"

// Each a reproduction from adversarial review, kept so that what it found stays found.

// A local client of a space's node, let in with these grants.
@(private)
open_local_session :: proc(t: ^testing.T, sp: ^Space, space: zsp.Key32, grants: []zsp.Grant) -> ^zsp.Session {
	grants := grants
	sp.node.host.authenticate = proc(data: rawptr, s: ^zsp.Session, _: []byte) {
		zsp.session_accept(s, (^[]zsp.Grant)(context.user_ptr)^)
	}
	context.user_ptr = &grants
	local := zsp.session_open(&sp.node, .Open, false)
	hello := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&hello, .Hello)
	append(&hello, zsp.VERSION, 0)
	space := space
	append(&hello, ..space[:])
	zsp.write_varint(&hello, 0)
	zsp.write_bytes(&hello, nil)
	zsp.frame_end(&hello, at)
	testing.expect(t, zsp.session_input(local, hello[:]))
	sp.node.host.authenticate = space_authenticate
	zsp.session_sent(local, len(zsp.session_output(local)))
	return local
}

// A local client's call, as frames.
@(private)
local_call :: proc(local: ^zsp.Session, id: u64, device: zsp.Key32, scope: zsp.Scope, method: string, first: []byte, urgency: u8 = zsp.URGENCY) -> bool {
	cf := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&cf, .Call)
	zsp.write_varint(&cf, id)
	device := device
	append(&cf, ..device[:])
	zsp.write_varint(&cf, u64(scope))
	zsp.write_bytes(&cf, transmute([]byte)method)
	zsp.write_bytes(&cf, nil)
	zsp.write_u8(&cf, urgency)
	append(&cf, ..first)
	zsp.frame_end(&cf, at)
	return zsp.session_input(local, cf[:])
}

// A knock through a relay is heard once: a newer one from the same device neither disturbs a live link nor is stood in
// the way of by it, and an old one heard again opens nothing.
@(test)
review_relayed_knocks :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	b := world_space(&w, 2)
	l1: pipe.Link
	defer pipe.link_destroy(&l1)
	testing.expect(t, pipe.link_dial(&l1, w.hosts[1].secret, w.keys[2].device, w.space, 100))
	first1_buf: [pipe.FIRST_SIZE]byte
	first1 := pipe.link_hello(&l1, first1_buf[:])
	saved1 := make([]byte, len(first1))
	defer delete(saved1)
	copy(saved1, first1)
	relayed_input(b, 0, w.keys[1].device, first1)
	testing.expect_value(t, len(b.relayed), 1)
	orig := b.relayed[0]
	// Answered, and heard from over it: a live link.
	second_buf: [pipe.SECOND_SIZE + pipe.FIRST_SIZE]byte
	testing.expect(t, pipe.link_input(&l1, pipe.link_hello(orig.link, second_buf[:]), now_us()))
	testing.expect(t, pipe.link_write(&l1, 0, transmute([]byte)string("hello")))
	out_buf: [RELAY_PACKET]byte
	packet := pipe.link_output(&l1, out_buf[:], now_us())
	testing.expect(t, packet != nil)
	relayed_input(b, 0, w.keys[1].device, packet)
	testing.expect(t, orig.proven, "the link was not heard from")
	l2: pipe.Link
	defer pipe.link_destroy(&l2)
	testing.expect(t, pipe.link_dial(&l2, w.hosts[1].secret, w.keys[2].device, w.space, 200))
	first2_buf: [pipe.FIRST_SIZE]byte
	first2 := pipe.link_hello(&l2, first2_buf[:])
	relayed_input(b, 0, w.keys[1].device, first2)
	still := false
	for r in b.relayed {
		still ||= r == orig
	}
	for len(b.relayed) > 0 {
		relayed_drop(pop(&b.relayed))
	}
	relayed_input(b, 0, w.keys[1].device, saved1)
	replayed := len(b.relayed) > 0
	testing.expectf(t, still && !replayed, "the live link stayed %v; an old knock was heard again %v", still, replayed)
}

// However many knocks come through a relay from one device, they open one link at a time, not one each.
@(test)
review_knocks_open_one_link_at_a_time :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	b := world_space(&w, 2)
	relay_id := b.node.sessions[0].id
	wire: [pipe.FIRST_SIZE]byte
	for i in 0 ..< 200 {
		client: pipe.Link
		testing.expect(t, pipe.link_dial(&client, w.hosts[1].secret, w.keys[2].device, w.space, u64(i + 1)))
		relayed_input(b, relay_id, w.keys[1].device, pipe.link_hello(&client, wire[:]))
		pipe.link_destroy(&client)
	}
	testing.expectf(t, len(b.relayed) <= 2, "%d links for one device", len(b.relayed))
}

// A peer that pings, and reads nothing, is owed one answer however often it pings: only the latest ping's, sent once all
// before it has gone. And before a session nothing longer than a handshake's message is taken, nor held while it comes.
@(test)
review_pings_owe_one_answer :: proc(t: ^testing.T) {
	s: Stream
	s.phase = .Noise
	defer {
		delete(s.in_buf)
		delete(s.pieces)
		delete(s.out)
		delete(s.pong)
	}
	wire := make([dynamic]byte, context.temp_allocator)
	payload: [pipe.CONTROL_MAX]byte
	for i in 0 ..< 1000 {
		payload[0] = byte(i)
		pipe.ws_put(&wire, .Ping, payload[:], true)
		if i % 10 == 0 {
			pipe.ws_put(&wire, .Text, transmute([]byte)string("ping"), true)
		}
	}
	testing.expect(t, stream_input(&s, wire[:]))
	testing.expectf(t, len(s.out) == 2 + pipe.CONTROL_MAX, "%d bytes owed for 1000 pings", len(s.out))
	s.sent = len(s.out) // as though the socket took it
	stream_answer(&s)
	first := 2 + pipe.CONTROL_MAX
	testing.expect_value(t, len(s.out), first + 2 + pipe.CONTROL_MAX + 2 + 4)
	if len(s.out) == first + 2 + pipe.CONTROL_MAX + 2 + 4 {
		testing.expect_value(t, s.out[first + 2], byte(999 % 256)) // the latest
		testing.expect_value(t, string(s.out[len(s.out) - 4:]), "pong")
	}

	// A message said to be a mebibyte long, before any session: refused at its head.
	big: [10]byte
	big[0], big[1], big[7] = 0x82, 127, 0x10
	quiet: Stream
	quiet.phase = .Noise
	defer delete(quiet.in_buf)
	testing.expect(t, !stream_input(&quiet, big[:]), "a mebibyte is waited for before any session")
}

// What a store forgets of its log is forgotten by the files that held it: a segment truncated away, or dropped, while it
// is the one written to, is made again by the next write to it, and what is written then is there after a restart.
@(test)
review_disk_forgets_open_segments :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	root, err := os.make_directory_temp(base, "zsp-disk-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(root)
	seg := u64(zsp.SEGMENT)
	read :: proc(dir: string, off: u64, n: int) -> (end: u64, got: string) {
		d: File_Disk
		if !file_disk_open(&d, dir) {
			return
		}
		disk := file_disk(&d)
		defer disk.close(disk.data)
		buf := make([]byte, n, context.temp_allocator)
		if disk.log_read(disk.data, off, buf) {
			got = string(buf)
		}
		return disk.log_end(disk.data), got
	}

	truncated, _ := filepath.join({root, "truncated"}, context.temp_allocator)
	{
		d: File_Disk
		testing.expect(t, file_disk_open(&d, truncated))
		disk := file_disk(&d)
		testing.expect(t, disk.log_write(disk.data, 0, transmute([]byte)string("first")))
		testing.expect(t, disk.log_write(disk.data, seg, transmute([]byte)string("dropped")))
		buf: [7]byte
		testing.expect(t, disk.log_read(disk.data, seg, buf[:])) // and read, so that both handles are its
		disk.log_truncate(disk.data, 5)
		testing.expect(t, !disk.log_read(disk.data, seg, buf[:]), "a segment truncated away is still read")
		testing.expect(t, disk.log_write(disk.data, seg, transmute([]byte)string("kept")))
		testing.expect(t, disk.log_sync(disk.data))
		disk.close(disk.data)
	}
	end, got := read(truncated, seg, 4)
	testing.expectf(t, end == seg + 4 && got == "kept", "after a truncation: end %d, %q", end, got)

	dropped, _ := filepath.join({root, "dropped"}, context.temp_allocator)
	{
		d: File_Disk
		testing.expect(t, file_disk_open(&d, dropped))
		disk := file_disk(&d)
		testing.expect(t, disk.log_write(disk.data, 0, transmute([]byte)string("old")))
		testing.expect(t, disk.log_sync(disk.data))
		disk.log_drop(disk.data, 0)
		testing.expect(t, disk.log_write(disk.data, 0, transmute([]byte)string("new!")))
		testing.expect(t, disk.log_sync(disk.data))
		disk.close(disk.data)
	}
	end, got = read(dropped, 0, 4)
	testing.expectf(t, end == 4 && got == "new!", "after a drop: end %d, %q", end, got)
}

// A relay opens nothing for a stranger that has only asked for a space: not for one it does not serve, which is refused
// at once; nor for any other, until a key is proved. And a connection on which no session is ready within
// HANDSHAKE_WAIT, as anyone may leave one, is let go of.
@(test)
review_relay_opens_nothing_for_strangers :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-strangers-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	h: Host
	testing.expect(t, host_init(&h, {dir = dir, relay = true, full = true, listen = net.Endpoint{net.IP4_Loopback, 0}}))
	defer host_destroy(&h)
	at, _ := net.bound_endpoint(h.listener)
	// What the relay says to an upgrade, if anything, before it closes.
	ask :: proc(h: ^Host, at: net.Endpoint) -> (said: string, socket: net.TCP_Socket) {
		buf := make([]byte, 512, context.temp_allocator)
		socket, _ = net.dial_tcp(at)
		net.set_blocking(socket, false)
		request := pipe.ws_request("x", strings.concatenate({"/", strings.repeat("ab", 32, context.temp_allocator)}, context.temp_allocator))
		net.send_tcp(socket, transmute([]byte)request)
		for start := time.tick_now(); time.tick_since(start) < 5 * time.Second; {
			host_settle(h)
			_ = nbio.tick(5 * time.Millisecond)
			n, rerr := net.recv_tcp(socket, buf)
			if rerr == .Would_Block {
				continue
			}
			return string(buf[:n]) if n > 0 else "closed", socket
		}
		return "", socket
	}
	h.serves = proc(_: rawptr, _: zsp.Key32) -> bool {return false}
	said, refused := ask(&h, at)
	net.close(refused)
	testing.expectf(t, said == "closed", "a space not served: %q", said)
	h.serves = nil
	said2, waiting := ask(&h, at)
	defer net.close(waiting)
	testing.expectf(t, strings.contains(said2, " 101 "), "a space served: %q", said2)
	testing.expectf(t, len(h.spaces) == 0, "%d spaces opened for a stranger that proved nothing", len(h.spaces))
	testing.expect_value(t, len(h.streams), 1)
	if len(h.streams) == 1 {
		h.streams[0].due = time.tick_now() // as though HANDSHAKE_WAIT had passed
		host_settle(&h)
		testing.expectf(t, len(h.streams) == 0 && h.handshaking == 0, "%d streams, %d handshaking, after HANDSHAKE_WAIT", len(h.streams), h.handshaking)
	}
}

// Keys a node could not keep are storage failed: it keeps no roster that needs them, writes no checkpoint, and its host
// stops before anything more is said. A roster it could not keep is the same.
@(test)
review_unkept_keys_stop_the_host :: proc(t: ^testing.T) {
	for what in ([]string{"keys", "roster"}) {
		base, _ := os.temp_directory(context.temp_allocator)
		dir, err := os.make_directory_temp(base, "zsp-unkept-*", context.temp_allocator)
		testing.expect(t, err == nil)
		defer os.remove_all(dir)
		h: Host
		testing.expect(t, host_init(&h, {dir = dir, full = true}))
		defer host_destroy(&h)
		root: zsp.Key32
		root[0] = 7
		ours: zsp.Keyring
		zsp.keyring_init(&ours, h.secret)
		defer zsp.keyring_destroy(&ours)
		none: zsp.Roster
		d := zsp.draft_from(&none, now_ms() << 16)
		home := zsp.draft_scope(&d)
		zsp.draft_grant(&d, ours.device, ours.signer, home, {.Read, .Write, .Call}).owner = true
		first, signed := zsp.roster_sign(&ours, root, &d, context.temp_allocator)
		testing.expect(t, signed)
		space := zsp.ed25519_public(root)
		sdir, _ := filepath.join({dir, string(hex.encode(space[:], context.temp_allocator))}, context.temp_allocator)
		os.make_directory_all(sdir)
		testing.expect(t, save(file_in(sdir, "roster"), first))
		s := space_open(&h, space)
		testing.expect(t, s != nil)
		if s == nil {
			return
		}
		// Where it is to be kept, a directory, which no file is renamed onto: as a full disk, a save that fails.
		os.remove(file_in(sdir, what))
		testing.expect(t, os.make_directory(file_in(sdir, what)) == nil)
		more := zsp.draft_from(&s.node.roster, (now_ms() + 1) << 16)
		zsp.draft_scope(&more)
		second, again := zsp.roster_sign(&s.keys, root, &more, context.temp_allocator)
		testing.expect(t, again)
		checkpoint := s.node.serial_kept
		logger := context.logger
		context.logger = log.nil_logger() // what the host says of it is meant, and the test's own is said after
		_ = zsp.node_adopt(&s.node, second)
		host_settle(&h)
		context.logger = logger
		testing.expectf(t, s.node.failed, "%s not kept, and the node goes on", what)
		testing.expectf(t, s.node.serial_kept == checkpoint, "%s not kept, and a checkpoint says the roster was taken", what)
		if what == "keys" {
			kept, _ := os.read_entire_file(file_in(sdir, "roster"), context.temp_allocator)
			testing.expect(t, string(kept) == string(first), "a roster kept whose keys were not")
		}
		testing.expectf(t, h.stopping, "%s not kept, and the host goes on", what)
	}
}

// What ends the handshake may come in one read with the first of the session, as a relay that speaks at once sends it:
// the frames after it are a session's, as long as a session's may be.
@(test)
review_session_follows_the_handshake_at_once :: proc(t: ^testing.T) {
	h: Host
	h.secret[0] = 1
	theirs: zsp.Key32
	theirs[0] = 2
	sp: Space
	sp.host = &h
	m: zsp.Memory_Disk
	defer zsp.memory_disk_destroy(&m)
	space: zsp.Key32
	space[0] = 3
	testing.expect(t, zsp.node_init(&sp.node, zsp.memory_disk(&m), space, nil, true))
	defer zsp.node_destroy(&sp.node)
	d: Dialer
	d.space, d.key = &sp, zsp.x25519_public(theirs)
	s: Stream
	s.host, s.dialer, s.space, s.phase = &h, &d, &sp, .Noise
	s.handshake = new(zsp.Handshake)
	first, ok := zsp.handshake_start(s.handshake, h.secret, d.key, space)
	testing.expect(t, ok)
	second, channel, answered := zsp.handshake_answer(theirs, space, first[:])
	testing.expect(t, answered)
	// The start of a session's frame longer than any handshake's message, which the session holds until the rest comes.
	plain: [300]byte
	plain[0], plain[1] = 0xe8, 0x07 // a frame of 1000 bytes
	sealed := make([dynamic]byte, context.temp_allocator)
	zsp.channel_seal(&channel, &sealed, plain[:])
	wire := make([dynamic]byte, context.temp_allocator)
	pipe.ws_put(&wire, .Binary, second[:], false)
	pipe.ws_put(&wire, .Binary, sealed[:], false)
	took := stream_input(&s, wire[:])
	testing.expect(t, took && s.session != nil && len(s.session.input) == len(plain), "the session's first frame, come with the handshake's last, was refused")
	if s.session != nil {
		zsp.session_close(s.session)
	}
	free(s.handshake)
	delete(s.in_buf)
	delete(s.pieces)
	delete(s.out)
	delete(s.pong)
}

// Saving what answers questions syncs the store as any sync does: a checkpoint due is made then, not passed over until
// something else is written.
@(test)
review_index_saved_by_a_whole_sync :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-found-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	h: Host
	testing.expect(t, host_init(&h, {dir = dir}))
	defer host_destroy(&h)
	root: zsp.Key32
	root[0] = 9
	s := space_open(&h, zsp.ed25519_public(root))
	testing.expect(t, s != nil)
	if s == nil {
		return
	}
	none: zsp.Roster
	d := zsp.draft_from(&none, now_ms() << 16)
	home := zsp.draft_scope(&d)
	zsp.draft_grant(&d, s.keys.device, s.keys.signer, home, {.Read, .Write, .Call}).owner = true
	roster, signed := zsp.roster_sign(&s.keys, root, &d, context.temp_allocator)
	testing.expect(t, signed && zsp.node_adopt(&s.node, roster))
	f := space_finder(s)
	for i := 0; i < 1000 && !find.finder_run(f); i += 1 {} // until it has caught up
	body: [512]byte
	cell := zsp.Cell{row = zsp.Id{1, 100}, slot = 1, kind = .Value, stamp = zsp.Stamp{1000, 1}, body = body[:]}
	testing.expect_value(t, zsp.store_commit(&s.node.store, []zsp.Cell{cell}, 0, own = false), 1)
	s.node.store.serial += 1 // a checkpoint is due
	f.x.tailing, f.x.unsaved = true, max(f.x.unsaved, 1)
	found_save(s)
	testing.expect(t, !zsp.store_unsynced(&s.node.store))
	testing.expect(t, !zsp.store_wants_checkpoint(&s.node.store), "the index saved, and the checkpoint due passed over")
}

// What is kept is kept whoever else is reading it, or keeping it too, and read whoever is replacing it: on Windows, where
// a file another has open cannot be replaced, nor one being replaced opened, as on any system. Two writers, a reader of
// this host's own, and another process's reader, all at once, as zspd's admin commands, tests and scanners read what a
// node keeps, and a command may keep a roster beside it.
@(test)
review_keeping_and_reading_at_once :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-kept-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	Shared :: struct {
		path:    string,
		done:    bool, // atomic
		torn:    int, // atomic: a read that was not one whole version
		missing: int, // atomic: a read that found nothing
		refused: int, // atomic: saves of the other writer that failed
	}
	sh := Shared{path = strings.clone(file_in(dir, "roster"))} // which outlasts the temporary memory let go of below
	defer delete(sh.path)
	version :: proc(i: int) -> []byte {
		b := make([]byte, 4096 + i, context.temp_allocator)
		for &x in b {
			x = byte(i)
		}
		return b
	}
	testing.expect(t, save(sh.path, version(0)))
	ours := thread.create_and_start_with_poly_data(&sh, proc(sh: ^Shared) {
		context = runtime.default_context() // temporary memory of its own
		for !sync.atomic_load(&sh.done) {
			data, ok := read_file(sh.path, context.temp_allocator)
			if !ok {
				sync.atomic_add(&sh.missing, 1)
			} else if len(data) < 4096 || data[0] != byte(len(data) - 4096) || data[len(data) - 1] != data[0] {
				sync.atomic_add(&sh.torn, 1)
			}
			free_all(context.temp_allocator)
		}
	})
	// As another process reads, or a scanner: opened as the system opens a file by default, not letting it be deleted,
	// held a moment, and let be a moment. One that let it be no longer than it takes to open it again would keep any
	// replacement out on Windows, which nothing could wait for the moment between without spinning.
	theirs := thread.create_and_start_with_poly_data(&sh, proc(sh: ^Shared) {
		context = runtime.default_context()
		for !sync.atomic_load(&sh.done) {
			if f, ferr := os.open(sh.path, {.Read}); ferr == nil {
				buf: [64]byte
				_, _ = os.read(f, buf[:])
				time.sleep(time.Millisecond)
				os.close(f)
			}
			time.sleep(time.Millisecond)
		}
	})
	other := thread.create_and_start_with_poly_data(&sh, proc(sh: ^Shared) {
		context = runtime.default_context()
		for i := 0; !sync.atomic_load(&sh.done); i += 1 {
			b := make([]byte, 4096 + 201 + i % 50, context.temp_allocator)
			for &x in b {
				x = byte(len(b) - 4096)
			}
			if !save(sh.path, b) {
				sync.atomic_add(&sh.refused, 1)
			}
			free_all(context.temp_allocator)
		}
	})
	failed := 0
	for i in 1 ..= 200 {
		if !save(sh.path, version(i)) {
			failed += 1
		}
		free_all(context.temp_allocator)
	}
	sync.atomic_store(&sh.done, true)
	thread.join(ours)
	thread.join(theirs)
	thread.join(other)
	thread.destroy(ours)
	thread.destroy(theirs)
	thread.destroy(other)
	testing.expectf(t, failed == 0 && sh.refused == 0, "%d of 200 saves failed while others read, and %d of the other writer's", failed, sh.refused)
	testing.expectf(t, sh.missing == 0 && sh.torn == 0, "reads while it was replaced: %d found nothing, %d torn", sh.missing, sh.torn)
}

// A roster drawn up from one kept here is kept only if that is still what is kept: one another command kept meanwhile,
// later or not, is never replaced by it, which would lose that command's change.
@(test)
review_roster_kept_after_what_it_follows :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-follows-*", context.temp_allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)
	secret, root: zsp.Key32
	secret[0], root[0] = 1, 2
	keys: zsp.Keyring
	zsp.keyring_init(&keys, secret)
	defer zsp.keyring_destroy(&keys)
	space := zsp.ed25519_public(root)
	none: zsp.Roster
	d := zsp.draft_from(&none, 1 << 16)
	home := zsp.draft_scope(&d)
	zsp.draft_grant(&d, keys.device, keys.signer, home, {.Write}).owner = true
	first, ok := zsp.roster_sign(&keys, root, &d, context.temp_allocator)
	testing.expect(t, ok)
	was, _ := zsp.roster_parse(first, space)
	defer zsp.roster_destroy(&was)
	// Two changes drawn up from it at once; the first is kept.
	ours, theirs := zsp.draft_from(&was, 2 << 16), zsp.draft_from(&was, 3 << 16)
	// Of two drawn up from one roster, which is later is chance: here it is the other.
	ours.random = proc(into: []byte) {for &b in into {b = 0x00}}
	theirs.random = proc(into: []byte) {for &b in into {b = 0xff}}
	zsp.draft_scope(&ours)
	zsp.draft_scope(&theirs, {.Signed})
	mine, ok1 := zsp.roster_sign(&keys, root, &ours, context.temp_allocator)
	later, ok2 := zsp.roster_sign(&keys, root, &theirs, context.temp_allocator)
	testing.expect(t, ok1 && ok2)
	a, _ := zsp.roster_claims(mine, space)
	b, _ := zsp.roster_claims(later, space)
	testing.expect(t, b > a, "the other change is not the later") // so that only what it was drawn up from keeps it out
	testing.expect(t, save(file_in(dir, "roster"), first))
	this, kept := roster_keep(dir, space, mine, first)
	testing.expect(t, this && kept)
	this, kept = roster_keep(dir, space, later, first)
	testing.expectf(t, !this && kept, "a roster kept in place of one kept meanwhile (this %v, ok %v)", this, kept)
	now, _ := read_file(file_in(dir, "roster"), context.temp_allocator)
	testing.expect(t, string(now) == string(mine), "the change kept meanwhile was lost")
}

// On Windows, a replacement waits for whoever else has the file open as long as FILE_BUSY_WAIT, by the clock, and no
// longer: however much longer the system's tick makes each short sleep within it, as the host's loop waits meanwhile.
@(test)
review_busy_file_waited_for_as_long_as_said :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		base, _ := os.temp_directory(context.temp_allocator)
		dir, err := os.make_directory_temp(base, "zsp-busy-*", context.allocator)
		testing.expect(t, err == nil)
		defer delete(dir)
		defer os.remove_all(dir)
		path := strings.clone(file_in(dir, "roster"))
		defer delete(path)
		testing.expect(t, save(path, transmute([]byte)string("first")))
		held, herr := os.open(path, {.Read}) // as another process opens it, letting nobody delete it
		testing.expect(t, herr == nil)
		// A wait of 200 ms, as the clock says: 200 tries of a millisecond each, as a wait counted in the sleeps asked for
		// took it to be, would take three seconds or more, the system's tick making each sleep 15.6 ms. A machine slow
		// for a while makes the wait no shorter, and a second of it no longer than allowed.
		file_busy_wait = 200 * time.Millisecond
		defer file_busy_wait = FILE_BUSY_WAIT
		start := time.tick_now()
		saved := save(path, transmute([]byte)string("second"))
		took := time.tick_since(start)
		os.close(held)
		testing.expectf(t, !saved && took >= file_busy_wait && took < time.Second, "saved %v after %v, waiting as long as %v", saved, took, file_busy_wait)
	}
}

// One stream with much to say, to one that takes it as fast as it is said, is given a turn's worth at a time, and the
// loop goes on at once: it does not keep every other stream waiting, nor what comes in, for as long as the socket takes
// what it is given.
@(test)
stream_takes_turns :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	a := world_space(&w, 1)
	body := make([]byte, 16000)
	defer delete(body)
	for i in 0 ..< 400 {
		place: [24]byte
		zsp.put_u64(place[:], 1 << 32 | 5)
		zsp.put_u64(place[8:], 5)
		zsp.put_u64(place[16:], u64(i))
		id := zsp.node_id(&a.node, 1)
		_ = zsp.node_write(&a.node, {{id, zsp.PLACE, .Place, zsp.node_stamp(&a.node), place[:]}, {id, zsp.DATA, .Value, zsp.node_stamp(&a.node), body}})
		free_all(context.temp_allocator)
	}
	// Once the relay has it all, it has all of it to say again to A, as when it brings A level afresh.
	testing.expect(t, world_run(&w, proc(w: ^World, _: rawptr) -> bool {
		return zsp.store_range(&world_space(w, 0).node.store, zsp.scope_lo(1), zsp.scope_hi(1)).count >= 400
	}))
	h := &w.hosts[0]
	to_a: ^Stream
	for s in h.streams {
		if s.session != nil && s.session.ready && s.session.peer == w.keys[1].device {
			to_a = s
		}
	}
	testing.expect(t, to_a != nil)
	if to_a == nil {
		return
	}
	append(&to_a.session.tasks, zsp.Task{kind = .Fill, lo = zsp.scope_lo(1), hi = zsp.scope_hi(1)})
	// Given one turn, with nobody reading the other end meanwhile.
	before := to_a.session.taken
	h.more = false
	stream_flush(to_a)
	given := int(to_a.session.taken - before)
	testing.expectf(t, given <= FLUSH_TURN + MAX_PLAIN, "one turn gave a stream %d bytes", given)
	testing.expect(t, given > 0)
	testing.expect(t, h.more, "a stream with more to say was not given another turn at once")
}

// A relay named two ways, both at hand, is reached one way: through two, all that came in by one would go back by the
// other.
@(test)
one_way_to_a_relay :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	// A names the relay again, otherwise: the same relay at another name.
	other, _ := strings.replace(w.urls[0], "127.0.0.1", "localhost", 1, context.temp_allocator)
	dial(&w.hosts[1], world_space(&w, 1), w.keys[0].device, other)
	up :: proc(w: ^World) -> int {
		n := 0
		for d in w.hosts[1].dialers {
			n += 1 if d.key == w.keys[0].device && d.state == .Up && d.admitted else 0
		}
		return n
	}
	world_run(&w, proc(w: ^World, _: rawptr) -> bool {return false}, within = 3 * time.Second)
	testing.expect_value(t, up(&w), 1)
}
