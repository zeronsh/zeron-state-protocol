#+build !windows
package host

import "core:sys/posix"

// What the system says of a connection refused, and of one reset (or written to once reset), as tests of the event
// loop expect to be told.
REFUSED_CODE :: u16(posix.Errno.ECONNREFUSED)
RESET_CODES :: [?]u16{u16(posix.Errno.ECONNRESET), u16(posix.Errno.EPIPE)}
