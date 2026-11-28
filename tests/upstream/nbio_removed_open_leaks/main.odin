// Reproduces core:nbio leaving open the file of a removed open (no upstream issue).
// Platform: windows
// Ours: FIXED
//
// An open is done as it is made; removed then, its callback is not called, and nobody is handed the file to close.
// nbio opens files without FILE_SHARE_DELETE, so the file cannot be removed while it is held.
//
// Prints one line and exits 0: "BROKEN: ..." if the file could not be removed, or "FIXED: ..." if it could. Anything
// else is the repro's own failure. Run by .github/workflows/upstream.yml, through tests/upstream/run.sh, against stock
// core:nbio and against ours.
package nbio_removed_open_leaks

import "core:fmt"
import "core:nbio"
import "core:os"

main :: proc() {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		fmt.eprintln("acquire_thread_event_loop failed:", err)
		os.exit(2)
	}
	dir, derr := os.make_directory_temp("", "nbio-removed-open-*", context.allocator)
	if derr != nil {
		fmt.eprintln("no directory could be made:", derr)
		os.exit(2)
	}
	defer os.remove_all(dir)
	path := fmt.aprintf("%s/opened", dir)
	_ = os.write_entire_file(path, transmute([]byte)string("opened"))
	called := false
	opening := nbio.open_poly(path, &called, proc(op: ^nbio.Operation, called: ^bool) {
		called^ = true
		if op.open.err == nil { nbio.close(op.open.handle) }
	})
	nbio.remove(opening)
	for _ in 0 ..< 3 { nbio.tick(0) }
	if called {
		fmt.eprintln("a removed open called back")
		os.remove_all(dir)
		os.exit(2)
	}
	rerr := os.remove(path)
	fmt.printfln("%s: the file of a removed open, removed: %v", "BROKEN" if rerr != nil else "FIXED", rerr)
}
