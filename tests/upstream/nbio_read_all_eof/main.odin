// Reproduces core:nbio never ending a read of all that meets the end of the file (no upstream issue).
// Platform: windows
// Ours: FIXED
//
// A read of all of 16 bytes from offset 2 of a file of 5: ReadFile reads 3, and the read is executed again for the
// rest; the end of the file comes by its completion, which read_callback takes for no end once some bytes were read,
// and executes the read again, at the end again, for ever. (Where ReadFile says so as it is made, the read fails with
// error 38 instead.)
//
// Prints one line and exits 0: "BROKEN: ..." if the read had not ended after 5 s, or ended with an error, or
// "FIXED: ..." if it ended with the 3 bytes and no error, as on Linux and macOS. Anything else is the repro's own
// failure. Run by .github/workflows/upstream.yml, through tests/upstream/run.sh, against stock core:nbio and ours.
package nbio_read_all_eof

import "core:fmt"
import "core:nbio"
import "core:os"
import "core:time"

Read :: struct {
	done: bool,
	err:  nbio.FS_Error,
	n:    int,
}

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}
	dir, derr := os.make_directory_temp("", "nbio-read-all-*", context.allocator)
	if derr != nil {
		fmt.eprintln("no directory could be made:", derr)
		os.exit(2)
	}
	defer os.remove_all(dir)
	path := fmt.aprintf("%s/short", dir)
	_ = os.write_entire_file(path, transmute([]byte)string("short"))
	h, oerr := nbio.open_sync(path)
	if oerr != nil {
		fmt.eprintln("open failed:", oerr)
		os.remove_all(dir)
		os.exit(2)
	}
	r: Read
	buf: [16]byte
	nbio.read_poly(h, 2, buf[:], &r, proc(op: ^nbio.Operation, r: ^Read) { r^ = {true, op.read.err, op.read.read} }, all = true)
	start := time.tick_now()
	for !r.done && time.tick_since(start) < 5 * time.Second {
		nbio.tick(10 * time.Millisecond)
	}
	nbio.close(h)
	nbio.tick(0)
	if r.done && r.err == nil && string(buf[:r.n]) == "ort" {
		fmt.println("FIXED: a read of all of 16 bytes from 2 of a file of 5 ended with \"ort\" and no error")
	} else if r.done {
		fmt.printfln("BROKEN: a read of all of 16 bytes from 2 of a file of 5 ended with %v, %q", r.err, string(buf[:r.n]))
	} else {
		fmt.println("BROKEN: a read of all of 16 bytes from 2 of a file of 5 had not ended after 5 s")
	}
}
