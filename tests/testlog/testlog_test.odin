package testlog

import "base:runtime"
import "core:log"
import "core:os"
import "core:testing"
import "core:thread"

// A runner's logger of the test's own: what reached it, as it reached it.
@(private = "file")
Reached :: struct {
	count:    int,
	level:    runtime.Logger_Level,
	text:     string,
	options:  runtime.Logger_Options,
	location: runtime.Source_Code_Location,
	data:     rawptr,
}

@(private = "file")
reached_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	r := (^Reached)(data)
	r.count += 1
	r.level, r.text, r.options, r.location, r.data = level, text, options, location, data
}

// What core:log does with a message given a logger (core/log/log.odin, log and logf), without the formatting.
@(private = "file")
say :: proc(l: runtime.Logger, level: runtime.Logger_Level, text: string, location: runtime.Source_Code_Location) {
	if l.procedure == nil || l.procedure == log.nil_logger_proc || level < l.lowest_level {
		return
	}
	l.procedure(l.data, level, text, l.options, location)
}

// For every level, from every kind of place, whatever the runner's logger takes, quieting either way and keeping or not:
// what reaches the runner is exactly what quiet's head says; and of a `_test.odin` file's errors, which are what fail a
// test, exactly what would have without it, untouched.
@(test)
quiet_passes_on_exactly_what_it_says :: proc(t: ^testing.T) {
	places := []string{"zsp/zsp_test.odin", `C:\a\host\stop_test.odin`, "host/host.odin", "core/testing/testing.odin", "a_test.odin.bak", ""}
	options := runtime.Logger_Options{.Level, .Line}
	for what in What {
		for keep in ([]bool{false, true}) {
			for lowest in runtime.Logger_Level {
				for level in runtime.Logger_Level {
					for place in places {
						r: Reached
						q: Quiet
						runner := runtime.Logger{procedure = reached_proc, data = &r, lowest_level = lowest, options = options}
						l := around(&q, runner, what, keep)
						at := runtime.Source_Code_Location{file_path = place, line = 7, column = 3, procedure = "p"}
						say(l, level, "said", at)
						from_test := len(place) > len("_test.odin") && place[len(place) - len("_test.odin"):] == "_test.odin"
						passes := level >= .Fatal || (level >= .Error if what == .Below_Errors else from_test)
						want := passes && level >= lowest
						testing.expectf(t, (r.count == 1) == want && r.count <= 1, "%v keep=%v, runner at %v: %v from %q reached it %d times", what, keep, lowest, level, place, r.count)
						if from_test && level >= .Error {
							// As without quiet: core:log gives the runner what it takes, and nothing else.
							testing.expectf(t, (r.count == 1) == (level >= lowest), "%v keep=%v: the test's own %v not passed on as without quiet, the runner at %v", what, keep, level, lowest)
						}
						if r.count == 1 {
							testing.expectf(t, r.data == &r && r.level == level && r.text == "said" && r.options == options && r.location == at, "%v: not passed on untouched: %v", what, r)
						}
						kept := len(q.said) == 1 && q.said[0] == "said"
						testing.expectf(t, kept == (keep && !passes) && len(q.said) <= 1, "%v keep=%v: %v from %q kept %d times", what, keep, level, place, len(q.said))
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
	log.error("meant", location = runtime.Source_Code_Location{file_path = "host/host.odin", line = 1, procedure = "said"})
	testing.expect(t, heard(&q, "meant"), "what the code under test said is not kept")
	testing.expect(t, os.get_env("ZSP_FAIL", context.temp_allocator) == "", "failing, as ZSP_FAIL asks, quieted of the code under test")
}

@(test)
quieted_in_a_thread_still_fails :: proc(t: ^testing.T) {
	q: Quiet
	context.logger = quiet(t, &q, .Code_Under_Test)
	th := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) {
		log.error("meant", location = runtime.Source_Code_Location{file_path = "host/host.odin", line = 1, procedure = "said"})
		testing.expect(t, os.get_env("ZSP_FAIL", context.temp_allocator) == "", "failing, as ZSP_FAIL asks, quieted in a thread")
	}, init_context = context)
	thread.join(th)
	thread.destroy(th)
}
