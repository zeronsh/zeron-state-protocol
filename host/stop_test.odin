package host

import "base:runtime"
import "core:crypto"
import "core:log"
import "core:net"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import "../third_party/nbio"
import "../zsp"

@(private = "file")
Stopping :: struct {
	dir:     string,
	how:     enum {
		Storage_Failed, // before the loop runs, as a callback marks it
		Sync_Failed, // when the loop syncs what it has written: the fsync it begins fails, once it is done
		Sync_Refused, // the same, but where the fsync cannot even be begun
		Stopped_Meanwhile, // by another thread, as a signal's does, while the loop is about to wait
	},
	h:       ^Host, // atomic
	ran:     bool, // atomic: host_run returned
	started: bool, // atomic
}

// However the host is told to stop, its loop ends: whether settling found storage failed, as it does before anything
// more is said, with nothing armed to wake the loop; or another thread asked it to just before the loop waited, which
// on Windows core:nbio's wake did not wake it from.
@(test)
host_stops_however_told :: proc(t: ^testing.T) {
	for how in ([]type_of(Stopping{}.how){.Storage_Failed, .Sync_Failed, .Sync_Refused, .Stopped_Meanwhile}) {
		base, _ := os.temp_directory(context.temp_allocator)
		dir, err := os.make_directory_temp(base, "zsp-stop-*", context.allocator)
		testing.expect(t, err == nil)
		st := Stopping{dir = dir, how = how}
		runner := thread.create_and_start_with_poly_data(&st, proc(st: ^Stopping) {
			context = runtime.default_context()
			context.logger = log.nil_logger() // what the host says of its failing is meant
			h: Host
			// Listening, so that the loop has something to wait for, and would wait for ever.
			if !host_init(&h, {dir = st.dir, full = true, listen = net.Endpoint{net.IP4_Loopback, 0}}) {
				sync.atomic_store(&st.started, true)
				return
			}
			defer host_destroy(&h)
			space: zsp.Key32
			crypto.rand_bytes(space[:])
			s := space_open(&h, space)
			switch st.how {
			case .Storage_Failed:
				s.node.failed = true
			case .Sync_Failed:
				body := [1]byte{1}
				cell := zsp.Cell{row = zsp.Id{1, 100}, slot = 1, kind = .Value, stamp = zsp.Stamp{1000, 1}, body = body[:]}
				zsp.store_commit(&s.node.store, []zsp.Cell{cell}, 0, own = false)
				s.node.store.disk.log_sync = proc(_: rawptr) -> bool {return false}
				// As the disk would say it, once the loop goes on: begun, and failed.
				s.node.store.disk.log_sync_start = proc(data: rawptr, token: u64) -> bool {
					h := (^File_Disk)(data).host
					fs := new(Fsync)
					fs.host, fs.token, fs.ok = h, token, false
					append(&h.fsyncing, fs)
					fs.next, h.fsync_ready = h.fsync_ready, fs
					return true
				}
				h.syncing, h.sync_due = true, time.tick_now()
			case .Sync_Refused:
				body := [1]byte{1}
				cell := zsp.Cell{row = zsp.Id{1, 100}, slot = 1, kind = .Value, stamp = zsp.Stamp{1000, 1}, body = body[:]}
				zsp.store_commit(&s.node.store, []zsp.Cell{cell}, 0, own = false)
				s.node.store.disk.log_sync_start = proc(_: rawptr, _: u64) -> bool {return false}
				h.syncing, h.sync_due = true, time.tick_now()
			case .Stopped_Meanwhile:
				// Called back first thing in the loop's next wait, before it sleeps: there another thread stops it.
				nbio.timeout_poly(0, &h, proc(_: ^nbio.Operation, h: ^Host) {
					other := thread.create_and_start_with_poly_data(h, proc(h: ^Host) {host_stop(h)})
					thread.join(other)
					thread.destroy(other)
				})
			}
			sync.atomic_store(&st.h, &h)
			sync.atomic_store(&st.started, true)
			host_run(&h)
			sync.atomic_store(&st.ran, true)
		})
		for !sync.atomic_load(&st.started) {
			time.sleep(time.Millisecond)
		}
		start := time.tick_now()
		for !sync.atomic_load(&st.ran) && time.tick_since(start) < 2 * time.Second {
			time.sleep(5 * time.Millisecond)
		}
		ran := sync.atomic_load(&st.ran)
		testing.expectf(t, ran, "%v: the host's loop goes on", how)
		if h := sync.atomic_load(&st.h); !ran && h != nil {
			host_stop(h) // a wake now finds it waiting, and the test ends
		}
		thread.join(runner)
		thread.destroy(runner)
		os.remove_all(dir)
		delete(dir)
	}
}

// The log's fsync is the disk's to make while the loop goes on: a sync that is due is begun, not waited for, and what
// it makes durable is counted on only once the system says it has; then the loop hears of it, and counts it.
@(test)
loop_does_not_wait_for_the_log_fsync :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-fsync-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	h: Host
	testing.expect(t, host_init(&h, {dir = dir, full = true}))
	defer host_destroy(&h)
	space: zsp.Key32
	crypto.rand_bytes(space[:])
	s := space_open(&h, space)
	body := [1]byte{1}
	cell := zsp.Cell{row = zsp.Id{1, 100}, slot = 1, kind = .Value, stamp = zsp.Stamp{1000, 1}, body = body[:]}
	zsp.store_commit(&s.node.store, []zsp.Cell{cell}, 0, own = false)
	h.syncing, h.sync_due = true, time.tick_now()
	host_settle(&h)
	tail := zsp.store_tail(&s.node.store)
	testing.expect(t, zsp.store_flying(&s.node.store), "the fsync is under way")
	testing.expect(t, s.node.store.synced < tail, "and nothing is counted on before it is done")
	start := time.tick_now()
	for s.node.store.synced < tail && time.tick_since(start) < 10 * time.Second {
		wait := time.Duration(10 * time.Millisecond)
		if due, ok := host_deadline(&h); ok {
			wait = min(wait, max(time.tick_diff(time.tick_now(), due), 0))
		}
		testing.expect(t, nbio.tick(wait) == nil)
		host_settle(&h)
	}
	testing.expect_value(t, s.node.store.synced, tail)
	testing.expect(t, !zsp.store_flying(&s.node.store) && !s.node.failed)
}

// A checkpoint too: its pages are written as it is begun, and the fsyncs it waits for, the log's and the page file's
// and then its header's, are the disk's to make while the loop goes on. The store counts on it only once all are done.
@(test)
loop_does_not_wait_for_a_checkpoint :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-fsync-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	h: Host
	testing.expect(t, host_init(&h, {dir = dir, full = true}))
	defer host_destroy(&h)
	space: zsp.Key32
	crypto.rand_bytes(space[:])
	s := space_open(&h, space)
	body: [1000]byte
	for i in 0 ..< u64(zsp.CHECKPOINT_TAIL / len(body) + 8) {
		cell := zsp.Cell{row = zsp.Id{1, 100 + i}, slot = 16, kind = .Value, stamp = zsp.Stamp{1000 + i, 1}, body = body[:]}
		zsp.store_commit(&s.node.store, []zsp.Cell{cell}, 0, own = false)
	}
	testing.expect(t, zsp.store_wants_checkpoint(&s.node.store))
	generation := s.node.store.generation
	h.syncing, h.sync_due = true, time.tick_now()
	host_settle(&h)
	testing.expect(t, s.node.store.flight.step != .None, "the checkpoint is under way")
	testing.expect(t, s.node.store.generation == generation, "and not yet counted on")
	start := time.tick_now()
	for zsp.store_flying(&s.node.store) && time.tick_since(start) < 10 * time.Second {
		wait := time.Duration(10 * time.Millisecond)
		if due, ok := host_deadline(&h); ok {
			wait = min(wait, max(time.tick_diff(time.tick_now(), due), 0))
		}
		testing.expect(t, nbio.tick(wait) == nil)
		host_settle(&h)
	}
	testing.expect_value(t, s.node.store.generation, generation + 1)
	testing.expect(t, s.node.store.checkpoint == s.node.store.synced && !s.node.failed)
}
