#+build !js
package pipe

import "core:testing"

// A proxy's request line is read exactly, as the device's server would read it: a version with anything after it is
// none, nor is a line with a part missing.
@(test)
http_proxy_request_exact :: proc(t: ^testing.T) {
	r, result := http_proxy_request(transmute([]byte)string("GET http://desk.zsp.internal/ HTTP/1.1\r\nHost: desk.zsp.internal\r\n\r\n"))
	testing.expect(t, result == .Done && r.host == "desk.zsp.internal" && r.port == 80)
	for bad in ([]string{
		"PROPFIND http://desk.zsp.internal/ HTTP/1.1 \r\nHost: x\r\n\r\n",
		"GET http://desk.zsp.internal/ HTTP/1.10\r\n\r\n",
		"GET  http://desk.zsp.internal/ HTTP/1.1\r\n\r\n",
		"CONNECT desk.zsp.internal:22 HTTP/1.1x\r\n\r\n",
	}) {
		_, result = http_proxy_request(transmute([]byte)bad)
		testing.expectf(t, result == .Broken, "%q", bad)
	}
}
