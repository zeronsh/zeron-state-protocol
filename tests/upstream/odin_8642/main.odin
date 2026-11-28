// Reproduces odin-lang/Odin#8642: the runtime's map_entry can give back the slot of another key.
//
// Keys put into and taken out of a small map, at random from a few, with map_entry, and the value written through the
// pointer it gives back, as core:nbio's kqueue loop does, with keys of the same shape: a map so churned comes to have
// tombstones and no empty slot, and an insertion then shifts entries round the table after it has taken the new key's
// slot, so that the value lands on another key and the new one is left with nothing. A second map, written with
// m[k] = v, says what each should be.
//
// Prints one line and exits 0: "BROKEN: ..." with the first key that went wrong, or "FIXED: ..." if none did over all
// its seeds. Where it goes wrong differs from run to run, as the runtime seeds its hashes afresh in each; it has gone
// wrong within a second in every run (30 of 30, within the first 12 of 23 sizes). Anything else (a crash, another
// exit) is the repro's own failure.
//
// Run by .github/workflows/upstream.yml, not by ./x test; tests/upstream/run.sh runs it. The copy third_party/nbio is
// dropped once a release has this fixed, with odin-lang/Odin#8644 and #8645.
package odin_8642

import "core:fmt"
import "core:math/rand"
import "core:os"

Key :: struct {
	filter: i16,
	ident:  uintptr,
}

main :: proc() {
	steps := 0
	for universe in 2 ..= 24 {
		for seed in u64(1) ..= 400 {
			rand.reset(seed * 1000 + u64(universe))
			m, want: map[Key]uintptr
			next: uintptr = 1
			for _ in 0 ..< 3000 {
				steps += 1
				n := rand.int_max(universe)
				k := Key{filter = i16(-1 - n % 2), ident = uintptr(n / 2 + 3)}
				if rand.int_max(2) == 0 {
					_, val, inserted, err := map_entry(&m, k)
					if err != nil {
						fmt.eprintln("map_entry failed:", err)
						os.exit(2)
					}
					if inserted {
						val^ = next
						want[k] = next
						next += 1
						if got := m[k]; got != want[k] {
							fmt.printfln("BROKEN: universe %d, seed %d: %v was given %d through map_entry's pointer, and has %d; %d entries, room for %d",
								universe, seed, k, want[k], got, len(m), cap(m))
							return
						}
					}
				} else {
					delete_key(&m, k)
					delete_key(&want, k)
				}
			}
			for k, v in want {
				if m[k] != v {
					fmt.printfln("BROKEN: universe %d, seed %d: %v has %d, not %d", universe, seed, k, m[k], v)
					return
				}
			}
			delete(m)
			delete(want)
		}
	}
	fmt.printfln("FIXED: every value written through map_entry's pointer was its key's, over %d steps", steps)
}
