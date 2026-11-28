# core:nbio, carried here for now

**Temporary.** This is Odin's `core:nbio` as the `dev-2026-11` release has it (tag commit `e28f5d1ff420`, the release
CI installs), with the changes below and nothing else. Every change is marked `ZSP:` in the source.

Drop the copy, and import `core:nbio` again, once an Odin release fixes all three of:

- [odin-lang/Odin#8642](https://github.com/odin-lang/Odin/issues/8642): the runtime's `__dynamic_map_entry` can give
  back another key's slot, which on macOS and the BSDs loses kqueue operations;
- [odin-lang/Odin#8644](https://github.com/odin-lang/Odin/issues/8644): on Windows, a read or write of a connection its
  peer reset never completes;
- [odin-lang/Odin#8645](https://github.com/odin-lang/Odin/issues/8645): on Windows, a dial whose bind fails closes its
  socket twice, the second time whatever socket was given that handle meanwhile;

and has the rest below, or they are kept as fixes of ours.

It is under Odin's license, in `LICENSE` beside it.

## Why

`map_entry` (`base:runtime`, `__dynamic_map_entry`) can give back the slot of another key. When inserting a key meets a
tombstone in a map with no empty slot, the insertion shifts entries back round the table, and can move the key it has
just placed after it has taken that key's slot as the one to give back. What the caller writes through it lands on
another key, and the new key is left with a zero value. The release has it, as Odin's master does at the time of writing.

On macOS and the BSDs, `core:nbio` keeps what it has given kqueue in such a map, adding each with `map_entry` and writing
the operation through it. A busy event loop's map is small, and churned by every operation, so it reaches that state:
the loop then lost an operation and failed `assert(del != nil)` when kqueue said it was ready, and a node died. The
forwarder (examples/forward) died so in CI on macOS. `host/nbio_test.odin`, `loop_churn_loses_no_operation`, fails
within a second with the release's `core:nbio`, and passes with this copy.

## What differs from the release

Each has a test in `host/nbio_test.odin` that fails without it, where the platform it is on runs it.

All platforms:
- `nbio.odin`, `Operation.system_error`: the system's own code for the failure an operation ended with, taken where it
  failed. The error an operation gives keeps only a category, and the system's last error, read in the callback, may be
  another's by then: on Windows, what the loop's wait said (often 258, a timeout). In the padding after `detached`, so
  an operation is no larger.
- `impl_posix.odin`, `impl_linux.odin`: what a removed operation took hold of, all the same, is let go of: a socket
  accepted or connected, or a file opened, which nobody would otherwise ever close.

kqueue (macOS, the BSDs), `impl_posix.odin`:
- `add_pending` and `timeout_and_delete`: looked up, then assigned, rather than `map_entry` (#8642).
- `__tick`: changes held back for want of room in a kqueue call are moved over only while there is room. The release
  took one before finding there was none and dropped it: kqueue never heard of it, and the operation never completed.
- `handle_completed`: a removed operation does nothing more. The release went on with it in the tick it was ready:
  reading into a buffer its owner may have let go of, accepting or connecting what nobody would be handed.
- `cleanup`: an operation with a timer kqueue may still fire goes back to the pool only once the timer's deletion has
  been given to kqueue (`_Event_Loop.retired`), and what kqueue says of it meanwhile is ignored. The release put it back
  at once, and a timer firing before a deletion held back in the overflow handed the loop an operation freed or reused.

Windows, `impl_windows.odin`:
- `accept_exec`, `dial_exec`, `recv_exec`, `send_exec`, `sendfile_exec`, `read_exec`, `write_exec`: an overlapped call
  that fails is left to complete later only if the system says `ERROR_IO_PENDING` (#8644). A call that fails as it is
  made leaves `over.Internal` at `STATUS_PENDING` all the same, and no completion ever comes for it (measured, with the
  port tied as nbio ties it: `WSARecv` and `WSASend` on a reset connection, `ReadFile` of a file opened only to write,
  `WriteFile` of one opened only to read). The release took it for one under way, and waited for ever.
- `dial_exec`: a socket whose bind failed is closed once, by `dial_callback` (#8645).
- `accept_callback`, `dial_callback`: `SO_UPDATE_ACCEPT_CONTEXT` and `SO_UPDATE_CONNECT_CONTEXT` are checked, and their
  failure is the operation's; and no socket is closed that was never made (the release closed handle 0, which said
  nothing but left the last error at 10038).
- `link_timeout`: an operation keeps the timeout it has. A send or receive of `all` that went only part of the way is
  executed again, and the release linked it a second timeout, which took the first's place and left it to fire at an
  operation done with by then.
- `__tick`, `compute_timeout`: the wait given the completion port is rounded up to a whole millisecond, and kept short
  of `INFINITE`. The release truncated it: a wait of under a millisecond, as is left of most once the system wakes a
  little early, was none, and the loop spun until it was over; one of more than some 49 days wrapped round.
- `check_timeouts`: the first timeout due is taken out of the tree before it is completed. The release walked the tree
  with an iterator holding the next node, which a callback removing that timeout freed under it.

## Not here, but of the same release

- `core:net`'s `enumerate_interfaces` on macOS, OpenBSD and NetBSD gathers interfaces with `map_entry`, writing through
  it: `host/interfaces_bsd.odin` walks `getifaddrs` itself there, as `host/interfaces_linux.odin` does.
- `core:net`'s `set_option(.Linger)` on macOS and the BSDs gives the system a `timeval` rather than a `linger`. Nothing
  here sets `.Linger`.

## To check the copy

```sh
diff -r "$(odin root)/core/nbio" third_party/nbio
```

shows only the changes above, the lines atop `doc.odin` that say this is a copy, `README.md` and `LICENSE`, with the
release installed.

`./x check` fails on any use, anywhere here, of what #8642 breaks, or of what of core uses it (`tests/odin_lint.py`
says what), `core:nbio` among them; and on core:os's open with `.Trunc` but not `.Create` in a file built for Windows,
which always fails there ([odin-lang/Odin#8646](https://github.com/odin-lang/Odin/issues/8646); this copy's own open,
by `NtCreateFile`, truncates so as asked). `./x selftest` shows that it finds each, however written.

## Whether upstream has fixed them

`.github/workflows/upstream.yml` runs a repro of each issue (`tests/upstream`) each night, with the release and with the
newest nightly: #8642 on Linux and macOS, #8644, #8645 and #8646 on Windows. That they are still broken is no failure; one
fixed upstream is said in the run's summary, as **FIXED UPSTREAM**. Once a release has #8642, #8644 and #8645, the
copy can go; once one has #8646, host/files_test.odin may open with `.Trunc` again.
