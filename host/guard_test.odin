package host

import "core:fmt"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"
import "../zsp"

// Requests each judged on a connection kept alive (forward_look_again): what has passed waits for the call's credit
// as anything does, and nothing more is read meanwhile, nor its end heard before it has gone.

@(private = "file")
Slow :: struct {
	using handler: Call_Handler,
	sp:            ^Space,
	call:          u64,
	buf:           [dynamic]byte,
	received:      int,
	credited:      int,
	connected:     bool,
	ended:         bool,
}

@(private = "file")
step :: proc(w: ^World) {
	for &h, i in w.hosts[:w.count] {
		if !w.dead[i] {
			host_settle(&h)
		}
	}
	_ = nbio.tick(5 * time.Millisecond)
	free_all(context.temp_allocator)
}

// The device's end of zsp.tcp, here: it keeps what comes, and gives credit only when told to.
@(private = "file")
slow_callee :: proc(w: ^World, keep: bool) -> ^Slow {
	callee := new(Slow)
	callee.sp = world_space(w, 1)
	callee.on_data = keep ? proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		sc := (^Slow)(h)
		append(&sc.buf, ..bytes)
		sc.received += len(bytes)
		return false
	} : proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		sc := (^Slow)(h)
		sc.received += len(bytes)
		return false
	}
	callee.on_end = proc(h: ^Call_Handler, call: u64) {
		(^Slow)(h).ended = true
	}
	w.hosts[1].methods["zsp.tcp"] = proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
		sc := (^Slow)(sp.host.data)
		sc.call = call
		return sc, {}
	}
	w.hosts[1].data = callee
	return callee
}

@(private = "file")
guarded_forward :: proc(t: ^testing.T, w: ^World) -> (f: ^Forward, client: net.TCP_Socket, listener: net.TCP_Socket, host_hdr: string) {
	sb := world_space(w, 2)
	sb.naming = {suffix = NAMES, loopback = {77, 0}}
	err: net.Network_Error
	listener, err = net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, err == nil)
	bound, _ := net.bound_endpoint(listener)
	client, err = net.dial_tcp(bound)
	testing.expect(t, err == nil)
	socket, _, aerr := net.accept_tcp(listener)
	testing.expect(t, aerr == nil)
	conn := new(Connection)
	conn.sp, conn.device = sb, w.hosts[1].device
	f = forward(sb, w.hosts[1].device, 1, 8080, "", socket, proc(data: rawptr, st: Forward_Status) {
		if st != .Connected {
			free((^Connection)(data))
		}
	}, conn, http_guard)
	testing.expect(t, f != nil)
	conn.forward = f
	ip, _ := device_address(sb, w.hosts[1].device)
	host_hdr = fmt.tprintf("%d.%d.%d.%d", ip[0], ip[1], ip[2], ip[3])
	return
}

@(test)
judged_requests_wait_for_credit :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, false))
	callee := slow_callee(&w, keep = false)
	defer free(callee)
	f, client, listener, host_hdr := guarded_forward(t, &w)
	defer net.close(listener)
	defer net.close(client)
	net.set_blocking(client, false)
	req := fmt.aprintf("GET /p HTTP/1.1\r\nHost: %s\r\nX-Pad: %s\r\n\r\n", host_hdr, strings.repeat("A", 3950, context.temp_allocator))
	defer delete(req)
	bytes := transmute([]byte)req
	sa, sb := world_space(&w, 1), world_space(&w, 2)
	peak, at := 0, 0
	last := time.tick_now()
	start := time.tick_now()
	for time.tick_since(start) < 4 * time.Second && peak <= 4 * zsp.CALL_WINDOW {
		if callee.call != 0 && !callee.connected {
			call_send(sa, callee.call, {0})
			callee.connected = true
		}
		for _ in 0 ..< 8 {
			n, err := net.send_tcp(client, bytes[at:])
			at = (at + n) % len(bytes)
			if err != nil {
				break
			}
		}
		// A reader slow as can be: 64 bytes of credit every 10 ms, once the window is used.
		if callee.connected && call_room(sb, f.call) == 0 && callee.credited < callee.received && time.tick_since(last) >= 10 * time.Millisecond {
			give := min(64, callee.received - callee.credited)
			call_consumed(sa, callee.call, give)
			callee.credited += give
			last = time.tick_now()
		}
		step(&w)
		peak = max(peak, len(f.held))
	}
	testing.expectf(t, peak <= zsp.CALL_WINDOW + INSPECT_MOST, "held %d while %d was credited", peak, callee.credited)
}

@(test)
judged_requests_go_before_the_end :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, false))
	callee := slow_callee(&w, keep = true)
	defer {
		delete(callee.buf)
		free(callee)
	}
	f, client, listener, host_hdr := guarded_forward(t, &w)
	defer net.close(listener)
	defer net.close(client)
	// A request as long as a call's window, then another, then the end: all of both arrive, then the end.
	head_form := "POST /one HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\n\r\n"
	body := zsp.CALL_WINDOW - len(fmt.tprintf(head_form, host_hdr, 262000))
	head := fmt.tprintf(head_form, host_hdr, body)
	second := fmt.tprintf("GET /second HTTP/1.1\r\nHost: %s\r\nX-Pad: %s\r\nX-End: WHOLE\r\n\r\n", host_hdr, strings.repeat("B", 3900, context.temp_allocator))
	payload := make([dynamic]byte, context.temp_allocator)
	append(&payload, head)
	for _ in 0 ..< body {
		append(&payload, 'A')
	}
	append(&payload, second)
	expected := len(payload)
	for sent := 0; sent < len(payload); {
		n, err := net.send_tcp(client, payload[sent:])
		testing.expect(t, err == nil)
		sent += n
	}
	net.shutdown(client, .Send)
	sa := world_space(&w, 1)
	small := false
	start := time.tick_now()
	for time.tick_since(start) < 5 * time.Second && !callee.ended {
		if callee.call != 0 && !callee.connected {
			call_send(sa, callee.call, {0})
			callee.connected = true
		}
		if !small && callee.connected && len(callee.buf) == zsp.CALL_WINDOW && len(f.held) > 512 {
			call_consumed(sa, callee.call, 512) // less than what waits
			callee.credited += 512
			small = true
		} else if small && callee.credited < len(callee.buf) {
			call_consumed(sa, callee.call, len(callee.buf) - callee.credited)
			callee.credited = len(callee.buf)
		}
		step(&w)
	}
	testing.expectf(t, len(callee.buf) == expected && strings.contains(string(callee.buf[:]), "WHOLE"), "%d of %d arrived", len(callee.buf), expected)
}
