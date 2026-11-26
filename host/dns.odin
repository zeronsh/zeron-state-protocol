package host

import "core:encoding/endian"
import "core:fmt"
import "core:nbio"
import "core:net"
import "../pipe"

// Answers for names, over UDP and TCP, at one address of this machine: the system's resolver is pointed here for
// the names' suffix alone (see setup.odin), so every application finds them. Nothing waits on a clock: a TCP
// asker past the few allowed makes way for the next.

DNS_TCP_MAX :: 8 // askers by TCP at once
DNS_TCP_BUFFER :: 2 + 512 // a question is short: a longer one is not one

@(private)
Dns :: struct {
	udp:       net.UDP_Socket,
	tcp:       net.TCP_Socket,
	open:      bool,
	accepting: ^nbio.Operation,
	receiving: ^nbio.Operation,
	askers:    [dynamic]^Dns_Asker,
}

@(private)
Dns_Asker :: struct {
	host:    ^Host,
	socket:  net.TCP_Socket,
	buf:     [DNS_TCP_BUFFER]byte,
	have:    int,
	out:     [dynamic]byte,
	sent:    int,
	polling: ^nbio.Operation,
}

// Listens for questions about names. False if it cannot, which is not fatal: names are then found through the
// proxy alone.
@(private)
dns_open :: proc(h: ^Host, at: net.Endpoint) -> bool {
	d := &h.dns_server
	err: net.Create_Socket_Error
	if d.udp, err = nbio.create_udp_socket(net.family_from_endpoint(at)); err != nil {
		return false
	}
	if berr := net.bind(d.udp, at); berr != nil {
		report(.Warning, "cannot answer for names at ", net.endpoint_to_string(at, context.temp_allocator), ": ", fmt.tprint(berr), "; see zspd setup")
		net.close(d.udp)
		return false
	}
	net.set_blocking(d.udp, false)
	tcp, lerr := nbio.listen_tcp(at, 16)
	if lerr != nil {
		report(.Warning, "cannot answer for names by TCP: ", fmt.tprint(lerr))
		net.close(d.udp)
		return false
	}
	d.tcp = tcp
	d.open = true
	dns_receive(h)
	d.accepting = nbio.accept_poly(d.tcp, h, dns_accepted)
	return true
}

@(private)
dns_close :: proc(h: ^Host) {
	d := &h.dns_server
	if !d.open {
		return
	}
	for len(d.askers) > 0 {
		dns_asker_close(d.askers[0])
	}
	delete(d.askers)
	if d.accepting != nil {
		nbio.remove(d.accepting)
	}
	if d.receiving != nil {
		nbio.remove(d.receiving)
	}
	net.close(d.udp)
	net.close(d.tcp)
	d^ = {}
}

@(private)
dns_receive :: proc(h: ^Host) {
	d := &h.dns_server
	d.receiving = nbio.poll_poly(d.udp, .Receive, h, proc(op: ^nbio.Operation, h: ^Host) {
		d := &h.dns_server
		d.receiving = nil
		if op.poll.result != .Ready {
			return
		}
		for _ in 0 ..< 64 {
			n, from, err := net.recv_udp(d.udp, h.shared)
			if err == .Would_Block {
				break
			}
			if err != nil {
				continue
			}
			q, ok := pipe.dns_query(h.shared[:n])
			if !ok {
				continue // not a question: nothing to say to it
			}
			w := make([dynamic]byte, 0, 512, context.temp_allocator)
			pipe.dns_reply(&w, &q, names_answer(h, &q), q.size)
			net.send_udp(d.udp, w[:], from)
		}
		dns_receive(h)
	})
}

@(private)
dns_accepted :: proc(op: ^nbio.Operation, h: ^Host) {
	d := &h.dns_server
	d.accepting = nbio.accept_poly(d.tcp, h, dns_accepted)
	if op.accept.err != nil {
		return
	}
	if len(d.askers) >= DNS_TCP_MAX {
		dns_asker_close(d.askers[0]) // the longest asking makes way
	}
	a := new(Dns_Asker)
	a.host, a.socket = h, op.accept.client
	net.set_blocking(a.socket, false)
	append(&d.askers, a)
	dns_asker_wait(a, .Receive)
}

@(private)
dns_asker_wait :: proc(a: ^Dns_Asker, event: nbio.Poll_Event) {
	a.polling = nbio.poll_poly(a.socket, event, a, proc(op: ^nbio.Operation, a: ^Dns_Asker) {
		a.polling = nil
		if op.poll.result != .Ready {
			dns_asker_close(a)
			return
		}
		dns_asker_run(a)
	})
}

// Sends what it can, then reads what has come and answers whatever is whole, over and over until it must wait: for
// the asker to read (nothing more is read meanwhile, so what waits for it is one read's answers at most), or to ask.
@(private)
dns_asker_run :: proc(a: ^Dns_Asker) {
	for {
		for a.sent < len(a.out) {
			n, err := net.send_tcp(a.socket, a.out[a.sent:])
			a.sent += n
			if err == .Would_Block {
				dns_asker_wait(a, .Send)
				return
			}
			if err != nil {
				dns_asker_close(a)
				return
			}
		}
		clear(&a.out)
		a.sent = 0
		n, err := net.recv_tcp(a.socket, a.buf[a.have:])
		if err == .Would_Block {
			dns_asker_wait(a, .Receive)
			return
		}
		if err != nil || n == 0 {
			dns_asker_close(a)
			return
		}
		a.have += n
		for a.have >= 2 {
			size := int(endian.unchecked_get_u16be(a.buf[:]))
			if 2 + size > DNS_TCP_BUFFER {
				dns_asker_close(a)
				return
			}
			if a.have < 2 + size {
				break
			}
			q, ok := pipe.dns_query(a.buf[2:2 + size])
			if !ok {
				dns_asker_close(a)
				return
			}
			at := len(a.out)
			append(&a.out, 0, 0)
			pipe.dns_reply(&a.out, &q, names_answer(a.host, &q))
			endian.unchecked_put_u16be(a.out[at:], u16(len(a.out) - at - 2))
			copy(a.buf[:], a.buf[2 + size:a.have])
			a.have -= 2 + size
		}
	}
}

@(private)
dns_asker_close :: proc(a: ^Dns_Asker) {
	d := &a.host.dns_server
	for x, i in d.askers {
		if x == a {
			ordered_remove(&d.askers, i)
			break
		}
	}
	if a.polling != nil {
		nbio.remove(a.polling)
	}
	net.close(a.socket)
	delete(a.out)
	free(a)
}
