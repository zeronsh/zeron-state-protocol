#+build !windows
package host

import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "../zsp"

@(private = "file")
interruptions: int // atomic

// Waiting for the roster's lock, which another process holds, a thread may be interrupted by a signal any number of
// times, as one with a handler without SA_RESTART does: it waits on, and keeps the roster once the lock is free, rather
// than taking the interruption for a failure to keep it, which stops the node.
@(test)
files_lock_waits_through_signals :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-eintr-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	secret, root: zsp.Key32
	secret[0], root[0] = 3, 4
	keys: zsp.Keyring
	zsp.keyring_init(&keys, secret)
	defer zsp.keyring_destroy(&keys)
	space := zsp.ed25519_public(root)
	none: zsp.Roster
	d := zsp.draft_from(&none, 1 << 16)
	zsp.draft_grant(&d, keys.device, keys.signer, zsp.draft_scope(&d), {.Write}).owner = true
	roster, signed := zsp.roster_sign(&keys, root, &d, context.temp_allocator)
	testing.expect(t, signed)

	// Another process holds the lock a while, as an admin command keeping a roster does.
	lock := strings.clone_to_cstring(file_in(dir, "roster.lock"), context.temp_allocator)
	ready: [2]posix.FD
	testing.expect(t, posix.pipe(&ready) == .OK)
	limit: posix.rlimit
	posix.getrlimit(.NOFILE, &limit)
	child := posix.fork()
	if child == 0 {
		// None of the files of the tests beside this one: a store's directory another holds (see hold.odin) would be
		// held by this child too, until it ended.
		for fd in 3 ..< posix.FD(min(limit.rlim_cur, 1 << 20)) {
			if fd != ready[1] {
				posix.close(fd)
			}
		}
		fd := posix.open(lock, {.RDWR, .CREAT, .CLOEXEC}, posix.mode_t{.IRUSR, .IWUSR})
		if fd < 0 || posix.lockf(fd, .LOCK, 0) != .OK {
			posix._exit(1)
		}
		b := byte(1)
		posix.write(ready[1], &b, 1)
		time.sleep(600 * time.Millisecond)
		posix._exit(0)
	}
	testing.expect(t, child > 0)
	posix.close(ready[1])
	b: byte
	testing.expect(t, posix.read(ready[0], &b, 1) == 1, "the other process could not take the lock")
	posix.close(ready[0])

	// A handler without SA_RESTART, and this thread interrupted by it, again and again, while it waits.
	sa: posix.sigaction_t
	sa.sa_handler = proc "c" (_: posix.Signal) {
		sync.atomic_add(&interruptions, 1)
	}
	posix.sigemptyset(&sa.sa_mask)
	was: posix.sigaction_t
	testing.expect(t, posix.sigaction(.SIGUSR2, &sa, &was) == .OK)
	defer posix.sigaction(.SIGUSR2, &was, nil)
	Interrupter :: struct {
		target: posix.pthread_t,
		done:   bool, // atomic
	}
	it := Interrupter{target = posix.pthread_self()}
	interrupter := thread.create_and_start_with_poly_data(&it, proc(it: ^Interrupter) {
		for !sync.atomic_load(&it.done) {
			time.sleep(20 * time.Millisecond)
			if !sync.atomic_load(&it.done) {
				posix.pthread_kill(it.target, .SIGUSR2)
			}
		}
	})
	sync.atomic_store(&interruptions, 0)
	start := time.tick_now()
	this, ok := roster_keep(dir, space, roster)
	waited := time.tick_since(start)
	sync.atomic_store(&it.done, true)
	thread.join(interrupter)
	thread.destroy(interrupter)
	status: i32
	posix.waitpid(child, &status, {})
	testing.expectf(t, sync.atomic_load(&interruptions) > 0 && waited >= 300 * time.Millisecond, "not interrupted while it waited (%d, %v)", interruptions, waited)
	testing.expectf(t, this && ok, "an interrupted wait for the lock, taken for a failure to keep the roster (this %v, ok %v)", this, ok)
}
