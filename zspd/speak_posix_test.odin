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
import "../zsp"

@(private = "file")
interruptions: int // atomic

// An admin command waiting for the node running here to answer may be interrupted by a signal, as by a handler without
// SA_RESTART, or on Linux by being stopped and started again (Ctrl+Z, fg): it waits on for the answer, rather than
// taking the interruption for none and the node for one that did not hear it.
@(test)
speak_waits_through_signals :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zspd-speak-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	listener, lerr := net.listen_tcp({net.IP4_Loopback, 0})
	testing.expect(t, lerr == nil)
	defer net.close(listener)
	at, _ := net.bound_endpoint(listener)
	testing.expect(t, host.save(in_dir(dir, "address"), transmute([]byte)net.endpoint_to_string(at, context.temp_allocator)))
	testing.expect(t, host.save(in_dir(dir, "token"), transmute([]byte)string("token")))

	// A node that answers once it has heard the greeting, a while after.
	node := thread.create_and_start_with_poly_data(listener, proc(listener: net.TCP_Socket) {
		client, _, aerr := net.accept_tcp(listener)
		if aerr != nil {
			return
		}
		defer net.close(client)
		buf: [4096]byte
		net.recv_tcp(client, buf[:])
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

	sa: posix.sigaction_t
	sa.sa_handler = proc "c" (_: posix.Signal) {
		sync.atomic_add(&interruptions, 1)
	}
	posix.sigemptyset(&sa.sa_mask)
	was: posix.sigaction_t
	testing.expect(t, posix.sigaction(.SIGUSR2, &sa, &was) == .OK)
	defer posix.sigaction(.SIGUSR2, &was, nil)
	Interrupter :: struct {
		target: posix.pthread_t,
		done:   bool, // atomic
	}
	it := Interrupter{target = posix.pthread_self()}
	interrupter := thread.create_and_start_with_poly_data(&it, proc(it: ^Interrupter) {
		for !sync.atomic_load(&it.done) {
			time.sleep(20 * time.Millisecond)
			if !sync.atomic_load(&it.done) {
				posix.pthread_kill(it.target, .SIGUSR2)
			}
		}
	})
	sync.atomic_store(&interruptions, 0)
	clock, answered, reached := speak(dir, nil)
	sync.atomic_store(&it.done, true)
	thread.join(interrupter)
	thread.destroy(interrupter)
	thread.join(node)
	thread.destroy(node)
	testing.expect(t, sync.atomic_load(&interruptions) > 0, "not interrupted while it waited")
	testing.expectf(t, reached && answered && clock == 1234, "an interrupted wait taken for no answer (reached %v, answered %v, clock %d)", reached, answered, clock)
}
