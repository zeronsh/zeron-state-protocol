package host

import "core:crypto"
import "core:encoding/hex"
import "core:os"
import "core:path/filepath"
import "core:net"
import "core:testing"
import "core:time"
import "../pipe"
import "../zsp"

// What a host sends is only ever where one peer could be, whoever asks it to send there. A beacon is answered where it
// says the device is, from the address it came from; not at that address's port, which may be anyone's, as the shared
// port beacons are said from is. Nothing that came from where nothing could be sent back, as everyone or nobody, is
// answered at all, nor believed. And the socket links send by may not broadcast, so that no address a member names, as
// its network's own broadcast address, reaches everyone on it.
@(test)
links_answer_only_where_one_could_be :: proc(t: ^testing.T) {
	base, _ := os.temp_directory(context.temp_allocator)
	dir, err := os.make_directory_temp(base, "zsp-answer-*", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)
	h: Host
	if !testing.expect(t, host_init(&h, {dir = dir, full = true, udp_port = 0})) {
		return
	}
	defer host_destroy(&h)
	ours, theirs: zsp.Keyring
	zsp.keyring_init(&ours, h.secret)
	defer zsp.keyring_destroy(&ours)
	// Another member, which does not dial this one, so that this one answers its beacon with its own.
	for {
		secret: zsp.Key32
		crypto.rand_bytes(secret[:])
		zsp.keyring_init(&theirs, secret)
		if string(theirs.device[:]) < string(ours.device[:]) {
			break
		}
		zsp.keyring_destroy(&theirs)
	}
	defer zsp.keyring_destroy(&theirs)
	root: zsp.Key32
	crypto.rand_bytes(root[:])
	none: zsp.Roster
	d := zsp.draft_from(&none, now_ms() << 16)
	home := zsp.draft_scope(&d)
	zsp.draft_grant(&d, ours.device, ours.signer, home, {.Read, .Write}).owner = true
	zsp.draft_grant(&d, theirs.device, theirs.signer, home, {.Read, .Write})
	roster, signed := zsp.roster_sign(&ours, root, &d, context.temp_allocator)
	testing.expect(t, signed)
	space := zsp.ed25519_public(root)
	sdir, _ := filepath.join({dir, string(hex.encode(space[:], context.temp_allocator))}, context.temp_allocator)
	os.make_directory_all(sdir)
	testing.expect(t, save(file_in(sdir, "roster"), roster))
	if !testing.expect(t, space_open(&h, space) != nil) {
		return
	}
	// The other member's node, to say its beacon.
	m: zsp.Memory_Disk
	defer zsp.memory_disk_destroy(&m)
	other: zsp.Node
	testing.expect(t, zsp.node_init(&other, zsp.memory_disk(&m), space, &theirs, true))
	defer zsp.node_destroy(&other)
	testing.expect(t, zsp.node_adopt(&other, roster))

	// Where it says it is, and where its beacon came from: sockets of the test's own, to see what is sent to each.
	says, says_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	from, from_err := net.make_bound_udp_socket(net.IP4_Loopback, 0)
	testing.expect(t, says_err == nil && from_err == nil)
	defer net.close(says)
	defer net.close(from)
	at_says, _ := net.bound_endpoint(says)
	at_from, _ := net.bound_endpoint(from)
	heard :: proc(socket: net.UDP_Socket) -> (first: int) {
		net.set_option(socket, .Receive_Timeout, 200 * time.Millisecond)
		buf: [2048]byte
		n, _, err := net.recv_udp(socket, buf[:])
		return int(buf[0]) if err == nil && n > 0 else -1
	}

	udp_input(&h, zsp.beacon_seal(&other, at_says.port), address_from(at_from))
	testing.expect_value(t, heard(says), int(BEACON))
	testing.expect_value(t, heard(from), -1)

	// A request for this machine's outside address, answered where it came from, and not from everyone.
	ask := pipe.stun_request()
	udp_input(&h, ask[:], address_from(at_from))
	testing.expect_value(t, heard(from), 1)
	udp_input(&h, ask[:], address_from({net.IP4_Any, at_from.port}))
	testing.expect_value(t, heard(from), -1)

	// Nor can anything go to everyone by the socket links use.
	_, everyone := net.send_udp(h.udp.socket, []byte{1}, {net.IP4_Address{255, 255, 255, 255}, at_from.port})
	testing.expect(t, everyone != nil, "the socket links send by broadcasts")
}
