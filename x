#!/bin/sh
# Everything there is to do here: ./x [check|test|build|wasm|sim|bench [find]|nat|slow]
set -eu
cd "$(dirname "$0")"
mkdir -p build
for d in /opt/homebrew/opt/lld*/bin /usr/local/opt/lld*/bin; do # Homebrew keeps wasm-ld to itself
	[ -d "$d" ] && PATH="$PATH:$d"
done
PYTHON=python3
command -v python3 >/dev/null || PYTHON=python
EXE=
[ "${OS:-}" = Windows_NT ] && EXE=.exe
STRICT="-vet -strict-style"
SMALL="-define:ZSP_SEGMENT=262144" # so that tests roll and reclaim segments

wasm() {
	odin build relay/wasm -target:js_wasm32 -o:size -out:relay/src/relay.wasm -no-entry-point $STRICT \
		-extra-linker-flags:"--strip-all -z stack-size=262144 --stack-first"
}

end_to_end() {
	[ -d relay/node_modules ] || (cd relay && npm install --silent)
	$PYTHON tests/end_to_end.py "$@"
}

case "${1:-test}" in
check) # every platform, no code generated
	for t in linux_amd64 linux_arm64 darwin_arm64 windows_amd64 freebsd_amd64; do
		odin check zspd -target:$t $STRICT && echo "ok   $t"
	done
	odin check relay/wasm -target:js_wasm32 -no-entry-point $STRICT && echo "ok   js_wasm32"
	luau-analyze luau/zsp/init.luau && echo "ok   luau"
	;;
test)
	# Side by side, since none needs another; each says what it has to say at its end.
	rm -f build/failed
	for p in zsp pipe find host; do
		(odin test $p -out:build/$p-test$EXE $STRICT $SMALL -define:ZSP_FIND_ASK=2 -define:ZSP_FIND_WALK=4 -define:ZSP_FIND_DEAD=8 -define:ZSP_FIND_TOUCHED=3 >build/$p.log 2>&1 || echo $p >>build/failed; cat build/$p.log) &
	done
	(odin build zspd -out:build/zspd$EXE -debug $STRICT -define:ZSP_CALL_ALIVE=1000 || echo zspd >>build/failed) &
	(odin build vectors -out:build/vectors$EXE $STRICT || echo vectors >>build/failed) &
	[ -f relay/src/relay.wasm ] && [ -z "$(find zsp relay/wasm -name "*.odin" -newer relay/src/relay.wasm)" ] || wasm || echo wasm >>build/failed
	wait
	[ ! -f build/failed ]
	build/vectors$EXE | cmp - vectors/vectors.json
	node tests/vectors.mjs vectors/vectors.json
	lune run luau/tests/vectors.luau vectors/vectors.json
	lune run luau/tests/client.luau
	end_to_end
	;;
build)
	# Whole-program optimisation, in parallel where the linker speaks the compiler's own LLVM.
	want=$(odin report 2>/dev/null | sed -n 's/.*LLVM \([0-9]*\).*/\1/p')
	case "$(clang --version 2>/dev/null) $(ld.lld --version 2>/dev/null)" in
	*"clang version $want."*"LLD $want."*) lto=-lto:thin ;;
	*) lto= ;;
	esac
	odin build zspd -out:build/zspd$EXE -o:speed $lto $STRICT
	;;
wasm) wasm ;;
sim) # as many worlds as you have patience for: ./x sim 10000 [first]
	odin test zsp -o:speed -out:build/sim$EXE $SMALL -define:ZSP_SEEDS=${2:-5000} -define:ZSP_FIRST_SEED=${3:-1000} \
		-define:ZSP_TEXT_SEEDS=${2:-5000} -define:ZSP_FUZZ=$((${2:-5000} / 10))
	odin test find -o:speed -out:build/find-sim$EXE $SMALL -define:ZSP_FIND_SEEDS=${2:-5000} -define:ZSP_FIND_FIRST=${3:-1000} \
		-define:ZSP_FIND_ASK=2 -define:ZSP_FIND_WALK=4 -define:ZSP_FIND_DEAD=8 -define:ZSP_FIND_TOUCHED=3
	;;
bench)
	if [ "${2:-}" = find ]; then # what it costs to ask: ./x bench find [rows]
		odin build bench/find -out:build/bench-find$EXE -o:speed $STRICT
		build/bench-find$EXE ${3:-1000000}
	else
		odin build bench -out:build/bench$EXE -o:speed $STRICT
		build/bench$EXE build/bench-data
	fi
	;;
nat) odin build zspd -out:build/zspd -debug $STRICT && sudo tests/nat.sh && sudo env NAT_B=--random-fully EXPECT_RELAY=1 tests/nat.sh ;;
slow) wasm && odin build zspd -out:build/zspd$EXE -debug $STRICT -define:ZSP_CALL_ALIVE=1000 && end_to_end slow_hibernation ;;
*) sed -n 2p "$0" && exit 2 ;;
esac
