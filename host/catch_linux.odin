package host

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:sys/linux"
import "core:time"

// On Linux a socket listening on every address of a port takes that port on every address, and leaves it to no
// other, whichever came first: so a device's port, listened for at its own address here, would keep this machine's
// own services from that port, or fail for them. Instead, once zspd setup has had the kernel send every connection
// to the devices' addresses here (an nftables redirect), one socket takes them all, and asks each where it was
// going (SO_ORIGINAL_DST, which anyone may). No port is taken, and every port a device offers is reached at once.
//
// Whether the redirect is there is found by trying it: a connection to an address of the range that arrives here.

@(private)
Catch :: struct {
	socket:    net.TCP_Socket,
	open:      bool,
	working:   bool, // connections to the devices' addresses come here
	accepting: ^nbio.Operation,
	trying:    ^nbio.Operation,
	probe:     net.Endpoint, // where the trial connection went
}

@(private)
catch_open :: proc(h: ^Host, at: net.Endpoint) {
	c := &h.catch
	socket, err := listen_on(at, 256)
	if err != nil {
		report(.Warning, "cannot listen for devices' addresses at ", net.endpoint_to_string(at, context.temp_allocator), ": ", fmt.tprint(err))
		return
	}
	c.socket, c.open = socket, true
	c.accepting = nbio.accept_poly(socket, h, catch_accepted)
	catch_try(h)
}

// Finds out whether connections to the devices' addresses come here.
@(private)
catch_try :: proc(h: ^Host) {
	c := &h.catch
	if !c.open || c.trying != nil || len(h.spaces) == 0 {
		return
	}
	base := h.spaces[0].naming.loopback
	c.probe = {net.IP4_Address{127, base[0], base[1] + 255, 254}, 9}
	c.trying = nbio.dial_poly(c.probe, h, proc(op: ^nbio.Operation, h: ^Host) {
		h.catch.trying = nil
		if op.dial.err != nil {
			catch_found(h, false)
			return
		}
		net.close(op.dial.socket) // its arrival is the answer
	}, timeout = 2 * time.Second)
}

@(private)
catch_found :: proc(h: ^Host, working: bool) {
	if h.catch.working == working {
		return
	}
	h.catch.working = working
	report(.Debug, "connections to devices' addresses come here" if working else "connections to devices' addresses do not come here: see zspd setup")
	for sp in h.spaces {
		if sp.ports != nil {
			for r in sp.ports.remotes {
				remote_listen(r)
			}
		}
	}
}

@(private)
catch_close :: proc(h: ^Host) {
	c := &h.catch
	if c.accepting != nil {
		nbio.remove(c.accepting)
	}
	if c.trying != nil {
		nbio.remove(c.trying)
	}
	if c.open {
		net.close(c.socket)
	}
	c^ = {}
}

@(private)
catch_accepted :: proc(op: ^nbio.Operation, h: ^Host) {
	c := &h.catch
	c.accepting = nbio.accept_poly(c.socket, h, catch_accepted)
	if op.accept.err != nil {
		return
	}
	socket := op.accept.client
	original, ok := original_destination(socket)
	if !ok {
		socket_abort(socket)
		return
	}
	if original == c.probe {
		net.close(socket)
		catch_found(h, true)
		return
	}
	ip, v4 := original.address.(net.IP4_Address)
	for sp in h.spaces {
		if v4 && sp.ports != nil && address_member(sp, {ip[0], ip[1], ip[2], ip[3]}) != nil {
			ports_accept(sp, socket, original, op.accept.client_endpoint)
			return
		}
	}
	socket_abort(socket) // somebody connected here directly, or to nobody's address
}

// Where a connection the kernel redirected here was going.
@(private)
original_destination :: proc(socket: net.TCP_Socket) -> (at: net.Endpoint, ok: bool) {
	SO_ORIGINAL_DST :: 80
	addr: [16]byte // sockaddr_in
	size: u32 = size_of(addr)
	if linux.syscall(linux.SYS_getsockopt, linux.Fd(socket), 0, SO_ORIGINAL_DST, &addr, &size) != 0 || size < 8 || addr[0] != 2 {
		return
	}
	return {net.IP4_Address{addr[4], addr[5], addr[6], addr[7]}, int(addr[2]) << 8 | int(addr[3])}, true
}

@(private)
catch_port :: proc(h: ^Host) -> int {
	if !h.catch.open {
		return -1
	}
	at, err := net.bound_endpoint(h.catch.socket)
	return at.port if err == nil else -1
}

// Whether connections to the devices' addresses are taken by one socket, and need no listener each.
@(private)
caught :: proc(h: ^Host) -> bool {
	return h.catch.working
}
