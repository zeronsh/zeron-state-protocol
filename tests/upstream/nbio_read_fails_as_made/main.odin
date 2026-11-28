// Reproduces core:nbio waiting for ever on a read that fails as it is made (no upstream issue; the same mechanism as
// odin-lang/Odin#8644, for files).
// Platform: windows
// Ours: FIXED
//
// ReadFile fails at once on a file opened only to write, and leaves OVERLAPPED.Internal at STATUS_PENDING; no
// completion is queued for it, and read_exec takes it for one under way.
//
// Prints one line and exits 0: "BROKEN: ..." if the read had not ended after 5 s, or "FIXED: ..." if it ended, with an
// error. Anything else is the repro's own failure. Run by .github/workflows/upstream.yml, through tests/upstream/run.sh,
// against stock core:nbio and against ours.
package nbio_read_fails_as_made

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:time"

Read :: struct {
	done: bool,
	err:  nbio.FS_Error,
}

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}
	dir, derr := os.make_directory_temp("", "nbio-read-fails-*", context.allocator)
	if derr != nil {
		fmt.eprintln("no directory could be made:", derr)
		os.exit(2)
	}
	defer os.remove_all(dir)
	path := fmt.aprintf("%s/written-only", dir)
	h, oerr := nbio.open_sync(path, mode = {.Write, .Create})
	if oerr != nil {
		fmt.eprintln("open failed:", oerr)
		os.remove_all(dir)
		os.exit(2)
	}
	r: Read
	buf: [16]byte
	nbio.read_poly(h, 0, buf[:], &r, proc(op: ^nbio.Operation, r: ^Read) { r^ = {true, op.read.err} })
	start := time.tick_now()
	for !r.done && time.tick_since(start) < 5 * time.Second {
		nbio.tick(10 * time.Millisecond)
	}
	nbio.close(h)
	nbio.tick(0)
	if r.done && r.err == nil {
		fmt.eprintln("a read of a file opened only to write ended with no error")
		os.remove_all(dir)
		os.exit(2)
	}
	if r.done {
		fmt.printfln("FIXED: a read of a file opened only to write ended, with %v", r.err)
	} else {
		fmt.println("BROKEN: a read of a file opened only to write had not ended after 5 s")
	}
}
