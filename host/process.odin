package host

// Processes this host runs for whoever calls zsp.exec or zsp.pty: with pipes, or with a terminal of their own
// (a pseudoterminal on Linux and macOS, ConPTY on Windows). Everything about them is told as it happens, on the
// event loop, without polling: output as it comes, room for more input as it goes, and the exit once all output is
// in. Output is read only while reading is wanted, so a process whose caller cannot keep up waits on its own pipe,
// and nothing piles up here. The platform's part is in process_posix.odin and process_windows.odin.

PROCESS_READ :: 64 << 10 // at most, at once
PROCESS_INPUT :: 256 << 10 // input held for a process that has not taken it yet, at most

Process_Spec :: struct {
	argv:  []string, // the first is the program, found on PATH if it has no separator; empty for the login shell
	env:   []string, // NAME=value, over the host's own environment; NAME alone removes it
	dir:   string, // where to start; the user's home if empty
	pty:   bool, // with a terminal, sized so, of this kind (TERM)
	rows:  u16,
	cols:  u16,
	term:  string,
}

Output_Stream :: enum u8 {
	Stdout = 1, // and a terminal's output
	Stderr = 2,
}

// How a process ended: its exit code, or the signal that ended it (POSIX numbering; Windows reports codes only).
Exit :: struct {
	code:   int,
	signal: int,
}

Signal :: enum u8 {
	Interrupt = 2, // SIGINT, Ctrl-C to a terminal's foreground
	Hangup    = 1,
	Quit      = 3,
	Kill      = 9, // cannot be ignored
	Terminate = 15,
	Stop      = 19,
	Continue  = 18,
}

Process_Events :: struct {
	data:     rawptr,
	on_output: proc(data: rawptr, stream: Output_Stream, bytes: []byte), // only while reading is wanted
	on_room:  proc(data: rawptr), // input that was held has been taken: process_input_room grew
	on_exit:  proc(data: rawptr, exit: Exit), // once, after all its output has been told; the process is reaped
}

// The operations every platform provides, in process_posix.odin and process_windows.odin:
//
// process_start :: proc(spec: Process_Spec, events: Process_Events) -> (p: ^Process, err: string)
//     Starts it, in a process group (POSIX) or job object (Windows) of its own, so that a signal or a kill reaches
//     all it started too. Reading is wanted from the start. err says why not, for whoever called.
// process_read :: proc(p: ^Process, want: bool)
//     Whether output is wanted now. While not, nothing is read, and the process blocks once its pipe is full.
// process_input :: proc(p: ^Process, bytes: []byte) -> int
//     Gives it input, as much as it takes now or room allows (PROCESS_INPUT held at most); returns how much was
//     accepted. on_room says when more may be.
// process_input_room :: proc(p: ^Process) -> int
// process_end_input :: proc(p: ^Process)
//     No more input: its stdin is closed once what is held is written (for a terminal, nothing is closed: the
//     caller sends EOF as a terminal user would, with ^D).
// process_signal :: proc(p: ^Process, s: Signal)
//     To its whole group. On Windows, Interrupt is Ctrl-C (to a console process, or a terminal's), and Kill and
//     Terminate end the job.
// process_resize :: proc(p: ^Process, rows, cols: u16)
// process_free :: proc(p: ^Process)
//     Lets it go: killed (its whole group) if still running, its handles closed, and nothing more told.
