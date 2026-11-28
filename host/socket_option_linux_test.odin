#+build linux
package host

import "core:os"
import "core:strconv"
import "core:strings"
import "../third_party/nbio"

// What Linux grants a buffer asked for: twice the size asked (for its own bookkeeping), within twice net.core.rmem_max
// or wmem_max (socket(7)).
@(private)
granted :: proc(option: nbio.Socket_Option, asked: int) -> int {
	path := "/proc/sys/net/core/rmem_max" if option == .Receive_Buffer_Size else "/proc/sys/net/core/wmem_max"
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return -1
	}
	most, _ := strconv.parse_int(strings.trim_space(string(data)))
	return 2 * min(asked, most)
}
