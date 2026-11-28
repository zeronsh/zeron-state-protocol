// What the code under test says, as testlog's own tests have it said: from a line of this file, which is not a test's,
// so that they need make no location of their own, which ./x check lets no test do.
package said

import "base:runtime"
import "core:log"

// Says text at .Error, as the code under test says what it means to.
error :: proc(text: string) {
	log.error(text)
}

// Gives l text at level as core:log would (core/log/log.odin, log), from here: and where from, the file and the line.
to :: proc(l: runtime.Logger, level: runtime.Logger_Level, text: string) -> (file: string, line: i32) {
	at := #location()
	if l.procedure != nil && l.procedure != log.nil_logger_proc && level >= l.lowest_level {
		l.procedure(l.data, level, text, l.options, at)
	}
	return at.file_path, at.line
}
