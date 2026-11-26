// A connection a device made, joined to a socket here, in Node, as host/bridge.odin joins a call to one: nothing is read
// from the socket that the stream has no room to send, and nothing is taken from the stream faster than the socket takes
// it, so a slow end slows the other. An end is a half-close, of a socket made with allowHalfOpen, as a server's should be
// for it; and a reset is a reset.

import type { Socket } from "node:net";
import type { Stream } from "./services.ts";

/** Joins a stream to a socket, both ways, until both are over. Resolves to whether both ways ended as they should, not by a reset. */
export function bridge(stream: Stream, socket: Socket): Promise<boolean> {
  return new Promise((done) => {
    let well = true;
    let streamOver = false;
    let socketOver = false;
    let held = 0; // from the stream, written to the socket, and waiting in it
    const check = () => {
      if (streamOver && socketOver) done(well);
    };
    socket.on("data", (d: Buffer) => {
      const sent = stream.write(d);
      if (stream.queued > 0) {
        socket.pause(); // until the stream has room for what it has
        void sent.then(() => socket.resume());
      }
    });
    socket.on("end", () => stream.end());
    socket.on("drain", () => {
      const n = held;
      held = 0;
      stream.consumed(n);
    });
    socket.on("error", () => (well = false));
    socket.on("close", () => {
      socketOver = true;
      if (!streamOver) {
        well = false;
        stream.close();
      }
      check();
    });
    stream.ondata = (d) => {
      if (!socket.writable) {
        stream.close(); // the socket will take nothing more
        return true;
      }
      if (socket.write(d)) return true;
      held += d.length;
      return false;
    };
    stream.onend = () => socket.end();
    stream.closed.then(
      () => {
        streamOver = true;
        check();
      },
      () => {
        streamOver = true;
        well = false;
        if (!socket.destroyed) socket.resetAndDestroy();
        check();
      },
    );
  });
}
