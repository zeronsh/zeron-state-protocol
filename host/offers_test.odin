package host

import "core:encoding/hex"
import "core:fmt"
import "core:strings"
import "core:testing"
import "../pipe"
import "../zsp"

@(private = "file")
words :: proc(s: string) -> []string {
	return strings.fields(s, context.temp_allocator)
}

@(test)
offers_read_and_written :: proc(t: ^testing.T) {
	device := strings.repeat("ab", 32, context.temp_allocator)
	for text in ([]string{"22 1", "8000-8999 3 name=dev", cat("5432 2 device=", device, " host=10.0.0.4 name=db proxy"), "80 1 host=fd00::4"}) {
		o, ok := offer_parse(words(text))
		testing.expectf(t, ok, "%q is an offer", text)
		testing.expect_value(t, offer_text(&o), text)
		w := make([dynamic]byte, context.temp_allocator)
		offer_put(&w, &o)
		r := zsp.Reader{buf = w[:]}
		back, read := offer_read(&r)
		testing.expect(t, read && zsp.read_done(&r) && offer_text(&back) == text)
	}
	for text in ([]string{
		"", "22", "0 1", "22 0", "22-21 1", "22-70000 1", "x 1", "22 x", "22 1 bogus", "22 1 device=12",
		"22 1 host=127.0.0.1", // this machine is no host: an offer of no host is
		"22 1 host=127.77.0.5", // nor is another device, through this one
		"22 1 host=::1", "22 1 host=::ffff:127.0.0.1", "22 1 host=0.0.0.0", "22 1 host=nas.local",
		"1-2000 1 host=10.0.0.4", // another machine's ports, a few at a time
		cat("22 1 name=", strings.repeat("x", 64, context.temp_allocator)),
	}) {
		_, ok := offer_parse(words(text))
		testing.expectf(t, !ok, "%q is not an offer", text)
	}
	bad := Offer{lo = 22, hi = 22, scope = 1, name = "a\nb"}
	testing.expect(t, !offer_sound(&bad))
	testing.expect(t, !ok_parse(cat("22 1 device=", device, "abab"))) // a key is 32 bytes, not the first 32 of more
	// A name is one word, as the offers file keeps it: else what is offered is not what is read back, as a name that
	// says `host=` would make an offer of this machine one of another.
	for name in ([]string{"app host=10.20.30.40 proxy", "my web app", "a\u00a0b", "a\u2003b", "a\u0085b", "\xff", "a\x7fb"}) {
		o := Offer{lo = 22, hi = 22, scope = 1, name = name}
		testing.expectf(t, !offer_sound(&o), "%q is a name", name)
	}
	for name in ([]string{"café", "web-1", "a=b", "#1"}) {
		o := Offer{lo = 22, hi = 22, scope = 1, name = name}
		back, ok := offer_parse(words(offer_text(&o)))
		testing.expectf(t, offer_sound(&o) && ok && back.name == name && back.host == "" && !back.proxy, "%q", name)
	}
}

@(private = "file")
ok_parse :: proc(text: string) -> bool {
	_, ok := offer_parse(words(text))
	return ok
}

@(test)
entries_round_trip :: proc(t: ^testing.T) {
	list := []Port_Entry{{22, 1, "", "ssh"}, {5432, 7, "10.0.0.4", ""}, {65535, 1 << 30, "", ""}}
	w := make([dynamic]byte, context.temp_allocator)
	entries_put(&w, list)
	back, ok := entries_read(w[:])
	testing.expect(t, ok && len(back) == 3)
	for e, i in back {
		testing.expect(t, e == list[i])
	}
	for cut in 0 ..< len(w) {
		_, partial := entries_read(w[:cut])
		testing.expect(t, !partial)
	}
	_, zero := entries_read({1, 0, 22, 0, 0, 0}) // scope 0 is nobody's
	testing.expect(t, !zero)
	// What no device would say is not believed of one: no port, no address for a host, no one-word name, nor more
	// than a device says at once, which would be kept and said again to every client that asks.
	big := strings.repeat("a", 63, context.temp_allocator)
	for bad in ([]Port_Entry{{0, 1, "", ""}, {22, 1, "nas.local", ""}, {22, 1, strings.repeat("1", 200, context.temp_allocator), ""}, {22, 1, "", "a b"}, {22, 1, "", cat(big, "a")}}) {
		one := make([dynamic]byte, context.temp_allocator)
		entries_put(&one, {bad})
		_, believed := entries_read(one[:])
		testing.expectf(t, !believed, "%v", bad)
	}
	many := make([dynamic]Port_Entry, context.temp_allocator)
	for i in 1 ..= 2000 {
		append(&many, Port_Entry{u16(i), 1, "", big})
	}
	lots := make([dynamic]byte, context.temp_allocator)
	entries_put(&lots, many[:])
	_, believed := entries_read(lots[:])
	testing.expect(t, !believed)
}

@(private = "file")
offer :: proc(t: ^testing.T, ts: ^Test_Space, text: string) {
	o, ok := offer_parse(words(text))
	testing.expect(t, ok)
	append(&ts.space.ports.offers, Offer{o.lo, o.hi, o.scope, o.device, strings.clone(o.host), strings.clone(o.name), o.proxy})
}

@(test)
offers_permit :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts)
	defer test_space_destroy(&ts)
	sp := &ts.space
	sp.ports = new(Ports)
	sp.ports.space = sp
	defer ports_close(sp)
	b, c := ts.keys[1].device, ts.keys[2].device

	// Nothing is offered unless it is.
	ok, _ := port_permitted(sp, b, 1, 22, "")
	testing.expect(t, !ok)

	offer(t, &ts, "22 1")
	offer(t, &ts, cat("8000-8100 1 device=", string(hex.encode(c[:], context.temp_allocator)), " proxy"))
	offer(t, &ts, "5432 1 host=10.0.0.4")
	ok, _ = port_permitted(sp, b, 1, 22, "")
	testing.expect(t, ok)
	ok, _ = port_permitted(sp, b, 1, 23, "")
	testing.expect(t, !ok)
	ok, _ = port_permitted(sp, b, 1, 22, "10.0.0.4") // the offer is of this machine's port, not another's
	testing.expect(t, !ok)
	ok, _ = port_permitted(sp, b, 1, 5432, "10.0.0.4")
	testing.expect(t, ok)
	ok, _ = port_permitted(sp, b, 1, 5432, "")
	testing.expect(t, !ok)
	// To one device, and only to it.
	ok, _ = port_permitted(sp, b, 1, 8050, "")
	testing.expect(t, !ok)
	proxy: bool
	ok, proxy = port_permitted(sp, c, 1, 8050, "")
	testing.expect(t, ok && proxy)
	// Nobody reaches this device through itself.
	ok, _ = port_permitted(sp, ts.keys[0].device, 1, 22, "")
	testing.expect(t, !ok)

	// What it lists is what listens, of what is offered; never this host's own; and another machine's as offered.
	append(&sp.ports.listening, pipe.address_v4(0, 0, 0, 0, 22), pipe.address_v4(127, 0, 0, 1, 8080), pipe.address_v4(192, 168, 1, 5, 8081))
	append(&sp.ports.listening, pipe.address_v4(127, 77, 0, 3, 8082)) // a forward of another's, here
	append(&sp.ports.listening, pipe.Address{ip = {15 = 1}, port = 8083}, pipe.address_v4(0, 0, 0, 0, 9999))
	list, _ := offered_to(sp.ports, c)
	ports := make([dynamic]u16, context.temp_allocator)
	for e in list {
		append(&ports, e.port)
	}
	testing.expectf(t, len(list) == 4 && list[0] == {22, 1, "", ""} && list[1].port == 5432 && list[1].host == "10.0.0.4" && list[2].port == 8080 && list[3].port == 8083, "%v", list)
	list, _ = offered_to(sp.ports, b)
	testing.expectf(t, len(list) == 2, "%v", list)

	// A grant that ends ends what it allowed.
	d := zsp.draft_from(&sp.node.roster, 1000)
	zsp.draft_revoke(&d, c)
	roster, signed := zsp.roster_sign(&ts.keys[0], ts.root, &d, context.temp_allocator)
	testing.expect(t, signed && zsp.node_adopt(&sp.node, roster))
	ok, _ = port_permitted(sp, c, 1, 8050, "")
	testing.expect(t, !ok)
	list, _ = offered_to(sp.ports, c)
	testing.expect_value(t, len(list), 0)

	// In the scope it is offered in, and no other: a call in one scope reaches nothing offered only in another,
	// though the caller may call in both.
	d = zsp.draft_from(&sp.node.roster, 2000)
	two := zsp.draft_scope(&d)
	zsp.draft_grant(&d, ts.keys[0].device, ts.keys[0].signer, two, {.Write, .Call})
	zsp.draft_grant(&d, b, ts.keys[1].signer, two, {.Write, .Call})
	roster, signed = zsp.roster_sign(&ts.keys[0], ts.root, &d, context.temp_allocator)
	testing.expect(t, signed && zsp.node_adopt(&sp.node, roster))
	offer(t, &ts, fmt.tprintf("6000 %d", two))
	ok, _ = port_permitted(sp, b, two, 6000, "")
	testing.expect(t, ok)
	ok, _ = port_permitted(sp, b, 1, 6000, "")
	testing.expect(t, !ok)
}

@(test)
web_pages_reach_only_their_own :: proc(t: ^testing.T) {
	ts: Test_Space
	test_space(t, &ts, {"", "desk", ""})
	defer test_space_destroy(&ts)
	sp := &ts.space
	desk := ts.keys[1].device
	verdict :: proc(sp: ^Space, device: zsp.Key32, request: string) -> Inspection {
		v, _ := http_verdict(sp, device, transmute([]byte)request)
		return v
	}
	id := name_id(ts.keys[2].device)
	other := strings.concatenate({string(id[:]), ".id.zsp.internal"}, context.temp_allocator)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal:8080\r\n\r\n"), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nhost: DESK.zsp.internal.\r\n\r\n"), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: 127.77.0.3:8080\r\n\r\n"), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, cat("POST /x HTTP/1.1\r\nHost: desk.zsp.internal\r\nOrigin: http://", other, ":3000\r\n\r\nbody")), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, "\r\nGET / HTTP/1.1\nHost: desk.zsp.internal\n\n"), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, "GET http://desk.zsp.internal:80/x HTTP/1.1\r\nHost: desk.zsp.internal\r\n\r\n"), Inspection.Pass)
	// Not yet known.
	testing.expect_value(t, verdict(sp, desk, "GE"), Inspection.More)
	testing.expect_value(t, verdict(sp, desk, "\r\n"), Inspection.More)
	testing.expect_value(t, verdict(sp, desk, "patch /x HTTP/1."), Inspection.More)
	// What came first, a token and nothing after, is no browser's, which writes its request's head at once: a client
	// that says a word and waits. A space, and it might be one.
	first :: proc(sp: ^Space, device: zsp.Key32, request: string) -> Inspection {
		v, _ := http_verdict(sp, device, transmute([]byte)request, first_look = true)
		return v
	}
	testing.expect_value(t, first(sp, desk, "hello"), Inspection.Pass)
	testing.expect_value(t, first(sp, desk, "e"), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, "hello"), Inspection.More)
	testing.expect_value(t, first(sp, desk, "patch /x HTTP/1."), Inspection.More)
	testing.expect_value(t, first(sp, desk, cat("patch / HTTP/1.1\r\n", "Host: attacker.example\r\n\r\n")), Inspection.Reject)
	// Only a short word, the whole of what came, and nothing before it: a read of 16 KiB of method is not the whole
	// of what was written, and an empty line is not a word.
	testing.expect_value(t, first(sp, desk, strings.repeat("A", 16384, context.temp_allocator)), Inspection.More)
	testing.expect_value(t, first(sp, desk, strings.repeat("A", 65, context.temp_allocator)), Inspection.More)
	testing.expect_value(t, first(sp, desk, "\r\n"), Inspection.More)
	testing.expect_value(t, first(sp, desk, "\r\nGET"), Inspection.More)
	// A method of HTTP's that goes on as no request line does is refused, not passed: a server reads it as one.
	for odd in ([]string{
		"GET /secret\r\nHost: attacker.example\r\n\r\n", // HTTP/0.9
		"GET  /secret HTTP/1.1\r\nHost: attacker.example\r\n\r\n",
		"GET /secret HTTP/1.1 \r\nHost: attacker.example\r\n\r\n",
		"GET /secret?\xc3\xa9 HTTP/1.1\r\nHost: attacker.example\r\n\r\n",
		"post\t/ HTTP/1.1\r\n\r\n",
	}) {
		testing.expectf(t, verdict(sp, desk, odd) == .Reject, "%q", odd)
	}
	// Nor one with another method that names HTTP's version on its line (WebDAV's, or any a page may send).
	for odd in ([]string{
		"PROPFIND /dav HTTP/1.1 \r\nHost: attacker.example\r\n\r\n",
		"PROPFIND /direct  HTTP/1.1\r\nHost: attacker.example\r\n\r\n",
		"MKCOL\t/x HTTP/1.1\r\n\r\n",
	}) {
		testing.expectf(t, verdict(sp, desk, odd) == .Reject, "%q", odd)
	}
	testing.expect_value(t, verdict(sp, desk, "PROPFIND /x  HTTP/1"), Inspection.More) // its line not yet whole
	// How long a request that passes is, so that the next on its connection is judged too; none where its end is not to
	// be found (a body in chunks, an upgrade, CONNECT), and two lengths are refused.
	length :: proc(sp: ^Space, device: zsp.Key32, request: string) -> (Inspection, int) {
		n := 0
		v, _ := http_verdict(sp, device, transmute([]byte)request, request = &n)
		return v, n
	}
	head := "POST /x HTTP/1.1\r\nHost: desk.zsp.internal\r\nContent-Length: 5\r\n\r\n"
	v, n := length(sp, desk, cat(head, "hello", "GET / HTTP/1.1\r\n"))
	testing.expect(t, v == .Pass && n == len(head) + 5)
	v, n = length(sp, desk, "\r\nGET / HTTP/1.1\r\nHost: desk.zsp.internal\r\n\r\n")
	testing.expect(t, v == .Pass && n == len("\r\nGET / HTTP/1.1\r\nHost: desk.zsp.internal\r\n\r\n"))
	for unbounded in ([]string{
		"POST /x HTTP/1.1\r\nHost: desk.zsp.internal\r\nTransfer-Encoding: chunked\r\n\r\n",
		"GET /ws HTTP/1.1\r\nHost: desk.zsp.internal\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
		"CONNECT desk.zsp.internal:443 HTTP/1.1\r\nHost: desk.zsp.internal\r\n\r\n",
	}) {
		v, n = length(sp, desk, unbounded)
		testing.expectf(t, v == .Pass && n == 0, "%q: %v %d", unbounded, v, n)
	}
	v, _ = length(sp, desk, "POST /x HTTP/1.1\r\nHost: desk.zsp.internal\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n")
	testing.expect_value(t, v, Inspection.Reject)
	v, _ = length(sp, desk, "POST /x HTTP/1.1\r\nHost: desk.zsp.internal\r\nContent-Length: +5\r\n\r\n")
	testing.expect_value(t, v, Inspection.Reject)
	// What no server takes for a request still passes: a mail client's word, a file server's.
	testing.expect_value(t, verdict(sp, desk, "USER bob\r\n"), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, "EHLO client.example\r\n"), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk"), Inspection.More)
	// Not HTTP at all: an SSH client, TLS.
	testing.expect_value(t, verdict(sp, desk, "SSH-2.0-OpenSSH_9.6\r\n"), Inspection.Pass)
	testing.expect_value(t, verdict(sp, desk, "\x16\x03\x01\x02\x00"), Inspection.Pass)
	// A page elsewhere, whose own name now leads here; another device's name; and a page of another place.
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: attacker.example:8080\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, cat("GET / HTTP/1.1\r\nHost: ", other, "\r\n\r\n")), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal\r\nOrigin: https://attacker.example\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal\r\nOrigin: null\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal\r\nHost: attacker.example\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal.attacker.example\r\n\r\n"), Inspection.Reject)
	// However the request is written, by fetch or by hand, a server reads the same of it, or it is refused.
	attacker := "Host: attacker.example\r\nOrigin: https://attacker.example\r\n\r\n"
	testing.expect_value(t, verdict(sp, desk, cat("patch / HTTP/1.1\r\n", attacker)), Inspection.Reject) // fetch sends a method as given
	testing.expect_value(t, verdict(sp, desk, cat(strings.repeat("A", 40, context.temp_allocator), " / HTTP/1.1\r\n", attacker)), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, cat("\r\n\r\nGET / HTTP/1.1\r\n", attacker)), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\nHost: attacker.example\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.0\r\n\r\n"), Inspection.Reject) // no browser leaves out the name
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal\r\nOrigin: https://attacker.example\r\nOrigin: http://desk.zsp.internal\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal:80@attacker.example\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal\r\nOrigin: https://desk.zsp.internal:80.attacker.example\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal\r\nOrigin: https://desk.zsp.internal/x\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET http://attacker.example/ HTTP/1.1\r\nHost: desk.zsp.internal\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: desk.zsp.internal\r\n attacker.example\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost : attacker.example\r\nHost: desk.zsp.internal\r\n\r\n"), Inspection.Reject)
	testing.expect_value(t, verdict(sp, desk, "GET / HTTP/1.1\r\nHost: [::1]:80\r\n\r\n"), Inspection.Reject)
}

@(private = "file")
cat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts, context.temp_allocator)
}
