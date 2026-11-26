"""Real processes on real sockets: a relay, devices and clients. Run by `./x test`."""

import json, os, re, shutil, socket, struct, subprocess, sys, tempfile, time, urllib.request

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
    def __init__(self, name, mode="run", *options, machine=False):
        self.dir = os.path.join(TMP, name)
        self.name, self.mode, self.options = name, mode, list(options)
        if mode == "run" and not machine:  # nothing of this machine's own: tests run side by side, and others may have set up for names
            for flag, default in (("--dns", "--dns=127.0.0.1:0"), ("--catch", "--catch=127.0.0.1:0"), ("--proxy", "--no-proxy")):
                if not any(o.startswith(flag) for o in self.options):
                    self.options.insert(0, default)
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
    import threading

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
    # Whoever was called dies without a word, and the link has nothing to say: the call is known to be lost.
    cb.serve(1, "wait", lambda device, body: None)
    ca.until(lambda: len(ca.devices) == 2)
    threading.Timer(0.7, b.stop).start()
    assert ca.call(ca.devices[1][0], 1, "wait", timeout=15)["fault"] == 4


def refused(*args):
    return subprocess.run([BIN, *args], capture_output=True).returncode != 0


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
    assert cb.scopes[two][0] == zsp.READ | zsp.SAYS_WHOSE and ca.scopes[two][0] & zsp.WRITE
    cb.watch(2, two, "news")
    ca.put(two, "news", 1, [b"signed"])
    cb.until(lambda: len(cb.list(two, "news")) == 1)
    try:
        cb.put(two, "news", 2, [b"forged"])
        cb.drain(1)
        raise SystemExit("a reader wrote")
    except PermissionError:
        pass

    roster = lambda d: open(os.path.join(d.dir, zspd_space(a), "roster"), "rb").read()
    # An admin governs without owning; may not appoint; and, unmade, governs no more.
    zspd("admin", a.dir, zspd("key", b.dir))
    cb = b.client()
    cb.until(lambda: cb.scopes.get(two, [0])[0] & zsp.WRITE)
    three = int(zspd("scope", b.dir))
    zspd("admit", b.dir, zspd("key", a.dir), str(three))
    ca.until(lambda: three in ca.scopes)
    eventually("a hears of it", lambda: roster(b) == roster(a))
    assert refused("admin", b.dir, zspd("key", c.dir)) and refused("revoke", b.dir, zspd("key", a.dir))
    zspd("admin", a.dir, zspd("key", b.dir), "off")
    eventually("b hears of it", lambda: roster(b) == roster(a))
    assert refused("scope", b.dir)

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
    signed = zspd("scope", a.dir, "signed")
    assert signed == "2"
    zspd("admit", a.dir, zspd("key", b.dir), signed, "vouch")
    zspd("subject", a.dir, zspd("key", a.dir), "ann")
    zspd("subject", a.dir, zspd("key", b.dir), "bob")
    args = []
    for d in (a, b):
        with open(os.path.join(d.dir, "token")) as f:
            args += [d.address, f.read()]
    try:
        p = subprocess.run(["lune", "run", os.path.join(ROOT, "luau", "tests", "live.luau"), *args], capture_output=True, text=True, timeout=60)
    except subprocess.TimeoutExpired as e: # it waits on its sockets once something has gone wrong
        raise timed_out(e) from None
    sys.stdout.write(p.stdout.replace("ok\n", ""))
    assert p.returncode == 0 and p.stdout.endswith("ok\n"), p.stderr


def timed_out(e):
    """What a process said before it was given up on: bytes, as Python keeps them, but text on Windows."""
    said = []
    for out in (e.stdout, e.stderr):
        if out:
            said.append(out.decode(errors="replace") if isinstance(out, bytes) else out)
    return AssertionError("timed out, having said:\n" + "\n".join(said)[-4000:])


def test_luau_services():
    _, (a, b) = space("sa", "sb")
    zspd("admit", a.dir, zspd("key", a.dir), "1", "shell", "files")
    assert zspd("scope", a.dir) == "2"  # where a may call b, and use nothing it shares
    zspd("admit", a.dir, zspd("key", b.dir), "2")
    folder = os.path.join(TMP, "shared")
    os.makedirs(folder)
    args = []
    for d in (a, b):
        with open(os.path.join(d.dir, "token")) as f:
            args += [d.address, f.read()]
    try:
        p = subprocess.run(
            ["lune", "run", os.path.join(ROOT, "luau", "tests", "live_services.luau"), *args, folder, sys.executable],
            capture_output=True, text=True, timeout=120,
        )
    except subprocess.TimeoutExpired as e:  # it waits on its sockets once something has gone wrong
        raise timed_out(e) from None
    sys.stdout.write(p.stdout.replace("ok\n", ""))
    assert p.returncode == 0 and p.stdout.endswith("ok\n"), p.stdout[-2000:] + p.stderr


def test_luau_ports():
    """The Luau client's names, ports and exposures."""
    _, (a, b) = space("lp", "lq")
    port = free_port()
    Service("127.0.0.1", port, says=b"x")
    args = []
    for d in (a, b):
        with open(os.path.join(d.dir, "token")) as f:
            args += [d.address, f.read()]
    p = subprocess.run(["lune", "run", os.path.join(ROOT, "luau", "tests", "ports.luau"), *args, str(port)], capture_output=True, text=True, timeout=60)
    assert p.returncode == 0 and p.stdout.endswith("ok\n"), p.stdout + p.stderr


def test_mirror():
    _, (a, b) = space("ma", "mb")
    args = []
    for d in (a, b):
        with open(os.path.join(d.dir, "token")) as f:
            args += [d.address, f.read()]
    try:
        p = subprocess.run(["lune", "run", os.path.join(ROOT, "luau", "tests", "mirror.luau"), *args], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired as e:
        raise timed_out(e) from None
    sys.stdout.write(p.stdout.replace("ok\n", ""))
    assert p.returncode == 0 and p.stdout.endswith("ok\n"), p.stdout[-2000:] + p.stderr


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


def test_questions():
    relay, (a, b) = space("ba", "bb")
    ca, cb = a.client(), b.client()
    name, age, text = zsp.column(zsp.FOLD, 16), zsp.column(zsp.NUMBER, 17), zsp.column(zsp.WORDS, 20)
    friend = zsp.column(zsp.ID, 19)

    def person(c, n, years, says, knows=None):
        row = c.new_id(1)
        cells = [(row, 1, zsp.PLACE, c.tag(1, "people") + struct.pack(">Q", 0)), (row, 16, zsp.VALUE, n.encode())]
        cells += [(row, 17, zsp.VALUE, struct.pack(">d", years)), (row, 20, zsp.VALUE, says.encode())]
        c.write(*cells, *([(row, 19, zsp.VALUE, knows)] if knows else []))
        return row

    ann = person(ca, "Ann", 30, "the quick brown fox")
    bob = person(ca, "bob", 41, "jumps over the lazy dog", ann)
    cat = person(ca, "Cat", 25, "a quick answer, over and out", bob)
    cb.ask(1, 1, zsp.matches(text, "quick"), [zsp.by(age)])
    cb.answer(1)
    cb.until(lambda: cb.answers[1].get("rows") == [cat, ann])
    assert cb.answers[1]["total"] == 2 and cb.answers[1]["settled"]
    # The rows come with it, though nothing is watched, and change as they change.
    assert any(body == b"Ann" for body in cb.rows[ann].values())
    ca.write((ann, 20, zsp.VALUE, b"slow"))
    cb.until(lambda: cb.answers[1]["rows"] == [cat])
    ca.write((bob, 20, zsp.VALUE, b"QUICK!"), (bob, 17, zsp.VALUE, struct.pack(">d", 7)))
    cb.until(lambda: cb.answers[1]["rows"] == [bob, cat])
    # All together, with sums.
    cb.ask(2, 1, zsp.every(zsp.no(zsp.equals(name, "CAT")), zsp.between(age, 5, 35)), totals=[(zsp.SUM, age, 0), (zsp.FACET, name, 5)])
    assert set(cb.answer(2)["rows"]) == {ann, bob} and cb.answers[2]["totals"][0][0] == 37
    assert sorted(cb.answers[2]["totals"][1][1]) == [(1, b"ann"), (1, b"bob")]
    # By what they refer to, and what refers to them.
    cb.ask(3, 1, zsp.refers(friend, 1, zsp.equals(name, "ann")))
    assert cb.answer(3)["rows"] == [bob]
    cb.ask(4, 1, zsp.referred(friend, 1, zsp.ALL))
    assert set(cb.answer(4)["rows"]) == {ann, bob}
    cb.ask(5, 1, zsp.matches(text, "anwser", edits=1))
    assert cb.answer(5)["rows"] == [cat]
    # One is deleted, and gone from them all; and what makes no sense, or is not allowed, is said to be so.
    ca.write((cat, 0, zsp.GRAVE, b""))
    cb.until(lambda: cb.answers[1]["rows"] == [bob] and cb.answers[5]["rows"] == [])
    cb.ask(6, 9)
    cb.until(lambda: cb.answers.get(6, {}).get("denied"))
    cb.send(zsp.ASK, b"\7nonsense")
    cb.until(lambda: cb.answers.get(7, {}).get("faulty"))
    # What was kept of it is made again if it is gone, or is rubbish; either way the answers are the same.
    for damage in (False, True):
        b.stop()
        if damage:
            with open(os.path.join(b.dir, zspd_space(a), "find"), "wb") as f:
                f.write(os.urandom(50000))
        person(ca, "Dee", 50, "quick quick quick")
        b.start()
        cb = b.client()
        cb.ask(1, 1, zsp.matches(text, "quick"), [zsp.by(age)], totals=[(zsp.COUNT, age, 0)])
        cb.until(lambda: cb.answers.get(1, {}).get("total") == (3 if damage else 2))
        assert cb.answers[1]["rows"][0] == bob


def test_questions_passed_on():
    """A device that holds little has one that holds everything answer, whichever way it is reached."""
    for names, udp in ((("bc", "bd"), ()), (("be", "bf"), ("be", "bf"))):
        relay, (a, b) = space(*names, udp=udp)
        b.stop()
        b.options.append("--partial")
        b.start()
        ca, cb = a.client(), b.client()
        rows = [ca.put(1, "people", i, [b"person %d" % i]) for i in range(300)]
        ca.until(lambda: ca.acked == ca.seq)
        name = zsp.column(zsp.FOLD, 16)
        cb.ask(1, 1, zsp.begins(name, "person 2"), [zsp.by(name)], limit=20, totals=[(zsp.FACET, name, 3)])
        cb.until(lambda: cb.answers.get(1, {}).get("settled") and cb.answers[1]["total"] == 111)
        assert cb.answers[1]["rows"][0] == rows[2] and len(cb.answers[1]["rows"]) == 20 and len(cb.answers[1]["totals"][0][1]) == 3
        assert all(b"person 2" in b"".join(cb.rows[r].values()) for r in cb.answers[1]["rows"])
        assert rows[100] not in cb.rows
        # It stays true, whoever writes.
        start = time.monotonic()
        ca.write((rows[0], 16, zsp.VALUE, b"person 2"))
        cb.until(lambda: cb.answers[1]["total"] == 112 and set(cb.answers[1]["rows"][:2]) == {rows[0], rows[2]})
        print(f"     a change over there shows in an answer here in {1000 * (time.monotonic() - start):.1f} ms")
        cb.write((rows[2], 16, zsp.VALUE, b"nobody"))
        cb.until(lambda: cb.answers[1]["total"] == 111 and cb.answers[1]["rows"][0] == rows[0])
        # Once, from over there, whatever is held here.
        once = cb.fetch(1, zsp.begins(name, "person 1"), [zsp.by(name)], limit=5)
        assert once["settled"] and once["total"] == 111 and len(once["cells"]) == 5
        assert all(b"person 1" in b"".join(c.values()) for c in once["cells"].values())
        # With nobody to ask, what is here is the answer, and says so; and then not.
        a.stop()
        cb.until(lambda: not cb.answers[1].get("settled", True) and cb.answers[1]["total"] >= 20, 40) # not before it has been asked seven times
        assert not cb.fetch(1, zsp.equals(name, "person 2"))["settled"]
        cb.ask(2, 1, zsp.equals(name, "person 2"))
        assert cb.answer(2)["rows"] == [rows[0]] and not cb.answers[2]["settled"]
        a.start()
        cb.until(lambda: cb.answers[1].get("settled") and cb.answers[1]["total"] == 111, 20)
        cb.until(lambda: cb.answers[2].get("settled"))
        cb.unask(1), cb.unask(2)


def test_questions_fallen_behind():
    """A client that does not listen while much changes is told, once it does, how things have come to be."""
    relay, (a, b) = space("bg", "bh")
    ca, cb = a.client(), b.client()
    rows = [ca.put(1, "people", i, [b"person %d" % i]) for i in range(20)]
    name = zsp.column(zsp.FOLD, 16)
    cb.ask(1, 1, zsp.begins(name, "p"), [zsp.by(name)], limit=50)
    cb.until(lambda: cb.answers.get(1, {}).get("total") == 20)
    for i in range(1500):
        ca.write(*((r, 17, zsp.VALUE, b"%d" % i + b"x" * 1000) for r in rows))
    ca.write((rows[0], 16, zsp.VALUE, b"person last"))
    ca.until(lambda: ca.acked == ca.seq, 60)
    time.sleep(1.5)
    cb.until(lambda: len(cb.rows) == 20 and all(b"1499" + b"x" * 1000 in r.values() for r in cb.rows.values()), 20)
    cb.until(lambda: cb.answers[1]["rows"][-1] == rows[0])
    # All at once, so that nothing else happens there afterwards; and none of it changes the answer.
    for n in range(5):
        ca.write(*((r, 17 + i, zsp.VALUE, b"at once %d" % n) for r in rows for i in range(1, 30)))
        cb.until(lambda: all(list(r.values()).count(b"at once %d" % n) == 29 for r in cb.rows.values()), 5)
        time.sleep(0.2)


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
    ca.put(1, "x", 2, [os.urandom((1 << 20) - 192)])
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
    # Whoever is sent away hears why, after all that was being said.
    c = a.client()
    c.watch(1, 1, "x")
    c.send(zsp.WATCH, b"\xff")
    time.sleep(0.5)
    try:
        c.drain(5)
        raise SystemExit("not told")
    except PermissionError as e:
        assert str(e) == "fault 1", e
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
    ca.send(zsp.CALL, zsp.varint(9) + ca.devices[1][0] + zsp.varint(1) + zsp.varint(3) + b"add\0hi")
    ca.calls[9] = {"data": [], "ended": False, "fault": None}
    cb.drain(1)
    ca.until(lambda: ca.calls[9]["data"] == [b"hi!"])

    # A device that was away while everything happened, with nobody else online.
    a.stop(), b.stop()
    c = Node("r", "run", "--no-udp", "--credential=" + cloud.token)
    zspd("admit", a.dir, zspd("key", c.dir), "1")
    zspd("join", c.dir, zspd_space(a), cloud.key, cloud.url)
    # And one without the credential, which in all this time is told nothing.
    d = Node("s", "run", "--no-udp")
    zspd("join", d.dir, zspd_space(a), cloud.key, cloud.url)
    d.start()
    a.start()
    time.sleep(2)
    a.stop()
    c.start()
    cc = c.client()
    cc.until(lambda: cc.scopes)  # told as soon as the node is
    cc.watch(1, 1, "chat")
    cc.until(lambda: len(cc.list(1, "chat")) == 300)
    assert not os.path.exists(os.path.join(d.dir, zspd_space(a), "roster"))


def test_busy_node_takes_change():
    """A change made beside a running node that is slow to answer is held out to it until it says it has it."""
    import threading

    d = Node("busy").dir
    zspd("create", d)
    server = socket.socket()
    server.bind(("127.0.0.1", 0))
    server.listen(4)
    with open(os.path.join(d, "address"), "w") as f:
        f.write("127.0.0.1:%d" % server.getsockname()[1])
    with open(os.path.join(d, "token"), "w") as f:
        f.write("t")
    hung_up, heard = [], []

    def whole(said):
        # The request, and all of the one WebSocket message after it.
        if b"\r\n\r\n" not in said:
            return False
        data = said[said.index(b"\r\n\r\n") + 4 :]
        if len(data) < 2:
            return False
        n, at = data[1] & 127, 2
        if n == 126:
            n, at = (int.from_bytes(data[2:4], "big") if len(data) >= 4 else 1 << 30), 4
        elif n == 127:
            n, at = (int.from_bytes(data[2:10], "big") if len(data) >= 10 else 1 << 30), 10
        return len(data) >= at + 4 + n

    def busy():
        # As a node that takes three seconds to answer: did whoever spoke wait for it?
        server.settimeout(30)
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            got = b""
            while not whole(got):  # however it comes, in pieces or at once
                got += conn.recv(4096)
            heard.append(got)
            time.sleep(3)
            conn.setblocking(False)
            try:
                hung_up.append(conn.recv(1, socket.MSG_PEEK) == b"")
            except BlockingIOError:
                hung_up.append(False)
            conn.setblocking(True)
            answer = bytes([9, 2]) + (1).to_bytes(8, "big")
            conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n" + bytes([0x82, len(answer)]) + answer)
            conn.close()

    t = threading.Thread(target=busy, daemon=True)
    t.start()
    p = subprocess.run([BIN, "scope", d], capture_output=True, text=True, timeout=60)
    server.close()
    assert p.returncode == 0, p.stderr
    assert len(hung_up) == 2 and not any(hung_up), hung_up  # asked its clock, then handed the change, waiting each time

    def frames(said):
        # The client's one WebSocket message, unmasked, as the protocol's frames: each a varint length, then its kind.
        data = said[said.index(b"\r\n\r\n") + 4 :]
        n, at = data[1] & 127, 2
        if n == 126:
            n, at = int.from_bytes(data[2:4], "big"), 4
        elif n == 127:
            n, at = int.from_bytes(data[2:10], "big"), 10
        mask, at = data[at : at + 4], at + 4
        body = bytes(b ^ mask[i % 4] for i, b in enumerate(data[at : at + n]))
        kinds, r = [], 0
        while r < len(body):
            size, shift = 0, 0
            while True:
                byte = body[r]
                r += 1
                size |= (byte & 127) << shift
                shift += 7
                if byte < 128:
                    break
            kinds.append(body[r])
            r += size
        return kinds

    assert frames(heard[0]) == [1] and frames(heard[1]) == [1, 2], [frames(h) for h in heard]  # a greeting; then with the roster


def test_relay_full():
    """A relay that can keep no more of a space says so and lets go, and nothing anyone has is lost or garbled: as one
    with nowhere to put what its object's own storage cannot hold, or whose object storage is down, comes to."""
    cloud = Cloud().start(ACCESS_TOKEN="sesame", STORAGE_LIMIT="1500000", FULL_WAIT="3000", NO_R2="1")
    _, (a, b) = space("fa", "fb", relay=cloud, options=["--credential=" + cloud.token])
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "big")
    cb.until(lambda: 1 in cb.windows)
    sent = {}
    for i in range(80):  # five megabytes, where one and a half may be kept
        sent[i] = bytes([i]) * 65536
        ca.put(1, "big", i, [sent[i]])
    host, port = cloud.address.split(":")

    def knock():
        k = socket.create_connection((host, int(port)))
        k.sendall(
            f"GET /{zspd_space(a)} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".encode()
        )
        status = k.recv(200).split(b" ")[1]
        k.close()
        return status

    eventually("the relay says it is full", lambda: knock() == b"507", timeout=30)
    assert cloud.p.poll() is None, "and is still there"
    # The other has some of it, all of it whole; the one who wrote has it all.
    cb.drain(0.5)
    got = {order: values[16] for order, _, values in cb.list(1, "big")}
    assert 0 < len(got) < 80, len(got)
    assert all(got[o] == sent[o] for o in got), "nothing garbled"
    ca.drain(0.5)
    assert len(ca.list(1, "big")) == 80, "nothing lost"
    # And after a while it lets devices in again, from what it kept.
    eventually("it lets devices in again", lambda: knock() == b"101", timeout=15)


def test_relay_unbounded():
    """With object storage behind it, a relay keeps far more of a space than its object's own storage may hold, and
    each device comes to have all of it, whole."""
    cloud = Cloud().start(ACCESS_TOKEN="sesame", STORAGE_LIMIT="3000000", CACHE_BYTES="400000", PAGES_KEPT="64", BLOCKS_KEPT="4")
    _, (a, b) = space("ua", "ub", relay=cloud, options=["--credential=" + cloud.token])
    ca, cb = a.client(), b.client()
    cb.watch(1, 1, "big")
    cb.until(lambda: 1 in cb.windows)
    sent = {}
    for i in range(240):  # fifteen megabytes, five times what may be kept there
        sent[i] = bytes([i]) * 65536
        ca.put(1, "big", i, [sent[i]])
    cb.until(lambda: len(cb.list(1, "big")) == 240, timeout=120)
    got = {order: values[16] for order, _, values in cb.list(1, "big")}
    assert all(got[o] == sent[o] for o in sent), "nothing garbled"
    url = cloud.url.replace("ws", "http", 1) + "/" + zspd_space(a) + "?stats"
    stats = json.loads(urllib.request.urlopen(url).read())
    assert stats["sqlite"] < 3000000, stats
    assert stats["node"]["extents"] >= 10 and stats["node"]["checkpoints"] > 0, stats

    # What the writing left to do (extents, checkpoints, what they read) is done before what follows is counted: nothing
    # goes to or comes from R2 for a second. (Pages may stay changed until the next checkpoint, which may be long.)
    def r2(st):
        return [st["storage"][k] for k in ("gets", "puts", "deletes")] + [st["node"][k] for k in ("checkpoints", "extents", "uploaded")]

    seen = []
    deadline = time.monotonic() + 60
    while True:
        s0 = json.loads(urllib.request.urlopen(url).read())
        time.sleep(1)
        stats = json.loads(urllib.request.urlopen(url).read())
        seen.append(r2(stats))
        if r2(s0) == r2(stats):
            break
        assert time.monotonic() < deadline, ("the relay never stops reaching R2", seen[-5:])
    # A device that comes later is sent all of it, much of it from object storage, which is read an extent at a time.
    before, got = stats["storage"]["gets"], stats["storage"]["got"]
    c = Node("uc", "run", "--credential=" + cloud.token, "--no-udp")
    zspd("admit", a.dir, zspd("key", c.dir), "1")
    zspd("join", c.dir, zspd_space(a), cloud.key, cloud.url)
    c.start()
    eventually("it hears who belongs", lambda: os.path.exists(os.path.join(c.dir, zspd_space(a), "roster")))
    cc = c.client()
    cc.watch(1, 1, "big")
    cc.until(lambda: len(cc.list(1, "big")) == 240, timeout=120)
    assert all(values[16] == sent[order] for order, _, values in cc.list(1, "big")), "nothing garbled"
    stats = json.loads(urllib.request.urlopen(cloud.url.replace("ws", "http", 1) + "/" + zspd_space(a) + "?stats").read())
    # Nothing fetched twice: little more than the log, and its pages. And in stretches, not a block at a time (some 240
    # gets): how long each is depends on how fast the device reads, so the bound leaves room for a slow one.
    extents, log = stats["node"]["extents"], stats["node"]["tail"]
    assert stats["storage"]["got"] - got <= log * 1.25, ("fetched more than once", stats)
    assert 0 < stats["storage"]["gets"] - before <= 4 * extents, ("fetched a little at a time", stats)


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


def slow_expose_hibernation():
    """What a device exposes through the relay on Durable Objects is still reached once the object has slept."""
    cloud = Cloud().start(EXPOSE_DOMAIN="expose.test")
    _, (a,) = space("xh", relay=cloud)
    ca = a.client()
    web = free_port()
    Service("127.0.0.1", web, says=b"still here")
    ca.expose(web)
    eventually("the relay says where", lambda: [r["status"] for e in ca.exposures() for r in e["relays"]] == [0])
    label = ca.exposures()[0]["label"]
    host, port = cloud.address.split(":")
    assert http_get(host, int(port), host=label + ".expose.test") == (200, b"still here")
    time.sleep(15)  # the object is evicted; its sockets are not, and the device has no reason to say it again
    assert http_get(host, int(port), host=label + ".expose.test") == (200, b"still here")
    cloud.p.terminate()
    assert "woke with 1 sockets" in cloud.p.stdout.read() + open(os.path.join(TMP, "cloud.log")).read()


given_ports = set()


def free_port(host="127.0.0.1"):
    """A port nothing listens on, for a node to listen on later. Not one the system would give (port 0): those are
    the ephemeral ports every outgoing connection takes one of, so one could be taken between now and the node's
    listening, and the node would go without. These are below every system's ephemeral range (Linux's 32768,
    macOS's and Windows's 49152), and handed out once each."""
    import random

    while True:
        port = random.randrange(20000, 32768)
        if port in given_ports:
            continue
        with socket.socket() as s:
            try:
                s.bind((host, port))
            except OSError:
                continue
        given_ports.add(port)
        return port


def bindable(address):
    """Whether this machine has the address (macOS has 127.0.0.1 alone until zspd setup gives it more)."""
    try:
        with socket.socket() as s:
            s.bind((address, 0))
        return True
    except OSError:
        return False


def lan_address():
    """An address of this machine that is not loopback, if it has one: another machine, as far as an offer can tell."""
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.connect(("192.0.2.1", 9))  # nothing is sent
            a = s.getsockname()[0]
        return None if a.startswith("127.") else a
    except OSError:
        return None


def resolve(server, name, qtype=1):
    """Asks a node for a name, as a system resolver would: the address, or the rcode if there is none."""
    q = os.urandom(2) + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    q += b"".join(bytes([len(label)]) + label.encode() for label in name.split(".")) + b"\x00" + struct.pack(">HH", qtype, 1)
    host, port = server.rsplit(":", 1)
    six = host.startswith("[")
    host = host.strip("[]")
    with socket.socket(socket.AF_INET6 if six else socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.settimeout(2)
        s.sendto(q, (host, int(port)))
        a = s.recv(512)
    assert a[:2] == q[:2] and a[12 : len(q)] == q[12:], "the question comes back as asked"
    if a[3] & 15 or struct.unpack(">H", a[6:8])[0] == 0:
        return a[3] & 15
    return ".".join(map(str, a[-4:]))


class Service:
    """A TCP service on this machine: HTTP that says who it is, or one that speaks first, as SSH does."""

    def __init__(self, host, port, banner=None, says=b""):
        import threading

        self.sock = socket.create_server((host, port))
        self.banner, self.says, self.peers, self.heads = banner, says, [], []
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        import threading

        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.one, args=(c,), daemon=True).start()

    def one(self, c):
        try:
            self.talk(c)
        except OSError:
            pass  # reset, as some are meant to be

    def talk(self, c):
        with c:
            self.peers.append(c)
            if self.banner:
                c.sendall(self.banner)  # before a word from the other side
                while (data := c.recv(65536)) :
                    c.sendall(data)
                c.sendall(b"bye")  # after the other side has finished: half-closed, not closed
                return
            head = b""
            while b"\r\n\r\n" not in head.removeprefix(b"\r\n\r\n\x00\r\nQUIT\n") and (data := c.recv(4096)):
                head += data
            self.heads.append(head)
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(self.says), self.says))


def http_get(address, port, host=None, origin=None, proxy=None):
    """A GET by hand, so nothing is hidden: the status and body, or None if the connection was refused or reset."""
    try:
        if proxy:  # SOCKS 5, by name
            s = socket.create_connection(proxy, 10)
            s.sendall(b"\x05\x01\x00")
            assert s.recv(2) == b"\x05\x00"
            s.sendall(b"\x05\x01\x00\x03" + bytes([len(address)]) + address.encode() + struct.pack(">H", port))
            reply = s.recv(10)
            if len(reply) < 2 or reply[1] != 0:
                return None
        else:
            s = socket.create_connection((address, port), 10)  # a slow machine's first connection makes a tunnel
        with s:
            extra = f"Origin: {origin}\r\n" if origin else ""
            s.sendall(f"GET / HTTP/1.1\r\nHost: {host or address}:{port}\r\nConnection: close\r\n{extra}\r\n".encode())
            got = b""
            while data := s.recv(65536):  # until the answer is whole, as framed, or the connection ends
                got += data
                head, sep, rest = got.partition(b"\r\n\r\n")
                lower = head.lower()
                if sep and b"transfer-encoding: chunked" in lower and rest.endswith(b"0\r\n\r\n"):
                    break
                if sep and b"content-length:" in lower:
                    length = int(lower.split(b"content-length:")[1].split(b"\r\n")[0])
                    if len(rest) >= length:
                        break
    except OSError:
        return None
    if not got:
        return None
    head, _, body = got.partition(b"\r\n\r\n")
    if b"transfer-encoding: chunked" in head.lower():
        whole = b""
        while body:
            size, _, body = body.partition(b"\r\n")
            if int(size, 16) == 0:
                break
            whole, body = whole + body[: int(size, 16)], body[int(size, 16) + 2 :]
        body = whole
    return int(head.split()[1]), body


def ports_space(n, owner_offers=False):
    """A relay and n devices that share scope 1, each with its own addresses for the others and its own name server."""
    relay = Node("pr-relay", "serve", "--no-udp").start()
    devices = []
    for i in range(n):
        dns = "127.0.0.1:%d" % free_port()
        d = Node("pd%d" % i, "run", "--no-udp", "--loopback=127.%d.0" % (90 + i), "--dns=" + dns, "--catch=127.0.0.1:0",
                 "--proxy=127.0.0.1:%d" % free_port())
        d.dns, d.base = dns, "127.%d.0" % (90 + i)
        devices.append(d)
    sid = zspd("create", devices[0].dir)
    url = "ws://localhost:" + relay.address.split(":")[1]
    zspd("relay", devices[0].dir, relay.key, url)
    for d in devices[1:]:
        zspd("admit", devices[0].dir, zspd("key", d.dir), "1")
        zspd("join", d.dir, sid, relay.key, url)
    for d in devices:
        d.start()
    for d in devices:
        eventually("every device hears who belongs", lambda: os.path.exists(os.path.join(d.dir, sid, "roster")))
    return relay, devices


def address_of(client, device_key):
    return next(n["address"] for n in client.nodes() if n["device"].hex() == device_key)


def test_names():
    """Every device has a name and an address on every other, which any resolver asking here finds; nothing else does."""
    _, (a, b, c) = ports_space(3)
    zspd("name", a.dir, zspd("key", b.dir), "bee")
    ca = a.client()
    eventually("the name reaches every device", lambda: resolve(a.dns, "bee.zsp.internal") == a.base[:-1] + "0.3")
    assert resolve(a.dns, "BEE.Zsp.Internal") == a.base[:-1] + "0.3"
    eventually("and itself", lambda: resolve(b.dns, "bee.zsp.internal") == "127.0.0.1")
    nodes = {n["device"].hex(): n for n in ca.nodes()}
    assert nodes[b.key]["name"] == "bee.zsp.internal" and nodes[a.key]["here"]
    cid = nodes[c.key]["name"]
    assert cid.endswith(".id.zsp.internal") and resolve(a.dns, cid) == nodes[c.key]["address"] == a.base[:-1] + "0.4"
    assert resolve(a.dns, "bee.zsp.internal", 28) == 0  # no IPv6 address, and no error
    assert resolve(a.dns, "nobody.zsp.internal") == 3
    assert resolve(a.dns, "example.com") == 5
    # By TCP, as many as anyone asks at once, each answered, however fast they are asked.
    host, dport = a.dns.rsplit(":", 1)
    name = b"".join(bytes([60]) + b"a" * 60 for _ in range(4)) + b"\0"
    query = struct.pack(">HHHHHH", 7, 0x0100, 1, 0, 0, 0) + name + struct.pack(">HH", 1, 1)
    asked = 60000
    with socket.create_connection((host, int(dport)), 5) as s:
        import threading

        threading.Thread(target=lambda: s.sendall((struct.pack(">H", len(query)) + query) * asked), daemon=True).start()
        got, answers = b"", 0
        while answers < asked:
            data = s.recv(1 << 20)
            assert data, "the name server hung up after %d answers" % answers
            got += data
            while len(got) >= 2 and len(got) >= 2 + struct.unpack(">H", got[:2])[0]:
                got = got[2 + struct.unpack(">H", got[:2])[0]:]
                answers += 1
    assert a.p.poll() is None
    # And however fast one asker asks and reads, the others are answered meanwhile.
    stop = threading.Event()

    def ask_on():
        with socket.create_connection((host, int(dport)), 5) as s:
            s.settimeout(1)

            def read_on():
                while not stop.is_set():
                    try:
                        if not s.recv(1 << 20):
                            return
                    except OSError:
                        pass

            threading.Thread(target=read_on, daemon=True).start()
            frames = (struct.pack(">H", len(query)) + query) * 200
            while not stop.is_set():
                try:
                    s.sendall(frames)
                except OSError:
                    return

    flood = threading.Thread(target=ask_on, daemon=True)
    flood.start()
    time.sleep(0.3)
    try:
        for _ in range(5):
            assert resolve(a.dns, "bee.zsp.internal") == a.base[:-1] + "0.3"  # in under 2 s, each
    finally:
        stop.set()
        flood.join(5)
    # Renamed, the old name is nobody's; the address stays.
    zspd("name", a.dir, zspd("key", b.dir), "wasp")
    eventually("the new name", lambda: resolve(a.dns, "wasp.zsp.internal") == a.base[:-1] + "0.3")
    assert resolve(a.dns, "bee.zsp.internal") == 3


def test_names_over_ipv6():
    """A name server on an IPv6 address answers there, and zspd setup sends names to it as such."""
    try:
        with socket.socket(socket.AF_INET6) as probe:
            probe.bind(("::1", 0))
            port = probe.getsockname()[1]
    except OSError:
        return  # no IPv6 here
    dns = "[::1]:%d" % port
    _, (a,) = space("n6", options=("--dns=" + dns, "--catch=127.0.0.1:0", "--no-proxy"))
    ca = a.client()
    me = next(n for n in ca.nodes() if n["here"])
    eventually("it answers by IPv6", lambda: resolve(dns, me["name"]) == "127.0.0.1")
    if sys.platform.startswith("linux"):
        script = subprocess.run([BIN, "setup", "--dry-run", "--dns=" + dns], capture_output=True, text=True).stdout
        assert "resolvectl dns zsp0 %s " % dns in script, script
        # A port the system is to be told must be one; a domain may have a label "id".
        for flag in ("--catch=127.0.0.1:0", "--dns=127.0.0.1:0"):
            assert subprocess.run([BIN, "setup", "--dry-run", flag], capture_output=True).returncode != 0, flag
        assert subprocess.run([BIN, "setup", "--dry-run", "--names=tunnel.example.id"], capture_output=True).returncode == 0
        # As many addresses as there are devices, all within 127.a.b.2 to 127.a.255.255.
        assert subprocess.run([BIN, "setup", "--dry-run", "--loopback=127.77.255", "--devices=600"], capture_output=True).returncode != 0
        assert subprocess.run([BIN, "setup", "--dry-run", "--loopback=127.77.254", "--devices=300"], capture_output=True).returncode == 0


def test_services_by_scope():
    """What a device lists among its services is what it offers in the scope asked of, and what listens now, though
    nobody has been kept up with it."""
    _, (a, b) = space("sv", "sw")
    two = zspd("scope", a.dir, "signed")
    zspd("admit", a.dir, zspd("key", b.dir), two)
    ca, cb = a.client(), b.client()
    cb.until(lambda: int(two) in cb.scopes)
    web = free_port()
    Service("127.0.0.1", web, says=b"x")
    ca.offer(web, 1, name="local")
    ca.offer(9999, int(two), host="10.0.0.5", name="secret")

    def listed(scope):
        answer = cb.call(bytes.fromhex(a.key), scope, "zsp.services")
        assert answer["fault"] is None, answer
        return b"".join(answer["data"])

    one = listed(1)
    assert b"\x03" + struct.pack(">H", web) in one and b"local" in one, one
    assert b"secret" not in one and struct.pack(">H", 9999) not in one, one
    assert b"secret" in listed(int(two))
    # A port offered in both, under a name in each: listed in each, as offered there.
    ca.offer(web, int(two), name="other")
    assert b"local" in listed(1) and b"other" not in listed(1)
    assert b"other" in listed(int(two)) and b"\x03" + struct.pack(">H", web) in listed(int(two)), listed(int(two))


def test_ports():
    """Offered ports, reached by name from any application, by address or proxy: two devices on one port, a service that
    speaks first, and nothing that is not offered, nor to anyone a web page sent."""
    _, (a, b, c) = ports_space(3)
    zspd("name", a.dir, zspd("key", b.dir), "bee")
    ca, cb, cc = a.client(), b.client(), c.client()
    ca.until(lambda: len(ca.devices) == 3)
    port, quiet = free_port(), free_port()
    web = Service("127.0.0.1", port, says=b"bee's")
    shell = Service("127.0.0.1", quiet, banner=b"SSH-2.0-zsp-test\r\n")
    direct = bindable(a.base[:-1] + "0.3")  # macOS without zspd setup: the proxy alone
    proxy = ("127.0.0.1", int(a.options[-1].rsplit(":", 1)[1]))
    bee = address_of(ca, b.key)

    # Nothing is offered unless it is.
    assert http_get("bee.zsp.internal", port, proxy=proxy) is None
    # The proxy goes to the space's devices and nowhere else: refused plainly, and closed.
    for target in (b"example.com:443", b"127.0.0.1:%d" % port):
        with socket.create_connection(proxy, 3) as s:
            s.sendall(b"CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n" % (target, target))
            got = b""
            while data := s.recv(4096):
                got += data
            assert got.startswith(b"HTTP/1.1 403 "), (target, got)
    if direct:
        assert http_get(bee, port) is None
    assert cb.offers() == []
    try:
        cb.offer(22, 9)  # a scope it may not call in: an offer that could never be taken up
        raise AssertionError("an offer in no scope of its own was made")
    except PermissionError:
        pass
    cb.offer((port, port + 1), 1, name="web")
    cb.offer(quiet, 1)
    assert [o["ports"] for o in cb.offers()] == [(port, port + 1), (quiet, quiet)]
    # Whoever looks the name up is kept up with what it offers: only what listens.
    resolve(a.dns, "bee.zsp.internal")
    eventually("the offer is heard", lambda: [p["port"] for p in next(n for n in ca.nodes() if n["device"].hex() == b.key)["ports"]] == sorted([port, quiet]))
    assert http_get("bee.zsp.internal", port, proxy=proxy) == (200, b"bee's")
    if direct:
        assert http_get(bee, port, host="bee.zsp.internal") == (200, b"bee's")
        assert http_get(bee, port) == (200, b"bee's")
    # Applications open many connections at once: what listens for them has room for them all to wait, where the
    # system says so (ss shows a listener's backlog as its Send-Q).
    if sys.platform.startswith("linux") and shutil.which("ss"):
        for at in ([f"{bee}:{port}"] if direct else []) + [f"127.0.0.1:{proxy[1]}"]:
            line = subprocess.run(["ss", "-Hltn", "src", at], capture_output=True, text=True).stdout.split()
            assert line and int(line[2]) >= 1024, (at, line)
    # Asked once, without a lease, a device's list is said once, and then the call is over: asking for a lease after
    # makes it none of those kept up, which are so many at most, each device's and all.
    once = []
    for _ in range(6):
        call = ca.open(bytes.fromhex(b.key), 1, "zsp.ports", zsp.varint(0))
        call.send(zsp.varint(600))
        once.append(call)
    eventually("each is over", lambda: all(c["ended"] or c["fault"] is not None for c in once) or ca.step() and False, timeout=5)
    # A name of letters past ASCII goes as its bytes: the device refuses it as no name, not as no frame.
    said = []
    host = ca.host
    ca.host = lambda method, body=b"": said.append(body) or [b"\x00"]
    try:
        ca.expose(port, name="café")
    finally:
        ca.host = host
    assert said[0] == b"\x01" + struct.pack(">H", port) + zsp.varint(5) + "café".encode() + b"\x00", said
    # What a device offers is among the services it lists, to whoever it offers it.
    listed = ca.call(bytes.fromhex(b.key), 1, "zsp.services")
    data = b"".join(listed["data"])
    assert listed["fault"] is None and data[0] == 0, listed
    assert b"\x03" + struct.pack(">H", port) + b"\x00\x03web" in data, data

    # Two devices, one port: the other's is another machine's, offered from there.
    other = lan_address()
    if other and direct:
        Service(other, port, says=b"see's")
        cc.offer(port, 1, host=other)
        resolve(a.dns, ca.nodes()[2]["name"])
        see = address_of(ca, c.key)
        eventually("both are heard", lambda: any(p["port"] == port for n in ca.nodes() if n["device"].hex() == c.key for p in n["ports"]))
        assert http_get(see, port) == (200, b"see's") and http_get(bee, port) == (200, b"bee's")

    # A service that speaks first, as SSH does, and ends one way at a time.
    if direct:
        s = socket.create_connection((bee, quiet), 3)
        assert s.recv(64) == b"SSH-2.0-zsp-test\r\n"
        s.sendall(b"hello")  # a word, and nothing after: no browser's
        assert s.recv(64) == b"hello"
        s.shutdown(socket.SHUT_WR)
        got = b""
        while data := s.recv(64):
            got += data
        assert got == b"bye"
        s.close()

    # Who connects, said first to a service that asks, through an offer marked so.
    told = free_port()
    asks = Service("127.0.0.1", told, says=b"who?")
    cb.offer(told, 1, proxy=True)
    resolve(a.dns, "bee.zsp.internal")
    eventually("that offer is heard", lambda: any(p["port"] == told for n in ca.nodes() for p in n["ports"]))
    assert http_get("bee.zsp.internal", told, proxy=proxy) == (200, b"who?")
    head = asks.heads[-1]
    here = address_of(cb, a.key)  # a, as b sees it
    assert head.startswith(b"\r\n\r\n\x00\r\nQUIT\n\x21\x11") and head[16:20] == socket.inet_aton(here), head[:40]
    tlv = head[28:]
    assert tlv[:3] == b"\xe0\x00\x20" and tlv[3:35] == bytes.fromhex(a.key), tlv[:40]
    assert tlv[35] == 0xE1 and b".id.zsp.internal" in tlv[38:38 + struct.unpack(">H", tlv[36:38])[0]]

    # A page elsewhere, whose own name leads here, or that would send it here, reaches nothing.
    if direct:
        assert http_get(bee, port, host="attacker.example")[0] == 403
        assert http_get(bee, port, host="bee.zsp.internal", origin="https://attacker.example")[0] == 403
        assert http_get(bee, port, host="bee.zsp.internal", origin="http://bee.zsp.internal:%d" % port) == (200, b"bee's")
        with socket.create_connection((bee, port), 5) as s:  # fetch sends a method as it is given
            s.sendall(b"patch / HTTP/1.1\r\nHost: attacker.example\r\nOrigin: https://attacker.example\r\n\r\n")
            assert s.recv(64).startswith(b"HTTP/1.1 403 ")
    # Through the proxy alike: by name or address, after it has connected, or sent along with where to.
    assert http_get("bee.zsp.internal", port, host="attacker.example", proxy=proxy)[0] == 403
    assert http_get(bee, port, host="bee.zsp.internal", origin="https://attacker.example", proxy=proxy)[0] == 403
    assert http_get(bee, port, host="bee.zsp.internal", proxy=proxy) == (200, b"bee's")
    for request in (b"CONNECT bee.zsp.internal:%d HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\nHost: attacker.example\r\n\r\n" % port,
                    b"GET http://bee.zsp.internal:%d/ HTTP/1.1\r\nHost: attacker.example\r\n\r\n" % port):
        with socket.create_connection(proxy, 5) as s:
            s.sendall(request)
            got = b""
            while data := s.recv(4096):
                got += data
            assert got.startswith(b"HTTP/1.1 403 "), (request, got)
    # As an HTTP proxy, as curl -x is: the request in absolute form, written whole, and answered.
    with socket.create_connection(proxy, 5) as s:
        s.sendall(b"GET http://bee.zsp.internal:%d/ HTTP/1.1\r\nHost: bee.zsp.internal:%d\r\nConnection: close\r\n\r\n" % (port, port))
        got = b""
        while data := s.recv(4096):
            got += data
        assert got.startswith(b"HTTP/1.1 200 ") and got.endswith(b"bee's"), got
    # A request with more body than a request's head may be, and one whose client says all at once and shuts its side.
    counter = socket.create_server(("127.0.0.1", free_port()))

    def count_each():
        import threading

        while True:
            try:
                c, _ = counter.accept()
            except OSError:
                return

            def one(c):
                with c:
                    got = b""
                    while b"\r\n\r\n" not in got and (data := c.recv(65536)):
                        got += data
                    head, _, body = got.partition(b"\r\n\r\n")
                    length = int(head.lower().split(b"content-length:")[1].split(b"\r\n")[0])
                    while len(body) < length and (data := c.recv(65536)):
                        body += data
                    said = b"got %d" % len(body)
                    c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(said), said))

            threading.Thread(target=one, args=(c,), daemon=True).start()

    import threading

    threading.Thread(target=count_each, daemon=True).start()
    cport = counter.getsockname()[1]
    cb.offer(cport, 1)
    eventually("that offer too", lambda: any(p["port"] == cport for n in ca.nodes() for p in n["ports"]))
    for size in (8 << 10, 20 << 10):
        with socket.create_connection(proxy, 5) as s:
            s.sendall(b"POST http://bee.zsp.internal:%d/ HTTP/1.1\r\nHost: bee.zsp.internal:%d\r\nContent-Length: %d\r\n\r\n" % (cport, cport, size) + b"x" * size)
            s.shutdown(socket.SHUT_WR)
            got = b""
            while data := s.recv(4096):
                got += data
            assert got.startswith(b"HTTP/1.1 200 ") and got.endswith(b"got %d" % size), (size, got)
    def socks_to(address, port):
        s = socket.create_connection(proxy, 5)
        s.sendall(b"\x05\x01\x00")
        assert s.recv(2) == b"\x05\x00"
        s.sendall(b"\x05\x01\x00\x03" + bytes([len(address)]) + address.encode() + struct.pack(">H", port))
        assert s.recv(10)[1] == 0
        return s

    # Each request on a connection kept alive is judged, not the first alone: a page's request that passes (an image's
    # GET, which says no Origin) does not open the way for its next (a POST that says it).
    import http.server

    class Keep(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"ok")

        def do_POST(self):
            self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.do_GET()

        def log_message(self, *a):
            pass

    kept = http.server.ThreadingHTTPServer(("127.0.0.1", free_port()), Keep)
    threading.Thread(target=kept.serve_forever, daemon=True).start()
    kport = kept.server_address[1]
    cb.offer(kport, 1)
    eventually("that one", lambda: any(p["port"] == kport for n in ca.nodes() for p in n["ports"]))

    def answers(s, count):
        got, out = b"", []
        while len(out) < count:
            data = s.recv(65536)
            if not data:
                break
            got += data
            while b"\r\n\r\n" in got:
                head, _, rest = got.partition(b"\r\n\r\n")
                n = int(head.lower().split(b"content-length:")[1].split(b"\r\n")[0]) if b"content-length:" in head.lower() else 0
                if len(rest) < n:
                    break
                out.append(head.split(b"\r\n")[0])
                got = rest[n:]
        return out

    ways = [lambda: socks_to("bee.zsp.internal", kport)] + ([lambda: socket.create_connection((bee, kport), 5)] if direct else [])
    for open_one in ways:
        with open_one() as s:
            s.sendall(b"GET /warm HTTP/1.1\r\nHost: bee.zsp.internal\r\n\r\n")
            assert answers(s, 1) == [b"HTTP/1.1 200 OK"]
            s.sendall(b"GET /again HTTP/1.1\r\nHost: bee.zsp.internal\r\n\r\n")
            assert answers(s, 1) == [b"HTTP/1.1 200 OK"]  # a page's own, again
            s.sendall(b"POST /reuse HTTP/1.1\r\nHost: bee.zsp.internal\r\nOrigin: http://other.example\r\nContent-Length: 5\r\n\r\nhello")
            got = answers(s, 1)
            assert got == [b"HTTP/1.1 403 Forbidden"], got
        with open_one() as s:  # two at once (no browser does): the second is refused, and the connection with it
            s.sendall(b"POST /a HTTP/1.1\r\nHost: bee.zsp.internal\r\nContent-Length: 3\r\n\r\nabc"
                      b"GET /b HTTP/1.1\r\nHost: attacker.example\r\n\r\n")
            got = answers(s, 2)
            assert got[-1:] == [b"HTTP/1.1 403 Forbidden"] and len(got) <= 2, got
    kept.shutdown()

    # Refused as it says all it will at once (its request, then the end of it): the refusal is still read.

    for open_one in [lambda: socks_to("bee.zsp.internal", port)] + ([lambda: socket.create_connection((bee, port), 5)] if direct else []):
        for _ in range(5):
            with open_one() as s:
                s.sendall(b"GET / HTTP/1.1\r\nHost: attacker.example\r\n\r\n")
                s.shutdown(socket.SHUT_WR)
                got = b""
                while data := s.recv(4096):
                    got += data
                assert got.startswith(b"HTTP/1.1 403 "), got
    assert a.p.poll() is None
    with socket.create_connection(proxy, 5) as s:  # a word with the request, however short, is not what came first
        s.sendall(b"CONNECT bee.zsp.internal:%d HTTP/1.1\r\n\r\nG" % port)
        time.sleep(0.2)
        s.sendall(b"ET / HTTP/1.1\r\nHost: attacker.example\r\n\r\n")
        got = b""
        while data := s.recv(4096):
            got += data
        assert got.startswith(b"HTTP/1.1 403 "), got
    import json

    with open(os.path.join(b.dir, zspd_space(b), "audit.log")) as f:
        audit = [json.loads(line) for line in f]
    assert any(e["event"] == "open" and e["device"] == a.key and e["service"] == "tcp" for e in audit), audit
    assert any(e["event"] == "change" and e["service"] == "offer" for e in audit), audit


def cpu_seconds(pid):
    """Processor time a process has used, where the system says it plainly; None elsewhere."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            fields = f.read().rsplit(")", 1)[1].split()
        return (int(fields[11]) + int(fields[12])) / os.sysconf("SC_CLK_TCK")
    except (OSError, ValueError, AttributeError):
        pass
    try:
        out = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
        minutes, _, seconds = out.rpartition(":")
        return float(minutes or 0) * 60 + float(seconds)
    except (OSError, ValueError):
        return None


def test_quiet_while_kept_up():
    """A device kept up with what another offers, and the other keeping it up, do nothing between changes."""
    _, (a, b, c) = ports_space(3)
    ca, cb = a.client(), b.client()
    ca.until(lambda: len(ca.devices) == 3)
    port = free_port()
    Service("127.0.0.1", port, says=b"x")
    cb.offer(port, 1)
    resolve(a.dns, next(n["name"] for n in ca.nodes() if n["device"].hex() == b.key))  # a lease begins
    eventually("the offer is heard", lambda: any(p["port"] == port for n in ca.nodes() for p in n["ports"]))
    time.sleep(0.5)
    before = [cpu_seconds(d.p.pid) for d in (a, b)]
    if None in before:
        return  # where the time used cannot be had
    time.sleep(3)
    used = [cpu_seconds(d.p.pid) - t for d, t in zip((a, b), before)]
    assert max(used) < 0.15, f"kept up, and yet busy: {used} s of processor in 3 s"


def test_offers_end():
    """Taking an offer back, or a grant, cuts off whoever was using it, then and there."""
    _, (a, b, c) = ports_space(3)  # a owns the space, and offers; b uses it
    ca, cb = a.client(), b.client()
    cb.until(lambda: len(cb.devices) == 3)
    quiet = free_port()
    Service("127.0.0.1", quiet, banner=b"hi\r\n")
    start = time.monotonic()
    ca.offer(quiet, 1)
    assert time.monotonic() - start < 0.5, "answered at once, not at the next deadline"
    zspd("offer", c.dir, str(quiet), "1", "name=x")  # straight to the file when no node runs there: here one does
    assert zspd("offers", c.dir) == "%d 1 name=x" % quiet
    proxy = ("127.0.0.1", int(b.options[-1].rsplit(":", 1)[1]))
    there = address_of(cb, a.key)

    def connect():
        s = socket.create_connection(proxy, 3)
        s.sendall(b"\x05\x01\x00")
        s.recv(2)
        s.sendall(b"\x05\x01\x00\x01" + socket.inet_aton(there) + struct.pack(">H", quiet))
        assert s.recv(10)[1] == 0 and s.recv(4) == b"hi\r\n"
        s.settimeout(3)
        return s

    def cut(s):
        """Whether the connection has been cut off: it says nothing more, at once. Silence is not that."""
        try:
            s.sendall(b"x")
            return s.recv(1) == b""
        except socket.timeout:
            return False
        except OSError:
            return True

    s = connect()
    ca.unoffer(quiet, 1)
    assert cut(s)
    ca.offer(quiet, 1)
    s = connect()
    zspd("revoke", a.dir, zspd("key", c.dir))  # another's grant ends: nothing of this changes
    time.sleep(0.3)
    s.sendall(b"still")
    assert s.recv(5) == b"still"
    zspd("revoke", a.dir, zspd("key", b.dir))  # its own ends: cut off, whatever it would do
    assert cut(s)
    with open(os.path.join(a.dir, zspd_space(a), "audit.log")) as f:
        audit = f.read()
    assert audit.count('"service":"offer"') == 3 and b.key in audit


CERTS = os.path.join(ROOT, "tests", "certs")


def public_get(port, name, path="/", alpn=None):
    """A GET over TLS as the public makes it, checking the certificate as browsers do: status, body, protocol."""
    import ssl

    context = ssl.create_default_context(cafile=os.path.join(CERTS, "p256.pem"))
    if alpn:
        context.set_alpn_protocols(alpn)
    with socket.create_connection(("127.0.0.1", port), 5) as raw, context.wrap_socket(raw, server_hostname=name) as s:
        s.sendall(f"GET {path} HTTP/1.1\r\nHost: {name}\r\nConnection: close\r\n\r\n".encode())
        got = bytearray()  # not bytes, which would copy all it has at every record: a crawl, for a large body
        while data := s.recv(65536):
            got += data
        head, _, body = bytes(got).partition(b"\r\n\r\n")
        return int(head.split()[1]), body, s.selected_alpn_protocol()


def public_get_closing(port, name):
    """A GET over TLS whose client says close_notify at once after it, in the same write, and then reads the answer, as
    RFC 8446 lets it. The answer's bytes."""
    import ssl

    context = ssl.create_default_context(cafile=os.path.join(CERTS, "p256.pem"))
    inward, outward = ssl.MemoryBIO(), ssl.MemoryBIO()
    tls = context.wrap_bio(inward, outward, server_hostname=name)
    with socket.create_connection(("127.0.0.1", port), 5) as raw:
        while True:
            try:
                tls.do_handshake()
                break
            except ssl.SSLWantReadError:
                raw.sendall(outward.read())
                inward.write(raw.recv(65536))
        raw.sendall(outward.read())
        tls.write(f"GET / HTTP/1.1\r\nHost: {name}\r\nConnection: close\r\n\r\n".encode())
        try:
            tls.unwrap()
        except ssl.SSLWantReadError:
            pass
        raw.sendall(outward.read())  # the request and close_notify, together
        got = b""
        while True:
            try:
                got += tls.read(65536)
                continue
            except ssl.SSLWantReadError:
                pass
            except (ssl.SSLZeroReturnError, ssl.SSLEOFError):
                break
            data = raw.recv(65536)
            if not data:
                break
            inward.write(data)
        return got


def test_expose():
    """A port exposed to the public through a relay, at a name of its own, by TLS and by plain HTTP; with where each
    connection came from if asked; at the pace of the slower side; and no more once taken back."""
    https, plain = free_port(), free_port()
    relay = Node("ex-relay", "serve", "--no-udp", "--expose=expose.test", "--https=127.0.0.1:%d" % https, "--expose-http=127.0.0.1:%d" % plain,
                 "--tls-cert=" + os.path.join(CERTS, "p256.pem"), "--tls-key=" + os.path.join(CERTS, "p256.key")).start()
    _, (a, b) = space("ex", "ey", relay=relay)
    ca, cb = a.client(), b.client()
    port, told, big = free_port(), free_port(), free_port()
    web = Service("127.0.0.1", port, says=b"hello, public")
    proxied = Service("127.0.0.1", told, says=b"who?")
    data = os.urandom(8 << 20)
    Service("127.0.0.1", big, says=data)

    # Nothing is exposed unless it is: no name leads anywhere.
    assert ca.exposures() == []
    try:
        public_get(https, "anything.expose.test")
        raise AssertionError("an unexposed name answered")
    except OSError:
        pass
    exposed = ca.expose(port, name="web")
    label = exposed[0]["label"]
    assert label.startswith("web-") and len(label) == 20, label
    eventually("the relay says where", lambda: [r["url"] for e in ca.exposures() for r in e["relays"]] == ["https://%s.expose.test:%d" % (label, https)])
    name = label + ".expose.test"
    assert public_get(https, name, alpn=["h2", "http/1.1"]) == (200, b"hello, public", "http/1.1")
    assert public_get(https, name.upper()) [:2] == (200, b"hello, public")
    assert http_get("127.0.0.1", plain, host=name) == (200, b"hello, public")
    assert http_get("127.0.0.1", plain, host="nobody.expose.test")[0] == 404
    # A client that says it is done as it asks is answered all the same.
    assert public_get_closing(https, name).endswith(b"hello, public")
    # One whose TLS fails while it is not reading has its port's connection cut off: at once, where the relay may read
    # while it waits to write; else (Windows) once it has read nothing for PUBLIC_STALL (3 s as tests build it).
    import ssl, threading

    cut_at = []
    flood = socket.create_server(("127.0.0.1", free_port()))

    def flood_each():
        while True:
            try:
                c, _ = flood.accept()
            except OSError:
                return
            threading.Thread(target=flood_one, args=(c,), daemon=True).start()

    def flood_one(c):
        c.recv(65536)
        try:
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 67108864\r\n\r\n" + b"x" * (64 << 20))  # more than any buffer holds
            while c.recv(65536):
                pass
        except OSError:
            pass
        cut_at.append(time.monotonic())

    threading.Thread(target=flood_each, daemon=True).start()
    floods = ca.expose(flood.getsockname()[1], name="flood")[-1]["label"] + ".expose.test"
    eventually("it too", lambda: all(r["status"] == 0 for e in ca.exposures() for r in e["relays"]))
    context = ssl.create_default_context(cafile=os.path.join(CERTS, "p256.pem"))
    inward, outward = ssl.MemoryBIO(), ssl.MemoryBIO()
    tls = context.wrap_bio(inward, outward, server_hostname=floods)
    raw = socket.create_connection(("127.0.0.1", https), 5)
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    while True:
        try:
            tls.do_handshake()
            break
        except ssl.SSLWantReadError:
            raw.sendall(outward.read())
            inward.write(raw.recv(65536))
    tls.write(f"GET / HTTP/1.1\r\nHost: {floods}\r\n\r\n".encode())
    raw.sendall(outward.read())
    time.sleep(1)  # the answer fills what the relay may write to it
    raw.sendall(b"\x00" * 8)  # and then not TLS at all
    eventually("the port's connection is cut off", lambda: cut_at, timeout=10)
    raw.close()
    # And one that asks and never reads is let go once it has read nothing for PUBLIC_STALL: it holds no place for ever.
    stalled = []
    huge = socket.create_server(("127.0.0.1", free_port()))

    def huge_one():
        c, _ = huge.accept()
        c.recv(65536)
        try:  # without end, until whatever buffers there are (Windows' are large) are full and it is cut off
            c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
            chunk = b"100000\r\n" + b"x" * (1 << 20) + b"\r\n"
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                c.sendall(chunk)
        except OSError:
            stalled.append(time.monotonic())

    threading.Thread(target=huge_one, daemon=True).start()
    huges = ca.expose(huge.getsockname()[1], name="huge")[-1]["label"] + ".expose.test"
    eventually("that one", lambda: all(r["status"] == 0 for e in ca.exposures() for r in e["relays"]))
    asked = socket.create_connection(("127.0.0.1", plain), 5)
    asked.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    asked.sendall(f"GET / HTTP/1.1\r\nHost: {huges}\r\n\r\n".encode())
    start = time.monotonic()
    eventually("a reader that never reads is let go", lambda: stalled, timeout=15)
    assert stalled[0] - start >= 2.5, stalled[0] - start  # not before its time
    asked.close()
    ca.unexpose(huge.getsockname()[1])
    ca.unexpose(flood.getsockname()[1])
    # One that has heard all, the relay's end too, and never says its own end, is let go at PUBLIC_STALL (3 s here).
    half = socket.create_connection(("127.0.0.1", plain), 5)
    half.sendall(f"GET / HTTP/1.1\r\nHost: {name}\r\nConnection: close\r\n\r\n".encode())
    heard = b""
    while chunk := half.recv(4096):
        heard += chunk
    assert heard.endswith(b"hello, public"), heard
    time.sleep(4.5)
    try:
        half.sendall(b"x")
        time.sleep(0.3)
        half.sendall(b"x")
        raise AssertionError("the relay still holds a connection that never ended")
    except OSError:
        pass
    half.close()
    # A port that resets each connection as it accepts it: the public hears nothing from it, and the device and relay
    # go on as before.
    resets = socket.create_server(("127.0.0.1", free_port()))
    resets.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))  # each accepted resets as it closes

    def reset_each():
        while True:
            try:
                c, _ = resets.accept()
            except OSError:
                return
            c.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            c.close()

    import threading

    threading.Thread(target=reset_each, daemon=True).start()
    rst = ca.expose(resets.getsockname()[1], name="rst", proxy=True)[-1]["label"] + ".expose.test"  # said first, to nobody
    eventually("that one too", lambda: all(r["status"] == 0 for e in ca.exposures() for r in e["relays"]))
    for _ in range(30):
        http_get("127.0.0.1", plain, host=rst)
    assert a.p.poll() is None and relay.p.poll() is None
    assert http_get("127.0.0.1", plain, host=name) == (200, b"hello, public")
    ca.unexpose(resets.getsockname()[1])
    # A port nothing listens on: refused, and the device goes on.
    nothing = free_port()
    gone = ca.expose(nothing, name="gone")[-1]["label"] + ".expose.test"
    eventually("and that", lambda: all(r["status"] == 0 for e in ca.exposures() for r in e["relays"]))
    for _ in range(10):
        assert http_get("127.0.0.1", plain, host=gone)[0] == 502
    time.sleep(0.3)
    assert a.p.poll() is None and http_get("127.0.0.1", plain, host=name) == (200, b"hello, public")
    ca.unexpose(nothing)

    # Where each came from, if asked, before anything else.
    ca.expose(told, proxy=True)
    eventually("both are exposed", lambda: all(r["status"] == 0 for e in ca.exposures() for r in e["relays"]) and len(ca.exposures()) == 2)
    other = next(e["label"] for e in ca.exposures() if e["port"] == told)
    assert public_get(https, other + ".expose.test")[:2] == (200, b"who?")
    head = proxied.heads[-1]
    assert head.startswith(b"\r\n\r\n\x00\r\nQUIT\n\x21\x11\x00\x0c\x7f\x00\x00\x01\x7f\x00\x00\x01"), head[:28]  # from 127.0.0.1, to 127.0.0.1
    assert struct.unpack(">H", head[26:28])[0] == told and head[28:].startswith(b"GET / HTTP/1.1")
    assert not any(h.startswith(b"\r\n\r\n\x00") for h in web.heads if hasattr(web, "heads"))

    # As fast as the slower side takes it, and no faster: the relay keeps only what is in flight.
    ca.expose(big)
    eventually("the big one too", lambda: len(ca.exposures()) == 3 and all(r["status"] == 0 for e in ca.exposures() for r in e["relays"]))
    third = next(e["label"] for e in ca.exposures() if e["port"] == big) + ".expose.test"
    import ssl

    context = ssl.create_default_context(cafile=os.path.join(CERTS, "p256.pem"))
    slow = context.wrap_socket(socket.create_connection(("127.0.0.1", https), 5), server_hostname=third)
    slow.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1 << 16)
    slow.sendall(f"GET / HTTP/1.1\r\nHost: {third}\r\n\r\n".encode())
    got = slow.recv(1 << 16)
    time.sleep(1)  # reading nothing, while the device would send 8 MB
    rss = memory_of(relay.p.pid)
    while b"\r\n\r\n" not in got or len(got.partition(b"\r\n\r\n")[2]) < len(data):  # the body, not the head with it
        more = slow.recv(1 << 16)
        assert more, "the answer ended short"
        got += more
        if len(got) < 1 << 20:
            time.sleep(0.001)
    assert got.partition(b"\r\n\r\n")[2] == data
    if rss and "asan" not in BIN:  # AddressSanitizer keeps what is freed a while, by design
        assert rss < 24 << 20, f"the relay held {rss >> 20} MB for a reader that did not read"
        print(f"     a reader that did not read: the relay at {rss >> 20} MB")
    slow.close()

    # A device is not a relay: neither its own client nor another device may come as the public.
    for caller, device in ((ca, ca.devices[0][0]), (cb, a.key and bytes.fromhex(a.key))):
        r = caller.call(device, 1, "zsp.public", varint_bytes(label.encode()) + bytes(18))
        assert r["fault"] == 1, r

    # Taken back, a live connection is cut off and the name is nobody's.
    live = context.wrap_socket(socket.create_connection(("127.0.0.1", https), 5), server_hostname=third)
    live.sendall(f"GET / HTTP/1.1\r\nHost: {third}\r\n\r\n".encode())
    live.recv(1024)
    ca.unexpose(big)
    live.settimeout(5)
    try:
        while live.recv(1 << 16):
            pass
    except OSError:
        pass  # reset, or ended short: either way, not the 8 MB
    try:
        public_get(https, third)
        raise AssertionError("a name taken back still answers")
    except OSError:
        pass
    with open(os.path.join(a.dir, zspd_space(a), "audit.log")) as f:
        audit = f.read()
    assert '"service":"public"' in audit and '"peer":"127.0.0.1:' in audit and '"detail":"-%d"' % big in audit


class Echo:
    """A WebSocket server that says back what it hears, and the body of a POST it is sent."""

    def __init__(self, port):
        import threading

        self.sock = socket.create_server(("127.0.0.1", port))
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        import threading

        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.one, args=(c,), daemon=True).start()

    def one(self, c):
        import base64, hashlib

        try:
            with c:
                head = b""
                while b"\r\n\r\n" not in head:
                    head += c.recv(4096)
                head, _, rest = head.partition(b"\r\n\r\n")
                lines = head.decode().split("\r\n")
                headers = {k.lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
                if headers.get("upgrade", "").lower() != "websocket":
                    if headers.get("transfer-encoding") == "chunked":
                        body = b""
                        while not rest.endswith(b"0\r\n\r\n"):
                            rest += c.recv(65536)
                        while True:
                            size, _, rest = rest.partition(b"\r\n")
                            if int(size, 16) == 0:
                                break
                            body, rest = body + rest[: int(size, 16)], rest[int(size, 16) + 2 :]
                    else:
                        body = rest
                        while len(body) < int(headers.get("content-length", 0)):
                            body += c.recv(65536)
                    out = hashlib.sha256(body).hexdigest().encode() + b" " + lines[0].split()[1].encode()
                    c.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n%x\r\n%s\r\n0\r\n\r\n" % (len(out), out))
                    return
                accept = base64.b64encode(hashlib.sha1(headers["sec-websocket-key"].encode() + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest())
                c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + b"\r\n\r\n")
                buf = rest
                while True:
                    while len(buf) < 2 or len(buf) < ws_frame_size(buf):
                        data = c.recv(65536)
                        if not data:
                            return
                        buf += data
                    n = ws_frame_size(buf)
                    opcode, payload = ws_payload(buf[:n])
                    buf = buf[n:]
                    if opcode == 8:
                        c.sendall(ws_frame(8, payload, mask=False))
                        return
                    c.sendall(ws_frame(opcode, payload.upper() if opcode == 1 else payload, mask=False))
        except OSError:
            pass


def ws_frame(opcode, payload, mask=True):
    n = len(payload)
    head = bytes([0x80 | opcode]) + (bytes([n | (0x80 if mask else 0)]) if n < 126 else bytes([126 | (0x80 if mask else 0)]) + struct.pack(">H", n) if n < 65536 else bytes([127 | (0x80 if mask else 0)]) + struct.pack(">Q", n))
    if not mask:
        return head + payload
    key = os.urandom(4)
    return head + key + bytes(b ^ key[i % 4] for i, b in enumerate(payload))


def ws_frame_size(b):
    n, at = b[1] & 127, 2
    if n == 126:
        if len(b) < 4:
            return 1 << 30
        n, at = struct.unpack(">H", b[2:4])[0], 4
    elif n == 127:
        if len(b) < 10:
            return 1 << 30
        n, at = struct.unpack(">Q", b[2:10])[0], 10
    return at + (4 if b[1] & 128 else 0) + n


def ws_payload(b):
    n, at = b[1] & 127, 2
    if n == 126:
        at = 4
    elif n == 127:
        at = 10
    if b[1] & 128:
        key, at = b[at : at + 4], at + 4
        return b[0] & 15, bytes(x ^ key[i % 4] for i, x in enumerate(b[at:]))
    return b[0] & 15, b[at:]


def test_durable_object_expose():
    """What a device exposes, reached through the relay on Durable Objects: a GET, a POST of unknown length, a large
    answer at the reader's pace, a WebSocket, and nothing once taken back."""
    cloud = Cloud().start(EXPOSE_DOMAIN="expose.test")
    _, (a,) = space("dx", relay=cloud)
    ca = a.client()
    web, echo = free_port(), free_port()
    data = os.urandom(3 << 20)
    Service("127.0.0.1", web, says=data)
    Echo(echo)
    ca.expose(web, name="web")
    ca.expose(echo, name="echo")
    eventually("the relay says where", lambda: [r["status"] for e in ca.exposures() for r in e["relays"]] == [0, 0])
    labels = {e["port"]: e["label"] for e in ca.exposures()}
    assert all(r["url"] == "https://%s.expose.test" % labels[e["port"]] for e in ca.exposures() for r in e["relays"])
    host, port = cloud.address.split(":")
    assert http_get(host, int(port), host=labels[web] + ".expose.test") == (200, data)
    assert http_get(host, int(port), host="nobody.expose.test")[0] == 404

    # A body of unknown length goes as chunks, and comes back so.
    s = socket.create_connection((host, int(port)), 5)
    body = os.urandom(200000)
    s.sendall(f"POST /up?x=1 HTTP/1.1\r\nHost: {labels[echo]}.expose.test\r\nTransfer-Encoding: chunked\r\n\r\n".encode())
    for at in range(0, len(body), 50000):
        part = body[at : at + 50000]
        s.sendall(b"%x\r\n%s\r\n" % (len(part), part))
    s.sendall(b"0\r\n\r\n")
    got = b""
    while not got.endswith(b"0\r\n\r\n") and b"/up?x=1" not in got:
        got += s.recv(65536)
    import hashlib

    assert hashlib.sha256(body).hexdigest().encode() + b" /up?x=1" in got, got[:300]
    s.close()

    # A WebSocket, either way.
    s = socket.create_connection((host, int(port)), 5)
    s.sendall(f"GET /ws HTTP/1.1\r\nHost: {labels[echo]}.expose.test\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(4096)
    head, _, buf = head.partition(b"\r\n\r\n")
    assert b" 101 " in head.split(b"\r\n")[0], head
    for message in (b"hello", b"x" * 70000):
        s.sendall(ws_frame(1, message))
        while len(buf) < 2 or len(buf) < ws_frame_size(buf):
            buf += s.recv(65536)
        n = ws_frame_size(buf)
        opcode, payload = ws_payload(buf[:n])
        buf = buf[n:]
        assert opcode == 1 and payload == message.upper(), (opcode, payload[:20])
    s.close()

    # What a port says that is odd, or wrong: interim answers are passed over, an answer whose length cannot be told is
    # refused at once, an answer is over when its length has come though the port keeps its connection, and a message
    # larger than the platform carries ends the WebSocket. Whatever the platform says the public's address is.
    quirky = Quirky(free_port())
    ca.expose(quirky.port, name="odd")
    eventually("that too", lambda: len([r for e in ca.exposures() for r in e["relays"] if r["status"] == 0]) == 3)
    odd = next(e["label"] for e in ca.exposures() if e["port"] == quirky.port) + ".expose.test"

    def ask(path, extra=""):
        with socket.create_connection((host, int(port)), 5) as s:
            s.settimeout(5)
            s.sendall(f"GET {path} HTTP/1.1\r\nHost: {odd}\r\n{extra}Connection: close\r\n\r\n".encode())
            got = b""
            while data := s.recv(65536):  # until the answer is whole, as framed: workerd keeps the connection
                got += data
                head, sep, rest = got.partition(b"\r\n\r\n")
                lower = head.lower()
                if sep and b"transfer-encoding: chunked" in lower and rest.endswith(b"0\r\n\r\n"):
                    break
                if sep and b"content-length:" in lower and len(rest) >= int(lower.split(b"content-length:")[1].split(b"\r\n")[0]):
                    break
            return got

    for path in ("/100", "/103"):
        got = ask(path)
        assert got.startswith(b"HTTP/1.1 200 ") and b"ok" in got.partition(b"\r\n\r\n")[2], (path, got)
    for path in ("/bad-length", "/two-lengths", "/101"):
        assert ask(path).startswith(b"HTTP/1.1 502 "), path
    assert ask("/205").startswith(b"HTTP/1.1 205 "), ask("/205")
    for path in ("/chunk-negative", "/chunk-garbage"):  # a body cut short, never one made up
        got = ask(path)
        assert b"HELLO" not in got.partition(b"\r\n\r\n")[2], (path, got)
    with socket.create_connection((host, int(port)), 5) as kept:  # the public stays, having had what there was
        kept.sendall(f"GET /chunk-garbage-kept HTTP/1.1\r\nHost: {odd}\r\n\r\n".encode())
        heard = b""
        while b"\r\n\r\n" not in heard:
            heard += kept.recv(4096)
        eventually("and the port's connection is let go with it", lambda: quirky.closed.get("/chunk-garbage-kept"))
    assert b"ok" in ask("/keep").partition(b"\r\n\r\n")[2]
    eventually("the port's connection is let go once its answer has come", lambda: quirky.closed.get("/keep"))
    for ip in ("1:2:3:4:5:6:7:8:9", "::ffff:192.0.2.1", "nonsense", "300.1.1.1"):
        assert ask("/", f"cf-connecting-ip: {ip}\r\n").startswith(b"HTTP/1.1 200 "), ip
    s = socket.create_connection((host, int(port)), 5)
    s.sendall(f"GET /huge HTTP/1.1\r\nHost: {odd}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
              "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".encode())
    got = b""
    while b"\r\n\r\n" not in got:
        got += s.recv(4096)
    head, _, buf = got.partition(b"\r\n\r\n")
    assert b" 101 " in head.split(b"\r\n")[0], head
    s.settimeout(5)
    while len(buf) < 2 or len(buf) < ws_frame_size(buf):
        data = s.recv(65536)
        assert data, "closed without saying why"
        buf += data
    opcode, payload = ws_payload(buf[: ws_frame_size(buf)])
    assert opcode == 8 and payload[:2] == struct.pack(">H", 1009), (opcode, payload)
    s.close()

    ca.unexpose(web)
    eventually("taken back", lambda: http_get(host, int(port), host=labels[web] + ".expose.test")[0] in (404, 502))


class Quirky:
    """A port that answers oddly, or wrongly, by path; and says when each connection was closed by the other side."""

    def __init__(self, port):
        import threading

        self.port, self.closed = port, {}
        self.sock = socket.create_server(("127.0.0.1", port))
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        import threading

        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.one, args=(c,), daemon=True).start()

    def one(self, c):
        ok = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        answers = {
            "/100": b"HTTP/1.1 100 Continue\r\n\r\n" + ok,
            "/103": b"HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n\r\n" + ok,
            "/bad-length": b"HTTP/1.1 200 OK\r\nContent-Length: abc\r\n\r\nhello",
            "/two-lengths": b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 5\r\n\r\nhello",
            "/101": b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: x\r\n\r\n",
            "/205": b"HTTP/1.1 205 Reset Content\r\nContent-Length: 0\r\n\r\n",
            "/chunk-negative": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n-2\r\n5\r\n5\r\nHELLO\r\n0\r\n\r\n",
            "/chunk-garbage": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5GARBAGE\r\nHELLO\r\n0\r\n\r\n",
            "/chunk-garbage-kept": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nNOT A SIZE\r\n",  # and the connection kept
            "/keep": b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok",  # and the connection kept, asked or not
            "/huge": b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            b"Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n\x82\x7f\x00\x00\x01\x00\x00\x00\x00\x00",
        }
        try:
            with c:
                head = b""
                while b"\r\n\r\n" not in head and (data := c.recv(4096)):
                    head += data
                path = head.split(b" ")[1].decode() if head.count(b" ") >= 2 else "/"
                c.sendall(answers.get(path, ok))
                if path == "/keep":  # as a port that minds no end, nor Connection: close: let go only when it is cut off
                    deadline = time.monotonic() + 30
                    while time.monotonic() < deadline:
                        c.sendall(b"x")
                        time.sleep(0.05)
                if path == "/chunk-garbage-kept":  # the request's end comes at once: cut off is when a write fails
                    deadline = time.monotonic() + 30
                    while time.monotonic() < deadline:
                        time.sleep(0.2)
                        c.sendall(b"Z" * 16384)
                if path == "/huge":
                    c.settimeout(30)
                    while c.recv(4096):
                        pass
                    self.closed[path] = True
        except OSError:
            self.closed[path] = True


def test_expose_nowhere():
    """A relay that exposes nothing says so; the device exposes nothing there."""
    _, (a,) = space("en")
    ca = a.client()
    port = free_port()
    ca.expose(port)
    eventually("the relay says it will not", lambda: [r["status"] for e in ca.exposures() for r in e["relays"]] == [1])


def listening_ports(pid):
    """The TCP ports a process listens on, as Linux says; None elsewhere."""
    if not os.path.isdir("/proc/%d/fd" % pid):
        return None
    inodes = set()
    for fd in os.listdir("/proc/%d/fd" % pid):
        try:
            link = os.readlink("/proc/%d/fd/%s" % (pid, fd))
        except OSError:
            continue
        if link.startswith("socket:["):
            inodes.add(link[8:-1])
    ports = set()
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
        with open(table) as f:
            for line in f.readlines()[1:]:
                fields = line.split()
                if fields[3] == "0A" and fields[9] in inodes:  # listening
                    ports.add(int(fields[1].rsplit(":", 1)[1], 16))
    return ports


def test_own_ports_kept():
    """A device's own sockets are never offered nor exposed, though it offers every port and the system chose theirs:
    else another device could reach, through this one's proxy, what only this one may."""
    relay = Node("ok-relay", "serve", "--no-udp").start()
    a = Node("oka", "run", "--no-udp", "--dns=127.0.0.1:0", "--proxy=127.0.0.1:0", "--catch=127.0.0.1:0")
    b = Node("okb", "run", "--no-udp", "--dns=127.0.0.1:0", "--no-proxy", "--catch=127.0.0.1:0")
    sid = zspd("create", a.dir)
    url = "ws://localhost:" + relay.address.split(":")[1]
    zspd("relay", a.dir, relay.key, url)
    zspd("admit", a.dir, zspd("key", b.dir), "1")
    zspd("join", b.dir, sid, relay.key, url)
    a.start(), b.start()
    ca, cb = a.client(), b.client()
    cb.until(lambda: len(cb.devices) == 2)
    web = free_port()
    Service("127.0.0.1", web, says=b"offered")
    ca.offer((1, 65535), 1)
    seen = lambda: {p["port"] for n in cb.nodes() if n["device"].hex() == a.key for p in n["ports"]}
    eventually("what listens is offered", lambda: web in seen(), timeout=15)
    own = listening_ports(a.p.pid)
    if own is not None:
        assert len(own) >= 3, own  # its local API, proxy, and name server at least
        assert not own & seen(), own & seen()
        for port in own:
            try:
                ca.expose(port)
                raise AssertionError("its own port %d was exposed" % port)
            except PermissionError:
                pass


def client_hello(name):
    """A TLS 1.3 ClientHello for a name, as a record: X25519 and AES-128-GCM, its key share any 32 bytes."""
    sni = name.encode()
    ext = (struct.pack(">HHHBH", 0, len(sni) + 5, len(sni) + 3, 0, len(sni)) + sni
           + struct.pack(">HHBH", 43, 3, 2, 0x0304) + struct.pack(">HHHH", 10, 4, 2, 0x001D)
           + struct.pack(">HHHHH", 13, 6, 4, 0x0403, 0x0804) + struct.pack(">HHHHH", 51, 38, 36, 0x001D, 32) + os.urandom(32))
    body = struct.pack(">H", 0x0303) + os.urandom(32) + b"\x00" + struct.pack(">HH", 2, 0x1301) + b"\x01\x00" + struct.pack(">H", len(ext)) + ext
    hello = bytes([1]) + len(body).to_bytes(3, "big") + body
    return struct.pack(">BHH", 22, 0x0301, len(hello)) + hello


def test_public_outlives_its_device():
    """A device answers and leaves while the public is still reading the answer: the relay keeps what it is serving,
    space and all, until the public has read it, and touches nothing it has let go."""
    import threading

    def window():  # what a sender here may put out to a reader that reads nothing
        srv = socket.create_server(("127.0.0.1", 0))
        cli = socket.socket()
        cli.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
        cli.connect(srv.getsockname())
        acc, _ = srv.accept()
        acc.setblocking(False)
        total = 0
        deadline = time.monotonic() + 0.5
        while time.monotonic() < deadline:
            try:
                total += acc.send(b"A" * 16384)
            except BlockingIOError:
                time.sleep(0.01)  # as the system grows what it will hold
                try:
                    total += acc.send(b"A" * 16384)
                except BlockingIOError:
                    break
        for x in (acc, cli, srv):
            x.close()
        return total

    size = window() + (100 << 10)  # what the system holds for the reader, and less than a call's window more
    plain = free_port()
    relay = Node("od-relay", "serve", "--no-udp", "--expose=expose.test", "--expose-http=127.0.0.1:%d" % plain).start()
    _, (a,) = space("od", relay=relay)
    ca = a.client()
    backend = socket.create_server(("127.0.0.1", free_port()))
    done = threading.Event()

    def serve_one():
        c, _ = backend.accept()
        while c.recv(4096):
            pass
        c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" % size + b"X" * size)
        c.close()
        done.set()

    threading.Thread(target=serve_one, daemon=True).start()
    name = ca.expose(backend.getsockname()[1])[0]["label"] + ".expose.test"
    eventually("exposed", lambda: [r["status"] for e in ca.exposures() for r in e["relays"]] == [0])
    reader = socket.socket()
    reader.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4096)
    reader.connect(("127.0.0.1", plain))
    reader.sendall(f"GET / HTTP/1.1\r\nHost: {name}\r\n\r\n".encode())
    reader.shutdown(socket.SHUT_WR)
    assert done.wait(10)
    time.sleep(0.6)
    a.p.kill()  # the space's only device, gone
    a.p.wait()
    time.sleep(0.6)
    got = 0
    try:
        while data := reader.recv(1 << 16):
            got += len(data)
    except OSError:
        pass
    reader.close()
    time.sleep(0.3)
    assert relay.p.poll() is None, "the relay fell over"
    assert got > size, (got, size)  # the whole answer, head and all, though its device had left


def test_public_held_off():
    """The public cannot keep the public out: what is not TLS, what fails its handshake, and what says nothing leave
    nothing behind at the relay, and someone who has something to ask is still answered."""
    try:
        import resource

        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        resource.setrlimit(resource.RLIMIT_NOFILE, (min(hard, 8192), hard))
    except (ImportError, ValueError, OSError):
        pass
    https = free_port()
    relay = Node("ho-relay", "serve", "--no-udp", "--expose=expose.test", "--https=127.0.0.1:%d" % https,
                 "--tls-cert=" + os.path.join(CERTS, "p256.pem"), "--tls-key=" + os.path.join(CERTS, "p256.key")).start()
    _, (a,) = space("ho", relay=relay)
    ca = a.client()
    port = free_port()
    Service("127.0.0.1", port, says=b"still here")
    name = ca.expose(port)[0]["label"] + ".expose.test"
    eventually("exposed", lambda: [r["status"] for e in ca.exposures() for r in e["relays"]] == [0])
    assert public_get(https, name)[:2] == (200, b"still here")
    fds = lambda: len(os.listdir("/proc/%d/fd" % relay.p.pid)) if os.path.isdir("/proc/self/fd") else 0
    before = fds()

    # More than the relay holds at once of what is not TLS, and of hellos for names nobody has: each is let go.
    for junk in (b"\0\0\0\0\0", b"GET / HTTP/1.1\r\n\r\n"):
        for _ in range(1100):
            with socket.create_connection(("127.0.0.1", https), 5) as s:
                s.sendall(junk)
    eventually("the relay holds nothing of them", lambda: fds() <= before)
    assert public_get(https, name)[:2] == (200, b"still here")

    # One that says nothing, as fast as it can (change_cipher_spec after change_cipher_spec, mid-handshake), keeps
    # nobody else waiting.
    import threading

    stop = threading.Event()

    def babble():
        with socket.create_connection(("127.0.0.1", https), 5) as s:
            s.sendall(client_hello(name))
            while not stop.is_set():
                try:
                    s.sendall(b"\x14\x03\x03\x00\x01\x01" * 4096)
                except OSError:
                    return

    babbler = threading.Thread(target=babble, daemon=True)
    babbler.start()
    time.sleep(0.3)
    try:
        start = time.monotonic()
        assert public_get(https, name)[:2] == (200, b"still here")
        assert time.monotonic() - start < 2, time.monotonic() - start
    finally:
        stop.set()
        babbler.join(5)

    # More than it holds at once of connections that say nothing: the longest silent make room.
    silent = [socket.create_connection(("127.0.0.1", https), 5) for _ in range(1100)]
    assert public_get(https, name)[:2] == (200, b"still here")
    # Those that make room are the longest silent, not whoever came last: one that has just come stays while more come.
    time.sleep(0.2)
    newest = socket.create_connection(("127.0.0.1", https), 5)
    time.sleep(0.2)
    more = [socket.create_connection(("127.0.0.1", https), 5) for _ in range(2)]
    time.sleep(0.3)

    def let_go(s):
        s.setblocking(False)
        try:
            return s.recv(1) == b""
        except BlockingIOError:
            return False
        except OSError:
            return True

    assert not let_go(newest), "the newest was let go"
    for s in silent + more + [newest]:
        s.close()
    eventually("and of them", lambda: fds() <= before)


def varint_bytes(b):
    return zsp.varint(len(b)) + b


def memory_of(pid):
    """A process's resident memory, where the system says it plainly."""
    try:
        with open(f"/proc/{pid}/status") as f:
            return next(int(line.split()[1]) * 1024 for line in f if line.startswith("VmRSS:"))
    except OSError:
        return None


def zspd_space(node):
    with open(os.path.join(node.dir, "space")) as f:
        return f.read().strip()


def one(name, tests, file):
    start = time.monotonic()
    try:
        tests[name]()
        print(f"ok   {name} {time.monotonic() - start:.2f}s")
        return 0
    except BaseException as e:
        import traceback

        where = [f.lineno for f in traceback.extract_tb(e.__traceback__) if f.filename == file]
        print(f"FAIL {name}: {type(e).__name__} {e} at {where}\nlogs in {TMP}")
        for log in sorted(f for f in os.listdir(TMP) if f.endswith(".log")):
            with open(os.path.join(TMP, log), errors="replace") as f:
                print("".join(f"     {log}: {line}" for line in f.readlines()[-40:]), end="")
        return 1
    finally:
        for p in procs:
            p.kill()
            p.wait()


def main(tests=globals(), file=__file__):
    """Runs the tests named, or all of them: each in a process of its own, side by side. Others' tests use it too."""
    names = sys.argv[1:] or [n for n in tests if n.startswith("test_")]
    if len(names) == 1:
        code = one(names[0], tests, file)
        if code == 0:
            shutil.rmtree(TMP, ignore_errors=True)
        sys.exit(code)
    os.rmdir(TMP)
    runs = [subprocess.Popen([sys.executable, file, n], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for n in names]
    for r in runs:
        sys.stdout.write(r.communicate()[0])
    sys.exit(any(r.returncode for r in runs))


if __name__ == "__main__":
    main()
