# Odin: the toolchain, and what of it we keep as our own

## The toolchain is pinned

Everything here builds with one Odin release, `dev-2026-11` (`laytan/setup-odin` in `.github/workflows/test.yml`).
It is moved deliberately, by a pull request that does nothing else, and only once everything passes on the new
release: `./x check`, `./x test` and `./x selftest` on all three platforms, as CI runs them, and the benches no worse
(`./x bench streams`).

Each night, `.github/workflows/upstream.yml` builds and runs `./x check` and `./x test` with the newest release and the
newest nightly, beside the pinned release as the control. It fails loudly on any breakage, so that what a move would
meet is known before it is made.

When the pin moves, go through [nbio/PATCHES.md](../nbio/PATCHES.md), *Elsewhere in Odin*, for what the new release
fixes:
- The `./x check` guard for `map_entry` and the pointers of `map_insert` and `map_upsert` (`tests/odin_lint.py`) stays
  while the pinned release predates odin-lang/Odin@b1acc19, which fixes odin-lang/Odin#8642. It can go in the pull
  request that pins a release with that commit, with `tests/upstream/odin_8642`'s nightly run saying FIXED to show it.
  Our nbio's lookup-then-assign may stay either way.
- The `.Trunc` guard and `host/files_test.odin`'s open-then-truncate stay until a release fixes odin-lang/Odin#8646.
- `host/interfaces_bsd.odin` may give way to core:net's `enumerate_interfaces` once the release has b1acc19. It need
  not.

## Our event loop is ours

`nbio/` is ZSP's event loop, taken from `core:nbio` at the release above and kept here ([nbio/README.md](../nbio/README.md)).
Upstream's changes to `core:nbio` are never taken wholesale. Each is reviewed and brought in by hand:

1. Diff upstream's `core/nbio` between the tag in PATCHES.md and the new one.
2. For each change, decide whether it applies, and apply it with a test where it changes behaviour.
3. Check that each PATCHES.md entry still holds, with its test. Where upstream now fixes the same thing, keep the
   simpler of the two, and say so in the entry.
4. Update PATCHES.md: the tag it is taken from, and each entry it touches.

The nightly job also runs `tests/upstream`, a repro of each PATCHES.md entry, against stock Odin with the newest
nightly. This is information only: "FIXED UPSTREAM" in its summary says upstream has changed, and what we may simplify
when the pin next moves. A repro must still say BROKEN against the pinned release (or it no longer shows anything), and
FIXED against ours (or our fix is broken); either failing fails the run.

Anything else found wrong upstream goes into PATCHES.md as fixed here, with upstream status "no issue". Nothing is
posted upstream.
