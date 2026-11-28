package host

import "core:os"
import "core:path/filepath"

// Makes a directory, and every one above it that is not there yet, and keeps their names, as SPEC says: each new one,
// synced so that the name of the next is kept in it, and the deepest that was there already, which the first new one's
// name is kept in. Nothing in a new directory is kept while the directory itself may not be: a sync of a file, or of
// the directory it is in, keeps neither that directory's name nor any above it. So whatever makes a directory makes it
// here, before anything is saved or written in it. A directory there already is left as it is, at no cost: so each is
// synced so once in its life, when it is made.
@(require_results)
dir_make :: proc(dir: string) -> bool {
	if os.is_dir(dir) {
		return true
	}
	path, _ := filepath.clean(dir, context.temp_allocator) // as make_directory_all takes it
	was := path
	for !os.exists(was) {
		up := dir_above(was)
		if up == was {
			break
		}
		was = up
	}
	if err := os.make_directory_all(path); err != nil && !os.is_dir(path) {
		return false
	}
	for at := path; at != was; at = dir_above(at) {
		dir_durable(at) or_return
	}
	return dir_durable(was)
}

// The directory a path is in: "." for a name alone, and itself for a root.
@(private)
dir_above :: proc(path: string) -> string {
	up := os.dir(path)
	return up if up != "" else "."
}
