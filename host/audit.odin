package host

import "core:encoding/hex"
import "core:os"
import "core:strings"
import "core:time"
import "../zsp"

// Who opened what on this device, and how it went: one JSON object a line, in `audit.log` in the space's directory.
// What passed through is never written down, only how much of it. A log that grows past AUDIT_MOST is set aside as
// audit.log.1, the one before that let go.

AUDIT_MOST :: 16 << 20

Audit_Event :: enum u8 {
	Open,
	Close,
	Denied,
	Change, // of what is offered, or to whom
}

Audit :: struct {
	device:    zsp.Key32, // who
	subject:   string, // for whom, as the roster or the device vouching says
	scope:     zsp.Scope,
	service:   string, // tcp, exec, pty, files, …
	detail:    string, // what of it: a port, a command, a path
	event:     Audit_Event,
	bytes_in, bytes_out: u64, // to the device, from it
	peer:      string, // anything else worth knowing: a public client's address, why it ended
}

@(private)
Audit_Log :: struct {
	file:  ^os.File,
	size:  i64,
}

AUDIT_FIELD :: 1024 // the most of any one field written, in bytes: a path, a command, a reason

// Writes down one thing that happened. Failing to is reported, and does not stop what was audited.
audit :: proc(sp: ^Space, a: Audit) {
	if sp == nil || sp.dir == "" {
		return
	}
	log := &sp.audit
	if log.file == nil && !audit_open(sp, false) {
		return
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"at":`)
	strings.write_i64(&b, time.time_to_unix_nano(time.now()) / 1_000_000)
	strings.write_string(&b, `,"event":"`)
	events := [Audit_Event]string{.Open = "open", .Close = "close", .Denied = "denied", .Change = "change"}
	strings.write_string(&b, events[a.event])
	strings.write_string(&b, `","device":"`)
	device := a.device
	strings.write_string(&b, string(hex.encode(device[:], context.temp_allocator)))
	strings.write_string(&b, `","scope":`)
	strings.write_u64(&b, u64(a.scope))
	json_field(&b, "subject", a.subject)
	json_field(&b, "service", a.service)
	json_field(&b, "detail", a.detail)
	json_field(&b, "peer", a.peer)
	if a.event == .Close {
		strings.write_string(&b, `,"in":`)
		strings.write_u64(&b, a.bytes_in)
		strings.write_string(&b, `,"out":`)
		strings.write_u64(&b, a.bytes_out)
	}
	strings.write_string(&b, "}\n")
	line := strings.to_string(b)
	if log.size + i64(len(line)) > AUDIT_MOST {
		// Set aside, the one before let go; or if it cannot be, begun again rather than grown without end.
		audit_close(sp)
		path := file_in(sp.dir, "audit.log")
		aside := path_with(path, ".1")
		os.remove(aside)
		begin := os.rename(path, aside) != nil
		if begin {
			report(.Warning, "cannot set the audit log aside; it begins again")
		}
		if !audit_open(sp, begin) {
			return
		}
	}
	if _, err := os.write(log.file, transmute([]byte)line); err != nil {
		report(.Warning, "cannot write the audit log")
		return
	}
	log.size += i64(len(line))
}

@(private)
audit_open :: proc(sp: ^Space, empty: bool) -> bool {
	flags := os.File_Flags{.Write, .Create, .Append}
	if empty {
		flags += {.Trunc}
	}
	f, err := os.open(file_in(sp.dir, "audit.log"), flags, os.Permissions{.Read_User, .Write_User})
	if err != nil {
		report(.Warning, "cannot write the audit log")
		return false
	}
	sp.audit.file = f
	sp.audit.size, _ = os.file_size(f)
	return true
}

@(private)
audit_close :: proc(sp: ^Space) {
	if sp.audit.file != nil {
		os.close(sp.audit.file)
		sp.audit = {}
	}
}

@(private)
json_field :: proc(b: ^strings.Builder, name, value: string) {
	if value == "" {
		return
	}
	strings.write_string(b, `,"`)
	strings.write_string(b, name)
	strings.write_string(b, `":`)
	if len(value) > AUDIT_FIELD {
		json_string(b, strings.concatenate({value[:AUDIT_FIELD], "…"}, context.temp_allocator))
	} else {
		json_string(b, value)
	}
}

// A string as JSON has it, whatever bytes it holds: what is not UTF-8 is written as the code points of its bytes.
json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for i := 0; i < len(s); {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			strings.write_byte(b, '\\')
			strings.write_byte(b, c)
			i += 1
		case c < 0x20 || c == 0x7f:
			digits := "0123456789abcdef"
			strings.write_string(b, `\u00`)
			strings.write_byte(b, digits[c >> 4])
			strings.write_byte(b, digits[c & 15])
			i += 1
		case c < 0x80:
			strings.write_byte(b, c)
			i += 1
		case:
			r, size := utf8_decode(s[i:])
			if r < 0 {
				digits := "0123456789abcdef"
				strings.write_string(b, `\u00`)
				strings.write_byte(b, digits[c >> 4])
				strings.write_byte(b, digits[c & 15])
				i += 1
			} else {
				strings.write_string(b, s[i:][:size])
				i += size
			}
		}
	}
	strings.write_byte(b, '"')
}

@(private)
utf8_decode :: proc(s: string) -> (r: rune, size: int) {
	c := s[0]
	need: int
	switch {
	case c & 0xe0 == 0xc0:
		need, r = 2, rune(c & 0x1f)
	case c & 0xf0 == 0xe0:
		need, r = 3, rune(c & 0x0f)
	case c & 0xf8 == 0xf0:
		need, r = 4, rune(c & 0x07)
	case:
		return -1, 1
	}
	if len(s) < need {
		return -1, 1
	}
	for i in 1 ..< need {
		if s[i] & 0xc0 != 0x80 {
			return -1, 1
		}
		r = r << 6 | rune(s[i] & 0x3f)
	}
	least := [5]rune{0, 0, 0x80, 0x800, 0x10000}
	if r < least[need] || r > 0x10ffff || (r >= 0xd800 && r <= 0xdfff) {
		return -1, 1
	}
	return r, need
}
