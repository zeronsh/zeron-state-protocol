# core:nbio, carried here for now

**Temporary.** This is Odin's `core:nbio` as the `dev-2026-11` release has it (tag commit `e28f5d1ff420`, the release
CI installs), with the changes below and nothing else. Every change is marked `ZSP:` in the source. Drop the copy, and
import `core:nbio` again, once an Odin release fixes
[odin-lang/Odin#8642](https://github.com/odin-lang/Odin/issues/8642) (the runtime's `__dynamic_map_entry`) and the
defects below.

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

- `impl_posix.odin`, `add_pending` and `timeout_and_delete`: looked up, then assigned, rather than `map_entry`.
- `impl_posix.odin`, `__tick`: changes held back for want of room in a kqueue call are moved over only while there is
  room. The release took one before finding there was none and dropped it: kqueue never heard of it, and the operation
  never completed. `loop_gives_every_change_it_held_back` fails with the release (773 of 775 timeouts come) and passes.
- `impl_windows.odin`, `accept_exec`, `dial_exec`, `recv_exec`, `send_exec`: an overlapped call that fails is left to
  complete later only if Winsock says `ERROR_IO_PENDING`. The release also did so when the failure left `over.Internal`
  set, or was `WSAEWOULDBLOCK`, and no completion comes for either: the operation waited for ever. A read and a write of
  a connection its peer has reset are such: with the release they never end, which the test of them in
  `host/nbio_test.odin` fails on; with this copy each ends at once, with an error.
- `impl_windows.odin`, `dial_exec`: a socket whose bind failed is closed once, by `dial_callback`. The release closed it
  in both, the second time whatever socket had since been given the same handle.
- `impl_windows.odin`, `accept_callback` and `dial_callback`: `SO_UPDATE_ACCEPT_CONTEXT` and `SO_UPDATE_CONNECT_CONTEXT`
  are checked, and their failure is the operation's.
- `impl_windows.odin`, `link_timeout`: an operation keeps the timeout it has. A send or receive of `all` that went only
  part of the way is executed again, and the release linked it a second timeout, which took the first's place and left
  it to fire at an operation done with by then.

Left as the release has them, as nothing here uses them: `sendfile_exec` and `read_exec`/`write_exec` on Windows wait on
a failed call as the four above did.

## Not here, but of the same release

- `core:net`'s `enumerate_interfaces` on macOS, OpenBSD and NetBSD gathers interfaces with `map_entry`, writing through
  it: `host/interfaces_bsd.odin` walks `getifaddrs` itself there, as `host/interfaces_linux.odin` does.
- `core:net`'s `set_option(.Linger)` on macOS and the BSDs gives the system a `timeval` rather than a `linger`.

## To check the copy

```sh
diff -r "$(odin root)/core/nbio" third_party/nbio
```

shows only the changes above, the two lines atop `doc.odin` that say this is a copy, `README.md` and `LICENSE`, with
the release installed.
