package host

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../pipe"
import "../zsp"

// Each a reproduction from adversarial review, kept so that what it found stays found.

// A handler that keeps every message, and says how the call went.
@(private)
Review_Recv :: struct {
	using handler: Call_Handler,
	msgs:    [dynamic][]byte,
	ended:   bool,
	faulted: bool,
}

@(private)
review_recv_init :: proc(r: ^Review_Recv) {
	r.data = r
	r.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		r := (^Review_Recv)(h.data)
		m := make([]byte, len(bytes))
		copy(m, bytes)
		append(&r.msgs, m)
		return true
	}
	r.on_end = proc(h: ^Call_Handler, call: u64) {(^Review_Recv)(h.data).ended = true}
	r.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {(^Review_Recv)(h.data).faulted = true}
}

@(private)
review_recv_destroy :: proc(r: ^Review_Recv) {
	for m in r.msgs {
		delete(m)
	}
	delete(r.msgs)
}

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
local_call :: proc(local: ^zsp.Session, id: u64, device: zsp.Key32, scope: zsp.Scope, method: string, first: []byte) -> bool {
	cf := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&cf, .Call)
	zsp.write_varint(&cf, id)
	device := device
	append(&cf, ..device[:])
	zsp.write_varint(&cf, u64(scope))
	zsp.write_bytes(&cf, transmute([]byte)method)
	zsp.write_bytes(&cf, nil)
	append(&cf, ..first)
	zsp.frame_end(&cf, at)
	return zsp.session_input(local, cf[:])
}

// A link to the side of a part, out of the share, is not followed: not to read it, not to write it.
@(test)
review_put_meta_link_is_not_followed :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	os.make_directory(in_world(&w, "outside"))
	os.make_directory(in_world(&w, "mine"))
	victim := strings.clone(in_world(&w, "outside", "secret.txt"))
	defer delete(victim)
	_ = os.write_entire_file(victim, transmute([]byte)string("DO NOT OVERWRITE THIS SECRET"))
	_ = os.write_entire_file(in_world(&w, "mine", "payload"), transmute([]byte)string("hello"))
	testing.expect(t, os.symlink(victim, in_world(&w, "shared", "target" + PART + ".meta")) == nil)
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs write ", in_world(&w, "shared")}, context.temp_allocator)))
	o: Outcomes
	defer outcomes_destroy(&o)
	testing.expect(t, host_put(a, w.keys[2].device, 1, in_world(&w, "mine", "payload"), "docs/target", true, outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	after, err := os.read_entire_file(victim, context.temp_allocator)
	testing.expectf(t, err == nil && string(after) == "DO NOT OVERWRITE THIS SECRET", "written through a link out: %v %q", o.results[0].status, after)
}

// What a part's progress is kept in is no file of the share's, to get or put.
@(test)
review_meta_files_are_not_served :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	os.make_directory(in_world(&w, "mine"))
	_ = os.write_entire_file(in_world(&w, "shared", "foo" + PART + ".meta"), transmute([]byte)string("internal-meta"))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs read ", in_world(&w, "shared")}, context.temp_allocator)))
	o: Outcomes
	defer outcomes_destroy(&o)
	testing.expect(t, host_get(a, w.keys[2].device, 1, "docs/foo" + PART + ".meta", in_world(&w, "mine", "got"), outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	testing.expectf(t, o.results[0].status == .Denied, "%v", o.results[0].status)
}

// Folders are made only within the share: not in another whose name begins as the share's does.
@(test)
review_mkdirs_stays_within :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		return
	}
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	share_dir := strings.clone(in_world(&w, "share"))
	sibling_dir := strings.clone(in_world(&w, "share_secret"))
	defer delete(share_dir)
	defer delete(sibling_dir)
	os.make_directory(share_dir)
	os.make_directory(sibling_dir)
	os.make_directory(in_world(&w, "mine"))
	_ = os.write_entire_file(in_world(&w, "mine", "x"), transmute([]byte)string("x"))
	testing.expect(t, os.symlink(sibling_dir, in_world(&w, "share", "out")) == nil)
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs write ", share_dir}, context.temp_allocator)))
	o: Outcomes
	defer outcomes_destroy(&o)
	testing.expect(t, host_put(a, w.keys[2].device, 1, in_world(&w, "mine", "x"), "docs/out/escaped_dir/nested/file", true, outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	escaped := in_world(&w, "share_secret", "escaped_dir")
	testing.expectf(t, !os.exists(escaped), "made %s, out of the share (%v)", escaped, o.results[0].status)
}

// A path that names the share itself, however it is written, is no file to put, and nothing is made beside it.
@(test)
review_put_of_the_share_itself :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs write ", in_world(&w, "shared")}, context.temp_allocator)))
	for path in ([]string{"docs//", "docs/./", "docs/ /"}) {
		first := make([dynamic]byte, context.temp_allocator)
		zsp.write_bytes(&first, transmute([]byte)path)
		zsp.write_varint(&first, 1)
		zsp.write_varint(&first, 0)
		zsp.write_bytes(&first, nil)
		append(&first, 1)
		recv: Review_Recv
		review_recv_init(&recv)
		defer review_recv_destroy(&recv)
		call := host_call(a, w.keys[2].device, 1, "zsp.put", first[:], &recv.handler)
		testing.expect(t, call != 0)
		call_end(a, call)
		testing.expect(t, world_run(&w, proc(w: ^World, d: rawptr) -> bool {
			r := (^Review_Recv)(d)
			return (r.ended || r.faulted) && nobody_left(w, nil)
		}, &recv))
		testing.expectf(t, !os.exists(in_world(&w, "shared" + PART)), "%q made a part beside the share", path)
		testing.expectf(t, len(recv.msgs) > 0 && Status(recv.msgs[0][0]) != .Ok, "%q was taken", path)
	}
}

// A share moved to another folder under the same name ends what used the old one.
@(test)
review_share_moved_ends_its_calls :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "secret_dir"))
	os.make_directory(in_world(&w, "public_dir"))
	os.make_directory(in_world(&w, "mine"))
	data := random_file(in_world(&w, "secret_dir", "big"), 64 * CHUNK)
	defer delete(data)
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs read ", in_world(&w, "secret_dir")}, context.temp_allocator)))
	o: Outcomes
	defer outcomes_destroy(&o)
	host_get(a, w.keys[2].device, 1, "docs/big", in_world(&w, "mine", "big"), outcome, &o)
	testing.expect(t, world_run(&w, proc(w: ^World, d: rawptr) -> bool {return len(world_space(w, 2).services) == 1}))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs read ", in_world(&w, "public_dir")}, context.temp_allocator)))
	testing.expect(t, outcomes_wait(&w, &o, 1))
	testing.expectf(t, o.results[0].status == .Denied, "%v, %d bytes", o.results[0].status, o.results[0].bytes)
}

// Shares are for a client that may act in every scope to see and change: not for one let into one.
@(test)
review_shares_not_for_a_client_of_one_scope :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	a := world_space(&w, 1)
	secret_dir := strings.clone(in_world(&w, "secret"))
	defer delete(secret_dir)
	os.make_directory(secret_dir)
	testing.expect(t, shares_set(a, strings.concatenate({"files 1 secret read ", secret_dir}, context.temp_allocator)))
	local := open_local_session(t, a, w.space, []zsp.Grant{{scope = 1, rights = {.Read, .Write, .Call}}})
	defer zsp.session_close(local)
	testing.expect(t, local_call(local, 1, w.keys[1].device, 1, "zsp.share", nil))
	out := string(zsp.session_output(local))
	leaked := strings.contains(out, secret_dir)
	zsp.session_sent(local, len(out))
	testing.expect(t, local_call(local, 2, w.keys[1].device, 1, "zsp.share", transmute([]byte)string("shell 1 terminal commands\n")))
	changed := len(a.shares) == 1 && a.shares[0].kind == .Shell
	testing.expectf(t, !leaked && !changed, "leaked %v, changed %v", leaked, changed)
}

// A knock heard before, through a relay, is not heard again however long after; nor does a newer one end a live
// link until it proves itself; and a knock again by another relay is answered by that one.
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

// A file sent whole is closed at once, though the caller never says it has done.
@(test)
review_get_closes_its_file :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	_ = os.write_entire_file(in_world(&w, "shared", "tiny.txt"), transmute([]byte)string("hello"))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs read ", in_world(&w, "shared")}, context.temp_allocator)))
	first := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&first, transmute([]byte)string("docs/tiny.txt"))
	zsp.write_varint(&first, 0)
	zsp.write_bytes(&first, nil)
	recv: Review_Recv
	review_recv_init(&recv)
	defer review_recv_destroy(&recv)
	call := host_call(a, w.keys[2].device, 1, "zsp.get", first[:], &recv.handler)
	testing.expect(t, call != 0)
	testing.expect(t, world_run(&w, proc(w: ^World, d: rawptr) -> bool {return (^Review_Recv)(d).ended}, &recv))
	open := false
	for c in b.calls {
		if c.handler != nil && c.handler.data != nil && c.handler.on_room != nil {
			open ||= (^Get)(c.handler.data).f != nil
		}
	}
	call_end(a, call)
	world_run(&w, nobody_left)
	testing.expect(t, !open, "the file stayed open")
}

// Files of every size about the edge of the first window come whole: what follows the last bytes has room too.
@(test)
review_get_near_the_window :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	os.make_directory(in_world(&w, "mine"))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs read ", in_world(&w, "shared")}, context.temp_allocator)))
	for delta in 1 ..= 120 {
		size := zsp.CALL_WINDOW - delta
		name := fmt.tprintf("f_%d", size)
		data := random_file(in_world(&w, "shared", name), size)
		defer delete(data)
		o: Outcomes
		defer outcomes_destroy(&o)
		testing.expect(t, host_get(a, w.keys[2].device, 1, fmt.tprintf("docs/%s", name), in_world(&w, "mine", name), outcome, &o) != 0)
		testing.expect(t, outcomes_wait(&w, &o, 1))
		if o.results[0].status != .Ok {
			testing.expectf(t, false, "size %d: %v %s", size, o.results[0].status, o.results[0].reason)
			break
		}
	}
}

// A folder of more names than a window holds is listed whole.
@(test)
review_list_is_whole :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	big_dir := in_world(&w, "bigdir")
	os.make_directory(big_dir)
	TOTAL :: 4500
	for i in 0 ..< TOTAL {
		name := fmt.tprintf("file_entry_padding_to_exceed_initial_call_window_%015d", i)
		if f, err := os.open(in_world(&w, "bigdir", name), {.Write, .Create}, os.Permissions{.Read_User, .Write_User}); err == nil {
			os.close(f)
		}
	}
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs read ", big_dir}, context.temp_allocator)))
	first := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&first, transmute([]byte)string("docs"))
	recv: Review_Recv
	review_recv_init(&recv)
	defer review_recv_destroy(&recv)
	call := host_call(a, w.keys[2].device, 1, "zsp.list", first[:], &recv.handler)
	testing.expect(t, call != 0)
	call_end(a, call)
	testing.expect(t, world_run(&w, proc(w: ^World, d: rawptr) -> bool {return (^Review_Recv)(d).ended && nobody_left(w, nil)}, &recv))
	count := 0
	for msg, idx in recv.msgs {
		if idx == 0 {
			continue
		}
		r := zsp.Reader{buf = msg}
		for r.pos < len(r.buf) && !r.bad {
			_ = zsp.read_u8(&r)
			_ = zsp.read_bytes(&r)
			_ = zsp.read_varint(&r)
			_ = zsp.read_varint(&r)
			if !r.bad {
				count += 1
			}
		}
	}
	testing.expectf(t, count == TOTAL, "%d of %d", count, TOTAL)
}

// A space closed while a port is being dialled for it: the dial ends without touching what is gone.
@(test)
review_space_closed_while_dialling :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	l, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	defer net.close(l)
	bound, _ := net.bound_endpoint(l)
	sp := world_space(&w, 1)
	b := bridge_new(sp, 42)
	bridge_dial(b, {net.IP4_Loopback, bound.port})
	space_close(sp)
	ordered_remove(&w.hosts[1].spaces, 0)
	// Abandoned, dialling still: it must hold nothing of the space, which is gone.
	testing.expect(t, b.abandoned && b.sp == nil, "an abandoned dial holds its space")
	// And it ends, letting go of all it has, without touching it.
	for _ in 0 ..< 20 {
		_ = nbio.tick(10 * time.Millisecond)
	}
}

// The audit log, unable to be set aside, goes on rather than crashing; and what one call writes in it is bounded.
@(test)
review_audit_cannot_set_aside :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	sp := world_space(&w, 1)
	aside := path_with(file_in(sp.dir, "audit.log"), ".1")
	testing.expect(t, os.make_directory(aside) == nil)
	_ = os.write_entire_file(file_in(aside, "blocker"), transmute([]byte)string("x"))
	big := make([]byte, AUDIT_MOST, context.temp_allocator)
	_ = os.write_entire_file(file_in(sp.dir, "audit.log"), big)
	audit(sp, {device = sp.host.device, scope = 1, service = "files", detail = "trigger", event = .Denied})
	audit(sp, {device = sp.host.device, scope = 1, service = "files", detail = strings.repeat("x", 1 << 20, context.temp_allocator), event = .Denied})
	info, _ := os.stat(file_in(sp.dir, "audit.log"), context.temp_allocator)
	testing.expectf(t, info.size <= AUDIT_MOST + 4096, "the log is %d", info.size)
}

// A device's own clients reach no port through it.
@(test)
review_local_client_reaches_no_port :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	a := world_space(&w, 1)
	e: Echo
	testing.expect(t, echo_start(&e))
	defer echo_stop(&e)
	open_port = u16(e.port)
	w.hosts[1].port_permitted = permit_open_port
	local := open_local_session(t, a, w.space, []zsp.Grant{{scope = 1, rights = {.Read, .Write, .Call}}})
	defer zsp.session_close(local)
	port := [2]byte{u8(e.port >> 8), u8(e.port)}
	testing.expect(t, local_call(local, 1, w.keys[1].device, 1, "zsp.tcp", port[:]))
	testing.expectf(t, len(a.bridges) == 0, "%d bridges", len(a.bridges))
}

// A file put without the whole file's hash is not put.
@(test)
review_put_needs_the_whole_hash :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs write ", in_world(&w, "shared")}, context.temp_allocator)))
	first := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&first, transmute([]byte)string("docs/nohash.txt"))
	zsp.write_varint(&first, 5)
	zsp.write_varint(&first, 0)
	zsp.write_bytes(&first, transmute([]byte)string("src"))
	append(&first, 1)
	recv: Review_Recv
	review_recv_init(&recv)
	defer review_recv_destroy(&recv)
	call := host_call(a, w.keys[2].device, 1, "zsp.put", first[:], &recv.handler)
	testing.expect(t, world_run(&w, proc(w: ^World, d: rawptr) -> bool {return len((^Review_Recv)(d).msgs) >= 1}, &recv))
	h: Hashing
	hashing_init(&h)
	hashing_feed(&h, transmute([]byte)string("hello"))
	chunk := hashing_chunk(&h)
	call_send(a, call, transmute([]byte)string("\x01hello"))
	hash_msg: [33]byte
	hash_msg[0] = 2
	copy(hash_msg[1:], chunk[:])
	call_send(a, call, hash_msg[:])
	call_send(a, call, []byte{3, u8(Status.Ok), 0xde})
	call_end(a, call)
	testing.expect(t, world_run(&w, proc(w: ^World, d: rawptr) -> bool {return (^Review_Recv)(d).ended && nobody_left(w, nil)}, &recv))
	final := Status(recv.msgs[len(recv.msgs) - 1][0])
	testing.expectf(t, final != .Ok && !os.exists(in_world(&w, "shared", "nohash.txt")), "%v", final)
}

// A file changed while it is sent is said to have changed.
@(test)
review_put_of_a_changing_file :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	os.make_directory(in_world(&w, "mine"))
	src := strings.clone(in_world(&w, "mine", "changing.bin"))
	defer delete(src)
	data := make([]byte, 4 * CHUNK)
	defer delete(data)
	for &x in data {
		x = 'A'
	}
	_ = os.write_entire_file(src, data)
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs write ", in_world(&w, "shared")}, context.temp_allocator)))
	o: Outcomes
	defer outcomes_destroy(&o)
	// Changed as soon as it begins: before the first credit has come back, so before it can all have gone.
	testing.expect(t, host_put(a, w.keys[2].device, 1, src, "docs/changing.bin", true, outcome, &o) != 0)
	for &x in data {
		x = 'B'
	}
	f, err := os.open(src, {.Write})
	testing.expect(t, err == nil)
	_, _ = os.write_at(f, data, 0)
	os.close(f)
	_ = os.change_times(src, time.now(), time.time_add(time.now(), 10 * time.Second))
	testing.expect(t, outcomes_wait(&w, &o, 1))
	testing.expectf(t, o.results[0].status == .Changed, "%v", o.results[0].status)
}

// Input held back from a process is credited whole, what tags it included.
@(test)
review_exec_credits_whole_messages :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	a := world_space(&w, 1)
	e := new(Exec)
	defer {
		delete(e.held)
		free(e)
	}
	dummy: Process
	e.sp, e.call, e.p, e.data, e.on_data = a, 777, &dummy, e, exec_on_data
	append(&e.held, 'A') // held already, so what comes is held too
	append(&a.calls, Host_Call{call = 777, handler = &e.handler, window = zsp.CALL_WINDOW, since = time.tick_now()})
	defer host_call_forget(a, 777)
	msg: [11]byte
	for _ in 0 ..< 10 {
		host_flow(a, 777, .Data, msg[:])
	}
	call_consumed(a, 777, 100) // what taking the held input credits
	c := host_call_find(a, 777)
	testing.expectf(t, c.used == 110, "%d credited of 110", c.used)
}
