#!/bin/sh
# Everything there is to do here: ./x [check|test|build|wasm|web|sim|bench [find|edits|mirror|web|partial|streams|aead]|nat|slow]
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
# An event loop's ring of 256 rather than 2048: the kernel finds the smaller run of memory it wants even when it is
# fragmented, as on busy machines where a big one at times could not be had; what does not fit waits its turn.
STRICT="-vet -strict-style -define:ODIN_NBIO_QUEUE_SIZE=256"
SIZED=zsp.review_little_room_whatever_quiet,zsp.review_little_room_pack_before_extent,zsp.review_little_room_small_writes_no_checkpoint # run at full size too
TESTING="-define:ZSP_CALL_ALIVE=1000" # what the end-to-end tests wait on, made short
SMALL="-define:ZSP_SEGMENT=262144 -define:ZSP_LOOSE=12 -define:ZSP_ALIKE=3 -define:ZSP_GC_HOT=4 -define:ZSP_GC_DEAD=1 -define:ZSP_EXTENT=131072 -define:ZSP_LOG_BLOCK=16384 -define:ZSP_LOCAL_KEEP=0" # so that tests roll and reclaim segments

# The relay for speed, with WebAssembly's 128-bit vectors, which Workers have: what it does is mostly ChaCha20-Poly1305.
wasm() {
	odin build relay/wasm -target:js_wasm32 -o:speed -target-features:simd128 -out:relay/src/relay.wasm -no-entry-point $STRICT \
		-extra-linker-flags:"--strip-all -z stack-size=262144 --stack-first"
}

# A device's node for browsers and Node, and one with small segments, so that test/store.ts rolls and drops them often.
web_wasm() {
	odin build web/wasm -target:js_wasm32 -o:size -out:web/src/node.wasm -no-entry-point $STRICT \
		-extra-linker-flags:"--strip-all -z stack-size=262144 --stack-first"
}
web_small() {
	odin build web/wasm -target:js_wasm32 -o:minimal -out:build/node-small.wasm -no-entry-point $STRICT $SMALL \
		-extra-linker-flags:"--strip-all -z stack-size=262144 --stack-first"
}
web_deps() {
	[ -d web/node_modules ] || (cd web && npm ci --silent)
}
relay_deps() {
	[ -d relay/node_modules ] || (cd relay && npm ci --silent)
}
stale() { # whether a file is older than any Odin it is built from
	[ ! -f "$1" ] || [ -n "$(find zsp find pipe web/wasm -name "*.odin" -newer "$1")" ]
}

end_to_end() {
	relay_deps
	$PYTHON tests/end_to_end.py "$@"
}

# The web client and node: on their own, against the other clients, beside zspd devices, and in a browser. Side by side,
# each saying what it has to say at its end.
web_test() {
	cd web
	# Each said failed should it fail: web_test runs as part of `... || echo web`, where sh ignores set -e, so a test
	# that failed and was not said so would pass.
	for t in client node "vectors ../vectors/vectors.json" streams ask utf8 store_cases mirror_edge package udp find_memory; do
		set -- $t
		node "test/$1.ts" ${2:+"$2"} || echo "web-$1" >>../build/failed
	done
	for t in text mirror_model mirror_interop store end_to_end browsers; do
		args=
		[ $t = store ] && args=../build/node-small.wasm
		(node test/$t.ts $args >../build/web-$t.log 2>&1 || echo web-$t >>../build/failed) &
	done
	wait
	for t in text mirror_model mirror_interop store end_to_end browsers; do
		cat ../build/web-$t.log
	done
}

case "${1:-test}" in
check) # every platform, no code generated
	# Each failure said, and the whole failed by any: sh ignores set -e in all of an `a && b` but its last.
	failed=
	said() { if [ "$1" = 0 ]; then echo "ok   $2"; else echo "FAIL $2"; failed=1; fi; }
	for t in linux_amd64 linux_arm64 darwin_arm64 windows_amd64 freebsd_amd64; do
		r=0; odin check zspd -target:$t $STRICT && odin check examples/forward -target:$t $STRICT || r=1; said $r $t
	done
	r=0; odin check relay/wasm -target:js_wasm32 -no-entry-point $STRICT || r=1; said $r js_wasm32
	r=0; odin check web/wasm -target:js_wasm32 -no-entry-point $STRICT || r=1; said $r "js_wasm32 web"
	r=0; luau-analyze luau/zsp/init.luau examples/luau/workspace.luau || r=1; said $r luau
	r=0; web_deps && (cd web && npx tsc -p .) || r=1; said $r typescript
	[ -z "$failed" ]
	;;
test)
	# Side by side, since none needs another; each says what it has to say at its end.
	rm -f build/failed
	for p in zsp pipe find host; do
		# Host tests each run whole hosts, each with an event loop of its own. On Windows core:nbio has those loops share
		# one completion port, and hands what one finds of another's to it, which may have let that go meanwhile: so
		# there they run one at a time, as zspd's one loop always does.
		one=
		[ $p = host ] && [ -n "$EXE" ] && one=-define:ODIN_TEST_THREADS=1
		(odin test $p -out:build/$p-test$EXE $STRICT $SMALL $one -define:ZSP_FIND_ASK=2 -define:ZSP_FIND_WALK=4 -define:ZSP_FIND_DEAD=8 -define:ZSP_FIND_TOUCHED=3 -define:ZSP_FIND_RUN=64 -define:ZSP_FIND_HOT=0 >build/$p.log 2>&1 || echo $p >>build/failed; cat build/$p.log) &
	done
	# And what shows only at the sizes a relay runs with, where CHECKPOINT_TAIL is larger than an extent.
	(odin test zsp -out:build/zsp-sized-test$EXE $STRICT -define:ODIN_TEST_NAMES=$SIZED >build/zsp-sized.log 2>&1 || echo zsp-sized >>build/failed; cat build/zsp-sized.log) &
	(odin build zspd -out:build/zspd$EXE -debug $STRICT $TESTING || echo zspd >>build/failed) &
	(odin build vectors -out:build/vectors$EXE $STRICT || echo vectors >>build/failed) &
	(odin build examples/apps -out:build/apps$EXE -debug $STRICT || echo examples >>build/failed) &
	(odin build examples/forward -out:build/forward$EXE -debug $STRICT || echo examples >>build/failed) &
	(! stale web/src/node.wasm || web_wasm || echo web >>build/failed) &
	(! stale build/node-small.wasm || web_small || echo web >>build/failed) &
	web_deps
	relay_deps # before anything that runs the Durable Object, the web tests among them
	[ -f relay/src/relay.wasm ] && [ -z "$(find zsp relay/wasm -name "*.odin" -newer relay/src/relay.wasm)" ] || wasm || echo wasm >>build/failed
	wait
	[ ! -f build/failed ]
	(web_test >build/web.log 2>&1 || echo web >>build/failed) &
	web=$!
	build/vectors$EXE | cmp - vectors/vectors.json
	node tests/vectors.mjs vectors/vectors.json
	lune run luau/tests/vectors.luau vectors/vectors.json
	lune run luau/tests/client.luau
	# Structured state held to a model, with its shortcuts and without: side by side, as each is a minute or so.
	lune run luau/tests/mirror_model.luau 300 & quick=$!
	lune run luau/tests/mirror_model.luau 300 plain & long=$!
	mfail=; wait $quick || mfail=1; wait $long || mfail=1; [ -z "$mfail" ]
	node examples/relay/test.mjs
	node tests/relay_storage.mjs
	node tests/relay_settle.mjs
	node tests/relay_checkpoints.mjs
	node tests/relay_keep.mjs
	node bench/aead_wasm/run.mjs simd check # zsp's ChaCha20-Poly1305 held to core's in WebAssembly, as the relay runs it
	$PYTHON examples/apps/test.py
	$PYTHON examples/forward/test.py
	$PYTHON examples/organization.py
	end_to_end
	if [ "$(uname)" = Linux ]; then
		# Calls and links again, under AddressSanitizer: what glibc forgives, it does not.
		odin build zspd -out:build/zspd-asan -debug -sanitize:address $STRICT $TESTING
		ZSPD=build/zspd-asan end_to_end test_calls test_direct_links test_sync_through_relay test_call_outlasts_a_pause
	fi
	wait $web || true
	cat build/web.log
	# Tabs as browsers treat them, last and alone: they hold back a Chrome's tabs, restart relays and fill pages, and beside
	# anything that times what it sees would make it late.
	(cd web && node test/tabs.ts) || echo web-tabs >>build/failed
	[ ! -f build/failed ]
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
wasm) wasm && web_wasm ;;
web) # what a browser loads, built into web/dist: ./x web
	web_wasm && web_deps && node web/build.ts
	;;
sim) # as many worlds as you have patience for: ./x sim 10000 [first]
	odin test zsp -o:speed -out:build/sim$EXE $SMALL -define:ZSP_SEEDS=${2:-5000} -define:ZSP_FIRST_SEED=${3:-1000} \
		-define:ZSP_TEXT_SEEDS=${2:-5000} -define:ZSP_FUZZ=$((${2:-5000} / 10))
	odin test find -o:speed -out:build/find-sim$EXE $SMALL -define:ZSP_FIND_SEEDS=${2:-5000} -define:ZSP_FIND_FIRST=${3:-1000} \
		-define:ZSP_FIND_ASK=2 -define:ZSP_FIND_WALK=4 -define:ZSP_FIND_DEAD=8 -define:ZSP_FIND_TOUCHED=3 -define:ZSP_FIND_RUN=64 -define:ZSP_FIND_HOT=0
	;;
bench)
	if [ "${2:-}" = streams ]; then # what streams cost and give, over UDP and a relay: ./x bench streams [bytes]
		odin build host -build-mode:test -o:speed -out:build/bench-streams$EXE $STRICT -define:ZSP_BENCH=true -define:ZSP_BENCH_BYTES=${3:-268435456} -define:ODIN_TEST_NAMES=host.bench_streams
		build/bench-streams$EXE 2>&1 | grep -v "^\[INFO"
	elif [ "${2:-}" = web ]; then # what a web device costs, in Node and in a browser: ./x bench web [rows]
		[ -f build/zspd$EXE ] || odin build zspd -out:build/zspd$EXE -debug $STRICT
		! stale web/src/node.wasm || web_wasm
		web_deps
		node web/build.ts
		node --expose-gc web/test/bench.ts ${3:-100000}
		node web/test/browsers.ts bench
	elif [ "${2:-}" = partial ]; then # a partial web device against a full one, in Node and Chrome, good network and poor: ./x bench partial [rows]
		odin build zspd -out:build/zspd-speed$EXE -o:speed $STRICT
		! stale web/src/node.wasm || web_wasm
		web_deps
		ZSPD=build/zspd-speed$EXE node web/test/browsers.ts partial ${3:-100000}
	elif [ "${2:-}" = mirror ]; then # what structured state costs a client: ./x bench mirror [rows]
		lune run luau/tests/mirror_bench.luau ${3:-2000}
	elif [ "${2:-}" = find ]; then # what it costs to ask: ./x bench find [rows]
		odin build bench/find -out:build/bench-find$EXE -o:speed $STRICT
		build/bench-find$EXE ${3:-1000000}
	elif [ "${2:-}" = aead ]; then # what sealing and opening cost, by message size: ./x bench aead, ./x bench aead wasm
		if [ "${3:-}" = wasm ]; then
			node bench/aead_wasm/run.mjs && node bench/aead_wasm/run.mjs simd
		else
			odin build bench/aead -out:build/bench-aead$EXE -o:speed $STRICT
			shift 2
			build/bench-aead$EXE "$@"
		fi
	elif [ "${2:-}" = edits ]; then # what it costs to keep up with one edit of a text: ./x bench edits
		odin build bench/edits -out:build/bench-edits$EXE -o:speed $STRICT
		build/bench-edits$EXE
	else
		odin build bench -out:build/bench$EXE -o:speed $STRICT
		build/bench$EXE build/bench-data
	fi
	;;
nat) odin build zspd -out:build/zspd -debug $STRICT && sudo tests/nat.sh && sudo env NAT_B=--random-fully EXPECT_RELAY=1 tests/nat.sh ;;
slow) wasm && odin build zspd -out:build/zspd$EXE -debug $STRICT $TESTING && end_to_end slow_hibernation ;;
*) sed -n 2p "$0" && exit 2 ;;
esac
