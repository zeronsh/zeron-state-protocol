#+build !windows
#+build !freebsd
package host

import "core:testing"

// Nothing to hold the host's interfaces to here: core:net lists none on Linux, and on macOS and the BSDs gathers them
// with map_entry (odin-lang/Odin#8642).
@(private)
also_listed_by_core :: proc(_: ^testing.T, _: []Interface) {}
