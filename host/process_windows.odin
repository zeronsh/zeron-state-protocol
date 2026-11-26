#+build windows
package host


import "base:runtime"
import "core:nbio"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

// A process on Windows: in a job object of its own, which ends all it starts with it, with pipes or a pseudoconsole
// (ConPTY) for a terminal. This end of each pipe is a named pipe opened for overlapped I/O and associated with the
// event loop's completion port, so that reads and writes complete through the loop as a socket's do; the child's
// end is an ordinary handle it inherits, or ConPTY's. Nothing is polled: a read waits in the kernel, for as long as
// output is wanted, and the process's end is told by a wait the thread pool keeps (RegisterWaitForSingleObject),
// which hands it to the loop by executing an operation made ready for it on the loop's thread.
//
// No program is %COMSPEC%, cmd.exe: always there, and quick to start, where PowerShell takes its time.

Process :: struct {
	events:   Process_Events,
	process:  win.HANDLE,
	job:      win.HANDLE,
	pid:      win.DWORD,
	console:  HPCON, // the pseudoconsole; nil for pipes
	taken:    bool, // atomic: the console is being closed, by the wait's thread or by process_free
	input:    win.HANDLE, // its stdin, or the console's; nil once closed
	output:   [2]win.HANDLE, // its stdout (or the console's output) and stderr; nil once all is read
	bufs:     [2][]byte, // what a read fills, PROCESS_READ each, while there is output
	got:      [2]int, // read, not yet told for it was not wanted
	read_ops: [2]^nbio.Operation,
	write_op: ^nbio.Operation,
	writing:  [dynamic]byte, // being written, which nothing may move meanwhile
	held:     [dynamic]byte, // to be written after
	wait:     win.HANDLE, // the thread pool's, for the process's end
	exit_op:  ^nbio.Operation, // executed from the wait's thread once the process has ended
	ended:    bool, // atomic: and exit_op has been executed
	reading:  bool,
	ending:   bool,
	reaped:   bool, // exit_op has run
	exit:     Exit,
	told:     bool,
	telling:  int,
	freed:    bool,
	console_guard: sync.Mutex, // held while the console is resized or closed, on whichever thread
}

HPCON :: distinct rawptr

@(private)
STARTUPINFOEXW :: struct {
	StartupInfo:     win.STARTUPINFOW,
	lpAttributeList: rawptr,
}

@(private)
JOBOBJECT_BASIC_LIMIT_INFORMATION :: struct {
	PerProcessUserTimeLimit: win.LARGE_INTEGER,
	PerJobUserTimeLimit:     win.LARGE_INTEGER,
	LimitFlags:              win.DWORD,
	MinimumWorkingSetSize:   win.SIZE_T,
	MaximumWorkingSetSize:   win.SIZE_T,
	ActiveProcessLimit:      win.DWORD,
	Affinity:                win.ULONG_PTR,
	PriorityClass:           win.DWORD,
	SchedulingClass:         win.DWORD,
}

@(private)
JOBOBJECT_EXTENDED_LIMIT_INFORMATION :: struct {
	BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
	IoInfo:                [6]u64, // IO_COUNTERS
	ProcessMemoryLimit:    win.SIZE_T,
	JobMemoryLimit:        win.SIZE_T,
	PeakProcessMemoryUsed: win.SIZE_T,
	PeakJobMemoryUsed:     win.SIZE_T,
}

@(private)
JOBOBJECT_BASIC_PROCESS_ID_LIST :: struct {
	NumberOfAssignedProcesses: win.DWORD,
	NumberOfProcessIdsInList:  win.DWORD,
	ProcessIdList:             [64]win.ULONG_PTR,
}

@(private)
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000
@(private)
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS :: 9
@(private)
JOB_OBJECT_BASIC_PROCESS_ID_LIST_CLASS :: 3
@(private)
PROC_THREAD_ATTRIBUTE_HANDLE_LIST :: 0x00020002
@(private)
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016

foreign import kernel32 "system:Kernel32.lib"
foreign import ntdll "system:Ntdll.lib"

@(private, default_calling_convention = "system")
foreign kernel32 {
	CreatePseudoConsole :: proc(size: win.COORD, hInput, hOutput: win.HANDLE, dwFlags: win.DWORD, phPC: ^HPCON) -> win.HRESULT ---
	ResizePseudoConsole :: proc(hPC: HPCON, size: win.COORD) -> win.HRESULT ---
	ClosePseudoConsole :: proc(hPC: HPCON) ---
	InitializeProcThreadAttributeList :: proc(lpAttributeList: rawptr, dwAttributeCount, dwFlags: win.DWORD, lpSize: ^win.SIZE_T) -> win.BOOL ---
	UpdateProcThreadAttribute :: proc(lpAttributeList: rawptr, dwFlags: win.DWORD, Attribute: win.DWORD_PTR, lpValue: rawptr, cbSize: win.SIZE_T, lpPreviousValue: rawptr, lpReturnSize: ^win.SIZE_T) -> win.BOOL ---
	DeleteProcThreadAttributeList :: proc(lpAttributeList: rawptr) ---
	CreateJobObjectW :: proc(lpJobAttributes: ^win.SECURITY_ATTRIBUTES, lpName: win.LPCWSTR) -> win.HANDLE ---
	SetInformationJobObject :: proc(hJob: win.HANDLE, JobObjectInformationClass: i32, lpJobObjectInformation: rawptr, cbJobObjectInformationLength: win.DWORD) -> win.BOOL ---
	QueryInformationJobObject :: proc(hJob: win.HANDLE, JobObjectInformationClass: i32, lpJobObjectInformation: rawptr, cbJobObjectInformationLength: win.DWORD, lpReturnLength: ^win.DWORD) -> win.BOOL ---
	AssignProcessToJobObject :: proc(hJob, hProcess: win.HANDLE) -> win.BOOL ---
	TerminateJobObject :: proc(hJob: win.HANDLE, uExitCode: win.UINT) -> win.BOOL ---
}

@(private, default_calling_convention = "system")
foreign ntdll {
	NtSuspendProcess :: proc(ProcessHandle: win.HANDLE) -> win.NTSTATUS ---
	NtResumeProcess :: proc(ProcessHandle: win.HANDLE) -> win.NTSTATUS ---
}

// Names this process's pipes apart.
@(private)
process_pipes: u64

process_start :: proc(spec: Process_Spec, events: Process_Events) -> (p: ^Process, err: string) {
	argv := spec.argv
	if len(argv) == 0 {
		shell := process_env_value(spec, "COMSPEC")
		login := make([]string, 1, context.temp_allocator)
		login[0] = shell if shell != "" else "cmd.exe"
		argv = login
	}
	if argv[0] == "" {
		return nil, "no program given"
	}
	path, missing := process_find(argv[0], process_env_value(spec, "PATH"))
	if missing != "" {
		return nil, missing
	}
	dir := spec.dir if spec.dir != "" else process_env_value(spec, "USERPROFILE")
	if attributes := win.GetFileAttributesW(win.utf8_to_wstring(dir)); attributes == win.INVALID_FILE_ATTRIBUTES || attributes & win.FILE_ATTRIBUTE_DIRECTORY == 0 {
		return nil, strings.concatenate({"no such directory: ", dir}, context.temp_allocator)
	}

	// This end of each pipe, and the child's (or the console's).
	mine, theirs: [3]win.HANDLE
	console: HPCON
	defer for h in theirs {
		if h != nil {
			win.CloseHandle(h)
		}
	}
	defer if err != "" {
		for h in mine {
			if h != nil {
				win.CloseHandle(h)
			}
		}
		if console != nil {
			ClosePseudoConsole(console)
		}
	}
	streams := 2 if spec.pty else 3
	for i in 0 ..< streams {
		inbound := i != 0 // stdin is written here; the rest read
		if !process_pipe(&mine[i], &theirs[i], inbound, !spec.pty) {
			return nil, process_error("cannot make a pipe", win.GetLastError())
		}
	}
	if spec.pty {
		rows := spec.rows if spec.rows > 0 else 24
		cols := spec.cols if spec.cols > 0 else 80
		if hr := CreatePseudoConsole({X = win.SHORT(cols), Y = win.SHORT(rows)}, theirs[0], theirs[1], 0, &console); hr < 0 {
			return nil, process_error("cannot make a console", win.DWORD(hr))
		}
		// The console has its own of these now.
		win.CloseHandle(theirs[0])
		win.CloseHandle(theirs[1])
		theirs = {}
	}

	job := CreateJobObjectW(nil, nil)
	if job == nil {
		return nil, process_error("cannot make a job object", win.GetLastError())
	}
	defer if err != "" && job != nil {
		win.CloseHandle(job)
	}
	limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if !SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS, &limits, size_of(limits)) {
		return nil, process_error("cannot make a job object", win.GetLastError())
	}

	// What it inherits is named, and nothing else is: the handles this process has are not the child's business.
	size: win.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &size)
	attributes := make([]byte, size, context.temp_allocator)
	if !InitializeProcThreadAttributeList(raw_data(attributes), 1, 0, &size) {
		return nil, process_error("cannot start a process", win.GetLastError())
	}
	defer DeleteProcThreadAttributeList(raw_data(attributes))
	info: STARTUPINFOEXW
	info.StartupInfo.cb = size_of(info)
	info.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES
	info.lpAttributeList = raw_data(attributes)
	flags := win.DWORD(win.CREATE_UNICODE_ENVIRONMENT | win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_SUSPENDED)
	inherit := false
	if spec.pty {
		// No std handles, so that it has the console's rather than any of this process's.
		if !UpdateProcThreadAttribute(raw_data(attributes), 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, rawptr(console), size_of(HPCON), nil, nil) {
			return nil, process_error("cannot start a process", win.GetLastError())
		}
	} else {
		info.StartupInfo.hStdInput, info.StartupInfo.hStdOutput, info.StartupInfo.hStdError = theirs[0], theirs[1], theirs[2]
		if !UpdateProcThreadAttribute(raw_data(attributes), 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, &theirs, size_of(theirs), nil, nil) {
			return nil, process_error("cannot start a process", win.GetLastError())
		}
		inherit = true
		// A group of its own, for Ctrl-Break to reach; this process's console if it has one, so that the group can
		// be reached on it, and else one of its own that nobody sees.
		flags |= win.CREATE_NEW_PROCESS_GROUP
		if win.GetConsoleWindow() == nil {
			flags |= win.CREATE_NO_WINDOW
		}
	}

	if spec.pty {
		// Whether Ctrl-C is ignored is handed down to whatever starts, and this process may have been started so (a
		// service, or a group of its own): a terminal's programs must hear the Ctrl-C typed into it all the same.
		win.SetConsoleCtrlHandler(nil, false)
	}
	command := process_command_line(argv)
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(win.utf8_to_wstring(path), command, nil, nil, win.BOOL(inherit), flags, process_environment(spec), win.utf8_to_wstring(dir), &info.StartupInfo, &pi) {
		errno := win.GetLastError()
		#partial switch win.System_Error(errno) {
		case .FILE_NOT_FOUND, .PATH_NOT_FOUND:
			return nil, strings.concatenate({"no such program: ", argv[0]}, context.temp_allocator)
		case .ACCESS_DENIED:
			return nil, strings.concatenate({"permission denied: ", argv[0]}, context.temp_allocator)
		case .BAD_EXE_FORMAT, .EXE_MACHINE_TYPE_MISMATCH:
			return nil, strings.concatenate({"not a program: ", argv[0]}, context.temp_allocator)
		case .DIRECTORY:
			return nil, strings.concatenate({"no such directory: ", dir}, context.temp_allocator)
		}
		return nil, process_error(strings.concatenate({"cannot run ", argv[0]}, context.temp_allocator), errno)
	}
	// In its job before it can start anything that would not be.
	if !AssignProcessToJobObject(job, pi.hProcess) {
		errno := win.GetLastError()
		win.TerminateProcess(pi.hProcess, 1)
		win.CloseHandle(pi.hThread)
		win.CloseHandle(pi.hProcess)
		return nil, process_error("cannot put a process in its job", errno)
	}
	win.ResumeThread(pi.hThread)
	win.CloseHandle(pi.hThread)

	p = new(Process)
	p.events = events
	p.process = pi.hProcess
	p.job = job
	p.pid = pi.dwProcessId
	p.console = console
	p.input = mine[0]
	p.output = {mine[1], mine[2]}
	p.reading = true
	for h, i in p.output {
		if h != nil {
			p.bufs[i] = make([]byte, PROCESS_READ)
		}
	}
	for h in mine {
		if h != nil {
			nbio.associate_handle(uintptr(h))
		}
	}
	// The process's now, and closed by process_free, whatever happens: not by what is deferred here too.
	mine, console, job = {}, nil, nil
	p.exit_op = nbio.prep_timeout(0, process_exited)
	p.exit_op.user_data[0] = p
	nbio.detach(p.exit_op)
	if !win.RegisterWaitForSingleObject(&p.wait, p.process, process_ended, p, win.INFINITE, win.WT_EXECUTEONLYONCE | win.WT_EXECUTELONGFUNCTION) {
		errno := win.GetLastError()
		p.wait = nil
		process_free(p)
		return nil, process_error("cannot wait for a process", errno)
	}
	process_listen(p, 0)
	process_listen(p, 1)
	return p, ""
}

process_read :: proc(p: ^Process, want: bool) {
	if p.freed {
		return
	}
	// A read waiting in the kernel is left to finish, for taking it back could lose what it got; what it gets is
	// kept, PROCESS_READ at most, until output is wanted again.
	p.reading = want
	if want {
		process_listen(p, 0)
		process_listen(p, 1)
	}
}

process_input :: proc(p: ^Process, bytes: []byte) -> int {
	if p.freed || p.input == nil || p.ending || p.reaped || sync.atomic_load(&p.ended) {
		return 0 // nobody is there to take it, whatever its pipe says
	}
	n := min(len(bytes), process_input_room(p))
	append(&p.held, ..bytes[:n])
	process_flush(p)
	return n
}

// Whether its input is over for good, closed by it or for it: what is given it now will never be taken.
process_input_closed :: proc(p: ^Process) -> bool {
	return p.freed || p.input == nil || p.reaped || sync.atomic_load(&p.ended)
}

process_input_room :: proc(p: ^Process) -> int {
	if p.freed || p.input == nil || p.ending || p.reaped || sync.atomic_load(&p.ended) {
		return 0
	}
	return max(PROCESS_INPUT - len(p.writing) - len(p.held), 0)
}

process_end_input :: proc(p: ^Process) {
	if p.freed || p.console != nil || p.ending {
		return
	}
	p.ending = true
	if p.write_op == nil && len(p.held) == 0 {
		process_input_close(p)
	}
}

process_signal :: proc(p: ^Process, s: Signal) {
	if p.freed {
		return
	}
	switch s {
	case .Interrupt:
		if p.console != nil {
			// Ctrl-C, typed: the console makes it CTRL_C_EVENT for whatever is attached. Ahead of what waits.
			if p.input != nil {
				inject_at(&p.held, 0, 0x03)
				process_flush(p)
			}
			return
		}
		// Ctrl-C is not delivered to a group of its own, but Ctrl-Break is, on the console it shares with this
		// process; on one it does not share, nothing reaches it but its end.
		if !win.GenerateConsoleCtrlEvent(win.CTRL_BREAK_EVENT, p.pid) {
			TerminateJobObject(p.job, 128 + win.UINT(s))
		}
	case .Hangup, .Quit, .Kill, .Terminate:
		TerminateJobObject(p.job, 128 + win.UINT(s))
	case .Stop, .Continue:
		process_suspend(p, s == .Stop)
	}
}

process_resize :: proc(p: ^Process, rows, cols: u16) {
	if p.freed || p.console == nil {
		return
	}
	// Not while the wait's thread is closing the console, which it may be doing as this is asked: then there is
	// nothing to resize, and waiting for it could wait on output that only this thread reads.
	if !sync.mutex_try_lock(&p.console_guard) {
		return
	}
	defer sync.mutex_unlock(&p.console_guard)
	if !sync.atomic_load(&p.taken) {
		ResizePseudoConsole(p.console, {X = win.SHORT(cols), Y = win.SHORT(rows)})
	}
}

process_free :: proc(p: ^Process) {
	if p == nil || p.freed {
		return
	}
	p.freed = true
	p.events = {}
	TerminateJobObject(p.job, 128 + win.UINT(Signal.Kill))
	// What waits on a handle is taken back before it is closed. A read or write taken back no longer touches its
	// buffer once the cancel has returned.
	for &op in p.read_ops {
		if op != nil {
			nbio.remove(op)
			op = nil
		}
	}
	process_input_close(p)
	for &h, i in p.output {
		if h != nil {
			win.CloseHandle(h)
			h = nil
		}
		delete(p.bufs[i])
		p.bufs[i] = nil
	}
	// The wait's thread may be closing the console, which waits for its output to be read: with this end of that
	// closed, it does not wait long, and once this returns the wait's callback has run or never will.
	if p.wait != nil {
		win.UnregisterWaitEx(p.wait, win.INVALID_HANDLE_VALUE)
		p.wait = nil
	}
	if p.console != nil && !sync.atomic_exchange(&p.taken, true) {
		ClosePseudoConsole(p.console)
	}
	p.console = nil
	win.CloseHandle(p.process)
	win.CloseHandle(p.job) // and all of it with it
	p.process, p.job = nil, nil
	if !sync.atomic_load(&p.ended) {
		nbio.reattach(p.exit_op) // never executed, and never will be
		p.exit_op = nil
	}
	// Otherwise the operation is on its way through the loop, and frees the process when it comes.
	if p.telling == 0 && p.exit_op == nil {
		process_release(p)
	}
}

@(private)
process_release :: proc(p: ^Process) {
	delete(p.writing)
	delete(p.held)
	free(p)
}

@(private)
process_told :: proc(p: ^Process) -> bool {
	p.telling -= 1
	if !p.freed {
		return true
	}
	if p.telling == 0 && p.exit_op == nil {
		process_release(p)
	}
	return false
}

// ---------------------------------------------------------------- output

@(private)
process_listen :: proc(p: ^Process, i: int) {
	if !p.reading || p.output[i] == nil || p.read_ops[i] != nil {
		return
	}
	if p.got[i] > 0 {
		// Read while it was not wanted: told on the loop's next turn, not within whatever wants it now.
		p.read_ops[i] = nbio.next_tick_poly2(p, i, proc(op: ^nbio.Operation, p: ^Process, i: int) {
			p.read_ops[i] = nil
			process_deliver(p, i)
		})
		return
	}
	p.read_ops[i] = nbio.read_poly2(nbio.Handle(p.output[i]), 0, p.bufs[i], p, i, proc(op: ^nbio.Operation, p: ^Process, i: int) {
		p.read_ops[i] = nil
		if op.read.err != nil {
			process_eof(p, i) // the end of a pipe is ERROR_BROKEN_PIPE, and any other failure is an end too
			return
		}
		p.got[i] = op.read.read
		process_deliver(p, i)
	})
}

@(private)
process_deliver :: proc(p: ^Process, i: int) {
	if !p.reading {
		return
	}
	if n := p.got[i]; n > 0 {
		p.got[i] = 0
		p.telling += 1
		p.events.on_output(p.events.data, Output_Stream(i + 1), p.bufs[i][:n])
		if !process_told(p) {
			return
		}
	}
	process_listen(p, i)
}

@(private)
process_eof :: proc(p: ^Process, i: int) {
	win.CloseHandle(p.output[i])
	p.output[i] = nil
	delete(p.bufs[i])
	p.bufs[i] = nil
	process_check_done(p)
}

@(private)
process_check_done :: proc(p: ^Process) {
	if p.told || !p.reaped || p.output[0] != nil || p.output[1] != nil {
		return
	}
	p.told = true
	if p.events.on_exit != nil {
		p.telling += 1
		p.events.on_exit(p.events.data, p.exit)
		process_told(p)
	}
}

// ---------------------------------------------------------------- input

@(private)
process_flush :: proc(p: ^Process) {
	if p.write_op != nil || len(p.held) == 0 {
		return
	}
	p.writing, p.held = p.held, p.writing
	p.write_op = nbio.write_poly(nbio.Handle(p.input), 0, p.writing[:], p, proc(op: ^nbio.Operation, p: ^Process) {
		p.write_op = nil
		if op.write.err != nil {
			process_input_close(p) // its stdin is gone, or the console is: what was held never will be taken
			if p.events.on_room != nil && !p.freed {
				p.telling += 1
				p.events.on_room(p.events.data) // so that it is let go of
				process_told(p)
			}
			return
		}
		clear(&p.writing)
		if cap(p.writing) > 64 << 10 {
			shrink(&p.writing)
		}
		if len(p.held) > 0 {
			process_flush(p)
			return
		}
		if p.ending {
			process_input_close(p)
			return
		}
		if p.events.on_room != nil {
			p.telling += 1
			p.events.on_room(p.events.data)
			process_told(p)
		}
	})
}

@(private)
process_input_close :: proc(p: ^Process) {
	if p.input == nil {
		return
	}
	if p.write_op != nil {
		nbio.remove(p.write_op)
		p.write_op = nil
	}
	win.CloseHandle(p.input)
	p.input = nil
	delete(p.writing)
	delete(p.held)
	p.writing, p.held = nil, nil
}

// ---------------------------------------------------------------- the end

// On a thread of the pool, once the process has ended. A console is closed here, for closing it waits until what it
// still has to say is read, which the loop's thread does.
@(private)
process_ended :: proc "system" (data: rawptr, timed_out: win.BOOLEAN) {
	context = runtime.default_context()
	p := (^Process)(data)
	if p.console != nil {
		sync.mutex_lock(&p.console_guard)
		if !sync.atomic_exchange(&p.taken, true) {
			ClosePseudoConsole(p.console)
		}
		sync.mutex_unlock(&p.console_guard)
	}
	op := p.exit_op
	sync.atomic_store(&p.ended, true)
	nbio.exec(op) // queued for the loop's thread, which is woken for it
}

// On the loop's thread, after process_ended.
@(private)
process_exited :: proc(op: ^nbio.Operation) {
	p := (^Process)(op.user_data[0])
	op.detached = false // the loop takes it back after this
	p.exit_op = nil
	if p.freed {
		if p.telling == 0 {
			process_release(p)
		}
		return
	}
	win.UnregisterWaitEx(p.wait, win.INVALID_HANDLE_VALUE) // its callback is over, or all but
	p.wait = nil
	code: win.DWORD
	win.GetExitCodeProcess(p.process, &code)
	p.exit = {code = int(code)}
	p.reaped = true
	process_check_done(p)
}

// Stops, or lets go on, everything in its job.
@(private)
process_suspend :: proc(p: ^Process, stop: bool) {
	list: JOBOBJECT_BASIC_PROCESS_ID_LIST
	if !QueryInformationJobObject(p.job, JOB_OBJECT_BASIC_PROCESS_ID_LIST_CLASS, &list, size_of(list), nil) && win.System_Error(win.GetLastError()) != .MORE_DATA {
		return
	}
	for pid in list.ProcessIdList[:min(list.NumberOfProcessIdsInList, len(list.ProcessIdList))] {
		h := win.OpenProcess(win.PROCESS_SUSPEND_RESUME, false, win.DWORD(pid))
		if h == nil {
			continue
		}
		if stop {
			NtSuspendProcess(h)
		} else {
			NtResumeProcess(h)
		}
		win.CloseHandle(h)
	}
}

// ---------------------------------------------------------------- what it starts with

// A pipe: this end a named pipe server, overlapped for the loop; the other an ordinary client handle, inheritable if
// a child is to have it, synchronous as children and ConPTY expect.
@(private)
process_pipe :: proc(mine, theirs: ^win.HANDLE, inbound: bool, inheritable: bool) -> bool {
	buf: [32]byte
	n := sync.atomic_add(&process_pipes, 1)
	name := strings.concatenate({`\\.\pipe\zsp-`, strconv.write_uint(buf[:16], u64(win.GetCurrentProcessId()), 10), "-", strconv.write_uint(buf[16:], n, 10)}, context.temp_allocator)
	wname := win.utf8_to_wstring(name)
	access := win.PIPE_ACCESS_INBOUND if inbound else win.PIPE_ACCESS_OUTBOUND
	mine^ = win.CreateNamedPipeW(wname, access | win.FILE_FLAG_OVERLAPPED | win.FILE_FLAG_FIRST_PIPE_INSTANCE, win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS, 1, PROCESS_READ, PROCESS_READ, 0, nil)
	if mine^ == win.INVALID_HANDLE_VALUE {
		mine^ = nil
		return false
	}
	security := win.SECURITY_ATTRIBUTES{nLength = size_of(win.SECURITY_ATTRIBUTES), bInheritHandle = win.BOOL(inheritable)}
	theirs^ = win.CreateFileW(wname, win.GENERIC_WRITE if inbound else win.GENERIC_READ, 0, &security, win.OPEN_EXISTING, 0, nil)
	if theirs^ == win.INVALID_HANDLE_VALUE {
		theirs^ = nil
		win.CloseHandle(mine^)
		mine^ = nil
		return false
	}
	return true
}

// The command line a C runtime makes argv of again (CommandLineToArgvW's rules): an argument with a space, a tab or
// a quote is quoted, a quote within escaped, and backslashes doubled where they come before a quote. The program's
// own name is only quoted, for its parse knows no escapes.
@(private)
process_command_line :: proc(argv: []string) -> win.wstring {
	b := strings.builder_make(context.temp_allocator)
	for arg, i in argv {
		if i > 0 {
			strings.write_byte(&b, ' ')
		}
		if i == 0 {
			if strings.contains_any(arg, " \t") || arg == "" {
				strings.write_byte(&b, '"')
				strings.write_string(&b, arg)
				strings.write_byte(&b, '"')
			} else {
				strings.write_string(&b, arg)
			}
			continue
		}
		if arg != "" && !strings.contains_any(arg, " \t\n\v\"") {
			strings.write_string(&b, arg)
			continue
		}
		strings.write_byte(&b, '"')
		slashes := 0
		for c in transmute([]byte)arg {
			switch c {
			case '\\':
				slashes += 1
				continue
			case '"':
				for _ in 0 ..< slashes * 2 + 1 {
					strings.write_byte(&b, '\\')
				}
			case:
				for _ in 0 ..< slashes {
					strings.write_byte(&b, '\\')
				}
			}
			slashes = 0
			strings.write_byte(&b, c)
		}
		for _ in 0 ..< slashes * 2 {
			strings.write_byte(&b, '\\')
		}
		strings.write_byte(&b, '"')
	}
	return win.utf8_to_wstring(strings.to_string(b))
}

// NAME=value from the host's environment, as the spec changes it (names in any case, as Windows has them), sorted as
// Windows wants its blocks, and in UTF-16.
@(private)
process_environment :: proc(spec: Process_Spec) -> rawptr {
	list := make([dynamic]string, context.temp_allocator)
	// Where each name the spec gives is given last, in any case: looked up, not searched for, however many it gives.
	last := make(map[string]int, len(spec.env), context.temp_allocator)
	for entry, i in spec.env {
		last[strings.to_upper(process_env_name(entry), context.temp_allocator)] = i
	}
	block := win.GetEnvironmentStringsW()
	if block != nil {
		for at := ([^]u16)(block); at[0] != 0; {
			n := 0
			for at[n] != 0 {
				n += 1
			}
			entry, _ := win.utf16_to_utf8(at[:n], context.temp_allocator)
			name := strings.to_upper(process_env_name(entry), context.temp_allocator)
			// What the spec says instead, or for a terminal, its own kind instead of the host's.
			if name not_in last && !(spec.pty && name == "TERM") {
				append(&list, entry)
			}
			at = at[n + 1:]
		}
		win.FreeEnvironmentStringsW(block)
	}
	if spec.pty && "TERM" not_in last {
		append(&list, strings.concatenate({"TERM=", spec.term if spec.term != "" else "xterm-256color"}, context.temp_allocator))
	}
	for entry, i in spec.env {
		name := process_env_name(entry)
		if len(name) == len(entry) {
			continue
		}
		if last[strings.to_upper(name, context.temp_allocator)] == i {
			append(&list, entry)
		}
	}
	slice.sort_by(list[:], proc(a, b: string) -> bool {
		return strings.compare(strings.to_upper(process_env_name(a), context.temp_allocator), strings.to_upper(process_env_name(b), context.temp_allocator)) < 0
	})
	b := strings.builder_make(context.temp_allocator)
	for entry in list {
		strings.write_string(&b, entry)
		strings.write_byte(&b, 0)
	}
	strings.write_byte(&b, 0)
	return raw_data(win.utf8_to_utf16(strings.to_string(b)))
}

// The name of NAME=value; one of Windows' own, such as =C:, begins with its =.
@(private)
process_env_name :: proc(entry: string) -> string {
	if eq := strings.index_byte(entry[min(1, len(entry)):], '='); eq >= 0 {
		return entry[:eq + min(1, len(entry))]
	}
	return entry
}

@(private)
process_env_value :: proc(spec: Process_Spec, name: string) -> string {
	#reverse for entry in spec.env {
		if strings.equal_fold(process_env_name(entry), name) {
			return entry[len(name) + 1:] if len(entry) > len(name) else ""
		}
	}
	wname := win.utf8_to_wstring(name)
	n := win.GetEnvironmentVariableW(wname, nil, 0)
	if n == 0 {
		return ""
	}
	value := make([]u16, n, context.temp_allocator)
	n = win.GetEnvironmentVariableW(wname, raw_data(value), n)
	text, _ := win.utf16_to_utf8(value[:n], context.temp_allocator)
	return text
}

// A program by its path, or found on PATH by its name, with .exe or .com if it has no extension of its own.
@(private)
process_find :: proc(name, path: string) -> (found: string, err: string) {
	extended := strings.last_index_byte(name, '.') > strings.last_index_any(name, `\/`)
	if strings.contains_any(name, `\/:`) {
		if process_is_file(name) {
			return name, ""
		}
		if !extended {
			for ext in ([]string{".exe", ".com"}) {
				if candidate := strings.concatenate({name, ext}, context.temp_allocator); process_is_file(candidate) {
					return candidate, ""
				}
			}
		}
		return "", strings.concatenate({"no such program: ", name}, context.temp_allocator)
	}
	path := path
	for dir in strings.split_iterator(&path, ";") {
		if dir == "" {
			continue
		}
		base := strings.concatenate({strings.trim_right(dir, `\/`), `\`, name}, context.temp_allocator)
		if extended && process_is_file(base) {
			return base, ""
		}
		if !extended {
			for ext in ([]string{".exe", ".com"}) {
				if candidate := strings.concatenate({base, ext}, context.temp_allocator); process_is_file(candidate) {
					return candidate, ""
				}
			}
		}
	}
	return "", strings.concatenate({"no such program: ", name}, context.temp_allocator)
}

@(private)
process_is_file :: proc(path: string) -> bool {
	attributes := win.GetFileAttributesW(win.utf8_to_wstring(path))
	return attributes != win.INVALID_FILE_ATTRIBUTES && attributes & win.FILE_ATTRIBUTE_DIRECTORY == 0
}

@(private)
process_error :: proc(what: string, errno: win.DWORD) -> string {
	buf: [16]byte
	return strings.concatenate({what, " (error ", strconv.write_uint(buf[:], u64(errno), 10), ")"}, context.temp_allocator)
}
