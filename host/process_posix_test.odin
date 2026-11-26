#+build !windows
package host

import "core:c/libc"
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
	// One this process would leave to any child that did not close it: dup's copy is not closed by an exec. Numbered
	// high, above those a shell keeps for itself as it redirects (bash's from 10, and 255), and below any limit.
	open := posix.dup2(2, 900)
	if !testing.expect(t, open == 900) {
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

// Sets, or with nil unsets, a variable of the environment processes are started with: libc's, as process_environment
// reads it. Returns what it was.
@(private)
process_test_env :: proc(name: string, value: Maybe(string)) -> (was: Maybe(string)) {
	n := strings.clone_to_cstring(name, context.temp_allocator)
	if old := libc.getenv(n); old != nil {
		was = strings.clone(string(old), context.temp_allocator)
	}
	if v, ok := value.?; ok {
		posix.setenv(n, strings.clone_to_cstring(v, context.temp_allocator), true)
	} else {
		posix.unsetenv(n)
	}
	return
}

// A terminal is of the kind it is given, whatever this host's own is: the host's TERM is not passed on beside it,
// where whoever reads the first would take the host's.
@(test)
process_terminal_kind_alone :: proc(t: ^testing.T) {
	before := process_test_env("TERM", "dumb")
	defer process_test_env("TERM", before)
	env := process_environment({pty = true, term = "xterm-zsp"})
	terms := make([dynamic]string, context.temp_allocator)
	for i := 0; env[i] != nil; i += 1 {
		if strings.has_prefix(string(env[i]), "TERM=") {
			append(&terms, string(env[i]))
		}
	}
	testing.expectf(t, len(terms) == 1 && terms[0] == "TERM=xterm-zsp", "%v", terms[:])
}

@(private)
review_mkfifo :: proc(path: string) -> bool {
	return posix.mkfifo(strings.clone_to_cstring(path, context.temp_allocator), {.IRUSR, .IWUSR}) == .OK
}

// Opens a FIFO's writing end and lets go: so that whoever waits to open its reading end goes on.
@(private)
review_fifo_poke :: proc(path: string) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .NONBLOCK})
	if fd >= 0 {
		posix.close(fd)
	}
}
