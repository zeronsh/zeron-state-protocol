package host

import "core:testing"
import "../zsp"

// What a local client hears of a call: the bytes of its messages, and whether it ended or failed. The output is taken.
@(private = "file")
heard_of :: proc(local: ^zsp.Session, data: ^int, ended, faulted: ^bool) {
	out := zsp.session_output(local)
	r := zsp.Reader{buf = out}
	for r.pos < len(r.buf) && !r.bad {
		n := int(zsp.read_varint(&r))
		frame := zsp.read_take(&r, n)
		if r.bad || len(frame) < 1 || zsp.Message(frame[0]) != .Flow {
			continue
		}
		body := zsp.Reader{buf = frame[1:]}
		_ = zsp.read_varint(&body)
		#partial switch zsp.Flow(zsp.read_u8(&body)) {
		case .Data:
			data^ += len(body.buf) - body.pos
		case .End:
			ended^ = true
		case .Fault, .Cancel:
			faulted^ = true
		}
	}
	zsp.session_sent(local, len(out))
}

// An answer longer than a call's credit is said all the same, as credit comes, and then the call ends: not ended with
// nothing said, as one message too long for the call would be.
@(test)
answer_longer_than_credit :: proc(t: ^testing.T) {
	w: World
	testing.expect(t, world_init(t, &w, udp = false))
	defer world_destroy(&w)
	testing.expect(t, world_ready(&w, direct = false))
	a := world_space(&w, 1)
	SIZE :: 700 << 10
	host_serve(&w.hosts[1], "zsp.test-long", proc(sp: ^Space, call: u64, from: Caller, scope: zsp.Scope, first: []byte) -> (^Call_Handler, zsp.Call_Fault) {
		return call_answer(sp, call, make([]byte, SIZE, context.temp_allocator)), {}
	})
	local := open_local_session(t, a, w.space, []zsp.Grant{{scope = 1, rights = {.Read, .Write, .Call}}})
	defer zsp.session_close(local)
	testing.expect(t, local_call(local, 7, w.keys[1].device, 1, "zsp.test-long", nil))
	data, ended, faulted := 0, false, false
	for round := 0; round < 20 && !ended && !faulted; round += 1 {
		later_run(&w.hosts[1])
		got := data
		heard_of(local, &data, &ended, &faulted)
		testing.expectf(t, data - got <= zsp.CALL_WINDOW, "%d bytes past the credit", data - got)
		if data > got {
			credit := make([dynamic]byte, context.temp_allocator) // taken: as much again may come
			at := zsp.frame_begin(&credit, .Flow)
			zsp.write_varint(&credit, 7 << 1)
			append(&credit, u8(zsp.Flow.Credit))
			zsp.write_varint(&credit, u64(data - got))
			zsp.frame_end(&credit, at)
			testing.expect(t, zsp.session_input(local, credit[:]))
		}
	}
	testing.expectf(t, data == SIZE && ended && !faulted, "%d of %d bytes, ended %v, failed %v", data, SIZE, ended, faulted)
}
