"""TCP forwarding built on calls, outside the host (examples/forward): python3 examples/forward/test.py

A relay and two devices: B serves "forward" to a TCP server here, and A listens, each connection a call to B. Through
the relay, then over a direct link: bytes both ways, whole and in order; a half-close; a reader that never reads holding
the writer back, rather than everything piling up between; a refusal; and what the roster does not allow.
"""

import hashlib
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from zspd import ROOT, Device, zspd  # noqa: E402


class Thread(threading.Thread):
    """A thread whose failure is the test's: raised again where it is joined, rather than only printed, as Python does
    with what a thread raises, letting the test pass."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.failed = None

    failures = []  # of threads not yet joined: what the test fails of at its end, though it never joins them

    def run(self):
        try:
            super().run()
        except BaseException as e:
            import traceback

            traceback.print_exc()  # said at once, as Python says it of any thread
            self.failed = e
            Thread.failures.append(e)

    def join(self, timeout=None):
        super().join(timeout)
        if self.failed is not None:
            if self.failed in Thread.failures:
                Thread.failures.remove(self.failed)
            raise self.failed

    @staticmethod
    def check():
        """Raises what any thread raised that was never joined, as the end of a test that ran it."""
        if Thread.failures:
            raise Thread.failures[0]


FORWARD = os.path.join(ROOT, "build", "forward" + (".exe" if os.name == "nt" else ""))


class Server:
    """A TCP server on a thread: echoes each connection, or with `stalled`, never reads it."""

    def __init__(self, stalled=False):
        self.stalled, self.stop = stalled, False
        self.sock = socket.create_server(("127.0.0.1", 0))
        self.port = self.sock.getsockname()[1]
        self.held = []
        Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while not self.stop:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            if self.stalled:
                self.held.append(c)  # read never, closed at the end
                continue
            Thread(target=self.echo, args=(c,), daemon=True).start()

    @staticmethod
    def echo(c):
        with c:
            try:
                while data := c.recv(1 << 16):
                    c.sendall(data)
                c.shutdown(socket.SHUT_WR)  # said all, once the other has
            except OSError:
                pass  # reset: a probe that gave up waiting, as reachable's first may

    def close(self):
        self.stop = True
        self.sock.close()
        for c in self.held:
            c.close()


def start(*args):
    p = subprocess.Popen([FORWARD, *map(str, args)], stdout=subprocess.PIPE, text=True)
    key = re.match(r"(\w{64}) ready", p.stdout.readline())
    assert key, "forward did not start"
    return p, key[1]


def listening(p, n):
    """The ports a forward listens at, as it says them, in the order of its --connect."""
    return [int(re.match(r"listening on 127\.0\.0\.1:(\d+) for ", p.stdout.readline())[1]) for _ in range(n)]


def stop(p):
    p.kill()
    p.wait()


def connect(port):
    return socket.create_connection(("127.0.0.1", port), timeout=20)


def reachable(port, within=30):
    """Waits until a connection through the forward is echoed: the devices have found each other."""
    until = time.monotonic() + within
    while time.monotonic() < until:
        try:
            with connect(port) as s:
                s.settimeout(2)
                s.sendall(b"ping")
                if s.recv(4) == b"ping":
                    return
        except OSError:
            pass
        time.sleep(0.2)
    raise AssertionError("the devices never reached each other")


def pattern(n, seed):
    out = bytearray(n)
    x = seed
    for i in range(0, n, 4096):
        x = (x * 6364136223846793005 + 1442695040888963407) % (1 << 64)
        out[i : i + 4096] = x.to_bytes(8, "little") * 512
    return bytes(out[:n])


def bulk(port, size):
    """Sends `size` bytes and reads them back at once, each way on its own thread: whole, in order."""
    data = pattern(size, size)
    got = bytearray()
    with connect(port) as s:
        sender = Thread(target=lambda: (s.sendall(data), s.shutdown(socket.SHUT_WR)))
        sender.start()
        while chunk := s.recv(1 << 18):
            got += chunk
        sender.join()
    assert hashlib.sha256(got).digest() == hashlib.sha256(data).digest(), f"{len(got)} of {size} bytes came back as sent"


def half_close(port):
    """Said all, the other side still answers, then says all itself."""
    with connect(port) as s:
        s.sendall(b"one way")
        s.shutdown(socket.SHUT_WR)
        got = b""
        while chunk := s.recv(1024):
            got += chunk
        assert got == b"one way", got


def held_back(port, stalled):
    """A reader that never reads: what the writer gets away with is bounded by windows and buffers, not by the size of
    what it would send."""
    with connect(port) as s:
        s.settimeout(3)
        block, sent = b"x" * (1 << 16), 0
        try:
            while sent < 256 << 20:
                sent += s.send(block)
        except (TimeoutError, socket.timeout):
            pass
        assert stalled.held, "the stalled server was never reached"
        assert sent < 96 << 20, f"{sent >> 20} MiB went into a connection nobody reads"
        return sent


def refused(port):
    """Nothing listens there, or it is not allowed, or the roster does not let the call be made: the connection here is
    closed or reset, at once, and nothing comes back."""
    started = time.monotonic()
    with connect(port) as s:
        s.settimeout(10)
        try:
            s.sendall(b"anyone?")
            assert s.recv(16) == b""
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError):
            pass
    assert time.monotonic() - started < 5, "a refusal took its time"


def main(root, direct):
    options = [] if direct else ["--no-udp"]
    relay = Device(os.path.join(root, "relay")).run("serve")
    a, b, c = (Device(os.path.join(root, name)) for name in "abc")
    zspd("create", a.dir)  # scope 1
    zspd("relay", a.dir, relay.name, "ws://" + relay.address)
    zspd("admit", a.dir, b.key, "1")
    zspd("scope", a.dir)  # 2, and C's only: in scope 1 it may not be called
    zspd("admit", a.dir, c.key, "2")
    with open(os.path.join(a.dir, "space")) as f:
        space = f.read().strip()
    zspd("join", b.dir, space, relay.name, "ws://" + relay.address)
    echo, stalled = Server(), Server(stalled=True)
    closed = socket.create_server(("127.0.0.1", 0))
    nothing = closed.getsockname()[1]
    closed.close()
    to = {name: f"127.0.0.1:{port}" for name, port in (("echo", echo.port), ("stalled", stalled.port), ("nothing", nothing), ("unallowed", 1))}
    procs = []
    try:
        served, b_key = start(b.dir, *(f"--allow={to[name]}" for name in ("echo", "stalled", "nothing")), *options)
        procs.append(served)
        targets = [(b_key, to["echo"]), (b_key, to["stalled"]), (b_key, to["nothing"]), (b_key, to["unallowed"]), (c.key[:64], to["echo"])]
        client, _ = start(a.dir, *(f"--connect=0/{device}/{where}" for device, where in targets), *options)
        procs.append(client)
        port, port_stalled, port_nothing, port_unallowed, port_c = listening(client, len(targets))

        reachable(port)
        bulk(port, 24 << 20)
        def many():
            if os.environ.get("ZSP_FAIL"):  # as `./x selftest` sets it: a thread's failure is the test's
                raise AssertionError("failing, as ZSP_FAIL asks")
            bulk(port, 2 << 20)

        threads = [Thread(target=many) for _ in range(8)]  # many calls at once
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        half_close(port)
        # Many small round trips, as something interactive makes: each answered, in order.
        with connect(port) as s:
            for i in range(200):
                want = b"%d." % i
                s.sendall(want)
                got = b""
                while len(got) < len(want):
                    got += s.recv(64)
                assert got == want, (got, want)
        sent = held_back(port_stalled, stalled)
        refused(port_nothing)
        refused(port_unallowed)
        refused(port_c)
        # And all the while, the others go on.
        bulk(port, 1 << 20)
        return sent
    finally:
        for p in procs:
            stop(p)
        relay.stop()
        echo.close()
        stalled.close()


if __name__ == "__main__":
    for direct in (False, True):
        root = tempfile.mkdtemp(prefix="zsp-forward-")
        try:
            sent = main(root, direct)
            Thread.check()  # what the servers' threads raised, which nothing joins
            print(f"ok   forward, {'direct' if direct else 'through the relay'}: a reader that never reads held {sent >> 20} MiB")
        finally:
            shutil.rmtree(root, ignore_errors=True)
