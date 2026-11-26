"""zspd's commands for what devices share, as whoever types them would use them: share and services, ls, get and put,
connect, exec and terminal, between real devices through a real relay. Run by `./x test`, after end_to_end."""

import hashlib, os, re, signal, socket, subprocess, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import end_to_end as e2e
from end_to_end import BIN, TMP, eventually, space, zspd

MiB = 1 << 20


def cli(*args, input=b"", timeout=60):
    """A command run to its end: its exit code, and what it said on each of its outputs."""
    p = subprocess.run([BIN, *args], input=input, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def ok(*args, input=b""):
    code, out, err = cli(*args, input=input)
    assert code == 0, f"zspd {args}: {code} {err.decode(errors='replace')}"
    return out.decode()


def roster(d, a):
    with open(os.path.join(d.dir, e2e.zspd_space(a), "roster"), "rb") as f:
        return f.read()


def shared(name, *shares):
    """Devices a and b; b, known to the roster as `<name>-b`, shares as told, and a may use what is shared in scope 1."""
    relay, (a, b) = space(name + "a", name + "b")
    zspd("admit", a.dir, zspd("key", a.dir), "1", "shell", "files")
    zspd("subject", a.dir, zspd("key", b.dir), name + "-b")
    eventually("b hears of it", lambda: roster(b, a) == roster(a, a))
    zspd("share", b.dir, *shares)
    return a, b


def folder(path, files):
    for rel, data in files.items():
        os.makedirs(os.path.dirname(os.path.join(path, rel)), exist_ok=True)
        with open(os.path.join(path, rel), "wb") as f:
            f.write(data)
    return path


def tree(path):
    """Every file under a folder: its path within it, and what is in it."""
    out = {}
    for root, _, names in os.walk(path):
        for n in names:
            with open(os.path.join(root, n), "rb") as f:
                out[os.path.relpath(os.path.join(root, n), path).replace(os.sep, "/")] = f.read()
    return out


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(MiB), b""):
            h.update(block)
    return h.digest()


def test_services():
    docs, drop = os.path.join(TMP, "sv-docs"), os.path.join(TMP, "sv-drop")
    os.makedirs(docs), os.makedirs(drop)
    a, b = shared("sv", "shell 1", f"files 1 docs read {docs}", f"files 1 drop write {drop}")
    # The shares as the device keeps them, and as another device is offered them: by whose it is, or by its key.
    assert ok("share", b.dir) == f"shell 1 terminal commands\nfiles 1 docs read {docs}\nfiles 1 drop write {drop}\n"
    offered = "shell terminal commands\nfiles docs read\nfiles drop write\n"
    assert ok("services", a.dir, "sv-b") == offered
    assert ok("services", a.dir, b.key[:10]) == offered
    assert ok("services", a.dir, zspd("key", b.dir)) == offered
    # A device that is nobody's, or more than one, is not guessed at.
    code, _, err = cli("services", a.dir, "nobody")
    assert code == 1 and b"no device" in err, err
    code, _, err = cli("services", a.dir, "")
    assert code == 1, err
    # What makes no sense is refused, and the shares stay as they were; nothing at all can be shared too.
    code, _, err = cli("share", b.dir, "files 1 ../up read /")
    assert code == 1 and b"not understood" in err, err
    assert ok("services", a.dir, "sv-b") == offered
    assert ok("share", b.dir, "") == ""
    assert ok("share", b.dir) == "" and ok("services", a.dir, "sv-b") == ""
    # Without its own node running, nothing is said. (What it left behind says where it was, where another may be now:
    # that one says nothing either.)
    b.stop()
    code, out, err = cli("share", b.dir)
    assert code == 1 and out == b"" and err, (out, err)


def test_files():
    docs, drop = os.path.join(TMP, "fl-docs"), os.path.join(TMP, "fl-drop")
    big = os.urandom(20 * MiB + 12345)
    folder(docs, {"big.bin": big, "tree/a.txt": b"alpha\n", "tree/sub/b.bin": os.urandom(3 * MiB), "tree/sub/empty": b""})
    os.makedirs(drop)
    secret = os.path.join(TMP, "fl-secret")
    folder(secret, {"key": b"not for anyone"})
    os.symlink(os.path.join(secret, "key"), os.path.join(docs, "away"))
    a, b = shared("fl", f"files 1 docs read {docs}", f"files 1 drop write {drop}")
    here = os.path.join(TMP, "fl-here")
    os.makedirs(here)

    # Listed: the shares, a folder, a file.
    assert re.findall(r"(\S+)\n", ok("ls", a.dir, "fl-b")) == ["docs/", "drop/"]
    listing = ok("ls", a.dir, "fl-b", "docs")
    assert [l.split()[-1] for l in listing.splitlines()] == ["away", "big.bin", "tree/"], listing
    assert re.search(rf"^\s+{len(big)}\s+\d{{4}}-\d\d-\d\d \d\d:\d\d  big.bin$", listing, re.M), listing
    assert ok("ls", a.dir, "fl-b", "docs/big.bin").split()[-1] == "big.bin"

    # A big file, then a folder, fetched; and again, which fetches nothing.
    out = ok("get", a.dir, "fl-b", "docs/big.bin", here + "/")
    assert f"{len(big)} bytes" in out and digest(os.path.join(here, "big.bin")) == hashlib.sha256(big).digest(), out
    # The sender's time to the ms, as it is sent: compared in whole ns, as floats of seconds may differ in their last bit.
    assert os.stat(os.path.join(here, "big.bin")).st_mtime_ns == os.stat(os.path.join(docs, "big.bin")).st_mtime_ns // 1_000_000 * 1_000_000
    ok("get", a.dir, "fl-b", "docs/tree", os.path.join(here, "tree"))
    assert tree(os.path.join(here, "tree")) == tree(os.path.join(docs, "tree"))
    again = ok("get", a.dir, "fl-b", "docs/tree", os.path.join(here, "tree"))
    assert again.count("here already") == 3 and "bytes" not in again, again
    # A share is a folder like any other: all of it comes but the link that leads out of it, which is said.
    code, out, err = cli("get", a.dir, "fl-b", "docs", os.path.join(here, "all"))
    assert code == 1 and err.decode().endswith("away: denied\n"), (out, err)
    assert set(tree(os.path.join(here, "all"))) == {"big.bin", "tree/a.txt", "tree/sub/b.bin", "tree/sub/empty"}

    # Sent: a file, a folder; again, which sends nothing; over what is there only when told to.
    mine = folder(os.path.join(TMP, "fl-mine"), {"one.txt": b"one\n", "deep/two.bin": os.urandom(2 * MiB + 7)})
    out = ok("put", a.dir, "fl-b", os.path.join(here, "big.bin"), "drop/")
    assert digest(os.path.join(drop, "big.bin")) == hashlib.sha256(big).digest(), out
    ok("put", a.dir, "fl-b", mine, "drop/mine")
    assert tree(os.path.join(drop, "mine")) == tree(mine)
    assert ok("put", a.dir, "fl-b", mine, "drop/mine").count("there already") == 2
    with open(os.path.join(mine, "one.txt"), "wb") as f:
        f.write(b"changed\n")
    code, out, err = cli("put", a.dir, "fl-b", mine, "drop/mine")
    assert code == 1 and b"--replace" in err and out.count(b"there already") == 1, (out, err)
    ok("put", a.dir, "fl-b", mine, "drop/mine", "--replace")
    assert tree(os.path.join(drop, "mine")) == tree(mine)
    # A file into a folder that is there, under its own name.
    ok("put", a.dir, "fl-b", os.path.join(mine, "one.txt"), "drop/mine/deep")
    assert open(os.path.join(drop, "mine", "deep", "one.txt"), "rb").read() == b"changed\n"

    # Denied: out of a share by '..' or by a link, into a share only to read, and what is not shared at all.
    for args, said in (
        (("ls", a.dir, "fl-b", "docs/.."), b"denied"),
        (("get", a.dir, "fl-b", "docs/../fl-secret/key", here + "/"), b"denied"),
        (("get", a.dir, "fl-b", "docs/away", here + "/"), b"denied"),
        (("put", a.dir, "fl-b", os.path.join(mine, "one.txt"), "docs/"), b"denied"),
        (("ls", a.dir, "fl-b", "secret"), b"not offered"),
        (("get", a.dir, "fl-b", "docs/nothing", here + "/"), b"not found"),
    ):
        code, out, err = cli(*args)
        assert code == 1 and said in err, (args, code, out, err)
    assert not os.path.exists(os.path.join(here, "key")) and not os.path.exists(os.path.join(here, "away"))
    assert not os.path.exists(os.path.join(docs, "one.txt"))
    # Nor by a device without the right, whatever is shared.
    zspd("admit", a.dir, zspd("key", a.dir), "1")
    eventually("b hears of it", lambda: roster(b, a) == roster(a, a))
    code, out, err = cli("ls", a.dir, "fl-b", "docs")
    assert code == 1 and b"denied" in err, (out, err)


def test_get_resumed():
    docs = os.path.join(TMP, "rs-docs")
    folder(docs, {"huge.bin": os.urandom(64 * MiB)})
    a, b = shared("rs", f"files 1 docs read {docs}")
    here = os.path.join(TMP, "rs-here")
    os.makedirs(here)
    target = os.path.join(here, "huge.bin")
    part = target + ".zsp-part"
    # Killed without a word, part of the way.
    p = subprocess.Popen([BIN, "get", a.dir, "rs-b", "docs/huge.bin", target], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    eventually("some of it comes", lambda: os.path.exists(part) and os.path.getsize(part) >= 3 * MiB, 30)
    p.kill()
    p.wait()
    had = os.path.getsize(part)
    assert not os.path.exists(target) and had < 64 * MiB, had
    # Begun again, it takes up where it stopped: only what had not come comes.
    out = ok("get", a.dir, "rs-b", "docs/huge.bin", target)
    carried, resumed = map(int, re.search(r"(\d+) bytes, taken up at (\d+)", out).groups())
    assert 0 < resumed <= had and carried == 64 * MiB - resumed, (had, out)
    assert carried < 64 * MiB and not os.path.exists(part)
    assert digest(target) == digest(os.path.join(docs, "huge.bin"))


def test_put_resumed():
    drop = os.path.join(TMP, "pr-drop")
    os.makedirs(drop)
    mine = folder(os.path.join(TMP, "pr-mine"), {"huge.bin": os.urandom(64 * MiB)})
    a, b = shared("pr", f"files 1 drop write {drop}")
    part = os.path.join(drop, "huge.bin.zsp-part")
    # Killed part of the way, what had come is kept there, and taken up from.
    p = subprocess.Popen([BIN, "put", a.dir, "pr-b", os.path.join(mine, "huge.bin"), "drop/"], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    eventually("some of it goes", lambda: os.path.exists(part) and os.path.getsize(part) >= 3 * MiB, 30)
    p.kill()
    p.wait()
    out = ok("put", a.dir, "pr-b", os.path.join(mine, "huge.bin"), "drop/")
    carried, resumed = map(int, re.search(r"(\d+) bytes, taken up at (\d+)", out).groups())
    assert resumed > 0 and carried == 64 * MiB - resumed, out
    assert digest(os.path.join(drop, "huge.bin")) == digest(os.path.join(mine, "huge.bin")) and not os.path.exists(part)


def test_connect():
    """zspd offers no ports: which may be reached, for whom, is a policy it does not have yet (Config.port_permitted),
    and without one every port is denied. So an echo there is asked for, and is refused, and nothing is read here."""
    echo = socket.socket()
    echo.bind(("127.0.0.1", 0))
    echo.listen()
    port = echo.getsockname()[1]
    accepted = []
    threading.Thread(target=lambda: accepted.append(echo.accept()), daemon=True).start()
    a, b = shared("cn", "shell 1")
    code, out, err = cli("connect", a.dir, "cn-b", str(port), input=b"hello\n")
    assert code == 1 and out == b"" and b"denied" in err, (code, out, err)
    time.sleep(0.2)
    assert not accepted
    code, _, _ = cli("connect", a.dir, "cn-b", "70000")
    assert code == 2


def test_exec():
    work = os.path.join(TMP, "ex-work")
    os.makedirs(work)
    a, b = shared("ex", "shell 1")
    # Its exit code is this one's; its output and errors stay apart.
    code, out, err = cli("exec", a.dir, "ex-b", "--", "sh", "-c", "exit 7")
    assert code == 7, (code, out, err)
    code, out, err = cli("exec", a.dir, "ex-b", "--", "sh", "-c", "echo out; echo err >&2; echo more")
    assert (code, out, err) == (0, b"out\nmore\n", b"err\n"), (code, out, err)
    # Input goes there as it is, all of it, and its end is the end of the command's.
    data = os.urandom(5 * MiB)
    code, out, err = cli("exec", a.dir, "ex-b", "cat", input=data)
    assert code == 0 and out == data, (code, len(out), err)
    # Where it begins, and what it has besides what the host has.
    code, out, err = cli("exec", a.dir, "ex-b", f"--cwd={work}", "--env=ZSP_SAID=yes", "--", "sh", "-c", 'pwd; echo "$ZSP_SAID"')
    assert out.decode().split() == [os.path.realpath(work), "yes"], (out, err)
    # A signal that ends it is said as 128 and its number.
    assert cli("exec", a.dir, "ex-b", "--", "sh", "-c", "kill -TERM $$")[0] == 128 + 15
    # And one sent here goes there.
    p = subprocess.Popen([BIN, "exec", a.dir, "ex-b", "--", "sh", "-c", "echo begun; exec sleep 30"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert p.stdout.readline() == b"begun\n"
    p.send_signal(signal.SIGINT)
    assert p.wait(10) == 128 + 2
    # Not shared, it does not run.
    zspd("share", b.dir, "shell 1 terminal")
    code, out, err = cli("exec", a.dir, "ex-b", "--", "true")
    assert code == 255 and b"denied" in err, (code, err)


def test_terminal():
    import fcntl, pty, select, struct, termios

    a, b = shared("tm", "shell 1")
    master, slave = os.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 90, 0, 0))
    before = termios.tcgetattr(slave)
    name = os.ttyname(slave)
    p = subprocess.Popen(
        [BIN, "terminal", a.dir, "tm-b"], stdin=slave, stdout=slave, stderr=slave, start_new_session=True,
        preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0),
    )
    seen = b""

    def until(pattern, timeout=15):
        nonlocal seen
        deadline = time.monotonic() + timeout
        while not re.search(pattern, seen):
            left = deadline - time.monotonic()
            assert left > 0 and p.poll() is None, (pattern, seen[-500:], p.poll())
            if select.select([master], [], [], left)[0]:
                seen += os.read(master, 65536)

    def type(text):
        nonlocal seen
        seen = b""
        os.write(master, text)

    try:
        # Raw here while it is used: no echo, no lines, no signals from keys.
        eventually("the terminal is raw", lambda: p.poll() is not None or not termios.tcgetattr(slave)[3] & termios.ICANON)
        raw = termios.tcgetattr(slave)
        assert not raw[3] & (termios.ICANON | termios.ECHO | termios.ISIG), (raw[3], p.poll(), os.read(master, 4096))
        type(b"echo zsp-$((6 * 7))\r")
        until(rb"zsp-42")
        # The size there is this one's, from the start and as it changes.
        type(b"stty size\r")
        until(rb"30 90")
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 100, 0, 0))
        # Asked until it says so, for the new size goes there beside what is typed, not before it.
        for _ in range(20):
            time.sleep(0.25)
            type(b"stty size\r")
            until(rb"\d+ \d+\r\n")
            if b"40 100" in seen:
                break
        assert b"40 100" in seen, seen[-300:]
        # Ctrl-C is a key there, and ends what runs there rather than this.
        type(b"sleep 30\r")
        time.sleep(0.5)
        type(b"\x03")
        type(b"echo after-$((1 + 1))\r")
        until(rb"after-2", 10)
        assert p.poll() is None
        # Its end is this one's, and the terminal is as it was.
        type(b"exit 3\r")
        # Read as a terminal does, for what is shown last may be more than a terminal holds unread (as on macOS).
        deadline = time.monotonic() + 10
        while p.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], 0.1)[0]:
                seen += os.read(master, 65536)
        assert p.poll() == 3, (p.poll(), seen[-300:])
        # Opened again by its name: macOS takes back what was open on a terminal whose session has ended.
        again = os.open(name, os.O_RDWR | os.O_NOCTTY)
        try:
            assert termios.tcgetattr(again) == before
        finally:
            os.close(again)
    finally:
        if p.poll() is None:
            p.kill()
        os.close(master), os.close(slave)


def test_get_takes_no_name_that_leads_out():
    """A device that lists a folder with names leading out of it, as one that means harm may, has nothing written
    anywhere but within the folder asked for: zspd get takes no such name. Played here by a node of this test's own."""
    import base64, struct

    def varint(n):
        out = bytearray()
        while n >= 0x80:
            out.append((n & 0x7F) | 0x80)
            n >>= 7
        out.append(n)
        return bytes(out)

    def read_varint(buf, pos):
        v = shift = 0
        while True:
            b = buf[pos]
            pos += 1
            v |= (b & 0x7F) << shift
            if not (b & 0x80):
                return v, pos
            shift += 7

    def frame(t, p):
        b = bytes([t]) + p
        return varint(len(b)) + b

    def ws_send(c, p):
        n = len(p)
        c.sendall((bytes([0x82, n]) if n < 126 else bytes([0x82, 126]) + struct.pack("!H", n)) + p)

    def ws_recv(c, raw):
        def exact(k):
            while len(raw) < k:
                d = c.recv(4096)
                if not d:
                    return None
                raw.extend(d)
            o = bytes(raw[:k])
            del raw[:k]
            return o

        h = exact(2)
        if not h:
            return None
        n = h[1] & 0x7F
        if n == 126:
            n = struct.unpack("!H", exact(2))[0]
        mask = exact(4) if (h[1] & 0x80) else b""
        data = bytearray(exact(n))
        for i in range(len(data) if mask else 0):
            data[i] ^= mask[i & 3]
        return bytes(data)

    node_dir = os.path.join(TMP, "lo-node")
    dest = os.path.join(TMP, "lo-work", "downloads")
    escaped = os.path.join(TMP, "lo-escaped.txt")
    os.makedirs(dest)
    zspd("create", node_dir)
    peer_hex = zspd("key", node_dir)[:64]
    peer = bytes.fromhex(peer_hex)
    payload = b"PWNED\n"
    chunk = hashlib.sha256(payload).digest()
    whole = hashlib.sha256(chunk).digest()
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    with open(os.path.join(node_dir, "address"), "w") as f:
        f.write("127.0.0.1:%d" % srv.getsockname()[1])
    with open(os.path.join(node_dir, "token"), "wb") as f:
        f.write(b"tok")

    def serve():
        conn, _ = srv.accept()
        req = b""
        while b"\r\n\r\n" not in req:
            req += conn.recv(4096)
        head, rest = req.split(b"\r\n\r\n", 1)
        raw = bytearray(rest)
        key = [l.split(":", 1)[1].strip() for l in head.decode().split("\r\n") if l.lower().startswith("sec-websocket-key:")][0]
        accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n".encode())
        ws_recv(conn, raw)
        ws_send(conn, frame(2, b"\x00" * 8 + varint(1) + b"\x7f" + b"\x00" * 32) + frame(12, peer + b"\x00"))
        buf = bytearray()
        while (msg := ws_recv(conn, raw)) is not None:
            buf.extend(msg)
            pos = 0
            while pos < len(buf):
                flen, p2 = read_varint(buf, pos)
                if p2 + flen > len(buf):
                    break
                f = bytes(buf[p2 : p2 + flen])
                pos = p2 + flen
                if f[0] == 15:
                    cid, q = read_varint(f, 1)
                    q += 32
                    _, q = read_varint(f, q)
                    mlen, q = read_varint(f, q)
                    method = f[q : q + mlen].decode()
                    tag = varint((cid << 1) | 1)
                    if method == "zsp.list":
                        nm = b"../../lo-escaped.txt"
                        ws_send(conn, frame(16, tag + b"\x00\x00\x01" + varint(len(nm)) + nm + varint(len(payload)) + b"\x00") + frame(16, tag + b"\x01"))
                    elif method == "zsp.get":
                        ws_send(
                            conn,
                            frame(16, tag + b"\x00\x00" + varint(len(payload)) + b"\x00\x01\x01\x00")
                            + frame(16, tag + b"\x00\x01" + payload)
                            + frame(16, tag + b"\x00\x02" + chunk)
                            + frame(16, tag + b"\x00\x03\x00" + whole)
                            + frame(16, tag + b"\x01"),
                        )
            del buf[:pos]
        conn.close()
        srv.close()

    t = threading.Thread(target=serve, daemon=True)
    t.start()
    code, out, err = cli("get", node_dir, peer_hex, "share", dest, timeout=10)
    t.join(timeout=2)
    assert not os.path.exists(escaped), (code, out, err)
    assert code == 1 and b"makes no sense" in err, (code, out, err)


if __name__ == "__main__":
    e2e.main(globals(), __file__)
