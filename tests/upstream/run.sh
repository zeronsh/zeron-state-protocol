#!/bin/sh
# One of the repros here, of the Odin bugs third_party/nbio works round, built with the odin on PATH and run, and what
# it says judged against what that toolchain is expected to say:
#
#   tests/upstream/run.sh <issue> pinned|latest
#
# pinned, the release CI builds with: the repro must say BROKEN. If it says FIXED there, it no longer shows what it was
# made to, and it fails.
# latest, the newest nightly: BROKEN is as expected; FIXED is said plainly, as the issue fixed upstream, and is no failure.
# Whatever else (it does not build, crashes, says neither) fails. What it said is put in the run's summary when there
# is one ($GITHUB_STEP_SUMMARY).
#
# Run by .github/workflows/upstream.yml, never by ./x test: odin_8645 takes every ephemeral port of the machine it is on.
set -u
issue=$1
toolchain=$2
cd "$(dirname "$0")"
version=$(odin version 2>&1 | head -n 1)
EXE=
[ "${OS:-}" = Windows_NT ] && EXE=.exe
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT

say() { # to the log, and to the summary if there is one
	echo "$1"
	[ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "$1" >>"$GITHUB_STEP_SUMMARY"
	return 0
}

what="odin-lang/Odin#$issue on ${RUNNER_OS:-$(uname -s)}, $toolchain ($version)"
if ! odin build "odin_$issue" -out:"$dir/repro$EXE" -vet -strict-style >"$dir/build.log" 2>&1; then
	cat "$dir/build.log"
	say "- **FAILED** $what: the repro does not build"
	echo "::error::$what: the repro does not build"
	exit 1
fi
"$dir/repro$EXE" >"$dir/out.log" 2>&1
code=$?
cat "$dir/out.log"
line=$(grep -E '^(BROKEN|FIXED): ' "$dir/out.log" | head -n 1)
case "$code:$line:$toolchain" in
0:BROKEN:*:pinned)
	say "- $what: still broken, as expected. ${line#BROKEN: }"
	;;
0:BROKEN:*:latest)
	say "- $what: still broken upstream. ${line#BROKEN: }"
	;;
0:FIXED:*:latest)
	say "- **FIXED UPSTREAM**: $what no longer shows it. ${line#FIXED: } Once a release has it, the part of third_party/nbio for it can go (see its README)."
	echo "::notice::FIXED UPSTREAM: $what no longer shows it"
	;;
0:FIXED:*:pinned)
	say "- **FAILED** $what: the repro no longer shows it on the release it was made against. ${line#FIXED: }"
	echo "::error::$what: the repro no longer shows the bug on the pinned release"
	exit 1
	;;
*)
	say "- **FAILED** $what: the repro exited $code, saying neither BROKEN nor FIXED"
	echo "::error::$what: the repro exited $code, saying neither BROKEN nor FIXED"
	exit 1
	;;
esac
