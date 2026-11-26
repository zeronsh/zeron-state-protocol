package host

import "core:os"
import "core:strconv"
import "core:strings"
import "../zsp"

// What this device lets others do on it, and in which scopes: its terminals and commands (shell), and directories
// of its files (files). Nothing is shared until its owner says so, in `shares` in the space's directory, by zspd's
// `share` command or a local client's zsp.share; and whoever would use a share needs, besides, the roster's Shell or
// Files right in its scope, and Call. When the shares or the roster change, every call they no longer allow is ended,
// its process killed, its file closed. Ports are another's to offer: see Host.port_permitted.
//
//     shell <scope> [terminal] [commands]
//     files <scope> <name> read|write <path>
//
// A share of files is known to callers by its name, never by where it is here.

Share_Kind :: enum u8 {
	Shell,
	Files,
}

Share :: struct {
	kind:     Share_Kind,
	scope:    zsp.Scope,
	terminal: bool, // shell: zsp.pty
	commands: bool, // shell: zsp.exec
	name:     string, // files
	path:     string,
	write:    bool, // files: zsp.put too
}

// The status that begins a service's answer: 0, or why not and a reason, in words.
Status :: enum u8 {
	Ok          = 0,
	Denied      = 1, // not for this caller: no right, or not shared with them
	Not_Offered = 2, // not shared at all in this scope
	Refused     = 3,
	Unreachable = 4,
	Timed_Out   = 5,
	Not_Found   = 6,
	Failed      = 7,
	Changed     = 8, // what was being resumed is not what it was
	Exists      = 9,
	Malformed   = 10,
}

// A call to a service that a change of shares or rights may end.
@(private)
Service_Call :: struct {
	call:   u64,
	kind:   Share_Kind,
	caller: zsp.Key32,
	scope:  zsp.Scope,
	name:   string, // the share's, for files; owned
	write:  bool, // needs a share that may be written
	terminal: bool, // needs a share of terminals; else of commands
	data:   rawptr,
	stop:   proc(data: rawptr), // ends it at once: its process killed, its file closed; the call is faulted already
}

// The shares as written, parsed. Lines that make no sense are reported and passed over.
@(private)
shares_parse :: proc(text: string, into: ^[dynamic]Share) -> (ok: bool) {
	ok = true
	text := text
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw)
		if line == "" || line[0] == '#' {
			continue
		}
		fields := strings.fields(line, context.temp_allocator)
		scope: u64
		sane := len(fields) > 1
		if sane {
			scope, sane = strconv.parse_u64(fields[1])
		}
		sane &&= scope > 0 && scope < 1 << 32
		s := Share{scope = zsp.Scope(scope)}
		switch {
		case !sane:
		case fields[0] == "shell":
			s.kind = .Shell
			for f in fields[2:] {
				switch f {
				case "terminal":
					s.terminal = true
				case "commands":
					s.commands = true
				case:
					sane = false
				}
			}
			if len(fields) == 2 {
				s.terminal, s.commands = true, true
			}
		case fields[0] == "files" && len(fields) >= 5 && (fields[3] == "read" || fields[3] == "write"):
			s.kind = .Files
			s.name = strings.clone(fields[2])
			s.write = fields[3] == "write"
			// The rest of the line after the fourth word, spaces and all.
			s.path = strings.clone(strings.trim_space(after_words(line, 4)))
			sane = share_name_valid(s.name)
		case:
			sane = false
		}
		if !sane {
			report(.Warning, "a share makes no sense: ", line)
			delete(s.name)
			delete(s.path)
			ok = false
			continue
		}
		append(into, s)
	}
	return
}

@(private)
share_name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > 64 {
		return false
	}
	for c in name {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return name != "." && name != ".."
}

@(private)
shares_text :: proc(shares: []Share) -> string {
	b := strings.builder_make(context.temp_allocator)
	for s in shares {
		switch s.kind {
		case .Shell:
			strings.write_string(&b, "shell ")
			strings.write_u64(&b, u64(s.scope))
			if s.terminal {
				strings.write_string(&b, " terminal")
			}
			if s.commands {
				strings.write_string(&b, " commands")
			}
		case .Files:
			strings.write_string(&b, "files ")
			strings.write_u64(&b, u64(s.scope))
			strings.write_string(&b, " ")
			strings.write_string(&b, s.name)
			strings.write_string(&b, " write " if s.write else " read ")
			strings.write_string(&b, s.path)
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private)
shares_free :: proc(shares: ^[dynamic]Share) {
	for s in shares {
		delete(s.name)
		delete(s.path)
	}
	clear(shares)
}

// Reads the shares this device has, at start.
@(private)
shares_load :: proc(sp: ^Space) {
	if text, err := os.read_entire_file(file_in(sp.dir, "shares"), context.temp_allocator); err == nil {
		shares_parse(string(text), &sp.shares)
	}
}

@(private)
shares_close :: proc(sp: ^Space) {
	for len(sp.services) > 0 {
		c := pop(&sp.services)
		delete(c.name)
		free(c)
	}
	delete(sp.services)
	shares_free(&sp.shares)
	delete(sp.shares)
}

// Takes new shares, as text: saved, in force at once, and every call they no longer allow ended.
shares_set :: proc(sp: ^Space, text: string) -> bool {
	parsed: [dynamic]Share
	if !shares_parse(text, &parsed) {
		shares_free(&parsed)
		delete(parsed)
		return false
	}
	shares_free(&sp.shares)
	delete(sp.shares)
	sp.shares = parsed
	file_disk_make(&sp.disk)
	if !save(file_in(sp.dir, "shares"), transmute([]byte)shares_text(sp.shares[:])) {
		report(.Error, "could not save the shares")
	}
	audit(sp, {device = sp.host.device, service = "shares", detail = shares_text(sp.shares[:]), event = .Change})
	services_recheck(sp)
	return true
}

// The share a call would use, if the caller may: Call and the right in the scope, by the roster, and the share.
@(private)
share_for :: proc(sp: ^Space, from: Caller, scope: zsp.Scope, kind: Share_Kind, name := "", write := false, terminal := false) -> (share: ^Share, status: Status) {
	if from.relay || from.local != nil {
		return nil, .Denied // the device's own clients, and relays, use nothing here
	}
	need := zsp.Right.Shell if kind == .Shell else zsp.Right.Files
	rights := zsp.device_rights(&sp.node, from.device, scope)
	offered := false
	for &s in sp.shares {
		if s.kind != kind || s.scope != scope || (kind == .Files && s.name != name) {
			continue
		}
		offered = true
		if kind == .Shell && !(s.terminal if terminal else s.commands) {
			continue
		}
		if kind == .Files && write && !s.write {
			continue
		}
		share = &s
	}
	switch {
	case !offered:
		return nil, .Not_Offered
	case share == nil || .Call not_in rights || need not_in rights:
		return nil, .Denied
	}
	return share, .Ok
}

// Records a call that a change may end.
@(private)
service_begin :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, kind: Share_Kind, name: string, write, terminal: bool, data: rawptr, stop: proc(data: rawptr)) {
	c := new(Service_Call)
	c^ = {call, kind, from.device, scope, strings.clone(name), write, terminal, data, stop}
	append(&sp.services, c)
}

@(private)
service_end :: proc(sp: ^Space, call: u64) {
	for c, i in sp.services {
		if c.call == call {
			unordered_remove(&sp.services, i)
			delete(c.name)
			free(c)
			return
		}
	}
}

// Ends every call to a service that the shares, or the roster, no longer allow.
services_recheck :: proc(sp: ^Space) {
	for i := len(sp.services) - 1; i >= 0; i -= 1 {
		if i >= len(sp.services) {
			continue
		}
		c := sp.services[i]
		from := Caller{device = c.caller}
		if _, status := share_for(sp, from, c.scope, c.kind, c.name, c.write, c.terminal); status == .Ok {
			continue
		}
		audit(sp, {device = c.caller, scope = c.scope, service = "shell" if c.kind == .Shell else "files", detail = c.name, event = .Denied, peer = "no longer allowed"})
		call, data, stop := c.call, c.data, c.stop
		unordered_remove(&sp.services, i)
		delete(c.name)
		free(c)
		call_fault(sp, call, .Denied)
		stop(data)
	}
}

// ---------------------------------------------------------------- answers

// Begins an answer: its status, and for a failure the reason, and then the end of what this side says.
@(private)
status_send :: proc(sp: ^Space, call: u64, status: Status, reason := "", more: []byte = nil) {
	w := make([dynamic]byte, 0, 1 + len(reason) + len(more), context.temp_allocator)
	append(&w, u8(status))
	if status == .Ok {
		append(&w, ..more)
	} else {
		append(&w, reason)
	}
	call_send(sp, call, w[:])
	if status != .Ok {
		call_end(sp, call)
	}
}

// A handler for a call that has failed and only waits for the caller's end.
@(private)
refused_handler :: proc() -> ^Call_Handler {
	@(static) refused := Call_Handler {
		on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {return true},
	}
	return &refused
}

// What is offered to the caller in the scope of the call: services by kind, and ports, from whoever offers them.
//     service = 1 shell ‖ flags (1: 1 terminal, 2 commands) | 2 files ‖ flags (1: 1 read, 2 write) ‖ name bytes
//             | 3 tcp ‖ port (2) ‖ host bytes ‖ name bytes
@(private)
serve_services :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	w := make([dynamic]byte, context.temp_allocator)
	append(&w, u8(Status.Ok))
	for s in sp.shares {
		if s.scope != scope {
			continue
		}
		need := zsp.Right.Shell if s.kind == .Shell else zsp.Right.Files
		if from.local == nil && need not_in zsp.device_rights(&sp.node, from.device, scope) {
			continue
		}
		switch s.kind {
		case .Shell:
			append(&w, 1, (1 if s.terminal else 0) | (2 if s.commands else 0))
		case .Files:
			append(&w, 2, 1 | (2 if s.write else 0))
			zsp.write_bytes(&w, transmute([]byte)s.name)
		}
	}
	if offers := sp.host.ports_offered; offers != nil {
		for p in offers(sp, from, scope) {
			append(&w, 3, u8(p.port >> 8), u8(p.port))
			zsp.write_bytes(&w, transmute([]byte)p.host)
			zsp.write_bytes(&w, transmute([]byte)p.name)
		}
	}
	call_send(sp, call, w[:])
	call_end(sp, call)
	return refused_handler(), .Cancelled
}

// The shares themselves, for the device's own clients alone: an empty first message asks for them as text, any other
// is new shares to put in their place.
@(private)
serve_shares :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	if from.local == nil {
		return nil, .Denied
	}
	if len(first) == 0 {
		status_send(sp, call, .Ok, more = transmute([]byte)shares_text(sp.shares[:]))
		call_end(sp, call)
	} else if shares_set(sp, string(first)) {
		status_send(sp, call, .Ok)
		call_end(sp, call)
	} else {
		status_send(sp, call, .Malformed, "a share makes no sense")
	}
	return refused_handler(), .Cancelled
}

// A port someone offers, as zsp.services lists it.
Port_Offer :: struct {
	port: u16,
	host: string,
	name: string,
}

// What is left of a line after its first n words.
@(private)
after_words :: proc(line: string, n: int) -> string {
	rest := line
	for _ in 0 ..< n {
		rest = strings.trim_left_space(rest)
		end := strings.index_any(rest, " \t")
		if end < 0 {
			return ""
		}
		rest = rest[end:]
	}
	return rest
}
