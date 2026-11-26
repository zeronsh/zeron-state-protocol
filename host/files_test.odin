package host

import "core:crypto"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "../zsp"

// How the transfers of a test went.
@(private)
Outcomes :: struct {
	results: [dynamic]Transfer_Result,
}

@(private)
outcome :: proc(data: rawptr, t: ^Transfer) {
	o := (^Outcomes)(data)
	r := t.result
	r.reason = strings.clone(r.reason)
	append(&o.results, r)
}

@(private)
outcomes_destroy :: proc(o: ^Outcomes) {
	for r in o.results {
		delete(r.reason)
	}
	delete(o.results)
}

@(private)
outcomes_wait :: proc(w: ^World, o: ^Outcomes, n: int) -> bool {
	Wait :: struct {
		o: ^Outcomes,
		n: int,
	}
	wait := Wait{o, n}
	return world_run(w, proc(w: ^World, data: rawptr) -> bool {
		d := (^Wait)(data)
		return len(d.o.results) >= d.n && nobody_left(w, nil)
	}, &wait)
}

@(private)
random_file :: proc(path: string, size: int) -> []byte {
	data := make([]byte, size)
	crypto.rand_bytes(data)
	_ = os.write_entire_file(path, data)
	return data
}

@(private)
in_world :: proc(w: ^World, parts: ..string) -> string {
	all := make([dynamic]string, 0, len(parts) + 1, context.temp_allocator)
	append(&all, w.root)
	append(&all, ..parts)
	p, _ := filepath.join(all[:], context.temp_allocator)
	return p
}

// A file goes to B and comes back, whole and checked, its time kept; through a folder made on the way.
@(test)
files_round_trip :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	os.make_directory(in_world(&w, "mine"))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs write ", in_world(&w, "shared")}, context.temp_allocator)))
	sent := random_file(in_world(&w, "mine", "x.bin"), 5 * CHUNK + 12345)
	defer delete(sent)
	o: Outcomes
	defer outcomes_destroy(&o)
	testing.expect(t, host_put(a, w.keys[2].device, 1, in_world(&w, "mine", "x.bin"), "docs/sub/x.bin", false, outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	testing.expectf(t, o.results[0].status == .Ok, "%v %s", o.results[0].status, o.results[0].reason)
	there, _ := os.read_entire_file(in_world(&w, "shared", "sub", "x.bin"), context.temp_allocator)
	testing.expect(t, string(there) == string(sent))
	mine, _ := os.stat(in_world(&w, "mine", "x.bin"), context.temp_allocator)
	theirs, _ := os.stat(in_world(&w, "shared", "sub", "x.bin"), context.temp_allocator)
	testing.expect(t, unix_ms(mine.modification_time) == unix_ms(theirs.modification_time))
	// Again, without leave to replace it: refused.
	testing.expect(t, host_put(a, w.keys[2].device, 1, in_world(&w, "mine", "x.bin"), "docs/sub/x.bin", false, outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 2))
	testing.expect_value(t, o.results[1].status, Status.Exists)
	// And back.
	testing.expect(t, host_get(a, w.keys[2].device, 1, "docs/sub/x.bin", in_world(&w, "mine", "y.bin"), outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 3))
	testing.expectf(t, o.results[2].status == .Ok, "%v %s", o.results[2].status, o.results[2].reason)
	back, _ := os.read_entire_file(in_world(&w, "mine", "y.bin"), context.temp_allocator)
	testing.expect(t, string(back) == string(sent))
	testing.expect(t, o.results[0].hash == o.results[2].hash)
	testing.expect(t, !os.exists(in_world(&w, "mine", "y.bin" + PART)) && !os.exists(in_world(&w, "shared", "sub", "x.bin" + PART)))
	// An empty file, too.
	_ = os.write_entire_file(in_world(&w, "shared", "empty"), nil)
	testing.expect(t, host_get(a, w.keys[2].device, 1, "docs/empty", in_world(&w, "mine", "empty"), outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 4))
	testing.expectf(t, o.results[3].status == .Ok && os.exists(in_world(&w, "mine", "empty")), "%v", o.results[3].status)
	log, _ := os.read_entire_file(file_in(b.dir, "audit.log"), context.temp_allocator)
	testing.expect(t, strings.count(string(log), `"service":"files"`) >= 6)
}

// What a transfer cut off after `chunks` chunks leaves behind, beside where the file was going: its first chunks, and
// the record of which file it is and of those chunks' hashes, as transfer.odin and files.odin keep them.
@(private)
leave_part :: proc(data: []byte, chunks: int, target: string, source: string, put: bool) {
	f, _ := os.open(source, {.Read})
	identity, _, _ := file_identity(f)
	os.close(f)
	_ = os.write_entire_file(path_with(target, PART), data[:chunks * CHUNK])
	meta := make([dynamic]byte, context.temp_allocator)
	zsp.write_bytes(&meta, identity)
	if put {
		zsp.write_varint(&meta, u64(len(data)))
	}
	for i in 0 ..< chunks {
		h: Hashing
		hashing_init(&h)
		hashing_feed(&h, data[i * CHUNK:][:CHUNK])
		hash := hashing_chunk(&h)
		append(&meta, ..hash[:])
	}
	_ = os.write_entire_file(path_with(path_with(target, PART), ".meta"), meta[:])
}

// A transfer cut off midway takes up where it stopped, both ways, carrying only the rest; one whose file changed since
// begins again; one whose part is not what its record says begins again too, or fails without harm.
@(test)
files_resume :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	os.make_directory(in_world(&w, "mine"))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs write ", in_world(&w, "shared")}, context.temp_allocator)))
	size := 12 * CHUNK + 777
	data := random_file(in_world(&w, "shared", "big"), size)
	defer delete(data)
	o: Outcomes
	defer outcomes_destroy(&o)
	// Fetched, cut off after five chunks.
	leave_part(data, 5, in_world(&w, "mine", "big"), in_world(&w, "shared", "big"), false)
	testing.expect(t, host_get(a, w.keys[2].device, 1, "docs/big", in_world(&w, "mine", "big"), outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	r := o.results[0]
	testing.expectf(t, r.status == .Ok && r.resumed == 5 * CHUNK && r.bytes == u64(size - 5 * CHUNK), "%v from %d, %d this time", r.status, r.resumed, r.bytes)
	back, _ := os.read_entire_file(in_world(&w, "mine", "big"), context.temp_allocator)
	testing.expect(t, string(back) == string(data))
	// Sent, cut off after seven.
	clear(&o.results)
	leave_part(data, 7, in_world(&w, "shared", "copy"), in_world(&w, "mine", "big"), true)
	testing.expect(t, host_put(a, w.keys[2].device, 1, in_world(&w, "mine", "big"), "docs/copy", false, outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	r = o.results[0]
	testing.expectf(t, r.status == .Ok && r.bytes == u64(size - 7 * CHUNK), "%v %d this time", r.status, r.bytes)
	copied, _ := os.read_entire_file(in_world(&w, "shared", "copy"), context.temp_allocator)
	testing.expect(t, string(copied) == string(data))
	// Cut off, and the file there changed since: begun again, and what comes is the new file.
	clear(&o.results)
	os.remove(in_world(&w, "mine", "big"))
	leave_part(data, 5, in_world(&w, "mine", "big"), in_world(&w, "shared", "big"), false)
	changed := random_file(in_world(&w, "shared", "big"), 6 * CHUNK)
	defer delete(changed)
	testing.expect(t, host_get(a, w.keys[2].device, 1, "docs/big", in_world(&w, "mine", "big"), outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	testing.expectf(t, o.results[0].status == .Ok && o.results[0].resumed == 0, "%v from %d", o.results[0].status, o.results[0].resumed)
	back2, _ := os.read_entire_file(in_world(&w, "mine", "big"), context.temp_allocator)
	testing.expect(t, string(back2) == string(changed))
	// A part changed on this disk since its chunks were checked: read again before it is taken up from, it is taken
	// up only from before the change.
	clear(&o.results)
	os.remove(in_world(&w, "mine", "big"))
	spoiled := make([]byte, len(changed))
	defer delete(spoiled)
	copy(spoiled, changed)
	leave_part(spoiled, 2, in_world(&w, "mine", "big"), in_world(&w, "shared", "big"), false)
	f, _ := os.open(path_with(in_world(&w, "mine", "big"), PART), {.Read, .Write})
	os.write_at(f, []byte{0xff, 0xfe}, CHUNK + 5) // within a chunk taken: unseen, until the file's hash
	os.close(f)
	testing.expect(t, host_get(a, w.keys[2].device, 1, "docs/big", in_world(&w, "mine", "big"), outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	back3, _ := os.read_entire_file(in_world(&w, "mine", "big"), context.temp_allocator)
	testing.expectf(t, o.results[0].status == .Ok && o.results[0].resumed == CHUNK && string(back3) == string(changed), "%v from %d", o.results[0].status, o.results[0].resumed)
	// The same for a part being received.
	clear(&o.results)
	os.remove(in_world(&w, "shared", "copy"))
	leave_part(changed, 4, in_world(&w, "shared", "copy"), in_world(&w, "mine", "big"), true) // which is now `changed`
	g, _ := os.open(path_with(in_world(&w, "shared", "copy"), PART), {.Read, .Write})
	os.write_at(g, []byte{0xff}, 2 * CHUNK + 9)
	os.close(g)
	testing.expect(t, host_put(a, w.keys[2].device, 1, in_world(&w, "mine", "big"), "docs/copy", false, outcome, &o) != 0)
	testing.expect(t, outcomes_wait(&w, &o, 1))
	copied2, _ := os.read_entire_file(in_world(&w, "shared", "copy"), context.temp_allocator)
	testing.expectf(t, o.results[0].status == .Ok && o.results[0].bytes == u64(len(changed) - 2 * CHUNK) && string(copied2) == string(changed), "%v %d", o.results[0].status, o.results[0].bytes)
}

// What is not shared, what lies outside a share by '..' or by a link, what may only be read, what nobody may use
// without the Files right: all refused, and written down.
@(test)
files_refused :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, grant_b = {.Read, .Write, .Call}))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	os.make_directory(in_world(&w, "secret"))
	os.make_directory(in_world(&w, "mine"))
	_ = os.write_entire_file(in_world(&w, "secret", "key"), transmute([]byte)string("hush"))
	_ = os.write_entire_file(in_world(&w, "shared", "ok"), transmute([]byte)string("fine"))
	_ = os.write_entire_file(in_world(&w, "mine", "x"), transmute([]byte)string("x"))
	shares := strings.concatenate({"files 1 docs read ", in_world(&w, "shared"), "\nfiles 1 out write ", in_world(&w, "secret")}, context.temp_allocator)
	testing.expect(t, shares_set(b, shares))
	testing.expect(t, shares_set(a, strings.concatenate({"files 1 hers write ", in_world(&w, "mine")}, context.temp_allocator)))
	when ODIN_OS != .Windows {
		testing.expect(t, os.symlink(in_world(&w, "secret", "key"), in_world(&w, "shared", "link")) == nil)
	}
	o: Outcomes
	defer outcomes_destroy(&o)
	Case :: struct {
		remote: string,
		put:    bool,
		scope:  zsp.Scope,
		status: Status,
	}
	cases := []Case {
		{"nope/ok", false, 1, .Not_Offered},
		{"docs/../secret/key", false, 1, .Denied},
		{"docs/ok", true, 1, .Denied}, // read only
		{"docs/missing", false, 1, .Not_Found},
		{"docs/ok", false, 1, .Ok},
	}
	for k, i in cases {
		if k.put {
			host_put(a, w.keys[2].device, k.scope, in_world(&w, "mine", "x"), k.remote, true, outcome, &o)
		} else {
			host_get(a, w.keys[2].device, k.scope, k.remote, in_world(&w, "mine", "got"), outcome, &o)
		}
		testing.expect(t, outcomes_wait(&w, &o, i + 1))
		testing.expectf(t, o.results[i].status == k.status, "%s: %v", k.remote, o.results[i].status)
	}
	when ODIN_OS != .Windows {
		host_get(a, w.keys[2].device, 1, "docs/link", in_world(&w, "mine", "got2"), outcome, &o)
		testing.expect(t, outcomes_wait(&w, &o, len(cases) + 1))
		testing.expectf(t, o.results[len(cases)].status == .Denied, "a link out: %v", o.results[len(cases)].status)
	}
	// B has no Files right in scope 1: A's share is not for it.
	n := len(o.results)
	host_get(b, w.keys[1].device, 1, "hers/x", in_world(&w, "got3"), outcome, &o)
	testing.expect(t, outcomes_wait(&w, &o, n + 1))
	testing.expect_value(t, o.results[n].status, Status.Denied)
	log, _ := os.read_entire_file(file_in(b.dir, "audit.log"), context.temp_allocator)
	testing.expect(t, strings.count(string(log), `"event":"denied"`) >= 3)
	testing.expect(t, !os.exists(in_world(&w, "mine", "got")) || string(os.read_entire_file(in_world(&w, "mine", "got"), context.temp_allocator) or_else nil) == "fine")
}

// A share withdrawn while it is used ends what uses it, at once.
@(test)
files_withdrawn :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	os.make_directory(in_world(&w, "shared"))
	os.make_directory(in_world(&w, "mine"))
	testing.expect(t, shares_set(b, strings.concatenate({"files 1 docs read ", in_world(&w, "shared"), "\nshell 1"}, context.temp_allocator)))
	data := random_file(in_world(&w, "shared", "big"), 64 * CHUNK)
	defer delete(data)
	o: Outcomes
	defer outcomes_destroy(&o)
	host_get(a, w.keys[2].device, 1, "docs/big", in_world(&w, "mine", "big"), outcome, &o)
	testing.expect(t, world_run(&w, proc(w: ^World, data: rawptr) -> bool {
		return len(world_space(w, 2).services) == 1
	}))
	testing.expect(t, shares_set(b, "shell 1"))
	testing.expect(t, outcomes_wait(&w, &o, 1))
	testing.expectf(t, o.results[0].status == .Denied, "%v", o.results[0].status)
	testing.expect_value(t, len(b.services), 0)
}

// What a device offers, as zsp.services tells whoever asks: what their rights let them use.
@(test)
services_listed :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = true))
	a, b := world_space(&w, 1), world_space(&w, 2)
	testing.expect(t, shares_set(b, strings.concatenate({"shell 1 terminal\nfiles 1 docs read ", w.root, "\nfiles 2 other write ", w.root}, context.temp_allocator)))
	Heard :: struct {
		using handler: Call_Handler,
		got:  [dynamic]byte,
		done: bool,
	}
	heard: Heard
	defer delete(heard.got)
	heard.data = &heard
	heard.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		append(&(^Heard)(h.data).got, ..bytes)
		return true
	}
	heard.on_end = proc(h: ^Call_Handler, call: u64) {(^Heard)(h.data).done = true}
	call := host_call(a, w.keys[2].device, 1, "zsp.services", nil, &heard.handler)
	testing.expect(t, call != 0)
	testing.expect(t, world_run(&w, proc(w: ^World, h: rawptr) -> bool {return (^Heard)(h).done}, &heard))
	call_end(a, call)
	want := [?]byte{0, 1, 1, 2, 1, 4, 'd', 'o', 'c', 's'}
	testing.expectf(t, string(heard.got[:]) == string(want[:]), "%v", heard.got[:])
}
