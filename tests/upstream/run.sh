#!/bin/sh
# One of the repros here, of what upstream Odin gets wrong that we work round (nbio/PATCHES.md), built and run, and what
# it says judged against what is expected of the toolchain it is built with:
#
#   tests/upstream/run.sh <repro> pinned|latest|ours
#
# Each repro prints "BROKEN: ..." or "FIXED: ...", or, if its head says "Crash: BROKEN", may crash for BROKEN; anything
# else is the repro's own failure. Its head says the platforms it means something on ("Platform:"), and whether ours is
# to be held to it ("Ours: FIXED").
#
# pinned: with the release CI builds with ($ODIN, or the odin on PATH), against stock core:nbio and Odin. The control:
# it must say BROKEN, or it shows nothing any more, and it fails.
# latest: with the newest nightly ($ODIN), against stock. Information only, never a failure: FIXED is said plainly, as
# fixed upstream and what we may simplify; a repro that no longer builds or runs there is a warning.
# ours: with the release, the repro's core:nbio swapped for ours (nbio/). It must say FIXED, or our fix is broken, and
# it fails.
#
# What each said goes in the run's summary when there is one ($GITHUB_STEP_SUMMARY). Run by
# .github/workflows/upstream.yml, never by ./x test: odin_8645 takes every ephemeral port of the machine it is on.
set -u
name=$1
mode=$2
ODIN=${ODIN:-odin}
here=$(cd "$(dirname "$0")" && pwd)
root=$(dirname "$(dirname "$here")")
src="$here/$name/main.odin"
[ -f "$src" ] || { echo "no repro $name"; exit 1; }
version=$("$ODIN" version 2>&1 | head -n 1 | sed 's/.* version //') # as dev-2026-11:e28f5d1
EXE=
[ "${OS:-}" = Windows_NT ] && EXE=.exe
# Built in build/, inside the tree, so that ours is imported by a path relative to it, as Odin takes it everywhere.
mkdir -p "$root/build"
dir=$(mktemp -d "$root/build/upstream-XXXXXX")
trap 'rm -rf "$dir"' EXIT
# What it reproduces: its first sentence, which may go on to the lines after the first, up to its marks.
what=$(awk 'NR == 1 || (/^\/\/ / && !/^\/\/ (Platform|Ours|Crash):/ && go) { sub(/^\/\/ (Reproduces )?/, ""); printf "%s%s", (NR > 1 ? " " : ""), $0; go = 1; next } { exit }' "$src" | sed 's/\.$//')
crash_is_broken=
grep -q '^// Crash: BROKEN' "$src" && crash_is_broken=1

say() { # to the log, and to the summary if there is one
	echo "$1"
	[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$1" >>"$GITHUB_STEP_SUMMARY"
	return 0
}
fail() {
	say "- **FAILED** $name, $mode ($version): $1"
	echo "::error::$name, $mode ($version): $1"
	exit 1
}
inform() { # latest: never a failure
	say "- $name, $mode ($version): $1"
	echo "::warning::$name, $mode ($version): $1"
	exit 0
}

# The repro to build: as it is, or with our nbio for core:nbio.
mkdir -p "$dir/$name"
if [ "$mode" = ours ]; then
	grep -q '^// Ours: FIXED' "$src" || { say "- $name: ours is not held to it"; exit 0; }
	sed 's|^import "core:nbio"$|import nbio "../../../nbio"|' "$src" >"$dir/$name/main.odin"
	grep -q '^import nbio "../../../nbio"$' "$dir/$name/main.odin" || fail "it imports no core:nbio to swap for ours"
else
	cp "$src" "$dir/$name/main.odin"
fi
if ! "$ODIN" build "$dir/$name" -out:"$dir/repro$EXE" -vet -strict-style -define:ODIN_NBIO_QUEUE_SIZE=256 >"$dir/build.log" 2>&1; then
	cat "$dir/build.log"
	[ "$mode" = latest ] && inform "the repro does not build"
	fail "the repro does not build"
fi
"$dir/repro$EXE" >"$dir/out.log" 2>&1
code=$?
cat "$dir/out.log"
line=$(grep -E '^(BROKEN|FIXED): ' "$dir/out.log" | head -n 1)
verdict=${line%%:*}
if [ -z "$line" ] && [ "$code" != 0 ] && [ -n "$crash_is_broken" ]; then
	verdict=BROKEN
	line="BROKEN: it crashed, exit $code"
elif [ -z "$line" ] || [ "$code" != 0 ]; then
	verdict=
fi
detail=${line#*: }

case "$mode:$verdict" in
pinned:BROKEN) say "- $name ($what), stock, pinned ($version): still broken, as expected. $detail" ;;
pinned:FIXED) fail "the repro no longer shows it on the release it was made against. $detail" ;;
ours:FIXED) say "- $name ($what), ours ($version): fixed, as it must be. $detail" ;;
ours:BROKEN) fail "our nbio no longer fixes it. $detail" ;;
latest:BROKEN) say "- $name ($what), stock, latest ($version): still broken upstream. $detail" ;;
latest:FIXED)
	simplify="the part of nbio/PATCHES.md for it may be simplified once a release with it is pinned"
	[ "$name" = odin_8642 ] && simplify="the ./x check guard for it can go once a release with it is pinned"
	say "- **FIXED UPSTREAM** in $version: $name ($what). $detail; $simplify."
	echo "::notice::FIXED UPSTREAM in $version: $name"
	;;
latest:*) inform "the repro exited $code, saying neither BROKEN nor FIXED" ;;
*) fail "the repro exited $code, saying neither BROKEN nor FIXED" ;;
esac
