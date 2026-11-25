#!/bin/sh
# Everything there is to do here: ./x [check|test|build|wasm|sim|bench|nat|slow]
set -eu
cd "$(dirname "$0")"
mkdir -p build
STRICT="-vet -strict-style"
SMALL="-define:ZSP_SEGMENT=262144" # so that tests roll and reclaim segments

wasm() {
	odin build relay/wasm -target:js_wasm32 -o:size -out:relay/src/relay.wasm -no-entry-point $STRICT \
		-extra-linker-flags:"--strip-all -z stack-size=262144 --stack-first"
}

end_to_end() {
	odin build zspd -out:build/zspd -debug $STRICT
	[ -f relay/src/relay.wasm ] || wasm
	[ -d relay/node_modules ] || (cd relay && npm install --silent)
	python3 tests/end_to_end.py "$@"
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
	odin test zsp -out:build/zsp-test $STRICT $SMALL
	odin test pipe -out:build/pipe-test $STRICT
	odin build vectors -out:build/vectors $STRICT
	build/vectors | cmp - vectors/vectors.json
	node tests/vectors.mjs vectors/vectors.json
	lune run luau/tests/vectors.luau vectors/vectors.json
	end_to_end
	;;
build)
	# Whole-program optimisation, in parallel where the linker speaks the compiler's own LLVM.
	want=$(odin report 2>/dev/null | sed -n 's/.*LLVM \([0-9]*\).*/\1/p')
	case "$(clang --version 2>/dev/null) $(ld.lld --version 2>/dev/null)" in
	*"clang version $want."*"LLD $want."*) lto=-lto:thin ;;
	*) lto= ;;
	esac
	odin build zspd -out:build/zspd -o:speed $lto $STRICT
	;;
wasm) wasm ;;
sim) # as many worlds as you have patience for: ./x sim 10000 [first]
	odin test zsp -o:speed -out:build/sim $SMALL -define:ZSP_SEEDS=${2:-5000} -define:ZSP_FIRST_SEED=${3:-1000} \
		-define:ZSP_TEXT_SEEDS=${2:-5000} -define:ZSP_FUZZ=$((${2:-5000} / 10))
	;;
bench)
	odin build bench -out:build/bench -o:speed $STRICT
	build/bench build/bench-data
	;;
nat) odin build zspd -out:build/zspd -debug $STRICT && sudo tests/nat.sh && sudo env NAT_B=--random-fully EXPECT_RELAY=1 tests/nat.sh ;;
slow) end_to_end slow_hibernation ;;
*) sed -n 2p "$0" && exit 2 ;;
esac
