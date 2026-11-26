#+build !js
package pipe

import "core:strings"
import "core:testing"

// A proxy's request line is read exactly, as the device's server would read it: a version with anything after it is
// none, nor is a line with a part missing.
@(test)
http_proxy_request_exact :: proc(t: ^testing.T) {
	r, result := http_proxy_request(transmute([]byte)string("GET http://desk.zsp.internal/ HTTP/1.1\r\nHost: desk.zsp.internal\r\n\r\n"))
	testing.expect(t, result == .Done && r.host == "desk.zsp.internal" && r.port == 80)
	// A query with no path: the path is /, and the query goes with it.
	r, result = http_proxy_request(transmute([]byte)string("GET http://desk.zsp.internal:8080?x=1 HTTP/1.1\r\nHost: desk.zsp.internal:8080\r\n\r\n"))
	testing.expectf(t, result == .Done && r.host == "desk.zsp.internal" && r.port == 8080 && strings.has_prefix(string(r.head), "GET /?x=1 HTTP/1.1\r\n"), "%v %q", result, string(r.head))
	_, result = http_proxy_request(transmute([]byte)string("GET http://desk.zsp.internal/#top HTTP/1.1\r\nHost: x\r\n\r\n"))
	testing.expect(t, result == .Broken)
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
