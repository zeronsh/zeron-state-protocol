package host

import "core:fmt"
import "core:net"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../zsp"

// What streams cost and give, measured on this machine over loopback: a relay and two devices in one process, so the
// CPU and memory are all three's together. Run by `./x bench streams`; a test that does nothing otherwise.
//
// For each path, directly over UDP and through the relay: the throughput of a forwarded TCP connection; the round trip
// of a small message in a call, idle; the same while a bulk transfer runs, a file (zsp.get) and a forward (zsp.tcp);
// and the CPU time and resident memory that cost.

BENCH :: #config(ZSP_BENCH, false)
BENCH_BYTES :: #config(ZSP_BENCH_BYTES, 64 << 20)

@(private)
Sink :: struct {
	listener: net.TCP_Socket,
	port:     int,
	thread:   ^thread.Thread,
	got:      i64, // atomic
	stop:     bool, // atomic
}

@(private)
sink_start :: proc(s: ^Sink) {
	s.listener, _ = net.listen_tcp({net.IP4_Loopback, 0})
	bound, _ := net.bound_endpoint(s.listener)
	s.port = bound.port
	s.thread = thread.create_and_start_with_poly_data(s, proc(s: ^Sink) {
		for !sync.atomic_load(&s.stop) {
			client, _, err := net.accept_tcp(s.listener)
			if err != nil || sync.atomic_load(&s.stop) {
				if err == nil {
					net.close(client)
				}
				return
			}
			buf: [256 << 10]byte
			for {
				n, rerr := net.recv_tcp(client, buf[:])
				if rerr != nil || n == 0 {
					break
				}
				sync.atomic_add(&s.got, i64(n))
			}
			net.close(client)
		}
	})
}

@(private)
sink_stop :: proc(s: ^Sink) {
	sync.atomic_store(&s.stop, true)
	if c, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, s.port}); err == nil {
		net.close(c)
	}
	thread.join(s.thread)
	thread.destroy(s.thread)
	net.close(s.listener)
}

// Pours bytes into a connection as fast as it takes them.
@(private)
Source :: struct {
	port:   int,
	bytes:  int,
	sent:   i64, // atomic
	done:   bool, // atomic
	thread: ^thread.Thread,
}

@(private)
source_start :: proc(s: ^Source) {
	s.thread = thread.create_and_start_with_poly_data(s, proc(s: ^Source) {
		defer sync.atomic_store(&s.done, true)
		c, err := net.dial_tcp(net.Endpoint{net.IP4_Loopback, s.port})
		if err != nil {
			return
		}
		defer net.close(c)
		buf: [256 << 10]byte
		for i := 0; i < s.bytes; i += len(buf) {
			n, serr := net.send_tcp(c, buf[:min(len(buf), s.bytes - i)])
			sync.atomic_add(&s.sent, i64(n))
			if serr != nil {
				return
			}
		}
		net.shutdown(c, .Send)
		one: [1]byte
		net.recv_tcp(c, one[:]) // until the other side lets go
	})
}

// A call whose messages come straight back: each round trip timed.
@(private)
Pinger :: struct {
	using handler: Call_Handler,
	sp:       ^Space,
	call:     u64,
	sent_at:  time.Tick,
	samples:  [dynamic]time.Duration,
	want:     int,
}

@(private)
ping_once :: proc(p: ^Pinger) {
	msg: [64]byte
	p.sent_at = time.tick_now()
	call_send(p.sp, p.call, msg[:])
}

@(private)
pinger_start :: proc(p: ^Pinger, w: ^World, want: int) -> bool {
	p.sp = world_space(w, 1)
	p.want = want
	p.data = p
	p.on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
		p := (^Pinger)(h.data)
		append(&p.samples, time.tick_since(p.sent_at))
		if len(p.samples) < p.want {
			ping_once(p)
		}
		return true
	}
	p.call = host_call(p.sp, w.keys[2].device, 1, "zsp.bench", nil, &p.handler)
	if p.call == 0 {
		return false
	}
	ping_once(p)
	return true
}

@(private)
bench_echo :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	@(static) echo := Call_Handler {
		on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
			sp := (^Space)(h.data)
			call_send(sp, call, bytes)
			return true
		},
	}
	echo.data = sp
	return &echo, .Cancelled
}

@(private)
Usage :: struct {
	cpu: time.Duration, // user and system
	rss: int, // the most resident, in bytes
}


@(private)
percentile :: proc(samples: []time.Duration, p: int) -> f64 {
	if len(samples) == 0 {
		return 0
	}
	sorted := slice.clone(samples, context.temp_allocator)
	slice.sort(sorted)
	return f64(sorted[min(len(sorted) * p / 100, len(sorted) - 1)]) / f64(time.Millisecond)
}

@(test)
bench_streams :: proc(t: ^testing.T) {
	when !BENCH {
		return
	}
	fmt.eprintln("\n  path      what                                  result")
	for udp in ([]bool{true, false}) {
		w: World
		testing.expect(t, world_init(t, &w, udp = udp))
		defer world_destroy(&w)
		testing.expect(t, world_ready(&w, direct = udp))
		host_serve(&w.hosts[2], "zsp.bench", bench_echo)
		path := "udp  " if udp else "relay"
		sink: Sink
		sink_start(&sink)
		defer sink_stop(&sink)
		open_port = u16(sink.port)
		w.hosts[2].port_permitted = permit_open_port
		g: Gate
		testing.expect(t, gate_open(&g, &w, u16(sink.port)))
		defer gate_close(&g)

		// Bulk alone.
		before := usage()
		start := time.tick_now()
		src := Source{port = g.port, bytes = BENCH_BYTES}
		source_start(&src)
		world_run(&w, proc(w: ^World, s: rawptr) -> bool {return sync.atomic_load(&(^Sink)(s).got) >= BENCH_BYTES}, &sink, 120 * time.Second)
		took := time.tick_since(start)
		after := usage()
		world_run(&w, proc(w: ^World, s: rawptr) -> bool {return sync.atomic_load(&(^Source)(s).done)}, &src, 30 * time.Second)
		thread.join(src.thread)
		thread.destroy(src.thread)
		mbps := f64(BENCH_BYTES) * 8 / time.duration_seconds(took) / 1e6
		cpu := time.duration_seconds(after.cpu - before.cpu) / (f64(BENCH_BYTES) / f64(1 << 30))
		fmt.eprintfln("  %s     a forward, %d MiB                      %.0f Mbit/s, %.2f s of CPU a GiB", path, BENCH_BYTES >> 20, mbps, cpu)
		world_run(&w, nobody_left)

		// A small message's round trip, idle.
		p: Pinger
		testing.expect(t, pinger_start(&p, &w, 300))
		world_run(&w, proc(w: ^World, p: rawptr) -> bool {return len((^Pinger)(p).samples) >= (^Pinger)(p).want}, &p)
		fmt.eprintfln("  %s     round trip, idle                      %.3f ms median, %.3f ms at the 99th", path, percentile(p.samples[:], 50), percentile(p.samples[:], 99))

		// The same while a file comes in bulk, and while a forward does.
		for bulk in ([]string{"zsp.get", "zsp.tcp"}) {
			clear(&p.samples)
			done := sync.atomic_load(&sink.got)
			busy := Source{port = g.port, bytes = BENCH_BYTES}
			fetched: Outcomes
			defer outcomes_destroy(&fetched)
			file := in_world(&w, "bulk.bin")
			if bulk == "zsp.tcp" {
				source_start(&busy)
			} else {
				f, _ := os.open(file, {.Write, .Create, .Trunc})
				os.truncate(f, i64(BENCH_BYTES))
				os.close(f)
				shares_set(world_space(&w, 2), strings.concatenate({"files 1 bulk read ", w.root}, context.temp_allocator))
				host_get(world_space(&w, 1), w.keys[2].device, 1, "bulk/bulk.bin", in_world(&w, "fetched.bin"), outcome, &fetched)
			}
			// Let it get going, then time round trips beneath it.
			wait := time.tick_now()
			world_run(&w, proc(w: ^World, at: rawptr) -> bool {return time.tick_since((^time.Tick)(at)^) > 300 * time.Millisecond}, &wait)
			p.want = 300
			ping_once(&p)
			bulk_start := time.tick_now()
			world_run(&w, proc(w: ^World, p: rawptr) -> bool {return len((^Pinger)(p).samples) >= (^Pinger)(p).want}, &p, 60 * time.Second)
			moved := f64(sync.atomic_load(&sink.got) - done)
			if bulk == "zsp.get" {
				info, _ := os.stat(path_with(in_world(&w, "fetched.bin"), PART), context.temp_allocator)
				moved = f64(info.size)
			}
			rate := moved * 8 / time.duration_seconds(time.tick_since(bulk_start) + 300 * time.Millisecond) / 1e6
			fmt.eprintfln("  %s     round trip, beneath a %s           %.3f ms median, %.3f ms at the 99th, the bulk at %.0f Mbit/s", path, bulk, percentile(p.samples[:], 50), percentile(p.samples[:], 99), rate)
			if bulk == "zsp.tcp" {
				world_run(&w, proc(w: ^World, s: rawptr) -> bool {return sync.atomic_load(&(^Source)(s).done)}, &busy, 120 * time.Second)
				thread.join(busy.thread)
				thread.destroy(busy.thread)
			} else {
				world_run(&w, proc(w: ^World, o: rawptr) -> bool {return len((^Outcomes)(o).results) > 0}, &fetched, 120 * time.Second)
			}
		}
		delete(p.samples)
		call_end(world_space(&w, 1), p.call)
	}
	u := usage()
	fmt.eprintfln("  the most resident at once, all three hosts: %d MiB", u.rss >> 20)
}
