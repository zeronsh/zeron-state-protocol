/*
A service built on ZSP's calls, outside package host: TCP forwarding between devices. It is a node in its own right,
embedding the host, so the service's bytes go straight between its sockets and its calls, and never through a local
client's pipe. Run it in place of `zspd run`, on a device of a space that zspd made or joined:

	forward <dir> [--allow=<host:port>]... [--connect=<port>/<device>/<host:port>]... [options]

	--allow=<host:port>   answer "forward" calls for this address, connecting to it from this machine
	--connect=<port>/<device>/<host:port>
	                      listen at 127.0.0.1:<port> (0 for any); each connection is a "forward" call to the device,
	                      joined to <host:port> as the device reaches it, if the device allows it
	--scope=N             call and be called in this scope (1); the roster says who may: whoever has Call there
	--urgency=N           of each call's stream, 0 the most urgent and 7 the least (3): a terminal wants 1, a bulk copy 6
	--no-udp              make no direct links: calls go through the relay
	--verbose

A call's first message is where to, "host:port"; then its messages are the connection's bytes, End a half-close, and a
cancel a reset, both ways. Nothing is read from a socket that the call has no credit for, and the call is credited only
as the socket takes what came: so a slow end slows the other, and nothing piles up between them however fast the other
end is. Everything happens on the host's one thread, in its event loop; between events the process sleeps.

The roster has already said that the caller and this device may call in the scope by the time `serve_forward` hears
of a call; this service asks besides whether it was told to allow the address, and a real one might ask for whom the
call is (Caller.who).
*/
package main

import "base:runtime"
import "core:encoding/hex"
import "core:fmt"
import "core:nbio"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"
import "../../host"
import "../../zsp"

METHOD :: "forward"
READ :: 32 << 10 // a socket is read this much at most at once, and never more than the call has credit for
DIAL_WAIT :: 15 * time.Second
ACCEPT_AGAIN :: 100 * time.Millisecond // after an accept fails, as when no more files may be open

Forward :: struct {
	scope:   zsp.Scope,
	urgency: u8,
	allowed: [dynamic]net.Endpoint, // where calls may be joined to
	space:   ^host.Space,
}

// Where connections accepted here go.
Connect :: struct {
	at:        net.Endpoint,
	listener:  net.TCP_Socket,
	listening: bool,
	accepting: ^nbio.Operation, // an accept, or the wait before trying again
	device:    zsp.Key32,
	to:        string, // host:port, as the device reaches it
}

forward: Forward

// A call joined to a TCP connection.
Join :: struct {
	using handler: host.Call_Handler,
	sp:        ^host.Space,
	call:      u64,
	socket:    net.TCP_Socket,
	connected: bool,
	closed:    bool, // the socket is, already
	dialling:  ^nbio.Operation,
	reading:   ^nbio.Operation,
	writing:   ^nbio.Operation,
	buf:       [READ]byte, // what the socket said, as it is read; it is in the call before it is read again
	out:       [dynamic]byte, // what the call said, for the socket, not yet handed to it
	sending:   [dynamic]byte, // what the socket has been handed and not yet taken: left alone until it has
	eof:       bool, // the socket said all it will, and the call was told
	heard_end: bool, // the call said all it will
	shut:      bool, // and the socket was told, once all before it was written
	over:      bool, // let go of, once nothing it handed the system is still the system's
}

join_new :: proc(sp: ^host.Space) -> ^Join {
	j := new(Join)
	j.sp, j.data = sp, j
	j.on_data = proc(h: ^host.Call_Handler, call: u64, bytes: []byte) -> bool {
		j := (^Join)(h.data)
		if j.heard_end || j.over {
			return true
		}
		append(&j.out, ..bytes)
		join_write(j)
		return false // credited as the socket takes it
	}
	j.on_room = proc(h: ^host.Call_Handler, call: u64) {join_read((^Join)(h.data))}
	j.on_end = proc(h: ^host.Call_Handler, call: u64) {
		j := (^Join)(h.data)
		j.heard_end = true
		join_write(j)
	}
	j.on_fault = proc(h: ^host.Call_Handler, call: u64, fault: zsp.Call_Fault) {
		j := (^Join)(h.data)
		j.call = 0 // over, and forgotten by the host: nothing more is said in it
		join_close(j)
	}
	return j
}

// The socket is connected: bytes flow both ways from now on.
join_attach :: proc(j: ^Join, socket: net.TCP_Socket) {
	j.socket, j.connected = socket, true
	net.set_option(socket, .TCP_Nodelay, true)
	join_read(j)
	join_write(j)
}

// Reads what the call has credit for; host.Call_Handler.on_room says when there is more.
join_read :: proc(j: ^Join) {
	if j.over || !j.connected || j.eof || j.reading != nil {
		return
	}
	room := min(host.call_room(j.sp, j.call), len(j.buf))
	if room <= 0 {
		return
	}
	j.reading = nbio.recv_poly(j.socket, {j.buf[:room]}, j, proc(op: ^nbio.Operation, j: ^Join) {
		j.reading = nil
		switch {
		case j.over:
			join_free(j)
		case op.recv.err != nil:
			join_close(j)
		case op.recv.received == 0:
			j.eof = true
			host.call_end(j.sp, j.call)
			join_finish(j)
		case !host.call_send(j.sp, j.call, j.buf[:op.recv.received]):
			join_close(j)
		case:
			join_read(j)
		}
	})
}

// Hands the socket what the call said, one batch at a time; the call is credited for each as the socket takes it.
join_write :: proc(j: ^Join) {
	if j.over || !j.connected || j.writing != nil {
		return
	}
	if len(j.out) == 0 {
		if j.heard_end && !j.shut {
			j.shut = true
			net.shutdown(j.socket, .Send)
			join_finish(j)
		}
		return
	}
	j.out, j.sending = j.sending, j.out // what is being sent is not appended to, nor moved, until it is taken
	j.writing = nbio.send_poly(j.socket, {j.sending[:]}, j, proc(op: ^nbio.Operation, j: ^Join) {
		j.writing = nil
		if j.over {
			join_free(j)
			return
		}
		if op.send.err != nil {
			join_close(j)
			return
		}
		host.call_consumed(j.sp, j.call, op.send.sent)
		clear(&j.sending)
		join_write(j)
	})
}

// Over, as it should be: both have said all, and all of it was taken.
join_finish :: proc(j: ^Join) {
	if j.eof && j.shut && !j.over {
		j.call = 0 // both ends said End: the host has forgotten it
		join_close(j)
	}
}

// Over: the call cancelled if it goes on, and the socket shut both ways, which ends whatever the system still has of
// it: each such operation then completes, and only once none is left is anything let go of. Removing one instead would
// leave the kernel writing into a buffer since freed, and a descriptor closed under it free to be another's.
join_close :: proc(j: ^Join) {
	if j.over {
		return
	}
	j.over = true
	if j.call != 0 {
		host.call_cancel(j.sp, j.call)
		j.call = 0
	}
	if j.connected {
		when ODIN_OS == .Windows {
			net.close(j.socket) // what is pending completes, aborted, on the completion port
			j.closed = true
		} else {
			net.shutdown(j.socket, .Both) // what is pending completes: a read with nothing, a write with an error
		}
	}
	join_free(j)
}

// Lets go of a join that is over, once the system has nothing of it.
join_free :: proc(j: ^Join) {
	if !j.over || j.dialling != nil || j.reading != nil || j.writing != nil {
		return
	}
	if j.connected && !j.closed {
		net.close(j.socket)
	}
	delete(j.out)
	delete(j.sending)
	free(j)
}

// ---------------------------------------------------------------- the service

serve_forward :: proc(sp: ^host.Space, call: u64, from: host.Caller, scope: zsp.Scope, first: []byte) -> (^host.Call_Handler, zsp.Call_Fault) {
	to, parsed := net.parse_endpoint(string(first))
	allowed := false
	for a in forward.allowed {
		allowed ||= parsed && a == to
	}
	if scope != forward.scope || !allowed {
		return nil, .Denied
	}
	j := join_new(sp)
	j.call = call
	// What the call says meanwhile waits in it, uncredited, for the connection.
	j.dialling = nbio.dial_poly(to, j, proc(op: ^nbio.Operation, j: ^Join) {
		j.dialling = nil
		if j.over {
			if op.dial.err == nil {
				net.close(op.dial.socket) // connected after all, for nobody
			}
			join_free(j)
			return
		}
		if op.dial.err != nil {
			join_close(j) // refused: a reset, as a connection refused is
			return
		}
		join_attach(j, op.dial.socket)
	}, timeout = DIAL_WAIT)
	return j, .Cancelled
}

// A connection accepted here becomes a call to the device.
accepted :: proc(op: ^nbio.Operation, c: ^Connect) {
	c.accepting = nil
	if op.accept.err != nil {
		// Tried again in a while, not at once: an error that lasts would have this spin.
		c.accepting = nbio.timeout_poly(ACCEPT_AGAIN, c, proc(_: ^nbio.Operation, c: ^Connect) {
			c.accepting = nbio.accept_poly(c.listener, c, accepted)
		})
		return
	}
	c.accepting = nbio.accept_poly(c.listener, c, accepted)
	j := join_new(forward.space)
	j.call = host.host_call(forward.space, c.device, forward.scope, METHOD, transmute([]byte)c.to, &j.handler, forward.urgency)
	if j.call == 0 {
		net.close(op.accept.client) // no right, or no way there: refused at once
		free(j)
		return
	}
	join_attach(j, op.accept.client)
}

main :: proc() {
	os.exit(run())
}

USAGE :: "forward <dir> [--allow=<host:port>]... [--connect=<port>/<device>/<host:port>]... [--scope=N] [--urgency=N] [--no-udp] [--verbose]\n"

run :: proc() -> int {
	args := os.args[1:]
	if len(args) < 1 {
		os.write_string(os.stderr, USAGE)
		return 2
	}
	dir := args[0]
	forward = {scope = 1, urgency = zsp.URGENCY}
	config := host.Config{dir = dir, full = true, udp_port = 0}
	connects: [dynamic]^Connect
	defer {
		for c in connects {
			free(c)
		}
		delete(connects)
	}
	rest := args[1:]
	verbose := false
	for a in rest {
		switch {
		case strings.has_prefix(a, "--allow="):
			to, ok := net.parse_endpoint(a[8:])
			if !ok {
				os.write_string(os.stderr, USAGE)
				return 2
			}
			append(&forward.allowed, to)
		case strings.has_prefix(a, "--connect="):
			parts := strings.split(a[10:], "/", context.temp_allocator)
			if len(parts) != 3 {
				os.write_string(os.stderr, USAGE)
				return 2
			}
			port, parsed := strconv.parse_int(parts[0])
			key, hexed := hex.decode(transmute([]byte)parts[1], context.temp_allocator)
			if !parsed || port < 0 || port > 65535 || !hexed || len(key) != 32 {
				os.write_string(os.stderr, USAGE)
				return 2
			}
			c := new(Connect)
			copy(c.device[:], key)
			c.to = parts[2]
			c.at, _ = net.parse_endpoint("127.0.0.1:0")
			c.at.port = port
			append(&connects, c)
		case strings.has_prefix(a, "--scope="):
			n, ok := strconv.parse_u64(a[8:])
			if !ok || n == 0 || n >= 1 << 32 - 1 {
				os.write_string(os.stderr, USAGE)
				return 2
			}
			forward.scope = zsp.Scope(n)
		case strings.has_prefix(a, "--urgency="):
			n, ok := strconv.parse_u64(a[10:])
			if !ok || n > u64(zsp.URGENCY_LEAST) {
				os.write_string(os.stderr, USAGE)
				return 2
			}
			forward.urgency = u8(n)
		case a == "--no-udp":
			config.udp_port = nil
		case a == "--verbose":
			verbose = true
		case:
			os.write_string(os.stderr, USAGE)
			return 2
		}
	}
	context.logger = {
		lowest_level = .Debug if verbose else .Info,
		procedure    = proc(_: rawptr, level: runtime.Logger_Level, text: string, _: runtime.Logger_Options, _ := #caller_location) {
			fmt.eprintln(text)
		},
	}

	// The space and its relay, as zspd create, join and relay left them.
	space: zsp.Key32
	name, err := os.read_entire_file(in_dir(dir, "space"), context.temp_allocator)
	if bytes, hexed := hex.decode(transmute([]byte)strings.trim_space(string(name)), context.temp_allocator); err != nil || !hexed || copy(space[:], bytes) != 32 {
		os.write_string(os.stderr, "no space here: make or join one with zspd first\n")
		return 1
	}
	h: host.Host
	if !host.host_init(&h, config) {
		return 1
	}
	defer host.host_destroy(&h)
	forward.space = host.space_open(&h, space)
	if forward.space == nil {
		os.write_string(os.stderr, "could not open the space\n")
		return 1
	}
	if line, rerr := os.read_entire_file(in_dir(dir, "relay"), context.temp_allocator); rerr == nil {
		parts := strings.fields(string(line), context.temp_allocator)
		key: []byte
		hexed: bool
		if len(parts) == 2 {
			key, hexed = hex.decode(transmute([]byte)parts[0], context.temp_allocator)
		}
		relay: zsp.Key32
		if !hexed || copy(relay[:], key) != 32 {
			os.write_string(os.stderr, "the relay file makes no sense\n")
			return 1
		}
		host.dial(&h, forward.space, relay, parts[1])
	}

	host.host_serve(&h, METHOD, serve_forward)
	// Listeners only now, on the event loop the host made: where it is a completion port, a socket made before it
	// could not be tied to it.
	defer for c in connects {
		nbio.remove(c.accepting) // an accept takes nothing of ours to write into, and a wait nothing at all
		if c.listening {
			net.close(c.listener)
		}
	}
	lines := make([dynamic]string, context.temp_allocator)
	for c in connects {
		lerr: net.Network_Error
		if c.listener, lerr = nbio.listen_tcp(c.at); lerr != nil {
			os.write_string(os.stderr, "could not listen there\n")
			return 1
		}
		c.listening = true
		c.accepting = nbio.accept_poly(c.listener, c, accepted)
		bound, _ := net.bound_endpoint(c.listener)
		append(&lines, fmt.tprintf("listening on %s for %s", net.endpoint_to_string(bound, context.temp_allocator), c.to))
	}
	fmt.printfln("%s ready", hex.encode(h.device[:], context.temp_allocator))
	for line in lines {
		fmt.println(line)
	}
	os.flush(os.stdout)
	host.links_announce(&h)
	return 0 if host.host_run(&h) else 1
}

in_dir :: proc(dir, name: string) -> string {
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}
