#+build !windows
package main

import "core:net"
import "core:os"
import "core:sync"
import "core:sys/posix"
import "core:testing"
import "core:thread"
import "core:time"
import "../host"
import "../pipe"
import "../third_party/nbio"
import "../zsp"

@(private = "file")
interruptions: int // atomic

// An admin command waiting for the node running here to answer may be interrupted by a signal, as by a handler without
// SA_RESTART, or on Linux by being stopped and started again (Ctrl+Z, fg): it waits on for the answer, rather than
// taking the interruption for none and the node for one that did not hear it. So too while it hands over a roster too
// large for the line to take at once, which the node reads as it can: a send interrupted part way said how much it had
// sent and was left there, and the command waited out its 10 s for an answer to what never all went.
@(test)
speak_waits_through_signals :: proc(t: ^testing.T) {
	sa: posix.sigaction_t
	sa.sa_handler = proc "c" (_: posix.Signal) {
		sync.atomic_add(&interruptions, 1)
	}
	posix.sigemptyset(&sa.sa_mask)
	was: posix.sigaction_t
	testing.expect(t, posix.sigaction(.SIGUSR2, &sa, &was) == .OK)
	defer posix.sigaction(.SIGUSR2, &was, nil)
	big := make([]byte, zsp.MAX_ROSTER) // the most there is, which the node below takes slowly
	defer delete(big)
	for roster in ([][]byte{nil, big}) {
		speak_through_signals(t, roster)
	}
}

@(private = "file")
speak_through_signals :: proc(t: ^testing.T, roster: []byte) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zspd-speak-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	defer net.close(listener)
	nbio.set_socket_option(listener, .Receive_Buffer_Size, 64 << 10) // what it accepts has as little room
	at, _ := net.bound_endpoint(listener)
	testing.expect(t, host.save(in_dir(dir, "address"), transmute([]byte)net.endpoint_to_string(at, context.temp_allocator)))
	testing.expect(t, host.save(in_dir(dir, "token"), transmute([]byte)string("token")))

	// A node that answers once it has heard the greeting and the roster, read a piece at a time, and a while after.
	// One that does not hear it all within a few seconds gives up, as the command then does.
	Node :: struct {
		listener: net.TCP_Socket,
		want:     int,
		heard:    int,
	}
	n := Node{listener = listener, want = max(1, len(roster))}
	node := thread.create_and_start_with_poly_data(&n, proc(n: ^Node) {
		client, _, aerr := net.accept_tcp(n.listener)
		if aerr != nil {
			return
		}
		defer net.close(client)
		nbio.set_socket_option(client, .Receive_Timeout, time.Duration(3 * time.Second))
		buf := make([]byte, 64 << 10)
		defer delete(buf)
		for n.heard < n.want {
			got, rerr := net.recv_tcp(client, buf)
			if got <= 0 || rerr != nil {
				return
			}
			n.heard += got
			if n.want > 1 {
				time.sleep(2 * time.Millisecond) // some 32 MB/s, so that the roster takes a while
			}
		}
		time.sleep(300 * time.Millisecond)
		frames := make([dynamic]byte, context.temp_allocator)
		f := zsp.frame_begin(&frames, .Roster)
		zsp.write_u64(&frames, 1234)
		zsp.frame_end(&frames, f)
		answer := make([dynamic]byte, context.temp_allocator)
		append(&answer, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
		pipe.ws_put(&answer, .Binary, frames[:], false)
		net.send_tcp(client, answer[:])
		net.recv_tcp(client, buf[:]) // until the command lets go
	})

	Interrupter :: struct {
		target: posix.pthread_t,
		done:   bool, // atomic
	}
	it := Interrupter{target = posix.pthread_self()}
	interrupter := thread.create_and_start_with_poly_data(&it, proc(it: ^Interrupter) {
		for !sync.atomic_load(&it.done) {
			time.sleep(5 * time.Millisecond)
			if !sync.atomic_load(&it.done) {
				posix.pthread_kill(it.target, .SIGUSR2)
			}
		}
	})
	sync.atomic_store(&interruptions, 0)
	clock, answered, reached := speak(dir, roster)
	sync.atomic_store(&it.done, true)
	thread.join(interrupter)
	thread.destroy(interrupter)
	thread.join(node)
	thread.destroy(node)
	testing.expectf(t, sync.atomic_load(&interruptions) > 0, "not interrupted while it waited (roster of %d)", len(roster))
	testing.expectf(t, reached && answered && clock == 1234, "an interrupted wait or send taken for no answer (roster of %d: reached %v, answered %v, clock %d, the node heard %d)", len(roster), reached, answered, clock, n.heard)
}
