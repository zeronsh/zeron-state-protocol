// The one way a test here quiets what is said while it runs, and still fails when it fails: ./x check holds every test to
// it (tests/odin_lint.py).
//
// core:testing counts a failure in its test logger: each message of .Error or above that reaches it (test_logger_proc,
// core/testing/logging.odin, `if level >= .Error { t.error_count += 1 }`), and a test with any fails. What a test says
// fails it, testing.expect, expectf, expect_value, fail and fail_now, is said so, through core:log, to context.logger,
// at .Error, at the caller's location (`location = loc`, `loc := #caller_location`): a line of a `_test.odin` file, as
// only those, and this, may import core:testing (./x check), and this says none. A failed assertion, a signal, a
// timeout and memory leaked are counted otherwise, by the runner itself, whatever the logger; though what an assertion
// says, it says at .Fatal, and is heard. So a test that sets context.logger to anything that is not the runner's loses
// every failure it says; and one that passes on only some of what is said loses whatever is not passed on.
//
// The logger quiet gives passes on to the runner's logger, untouched, as core:log would have, every message:
//
// - of .Fatal or above, from anywhere;
// - with .Below_Errors, of .Error or above, from anywhere: so that only what is said below .Error is quieted;
// - with .Code_Under_Test, from a line of a `_test.odin` file, at any level: so that what the code under test says, at
//   any level below .Fatal, is quieted, as when a test makes it fail and what it says of that is meant.
//
// Every failure of a test is a message of .Error from a `_test.odin` file, and so is passed on either way. "Untouched":
// to the runner's own procedure, with its data, its options and the message as given, if its level is one the runner's
// logger takes (its lowest_level), as core:log would have given it; and nothing else reaches the runner. So what the
// runner counts of a test's own is exactly what it would have counted without this. testlog_test.odin holds quiet to
// that, for every level from every kind of place, and ./x selftest that a test quieted so, which fails, fails the run.
package testlog

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:testing"

// What is quieted: see the head of this file.
What :: enum {
	Below_Errors,
	Code_Under_Test,
}

// A quieted test's: kept by it, where it outlasts what it quiets, as its own variable does.
Quiet :: struct {
	runner:    runtime.Logger, // the test runner's, to which what is not quieted is passed on
	what:      What,
	keep:      bool, // whether what is quieted is kept, in said, to be asked of with heard
	said:      [dynamic]string,
	allocator: runtime.Allocator, // of what is kept
	lock:      sync.Mutex, // over said, as the code under test may speak from threads of its own
}

// The logger to run with, quieting what `what` says (see the head of this file):
//
//	q: testlog.Quiet
//	defer testlog.destroy(&q)
//	context.logger = testlog.quiet(t, &q, .Code_Under_Test)
//
// the one way ./x check lets a test set its logger. Within a block, it is quieted only there, as context is the
// block's. What is quieted is kept, if keep, in q's said, until destroy. It must be the test's own logger that is quieted:
// the runner's for t, or one quieted of it, as in a test already quieted; else nothing said would fail it, and the
// test fails at once.
quiet :: proc(t: ^testing.T, q: ^Quiet, what: What, keep := false, loc := #caller_location) -> runtime.Logger {
	runner := context.logger
	if runner.procedure == quiet_proc {
		runner = (^Quiet)(runner.data).runner // quieted again: the runner's is the one to pass on to
	}
	// core:testing's test logger is given the test's T as its data (runner.odin, run_test_task).
	assert(runner.procedure != nil && runner.data == rawptr(t), "a logger that is not the test runner's for this test, as a thread's of its own: nothing said would fail the test", loc)
	return around(q, runner, what, keep)
}

// Lets go of what was kept.
destroy :: proc(q: ^Quiet) {
	for s in q.said {
		delete(s, q.allocator)
	}
	delete(q.said)
	q.said = nil
}

// Whether anything quieted and kept said what.
heard :: proc(q: ^Quiet, what: string) -> bool {
	sync.guard(&q.lock)
	for s in q.said {
		if strings.contains(s, what) {
			return true
		}
	}
	return false
}

// Whether a message said there is passed on by a logger quieting what.
@(private)
passed_on :: proc(what: What, level: runtime.Logger_Level, location: runtime.Source_Code_Location) -> bool {
	if level >= .Fatal {
		return true
	}
	switch what {
	case .Below_Errors:
		return level >= .Error
	case .Code_Under_Test:
		return strings.has_suffix(location.file_path, "_test.odin")
	}
	return true
}

// The logger quieting what of runner's: quiet, for the runner of a test, or testlog_test.odin, for one of its own.
@(private)
around :: proc(q: ^Quiet, runner: runtime.Logger, what: What, keep: bool) -> runtime.Logger {
	q.runner = runner
	q.what = what
	q.keep = keep
	q.allocator = context.allocator
	if q.said == nil {
		q.said.allocator = q.allocator // not the allocator of whoever speaks first, which may be another thread's
	}
	// What core:log is to give it: whatever the runner's would take, and, to be kept, all.
	lowest := runner.lowest_level
	if keep {
		lowest = .Debug
	} else if what == .Below_Errors {
		lowest = max(lowest, .Error)
	}
	return {procedure = quiet_proc, data = q, lowest_level = lowest, options = runner.options}
}

@(private)
quiet_proc :: proc(data: rawptr, level: runtime.Logger_Level, text: string, options: runtime.Logger_Options, location := #caller_location) {
	q := (^Quiet)(data)
	if passed_on(q.what, level, location) {
		if level >= q.runner.lowest_level {
			q.runner.procedure(q.runner.data, level, text, q.runner.options, location)
		}
	} else if q.keep {
		sync.guard(&q.lock)
		append(&q.said, strings.clone(text, q.allocator))
	}
}
