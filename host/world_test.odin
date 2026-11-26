package host

import "core:crypto"
import "core:encoding/hex"
import "core:nbio"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../zsp"

// A relay and two devices, A and B, in one process and on one event loop, over loopback: the whole of the host,
// sockets and all, under a test's eye. A owns the space; both may call, run and reach files in scope 1.

@(private)
World :: struct {
	t:      ^testing.T,
	root:   string, // a directory of its own, removed after
	hosts:  [3]Host, // the relay, A, B
	space:  zsp.Key32,
	url:    string,
	keys:   [3]zsp.Keyring,
	dirs:   [3]string,
}

@(private)
world_init :: proc(t: ^testing.T, w: ^World, udp := true, grant_b: zsp.Rights = {.Read, .Write, .Call, .Shell, .Files}) -> bool {
	w.t = t
	base, terr := os.temp_directory(context.temp_allocator)
	if terr != nil {
		return false
	}
	err: os.Error
	w.root, err = os.make_directory_temp(base, "zsp-world-*", context.allocator)
	if err != nil {
		return false
	}
	names := [3]string{"relay", "a", "b"}
	dirs := &w.dirs
	for name, i in names {
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
	zsp.draft_grant(&d, w.keys[1].device, w.keys[1].signer, home, {.Read, .Write, .Call, .Shell, .Files}).owner = true
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
		save(file_in(dir, "roster"), roster) or_return
	}
	host_init(&w.hosts[0], {dir = dirs[0], relay = true, full = true, listen = net.Endpoint{net.IP4_Loopback, 0}}) or_return
	bound, _ := net.bound_endpoint(w.hosts[0].listener)
	w.url = strings.concatenate({"ws://", net.endpoint_to_string(bound, context.temp_allocator), "/", name})
	for i in 1 ..= 2 {
		config := Config{dir = dirs[i], full = true, listen = net.Endpoint{net.IP4_Loopback, 0}}
		if udp {
			config.udp_port = 0
		}
		host_init(&w.hosts[i], config) or_return
		if space_open(&w.hosts[i], w.space) == nil {
			return false
		}
		dial(&w.hosts[i], w.hosts[i].spaces[0], w.keys[0].device, w.url)
		dialers_refresh(&w.hosts[i])
	}
	return true
}

@(private)
world_destroy :: proc(w: ^World) {
	for i := 2; i >= 0; i -= 1 {
		host_destroy(&w.hosts[i])
	}
	for &k in w.keys {
		zsp.keyring_destroy(&k)
	}
	os.remove_all(w.root)
	delete(w.root)
	for d in w.dirs {
		delete(d)
	}
	delete(w.url)
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
		for &h in w.hosts {
			host_settle(&h)
		}
		if done(w, data) {
			return true
		}
		wait := 20 * time.Millisecond
		for &h in w.hosts {
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

// ---------------------------------------------------------------- a TCP service to reach, on a thread of its own

@(private)
Echo :: struct {
	listener: net.TCP_Socket,
	port:     int,
	thread:   ^thread.Thread,
	accepted: i32, // atomic
	read:     i64, // atomic; bytes
	stalled:  bool, // reads nothing: a reader that never reads
	stop:     bool, // atomic
}

// Echoes whatever each connection says until it says no more, then says no more itself.
@(private)
echo_start :: proc(e: ^Echo, stalled := false) -> bool {
	listener, err := net.listen_tcp({net.IP4_Loopback, 0})
	if err != nil {
		return false
	}
	e.listener = listener
	bound, _ := net.bound_endpoint(listener)
	e.port = bound.port
	e.stalled = stalled
	e.thread = thread.create_and_start_with_poly_data(e, proc(e: ^Echo) {
		for !sync.atomic_load(&e.stop) {
			client, _, err := net.accept_tcp(e.listener)
			if err != nil {
				return
			}
			if sync.atomic_load(&e.stop) {
				net.close(client)
				return
			}
			sync.atomic_add(&e.accepted, 1)
			// A reset that comes while nothing can be sent may be heard late: so a send gives up, now and then,
			// to see whether the test is over.
			net.set_option(client, .Send_Timeout, 200 * time.Millisecond)
			if e.stalled {
				for !sync.atomic_load(&e.stop) {
					time.sleep(10 * time.Millisecond)
				}
				net.close(client)
				return
			}
			buf: [32 << 10]byte
			for {
				n, rerr := net.recv_tcp(client, buf[:])
				if rerr != nil || n == 0 {
					break
				}
				sync.atomic_add(&e.read, i64(n))
				for sent := 0; sent < n && !sync.atomic_load(&e.stop); {
					m, serr := net.send_tcp(client, buf[sent:n])
					sent += m
					if serr != nil && serr != .Timeout && serr != .Would_Block {
						break
					}
				}
				if sync.atomic_load(&e.stop) {
					break
				}
			}
			net.shutdown(client, .Send)
			net.close(client)
		}
	})
	return true
}

@(private)
echo_stop :: proc(e: ^Echo) {
	sync.atomic_store(&e.stop, true)
	// Wake an accept that may still be waiting: closing the listener would not, everywhere.
	if s, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, e.port}); err == nil {
		net.close(s)
	}
	thread.join(e.thread)
	thread.destroy(e.thread)
	net.close(e.listener)
}
