#+build !linux
package host

import "../third_party/nbio"

// What macOS, the BSDs and Windows grant a buffer asked for, within their limits: what is asked.
@(private)
granted :: proc(option: nbio.Socket_Option, asked: int) -> int {
	return asked
}
