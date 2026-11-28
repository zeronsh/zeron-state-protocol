package host

@(require) import "core:fmt"
@(require) import "core:strings"
import "core:time"
@(require) import "../third_party/nbio"

// What the loop does with its time, tick by tick, where built with -define:ZSP_TICKS=true: so that a tick that keeps it
// from what the network brings, for as long as a socket's buffer takes to fill and drop what comes, says what kept it.
// Built otherwise, none of it is: every procedure here is empty, and costs nothing.
//
// A tick is all the loop does between two waits in the kernel: the callbacks of what the kernel said (Events), then
// host_settle's phases, each timed by a mark at its end. What the disk was asked meanwhile is timed besides, as it is
// asked, whichever phase asked it.

TICKS :: #config(ZSP_TICKS, false)
TICK_LONG :: time.Duration(#config(ZSP_TICK_LONG_US, 2000)) * time.Microsecond // longer is said to be long
TICK_WORST :: 24 // of the long, the longest, kept whole

Tick_Phase :: enum u8 {
	Events, // the callbacks of nbio.tick: packets, reads and writes of streams, timers
	Free, // the temporary allocator's
	Sync, // node_sync, on a sync that is due: the log's fsync, and a checkpoint if one is due
	Dialers,
	Links,
	Retain,
	Found,
	Relayed,
	Links_Flush,
	Relayed_Flush,
	Streams,
	Spaces, // a relay's letting go of spaces nobody is in
	Store_Flush, // the log's write
}

Tick_Disk :: enum u8 {
	Log_Sync, // the log's fsync, for a sync or a checkpoint
	Roll_Sync, // the fsync of a segment that is full, as the next is begun
	Page_Sync, // the page file's fsync, at a checkpoint
	Log_Write,
	Page_Write,
	Log_Sync_Start, // the log's fsync begun, not waited for
}

Tick_Record :: struct {
	took:   time.Duration,
	at:     time.Duration, // since the first tick
	phases: [Tick_Phase]time.Duration,
	disk:   [Tick_Disk]time.Duration,
	asked:  [Tick_Disk]u32, // times
}

Ticks :: struct {
	first, mark: time.Tick,
	began:       bool,
	cur:         Tick_Record,
	count:       u64, // ticks: every one followed a wake
	busy:        time.Duration, // in all of them
	long:        [4]u64, // over 2, 5, 10 and 20 ms
	long_time:   [Tick_Phase]time.Duration, // of the long ones, in each phase
	long_disk:   [Tick_Disk]time.Duration,
	disk:        [Tick_Disk]time.Duration, // of all
	asked:       [Tick_Disk]u64,
	longest:     [Tick_Disk]time.Duration, // one ask
	worst:       [TICK_WORST]Tick_Record, // longest first
	worst_n:     int,
}

@(private, thread_local)
ticks: Ticks

// The loop has woken: what it did since, before this, was the callbacks of what woke it.
@(private)
ticks_woke :: #force_inline proc() {
	when TICKS {
		now := time.tick_now()
		if !ticks.began {
			ticks.began, ticks.first = true, now
		}
		ticks.cur = {}
		// nbio's clock is read as the kernel's wait returns: everything after it is the callbacks.
		ticks.cur.phases[.Events] = max(time.since(nbio.now()), 0)
		ticks.mark = now
	}
}

// What was done since the last mark was this phase's.
@(private)
ticks_mark :: #force_inline proc(phase: Tick_Phase) {
	when TICKS {
		now := time.tick_now()
		ticks.cur.phases[phase] += time.tick_diff(ticks.mark, now)
		ticks.mark = now
	}
}

// The loop is about to wait again.
@(private)
ticks_end :: proc() {
	when TICKS {
		if !ticks.began {
			return
		}
		r := &ticks.cur
		for d in r.phases {
			r.took += d
		}
		r.at = time.tick_diff(ticks.first, ticks.mark)
		ticks.count += 1
		ticks.busy += r.took
		if r.took <= TICK_LONG {
			return
		}
		for limit, i in ([4]time.Duration{2, 5, 10, 20}) {
			if r.took > limit * time.Millisecond {
				ticks.long[i] += 1
			}
		}
		for d, p in r.phases {
			ticks.long_time[p] += d
		}
		for d, k in r.disk {
			ticks.long_disk[k] += d
		}
		// Kept in order, longest first, as the longest are what is to be explained.
		at := ticks.worst_n
		for at > 0 && ticks.worst[at - 1].took < r.took {
			at -= 1
		}
		if at < TICK_WORST {
			copy(ticks.worst[at + 1:], ticks.worst[at:TICK_WORST - 1])
			ticks.worst[at] = r^
			ticks.worst_n = min(ticks.worst_n + 1, TICK_WORST)
		}
	}
}

// Times what the disk is asked, from `since`, the tick it was asked at.
@(private)
ticks_disk :: #force_inline proc(kind: Tick_Disk, since: time.Tick) {
	when TICKS {
		d := time.tick_since(since)
		ticks.cur.disk[kind] += d
		ticks.cur.asked[kind] += 1
		ticks.disk[kind] += d
		ticks.asked[kind] += 1
		ticks.longest[kind] = max(ticks.longest[kind], d)
	}
}

// When what ticks_disk is to time began, where it is timed at all.
@(private)
ticks_now :: #force_inline proc() -> (t: time.Tick) {
	when TICKS {
		t = time.tick_now()
	}
	return
}

// What the loop did with its time, as JSON on one line: see bench/stalls.py. Empty unless built to count.
host_ticks_json :: proc(allocator := context.allocator) -> string {
	when !TICKS {
		return ""
	} else {
		ms :: proc(d: time.Duration) -> f64 {return f64(d) / f64(time.Millisecond)}
		b := strings.builder_make(allocator)
		fmt.sbprintf(&b, `{{"ticks":%d,"busy_ms":%.3f,"long":[%d,%d,%d,%d],"span_ms":%.3f`, ticks.count, ms(ticks.busy), ticks.long[0], ticks.long[1], ticks.long[2], ticks.long[3], ms(time.tick_diff(ticks.first, ticks.mark)))
		phases :: proc(b: ^strings.Builder, name: string, of: [Tick_Phase]time.Duration) {
			fmt.sbprintf(b, `,"%s":{{`, name)
			first := true
			for d, p in of {
				if d > 0 {
					fmt.sbprintf(b, `%s"%v":%.3f`, "" if first else ",", p, ms(d))
					first = false
				}
			}
			strings.write_byte(b, '}')
		}
		disks :: proc(b: ^strings.Builder, name: string, of: [Tick_Disk]time.Duration) {
			fmt.sbprintf(b, `,"%s":{{`, name)
			first := true
			for d, k in of {
				if d > 0 {
					fmt.sbprintf(b, `%s"%v":%.3f`, "" if first else ",", k, ms(d))
					first = false
				}
			}
			strings.write_byte(b, '}')
		}
		phases(&b, "long_phases", ticks.long_time)
		disks(&b, "long_disk", ticks.long_disk)
		disks(&b, "disk", ticks.disk)
		disks(&b, "longest_ask", ticks.longest)
		fmt.sbprintf(&b, `,"asked":{{`)
		for n, k in ticks.asked {
			fmt.sbprintf(&b, `%s"%v":%d`, "" if k == min(Tick_Disk) else ",", k, n)
		}
		strings.write_string(&b, `},"worst":[`)
		for &r, i in ticks.worst[:ticks.worst_n] {
			fmt.sbprintf(&b, `%s{{"ms":%.3f,"at_s":%.3f`, "" if i == 0 else ",", ms(r.took), time.duration_seconds(r.at))
			phases(&b, "phases", r.phases)
			disks(&b, "disk", r.disk)
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
		return strings.to_string(b)
	}
}
