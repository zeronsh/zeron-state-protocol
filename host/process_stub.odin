package host

// Stands in for the platforms' processes until process_posix.odin and process_windows.odin are here.

Process :: struct {}
process_start :: proc(spec: Process_Spec, events: Process_Events) -> (p: ^Process, err: string) {return nil, "not yet"}
process_read :: proc(p: ^Process, want: bool) {}
process_input :: proc(p: ^Process, bytes: []byte) -> int {return 0}
process_input_room :: proc(p: ^Process) -> int {return 0}
process_end_input :: proc(p: ^Process) {}
process_signal :: proc(p: ^Process, s: Signal) {}
process_resize :: proc(p: ^Process, rows, cols: u16) {}
process_free :: proc(p: ^Process) {}
