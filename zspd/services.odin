package main

import "core:os"
import "core:strconv"
import "core:strings"
import "../host"
import "../zsp"

// What a device lets others do on it (§16), asked of it from here: by the node running here, as a local client, on
// behalf of whoever runs these commands. Shares are said with zspd's `share`; what another device offers this one,
// with `services`; and the rest, in remote.odin and files.odin, use what is offered.

// A command's line: words, and the options it allows.
Command_Line :: struct {
	words:   [dynamic]string,
	scope:   zsp.Scope,
	cwd:     string,
	env:     [dynamic]string,
	replace: bool,
	argv:    []string, // after `--`, or after the words a command wants
}

Command_Option :: enum {
	Scope,
	Cwd,
	Env,
	Replace,
	Argv, // the words after `want` are a command's arguments
}

// Parses what follows `<dir>`. False if anything is not what the command takes.
command_line :: proc(args: []string, allowed: bit_set[Command_Option], want: int) -> (line: Command_Line, ok: bool) {
	line.scope = 1
	line.words = make([dynamic]string, context.temp_allocator)
	line.env = make([dynamic]string, context.temp_allocator)
	for a, i in args {
		if a == "--" && .Argv in allowed {
			line.argv = args[i + 1:]
			return line, true
		}
		if !strings.has_prefix(a, "--") || a == "--" {
			if .Argv in allowed && len(line.words) == want {
				line.argv = args[i:]
				return line, true
			}
			append(&line.words, a)
			continue
		}
		name, value := a, ""
		if eq := strings.index_byte(a, '='); eq >= 0 {
			name, value = a[:eq], a[eq + 1:]
		}
		switch {
		case name == "--scope" && .Scope in allowed:
			scope, parsed := strconv.parse_u64(value)
			if !parsed || scope == 0 || scope >= 1 << 32 {
				return
			}
			line.scope = zsp.Scope(scope)
		case name == "--cwd" && .Cwd in allowed:
			line.cwd = value
		case name == "--env" && .Env in allowed && value != "":
			append(&line.env, value)
		case a == "--replace" && .Replace in allowed:
			line.replace = true
		case a == "--verbose":
		case:
			return
		}
	}
	return line, true
}

// The device a name names: its key in hex (the device's 64 digits, or the device's and signer's 128, as `members`
// prints them), a start of that unique among members, or whose it is, as the roster says. Says why not, if not.
device_named :: proc(dir, name: string) -> (device: zsp.Key32, ok: bool) {
	space, folder, have := read_space(dir)
	if !have {
		say(os.stderr, "no space here: create or join one first\n")
		return
	}
	data, err := os.read_entire_file(in_dir(in_dir(dir, folder), "roster"), context.temp_allocator)
	roster: zsp.Roster
	sound := false
	if err == nil {
		roster, sound = zsp.roster_parse(data, space)
	}
	if !sound {
		say(os.stderr, "this device has no roster yet: run it, and let it hear from the space\n")
		return
	}
	defer zsp.roster_destroy(&roster)
	if name == "" {
		say(os.stderr, "no device is called nothing\n")
		return
	}
	lower := strings.to_lower(name, context.temp_allocator)
	hexed := len(lower) > 0 && len(lower) <= 128
	for ch in lower {
		hexed &&= (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f')
	}
	found := 0
	for &m in roster.members {
		if !zsp.member_active(&m) {
			continue
		}
		key := strings.concatenate({to_hex(m.device[:]), to_hex(m.signer[:])}, context.temp_allocator)
		if (hexed && strings.has_prefix(key, lower)) || string(m.subject) == name {
			if found == 0 || m.device != device {
				found += 1
			}
			device = m.device
		}
	}
	switch found {
	case 0:
		say(os.stderr, "no device of the space is called ", name, "\n")
		return
	case 1:
		return device, true
	}
	say(os.stderr, name, " could be more than one device: say more of its key\n")
	return {}, false
}

// What a status says, in words.
status_text :: proc(s: host.Status) -> string {
	switch s {
	case .Ok:
		return "ok"
	case .Denied:
		return "denied"
	case .Not_Offered:
		return "not offered"
	case .Refused:
		return "refused"
	case .Unreachable:
		return "unreachable"
	case .Timed_Out:
		return "timed out"
	case .Not_Found:
		return "not found"
	case .Failed:
		return "failed"
	case .Changed:
		return "changed while it was being sent"
	case .Exists:
		return "there already"
	case .Malformed:
		return "not understood"
	}
	return "failed"
}

// What a fault says, in words.
fault_text :: proc(f: zsp.Call_Fault) -> string {
	switch f {
	case .Cancelled:
		return "cancelled"
	case .Denied:
		return "denied: both devices need Call in the scope, and this one Shell or Files for what is shared"
	case .Unreachable:
		return "unreachable"
	case .Unserved:
		return "not served there"
	case .Lost:
		return "lost: it may or may not have happened"
	case .Overrun:
		return "overrun"
	case .Busy:
		return "busy"
	}
	return "failed"
}

// A status and its reason, as a failure is said: "denied", or "failed: no such file".
status_said :: proc(reply: []byte) -> string {
	if len(reply) == 0 {
		return "said nothing"
	}
	text := status_text(host.Status(reply[0]))
	if len(reply) > 1 {
		return strings.concatenate({text, ": ", string(reply[1:])}, context.temp_allocator)
	}
	return text
}

// ---------------------------------------------------------------- one question, one answer

// A call whose answer is all its messages, then the end: zsp.services, zsp.share and zsp.list.
Ask :: struct {
	using handler: host.Call_Handler,
	c:       ^Client,
	call:    u64,
	replies: [dynamic][]byte, // each message, owned
	fault:   Maybe(zsp.Call_Fault),
	done:    proc(a: ^Ask), // once it is over, whichever way
	job:     rawptr,
}

ask :: proc(c: ^Client, device: zsp.Key32, scope: zsp.Scope, method: string, first: []byte, done: proc(a: ^Ask), job: rawptr = nil) -> ^Ask {
	a := new(Ask)
	a.c, a.done, a.job = c, done, job
	a.data = a
	a.on_data = proc(h: ^host.Call_Handler, call: u64, bytes: []byte) -> bool {
		a := (^Ask)(h.data)
		reply := make([]byte, len(bytes))
		copy(reply, bytes)
		append(&a.replies, reply)
		return true
	}
	a.on_end = proc(h: ^host.Call_Handler, call: u64) {
		a := (^Ask)(h.data)
		client_end(a.c, call)
		a.done(a)
	}
	a.on_fault = proc(h: ^host.Call_Handler, call: u64, fault: zsp.Call_Fault) {
		a := (^Ask)(h.data)
		a.fault = fault
		a.done(a)
	}
	a.call = client_call(c, device, scope, method, first, &a.handler)
	if a.call == 0 {
		a.fault = .Unreachable
		a.done(a)
		return nil
	}
	client_end(c, a.call) // nothing more to say
	return a
}

ask_free :: proc(a: ^Ask) {
	for r in a.replies {
		delete(r)
	}
	delete(a.replies)
	free(a)
}

// Why an answer failed, or "" if it did not: a fault, a status, or nothing said at all.
ask_failure :: proc(a: ^Ask) -> string {
	if f, faulted := a.fault.?; faulted {
		return fault_text(f)
	}
	if len(a.replies) == 0 {
		return "said nothing"
	}
	if host.Status(a.replies[0][0] if len(a.replies[0]) > 0 else u8(host.Status.Malformed)) != .Ok {
		return status_said(a.replies[0])
	}
	return ""
}

// ---------------------------------------------------------------- services

@(private = "file")
One_Answer :: struct {
	device: zsp.Key32,
	scope:  zsp.Scope,
	method: string,
	first:  []byte,
	ok:     bool,
	print:  proc(a: ^Ask) -> bool,
}

// Makes one call, waits for all it says, and prints it.
@(private = "file")
one_answer :: proc(dir: string, job: ^One_Answer) -> int {
	c := new(Client)
	defer free(c)
	c.data, c.target = job, job.device
	c.begin = proc(c: ^Client) {
		job := (^One_Answer)(c.data)
		scope := job.scope
		if scope == 0 {
			// The device's own, in any scope it may call in.
			for s in c.scopes {
				if .Call in s.rights {
					scope = s.scope
					break
				}
			}
		}
		ask(c, job.device, scope, job.method, job.first, proc(a: ^Ask) {
			job := (^One_Answer)(a.c.data)
			if why := ask_failure(a); why != "" {
				say(os.stderr, why, "\n")
			} else {
				job.ok = job.print(a)
			}
			client_stop(a.c)
			ask_free(a)
		})
	}
	if !client_open(c, dir) {
		say(os.stderr, c.failure, "\n")
		return 1
	}
	if !client_run(c) {
		say(os.stderr, c.failure, "\n")
		return 1
	}
	return 0 if job.ok else 1
}

// zspd services <dir> <device> [--scope=N]: what a device offers this one, a line each, as `share` would say it.
services :: proc(dir: string, args: []string) -> int {
	line, ok := command_line(args, {.Scope}, 1)
	if !ok || len(line.words) != 1 {
		return usage()
	}
	device, found := device_named(dir, line.words[0])
	if !found {
		return 1
	}
	job := One_Answer{device = device, scope = line.scope, method = "zsp.services"}
	job.print = proc(a: ^Ask) -> bool {
		b := strings.builder_make(context.temp_allocator)
		for reply, i in a.replies {
			r := zsp.Reader{buf = reply[1:] if i == 0 else reply}
			for r.pos < len(r.buf) {
				switch zsp.read_u8(&r) {
				case 1:
					flags := zsp.read_u8(&r)
					strings.write_string(&b, "shell")
					strings.write_string(&b, " terminal" if flags & 1 != 0 else "")
					strings.write_string(&b, " commands" if flags & 2 != 0 else "")
				case 2:
					flags := zsp.read_u8(&r)
					name := zsp.read_bytes(&r)
					strings.write_string(&b, "files ")
					strings.write_string(&b, string(name))
					strings.write_string(&b, " write" if flags & 2 != 0 else " read")
				case 3:
					at := zsp.read_take(&r, 2)
					port := u16(at[0]) << 8 | u16(at[1]) if len(at) == 2 else 0
					target := zsp.read_bytes(&r)
					name := zsp.read_bytes(&r)
					strings.write_string(&b, "tcp ")
					strings.write_u64(&b, u64(port))
					strings.write_string(&b, " ")
					strings.write_string(&b, string(target) if len(target) > 0 else "localhost")
					strings.write_string(&b, " ")
					strings.write_string(&b, string(name))
				case:
					r.bad = true
				}
				if r.bad {
					say(os.stderr, "what it offers makes no sense\n")
					return false
				}
				strings.write_byte(&b, '\n')
			}
		}
		say(os.stdout, strings.to_string(b))
		return true
	}
	return one_answer(dir, &job)
}

// zspd share <dir> [line ...]: what this device shares, or, given lines, that instead (zsp.share). An empty line
// alone shares nothing.
share :: proc(dir: string, args: []string) -> int {
	secret, have := host.device_secret(dir)
	if !have {
		say(os.stderr, "no device here\n")
		return 1
	}
	job := One_Answer{device = zsp.x25519_public(secret), method = "zsp.share"}
	if len(args) > 0 {
		b := strings.builder_make(context.temp_allocator)
		for a in args {
			strings.write_string(&b, a)
			strings.write_byte(&b, '\n')
		}
		job.first = transmute([]byte)strings.clone(strings.to_string(b)) // kept past the loop's turns, which free what is temporary
	}
	job.print = proc(a: ^Ask) -> bool {
		reply := a.replies[0]
		say(os.stdout, string(reply[1:]))
		return true
	}
	return one_answer(dir, &job)
}

usage :: proc() -> int {
	os.write_string(os.stderr, USAGE)
	return 2
}
