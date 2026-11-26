#+build !windows
package main

import "core:sys/posix"

linux_getuid :: proc() -> u32 {
	return u32(posix.getuid())
}

darwin_getuid :: linux_getuid
