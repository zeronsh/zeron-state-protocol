#+build !linux
package host

// Nothing here needs waiting for before the event loop is made.
ring_free :: proc() -> bool {
	return true
}
