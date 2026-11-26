package host

import "core:encoding/endian"
import win "core:sys/windows"
import "../pipe"

// What the system says of TCP sockets, through the IP helper (GetExtendedTcpTable), which anyone may ask: which are
// listening, and which process owns a connected one, and so whose it is. It is asked when there is a question, never
// on a clock.

foreign import iphlpapi "system:Iphlpapi.lib"
foreign import advapi32 "system:Advapi32.lib"

@(default_calling_convention = "system", private = "file")
foreign iphlpapi {
	GetExtendedTcpTable :: proc(table: rawptr, size: ^u32, order: win.BOOL, family: u32, class: i32, reserved: u32) -> u32 ---
}

@(default_calling_convention = "system", private = "file")
foreign advapi32 {
	GetLengthSid :: proc(sid: rawptr) -> u32 ---
}

@(private = "file")
TCP_TABLE_OWNER_PID_ALL :: 5
@(private = "file")
LISTEN :: 2
@(private = "file")
ERROR_INSUFFICIENT_BUFFER :: 122

@(private = "file")
Tcp_Entry :: struct {
	local, remote: pipe.Address,
	pid:           u32,
	listening:     bool,
}

@(private = "file")
tcp_entries :: proc() -> (out: [dynamic]Tcp_Entry, ok: bool) {
	out = make([dynamic]Tcp_Entry, context.temp_allocator)
	for family in ([]u32{2, 23}) {
		size: u32
		buf: []byte
		for _ in 0 ..< 4 {
			result := GetExtendedTcpTable(raw_data(buf), &size, false, family, TCP_TABLE_OWNER_PID_ALL, 0)
			if result == 0 {
				break
			}
			if result != ERROR_INSUFFICIENT_BUFFER {
				return
			}
			size += size / 4 + 1024 // room for sockets made meanwhile
			buf = make([]byte, size, context.temp_allocator)
		}
		if len(buf) < 4 {
			continue // none of this family
		}
		count := int(endian.unchecked_get_u32le(buf))
		row := 24 if family == 2 else 56
		if 4 + count * row > len(buf) {
			return
		}
		for i in 0 ..< count {
			r := buf[4 + i * row:]
			e: Tcp_Entry
			if family == 2 {
				e.listening = endian.unchecked_get_u32le(r) == LISTEN
				e.local = pipe.address_v4(r[4], r[5], r[6], r[7], endian.unchecked_get_u16be(r[8:]))
				e.remote = pipe.address_v4(r[12], r[13], r[14], r[15], endian.unchecked_get_u16be(r[16:]))
				e.pid = endian.unchecked_get_u32le(r[20:])
			} else {
				copy(e.local.ip[:], r[0:16])
				e.local.port = endian.unchecked_get_u16be(r[20:])
				copy(e.remote.ip[:], r[24:40])
				e.remote.port = endian.unchecked_get_u16be(r[44:])
				e.listening = endian.unchecked_get_u32le(r[48:]) == LISTEN
				e.pid = endian.unchecked_get_u32le(r[52:])
			}
			append(&out, e)
		}
	}
	return out, true
}

// Every address some socket listens at, in temporary memory.
@(private, require_results)
tcp_listening :: proc() -> (list: []pipe.Address, ok: bool) {
	all := tcp_entries() or_return
	out := make([dynamic]pipe.Address, context.temp_allocator)
	for e in all {
		if e.listening {
			append(&out, e.local)
		}
	}
	return out[:], true
}

// The user a process runs as, in temporary memory; nil if it cannot be told, as for another user's.
@(private = "file")
process_user :: proc(process: win.HANDLE) -> []byte {
	token: win.HANDLE
	if !win.OpenProcessToken(process, win.TOKEN_QUERY, &token) {
		return nil
	}
	defer win.CloseHandle(token)
	size: u32
	win.GetTokenInformation(token, .TokenUser, nil, 0, &size)
	if size == 0 {
		return nil
	}
	buf := make([]byte, size, context.temp_allocator)
	if !win.GetTokenInformation(token, .TokenUser, raw_data(buf), size, &size) {
		return nil
	}
	sid := (^win.TOKEN_USER)(raw_data(buf)).User.Sid
	out := make([]byte, GetLengthSid(sid), context.temp_allocator)
	copy(out, ([^]byte)(sid)[:len(out)])
	return out
}

// Whether the socket that connected from `remote` to our `local`, on this machine, is this user's, or the system's:
// nobody else on the machine may borrow what this device may reach.
@(private, require_results)
tcp_peer_is_mine :: proc(local, remote: pipe.Address) -> bool {
	all, ok := tcp_entries()
	if !ok {
		return false
	}
	for e in all {
		if e.listening || e.local != remote || e.remote != local {
			continue
		}
		if e.pid == win.GetCurrentProcessId() {
			return true
		}
		process := win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, false, e.pid)
		if process == nil {
			return false // not ours to look into: not ours
		}
		defer win.CloseHandle(process)
		theirs, mine := process_user(process), process_user(win.GetCurrentProcess())
		SYSTEM := []byte{1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0} // S-1-5-18
		return theirs != nil && mine != nil && (string(theirs) == string(mine) || string(theirs) == string(SYSTEM))
	}
	return false
}
