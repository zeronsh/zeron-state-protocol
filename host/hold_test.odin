package host

import "base:runtime"
import "core:crypto"
import "core:encoding/hex"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../zsp"

// What the host said, at any level, while a test listened: kept, rather than failing the test as what is said at error
// level does. What the test itself says is passed on to the test's own logger, as its failures are.
@(private = "file")
Heard :: struct {
	said: [dynamic]string,
	test: runtime.Logger,
}

@(private = "file")
listening :: proc(heard: ^Heard) -> runtime.Logger {
	heard.test = context.logger
	return {
		data = heard,
		lowest_level = .Debug,
		procedure = proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
			heard := (^Heard)(data)
			if strings.has_suffix(location.file_path, "_test.odin") {
				heard.test.procedure(heard.test.data, level, text, options, location)
			} else {
				append(&heard.said, strings.clone(text, context.temp_allocator))
			}
		},
	}
}

@(private = "file")
heard_of :: proc(heard: ^Heard, what: string) -> bool {
	for s in heard.said {
		if strings.contains(s, what) {
			return true
		}
	}
	return false
}

// A store's directory is one node's: a second, as one in another process or in this one, is told it is in use, and
// leaves everything there as it was; once the first is done, it may. Two at once would each write over what the other
// wrote to the same log, and each acknowledge what the other had overwritten.
@(test)
hold_one_node_to_a_store :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-hold-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	heard: Heard
	defer delete(heard.said)
	logger := context.logger
	context.logger = listening(&heard)

	a: Host
	if !testing.expect(t, host_init(&a, {dir = dir, full = true}), "the first node does not start") {
		context.logger = logger
		return
	}
	key, _ := read_file(file_in(dir, "device.key"), context.temp_allocator)
	b: Host
	second := host_init(&b, {dir = dir, full = true})
	if second {
		host_destroy(&b)
	}
	testing.expect(t, !second, "a second node starts on a store in use")
	testing.expect(t, heard_of(&heard, "in use by another process"), "and is not told it is in use")
	// Nor does anything else that would keep a store there, nor make the device's key there.
	if lock, held := dir_hold(dir); held {
		dir_unlock(lock)
		testing.expect(t, false, "the directory is held twice")
	}
	other, _ := os.make_directory_temp(base, "zsp-hold-*", context.temp_allocator)
	defer os.remove_all(other)
	if lock, held := dir_hold(other); testing.expect(t, held) {
		_, made := device_secret(other)
		testing.expect(t, !made, "a device's key is made in a directory another holds, who may be making it")
		testing.expect(t, !os.exists(file_in(other, "device.key")))
		dir_unlock(lock)
	}
	_, made := device_secret(other)
	testing.expect(t, made && os.exists(file_in(other, "device.key")), "nor once it is let go of")
	kept, _ := read_file(file_in(dir, "device.key"), context.temp_allocator)
	testing.expect(t, string(kept) == string(key), "the device's key was changed")

	host_destroy(&a)
	resumed := host_init(&b, {dir = dir, full = true})
	context.logger = logger
	testing.expect(t, resumed, "the store is not let go of when its node is done")
	if resumed {
		host_destroy(&b)
	}
}

// So is each space's own directory, while its space is open, against whoever would keep a store there itself, as a Node
// device pointed at it would: a relay that is asked of a space is not kept from it by its own last try, which failed.
@(test)
hold_a_space_while_open :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-hold-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	heard: Heard
	defer delete(heard.said)
	logger := context.logger
	context.logger = listening(&heard)
	defer context.logger = logger

	h: Host
	if !testing.expect(t, host_init(&h, {dir = dir, relay = true, full = true})) {
		return
	}
	defer host_destroy(&h)
	space: zsp.Key32
	crypto.rand_bytes(space[:])
	sdir := file_in(dir, string(hex.encode(space[:], context.temp_allocator)))
	other, held := dir_hold(sdir) // as another keeping a store there
	testing.expect(t, held)
	s := space_open(&h, space)
	testing.expect(t, s == nil, "a space is opened in a directory another holds")
	testing.expect(t, heard_of(&heard, "in use by another process"))
	if held {
		dir_unlock(other)
	}
	s = space_open(&h, space)
	if !testing.expect(t, s != nil, "a space is kept from its directory by its own try before") {
		return
	}
	if _, again := dir_hold(sdir); again {
		testing.expect(t, false, "a space's directory is not held while it is open")
	}
	// And let go of when it is closed.
	for x, i in h.spaces {
		if x == s {
			unordered_remove(&h.spaces, i)
			break
		}
	}
	space_close(s)
	if lock, free := dir_hold(sdir); testing.expect(t, free, "a space's directory is held once it is closed") {
		dir_unlock(lock)
	}
}

// A store on a file system shared with other machines is refused, as its lock may not hold there.
@(test)
hold_refuses_what_other_machines_share :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		for magic in ([]u32{0x6969, 0xff534d42, 0xfe534d42, 0x517b, 0x01021997, 0x00c36400}) {
			remote, _ := remote_magic(magic)
			testing.expectf(t, remote, "%x is taken for a disk of this machine's own", magic)
		}
		// ext4, xfs, btrfs, tmpfs, overlayfs, FUSE
		for magic in ([]u32{0xef53, 0x58465342, 0x9123683e, 0x01021994, 0x794c7630, 0x65735546}) {
			remote, _ := remote_magic(magic)
			testing.expectf(t, !remote, "%x is taken for a file system other machines share", magic)
		}
	}
	// A directory of this machine's own is not refused.
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-hold-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	lock, held, _ := dir_try(dir)
	testing.expect(t, held == .Held, "a directory of this machine's own is refused")
	if held == .Held {
		dir_unlock(lock)
	}
	when ODIN_OS == .Windows {
		// The same directory, through this machine's own share of its drive: as a share of another's would be.
		if len(dir) > 2 && dir[1] == ':' {
			share := strings.concatenate({`\\localhost\`, dir[:1], `$`, dir[2:]}, context.temp_allocator)
			testing.expectf(t, os.is_dir(share), "%s cannot be reached", share)
			_, through, _ := dir_try(share)
			testing.expectf(t, through == .Remote, "%s is taken for a disk of this machine's own: %v", share, through)
		}
	}
}

// A directory is judged, made and held where the system takes its path to be: `<dir>/none/../there` is `<dir>/there`,
// and `none` is never made, nor `there` judged by `<dir>`, which may be another file system's.
@(test)
hold_where_the_system_takes_it :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-hold-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	sep := "\\" if ODIN_OS == .Windows else "/"
	roundabout := strings.concatenate({dir, sep, "none", sep, "..", sep, "there"}, context.temp_allocator)
	lock, held, _ := dir_try(roundabout)
	testing.expectf(t, held == .Held, "%s is not held: %v", roundabout, held)
	if held == .Held {
		dir_unlock(lock)
	}
	testing.expect(t, os.exists(file_in(file_in(dir, "there"), LOCK_FILE)), "the directory is not held where its path leads")
	testing.expect(t, !os.exists(file_in(dir, "none")), "a directory its path only passes through was made")
	start, starting := dir_starting(strings.concatenate({dir, sep, "gone", sep, "..", sep, "starting"}, context.temp_allocator))
	testing.expect(t, starting)
	if starting {
		dir_started(start)
	}
	testing.expect(t, os.exists(file_in(file_in(dir, "starting"), START_FILE)) && !os.exists(file_in(dir, "gone")))
}

// A node starting, or a command holding the directory a while, waits for another in a thread of its own process as for
// one in another process: which a process's own lock (lockf) would let through.
@(test)
hold_start_against_another_thread :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-hold-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	first, ok := dir_starting(dir)
	if !testing.expect(t, ok) {
		return
	}
	Second :: struct {
		dir:  string,
		done: bool, // atomic
	}
	second := Second{dir = dir}
	waiter := thread.create_and_start_with_poly_data(&second, proc(s: ^Second) {
		context = runtime.default_context()
		if lock, held := dir_starting(s.dir); held {
			sync.atomic_store(&s.done, true)
			dir_started(lock)
		}
	})
	time.sleep(200 * time.Millisecond)
	testing.expect(t, !sync.atomic_load(&second.done), "another thread started while this one was starting")
	dir_started(first)
	thread.join(waiter)
	thread.destroy(waiter)
	testing.expect(t, sync.atomic_load(&second.done), "the other thread never started")
}
