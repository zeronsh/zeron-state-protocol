package host

import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:testing"
import "core:time"
import "../pipe"
import "../zsp"

// What streams cost and give, measured on this machine over loopback: a relay and two devices in one process, so the
// CPU and memory are all three's together. Run by `./x bench streams`; a test that does nothing otherwise.
//
// For each path, directly over UDP and through the relay: the throughput of a bulk call; the round trip of a small
// message in a call, idle; the same beneath a bulk call of a lesser urgency, and of the same; and the CPU time and
// resident memory that cost.

BENCH :: #config(ZSP_BENCH, false)
BENCH_BYTES :: #config(ZSP_BENCH_BYTES, 64 << 20)

// B's "sink": takes whatever it is told, counting it, and ends when the caller does.
@(private)
sunk: int

@(private)
bench_sink :: proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
	@(static) sink := Call_Handler {
		on_data = proc(h: ^Call_Handler, call: u64, bytes: []byte) -> bool {
			sunk += len(bytes)
			return true
		},
		on_end = proc(h: ^Call_Handler, call: u64) {
			call_end((^Space)(h.data), call)
		},
	}
	sink.data = sp
	sunk += len(first)
	return &sink, .Cancelled
}

// A's end of a bulk call: pours bytes into it as fast as credit allows, then ends.
@(private)
Sender :: struct {
	using handler: Call_Handler,
	sp:    ^Space,
	call:  u64,
	total: int,
	sent:  int,
	done:  bool, // the other side has ended too
}

@(private)
sender_start :: proc(s: ^Sender, w: ^World, total: int, urgency: u8) -> bool {
	s.sp, s.total, s.data = world_space(w, 1), total, s
	s.on_room = proc(h: ^Call_Handler, call: u64) {sender_fill((^Sender)(h.data))}
	s.on_end = proc(h: ^Call_Handler, call: u64) {(^Sender)(h.data).done = true}
	s.call = host_call(s.sp, w.keys[2].device, 1, "sink", nil, &s.handler, urgency)
	if s.call == 0 {
		return false
	}
	sender_fill(s)
	return true
}

@(private)
sender_fill :: proc(s: ^Sender) {
	@(static) zeros: [64 << 10]byte
	for s.sent < s.total {
		n := min(s.total - s.sent, call_room(s.sp, s.call), len(zeros))
		if n <= 0 || !call_send(s.sp, s.call, zeros[:n]) {
			return
		}
		s.sent += n
	}
	call_end(s.sp, s.call)
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
	p.call = host_call(p.sp, w.keys[2].device, 1, "bench", nil, &p.handler)
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

// Of every link of every host, direct or by a relay: packets sent (all but probes), and of them, lost and sent again.
@(private)
links_packets :: proc(w: ^World) -> (sent, lost: u64) {
	for &h in w.hosts[:w.count] {
		for p in h.udp.links {
			for l in ([]^pipe.Link{p.link, p.answer}) {
				if l != nil {
					sent += l.sent_packets
					lost += l.lost_packets
				}
			}
		}
		for s in h.spaces {
			for r in s.relayed {
				if r.link != nil {
					sent += r.link.sent_packets
					lost += r.link.lost_packets
				}
			}
		}
	}
	return
}

@(test)
bench_streams :: proc(t: ^testing.T) {
	when !BENCH {
		return
	}
	// With what zspd allocates with, not the test runner's tracking allocator, which costs what zspd does not.
	context.allocator = runtime.heap_allocator()
	fmt.eprintln("\n  path      what                                  result")
	for udp in ([]bool{true, false}) {
		w: World
		testing.expect(t, world_init(t, &w, udp = udp))
		defer world_destroy(&w)
		testing.expect(t, world_ready(&w, direct = udp))
		host_serve(&w.hosts[2], "bench", bench_echo)
		host_serve(&w.hosts[2], "sink", bench_sink)
		path := "udp  " if udp else "relay"

		// Bulk alone.
		before := usage()
		start := time.tick_now()
		sunk = 0
		src: Sender
		testing.expect(t, sender_start(&src, &w, BENCH_BYTES, 6))
		world_run(&w, proc(w: ^World, s: rawptr) -> bool {return (^Sender)(s).done}, &src, 120 * time.Second)
		took := time.tick_since(start)
		after := usage()
		testing.expect_value(t, sunk, BENCH_BYTES)
		mbps := f64(BENCH_BYTES) * 8 / time.duration_seconds(took) / 1e6
		cpu := time.duration_seconds(after.cpu - before.cpu) / (f64(BENCH_BYTES) / f64(1 << 30))
		fmt.eprintfln("  %s     a bulk call, %d MiB                    %.0f Mbit/s, %.2f s of CPU a GiB", path, BENCH_BYTES >> 20, mbps, cpu)
		sent, lost := links_packets(&w)
		fmt.eprintfln("  %s     packets of all links, so far           %d sent, %d lost and sent again (%.3f%%)", path, sent, lost, 100 * f64(lost) / max(f64(sent), 1))
		world_run(&w, nobody_left)

		// A small message's round trip, idle.
		p: Pinger
		testing.expect(t, pinger_start(&p, &w, 300))
		world_run(&w, proc(w: ^World, p: rawptr) -> bool {return len((^Pinger)(p).samples) >= (^Pinger)(p).want}, &p)
		fmt.eprintfln("  %s     round trip, idle                      %.3f ms median, %.3f ms at the 99th", path, percentile(p.samples[:], 50), percentile(p.samples[:], 99))

		// The same beneath a bulk call less urgent than it, and beneath one as urgent.
		for urgency in ([]u8{6, 3}) {
			clear(&p.samples)
			sunk = 0
			busy: Sender
			testing.expect(t, sender_start(&busy, &w, BENCH_BYTES, urgency))
			// Let it get going, then time round trips beneath it.
			wait := time.tick_now()
			world_run(&w, proc(w: ^World, at: rawptr) -> bool {return time.tick_since((^time.Tick)(at)^) > 300 * time.Millisecond}, &wait)
			p.want = 300
			ping_once(&p)
			bulk_start := time.tick_now()
			world_run(&w, proc(w: ^World, p: rawptr) -> bool {return len((^Pinger)(p).samples) >= (^Pinger)(p).want}, &p, 60 * time.Second)
			rate := f64(sunk) * 8 / time.duration_seconds(time.tick_since(bulk_start) + 300 * time.Millisecond) / 1e6
			fmt.eprintfln("  %s     round trip, beneath bulk at urgency %d  %.3f ms median, %.3f ms at the 99th, the bulk at %.0f Mbit/s", path, urgency, percentile(p.samples[:], 50), percentile(p.samples[:], 99), rate)
			sent, lost = links_packets(&w)
			fmt.eprintfln("  %s     packets of all links, so far           %d sent, %d lost and sent again (%.3f%%)", path, sent, lost, 100 * f64(lost) / max(f64(sent), 1))
			world_run(&w, proc(w: ^World, s: rawptr) -> bool {return (^Sender)(s).done}, &busy, 120 * time.Second)
		}
		delete(p.samples)
		call_end(world_space(&w, 1), p.call)
	}
	u := usage()
	fmt.eprintfln("  the most resident at once, all three hosts: %d MiB", u.rss >> 20)
}
