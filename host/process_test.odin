package host

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:time"

// Processes run on the test's own event loop, with what they say kept for the test to look at. The commands are
// the platform's own: sh and its kin on Linux, macOS and FreeBSD, cmd and PowerShell on Windows.

@(private)
Ran :: struct {
	p:         ^Process,
	out:       [dynamic]byte,
	err:       [dynamic]byte,
	exit:      Exit,
	exited:    int, // times told
	rooms:     int,
	biggest:   int, // the most told at once
	pause:     bool, // stops reading at the first output
	paused:    bool,
	late:      int, // told while reading was not wanted
	feed:      []byte, // input to give as room allows, then end
	fed:       int,
	end:       bool, // the input is to be ended once fed
	awaited:   string, // what ran_said waits for
	times:     int, // to have been said so often
}

@(private)
ran_said :: proc(r: ^Ran) -> bool {
	return strings.count(string(r.out[:]), r.awaited) >= r.times
}

@(private)
ran_start :: proc(r: ^Ran, spec: Process_Spec) -> string {
	events := Process_Events {
		data = r,
		on_output = proc(data: rawptr, stream: Output_Stream, bytes: []byte) {
			r := (^Ran)(data)
			r.biggest = max(r.biggest, len(bytes))
			if r.paused {
				r.late += len(bytes)
			}
			append(&r.out if stream == .Stdout else &r.err, ..bytes)
			if r.pause && !r.paused {
				r.paused = true
				process_read(r.p, false)
			}
		},
		on_room = proc(data: rawptr) {
			r := (^Ran)(data)
			r.rooms += 1
			ran_feed(r)
		},
		on_exit = proc(data: rawptr, exit: Exit) {
			r := (^Ran)(data)
			r.exit = exit
			r.exited += 1
		},
	}
	p, err := process_start(spec, events)
	r.p = p
	return err
}

@(private)
ran_feed :: proc(r: ^Ran) {
	for r.fed < len(r.feed) {
		n := process_input(r.p, r.feed[r.fed:])
		if n == 0 {
			return // on_room says when to go on
		}
		r.fed += n
	}
	if r.end {
		r.end = false
		process_end_input(r.p)
	}
}

@(private)
ran_send :: proc(r: ^Ran, text: string) -> bool {
	return process_input(r.p, transmute([]byte)text) == len(text)
}

@(private)
ran_destroy :: proc(r: ^Ran) {
	process_free(r.p)
	delete(r.out)
	delete(r.err)
}

// Turns the loop until `done` says so, or the time is up. Returns whether it was done.
@(private)
ran_until :: proc(r: ^Ran, done: proc(r: ^Ran) -> bool, within := 15 * time.Second) -> bool {
	start := time.tick_now()
	for !done(r) {
		if time.tick_since(start) >= within {
			return false
		}
		if nbio.tick(50 * time.Millisecond) != nil {
			return false
		}
	}
	return true
}

@(private)
ran_exited :: proc(r: ^Ran) -> bool {
	return r.exited > 0
}

// Runs a process to its end, with nothing for its stdin. Returns whether it ended in time.
@(private)
ran_through :: proc(t: ^testing.T, r: ^Ran, spec: Process_Spec) -> bool {
	if err := ran_start(r, spec); err != "" {
		testing.expectf(t, false, "could not start %v: %v", spec.argv, err)
		return false
	}
	process_end_input(r.p)
	return ran_until(r, ran_exited)
}

// The event loop, made as the host makes it.
@(private)
process_loop :: proc() -> bool {
	for tries := 0; !ring_free() && tries < 40; tries += 1 {
		time.sleep(50 * time.Millisecond)
	}
	return nbio.acquire_thread_event_loop() == nil
}

@(test)
process_runs_a_program :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	r: Ran
	defer ran_destroy(&r)
	when ODIN_OS == .Windows {
		argv := []string{"cmd", "/c", "echo hello"}
		want := "hello\r\n"
	} else {
		argv := []string{"echo", "hello"}
		want := "hello\n"
	}
	if !testing.expect(t, ran_through(t, &r, {argv = argv})) {
		return
	}
	testing.expect_value(t, string(r.out[:]), want)
	testing.expect_value(t, len(r.err), 0)
	testing.expect_value(t, r.exit, Exit{})
	// Told once, and only once: more turns of the loop tell nothing more.
	for _ in 0 ..< 3 {
		nbio.tick(10 * time.Millisecond)
	}
	testing.expect_value(t, r.exited, 1)
}

@(test)
process_says_its_exit_code :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	r: Ran
	defer ran_destroy(&r)
	when ODIN_OS == .Windows {
		argv := []string{"cmd", "/c", "exit 7"}
	} else {
		argv := []string{"sh", "-c", "exit 7"}
	}
	if !testing.expect(t, ran_through(t, &r, {argv = argv})) {
		return
	}
	testing.expect_value(t, r.exit, Exit{code = 7})
}

@(test)
process_keeps_stderr_apart :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	r: Ran
	defer ran_destroy(&r)
	when ODIN_OS == .Windows {
		argv := []string{"cmd", "/c", "echo out& echo err>&2"}
		out, err := "out\r\n", "err\r\n"
	} else {
		argv := []string{"sh", "-c", "echo out; echo err >&2"}
		out, err := "out\n", "err\n"
	}
	if !testing.expect(t, ran_through(t, &r, {argv = argv})) {
		return
	}
	testing.expect_value(t, string(r.out[:]), out)
	testing.expect_value(t, string(r.err[:]), err)
}

// More input than may be held at once, given as room comes, comes back as it went in, and the end of it ends the
// program reading it.
@(test)
process_passes_input_through :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	SIZE :: 5 << 20
	input := make([]byte, SIZE)
	defer delete(input)
	when ODIN_OS == .Windows {
		// findstr gives back every line it is given; lines are what it takes.
		argv := []string{"findstr", "^"}
		line := "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ\r\n"
		for i in 0 ..< SIZE {
			input[i] = line[i % len(line)]
		}
		input[SIZE - 2], input[SIZE - 1] = '\r', '\n'
	} else {
		argv := []string{"cat"}
		x := u32(1)
		for &b in input {
			x = x * 1103515245 + 12345
			b = byte(x >> 23)
		}
	}
	r: Ran
	defer ran_destroy(&r)
	if err := ran_start(&r, {argv = argv}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	r.feed, r.end = input, true
	ran_feed(&r)
	testing.expect(t, r.fed <= PROCESS_INPUT + 64 << 10, "more taken at once than may be held, and than a pipe holds")
	if !testing.expect(t, ran_until(&r, ran_exited, 60 * time.Second)) {
		return
	}
	testing.expect_value(t, r.fed, SIZE)
	testing.expect(t, r.rooms > 0, "on_room never said there was room")
	testing.expect_value(t, len(r.out), SIZE)
	testing.expect(t, string(r.out[:]) == string(input), "what came back is not what went in")
	testing.expect_value(t, r.exit, Exit{})
	testing.expect(t, r.biggest <= PROCESS_READ, "more told at once than is read at once")
}

@(test)
process_says_why_it_cannot_start :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	base, _ := os.temp_directory(context.temp_allocator)
	root, merr := os.make_directory_temp(base, "zsp-process-*", context.allocator)
	if !testing.expect(t, merr == nil) {
		return
	}
	defer {
		os.remove_all(root)
		delete(root)
	}
	plain, _ := filepath.join({root, "plain.txt"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(plain, transmute([]byte)string("not a program\n")) == nil)
	nowhere, _ := filepath.join({root, "nowhere"}, context.temp_allocator)
	missing, _ := filepath.join({root, "missing"}, context.temp_allocator)
	when ODIN_OS == .Windows {
		here := []string{"cmd", "/c", "exit 0"}
		cases := []struct {
			spec: Process_Spec,
			err:  string,
		} {
			{{argv = {"zsp-no-such-program"}}, "no such program: zsp-no-such-program"},
			{{argv = {missing}}, strings.concatenate({"no such program: ", missing}, context.temp_allocator)},
			{{argv = {plain}}, strings.concatenate({"not a program: ", plain}, context.temp_allocator)},
			{{argv = here, dir = nowhere}, strings.concatenate({"no such directory: ", nowhere}, context.temp_allocator)},
		}
	} else {
		here := []string{"true"}
		cases := []struct {
			spec: Process_Spec,
			err:  string,
		} {
			{{argv = {"zsp-no-such-program"}}, "no such program: zsp-no-such-program"},
			// Found by the child's exec, which says why not through the pipe the exec would have closed.
			{{argv = {missing}}, strings.concatenate({"no such program: ", missing}, context.temp_allocator)},
			{{argv = {plain}}, strings.concatenate({"permission denied: ", plain}, context.temp_allocator)},
			{{argv = here, dir = nowhere}, strings.concatenate({"no such directory: ", nowhere}, context.temp_allocator)},
		}
	}
	for c in cases {
		r: Ran
		err := ran_start(&r, c.spec)
		testing.expect_value(t, err, c.err)
		testing.expect(t, r.p == nil)
		ran_destroy(&r)
	}
	// And what does start still does.
	r: Ran
	defer ran_destroy(&r)
	testing.expect(t, ran_through(t, &r, {argv = here}))
	testing.expect_value(t, r.exit, Exit{})
}

@(test)
process_starts_where_and_as_it_is_told :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	base, _ := os.temp_directory(context.temp_allocator)
	root, merr := os.make_directory_temp(base, "zsp-process-*", context.allocator)
	if !testing.expect(t, merr == nil) {
		return
	}
	defer {
		os.remove_all(root)
		delete(root)
	}
	// The variable it is told to go without is one every host has.
	when ODIN_OS == .Windows {
		argv := []string{"cmd", "/c", "cd& echo %ZSP_X% %USERNAME%"}
		gone := "USERNAME"
		home_var := "USERPROFILE"
		here := []string{"cmd", "/c", "cd"}
	} else {
		argv := []string{"sh", "-c", "pwd -P; echo \"$ZSP_X ${HOME-unset}\""}
		gone := "HOME"
		home_var := "HOME"
		here := []string{"pwd", "-P"}
	}
	r: Ran
	defer ran_destroy(&r)
	if !testing.expect(t, ran_through(t, &r, {argv = argv, dir = root, env = {"ZSP_X=wrong", "ZSP_X=hello", gone}})) {
		return
	}
	lines := strings.split_lines(strings.trim_space(string(r.out[:])), context.temp_allocator)
	if !testing.expect_value(t, len(lines), 2) {
		return
	}
	testing.expect_value(t, process_test_path(lines[0]), process_test_path(process_test_real(t, root)))
	when ODIN_OS == .Windows {
		testing.expect_value(t, strings.trim_space(lines[1]), "hello %USERNAME%")
	} else {
		testing.expect_value(t, lines[1], "hello unset")
	}
	// No directory is the user's home.
	home: Ran
	defer ran_destroy(&home)
	if !testing.expect(t, ran_through(t, &home, {argv = here})) {
		return
	}
	want := process_test_real(t, os.get_env(home_var, context.temp_allocator))
	testing.expect_value(t, process_test_path(strings.trim_space(string(home.out[:]))), process_test_path(want))
}

// Where a directory really is, as the platform's own shell says, links and all followed.
@(private)
process_test_real :: proc(t: ^testing.T, dir: string) -> string {
	when ODIN_OS == .Windows {
		argv := []string{"cmd", "/c", "cd"}
	} else {
		argv := []string{"pwd", "-P"}
	}
	r: Ran
	defer ran_destroy(&r)
	if !ran_through(t, &r, {argv = argv, dir = dir}) {
		return ""
	}
	return strings.clone(strings.trim_space(string(r.out[:])), context.temp_allocator)
}

// A path as compared: Windows' are the same in any case.
@(private)
process_test_path :: proc(path: string) -> string {
	when ODIN_OS == .Windows {
		return strings.to_lower(path, context.temp_allocator)
	} else {
		return path
	}
}

@(test)
process_takes_a_signal :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	when ODIN_OS == .Windows {
		argv := []string{"ping", "-n", "100", "127.0.0.1"}
		want := Exit{code = 128 + 15} // the job ended with the code a shell gives the signal
	} else {
		argv := []string{"sleep", "100"}
		want := Exit{code = 128 + 15, signal = 15}
	}
	r: Ran
	defer ran_destroy(&r)
	if err := ran_start(&r, {argv = argv}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	testing.expect(t, !ran_until(&r, ran_exited, 300 * time.Millisecond), "ended before it was told to")
	process_signal(r.p, .Terminate)
	if !testing.expect(t, ran_until(&r, ran_exited)) {
		return
	}
	testing.expect_value(t, r.exit, want)
}

// Letting go of a process that still runs ends what it started too.
@(test)
process_free_ends_its_group :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	when ODIN_OS == .Windows {
		argv := []string{"powershell", "-NoProfile", "-Command", "$c = Start-Process -NoNewWindow -PassThru ping -ArgumentList '-n','100','127.0.0.1'; $c.Id; Wait-Process -Id $c.Id"}
	} else {
		argv := []string{"sh", "-c", "sleep 100 & echo $!; wait"}
	}
	r: Ran
	defer ran_destroy(&r)
	if err := ran_start(&r, {argv = argv}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	if !testing.expect(t, ran_until(&r, proc(r: ^Ran) -> bool {
		return strings.index_byte(string(r.out[:]), '\n') >= 0
	})) {
		return
	}
	first := strings.trim_space(string(r.out[:strings.index_byte(string(r.out[:]), '\n')]))
	child, ok := strconv.parse_int(first)
	if !testing.expectf(t, ok, "no process id in %q", first) {
		return
	}
	if !testing.expect(t, process_test_alive(t, child), "what it started is not running to begin with") {
		return
	}
	process_free(r.p)
	r.p = nil
	start := time.tick_now()
	for process_test_alive(t, child) && time.tick_since(start) < 10 * time.Second {
		nbio.tick(50 * time.Millisecond)
	}
	testing.expect(t, !process_test_alive(t, child), "what it started outlived it")
	testing.expect_value(t, r.exited, 0) // and nothing more is told
}

// Whether a process runs, as the platform's own tools say: one that has ended but is not yet reaped does not.
@(private)
process_test_alive :: proc(t: ^testing.T, pid: int) -> bool {
	buf: [32]byte
	id := strconv.write_int(buf[:], i64(pid), 10)
	when ODIN_OS == .Windows {
		argv := []string{"tasklist", "/NH", "/FI", strings.concatenate({"PID eq ", id}, context.temp_allocator)}
	} else {
		argv := []string{"ps", "-o", "stat=", "-p", id}
	}
	r: Ran
	defer ran_destroy(&r)
	if !ran_through(t, &r, {argv = argv}) {
		return true
	}
	said := strings.trim_space(string(r.out[:]))
	when ODIN_OS == .Windows {
		return strings.contains(said, id)
	} else {
		return said != "" && said[0] != 'Z'
	}
}

// Nothing is read while reading is not wanted, so a program that has more to say waits; once it is, all of it comes.
@(test)
process_reads_only_when_wanted :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	SIZE :: 1 << 20 // more than a pipe and a read hold together
	when ODIN_OS == .Windows {
		argv := []string{"powershell", "-NoProfile", "-Command", "$o = [Console]::OpenStandardOutput(); $b = New-Object byte[] 1048576; $o.Write($b, 0, $b.Length); $o.Flush()"}
	} else {
		argv := []string{"head", "-c", "1048576", "/dev/zero"}
	}
	for from_start in ([]bool{true, false}) {
		r: Ran
		defer ran_destroy(&r)
		r.pause = !from_start
		if err := ran_start(&r, {argv = argv}); err != "" {
			testing.expectf(t, false, "could not start: %v", err)
			return
		}
		process_end_input(r.p)
		if from_start {
			process_read(r.p, false)
			r.paused = true
		} else {
			if !testing.expect(t, ran_until(&r, proc(r: ^Ran) -> bool {
				return r.paused
			})) {
				return
			}
		}
		told := len(r.out)
		ran_until(&r, proc(r: ^Ran) -> bool {
			return r.late > 0 || r.exited > 0
		}, 1500 * time.Millisecond)
		testing.expect_value(t, r.late, 0)
		testing.expect_value(t, len(r.out), told)
		testing.expect(t, r.exited == 0, "it ended without all it said having been read")
		r.pause, r.paused = false, false
		process_read(r.p, true)
		if !testing.expect(t, ran_until(&r, ran_exited)) {
			return
		}
		testing.expect_value(t, len(r.out), SIZE)
		testing.expect_value(t, r.exit, Exit{})
		testing.expect(t, r.biggest <= PROCESS_READ, "more told at once than is read at once")
	}
}

// A terminal of its own, of the size and kind it was given, and of the size it is changed to.
@(test)
process_has_a_terminal :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	when ODIN_OS == .Windows {
		argv := []string{"cmd"}
		enter := "\r"
		size := "mode con"
		term := "set TERM"
	} else {
		argv := []string{"sh"}
		enter := "\n"
		size := "stty size"
		term := "env | grep ^TERM="
	}
	// Whatever kind of terminal this host's own is (as under a shell, which says), the one made is of the kind given.
	when ODIN_OS == .Windows {
		was, had := os.lookup_env("TERM", context.temp_allocator)
		os.set_env("TERM", "dumb")
		defer if had {
			os.set_env("TERM", was)
		} else {
			os.unset_env("TERM")
		}
	} else {
		before := process_test_env("TERM", "dumb")
		defer process_test_env("TERM", before)
	}
	r: Ran
	defer ran_destroy(&r)
	if err := ran_start(&r, {argv = argv, pty = true, rows = 33, cols = 101, term = "xterm-zsp"}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	testing.expect(t, ran_send(&r, strings.concatenate({size, enter}, context.temp_allocator)))
	if !testing.expect(t, ran_until(&r, proc(r: ^Ran) -> bool {
		return process_test_size(r, 33, 101)
	}), "not the size it was given") {
		return
	}
	clear(&r.out)
	process_resize(r.p, 40, 120)
	testing.expect(t, ran_send(&r, strings.concatenate({size, enter}, context.temp_allocator)))
	if !testing.expect(t, ran_until(&r, proc(r: ^Ran) -> bool {
		return process_test_size(r, 40, 120)
	}), "not the size it was changed to") {
		return
	}
	clear(&r.out)
	testing.expect(t, ran_send(&r, strings.concatenate({term, enter}, context.temp_allocator)))
	if !testing.expect(t, ran_until(&r, proc(r: ^Ran) -> bool {
		return strings.contains(process_test_screen(r), "TERM=xterm-zsp")
	}), "not of the kind it was given") {
		return
	}
	testing.expectf(t, !strings.contains(process_test_screen(&r), "TERM=dumb"), "of this host's kind too: %q", process_test_screen(&r))
	testing.expect(t, ran_send(&r, strings.concatenate({"exit 3", enter}, context.temp_allocator)))
	if !testing.expect(t, ran_until(&r, ran_exited)) {
		return
	}
	testing.expect_value(t, r.exit.code, 3)
	testing.expect_value(t, len(r.err), 0)
}

// What a terminal showed, without its escape sequences and spaces, which ConPTY draws as it likes.
@(private)
process_test_screen :: proc(r: ^Ran) -> string {
	text := make([dynamic]byte, 0, len(r.out), context.temp_allocator)
	for i := 0; i < len(r.out); i += 1 {
		b := r.out[i]
		switch {
		case b == 0x1b && i + 1 < len(r.out) && r.out[i + 1] == '[':
			i += 2
			for i < len(r.out) && (r.out[i] < 0x40 || r.out[i] > 0x7e) {
				i += 1
			}
		case b == 0x1b && i + 1 < len(r.out) && r.out[i + 1] == ']':
			for i < len(r.out) && r.out[i] != 0x07 {
				i += 1
			}
		case b == ' ' || b == '\t':
		case:
			append(&text, b)
		}
	}
	return string(text[:])
}

@(private)
process_test_size :: proc(r: ^Ran, rows, cols: int) -> bool {
	buf: [2][8]byte
	row := strconv.write_int(buf[0][:], i64(rows), 10)
	col := strconv.write_int(buf[1][:], i64(cols), 10)
	screen := process_test_screen(r)
	when ODIN_OS == .Windows {
		return strings.contains(screen, strings.concatenate({"Lines:", row, "\r\n"}, context.temp_allocator)) && strings.contains(screen, strings.concatenate({"Columns:", col, "\r\n"}, context.temp_allocator))
	} else {
		return strings.contains(screen, strings.concatenate({row, col, "\r\n"}, context.temp_allocator))
	}
}

// No program is the user's login shell, which takes commands from its stdin, and with a terminal is told it is a
// login shell by the dash before its name.
@(test)
process_runs_the_login_shell :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	r: Ran
	defer ran_destroy(&r)
	if err := ran_start(&r, {}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	when ODIN_OS == .Windows {
		r.feed = transmute([]byte)string("echo zsp-login\r\nexit 4\r\n")
	} else {
		r.feed = transmute([]byte)string("echo zsp-login; exit 4\n")
	}
	r.end = true
	ran_feed(&r)
	if !testing.expect(t, ran_until(&r, ran_exited)) {
		return
	}
	testing.expect(t, strings.contains(string(r.out[:]), "zsp-login"))
	testing.expect_value(t, r.exit.code, 4)
	when ODIN_OS != .Windows {
		login: Ran
		defer ran_destroy(&login)
		if err := ran_start(&login, {pty = true}); err != "" {
			testing.expectf(t, false, "could not start: %v", err)
			return
		}
		buf: [32]byte
		ps: Ran
		defer ran_destroy(&ps)
		if !testing.expect(t, ran_through(t, &ps, {argv = {"ps", "-o", "args=", "-p", strconv.write_int(buf[:], i64(login.p.pid), 10)}})) {
			return
		}
		testing.expectf(t, strings.has_prefix(strings.trim_space(string(ps.out[:])), "-"), "not told it is a login shell: %q", string(ps.out[:]))
		testing.expect(t, ran_send(&login, "exit 5\n"))
		if !testing.expect(t, ran_until(&login, ran_exited)) {
			return
		}
		testing.expect_value(t, login.exit.code, 5)
	}
}

// Input for a program that has gone is turned away, and costs this process nothing: not the SIGPIPE a pipe without a
// reader raises, which would end it.
@(test)
process_input_after_its_end :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	when ODIN_OS == .Windows {
		argv := []string{"cmd", "/c", "exit 0"}
	} else {
		argv := []string{"true"}
	}
	r: Ran
	defer ran_destroy(&r)
	if err := ran_start(&r, {argv = argv}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	if !testing.expect(t, ran_until(&r, ran_exited)) {
		return
	}
	turned_away := false
	start := time.tick_now()
	for !turned_away && time.tick_since(start) < 5 * time.Second {
		turned_away = !ran_send(&r, "for nobody\n")
		nbio.tick(10 * time.Millisecond)
	}
	testing.expect(t, turned_away, "input was taken for a program that has gone")
	testing.expect_value(t, process_input_room(r.p), 0)
}

// Ctrl-C reaches what runs in a terminal's foreground, as it would from a keyboard, and not the shell that ran it.
@(test)
process_interrupts_a_terminal :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	r: Ran
	defer ran_destroy(&r)
	when ODIN_OS == .Windows {
		argv := []string{"cmd"}
		run := "ping -n 100 127.0.0.1\r"
		exit := "exit 6\r"
		r.awaited, r.times = "127.0.0.1", 2 // as typed, and as ping says it
	} else {
		argv := []string{"sh"}
		run := "echo zsp-sleeping; sleep 100\n"
		exit := "exit 6\n"
		r.awaited, r.times = "zsp-sleeping\r\n", 1 // as said, not as typed
	}
	if err := ran_start(&r, {argv = argv, pty = true, rows = 24, cols = 80}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	testing.expect(t, ran_send(&r, run))
	if !testing.expect(t, ran_until(&r, ran_said)) {
		return
	}
	ran_until(&r, ran_exited, 500 * time.Millisecond) // for it to be well under way
	process_signal(r.p, .Interrupt)
	testing.expect(t, ran_send(&r, exit))
	if !testing.expect(t, ran_until(&r, ran_exited)) {
		fmt.eprintfln("TERMINAL SAID: %q", string(r.out[max(len(r.out) - 1500, 0):]))
		return
	}
	testing.expect_value(t, r.exit.code, 6)
}

// A stopped program takes nothing in and says nothing until it goes on.
@(test)
process_stops_and_goes_on :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	when ODIN_OS == .Windows {
		// cmd says each echo at once; findstr, writing to a pipe, holds back until its input ends.
		argv := []string{"cmd", "/d", "/q"}
		line := "echo zsp-line\r\n"
	} else {
		argv := []string{"cat"}
		line := "zsp-line\n"
	}
	r: Ran
	defer ran_destroy(&r)
	if err := ran_start(&r, {argv = argv}); err != "" {
		testing.expectf(t, false, "could not start: %v", err)
		return
	}
	process_signal(r.p, .Stop)
	testing.expect(t, ran_send(&r, line))
	ran_until(&r, proc(r: ^Ran) -> bool {
		return len(r.out) > 0
	}, 700 * time.Millisecond)
	testing.expect_value(t, len(r.out), 0)
	process_signal(r.p, .Continue)
	testing.expect(t, ran_until(&r, proc(r: ^Ran) -> bool {
		return len(r.out) > 0
	}))
	process_end_input(r.p)
	if !testing.expect(t, ran_until(&r, ran_exited)) {
		return
	}
	when ODIN_OS == .Windows {
		testing.expectf(t, strings.contains(string(r.out[:]), "zsp-line\r\n"), "%q", string(r.out[:]))
	} else {
		testing.expect_value(t, string(r.out[:]), line)
	}
	testing.expect_value(t, r.exit, Exit{})
}

// Let go of while it tells its owner something: freed once that is over, and nothing more is told.
@(test)
process_free_while_telling :: proc(t: ^testing.T) {
	if !testing.expect(t, process_loop()) {
		return
	}
	defer nbio.release_thread_event_loop()
	when ODIN_OS == .Windows {
		argv := []string{"cmd", "/c", "echo first& ping -n 100 127.0.0.1"}
	} else {
		argv := []string{"sh", "-c", "echo first; exec sleep 100"}
	}
	Freeing :: struct {
		p:     ^Process,
		told:  int,
		ended: int,
	}
	f: Freeing
	events := Process_Events {
		data = &f,
		on_output = proc(data: rawptr, stream: Output_Stream, bytes: []byte) {
			f := (^Freeing)(data)
			f.told += 1
			process_free(f.p)
			process_free(f.p) // and once more, which is nothing
		},
		on_exit = proc(data: rawptr, exit: Exit) {
			(^Freeing)(data).ended += 1
		},
	}
	p, err := process_start({argv = argv}, events)
	if !testing.expectf(t, err == "", "could not start: %v", err) {
		return
	}
	f.p = p
	start := time.tick_now()
	for f.told == 0 && time.tick_since(start) < 10 * time.Second {
		nbio.tick(50 * time.Millisecond)
	}
	testing.expect_value(t, f.told, 1)
	for _ in 0 ..< 10 {
		nbio.tick(20 * time.Millisecond)
	}
	testing.expect_value(t, f.told, 1)
	testing.expect_value(t, f.ended, 0)
}
