/*
zspd is one consumer of the protocol: a device's node, or a self-hosted relay, with the simplest
authentication that is not none. Local clients present the token in `<dir>/token`; a relay, unless
told which spaces it serves, serves any. An application with accounts embeds package host and answers
Config.authenticate from its own.
*/
package main

import "base:runtime"
import "core:crypto"
import "core:encoding/hex"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "../host"
import "../pipe"
import "../zsp"

USAGE :: `zspd - Zeron State Protocol node

  zspd create <dir>                          make a space, owned by this device
  zspd key <dir>                             print what an admin needs to admit this device
  zspd scope <dir> [signed]                  add a scope to the space
  zspd admit <dir> <key> <scope> [read|vouch|shell|files ...]
                                             grant a device a scope: to read, write and call; only to read; to say
                                             for whom, too, and be believed; to use what devices share of terminals
                                             and commands, or of files
  zspd revoke <dir> <key> [scope]            end a device's grants
  zspd subject <dir> <key> <text>            say whose a device is: an account, a name, as you know them
  zspd name <dir> <key> [name]               name a device, as other devices will reach it: <name>.zsp.internal;
                                             without a name, unname it
  zspd members <dir>                         list devices: key, @name, rights in each scope, whose it is
  zspd admin <dir> <key> [off]               let a device do all of this but make admins and owners, or no longer
  zspd owner <dir> <key>                     make a device an owner too, for good
  zspd relay <dir> <key> <url>               name a relay for the space's devices to meet at
  zspd join <dir> <space> <relay-key> <url>  become a device of a space that has admitted this one
  zspd peer <dir> <roster-file>              join from a roster file instead of a relay
  zspd run <dir> [options]                   run a device's node
  zspd serve <dir> [options]                 run a relay

  zspd share <dir> [line ...]                say what this device shares, or share instead, a line each:
                                             "shell <scope> [terminal] [commands]",
                                             "files <scope> <name> read|write <path>"; "" for nothing
  zspd services <dir> <device>               what a device offers this one
  zspd connect <dir> <device> <port> [host]  join stdin and stdout to a TCP port there, or one it reaches (as an ssh
                                             ProxyCommand, say)
  zspd exec <dir> <device> [--] <argv...>    run a command there: its stdin, stdout and stderr are these, its exit
                                             code this one's (128 and the signal, if one ended it; 255 if it could
                                             not run), and signals sent here go there
  zspd terminal <dir> <device>               a terminal there, the user's shell, in this one
  zspd ls <dir> <device> [path]              list a folder there; with no path, the shares of files
  zspd get <dir> <device> <remote> [local]   fetch a file or a folder; again, after a break, it takes up where it
                                             stopped
  zspd put <dir> <device> <local> <remote>   send a file or a folder

  --listen=<addr:port>   serve WebSockets here (run: 127.0.0.1:0, serve: 0.0.0.0:8787)
  --udp=<port>           use this port for direct links
  --no-udp               make no direct links
  --stun=<host:port>     learn this machine's outside address here
  --partial              replicate only what local clients watch
  --credential=<text>    present this to relays
  --allow=<space,...>    serve only these spaces
  --verbose

  <device>               a device's key, the start of one, or whose it is, as the roster says
  <path>, <remote>       a share's name, then the path within it, '/' between
  <remote>, <local>      where what is sent or fetched goes: there; or, ending in '/', a share alone, or for a file a
                         folder that is there already, into it, under its own name
  --scope=N              call in this scope (1)
  --cwd=<dir>            exec: begin there, not at home
  --env=NAME[=value]     exec: set this, or with no value unset it
  --replace              put: over what is there
`

main :: proc() {
	os.exit(run())
}

run :: proc() -> int {
	args := os.args[1:]
	if len(args) < 2 {
		os.write_string(os.stderr, USAGE)
		return 2
	}
	verbose := false
	for a in args {
		if a == "--" {
			break // what follows is a command's, not this one's
		}
		verbose ||= a == "--verbose"
	}
	// Standard output is for answers.
	context.logger = {
		lowest_level = .Debug if verbose else .Info,
		procedure    = proc(_: rawptr, level: runtime.Logger_Level, text: string, _: runtime.Logger_Options, _ := #caller_location) {
			if level == .Debug {
				// When, to the millisecond, so that what several nodes say can be read as one story.
				now := time.now()
				h, m, sec := time.clock_from_time(now)
				ms := time.to_unix_nanoseconds(now) / 1_000_000 % 1000
				say(os.stderr, fmt.tprintf("%02d:%02d:%02d.%03d ", h, m, sec, ms), text, "\n")
				return
			}
			say(os.stderr, text, "\n")
		},
	}
	dir := args[1]
	rest := args[2:]
	ok := false
	switch args[0] {
	case "create":
		ok = create(dir)
	case "key":
		ok = print_key(dir)
	case "scope":
		ok = amend(dir, rest, proc(a: ^Admin, args: []string) -> bool {
			id := zsp.draft_scope(&a.draft, {.Signed} if len(args) > 0 && args[0] == "signed" else {})
			for m in a.draft.members {
				if m.owner || m.admin {
					zsp.draft_grant(&a.draft, m.device, m.signer, id, {.Read, .Write, .Call})
				}
			}
			buf: [10]byte
			say(os.stdout, strconv.write_uint(buf[:], u64(id), 10), "\n")
			return true
		})
	case "admit":
		ok = len(rest) >= 2 && amend(dir, rest, proc(a: ^Admin, args: []string) -> bool {
			key := parse_hex(args[0], 64) or_return
			scope := strconv.parse_u64(args[1]) or_return
			device, signer: zsp.Key32
			copy(device[:], key)
			copy(signer[:], key[32:])
			rights := zsp.Rights{.Read, .Write, .Call}
			for word in args[2:] {
				switch word {
				case "read":
					rights -= {.Write, .Call}
				case "vouch":
					rights += {.Vouch}
				case "shell":
					rights += {.Shell}
				case "files":
					rights += {.Files}
				case:
					return false
				}
			}
			zsp.draft_grant(&a.draft, device, signer, zsp.Scope(scope), rights)
			return true
		})
	case "revoke":
		ok = len(rest) >= 1 && amend(dir, rest, proc(a: ^Admin, args: []string) -> bool {
			key := parse_hex(args[0], 64) or_return
			device: zsp.Key32
			copy(device[:], key)
			if m := zsp.roster_member(&a.roster, device); m != nil && m.owner {
				say(os.stderr, "an owner holds the key that is the space, and nothing can take that back\n")
				return false
			}
			scope: u64
			if len(args) > 1 {
				scope = strconv.parse_u64(args[1]) or_return
			}
			zsp.draft_revoke(&a.draft, device, zsp.Scope(scope))
			return true
		})
	case "subject":
		ok = len(rest) == 2 && amend(dir, rest, proc(a: ^Admin, args: []string) -> bool {
			key := parse_hex(args[0], 64) or_return
			for &m in a.draft.members {
				if string(m.device[:]) == string(key[:32]) {
					m.subject = transmute([]byte)args[1]
					return true
				}
			}
			return false
		})
	case "name":
		ok = len(rest) >= 1 && len(rest) <= 2 && amend(dir, rest, proc(a: ^Admin, args: []string) -> bool {
			key, hexed := parse_hex(args[0], 64)
			if !hexed {
				key = parse_hex(args[0], 32) or_return
			}
			device: zsp.Key32
			copy(device[:], key)
			name := args[1] if len(args) > 1 else ""
			if zsp.draft_name(&a.draft, device, name) {
				return true
			}
			switch {
			case name != "" && !zsp.name_valid(name):
				say(os.stderr, "a name is 1 to 63 lower-case letters, digits and hyphens, with no hyphen at either end\n")
			case zsp.roster_member(&a.roster, device) == nil:
				say(os.stderr, "no such device\n")
			case:
				say(os.stderr, "another device has that name\n")
			}
			return false
		})
	case "members":
		ok = members(dir)
	case "admin":
		ok = len(rest) >= 1 && amend(dir, rest, proc(a: ^Admin, args: []string) -> bool {
			return appoint(a, args[0], false, len(args) < 2 || args[1] != "off")
		})
	case "owner":
		ok = len(rest) == 1 && amend(dir, rest, proc(a: ^Admin, args: []string) -> bool {
			return appoint(a, args[0], true, true)
		})
	case "relay":
		ok = len(rest) == 2 && amend(dir, rest, proc(a: ^Admin, args: []string) -> bool {
			key := parse_hex(args[0], 32) or_return
			r: zsp.Relay
			copy(r.key[:], key)
			r.url = space_url(args[1], a.space)
			append(&a.draft.relays, r)
			return true
		})
	case "join":
		ok = len(rest) == 3 && join(dir, rest[0], rest[1], rest[2])
	case "peer":
		ok = len(rest) == 1 && join_from_roster(dir, rest[0])
	case "run", "serve":
		return serve(dir, rest, args[0] == "serve")
	case "share":
		return share(dir, rest)
	case "services":
		return services(dir, rest)
	case "connect":
		return connect(dir, rest)
	case "exec":
		return exec(dir, rest)
	case "terminal":
		return terminal(dir, rest)
	case "ls":
		return ls(dir, rest)
	case "get":
		return get(dir, rest)
	case "put":
		return put(dir, rest)
	case:
		os.write_string(os.stderr, USAGE)
		return 2
	}
	if !ok {
		say(os.stderr, args[0], " failed\n")
		return 1
	}
	return 0
}

Admin :: struct {
	keys:   zsp.Keyring,
	roster: zsp.Roster,
	draft:  zsp.Draft,
	space:  string,
}

// An admin or owner draws up rosters, and so must hold every scope's keys.
appoint :: proc(a: ^Admin, key: string, owner, yes: bool) -> bool {
	bytes := parse_hex(key, 64) or_return
	device, signer: zsp.Key32
	copy(device[:], bytes)
	copy(signer[:], bytes[32:])
	if yes {
		for s in a.draft.scopes {
			zsp.draft_grant(&a.draft, device, signer, s.id, {.Read, .Write, .Call})
		}
	}
	for &m in a.draft.members {
		if m.device == device {
			m.owner ||= owner
			m.admin = yes if !owner else m.admin
			return true
		}
	}
	return false
}

in_dir :: proc(dir, name: string) -> string {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

say :: proc(to: ^os.File, parts: ..string) {
	os.write_string(to, strings.concatenate(parts, context.temp_allocator))
}

@(require_results)
parse_hex :: proc(s: string, size: int) -> (b: []byte, ok: bool) {
	b = hex.decode(transmute([]byte)s, context.temp_allocator) or_return
	return b, len(b) == size
}

to_hex :: proc(b: []byte) -> string {
	return string(hex.encode(b, context.temp_allocator))
}

create :: proc(dir: string) -> bool {
	secret := host.device_secret(dir) or_return
	if os.exists(in_dir(dir, "space")) {
		say(os.stderr, "there is a space here already\n")
		return false
	}
	root: zsp.Key32
	crypto.rand_bytes(root[:])
	space := zsp.ed25519_public(root)
	k: zsp.Keyring
	zsp.keyring_init(&k, secret)
	none: zsp.Roster
	d := zsp.draft_from(&none, host.now_ms() << 16)
	home := zsp.draft_scope(&d)
	zsp.draft_grant(&d, k.device, k.signer, home, {.Read, .Write, .Call}).owner = true
	bytes := zsp.roster_sign(&k, root, &d, context.temp_allocator) or_return
	name := to_hex(space[:])
	if err := os.make_directory_all(in_dir(dir, name)); err != nil {
		return false
	}
	host.save(in_dir(in_dir(dir, name), "roster"), bytes) or_return
	host.save(in_dir(dir, "space"), transmute([]byte)name) or_return
	say(os.stdout, name, "\n")
	return true
}

print_key :: proc(dir: string) -> bool {
	secret := host.device_secret(dir) or_return
	k: zsp.Keyring
	zsp.keyring_init(&k, secret)
	say(os.stdout, to_hex(k.device[:]), to_hex(k.signer[:]), "\n")
	return true
}

// A line for each device: its key, what it may do, and whose it is.
members :: proc(dir: string) -> bool {
	space, name := read_space(dir) or_return
	data, err := os.read_entire_file(in_dir(in_dir(dir, name), "roster"), context.temp_allocator)
	if err != nil {
		return false
	}
	r := zsp.roster_parse(data, space) or_return
	for &m in r.members {
		if !zsp.member_active(&m) {
			continue
		}
		say(os.stdout, to_hex(m.device[:]), to_hex(m.signer[:]))
		if len(m.hostname) > 0 {
			say(os.stdout, " @", string(m.hostname))
		}
		buf: [10]byte
		for g in m.grants {
			if g.until != 0 {
				continue
			}
			say(os.stdout, " ", strconv.write_uint(buf[:], u64(g.scope), 10), ":", "r" if .Read in g.rights else "", "w" if .Write in g.rights else "", "c" if .Call in g.rights else "", "v" if .Vouch in g.rights else "", "s" if .Shell in g.rights else "", "f" if .Files in g.rights else "")
		}
		say(os.stdout, " owner" if m.owner else " admin" if m.admin else "", "\t", string(m.subject), "\n")
	}
	return true
}

read_space :: proc(dir: string) -> (space: zsp.Key32, name: string, ok: bool) {
	data, err := os.read_entire_file(in_dir(dir, "space"), context.temp_allocator)
	if err != nil {
		return
	}
	name = strings.trim_space(string(data))
	bytes := parse_hex(name, 32) or_return
	copy(space[:], bytes)
	return space, name, true
}

// Publishes an amended roster: to disk, to the node running here, and through it to everyone.
amend :: proc(dir: string, args: []string, change: proc(a: ^Admin, args: []string) -> bool) -> bool {
	secret := host.device_secret(dir) or_return
	space, name := read_space(dir) or_return
	a: Admin
	a.space = name
	zsp.keyring_init(&a.keys, secret)
	path := in_dir(in_dir(dir, name), "roster")
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	a.roster = zsp.roster_parse(data, space) or_return
	if kept, kerr := os.read_entire_file(in_dir(in_dir(dir, name), "keys"), context.temp_allocator); kerr == nil {
		zsp.keyring_load(&a.keys, kept)
	}
	if !zsp.roster_unwrap(&a.keys, &a.roster) {
		say(os.stderr, "this device does not belong to the space\n")
		return false
	}
	if !zsp.keyring_rules(&a.keys, &a.roster) {
		say(os.stderr, "this device is not an admin of the space\n")
		return false
	}
	a.draft = zsp.draft_from(&a.roster, max(host.now_ms() << 16, host.clock_of(in_dir(dir, name)), running_clock(dir)))
	change(&a, args) or_return
	bytes, signed := zsp.roster_sign(&a.keys, a.keys.root, &a.draft, context.temp_allocator)
	if !signed {
		say(os.stderr, "only an owner can do that, or an admin who may read every scope\n")
		return false
	}
	if _, sound := zsp.roster_parse(bytes, space); !sound {
		say(os.stderr, "that would make an unsound roster: only signed scopes may have readers who do not write\n")
		return false
	}
	host.save(in_dir(in_dir(dir, name), "roster.old"), data) or_return
	host.save(path, bytes) or_return
	return announce(dir, bytes)
}

// Hands a roster to the node running here, if one is, so that the change takes effect at once. One that is there but
// does not say it has it, as a busy one may not at once, is asked again; and if it never does, that is said.
announce :: proc(dir: string, roster: []byte) -> bool {
	for _ in 0 ..< 3 {
		_, confirmed, reached := speak(dir, roster)
		if confirmed || !reached {
			return true // taken; or no node runs here, and it reads the roster when it starts
		}
	}
	say(os.stderr, "the node running here did not say it has the change: it takes it when it next starts\n")
	return false
}

// What the node running here, if one is, thinks the time is: no earlier than anything it has seen.
running_clock :: proc(dir: string) -> u64 {
	clock, _, _ := speak(dir, nil)
	return clock
}

// Greets the node running here, with a roster if there is one to hand over, and hears what it says back: its clock,
// whether it said it, and whether anything was there to speak to.
speak :: proc(dir: string, roster: []byte) -> (clock: u64, ok: bool, reached: bool) {
	address, aerr := os.read_entire_file(in_dir(dir, "address"), context.temp_allocator)
	token, terr := os.read_entire_file(in_dir(dir, "token"), context.temp_allocator)
	endpoint, parsed := net.parse_endpoint(string(address))
	if aerr != nil || terr != nil || !parsed {
		return
	}
	socket, err := net.dial_tcp(endpoint)
	if err != nil {
		return
	}
	defer net.close(socket)
	reached = true
	request := pipe.ws_request(string(address), "/")
	net.send_tcp(socket, transmute([]byte)request)
	frames := make([dynamic]byte, context.temp_allocator)
	at := zsp.frame_begin(&frames, .Hello)
	append(&frames, zsp.VERSION, 0)
	resize(&frames, len(frames) + 32)
	zsp.write_varint(&frames, 0)
	zsp.write_bytes(&frames, token)
	zsp.frame_end(&frames, at)
	if roster != nil {
		at = zsp.frame_begin(&frames, .Roster)
		append(&frames, ..roster)
		zsp.frame_end(&frames, at)
	}
	message := make([dynamic]byte, context.temp_allocator)
	pipe.ws_put(&message, .Binary, frames[:], true)
	net.send_tcp(socket, message[:])
	// Its answer, which begins with its clock, says it has read this far. Until then the line stays open: what was sent
	// on one closed before a busy node read it may not be read at all.
	buf: [4096]byte
	net.set_option(socket, .Receive_Timeout, 10 * time.Second)
	got := make([dynamic]byte, context.temp_allocator)
	stream := make([dynamic]byte, context.temp_allocator)
	used := 0
	for {
		n, rerr := net.recv_tcp(socket, buf[:])
		if n <= 0 || rerr != nil {
			return
		}
		append(&got, ..buf[:n])
		if used == 0 {
			head := pipe.http_head(got[:]) or_continue
			used = head.size
		}
		for {
			op, payload, size, _, result := pipe.ws_take(got[used:])
			if result != .Message {
				break
			}
			used += size
			if op == .Binary {
				append(&stream, ..payload)
			}
		}
		r := zsp.Reader{buf = stream[:]}
		for {
			frame := zsp.read_bytes(&r)
			if r.bad || len(frame) == 0 {
				break
			}
			if zsp.Message(frame[0]) == .Roster && len(frame) >= 9 {
				return zsp.get_u64(frame[1:]), true, true
			}
		}
	}
}

join :: proc(dir, space, relay_key, url: string) -> bool {
	_ = host.device_secret(dir) or_return
	_ = parse_hex(space, 32) or_return
	_ = parse_hex(relay_key, 32) or_return
	if err := os.make_directory_all(in_dir(dir, space)); err != nil && !os.is_dir(in_dir(dir, space)) {
		return false
	}
	host.save(in_dir(dir, "space"), transmute([]byte)space) or_return
	return host.save(in_dir(dir, "relay"), transmute([]byte)strings.concatenate({relay_key, " ", space_url(url, space)}, context.temp_allocator))
}

// Where a relay keeps a space. A query the relay's proxy wants stays at the end.
space_url :: proc(url, space: string) -> string {
	base, query := url, ""
	if i := strings.index_byte(url, '?'); i >= 0 {
		base, query = url[:i], url[i:]
	}
	return strings.concatenate({strings.trim_suffix(base, "/"), "/", space, query}, context.temp_allocator)
}

join_from_roster :: proc(dir, file: string) -> bool {
	_ = host.device_secret(dir) or_return
	data, err := os.read_entire_file(file, context.temp_allocator)
	if err != nil || len(data) < 38 {
		return false
	}
	space: zsp.Key32
	copy(space[:], data[6:])
	roster := zsp.roster_parse(data, space) or_return
	zsp.roster_destroy(&roster)
	name := to_hex(space[:])
	if merr := os.make_directory_all(in_dir(dir, name)); merr != nil && !os.is_dir(in_dir(dir, name)) {
		return false
	}
	host.save(in_dir(in_dir(dir, name), "roster"), data) or_return
	return host.save(in_dir(dir, "space"), transmute([]byte)name)
}

// This consumer's whole notion of authentication.
Policy :: struct {
	token:  string,
	spaces: [dynamic]zsp.Key32,
}

authenticate :: proc(data: rawptr, s: ^zsp.Session, credential: []byte) {
	p := (^Policy)(data)
	if s.role == .Open {
		if len(p.token) > 0 && crypto.compare_constant_time(credential, transmute([]byte)p.token) == 1 {
			zsp.session_accept(s, {{0, {.Read, .Write, .Call}, 0}})
		} else {
			zsp.session_refuse(s)
		}
		return
	}
	for id in p.spaces {
		if id == s.node.space {
			zsp.session_accept(s)
			return
		}
	}
	if len(p.spaces) == 0 {
		zsp.session_accept(s)
	} else {
		zsp.session_refuse(s)
	}
}

serve :: proc(dir: string, args: []string, relay: bool) -> int {
	policy: Policy
	config := host.Config {
		dir          = dir,
		full         = true,
		relay        = relay,
		udp_port     = 0,
		data         = &policy,
		authenticate = authenticate,
	}
	listen := "0.0.0.0:8787" if relay else "127.0.0.1:0"
	for a in args {
		eq := strings.index_byte(a, '=')
		name, value := a, ""
		if eq >= 0 {
			name, value = a[:eq], a[eq + 1:]
		}
		switch name {
		case "--listen":
			listen = value
		case "--udp":
			port, ok := strconv.parse_int(value)
			if !ok {
				os.write_string(os.stderr, USAGE)
				return 2
			}
			config.udp_port = port
		case "--no-udp":
			config.udp_port = nil
		case "--stun":
			config.stun = value
		case "--partial":
			config.full = false
		case "--credential":
			config.credential = value
		case "--allow":
			list := value
			for hexed in strings.split_iterator(&list, ",") {
				bytes, ok := parse_hex(hexed, 32)
				if !ok {
					os.write_string(os.stderr, USAGE)
					return 2
				}
				id: zsp.Key32
				copy(id[:], bytes)
				append(&policy.spaces, id)
			}
		case "--verbose":
		case:
			os.write_string(os.stderr, USAGE)
			return 2
		}
	}
	at, ok := net.parse_endpoint(listen)
	if !ok {
		os.write_string(os.stderr, USAGE)
		return 2
	}
	config.listen = at

	h: host.Host
	if !host.host_init(&h, config) {
		return 1
	}
	defer host.host_destroy(&h)
	if !relay {
		space, _, have := read_space(dir)
		if !have {
			say(os.stderr, "no space here: create or join one first\n")
			return 1
		}
		if host.space_open(&h, space) == nil {
			say(os.stderr, "could not open the space\n")
			return 1
		}
		if line, err := os.read_entire_file(in_dir(dir, "relay"), context.allocator); err == nil {
			parts := strings.fields(string(line), context.temp_allocator)
			key: zsp.Key32
			if len(parts) != 2 {
				say(os.stderr, "the relay file makes no sense\n")
				return 1
			}
			if bytes, hexed := parse_hex(parts[0], 32); hexed {
				copy(key[:], bytes)
				host.dial(&h, h.spaces[0], key, parts[1])
			}
		}
		policy.token = local_token(dir)
	}
	bound, _ := net.bound_endpoint(h.listener)
	address := net.endpoint_to_string(bound, context.temp_allocator)
	if !relay {
		host.save(in_dir(dir, "address"), transmute([]byte)address)
	}
	say(os.stdout, to_hex(h.device[:]), " listening on ws://", address, "\n")
	host.links_announce(&h)
	return 0 if host.host_run(&h) else 1
}

local_token :: proc(dir: string) -> string {
	path := in_dir(dir, "token")
	if data, err := os.read_entire_file(path, context.allocator); err == nil {
		return string(data)
	}
	b: [24]byte
	crypto.rand_bytes(b[:])
	token := strings.clone(to_hex(b[:]))
	host.save(path, transmute([]byte)token)
	return token
}
