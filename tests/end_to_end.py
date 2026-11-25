"""Real processes on real sockets: a relay, devices and clients. Run by `./x test`."""

import os, re, shutil, socket, subprocess, sys, tempfile, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))
import zsp

BIN = os.environ.get("ZSPD", os.path.join(ROOT, "build", "zspd.exe" if os.name == "nt" else "zspd"))
TMP = tempfile.mkdtemp(prefix="zsp-")
procs = []


def zspd(*args):
    p = subprocess.run([BIN, *args], capture_output=True, text=True)
    if p.returncode:
        raise SystemExit(f"zspd {args}: {p.stderr}")
    return p.stdout.strip()


class Node:
    def __init__(self, name, mode="run", *options):
        self.dir = os.path.join(TMP, name)
        self.name, self.mode, self.options = name, mode, list(options)
        self.listen = "127.0.0.1:0"
        self.p = None

    def start(self):
        out = open(os.path.join(TMP, self.name + ".log"), "a")
        self.p = subprocess.Popen(
            [BIN, self.mode, self.dir, "--listen=" + self.listen, "--verbose", *self.options], stdout=subprocess.PIPE, stderr=out, text=True
        )
        procs.append(self.p)
        line = self.p.stdout.readline()
        self.key, self.address = re.match(r"(\w{64}) listening on ws://(\S+)", line).groups()
        self.listen = self.address
        return self

    def stop(self):
        self.p.kill()  # never politely
        self.p.wait()

    def client(self):
        with open(os.path.join(self.dir, "token"), "rb") as f:
            return zsp.Client(self.address, f.read())

    def log(self):
        with open(os.path.join(TMP, self.name + ".log")) as f:
            return f.read()


class Cloud:
    """The same relay as a Durable Object: under workerd here or, given ZSP_CLOUD=https://... and
    ZSP_CLOUD_TOKEN, wherever it is deployed."""

    def start(self, **env):
        self.token = env.get("ACCESS_TOKEN", "")
        live = os.environ.get("ZSP_CLOUD")
        if live:
            request = urllib.request.Request(live, headers={"User-Agent": "zsp-test"})
            self.key = urllib.request.urlopen(request).read().decode().strip()
            self.url, self.token, self.p = live.replace("http", "ws", 1), os.environ["ZSP_CLOUD_TOKEN"], None
            return self
        self.p = subprocess.Popen(
            ["node", os.path.join(ROOT, "relay", "dev.mjs")], stdout=subprocess.PIPE, text=True, env={**os.environ, **env},
            stderr=open(os.path.join(TMP, "cloud.log"), "a"),
        )
        procs.append(self.p)
        self.key, self.address = re.match(r"(\w{64}) listening on ws://(\S+)", self.p.stdout.readline()).groups()
        self.url = "ws://" + self.address
        return self


def eventually(what, f, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if f():
            return
        time.sleep(0.02)
    raise AssertionError("never: " + what)


def space(*names, udp=(), relay=None, options=()):
    """A relay and devices that share scope 1."""
    relay = relay or Node(names[0] + "-relay", "serve", "--no-udp").start()
    devices = [Node(n, "run", *options, *([] if n in udp else ["--no-udp"])) for n in names]
    sid = zspd("create", devices[0].dir)
    url = getattr(relay, "url", None) or "ws://localhost:" + relay.address.split(":")[1]
    zspd("relay", devices[0].dir, relay.key, url)
    for d in devices[1:]:
        zspd("admit", devices[0].dir, zspd("key", d.dir), "1")
        zspd("join", d.dir, sid, relay.key, url)
    for d in devices:
        d.start()
    for d in devices:
        eventually("every device hears who belongs", lambda: os.path.exists(os.path.join(d.dir, sid, "roster")))
    return relay, devices


def test_sync_through_relay():
    relay, (a, b) = space("a", "b")
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "chat", limit=50)
    cb.until(lambda: 1 in cb.windows)
    rows = [ca.put(1, "chat", i, [b"message %d" % i]) for i in range(120)]
    ca.until(lambda: ca.acked == ca.seq)
    cb.until(lambda: len(cb.list(1, "chat")) == 120)
    assert [v[16] for _, _, v in cb.list(1, "chat")] == [b"message %d" % i for i in range(120)]

    # A page of the end, then the page before it, each knowing what lies beyond.
    late = b.client()
    late.watch(1, 1, "chat", limit=50).__class__
    late.until(lambda: 1 in late.windows)
    w = late.windows[1]
    assert len(late.list(1, "chat")) == 50 and (w["before"], w["after"]) == (70, 0), w
    late.watch(2, 1, "chat", limit=50, hi=w["lo"])
    late.until(lambda: 2 in late.windows)
    assert len(late.list(1, "chat")) == 100 and late.windows[2]["before"] == 20

    # Edits, moves and deletions arrive in view.
    cb.write((rows[119], 16, zsp.VALUE, b"edited"))
    ca.watch(1, 1, "chat")
    ca.until(lambda: ca.list(1, "chat")[119][2].get(16) == b"edited")
    ca.write((rows[0], 0, zsp.GRAVE, b""))
    cb.until(lambda: len(cb.list(1, "chat")) == 119)

    # Live frames flow to whoever watches, and are never stored.
    ca.live(rows[119], 17, b"pieceone", 0, b"hello ")
    ca.live(rows[119], 17, b"pieceone", 6, b"world")
    cb.until(lambda: len(cb.lives) == 2)
    assert cb.lives[1] == (rows[119], 17, b"pieceone", 6, b"world")


def test_dial_by_name():
    # Resolving a name is a thread's work, and the loop must hear of it with nobody there to poke it.
    relay = Node("x-relay", "serve", "--no-udp").start()
    for i in range(12):
        n = Node("x%d" % i, "run", "--no-udp")
        sid = zspd("create", n.dir)
        zspd("relay", n.dir, relay.key, "ws://localhost:" + relay.address.split(":")[1])
        n.start()
        eventually("the relay hears from it", lambda: os.path.exists(os.path.join(relay.dir, sid, "roster")), 3)
        n.stop()


def test_offline_and_crash():
    relay, (a, b) = space("c", "d")
    ca = a.client()
    row = ca.put(1, "notes", 1, [b"one"])
    ca.until(lambda: ca.acked == ca.seq)
    a.stop()  # acknowledged means durable, even so
    a.start()
    ca = a.client()
    ca.watch(1, 1, "notes")
    ca.until(lambda: 1 in ca.windows)
    assert ca.list(1, "notes")[0][2][16] == b"one"

    relay.stop()
    ca.put(1, "notes", 2, [b"two"])  # local first
    ca.until(lambda: ca.acked == ca.seq)
    cb = b.client()
    cb.watch(1, 1, "notes")
    cb.drain(0.2)
    cb.put(1, "notes", 3, [b"three"])
    relay.start()
    cb.until(lambda: [v[16] for _, _, v in cb.list(1, "notes")] == [b"one", b"two", b"three"], 15)
    ca.until(lambda: len(ca.list(1, "notes")) == 3)
    assert row


def test_direct_links():
    relay, (a, b) = space("e", "f", udp=("e", "f"))
    eventually("e links to f", lambda: "linked directly" in a.log() and "linked directly" in b.log())
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "x")
    cb.until(lambda: 1 in cb.windows)
    time.sleep(0.3)
    relay.stop()  # and nothing is missed
    for i in range(50):
        ca.put(1, "x", i, [os.urandom(2000)])
    cb.until(lambda: len(cb.list(1, "x")) == 50)
    ca.live(ca.list(1, "x")[0][1], 17, b"piecetwo", 0, b"direct")
    cb.until(lambda: cb.lives and cb.lives[0][4] == b"direct")


def test_lan_without_relay():
    a, b = Node("g"), Node("h")
    sid = zspd("create", a.dir)
    zspd("admit", a.dir, zspd("key", b.dir), "1")
    zspd("peer", b.dir, os.path.join(a.dir, sid, "roster"))
    a.start(), b.start()
    eventually("beacons meet", lambda: "linked directly" in a.log() and "linked directly" in b.log())
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "x")
    cb.until(lambda: 1 in cb.windows)
    ca.put(1, "x", 1, [b"no servers"])
    cb.until(lambda: len(cb.list(1, "x")) == 1)


def test_permissions():
    relay, (a, b, c) = space("i", "j", "k")
    ca = a.client()
    ca.put(1, "x", 1, [b"before"])
    ca.until(lambda: ca.acked == ca.seq)
    cc = c.client()
    cc.watch(1, 1, "x")
    cc.until(lambda: len(cc.list(1, "x")) == 1)
    # c is revoked, with everything running: the relay hears from a, and c from being refused.
    zspd("revoke", a.dir, zspd("key", c.dir))
    ca.put(1, "x", 2, [b"after"])
    cb = b.client()
    cb.watch(1, 1, "x")
    cb.until(lambda: len(cb.list(1, "x")) == 2)
    cc.drain(0.5)
    assert len(cc.rows) == 1
    assert cc.windows[1]["denied"] and 1 not in cc.scopes  # and c's own client is told

    # A scope granted while everything runs is open at once; its readers cannot write.
    two = int(zspd("scope", a.dir, "signed"))
    zspd("admit", a.dir, zspd("key", b.dir), str(two), "read")
    cb.until(lambda: two in cb.scopes)
    ca.until(lambda: two in ca.scopes)
    assert cb.scopes[two][0] == zsp.READ and ca.scopes[two][0] & zsp.WRITE
    cb.watch(2, two, "news")
    ca.put(two, "news", 1, [b"signed"])
    cb.until(lambda: len(cb.list(two, "news")) == 1)
    try:
        cb.put(two, "news", 2, [b"forged"])
        cb.drain(1)
        raise SystemExit("a reader wrote")
    except PermissionError:
        pass

    # The wrong token, and a web page, are refused.
    for attempt in (lambda: zsp.Client(a.address, b"wrong"),):
        try:
            attempt()
            raise SystemExit("admitted")
        except (PermissionError, ConnectionError):
            pass
    s = socket.create_connection(a.address.split(":"))
    s.sendall(b"GET / HTTP/1.1\r\nHost: x\r\nOrigin: https://evil.example\r\nSec-WebSocket-Key: x\r\n\r\n")
    s.settimeout(2)
    assert s.recv(100) == b""


def test_partial():
    relay, (a, b) = space("l", "m")
    b.stop()
    b.options.append("--partial")
    b.start()
    ca, cb = a.client(), b.client()
    for i in range(300):
        ca.put(1, "feed", i, [b"x" * 100])
    ca.until(lambda: ca.acked == ca.seq)
    time.sleep(0.3)
    cb.watch(1, 1, "feed", limit=40)
    cb.until(lambda: cb.windows.get(1, {}).get("settled"))
    got = cb.list(1, "feed")
    assert [o for o, _, _ in got] == list(range(260, 300)), got[:3]
    cb.put(1, "feed", 1000, [b"mine"])
    ca.watch(1, 1, "feed", limit=1)
    ca.until(lambda: any(v.get(16) == b"mine" for _, _, v in ca.list(1, "feed")))


def test_calls():
    import threading

    relay, (a, b) = space("n", "o")
    ca, cb = a.client(), b.client()
    cb.serve(1, "add", lambda device, body: str(sum(map(int, body.split()))).encode())
    stop = threading.Event()

    def answer():
        while not stop.is_set():
            cb.drain(0.05)

    t = threading.Thread(target=answer)
    t.start()
    try:
        ca.until(lambda: len(ca.devices) == 2)
        device = ca.devices[1][0]
        assert device.hex() == b.key
        first = ca.call(device, 1, "add", b"2 3")  # through the relay, which sees nothing
        assert first["data"] == [b"5"], first
        start = time.monotonic()
        for i in range(200):
            assert ca.call(device, 1, "add", b"%d 1" % i)["data"] == [b"%d" % (i + 1)]
        each = (time.monotonic() - start) / 200
        assert each < 0.02, each
        print(f"     a relayed call takes {each * 1e6:.0f} µs")
        assert ca.call(device, 1, "subtract")["fault"] == 3  # unserved
    finally:
        stop.set()
        t.join()


def test_luau():
    _, (a, b) = space("v", "w")
    args = []
    for d in (a, b):
        with open(os.path.join(d.dir, "token")) as f:
            args += [d.address, f.read()]
    p = subprocess.run(["lune", "run", os.path.join(ROOT, "luau", "tests", "live.luau"), *args], capture_output=True, text=True, timeout=60)
    sys.stdout.write(p.stdout.replace("ok\n", ""))
    assert p.returncode == 0 and p.stdout.endswith("ok\n"), p.stderr


def knock(address, path):
    """An upgrade, and nothing after it."""
    host, port = address.split(":")
    k = socket.create_connection((host, int(port)))
    k.sendall(
        f"GET {path} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".encode()
    )
    assert b" 101 " in k.recv(500)
    return k


def test_knocking_leaves_no_trace():
    relay = Node("y-relay", "serve", "--no-udp").start()
    ks = [knock(relay.address, "/" + os.urandom(32).hex()) for _ in range(5)]
    time.sleep(0.2)
    left = [d for d in os.listdir(relay.dir) if len(d) == 64]
    assert not left, left
    for k in ks:
        k.close()


def test_limits():
    relay, (a, b) = space("aa", "ab")
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "x")
    ca.put(1, "x", 1, [b"first"])
    cb.until(lambda: len(cb.list(1, "x")) == 1)
    # The largest legal value arrives; a larger one is refused before it can do harm.
    ca.put(1, "x", 2, [os.urandom((1 << 20) - 128)])
    cb.until(lambda: len(cb.list(1, "x")) == 2)
    try:
        ca.put(1, "x", 3, [bytes(1 << 20)])
        ca.drain(1)
        raise SystemExit("accepted")
    except (PermissionError, ConnectionError):
        pass
    ca = a.client()
    ca.put(1, "x", 4, [b"after"])
    cb.until(lambda: len(cb.list(1, "x")) == 3)
    # Frames that would outgrow a record end the session that sent them, and not the node.
    for target in (a,):
        c = target.client()
        c.seq += 1
        graves = b"".join(bytes([zsp.GRAVE]) + c.new_id(1) + b"\0" + c.stamp() + b"\0" for _ in range(100000))
        c.send(zsp.CELLS, zsp.varint(c.seq) + graves[: (1 << 22) - 100])
        time.sleep(0.5)
    assert a.p.poll() is None
    # A message in several frames is a message.
    c = a.client()
    body = zsp.frame(zsp.UNWATCH, zsp.varint(1)) + zsp.frame(zsp.WATCH, zsp.varint(7) + b"\1" + zsp.put_key(c.tag(1, "x").ljust(40, b"\0")) + zsp.put_key(zsp.key_after(c.tag(1, "x"))) + b"\0")
    for i, part in enumerate((body[:3], body[3:9], body[9:])):
        op = (2 if i == 0 else 0) | (0x80 if i == 2 else 0)
        c.sock.sendall(bytes([op, 0x80 | len(part)]) + bytes(4) + part)
    c.until(lambda: 7 in c.windows)


def test_durable_object():
    cloud = Cloud().start(ACCESS_TOKEN="sesame")
    _, (a, b) = space("p", "q", relay=cloud, options=["--credential=" + cloud.token])
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "chat", limit=50)
    cb.until(lambda: 1 in cb.windows)
    for i in range(300):
        ca.put(1, "chat", i, [b"message %d" % i])
    cb.until(lambda: len(cb.list(1, "chat")) == 300)
    row = cb.list(1, "chat")[-1][1]
    ca.live(row, 17, b"pieceone", 0, b"hello")
    cb.until(lambda: cb.lives)
    cb.serve(1, "add", lambda device, body: body + b"!")
    cb.drain(0.1)
    ca.until(lambda: len(ca.devices) == 2)
    ca.send(zsp.CALL, zsp.varint(9) + ca.devices[1][0] + zsp.varint(1) + zsp.varint(3) + b"addhi")
    ca.calls[9] = {"data": [], "ended": False, "fault": None}
    cb.drain(1)
    ca.until(lambda: ca.calls[9]["data"] == [b"hi!"])

    # A device that was away while everything happened, with nobody else online.
    a.stop(), b.stop()
    c = Node("r", "run", "--no-udp", "--credential=" + cloud.token)
    zspd("admit", a.dir, zspd("key", c.dir), "1")
    zspd("join", c.dir, zspd_space(a), cloud.key, cloud.url)
    a.start()
    time.sleep(2)
    a.stop()
    c.start()
    cc = c.client()
    cc.until(lambda: cc.scopes)  # told as soon as the node is
    cc.watch(1, 1, "chat")
    cc.until(lambda: len(cc.list(1, "chat")) == 300)

    # Without the credential, nothing.
    d = Node("s", "run", "--no-udp")
    zspd("join", d.dir, zspd_space(a), cloud.key, cloud.url)
    d.start()
    time.sleep(2)
    assert not os.path.exists(os.path.join(d.dir, zspd_space(a), "roster"))


def slow_hibernation():
    cloud = Cloud().start()
    _, (a, b) = space("t", "u", relay=cloud, options=["--credential=" + cloud.token])
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "chat", limit=50)
    ca.put(1, "chat", 1, [b"before"])
    cb.until(lambda: len(cb.list(1, "chat")) == 1)
    time.sleep(40 if cloud.p is None else 15)  # the object is evicted; its sockets are not
    ca.put(1, "chat", 2, [b"after"])
    cb.until(lambda: len(cb.list(1, "chat")) == 2)
    ca.live(cb.list(1, "chat")[0][1], 17, b"pieceone", 0, b"still live")
    cb.until(lambda: cb.lives)
    if cloud.p is None:
        return  # its console is elsewhere
    cloud.p.terminate()
    assert "woke with 2 sockets" in cloud.p.stdout.read() + open(os.path.join(TMP, "cloud.log")).read()


def zspd_space(node):
    with open(os.path.join(node.dir, "space")) as f:
        return f.read().strip()


def one(name):
    start = time.monotonic()
    try:
        globals()[name]()
        print(f"ok   {name} {time.monotonic() - start:.2f}s")
        return 0
    except BaseException as e:
        import traceback

        where = [f.lineno for f in traceback.extract_tb(e.__traceback__) if f.filename == __file__]
        print(f"FAIL {name}: {type(e).__name__} {e} at {where}\nlogs in {TMP}")
        return 1
    finally:
        for p in procs:
            p.kill()
            p.wait()


def main():
    names = sys.argv[1:] or [n for n in globals() if n.startswith("test_")]
    if len(names) == 1:
        code = one(names[0])
        if code == 0:
            shutil.rmtree(TMP, ignore_errors=True)
        sys.exit(code)
    os.rmdir(TMP)
    runs = [subprocess.Popen([sys.executable, __file__, n], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for n in names]
    for r in runs:
        sys.stdout.write(r.communicate()[0])
    sys.exit(any(r.returncode for r in runs))


main()
