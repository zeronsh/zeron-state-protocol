#+build !linux
#+build !darwin
#+build !freebsd
#+build !openbsd
#+build !netbsd
package host

// Whether the event loop holds operations back that it will give the system only after waiting: never, here.
@(private)
loop_held_back :: proc() -> bool {
	return false
}
