#+build js
package find

import "base:runtime"

// Memory for one thing, given back all at once. In WebAssembly there is no address space to reserve, so blocks
// of the heap, small ones, for most of what is put here is a question.
@(private)
Arena :: runtime.Arena

@(private)
arena_reserve :: proc(a: ^Arena, size: uint) -> bool {
	return false
}

@(private)
arena_allocator :: proc(a: ^Arena) -> runtime.Allocator {
	if a.minimum_block_size == 0 {
		a.minimum_block_size = 4096
	}
	return runtime.arena_allocator(a)
}

@(private)
arena_destroy :: proc(a: ^Arena) {
	runtime.arena_destroy(a)
}

@(private)
arena_used :: proc(a: ^Arena) -> bool {
	return a.curr_block != nil
}
