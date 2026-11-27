"""Real processes on real sockets: a relay, devices and clients. Run by `./x test`."""

import json, os, re, shutil, signal, socket, struct, subprocess, sys, tempfile, threading, time, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))
import zsp


class Thread(threading.Thread):
    """A thread whose failure is the test's: raised again where it is joined, rather than only printed, as Python does
    with what a thread raises, letting the test pass."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.failed = None

    def run(self):
        try:
            super().run()
        except BaseException as e:
            self.failed = e

    def join(self, timeout=None):
        super().join(timeout)
        if self.failed is not None:
            raise self.failed


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


def read_kept(path):
    """What a node keeps, read while it may be replacing it: which Windows refuses for a moment, mid-replace."""
    for _ in range(200):
        try:
            with open(path, "rb") as f:
                return f.read()
        except PermissionError:
            time.sleep(0.01)
    with open(path, "rb") as f:
        return f.read()


def eventually(what, f, timeout=10):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if f():
            return
        time.sleep(0.02)
    raise AssertionError("never: " + what)


def space(*names, udp=(), relay=None, options=(), partial={}):
    """A relay and devices that share scope 1; some partial replicas from the first, and perhaps keeping what they say."""
    relay = relay or Node(names[0] + "-relay", "serve", "--no-udp").start()
    devices = [Node(n, "run", *options, *([] if n in udp else ["--no-udp"]), *partial.get(n, ())) for n in names]
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


def test_runner_says_what_fails():
    """Fails when ZSP_FAIL is set, as `./x selftest` sets it: to see that ./x test says this failed."""
    assert not os.environ.get("ZSP_FAIL"), "failing, as ZSP_FAIL asks"


def test_sync_through_relay():
    relay, (a, b) = space("a", "b")
    ca, cb = a.client(), b.client()
    # All of the list, for all of it is waited for: a window of the last 50 shows only those, whenever more than that come
    # at once, as they may through a busy relay, and a client holds those it was shown before only if they came apart.
    cb.watch(1, 1, "chat")
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
        # Within the usual while: the relay keeps the roster, fsyncs and all, which a busy machine may take seconds over;
        # a loop never woken for the name would wait for ever.
        eventually("the relay hears from it", lambda: os.path.exists(os.path.join(relay.dir, sid, "roster")))
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

    roster = lambda d: read_kept(os.path.join(d.dir, zspd_space(a), "roster"))
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
    relay, (a, b) = space("l", "m", partial={"m": ["--partial"]})
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


def test_partial_keeps():
    """A partial replica lets go of what nobody has watched for long enough, says that what it shows while it reaches
    nobody is only what it holds, and has what it let go of again once it is watched."""
    relay, (a, b) = space("pk", "pl", partial={"pl": ["--partial", "--keep=0.00002"]})  # about 1.7 seconds
    ca = a.client()
    for i in range(50):
        ca.put(1, "old", i, [b"x" * 100])
    ca.until(lambda: ca.acked == ca.seq)
    time.sleep(0.3)
    cb = b.client()
    cb.watch(1, 1, "old")
    cb.until(lambda: cb.windows.get(1, {}).get("settled") and len(cb.list(1, "old")) == 50)
    cb.sock.close()  # and so watches it no longer
    relay.stop()
    time.sleep(3)
    cc = b.client()
    cc.watch(1, 1, "old")
    cc.until(lambda: 1 in cc.windows)
    assert len(cc.list(1, "old")) == 0 and not cc.windows[1]["settled"], (len(cc.list(1, "old")), cc.windows[1])
    relay.start()
    cc.until(lambda: cc.windows[1]["settled"] and len(cc.list(1, "old")) == 50, 30)


def test_calls():
    relay, (a, b) = space("n", "o")
    ca, cb = a.client(), b.client()
    cb.serve(1, "add", lambda device, body: str(sum(map(int, body.split()))).encode())
    stop = threading.Event()

    def answer():
        while not stop.is_set():
            cb.drain(0.05)

    t = Thread(target=answer)
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
        # However urgent the caller says it is; and no more than 7.
        for urgency in range(8):
            assert ca.call(device, 1, "add", b"%d 1" % urgency, urgency=urgency)["data"] == [b"%d" % (urgency + 1)]
        try:
            ca.open(device, 1, "add", b"1 1", urgency=8)
            raise AssertionError("an urgency of 8")
        except ValueError:
            pass
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
        relay, (a, b) = space(*names, udp=udp, partial={names[1]: ["--partial"]})
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


def test_strangers_are_let_go():
    """A relay serving only some spaces refuses an upgrade to any other before anything is opened for it; and one that
    serves any lets go of a connection on which no session is ready within HANDSHAKE_WAIT, fifteen seconds, as anyone may
    leave one: nothing else need happen for it to."""
    allowed = os.urandom(32).hex()
    relay = Node("strangers-relay", "serve", "--no-udp", "--allow=" + allowed).start()
    k = knock(relay.address, "/" + allowed)
    k.close()
    host, port = relay.address.split(":")
    other = socket.create_connection((host, int(port)))
    other.sendall(
        f"GET /{os.urandom(32).hex()} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n".encode()
    )
    other.settimeout(10)
    assert other.recv(500) == b"", "a space not served was answered"
    other.close()
    idle = Node("idle-relay", "serve", "--no-udp").start()
    k = knock(idle.address, "/" + os.urandom(32).hex())
    k.settimeout(30)
    start = time.monotonic()
    assert k.recv(500) == b"", "said something"
    assert 10 < time.monotonic() - start < 25, time.monotonic() - start
    k.close()


def test_appointed_keep_their_rights():
    """Made an admin, or an owner, a device may read, write and call in every scope, and still do whatever else it might:
    vouch, where it could."""
    d, other = Node("appointing").dir, Node("appointed").dir
    zspd("create", d)
    key = zspd("key", other)
    zspd("admit", d, key, "1", "vouch")
    for appoint in (["admin", d, key], ["owner", d, key]):
        zspd(*appoint)
        line = next(l for l in zspd("members", d).splitlines() if l.startswith(key))
        assert " 1:rwcv " in line, (appoint[0], line)


def test_unkept_address_stops_the_node():
    """A node that cannot keep where it listens, by which admin commands find it, does not run: they would keep rosters
    beside it that it never took."""
    n = Node("unkept")
    zspd("create", n.dir)
    os.mkdir(os.path.join(n.dir, "address"))  # which no file is renamed onto: as a full disk, a save that fails
    p = subprocess.run([BIN, "run", n.dir, "--listen=127.0.0.1:0", "--no-udp"], capture_output=True, text=True, timeout=30)
    assert p.returncode == 1 and "could not keep" in p.stderr, (p.returncode, p.stderr)


def test_scopes_by_number():
    """A scope is named by its number, as the space has it: one past what a scope's number can be is no other scope, nor
    is 0, which would be every scope; nor one the space does not have."""
    d, other = Node("numbering").dir, Node("numbered").dir
    zspd("create", d)
    key = zspd("key", other)
    zspd("admit", d, key, "1")
    for bad in ("4294967297", "0", "7", "x"):
        assert refused("admit", d, key, bad), bad
    for bad in ("4294967296", "4294967297", "0", "7"):
        assert refused("revoke", d, key, bad), bad
    line = next(l for l in zspd("members", d).splitlines() if l.startswith(key))
    assert " 1:rwc" in line, line


def test_stops_when_told():
    """Told to stop, as a service manager or Ctrl+C tells it, a node finishes what it is doing and writes down what it keeps
    before it goes; told again, it goes at once."""
    if os.name == "nt":
        return  # a console's Ctrl+C reaches a process only in its own console; and Python's terminate is TerminateProcess
    relay, (a,) = space("st")
    ca = a.client()
    ca.put(1, "x", 1, [b"kept"])
    ca.until(lambda: ca.acked == ca.seq)
    for sig in (signal.SIGTERM, signal.SIGINT):
        a.p.send_signal(sig)
        assert a.p.wait(timeout=20) == 0, (sig, a.p.returncode)
        a.start()
        c = a.client()
        c.watch(1, 1, "x")
        c.until(lambda: len(c.list(1, "x")) == 1)


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
        # Until its node is done with them, as it is once it acknowledges them or sends them away: it seals every cell a
        # client writes, some hundred thousand here, which on a busy machine, built for debugging, takes longer than the
        # next client waits to be let in.
        try:
            c.until(lambda: c.acked >= c.seq, timeout=120)
        except (PermissionError, ConnectionError):
            pass
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
    cb.watch(1, 1, "chat")  # all of it, which is waited for (see test_sync_through_relay)
    cb.until(lambda: 1 in cb.windows)
    for i in range(300):
        ca.put(1, "chat", i, [b"message %d" % i])
    cb.until(lambda: len(cb.list(1, "chat")) == 300)
    row = cb.list(1, "chat")[-1][1]
    ca.live(row, 17, b"pieceone", 0, b"hello")
    cb.until(lambda: cb.lives)
    # The call is answered whenever it comes, as test_calls answers: not only within a second, which a busy machine
    # may take to carry it, as it does here, the answering device held up.
    cb.serve(1, "add", lambda device, body: body + b"!")
    stop = threading.Event()

    def answer():
        while not stop.is_set():
            cb.drain(0.05)

    answering = Thread(target=answer)
    answering.start()
    held = None
    try:
        ca.until(lambda: len(ca.devices) == 2)
        held = Thread(target=pause, args=(b.p, 1.5))
        held.start()
        time.sleep(0.1)
        ca.send(zsp.CALL, zsp.varint(9) + ca.devices[1][0] + zsp.varint(1) + zsp.varint(3) + b"add\0" + bytes([zsp.URGENCY]) + b"hi")
        ca.calls[9] = {"data": [], "ended": False, "fault": None}
        ca.until(lambda: ca.calls[9]["data"] == [b"hi!"])
    finally:
        if held:
            held.join()  # let go on before anything stops it, whatever failed
        stop.set()
        answering.join()

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
    d = Node("busy").dir
    sid = zspd("create", d)
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
            for kind, body in frames(got):
                if kind == 2:  # kept, as a node keeps a roster it takes before it answers
                    with open(os.path.join(d, sid, "roster"), "wb") as f:
                        f.write(body)
            conn.setblocking(False)
            try:
                hung_up.append(conn.recv(1, socket.MSG_PEEK) == b"")
            except BlockingIOError:
                hung_up.append(False)
            conn.setblocking(True)
            answer = bytes([9, 2]) + (1).to_bytes(8, "big")
            conn.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n" + bytes([0x82, len(answer)]) + answer)
            conn.close()

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
        said, r = [], 0
        while r < len(body):
            size, shift = 0, 0
            while True:
                byte = body[r]
                r += 1
                size |= (byte & 127) << shift
                shift += 7
                if byte < 128:
                    break
            said.append((body[r], body[r + 1 : r + size]))
            r += size
        return said

    t = Thread(target=busy, daemon=True)
    t.start()
    p = subprocess.run([BIN, "scope", d], capture_output=True, text=True, timeout=60)
    server.close()
    assert p.returncode == 0, p.stderr
    assert len(hung_up) == 2 and not any(hung_up), hung_up  # asked its clock, then handed the change, waiting each time
    kinds = [[kind for kind, _ in frames(h)] for h in heard]
    assert kinds == [[1], [1, 2]], kinds  # a greeting; then with the roster


def test_roster_kept_beside_a_running_node():
    """A change made beside a running node is kept by it, and the roster it follows as roster.old; one that it will not
    take, drawn up from a roster older than the node's, is neither kept in place of the node's nor said to be made."""
    n = Node("beside", "run", "--no-udp")
    sid = zspd("create", n.dir)
    kept = lambda name: read_kept(os.path.join(n.dir, sid, name))
    first = kept("roster")
    n.start()
    zspd("scope", n.dir)
    second = kept("roster")
    assert second != first and kept("roster.old") == first
    zspd("scope", n.dir)
    assert kept("roster.old") == second
    zspd("scope", n.dir)
    # As another admin command drawn up from what was kept two changes ago would be: it has a scope fewer than the node's.
    with open(os.path.join(n.dir, sid, "roster"), "wb") as f:
        f.write(second)
    p = subprocess.run([BIN, "scope", n.dir], capture_output=True, text=True)
    assert p.returncode != 0 and "would not take it" in p.stderr, (p.returncode, p.stderr)
    assert kept("roster") == second, "a roster the node would not take was kept"
    # And with no node running, it is kept here, for the node to read when it starts.
    n.stop()
    os.remove(os.path.join(n.dir, "address"))
    zspd("scope", n.dir)
    assert kept("roster.old") == second and kept("roster") != second


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


def test_call_outlasts_a_pause():
    """A call through a relay outlasts the relay's being silent for a while, as a busy machine's may be: the link between
    the devices waits before it gives up, however fast the path was."""
    relay, (a, b) = space("pa", "pb")
    ca, cb = a.client(), b.client()
    cb.serve(1, "echo", lambda device, body: body)
    stop = threading.Event()

    def answer():
        while not stop.is_set():
            cb.drain(0.05)

    t = Thread(target=answer)
    t.start()
    try:
        ca.until(lambda: len(ca.devices) == 2)
        device = ca.devices[1][0]
        assert ca.call(device, 1, "echo", b"hi")["data"] == [b"hi"]
        # A call under way, which this side has not ended: its link must not give up on the other end.
        held = ca.open(device, 1, "echo", b"held")
        assert held.read() == b"held"
        time.sleep(1.5)  # quiet, with a call under way: the link asks after the other end
        pause(relay.p, 2)
        assert ca.call(device, 1, "echo", b"still", timeout=20)["data"] == [b"still"]
        ca.drain(0.2)
        assert held["fault"] is None, f"the call under way was lost: {held['fault']}"
        held.end()
    finally:
        stop.set()
        t.join()


def pause(p, seconds):
    """Stops a process for a while, as a busy machine may, and lets it go on."""
    if os.name == "nt":
        import ctypes

        kernel, nt = ctypes.windll.kernel32, ctypes.windll.ntdll
        kernel.OpenProcess.restype = ctypes.c_void_p
        nt.NtSuspendProcess.argtypes = nt.NtResumeProcess.argtypes = kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        handle = kernel.OpenProcess(0x0800, False, p.pid)  # PROCESS_SUSPEND_RESUME
        assert handle, "cannot stop it"
        nt.NtSuspendProcess(handle)
        try:
            time.sleep(seconds)
        finally:
            nt.NtResumeProcess(handle)
            kernel.CloseHandle(handle)
    else:
        os.kill(p.pid, signal.SIGSTOP)
        try:
            time.sleep(seconds)
        finally:
            os.kill(p.pid, signal.SIGCONT)


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
        # Out at once, said and done: a test's servers run in threads that may yet be writing (a reset peer's
        # traceback, say), and an interpreter shutting down under them can fail for that alone.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)
    os.rmdir(TMP)
    runs = [subprocess.Popen([sys.executable, file, n], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) for n in names]
    for r in runs:
        sys.stdout.write(r.communicate()[0])
    sys.exit(any(r.returncode for r in runs))


if __name__ == "__main__":
    main()
