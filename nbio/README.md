# nbio: ZSP's event loop

This is the event loop every node here runs on: non-blocking sockets, files and timers, on io_uring (Linux), kqueue
(macOS, the BSDs) and I/O completion ports (Windows). It is ours. It was taken from Odin's `core:nbio`, as the
`dev-2026-11` release has it (tag commit `e28f5d1ff420`), and we keep it, with fixes of ours that upstream does not
have. `core:nbio` is not imported anywhere here, and `./x check` fails if it is (`tests/odin_lint.py`).

- **[PATCHES.md](PATCHES.md)** lists every way it differs from upstream, with why, the test that proves each, and
  upstream's status. It also covers what else of Odin we work round. Every change is marked `ZSP:` in the source.
- **[docs/odin.md](../docs/odin.md)** says how the toolchain is moved and how upstream's changes to `core:nbio` are
  brought in: by hand, each updating PATCHES.md.
- It is under Odin's license, in `LICENSE` beside it.

To see what ours does otherwise, against the release it was taken from, with that release installed:

```sh
diff -r "$(odin root)/core/nbio" nbio
```

This shows the changes PATCHES.md lists, the lines atop `doc.odin`, `README.md`, `PATCHES.md` and `LICENSE`. To see
what upstream has changed since, diff its `core/nbio` between `e28f5d1ff420` and the new release, in Odin's own
repository.

Its tests are `host/nbio_test.odin`, run by `./x test`. `.github/workflows/upstream.yml` runs, each night, a repro of
each of PATCHES.md's entries against stock Odin, to learn when upstream changes, and against ours.
