package host

import win32 "core:sys/windows"

// What wakes the host's loop, from any thread: here an APC queued to the loop's thread, which the system keeps until the
// thread next waits alertably, as the loop does, and which then ends that wait. So a wake is never lost, however soon
// before the loop waits it comes: core:nbio's own wakes only a loop that has said it is waiting already.
@(private)
Waker :: win32.HANDLE // the loop's thread

@(private)
waker_init :: proc(h: ^Host) -> bool {
	process := win32.GetCurrentProcess()
	return bool(win32.DuplicateHandle(process, win32.GetCurrentThread(), process, &h.waker, 0, false, win32.DUPLICATE_SAME_ACCESS))
}

@(private)
waker_wake :: proc(h: ^Host) {
	win32.QueueUserAPC(proc "system" (_: win32.ULONG_PTR) {}, h.waker, 0)
}

// On the loop's thread, as the host is let go of: wakes queued and not yet delivered are delivered now, and so are not
// left to end a wait of whatever this thread does next, which may not expect it. SHFileOperationW, as os.remove_all
// calls it, does not, and raises and catches an exception of its own there.
@(private)
waker_destroy :: proc(h: ^Host) {
	SleepEx(0, true)
	win32.CloseHandle(h.waker)
}

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private)
foreign kernel32 {
	SleepEx :: proc(milliseconds: win32.DWORD, alertable: win32.BOOL) -> win32.DWORD ---
}
