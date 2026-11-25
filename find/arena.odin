#+build !js
package find

import "base:runtime"
import "core:mem/virtual"

// Memory for one thing, given back all at once. Here, address space reserved and paid for as it is touched.
@(private)
Arena :: virtual.Arena

// Room for so much, set aside up front; false where that cannot be, and the heap is to be used instead.
@(private)
arena_reserve :: proc(a: ^Arena, size: uint) -> bool {
	return virtual.arena_init_static(a, size, 1 << 16) == nil
}

@(private)
arena_allocator :: proc(a: ^Arena) -> runtime.Allocator {
	return virtual.arena_allocator(a)
}

@(private)
arena_destroy :: proc(a: ^Arena) {
	virtual.arena_destroy(a)
}

@(private)
arena_used :: proc(a: ^Arena) -> bool {
	return a.curr_block != nil
}
