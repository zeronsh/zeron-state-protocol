/*
A node whose local applications each have only their own scopes: one that is told what a credential is worth. Run it in
place of `zspd run`:

	apps <dir>

<dir>/apps says who there is, a line for each: a secret, and what it may do in which scopes.

	6f1c…  1:rwc 2:r
	09ab…  2:rw

What an application may do is that and no more, and no more than this device may. See docs/scoping.md.
*/
package main

import "core:crypto"
import "core:encoding/hex"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "../../host"
import "../../zsp"

App :: struct {
	secret: string,
	grants: []zsp.Grant,
}

Apps :: struct {
	all: [dynamic]App,
}

// Called with what a local application, or another device, presents. Another device has proven which it is, and
// the roster says what it may do; an application has only its secret.
authenticate :: proc(data: rawptr, s: ^zsp.Session, credential: []byte) {
	if s.role == .Peer {
		zsp.session_accept(s)
		return
	}
	for app in (^Apps)(data).all {
		if crypto.compare_constant_time(credential, transmute([]byte)app.secret) == 1 {
			zsp.session_accept(s, app.grants)
			return
		}
	}
	zsp.session_refuse(s)
}

apps_read :: proc(path: string) -> (apps: Apps, ok: bool) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		words := strings.fields(line)
		if len(words) == 0 {
			continue
		}
		grants: [dynamic]zsp.Grant
		for word in words[1:] {
			colon := strings.index_byte(word, ':')
			scope := strconv.parse_uint(word[:max(colon, 0)], 10) or_return
			g := zsp.Grant{scope = zsp.Scope(scope)}
			for letter in word[colon + 1:] {
				switch letter {
				case 'r':
					g.rights += {.Read}
				case 'w':
					g.rights += {.Read, .Write}
				case 'c':
					g.rights += {.Read, .Call}
				case:
					return
				}
			}
			append(&grants, g)
		}
		append(&apps.all, App{words[0], grants[:]})
	}
	return apps, true
}

main :: proc() {
	if len(os.args) != 2 {
		os.write_string(os.stderr, "apps <dir>\n")
		os.exit(2)
	}
	dir := os.args[1]
	apps, read := apps_read(strings.concatenate({dir, "/apps"}))
	name, err := os.read_entire_file(strings.concatenate({dir, "/space"}), context.allocator)
	space: zsp.Key32
	if bytes, hexed := hex.decode(transmute([]byte)strings.trim_space(string(name))); !read || err != nil || !hexed || copy(space[:], bytes) != 32 {
		os.write_string(os.stderr, "there must be a space here, made or joined with zspd, and a file that says what applications there are\n")
		os.exit(1)
	}
	at, _ := net.parse_endpoint("127.0.0.1:0")
	h: host.Host
	if !host.host_init(&h, {dir = dir, full = true, listen = at, data = &apps, authenticate = authenticate}) || host.space_open(&h, space) == nil {
		os.exit(1)
	}
	bound, _ := net.bound_endpoint(h.listener)
	os.write_string(os.stdout, strings.concatenate({hex_of(h.device[:]), " listening on ws://", net.endpoint_to_string(bound), "\n"}))
	os.exit(0 if host.host_run(&h) else 1)
}

hex_of :: proc(b: []byte) -> string {
	return string(hex.encode(b))
}
