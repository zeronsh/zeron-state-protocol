#+build !windows
package host

import "core:os"

// The whole of a file, or false if there is none.
read_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	err: os.Error
	data, err = os.read_entire_file(path, allocator)
	return data, err == nil
}

// Puts one file in another's place, whole: which a rename does here, whoever has either open.
@(private)
replace_file :: proc(from, to: string) -> bool {
	return os.rename(from, to) == nil
}
