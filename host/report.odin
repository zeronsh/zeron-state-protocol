package host

import "base:runtime"
import "core:strings"

// Speaks to the embedder's logger. core:log would do, but with core:fmt behind it is a fifth of the
// optimised build.
@(private)
report :: proc(level: runtime.Logger_Level, parts: ..string, loc := #caller_location) {
	l := context.logger
	if l.procedure != nil && level >= l.lowest_level {
		l.procedure(l.data, level, strings.concatenate(parts, context.temp_allocator), l.options, loc)
	}
}

// Whether what is said at debug level is heard: so that nothing is put into words for nobody.
@(private)
debugging :: proc() -> bool {
	l := context.logger
	return l.procedure != nil && l.lowest_level <= .Debug
}
