# What ours does otherwise than upstream

`nbio/` is ZSP's own event loop. It was taken from Odin's `core:nbio` as the `dev-2026-11` release has it (tag commit
`e28f5d1ff420`), in this repository's commit "Carry Odin's core:nbio here, as its dev-2026-11 release has it", untouched.
Every change since is marked `ZSP:` in the source and listed here. This file is the checklist for bringing in upstream's
changes ([docs/odin.md](../docs/odin.md)):

1. Diff upstream's `core/nbio` between the tag above and the new one.
2. Take what applies, by hand.
3. Check each entry below still holds, with its test.
4. Update the tag above.

It also lists what else of Odin we work round, outside `nbio/`.

Each entry gives:
- **Platform**, and what goes wrong upstream (**symptom**).
- **Upstream**, where the release has it (`core/nbio/...` at `e28f5d1`).
- **Status** upstream:
  - `open (#N)`;
  - `fixed in <commit>, in release <tag>`, or `fixed in <commit>, not yet released`;
  - or `no issue`. We post nothing upstream.
- **Ours**, what we do instead.
- **Test**, the test of ours that fails without the change.
- **Repro**, the standalone program, against stock, in `tests/upstream/`. The nightly job (`.github/workflows/upstream.yml`) runs each against stock with the pinned release (the control: still broken) and with the newest nightly (information only: whether upstream changed), and against ours (fixed).

Tests are in `host/nbio_test.odin` unless said otherwise.

## nbio/, kqueue (macOS, the BSDs): impl_posix.odin

### Operations lost from the map of those given kqueue
- **Platform:** macOS, the BSDs.
- **Symptom:** `assert(del != nil)` when kqueue says an operation is ready; a node dies. The forwarder died so in CI.
- **Upstream:** `add_pending` (impl_posix.odin:1172) and `timeout_and_delete` (:1322) add with `map_entry` and write through its pointer, which can be another key's (see *base:runtime map_entry* below).
- **Status:** fixed in b1acc19 (odin-lang/Odin#8643, for #8642), not yet released. The fix is in the runtime, under nbio.
- **Ours:** look up, then assign (`m[k] = v`), never `map_entry`. This can stay after the runtime is fixed: it costs nothing, and is plainer.
- **Test:** `loop_churn_loses_no_operation`. **Repro:** `odin_8642`.

### A change held back for want of room, dropped
- **Platform:** macOS, the BSDs.
- **Symptom:** an operation added while one kqueue call's changes were full never completes.
- **Upstream:** `__tick` (impl_posix.odin:181–182) pops a change from the overflow before finding there is no room for it, and drops it.
- **Status:** no issue.
- **Ours:** changes are moved over only while there is room.
- **Test:** `loop_gives_every_change_it_held_back` (773 of 775 timeouts come with the release).

### An operation freed while kqueue still has its timer
- **Platform:** macOS, the BSDs.
- **Symptom:** `assert(op.type != .None)` (impl_posix.odin:251): a timer fires at an operation already put back in the pool, or reused.
- **Upstream:** `cleanup` (:632–637) puts an operation with a timeout back in the pool at once, while the timer's deletion may still be held back in the overflow.
- **Status:** no issue.
- **Ours:** such an operation is retired (`_Event_Loop.retired`) until the changes queued by the time it was done with, its timer's deletion among them, have been given to kqueue. What kqueue says of it meanwhile is ignored. What has been queued is derived as what has been given plus what pending and the overflow still hold. An earlier counter of ours missed two ways of queueing a change, and drifted (review P25-1).
- **Tests:** `loop_keeps_an_operation_kqueue_may_still_name`, and `loop_counts_every_change_it_gives_kqueue` for the drift. **Repro:** `nbio_kqueue_timer_after_free`.

### A removed operation going on
- **Platform:** macOS, the BSDs.
- **Symptom:** a read removed in the tick it was ready reads all the same, into a buffer its owner may have let go of. An accept or dial removed so leaves what it accepted or connected open, and the peer is never told.
- **Upstream:** `handle_completed` (impl_posix.odin:571–592) executes the operation without looking at `.Removed`, and `maybe_callback` (:613–618) then skips it.
- **Status:** no issue.
- **Ours:** a removed operation does nothing more, and `let_go` closes what it had taken: an accepted client, a connected socket, an opened file.
- **Tests:** `loop_reads_nothing_for_a_removed_read`, `loop_lets_go_of_what_a_removed_accept_took`. **Repros:** `nbio_removed_read_reads`, `nbio_removed_accept_leaks`.

## nbio/, io_uring (Linux): impl_linux.odin

### What a removed operation got, left open
- **Platform:** Linux.
- **Symptom:** an accept removed after the kernel accepted for it leaves the connection open, and the peer waits for ever. The same goes for a dial or an open.
- **Upstream:** `maybe_callback` (impl_linux.odin:547–556) skips a removed operation whose result came, and nothing closes what it holds.
- **Status:** no issue.
- **Ours:** `let_go` in both skipping branches.
- **Test:** `loop_lets_go_of_what_a_removed_accept_took`. **Repro:** `nbio_removed_accept_leaks`.

### A read or write of all given the ring again after its removal was asked for
- **Platform:** Linux.
- **Symptom:** an `all` operation that went part of the way before its removal took is given to the ring again for the rest. With more data already there, it reads it at once, into a buffer its owner may have let go of, for nobody.
- **Upstream:** `recv_callback` (impl_linux.odin:862), `send_callback` (:942), `write_callback` (:977) and `read_callback` (:1016) re-execute without looking at `_impl.removal`.
- **Status:** no issue.
- **Ours:** not given again once removing (`removing`); the operation is done with what it has.
- **Test:** `loop_reads_no_more_for_a_removed_read_of_all`. **Repro:** `nbio_removed_partial_rereads`.

## nbio/, Windows: impl_windows.odin

### A call that fails as it is made, waited on for ever
- **Platform:** Windows.
- **Symptom:** a read or write of a connection its peer reset never ends. The same goes for a `ReadFile` of a file opened only to write, a `WriteFile` of one opened only to read, and any overlapped call that fails at once.
- **Upstream:** `accept_exec` (impl_windows.odin:1007), `dial_exec` (:1112), `read_exec` (:1168–1170), `write_exec` (:1250), `recv_exec` (:1348), `send_exec` (:1469) and `sendfile_exec` (:1564) take `is_pending(over)` for a call under way. A call that fails as it is made leaves `over.Internal` at `STATUS_PENDING`, and no completion is ever queued for it (measured, with the port tied as nbio ties it).
- **Status:** open (#8644) for sockets. The file case is no issue (the same mechanism).
- **Ours:** left to complete only on `ERROR_IO_PENDING`; any other failure is the operation's result now.
- **Tests:** `loop_ends_reads_and_writes_of_a_reset_connection`, `loop_ends_a_read_that_fails_as_it_is_made`. **Repros:** `odin_8644`, `nbio_read_fails_as_made`.

### A failed bind's socket closed twice
- **Platform:** Windows.
- **Symptom:** a socket made between a dial whose bind failed and its callback is closed under its owner.
- **Upstream:** `dial_exec` closes the socket on a failed bind (impl_windows.odin:1093), and `dial_callback` closes it again (:1130).
- **Status:** open (#8645).
- **Ours:** closed once, by `dial_callback`.
- **Test:** none in `./x test`: it takes every ephemeral port of the machine. **Repro:** `odin_8645`, on a CI runner of its own.

### Waits under a millisecond, spun through
- **Platform:** Windows.
- **Symptom:** a wait under 1 ms, asked of a tick or to a timeout due that soon, is a poll, and the loop busy-spins until it is over: 54,845 rounds in 30 ms of `tick(500 µs)` on Windows 11. Most timed waits end so, as the system wakes a little early.
  - `host.relayed_held_back_waits` went round 1,135 times in 50 ms, 1,133 of them in a wait under 1 ms; it failed about 1 run in 3 here, and 0 of 11 after the fix.
  - #19 found the same independently. On main, with Windows-only CI, it went round 139, 229 and 238 times in 3 of 20 runs, each from a dialer's ping deadline (`quiet_at + PING_IDLE`) landing in the test's window, with no traffic. Under full CI load it went round 681 times.
- **Upstream:** `__tick` → `compute_timeout` (impl_windows.odin:297, :300), `win.DWORD(d / time.Millisecond)`, truncated. A wait over 2^32 ms wraps round too.
- **Status:** open (#8647).
- **Ours:** round up to a whole millisecond, capped short of `INFINITE` (`wait_ms`). A timeout under 1 ms now fires on the system timer's tick (about 15.6 ms by default), as every longer one already did upstream. The CPU cost of such a wait falls from 0.9–3.2 M cycles and thousands of rounds to about 0.2 M cycles and 2 rounds.
- **Test:** `loop_waits_out_a_wait_of_under_a_millisecond`. **Repro:** `odin_8647`.

### The timeout walk freeing a timeout under itself
- **Platform:** Windows.
- **Symptom:** a timeout's callback that removes the next timeout due crashes the loop (STATUS_ILLEGAL_INSTRUCTION, no output).
- **Upstream:** `check_timeouts` (impl_windows.odin:314–315) walks the tree with an iterator holding the next node; the callback's `remove` frees it.
- **Status:** no issue.
- **Ours:** loop on `avl.first`, taking the node out before completing it.
- **Test:** `loop_lets_a_timeout_remove_the_one_after_it`. **Repro:** `nbio_timeout_removes_next`.

### A second timeout linked over the first
- **Platform:** Windows.
- **Symptom:** a send or receive of `all`, with a timeout, that goes in two pieces asserts later: `target._impl.timeout == op` (impl_windows.odin:1756).
- **Upstream:** `link_timeout` (:1735) links a second timeout when the operation is executed again, and the first, left in the tree, fires at it once it is done with.
- **Status:** no issue.
- **Ours:** an operation keeps the timeout it has.
- **Test:** `loop_keeps_one_timeout_for_a_read_of_all`. **Repro:** `nbio_second_timeout`.

### A read of all never ending at the end of the file
- **Platform:** Windows.
- **Symptom:** a read of all of more than is left of a file, past some bytes, is executed again at the end for ever, or, where `ReadFile` says so as it is made, fails with error 38 (review P25-2).
- **Upstream:** `read_callback` (impl_windows.odin:1211) ends on `HANDLE_EOF` only when nothing was read.
- **Status:** no issue.
- **Ours:** the end ends the read, with `.EOF` only if nothing was read. The end met as the read is made is left as a read of nothing, done.
- **Test:** `loop_ends_a_read_of_all_at_the_end_of_the_file`. **Repro:** `nbio_read_all_eof`.

### A removed open's file left open
- **Platform:** Windows.
- **Symptom:** the file of an open removed once it was open stays open; it cannot even be removed (nbio opens without `FILE_SHARE_DELETE`).
- **Upstream:** `maybe_callback` (impl_windows.odin:418) skips the callback, and nothing closes the handle.
- **Status:** no issue.
- **Ours:** closed there, as `let_go` does on Linux and macOS.
- **Test:** `loop_closes_what_a_removed_open_opened`. **Repro:** `nbio_removed_open_leaks`.

### SO_UPDATE_*_CONTEXT unchecked, and handle 0 closed
- **Platform:** Windows.
- **Symptom:** a failed `SO_UPDATE_ACCEPT_CONTEXT` or `SO_UPDATE_CONNECT_CONTEXT` goes unsaid. A socket never made (handle 0) is "closed", leaving the last error at 10038.
- **Upstream:** `accept_callback` (impl_windows.odin:1025, :1055) and `dial_callback` (:1130, :1141).
- **Status:** no issue.
- **Ours:** checked, their failure the operation's; nothing closed that was never made.
- **Test:** none that can make the system fail them; the code is read in review.

## nbio/, all platforms: nbio.odin and every impl

### No system error code with an operation
- **Platform:** all; shown on Windows.
- **Symptom:** a failed operation's error keeps only a category, and the last error read in the callback is whatever the system said last. On Windows that is the loop's own wait's: a refused dial reads 0 or 258, not 10061.
- **Upstream:** each `net._*_error()` site, e.g. impl_windows.odin:1116, :1147 for a dial, :978–1066 for an accept; the same in impl_posix and impl_linux.
- **Status:** no issue.
- **Ours:** `Operation.system_error: u16`, the system's own code, taken where it failed. It lives in the padding after `detached`, so an operation is no larger. Async write and sendfile callbacks too.
- **Tests:** `loop_keeps_what_the_system_said_of_a_refusal`, `loop_ends_reads_and_writes_of_a_reset_connection`. **Repro:** `nbio_error_code` (stock only: ours keeps the code with the operation rather than mending the last error).

## Not changed, but known

### Cancelling one read of a socket ends its other reads (Winsock)
- **Platform:** Windows.
- **Symptom:** removing one of two reads waiting on a socket ends the other too, with an error. It is Winsock's own doing (AFD aborts a stream socket's other queued receives), not nbio's.
- **Upstream:** `_remove` (impl_windows.odin:775, :787) and a timeout's removal (:1827) cancel with the operation's own `OVERLAPPED`. Seen with raw `WSARecv`s tied to a completion port as nbio ties them: both complete with `STATUS_CANCELLED` (0xC0000120). Writes are not cancelled with them: a pending `WSASend` of 64 MiB went on and completed whole.
- **Status:** no issue (the platform's).
- **Ours:** unchanged.
- **Test:** `loop_keeps_a_write_when_a_read_of_its_socket_is_removed` (a forwarder's case: a write goes on when a read of its socket is removed). On Windows, a write of a socket nbio has made non-blocking is taken by the system as it is made, so the case is held where writes wait (Linux, macOS). `loop_counts_every_change_it_gives_kqueue`, which removes one of two reads, runs only on kqueue for this reason.

### One completion port for every loop of a process
- **Platform:** Windows.
- **Symptom:** every thread's loop shares one completion port, and a completion one loop dequeues for another is handed to it, even if that loop has been let go of meanwhile.
- **Upstream:** `g.iocp` (impl_windows.odin:856–915) and `__tick`'s hand-off (:254–263).
- **Status:** no issue.
- **Ours:** unchanged. zspd runs one loop. `./x test` runs host tests one at a time on Windows (`x`, the comment at `one=`).

## Elsewhere in Odin

### base:runtime map_entry, and the pointer map_insert and map_upsert give back
- **Platform:** all.
- **Symptom:** the slot `map_entry` gives back can be another key's: when inserting meets a tombstone in a map with no empty slot, the backward shift moves the key just placed after its slot was taken. What is written through it lands on another key, and the new key is left with nothing. `map_insert`'s and `map_upsert`'s pointers come from the same path. `m[k] = v` is sound.
- **Upstream:** `map_insert_hash_dynamic_with_key` (base/runtime/dynamic_map_internal.odin:337).
- **Status:** fixed in b1acc19 (odin-lang/Odin#8643), not yet released. Verified with `gh api repos/odin-lang/Odin/commits/b1acc19`: the insert now follows the new entry through the shift, which covers `map_entry`, `map_insert` and `map_upsert` alike, with a test of all three. `tests/upstream/odin_8642` says FIXED against the newest nightly with b1acc19's runtime change applied.
- **Ours:** cannot be patched in the tree. `./x check` fails on any use of `map_entry`, of either pointer, or of what in core uses them (`tests/odin_lint.py`); `./x selftest` shows it finds each, however written. The guard stays while the pinned release predates b1acc19. When a release with it becomes our pin, the guard can go in that upgrade PR (docs/odin.md).
- **Repro:** `odin_8642`.

### core:net enumerate_interfaces on macOS, OpenBSD and NetBSD
- **Platform:** macOS, OpenBSD, NetBSD.
- **Symptom:** interfaces gathered with `map_entry`, written through, so an interface can be lost or given another's address.
- **Upstream:** core/net/interface_posix.odin:44.
- **Status:** fixed with the runtime, in b1acc19 (odin-lang/Odin#8643), not yet released.
- **Ours:** `host/interfaces_bsd.odin` walks `getifaddrs` itself, as `host/interfaces_linux.odin` does. The lint fails on `enumerate_interfaces` in a file built for those platforms.
- **Test:** `host/interfaces_test.odin` (each address bindable, where the host walks them).

### core:os open with .Trunc but not .Create, on Windows
- **Platform:** Windows.
- **Symptom:** `os.open(path, {.Write, .Trunc})` always fails, `INVALID_PARAMETER` (87).
- **Upstream:** core/os/file_windows.odin:118–119: `TRUNCATE_EXISTING` with `FILE_GENERIC_WRITE`, where Windows wants the `GENERIC_WRITE` bit itself.
- **Status:** open (#8646).
- **Ours:** `./x check` fails on such flags in a file that imports core:os and is built for Windows. `host/files_test.odin` opens, then truncates (#28). nbio's own open (by `NtCreateFile`) truncates as asked.
- **Repro:** `odin_8646`.

### core:net set_option(.Linger) on macOS and the BSDs
- **Platform:** macOS, the BSDs.
- **Symptom:** the system is given a `timeval` rather than a `linger`.
- **Status:** no issue.
- **Ours:** nothing here sets `.Linger` outside Windows (`tests/upstream/odin_8644` sets it, and runs on Windows).
