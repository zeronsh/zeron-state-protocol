#+build !windows
package host

import "core:os"

// A link at `link` to `target`, for a test: whether it could be made.
@(private)
link_for_test :: proc(target, link: string) -> bool {
	return os.symlink(target, link) == nil
}
