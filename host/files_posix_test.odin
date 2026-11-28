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

// Waiting for the roster's lock, which another holds, a thread may be interrupted by a signal any number of
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

	// Another holds the lock a while, as an admin command keeping a roster does: on a file of its own, opened by another
	// thread, flock's lock being an open file's, held against another of this process as against another process. Not by
	// a process forked from this one, which would share every file open in the tests beside this one, until it had
	// closed each: a store's directory among them, held by that child too (see hold.odin), after its node was done.
	Holder :: struct {
		lock:  cstring,
		ready: sync.Sema,
		ok:    bool,
	}
	holder := Holder{lock = strings.clone_to_cstring(file_in(dir, "roster.lock"), context.temp_allocator)}
	holding := thread.create_and_start_with_poly_data(&holder, proc(h: ^Holder) {
		fd := posix.open(h.lock, {.RDWR, .CREAT, .CLOEXEC}, posix.mode_t{.IRUSR, .IWUSR})
		h.ok = fd >= 0 && flock(fd, LOCK_EX) == 0
		sync.sema_post(&h.ready)
		if h.ok {
			time.sleep(600 * time.Millisecond)
		}
		if fd >= 0 {
			posix.close(fd) // which lets go of the lock
		}
	})
	sync.sema_wait(&holder.ready)
	testing.expect(t, holder.ok, "the other could not take the lock")

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
	thread.join(holding)
	thread.destroy(holding)
	testing.expectf(t, sync.atomic_load(&interruptions) > 0 && waited >= 300 * time.Millisecond, "not interrupted while it waited (%d, %v)", interruptions, waited)
	testing.expectf(t, this && ok, "an interrupted wait for the lock, taken for a failure to keep the roster (this %v, ok %v)", this, ok)
}
