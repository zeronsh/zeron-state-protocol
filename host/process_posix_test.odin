#+build !windows
package host

import "core:nbio"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"

// What a child of this process should not have of it: its other descriptors, and the signals it ignores.

@(test)
process_has_only_its_stdio :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	// One this process would leave to any child that did not close it: dup's copy is not closed by an exec.
	open := posix.dup(2)
	if !testing.expect(t, open >= 0) {
		return
	}
	defer posix.close(open)
	buf: [16]byte
	fd := strconv.write_int(buf[:], i64(open), 10)
	r: Ran
	defer ran_destroy(&r)
	script := strings.concatenate({"if (echo x >&", fd, ") 2>/dev/null; then echo open; else echo closed; fi"}, context.temp_allocator)
	if !testing.expect(t, ran_through(t, &r, {argv = {"sh", "-c", script}})) {
		return
	}
	testing.expect_value(t, string(r.out[:]), "closed\n")
}

@(test)
process_takes_signals_as_they_come :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	// A program whose reader has gone ends by SIGPIPE, quietly; one that inherited it ignored says it failed.
	ignore: posix.sigaction_t
	ignore.sa_handler = auto_cast posix.SIG_IGN
	was: posix.sigaction_t
	posix.sigaction(.SIGPIPE, &ignore, &was)
	defer posix.sigaction(.SIGPIPE, &was, nil)
	r: Ran
	defer ran_destroy(&r)
	if !testing.expect(t, ran_through(t, &r, {argv = {"sh", "-c", "yes | head -c 1 >/dev/null"}})) {
		return
	}
	testing.expect_value(t, string(r.err[:]), "")
	testing.expect_value(t, r.exit, Exit{})
}
