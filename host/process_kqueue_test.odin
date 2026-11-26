#+build darwin, freebsd, netbsd, openbsd
package host

import "core:nbio"
import "core:sys/posix"
import "core:testing"
import "core:time"
import kq "core:sys/kqueue"

// A process said to have ended a moment before it can be reaped, as macOS may say it, is reaped all the same: what its
// watch had to say it has said, and no more will come of it.
@(test)
process_reaped_though_told_early :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	r: Ran
	defer ran_destroy(&r)
	if err := ran_start(&r, {argv = {"sleep", "0.3"}}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	// As though its NOTE_EXIT had come and gone, and it were reaped too soon after.
	if r.p.watch_op != nil {
		nbio.remove(r.p.watch_op)
		r.p.watch_op = nil
	}
	gone := [1]kq.KEvent{{ident = uintptr(r.p.pid), filter = .Proc, flags = {.Delete}}}
	zero: posix.timespec
	kq.kevent(r.p.watch, gone[:], nil, &zero)
	process_reap(r.p)
	testing.expect(t, ran_until(&r, ran_exited, 5 * time.Second), "never reaped")
	testing.expect_value(t, r.exit, Exit{})
}
