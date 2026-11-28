package main

@(require) import "core:fmt"
@(require) import "core:os"
@(require) import "core:strconv"
@(require) import "core:strings"
import "core:time"
import "../host"
import "../third_party/nbio"
import "../zsp"

// What bench/stalls.py runs zspd with, built with -define:ZSP_BENCH=true, and nothing otherwise: every procedure here
// is empty unless so built. A node so built serves "sink", which takes whatever it is told and counts it; and, as its
// environment says,
//
//   ZSP_STALL=<ms>,<every ms>   holds its loop that long, that often, as a tick that does that much work would
//   ZSP_BULK=<device>,<MiB>     calls that device's sink once a direct link to it is ready, and pours that much in
//
// and says, as it stops, what it did and what its loop did, as JSON on one line of standard error after "bench ".

BENCH :: #config(ZSP_BENCH, false)

@(private = "file")
Bench :: struct {
	using handler: host.Call_Handler,
	h:            ^host.Host,
	stall, every: time.Duration,
	stalls:       int,
	stalled:      time.Duration,
	// The bulk call this node makes.
	to:           zsp.Key32,
	total, sent:  int,
	call:         u64,
	began, ended: time.Tick, // the first byte sent, and the other side's end heard
	done:         bool,
	// What its sink was told.
	sunk:         int,
	first, last:  time.Tick,
}

@(private = "file")
bench: Bench

bench_start :: proc(h: rawptr) {
	when BENCH {
		bench.h = (^host.Host)(h)
		host.host_serve(bench.h, "sink", proc(sp: ^host.Space, call: u64, from: host.Caller, scope: zsp.Scope, first: []byte) -> (^host.Call_Handler, zsp.Call_Fault) {
			@(static) sink := host.Call_Handler {
				on_data = proc(h: ^host.Call_Handler, call: u64, bytes: []byte) -> bool {
					sink_took(len(bytes))
					return true
				},
				on_end = proc(h: ^host.Call_Handler, call: u64) {
					host.call_end((^host.Space)(h.data), call)
				},
			}
			sink.data = sp
			sink_took(len(first))
			return &sink, .Cancelled
		})
		if stall, ok := os.lookup_env("ZSP_STALL", context.temp_allocator); ok {
			ms, _, every := strings.partition(stall, ",")
			a, aok := strconv.parse_f64(ms)
			b, bok := strconv.parse_f64(every)
			if aok && bok && a > 0 && b > a {
				bench.stall, bench.every = time.Duration(a * 1e6), time.Duration(b * 1e6)
				nbio.timeout(bench.every, stall_now)
			}
		}
		if bulk, ok := os.lookup_env("ZSP_BULK", context.temp_allocator); ok {
			device, _, mib := strings.partition(bulk, ",")
			key, kok := parse_hex(device, 32)
			n, nok := strconv.parse_int(mib)
			if kok && nok && n > 0 {
				copy(bench.to[:], key)
				bench.total = n << 20
				nbio.timeout(50 * time.Millisecond, bulk_try)
			}
		}
	}
}

@(private = "file")
sink_took :: proc(n: int) {
	now := time.tick_now()
	if bench.sunk == 0 {
		bench.first = now
	}
	bench.sunk += n
	bench.last = now
}

// Holds the loop as a long tick would: busy, not asleep, as work is.
@(private = "file")
stall_now :: proc(_: ^nbio.Operation) {
	start := time.tick_now()
	for time.tick_since(start) < bench.stall {
	}
	bench.stalls += 1
	bench.stalled += time.tick_since(start)
	nbio.timeout(max(bench.every - time.tick_since(start), 0), stall_now)
}

@(private = "file")
bulk_try :: proc(_: ^nbio.Operation) {
	h := bench.h
	if len(h.spaces) == 0 || !host.host_linked(h.spaces[0], bench.to) {
		nbio.timeout(50 * time.Millisecond, bulk_try)
		return
	}
	bench.on_room = proc(_: ^host.Call_Handler, _: u64) {bulk_fill()}
	bench.on_end = proc(_: ^host.Call_Handler, _: u64) {
		bench.done = true
		bench.ended = time.tick_now()
		say(os.stderr, "bench: bulk over\n") // for whoever waits for it
	}
	bench.on_fault = proc(_: ^host.Call_Handler, _: u64, _: zsp.Call_Fault) {bench.done = true}
	bench.call = host.host_call(h.spaces[0], bench.to, 1, "sink", nil, &bench.handler, 6)
	if bench.call == 0 {
		nbio.timeout(50 * time.Millisecond, bulk_try)
		return
	}
	bench.began = time.tick_now()
	bulk_fill()
}

@(private = "file")
bulk_fill :: proc() {
	@(static) zeros: [64 << 10]byte
	sp := bench.h.spaces[0]
	for bench.sent < bench.total {
		n := min(bench.total - bench.sent, host.call_room(sp, bench.call), len(zeros))
		if n <= 0 || !host.call_send(sp, bench.call, zeros[:n]) {
			return
		}
		bench.sent += n
	}
	host.call_end(sp, bench.call)
}

bench_report :: proc(h: ^host.Host) {
	when BENCH {
		ms :: proc(d: time.Duration) -> f64 {return f64(d) / f64(time.Millisecond)}
		direct, direct_lost, relayed, relayed_lost := host.host_link_packets(h)
		ticks := host.host_ticks_json(context.temp_allocator)
		line := fmt.tprintf(
			`bench {{"stalls":%d,"stalled_ms":%.3f,"bulk":{{"sent":%d,"ms":%.3f,"done":%v},"sink":{{"bytes":%d,"ms":%.3f},"packets":{{"direct":%d,"direct_lost":%d,"relayed":%d,"relayed_lost":%d},"loop":%s}}`,
			bench.stalls, ms(bench.stalled),
			bench.sent, ms(time.tick_diff(bench.began, bench.ended)) if bench.done else 0, bench.done,
			bench.sunk, ms(time.tick_diff(bench.first, bench.last)),
			direct, direct_lost, relayed, relayed_lost,
			ticks if ticks != "" else "null",
		)
		say(os.stderr, line, "\n")
	}
}
