#+build !js
package zsp

import "core:os"
import "core:testing"

// Fails when ZSP_FAIL is set, as `./x selftest` sets it: to see that ./x test says an Odin test failed.
@(test)
runner_says_what_fails :: proc(t: ^testing.T) {
	testing.expect(t, os.get_env("ZSP_FAIL", context.temp_allocator) == "", "failing, as ZSP_FAIL asks")
}
