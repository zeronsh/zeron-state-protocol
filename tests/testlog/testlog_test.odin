package testlog

import "base:runtime"
import "core:log"
import "core:os"
import "core:testing"
import "core:thread"
import "said"

// A runner's logger of the test's own: what reached it, as it reached it.
@(private = "file")
Reached :: struct {
	count:   int,
	level:   runtime.Logger_Level,
	text:    string,
	options: runtime.Logger_Options,
	file:    string,
	line:    i32,
	data:    rawptr,
}

@(private = "file")
reached_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	r := (^Reached)(data)
	r.count += 1
	r.level, r.text, r.options, r.file, r.line, r.data = level, text, options, location.file_path, location.line, data
}

// Gives l text at level as core:log would (core/log/log.odin, log), from here, a line of a `_test.odin` file: and where
// from. said.to does the same from a line of a file that is not a test's.
@(private = "file")
say :: proc(l: runtime.Logger, level: runtime.Logger_Level, text: string) -> (file: string, line: i32) {
	at := #location()
	if l.procedure != nil && l.procedure != log.nil_logger_proc && level >= l.lowest_level {
		l.procedure(l.data, level, text, l.options, at)
	}
	return at.file_path, at.line
}

// Of every kind of file a message may be said from, whether quiet takes it for a test's: only one whose name ends
// `_test.odin`, whatever its directory and on whatever system.
@(test)
quiet_knows_a_tests_file :: proc(t: ^testing.T) {
	Place :: struct {
		path: string,
		test: bool,
	}
	places := []Place {
		{"zsp/zsp_test.odin", true},
		{`C:\a\host\stop_test.odin`, true},
		{"/home/a/host/files_posix_test.odin", true},
		{"_test.odin", true},
		{"host/host.odin", false},
		{"core/testing/testing.odin", false},
		{"a_test.odin.bak", false},
		{"a_test.odin/b.odin", false},
		{"a_tests.odin", false},
		{"", false},
	}
	for p in places {
		for level in runtime.Logger_Level {
			testing.expectf(t, passed_on(.Code_Under_Test, level, p.path) == (p.test || level >= .Fatal), "%v from %q", level, p.path)
			testing.expectf(t, passed_on(.Below_Errors, level, p.path) == (level >= .Error), "%v from %q", level, p.path)
		}
	}
}

// For every level, from a test's file and from another's, whatever the runner's logger takes, quieting either way and
// keeping or not: what reaches the runner is exactly what quiet's head says; and of a `_test.odin` file's errors, which
// are what fail a test, exactly what would have without it, untouched.
@(test)
quiet_passes_on_exactly_what_it_says :: proc(t: ^testing.T) {
	options := runtime.Logger_Options{.Level, .Line}
	for what in What {
		for keep in ([]bool{false, true}) {
			for lowest in runtime.Logger_Level {
				for level in runtime.Logger_Level {
					for from_test in ([]bool{true, false}) {
						r: Reached
						q: Quiet
						runner := runtime.Logger{procedure = reached_proc, data = &r, lowest_level = lowest, options = options}
						l := around(&q, runner, what, keep)
						file: string
						line: i32
						if from_test {
							file, line = say(l, level, "said")
						} else {
							file, line = said.to(l, level, "said")
						}
						testing.expect(t, passed_on(.Code_Under_Test, .Error, file) == from_test, "said from the wrong kind of file")
						passes := level >= .Fatal || (level >= .Error if what == .Below_Errors else from_test)
						want := passes && level >= lowest
						testing.expectf(t, (r.count == 1) == want && r.count <= 1, "%v keep=%v, runner at %v: %v from %q reached it %d times", what, keep, lowest, level, file, r.count)
						if from_test && level >= .Error {
							// As without quiet: core:log gives the runner what it takes, and nothing else.
							testing.expectf(t, (r.count == 1) == (level >= lowest), "%v keep=%v: the test's own %v not passed on as without quiet, the runner at %v", what, keep, level, lowest)
						}
						if r.count == 1 {
							testing.expectf(t, r.data == &r && r.level == level && r.text == "said" && r.options == options && r.file == file && r.line == line, "%v: not passed on untouched: %v", what, r)
						}
						kept := len(q.said) == 1 && q.said[0] == "said"
						testing.expectf(t, kept == (keep && !passes) && len(q.said) <= 1, "%v keep=%v: %v from %q kept %d times", what, keep, level, file, len(q.said))
						testing.expect(t, heard(&q, "sa") == kept)
						destroy(&q)
					}
				}
			}
		}
	}
}

// A logger that is not the test runner's for the test is refused: nothing said to it would fail the test.
@(test)
quiet_refuses_another_tests_logger :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, "a logger that is not the test runner's for this test, as a thread's of its own: nothing said would fail the test")
	other: testing.T
	q: Quiet
	_ = quiet(&other, &q, .Below_Errors)
}

// Quieted again, the runner's is still the one passed on to.
@(test)
quiet_again_passes_on_to_the_runner :: proc(t: ^testing.T) {
	runner := context.logger
	q: Quiet
	context.logger = quiet(t, &q, .Below_Errors)
	{
		again: Quiet
		context.logger = quiet(t, &again, .Code_Under_Test)
		testing.expect(t, again.runner == runner, "quieted again, what is passed on goes through the first quieting")
	}
	testing.expect(t, q.runner == runner)
}

// Each fails when ZSP_FAIL is set, as `./x selftest` sets it, quieted as much as it can be: so that ./x selftest sees
// that a failure said in a test quieted either way, in it or in a thread it runs with its context, fails the run.
@(test)
quieted_below_errors_still_fails :: proc(t: ^testing.T) {
	q: Quiet
	context.logger = quiet(t, &q, .Below_Errors)
	log.warn("quieted")
	testing.expect(t, os.get_env("ZSP_FAIL", context.temp_allocator) == "", "failing, as ZSP_FAIL asks, quieted below errors")
}

@(test)
quieted_code_under_test_still_fails :: proc(t: ^testing.T) {
	q: Quiet
	defer destroy(&q)
	context.logger = quiet(t, &q, .Code_Under_Test, keep = true)
	// What the code under test says, at .Error, which would fail the test unquieted: it does not, as ./x test sees.
	said.error("meant")
	testing.expect(t, heard(&q, "meant"), "what the code under test said is not kept")
	testing.expect(t, os.get_env("ZSP_FAIL", context.temp_allocator) == "", "failing, as ZSP_FAIL asks, quieted of the code under test")
}

@(test)
quieted_in_a_thread_still_fails :: proc(t: ^testing.T) {
	q: Quiet
	context.logger = quiet(t, &q, .Code_Under_Test)
	th := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) {
		said.error("meant")
		testing.expect(t, os.get_env("ZSP_FAIL", context.temp_allocator) == "", "failing, as ZSP_FAIL asks, quieted in a thread")
	}, init_context = context)
	thread.join(th)
	thread.destroy(th)
}
