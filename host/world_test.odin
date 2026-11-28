package host

import "core:crypto"
import "core:encoding/hex"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "../nbio"
import "../zsp"

// A relay and two devices, A and B, in one process and on one event loop, over loopback: the whole of the host,
// sockets and all, under a test's eye. A owns the space; both may call in scope 1.

@(private)
World :: struct {
	t:      ^testing.T,
	root:   string, // a directory of its own, removed after
	hosts:  [4]Host, // the relay, A, B, and a second relay if asked for
	space:  zsp.Key32,
	url:    string,
	urls:   [2]string,
	keys:   [4]zsp.Keyring,
	dirs:   [4]string,
	count:  int, // hosts
	dead:   [4]bool, // destroyed already
}

@(private)
world_init :: proc(t: ^testing.T, w: ^World, udp := true, grant_b: zsp.Rights = {.Read, .Write, .Call}, relays := 1, bare_b := false) -> bool {
	w.t = t
	w.count = 3 if relays == 1 else 4
	base, terr := os.temp_directory(context.temp_allocator)
	if terr != nil {
		return false
	}
	err: os.Error
	w.root, err = os.make_directory_temp(base, "zsp-world-*", context.allocator)
	if err != nil {
		return false
	}
	names := [4]string{"relay", "a", "b", "relay2"}
	dirs := &w.dirs
	for name, i in names[:w.count] {
		dirs[i], _ = filepath.join({w.root, name}) // the hosts keep them
		secret, ok := device_secret(dirs[i])
		if !ok {
			return false
		}
		zsp.keyring_init(&w.keys[i], secret)
	}
	root: zsp.Key32
	crypto.rand_bytes(root[:])
	w.space = zsp.ed25519_public(root)
	none: zsp.Roster
	d := zsp.draft_from(&none, now_ms() << 16)
	home := zsp.draft_scope(&d)
	zsp.draft_grant(&d, w.keys[1].device, w.keys[1].signer, home, {.Read, .Write, .Call}).owner = true
	zsp.draft_grant(&d, w.keys[2].device, w.keys[2].signer, home, grant_b)
	zsp.draft_scope(&d) // scope 2, which B has no part of
	roster, signed := zsp.roster_sign(&w.keys[1], root, &d, context.temp_allocator)
	if !signed {
		return false
	}
	name := string(hex.encode(w.space[:], context.temp_allocator))
	for i in 1 ..= 2 {
		dir, _ := filepath.join({dirs[i], name}, context.temp_allocator)
		os.make_directory_all(dir)
		if i != 2 || !bare_b { // b, bare, has joined: it has the space's id and its relay's, and no roster yet
			save(file_in(dir, "roster"), roster) or_return
		}
	}
	which := [2]int{0, 3}
	for i in which[:relays] {
		host_init(&w.hosts[i], {dir = dirs[i], relay = true, full = true, listen = net.Endpoint{net.IP4_Loopback, 0}}) or_return
		bound, _ := net.bound_endpoint(w.hosts[i].listener)
		w.urls[0 if i == 0 else 1] = strings.concatenate({"ws://", net.endpoint_to_string(bound, context.temp_allocator), "/", name})
	}
	w.url = w.urls[0]
	for i in 1 ..= 2 {
		config := Config{dir = dirs[i], full = true, listen = net.Endpoint{net.IP4_Loopback, 0}}
		if udp {
			config.udp_port = 0
		}
		host_init(&w.hosts[i], config) or_return
		if space_open(&w.hosts[i], w.space) == nil {
			return false
		}
		dial(&w.hosts[i], w.hosts[i].spaces[0], w.keys[0].device, w.urls[0])
		if relays > 1 {
			dial(&w.hosts[i], w.hosts[i].spaces[0], w.keys[3].device, w.urls[1])
		}
		dialers_refresh(&w.hosts[i])
	}
	return true
}

@(private)
world_destroy :: proc(w: ^World) {
	for i := w.count - 1; i >= 0; i -= 1 {
		if !w.dead[i] {
			host_destroy(&w.hosts[i])
		}
	}
	for &k in w.keys[:w.count] {
		zsp.keyring_destroy(&k)
	}
	os.remove_all(w.root)
	delete(w.root)
	for d in w.dirs {
		delete(d)
	}
	for u in w.urls {
		delete(u)
	}
}

@(private)
world_space :: proc(w: ^World, i: int) -> ^Space {
	return w.hosts[i].spaces[0]
}

// Runs every host until `done` says so, or the time is up. Returns whether it was done.
@(private)
world_run :: proc(w: ^World, done: proc(w: ^World, data: rawptr) -> bool, data: rawptr = nil, within := 20 * time.Second) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < within {
		for &h, i in w.hosts[:w.count] {
			if !w.dead[i] {
				host_settle(&h)
			}
		}
		if done(w, data) {
			return true
		}
		wait := 20 * time.Millisecond
		for &h, i in w.hosts[:w.count] {
			if w.dead[i] {
				continue
			}
			if due, ok := host_deadline(&h); ok {
				wait = min(wait, max(time.tick_diff(time.tick_now(), due), 0))
			}
		}
		if err := nbio.tick(wait); err != nil {
			return false
		}
		free_all(context.temp_allocator)
	}
	return false
}

// A and B can call each other, directly or through the relay.
@(private)
world_ready :: proc(w: ^World, direct: bool) -> bool {
	direct := direct
	return world_run(w, proc(w: ^World, data: rawptr) -> bool {
		direct := (^bool)(data)^
		a, b := world_space(w, 1), world_space(w, 2)
		for s in ([]^Space{a, b}) {
			other := w.keys[2 if s == a else 1].device
			found := false
			for session in s.node.sessions {
				if !session.ready {
					continue
				}
				if direct {
					found ||= session.peer == other && !session.peer_relay && session.role == .Peer
				} else {
					found ||= session.peer_relay && len(session.online) > 0
				}
			}
			if !found {
				return false
			}
		}
		return true
	}, &direct)
}

// ---------------------------------------------------------------- a service on calls, and a caller that fills it

// Calls whose end is a host, and calls, no longer under way on A or B.
@(private)
nobody_left :: proc(w: ^World, _: rawptr) -> bool {
	return len(world_space(w, 1).calls) + len(world_space(w, 2).calls) + len(world_space(w, 1).node.calls) + len(world_space(w, 2).node.calls) == 0
}

// B's end of "echo": says back whatever it is told, as fast as credit allows, and credits what it is told only once it
// has said it back, so that a caller that does not read holds the echo up, and the echo the caller, and nothing piles up.
@(private)
Echoer :: struct {
	using handler: Call_Handler,
	sp:       ^Space,
	call:     u64,
	held:     [dynamic]byte, // told, not yet said back
	owed:     int, // of that, credit not yet given
	heard_end: bool,
}

@(private)
echo_serve :: proc(h: ^Host) {
	host_serve(h, "echo", proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
		e := new(Echoer)
		e.sp, e.call, e.data = sp, call, e
		append(&e.held, ..first) // the first message is credited as it is taken
		e.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
			e := (^Echoer)(h.data)
			append(&e.held, ..bytes)
			e.owed += len(bytes)
			echoer_flush(e)
			return false
		}
		e.on_room = proc(h: ^Call_Handler, call: u64) {echoer_flush((^Echoer)(h.data))}
		e.on_end = proc(h: ^Call_Handler, call: u64) {
			e := (^Echoer)(h.data)
			e.heard_end = true
			echoer_flush(e)
		}
		e.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {echoer_free((^Echoer)(h.data))}
		echoer_flush(e)
		return e, .Cancelled
	})
}

@(private)
echoer_flush :: proc(e: ^Echoer) {
	sent := 0
	for sent < len(e.held) {
		n := min(len(e.held) - sent, call_room(e.sp, e.call), 64 << 10)
		if n <= 0 || !call_send(e.sp, e.call, e.held[sent:][:n]) {
			break
		}
		sent += n
	}
	remove_range(&e.held, 0, sent)
	if credit := min(sent, e.owed); credit > 0 {
		e.owed -= credit
		call_consumed(e.sp, e.call, credit)
	}
	if e.heard_end && len(e.held) == 0 {
		call_end(e.sp, e.call) // over for both, so nothing more is said to it
		echoer_free(e)
	}
}

@(private)
echoer_free :: proc(e: ^Echoer) {
	delete(e.held)
	free(e)
}

// A's end: sends `total` bytes of a pattern as credit allows, then ends, and checks what comes back byte for byte.
@(private)
Pump :: struct {
	using handler: Call_Handler,
	sp:      ^Space,
	call:    u64,
	total:   int,
	sent:    int,
	got:     int,
	wrong:   bool, // something came back that was not what was sent
	ended:   bool, // the other side has said all
	faulted: bool,
	fault:   zsp.Call_Fault,
}

@(private)
pump_byte :: proc(i: int) -> byte {
	return byte(i * 7 + i / 251)
}

// Begins a pump of `total` bytes from A to "echo" at B. False if the call cannot be made.
@(private)
pump_start :: proc(p: ^Pump, w: ^World, total: int, urgency: u8 = zsp.URGENCY) -> bool {
	p.sp, p.total, p.data = world_space(w, 1), total, p
	p.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		p := (^Pump)(h.data)
		for b in bytes {
			p.wrong ||= b != pump_byte(p.got)
			p.got += 1
		}
		return true
	}
	p.on_room = proc(h: ^Call_Handler, call: u64) {pump_fill((^Pump)(h.data))}
	p.on_end = proc(h: ^Call_Handler, call: u64) {
		p := (^Pump)(h.data)
		p.ended = true
		if p.sent == p.total {
			call_end(p.sp, p.call)
		}
	}
	p.on_fault = proc(h: ^Call_Handler, call: u64, fault: zsp.Call_Fault) {
		p := (^Pump)(h.data)
		p.faulted, p.fault = true, fault
	}
	p.call = host_call(p.sp, w.keys[2].device, 1, "echo", nil, &p.handler, urgency)
	if p.call == 0 {
		return false
	}
	pump_fill(p)
	return true
}

@(private)
pump_fill :: proc(p: ^Pump) {
	buf: [32 << 10]byte
	for p.sent < p.total && !p.faulted {
		n := min(p.total - p.sent, call_room(p.sp, p.call), len(buf))
		if n <= 0 {
			return
		}
		for i in 0 ..< n {
			buf[i] = pump_byte(p.sent + i)
		}
		if !call_send(p.sp, p.call, buf[:n]) {
			return
		}
		p.sent += n
	}
	if p.sent == p.total && !p.faulted {
		call_end(p.sp, p.call)
	}
}

// Whether a pump is over: all of it back, as it was, and both sides done; or failed.
@(private)
pump_done :: proc(w: ^World, data: rawptr) -> bool {
	p := (^Pump)(data)
	return p.faulted || p.ended && p.got == p.total
}

@(private)
pump_whole :: proc(p: ^Pump) -> bool {
	return !p.faulted && !p.wrong && p.ended && p.got == p.total && p.sent == p.total
}

// A relay goes, as a process that dies does: every connection to it closed at once.
@(private)
world_kill :: proc(w: ^World, i: int) {
	w.dead[i] = true
	host_destroy(&w.hosts[i])
}
