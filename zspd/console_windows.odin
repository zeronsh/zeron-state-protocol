#+build windows
package main

import win "core:sys/windows"

// Windows waits on no console or pipe as it waits on sockets, so standard input is always read by a thread. A
// terminal's keys are read as the console's records: with virtual terminal input each key comes as the characters a
// terminal would send, and a change of the window's size comes as a record of its own.

console_stdin :: proc() -> int {
	return 0
}

console_pollable :: proc() -> bool {
	return false
}

@(private = "file")
high_surrogate: u16 // of a character in two halves, the first, until the second comes

// One read of standard input, which waits only if nothing has come.
console_read :: proc(i: ^Input, buf: []byte) -> int {
	h := win.GetStdHandle(win.STD_INPUT_HANDLE)
	if !i.terminal {
		n: win.DWORD
		if !win.ReadFile(h, raw_data(buf), win.DWORD(len(buf)), &n, nil) {
			return 0 if win.GetLastError() == win.ERROR_BROKEN_PIPE else INPUT_FAILED
		}
		return int(n)
	}
	records: [64]win.INPUT_RECORD
	for {
		// Each record makes at most four bytes, times its repeats, which are cut short to fit.
		most := clamp(len(buf) / 4, 1, len(records))
		got: win.DWORD
		if !win.ReadConsoleInputW(h, &records[0], win.DWORD(most), &got) {
			return INPUT_FAILED
		}
		n := 0
		for &r in records[:got] {
			#partial switch r.EventType {
			case .KEY_EVENT:
				k := r.Event.KeyEvent
				unit := u16(k.uChar.UnicodeChar)
				// A key's character comes as it goes down; but one composed with Alt comes as Alt comes up.
				VK_MENU :: 0x12
				if unit == 0 || (!k.bKeyDown && k.wVirtualKeyCode != VK_MENU) {
					continue
				}
				for _ in 0 ..< max(int(k.wRepeatCount), 1) {
					if n + 4 > len(buf) {
						break
					}
					n += utf16_put(buf[n:], unit)
				}
			case .WINDOW_BUFFER_SIZE_EVENT:
				signal_caught(SIGNAL_RESIZE)
			}
		}
		if n > 0 {
			return n
		}
	}
}

// Puts one UTF-16 unit as UTF-8, once a character is whole.
@(private = "file")
utf16_put :: proc(into: []byte, unit: u16) -> int {
	r: rune
	switch {
	case unit >= 0xd800 && unit < 0xdc00:
		high_surrogate = unit
		return 0
	case unit >= 0xdc00 && unit < 0xe000:
		if high_surrogate == 0 {
			return 0
		}
		r = 0x10000 + (rune(high_surrogate) - 0xd800) << 10 + (rune(unit) - 0xdc00)
		high_surrogate = 0
	case:
		r = rune(unit)
	}
	switch {
	case r < 0x80:
		into[0] = byte(r)
		return 1
	case r < 0x800:
		into[0] = 0xc0 | byte(r >> 6)
		into[1] = 0x80 | byte(r & 0x3f)
		return 2
	case r < 0x10000:
		into[0] = 0xe0 | byte(r >> 12)
		into[1] = 0x80 | byte(r >> 6 & 0x3f)
		into[2] = 0x80 | byte(r & 0x3f)
		return 3
	}
	into[0] = 0xf0 | byte(r >> 18)
	into[1] = 0x80 | byte(r >> 12 & 0x3f)
	into[2] = 0x80 | byte(r >> 6 & 0x3f)
	into[3] = 0x80 | byte(r & 0x3f)
	return 4
}

// Writes all of it, waiting as long as it takes: this is the writer's thread, and nothing else waits on it.
console_write :: proc(stream: Output_Stream, bytes: []byte) -> bool {
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE if stream == .Stdout else win.STD_ERROR_HANDLE)
	bytes := bytes
	for len(bytes) > 0 {
		n: win.DWORD
		if !win.WriteFile(h, raw_data(bytes), win.DWORD(min(len(bytes), 1 << 30)), &n, nil) {
			return false
		}
		bytes = bytes[n:]
	}
	return true
}

console_close_stdout :: proc() {
	win.CloseHandle(win.GetStdHandle(win.STD_OUTPUT_HANDLE))
}

// A broken pipe is a failed write here already.
console_quiet_pipes :: proc() {}

console_is_terminal :: proc() -> bool {
	mode: win.DWORD
	return bool(win.GetConsoleMode(win.GetStdHandle(win.STD_INPUT_HANDLE), &mode))
}

Terminal_State :: struct {
	input, output:        win.DWORD,
	input_cp, output_cp:  win.CODEPAGE,
}

// The console, raw: keys as a terminal would send them, Ctrl-C among them, nothing echoed; and what is written to it
// read as a terminal reads it, in UTF-8.
terminal_raw :: proc() -> (state: Terminal_State, ok: bool) {
	in_h := win.GetStdHandle(win.STD_INPUT_HANDLE)
	out_h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	if !win.GetConsoleMode(in_h, &state.input) || !win.GetConsoleMode(out_h, &state.output) {
		return
	}
	state.input_cp, state.output_cp = win.GetConsoleCP(), win.GetConsoleOutputCP()
	win.SetConsoleCP(.UTF8)
	win.SetConsoleOutputCP(.UTF8)
	ok = bool(win.SetConsoleMode(in_h, win.ENABLE_VIRTUAL_TERMINAL_INPUT | win.ENABLE_WINDOW_INPUT))
	ok &&= bool(win.SetConsoleMode(out_h, state.output | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING | win.DISABLE_NEWLINE_AUTO_RETURN))
	if !ok {
		terminal_restore(&state)
	}
	return
}

terminal_restore :: proc(state: ^Terminal_State) {
	win.SetConsoleMode(win.GetStdHandle(win.STD_INPUT_HANDLE), state.input)
	win.SetConsoleMode(win.GetStdHandle(win.STD_OUTPUT_HANDLE), state.output)
	win.SetConsoleCP(state.input_cp)
	win.SetConsoleOutputCP(state.output_cp)
}

// The window's size, in characters.
terminal_size :: proc() -> (rows, cols: u16, ok: bool) {
	info: win.CONSOLE_SCREEN_BUFFER_INFO
	if !win.GetConsoleScreenBufferInfo(win.GetStdHandle(win.STD_OUTPUT_HANDLE), &info) {
		return
	}
	w := info.srWindow
	return u16(w.Bottom - w.Top + 1), u16(w.Right - w.Left + 1), true
}

// Catches Ctrl-C, Ctrl-Break and the console's closing, as the signals POSIX would send for them. A terminal's own
// Ctrl-C is a key while it is raw, and never comes here.
signals_catch :: proc(which: Signal_Set) {
	win.SetConsoleCtrlHandler(proc "system" (ctrl: win.DWORD) -> win.BOOL {
		switch ctrl {
		case win.CTRL_C_EVENT:
			signal_caught(SIGNAL_INTERRUPT)
		case win.CTRL_BREAK_EVENT:
			signal_caught(SIGNAL_QUIT)
		case:
			signal_caught(SIGNAL_HANGUP)
		}
		return true
	}, true)
}
