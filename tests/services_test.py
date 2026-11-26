"""What devices share of themselves, between real devices through a relay: files, commands, terminals and ports, each
bounded by what its reader has taken. Run by `./x test`, after end_to_end.py, whose devices these are."""

import base64, hashlib, json, os, socket, subprocess, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import end_to_end
from end_to_end import ROOT, TMP, procs, space, zspd, zsp

WINDOWS = os.name == "nt"


def pair(names):
    """A relay and two devices, a and b, in scope 1. a may use the shells and files devices share there; b shares, by
    its own client, a shell, a folder to read and write, and another only to read."""
    relay, (a, b) = space(*names)
    zspd("admit", a.dir, zspd("key", a.dir), "1", "shell", "files")
    ca, cb = a.client(), b.client()
    docs, pub = os.path.join(TMP, names[1] + "-docs"), os.path.join(TMP, names[1] + "-pub")
    os.makedirs(docs)
    os.makedirs(pub)
    cb.set_shares(f"shell 1\nfiles 1 docs write {docs}\nfiles 1 pub read {pub}\n")
    ca.until(lambda: len(ca.devices) == 2)
    device = bytes.fromhex(b.key)
    # b hears of a's rights through the relay; until it has, a may use nothing there.
    said("b lets a use what it shares", lambda: len(ca.services(device, 1)) == 3)
    return a, b, ca, cb, device, docs, pub


def said(what, f, timeout=15):
    """What f says, asked again until it says something true. A refusal meanwhile is as good as false."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            got = f()
            if got:
                return got
        except zsp.Refused:
            pass
        if time.monotonic() > deadline:
            raise AssertionError("never: " + what)
        time.sleep(0.1)


def refused(status, f):
    try:
        f()
    except zsp.Refused as e:
        assert e.status in ((status,) if isinstance(status, int) else status), e
        return e
    raise AssertionError("not refused")


def write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def ms(path):
    return os.stat(path).st_mtime_ns // 1_000_000


def tree(root):
    """Every file under a folder, by its path within it, with what is in it."""
    out = {}
    for at, _, names in os.walk(root):
        for name in names:
            path = os.path.join(at, name)
            out[os.path.relpath(path, root).replace(os.sep, "/")] = read(path)
    return out


def rss(pid):
    """What a process has in memory, in bytes, as the system says; None where that is not known."""
    try:
        if WINDOWS:
            line = subprocess.run(["tasklist", "/fi", f"PID eq {pid}", "/fo", "csv", "/nh"], capture_output=True, text=True).stdout
            return int("".join(c for c in line.strip().split('","')[-1] if c.isdigit())) * 1024
        return int(subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout) * 1024
    except (OSError, ValueError, IndexError):
        return None


def grown(before, after):
    return 0 if before is None or after is None else after - before


def shell(posix, windows):
    return ["cmd", "/c", windows] if WINDOWS else ["sh", "-c", posix]


def text(b):
    return b.replace(b"\r\n", b"\n").decode()


def test_vectors():
    """The bytes these encoders make, and the hashes of files, are those vectors/vectors.json pins."""
    with open(os.path.join(ROOT, "vectors", "vectors.json")) as f:
        v = json.load(f)
    for case in v["files"]:
        data = bytes((i * 7 + i // 251) & 255 for i in range(case["size"]))
        chunks, whole = zsp.file_hashes(data)
        assert [c.hex() for c in chunks] == case["chunks"] and whole.hex() == case["file"], case["size"]
    m = {x["message"]: bytes.fromhex(x["bytes"]) for x in v["services"]}
    assert zsp.first_tcp(22, "127.0.0.1") == m["zsp.tcp to port 22 of 127.0.0.1"]
    assert zsp.first_exec(["ls", "-l", "/tmp"], ["LANG=C", "HOME"], "/srv") == m["zsp.exec ls -l /tmp, LANG=C and without HOME, in /srv"]
    assert zsp.first_pty(24, 80, "xterm-256color", ["COLORTERM=truecolor"]) == m["zsp.pty 24 rows by 80, xterm-256color, the user's shell, COLORTERM=truecolor"]
    assert zsp.first_get("docs/report.pdf", 3 << 20, b"\xaa\xbb\xcc") == m["zsp.get docs/report.pdf from 3 MiB, as it was"]
    put = zsp.first_put("docs/new/report.pdf", 2621440, 1700000000123, b"\1\2\3\4", replace=True, folders=True)
    assert put == m["zsp.put docs/new/report.pdf of 2.5 MiB, replacing, making folders"]
    assert zsp.first_list("docs/sub") == m["zsp.list docs/sub"]
    assert zsp.entries_of(m["an entry: a.txt, 1234 bytes"]) == [(zsp.FILE, "a.txt", 1234, 1700000000000)]
    status, body = zsp.status_of(m["zsp.services: terminals and commands, docs to read and write, port 22 as ssh"])
    assert status == zsp.OK and zsp.services_of(body) == [
        dict(kind="shell", terminal=True, commands=True),
        dict(kind="files", read=True, write=True, name="docs"),
        dict(kind="tcp", port=22, host="", name="ssh"),
    ]
    assert zsp.status_of(m["status: ok"]) == (zsp.OK, b"")
    assert zsp.status_of(m["status: denied, with a reason"]) == (zsp.DENIED, b"not shared with you")
    status, body = zsp.status_of(m["zsp.get answered: 2.5 MiB, from 1 MiB"])
    assert status == zsp.OK and zsp.get_answer(body) == (2621440, 1700000000123, b"\xaa\xbb\xcc", 1 << 20)
    status, body = zsp.status_of(m["zsp.put answered: from 2 MiB"])
    assert status == zsp.OK and zsp.put_answer(body) == 2 << 20
    assert zsp.input_message(b"ls\n") == m["input: ls"]
    assert zsp.signal_message(zsp.INTERRUPT) == m["signal: interrupt"]
    assert zsp.resize_message(50, 132) == m["resize: 50 rows by 132"]
    assert zsp.from_process(m["output: hi"]) == (zsp.OUTPUT, b"hi")
    assert zsp.from_process(m["errors: no"]) == (zsp.ERRORS, b"no")
    assert zsp.from_process(m["exited 1"]) == (zsp.EXITED, (1, 0))
    assert zsp.from_process(m["killed by 9"]) == (zsp.EXITED, (0, 9))
    password = hashlib.sha256(b"password").digest()
    assert zsp.hash_message(password) == m["a chunk's hash follows its bytes"]
    assert zsp.done_message(zsp.OK, password) == m["the end of a file sent whole, with its hash"]


def test_services():
    """What a device offers is listed as far as the caller's rights let it use it, and whatever a change of shares no
    longer allows is ended at once."""
    a, b, ca, cb, device, docs, pub = pair(("sa", "sb"))
    shell_offer = dict(kind="shell", terminal=True, commands=True)
    offers = [shell_offer, dict(kind="files", read=True, write=True, name="docs"), dict(kind="files", read=True, write=False, name="pub")]
    assert ca.services(device, 1) == offers
    assert cb.services(device, 1) == offers  # its own device, to its own client
    assert cb.shares() == f"shell 1 terminal commands\nfiles 1 docs write {docs}\nfiles 1 pub read {pub}\n"
    refused(zsp.MALFORMED, lambda: cb.set_shares("files 1 ../nonsense read /"))
    assert len(cb.shares().splitlines()) == 3, "and what was there stays"

    # In a scope where a may call b but use nothing it shares, nothing is listed, and nothing may be used.
    two = zspd("scope", a.dir)
    zspd("admit", a.dir, zspd("key", b.dir), two)
    other = os.path.join(TMP, "sb-other")
    os.makedirs(other)
    write(os.path.join(other, "note.txt"), b"in scope two")
    cb.set_shares(cb.shares() + f"shell {two} commands\nfiles {two} other read {other}\n")
    said("b hears of scope two", lambda: ca.services(device, int(two)) == [])
    refused(zsp.DENIED, lambda: ca.get(device, int(two), "other/note.txt", os.path.join(TMP, "note.txt")))
    refused(zsp.DENIED, lambda: ca.list(device, int(two), "other"))
    # With Files and not Shell, its files and not its commands.
    zspd("admit", a.dir, zspd("key", a.dir), two, "files")
    said("b hears that a may use files there", lambda: ca.services(device, int(two)) == [dict(kind="files", read=True, write=False, name="other")])
    ca.get(device, int(two), "other/note.txt", os.path.join(TMP, "note.txt"))
    assert read(os.path.join(TMP, "note.txt")) == b"in scope two"
    refused(zsp.DENIED, lambda: ca.exec(device, int(two), shell("true", "exit 0")))
    refused(zsp.DENIED, lambda: ca.terminal(device, int(two), 24, 80))  # only commands are shared there

    # A fetch under way, from a share that is then taken away, is ended there and then.
    write(os.path.join(docs, "big.bin"), os.urandom(4 << 20))
    fetch = ca.open(device, 1, "zsp.get", zsp.first_get("docs/big.bin"))
    ca.until(lambda: fetch["data"])
    cb.set_shares(f"shell 1\nfiles 1 pub read {pub}\n")
    ca.until(lambda: fetch["fault"] is not None)
    assert fetch["fault"] == 1, fetch["fault"]  # denied
    assert ca.services(device, 1) == [shell_offer, offers[2]]


def test_files():
    """Files both ways, any size and checked end to end, folders and all; and nothing outside a share."""
    a, b, ca, cb, device, docs, pub = pair(("fa", "fb"))
    here = os.path.join(TMP, "here")
    os.makedirs(here)
    big, data = os.path.join(here, "big.bin"), os.urandom(20 << 20)
    write(big, data)
    whole = zsp.file_hashes(data)[1]
    start = time.monotonic()
    sent = ca.put(device, 1, big, "docs/in/big.bin")  # its folder made on the way
    took = time.monotonic() - start
    there = os.path.join(docs, "in", "big.bin")
    assert sent == dict(size=len(data), bytes=len(data), resumed=0, hash=whole), sent
    assert read(there) == data and ms(there) == ms(big)
    start = time.monotonic()
    back = os.path.join(here, "back.bin")
    got = ca.get(device, 1, "docs/in/big.bin", back)
    print(f"     20 MB through a relay: sent in {took:.2f}s, fetched in {time.monotonic() - start:.2f}s")
    assert got == sent and read(back) == data and ms(back) == ms(there)
    assert not os.path.exists(back + zsp.PART) and not os.path.exists(back + zsp.PART + ".meta")

    # What is there is not replaced unless that is asked for.
    small = os.path.join(here, "small.txt")
    write(small, b"smaller")
    refused(zsp.EXISTS, lambda: ca.put(device, 1, small, "docs/in/big.bin"))
    assert read(there) == data
    ca.put(device, 1, small, "docs/in/big.bin", replace=True)
    assert read(there) == b"smaller"
    refused(zsp.NOT_FOUND, lambda: ca.put(device, 1, small, "docs/nowhere/small.txt", folders=False))

    # Listings: the shares of files, and what is in a folder.
    assert ca.list(device, 1, "") == [(zsp.FOLDER, "docs", 0, 0), (zsp.FOLDER, "pub", 0, 0)]
    assert ca.list(device, 1, "docs/in") == [(zsp.FILE, "big.bin", 7, ms(there))]
    assert [entry[:2] for entry in ca.list(device, 1, "docs")] == [(zsp.FOLDER, "in")]

    # A tree of folders, there and back, with files empty, of a chunk, and just over.
    source = os.path.join(here, "tree")
    files = {
        "a.txt": b"top",
        "empty.bin": b"",
        "one/chunk.bin": os.urandom(zsp.CHUNK),
        "one/two/more.bin": os.urandom(zsp.CHUNK + 1),
        "one/two/deep/three/x.txt": b"deep down",
        "other/y.txt": b"beside",
    }
    for name, content in files.items():
        os.makedirs(os.path.dirname(os.path.join(source, name)), exist_ok=True)
        write(os.path.join(source, name), content)
    assert ca.put_tree(device, 1, source, "docs/tree") == (len(files), sum(map(len, files.values())))
    assert tree(os.path.join(docs, "tree")) == files
    assert ca.get_tree(device, 1, "docs/tree", os.path.join(here, "tree-back")) == (len(files), sum(map(len, files.values())))
    assert tree(os.path.join(here, "tree-back")) == files

    # Nothing outside a share, nothing in one that is not there, and nothing written to one that is only read.
    for path in ("docs/..", "docs/in/../../escape", "docs/./in/big.bin", "docs/in/big.bin.zsp-part"):
        refused(zsp.DENIED, lambda: ca.get(device, 1, path, os.path.join(here, "escaped")))
    refused(zsp.DENIED, lambda: ca.list(device, 1, "docs/.."))
    refused(zsp.DENIED, lambda: ca.put(device, 1, small, "docs/../escape.txt"))
    assert not os.path.exists(os.path.join(TMP, "escape.txt")) and not os.path.exists(os.path.join(here, "escaped"))
    refused(zsp.NOT_OFFERED, lambda: ca.get(device, 1, "nothere/x", os.path.join(here, "x")))
    refused(zsp.NOT_OFFERED, lambda: ca.list(device, 1, "nothere"))
    refused(zsp.NOT_FOUND, lambda: ca.get(device, 1, "docs/missing.bin", os.path.join(here, "missing.bin")))
    refused(zsp.DENIED, lambda: ca.put(device, 1, small, "pub/small.txt"))
    assert os.listdir(pub) == []


CHILD = r"""
import os, sys, time
root, address, token, device, remote, local, stall = sys.argv[1:]
sys.path.insert(0, os.path.join(root, "clients", "python"))
import zsp

def stalled(at, size):
    if at >= int(stall):
        print("stalled at", at, flush=True)
        time.sleep(600)

zsp.Client(address, token.encode()).get(bytes.fromhex(device), 1, remote, local, progress=stalled)
"""


def fetch_until_killed(a, b, remote, local, stall):
    """A client of a's fetches a file of b's, and is killed when it has some of it."""
    with open(os.path.join(a.dir, "token")) as f:
        token = f.read()
    child = subprocess.Popen([sys.executable, "-c", CHILD, ROOT, a.address, token, b.key, remote, local, str(stall)], stdout=subprocess.PIPE, text=True)
    procs.append(child)
    line = child.stdout.readline()
    child.kill()
    child.wait()
    assert line.startswith("stalled at"), line


def test_resume():
    """A fetch whose client is killed takes up, next time, from the part it left, if the file there is the one it was;
    and the part is as host/transfer.odin keeps one, so that either may take up the other's."""
    a, b, ca, cb, device, docs, pub = pair(("ra", "rb"))
    data = os.urandom(20 << 20)
    write(os.path.join(docs, "big.bin"), data)
    here = os.path.join(TMP, "fetched")
    os.makedirs(here)
    local = os.path.join(here, "big.bin")
    fetch_until_killed(a, b, "docs/big.bin", local, 8 << 20)
    part, meta = local + zsp.PART, local + zsp.PART + ".meta"
    # Which file it is there, then the hash of each chunk taken and checked.
    kept = read(meta)
    r = zsp.Reader(kept)
    identity = bytes(r.bytes())
    hashes = kept[r.pos :]
    chunks = len(hashes) // 32
    assert identity and len(hashes) % 32 == 0 and chunks >= 7, (len(identity), len(hashes))
    assert os.path.getsize(part) >= chunks * zsp.CHUNK
    assert all(hashes[i * 32 : i * 32 + 32] == hashlib.sha256(data[i * zsp.CHUNK : (i + 1) * zsp.CHUNK]).digest() for i in range(chunks))
    got = ca.get(device, 1, "docs/big.bin", local)
    assert got["resumed"] == chunks * zsp.CHUNK and got["bytes"] == len(data) - got["resumed"] < len(data), got
    assert got["hash"] == zsp.file_hashes(data)[1] and read(local) == data
    assert not os.path.exists(part) and not os.path.exists(meta)

    # A part of a file that has changed since is not taken up from: it all comes again.
    first = os.urandom(6 << 20)
    write(os.path.join(docs, "changing.bin"), first)
    local = os.path.join(here, "changing.bin")
    fetch_until_killed(a, b, "docs/changing.bin", local, 3 << 20)
    assert os.path.getsize(local + zsp.PART) >= 2 * zsp.CHUNK
    second = os.urandom(6 << 20)
    write(os.path.join(docs, "changing.bin"), second)
    later = time.time() + 10
    os.utime(os.path.join(docs, "changing.bin"), (later, later))
    got = ca.get(device, 1, "docs/changing.bin", local)
    assert got["resumed"] == 0 and got["bytes"] == len(second) and read(local) == second, got
    # And a part whose chunks are no longer what was recorded is taken up only from before the first that is not.
    fetch_until_killed(a, b, "docs/big.bin", os.path.join(here, "again.bin"), 6 << 20)
    with open(os.path.join(here, "again.bin") + zsp.PART, "r+b") as f:
        f.seek(2 * zsp.CHUNK + 5)
        f.write(b"garbled")
    got = ca.get(device, 1, "docs/big.bin", os.path.join(here, "again.bin"))
    assert got["resumed"] == 2 * zsp.CHUNK and read(os.path.join(here, "again.bin")) == data, got


def test_unread_fetch():
    """A fetch nobody reads holds no more here than its window, and nothing piles up anywhere between."""
    a, b, ca, cb, device, docs, pub = pair(("ua", "ub"))
    data = os.urandom(20 << 20)
    write(os.path.join(docs, "big.bin"), data)
    before = [rss(n.p.pid) for n in (a, b)]
    fetch = ca.open(device, 1, "zsp.get", zsp.first_get("docs/big.bin"))
    ca.drain(3)  # everything that comes is taken in, and nothing of it is read
    held = fetch.held()
    after = [rss(n.p.pid) for n in (a, b)]
    print(f"     a fetch nobody reads: {held} bytes held here, in a window of {fetch.window}; the devices grew by "
          f"{grown(before[0], after[0]) >> 10} and {grown(before[1], after[1]) >> 10} KiB")
    assert fetch.window == zsp.CALL_WINDOW and zsp.CALL_WINDOW // 2 < held <= zsp.CALL_WINDOW, held
    assert all(grown(x, y) < 8 << 20 for x, y in zip(before, after)), (before, after)
    # Read, it all comes, and is what it should be.
    status, body = zsp.status_of(fetch.read())
    assert status == zsp.OK and zsp.get_answer(body)[0] == len(data)
    hashing, last = zsp.Hashing(), None
    while True:
        message = fetch.read(30)
        if message is None:
            break
        if message[0] == zsp.CHUNK_BYTES:
            hashing.feed(message[1:])
        elif message[0] == zsp.CHUNK_HASH:
            assert message[1:] == hashing.end_chunk()
        last = message
    assert last == zsp.done_message(zsp.OK, zsp.file_hashes(data)[1]) and hashing.file.digest() == zsp.file_hashes(data)[1]


PRODUCER = r"""
import sys
total, record = int(sys.argv[1]), sys.argv[2]
block, sent = b"x" * 65536, 0
while sent < total:
    sys.stdout.buffer.write(block)
    sys.stdout.buffer.flush()
    sent += len(block)
    with open(record, "w") as f:
        f.write(str(sent))
"""


def test_unread_output():
    """A process whose output nobody reads waits at its own pipe, there, with no more than a window of it held here."""
    a, b, ca, cb, device, docs, pub = pair(("oa", "ob"))
    total, record = 32 << 20, os.path.join(TMP, "produced")
    before = [rss(n.p.pid) for n in (a, b)]
    p = ca.exec(device, 1, [sys.executable, "-c", PRODUCER, str(total), record])
    ca.drain(3)
    held, produced = p.call.held(), int(read(record) or b"0")
    after = [rss(n.p.pid) for n in (a, b)]
    print(f"     output nobody reads: {held} bytes held here, {produced} written of {total}; the devices grew by "
          f"{grown(before[0], after[0]) >> 10} and {grown(before[1], after[1]) >> 10} KiB")
    assert zsp.CALL_WINDOW // 2 < held <= p.call.window == zsp.CALL_WINDOW, held
    assert produced < 2 << 20, produced
    assert all(grown(x, y) < 8 << 20 for x, y in zip(before, after)), (before, after)
    # Read, it goes on, and all of it comes.
    got = 0
    while True:
        said_next = p.read(30)
        if said_next is None:
            break
        got += len(said_next[1])
        p.output.clear()
    assert got == total and p.exit == (0, 0), (got, p.exit)


BEATING = r"""
import subprocess, sys, time
beat = sys.argv[1]
subprocess.Popen([sys.executable, "-c", "import sys, time\nwhile True:\n    open(sys.argv[1], 'a').write('.')\n    time.sleep(0.05)", beat + ".child"])
while True:
    open(beat, "a").write(".")
    time.sleep(0.05)
"""


def test_exec():
    """Commands: their exit, their output and errors apart, their input as they take it, signals, and a kill that
    reaches all they started."""
    a, b, ca, cb, device, docs, pub = pair(("ea", "eb"))
    assert ca.run(device, 1, shell("exit 3", "exit 3")) == (3, 0, b"", b"")
    code, sig, out, err = ca.run(device, 1, shell("echo out; echo err >&2", "echo out& echo err>&2"))
    assert (code, sig, text(out).strip(), text(err).strip()) == (0, 0, "out", "err"), (code, sig, out, err)
    code, _, out, _ = ca.run(device, 1, shell('echo "$ZSP_GREETING"; pwd', "echo %ZSP_GREETING%& cd"), env=["ZSP_GREETING=hello"], cwd=docs)
    greeting, where = text(out).strip().splitlines()
    assert code == 0 and greeting == "hello" and os.path.samefile(where, docs), out
    refused((zsp.NOT_FOUND, zsp.FAILED), lambda: ca.exec(device, 1, ["zsp-no-such-program"]))

    # Input, more than a window of it, to cat, which gives it back: each way only as the other takes it.
    lines = b"".join(b"line %d of what goes in\n" % i for i in range(20000))
    code, _, out, err = ca.run(device, 1, ["findstr", "^"] if WINDOWS else ["cat"], input=lines)
    assert code == 0 and text(out) == lines.decode() and err == b"", (code, len(out), err)
    p = ca.exec(device, 1, ["findstr", "^"] if WINDOWS else ["cat"])
    p.write(b"one\n")
    p.write(b"two\n")
    p.close_stdin()
    assert p.wait() == (0, 0) and text(p.output) == "one\ntwo\n", (p.exit, p.output)

    # A signal, to a command that would otherwise go on.
    p = ca.exec(device, 1, shell("sleep 30", "ping -n 30 127.0.0.1 >nul"))
    time.sleep(0.3)
    p.signal(zsp.TERMINATE)
    exit = p.wait(10)
    assert exit is not None and (WINDOWS or exit[1] == zsp.TERMINATE), exit

    # Killed, with what it started.
    beat = os.path.join(TMP, "beat")
    p = ca.exec(device, 1, [sys.executable, "-c", BEATING, beat])
    end_to_end.eventually("it and its child beat", lambda: os.path.exists(beat) and os.path.exists(beat + ".child"))
    p.kill()
    time.sleep(1)
    sizes = [os.path.getsize(f) for f in (beat, beat + ".child")]
    time.sleep(0.5)
    assert [os.path.getsize(f) for f in (beat, beat + ".child")] == sizes, "still beating"


def size_probe():
    """What, typed, says how big the terminal is: rows, a space, columns."""
    if not WINDOWS:
        return b"stty size\r"
    script = "$s = $Host.UI.RawUI.WindowSize; Write-Output ('{0} {1}' -f $s.Height, $s.Width)"
    return b"powershell -NoProfile -EncodedCommand " + base64.b64encode(script.encode("utf-16-le")) + b"\r"


def shows(t, what, since, timeout=10):
    deadline = time.monotonic() + timeout
    while what not in t.output[since:]:
        if t.read(max(deadline - time.monotonic(), 0.001)) is None:
            raise AssertionError(f"the terminal ended without showing {what!r}: {bytes(t.output)!r}")


def test_terminal():
    """A shell with a terminal of its own, of the size asked for, and then of another."""
    a, b, ca, cb, device, docs, pub = pair(("pa", "pb"))
    t = ca.terminal(device, 1, 24, 80)
    t.write(size_probe())
    shows(t, b"24 80", 0)
    since = len(t.output)
    t.resize(50, 132)
    t.write(size_probe())
    shows(t, b"50 132", since)
    t.write(b"exit\r")
    exit = t.wait(10)
    assert exit is not None and exit[0] == 0, exit
    # One that is closed is hung up on, and gone: on Windows, where nothing hangs up, killed.
    t = ca.terminal(device, 1, 24, 80)
    exit = t.close()
    assert (exit is not None or t.call["fault"] == 0) and (WINDOWS or exit is not None and exit[1] == zsp.HANGUP), exit


def test_connect():
    """zsp.tcp reaches only the ports a device's host permits, and zspd permits none (its policy for ports is
    another's to build): so a connection is refused, and said to be, and nothing is dialled."""
    a, b, ca, cb, device, docs, pub = pair(("ta", "tb"))
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    port = listener.getsockname()[1]
    refused((zsp.DENIED, zsp.NOT_OFFERED), lambda: ca.connect(device, 1, port))
    listener.settimeout(0.5)
    try:
        listener.accept()
        raise AssertionError("dialled")
    except socket.timeout:
        pass
    assert not [s for s in ca.services(device, 1) if s["kind"] == "tcp"]


def test_put_takes_no_early_verdict():
    """A put is done only when all of it has gone and the receiver says so after: an Ok before then is no success."""
    path = os.path.join(TMP, "ev-big.bin")
    with open(path, "wb") as f:
        f.write(b"A" * (512 * 1024))
    t = zsp.Transfer(True, path, "docs/big.bin")
    t.first_put(True, True)
    t.on_data(b"\x00\x00")  # taken, from the start
    t.on_data(b"\x00")  # and done, though nothing has gone
    assert t.finished and t.status != zsp.OK, (t.status, t.bytes)
    t.f.close()


def test_tree_not_without_end():
    """A device whose every folder holds another is fetched from only so deep, and nothing it names leads elsewhere."""

    class Lying(zsp.Client):
        def __init__(self, name):
            self.calls, self.name = 0, name

        def list_files(self, device, scope, path, timeout=10):
            self.calls += 1
            return [(zsp.FOLDER, self.name, 0, 0)]

    for name in ("a", "c:x"):
        c = Lying(name)
        out = os.path.join(TMP, "tw-" + str(len(name)))
        try:
            c.get_tree(b"\x00" * 32, 1, "share", out)
            raise AssertionError("it went on for ever")
        except zsp.Refused as e:
            assert e.status == zsp.MALFORMED and c.calls <= 65, (name, e.status, c.calls)


def test_resume_from_a_cut_record():
    """A record of a fetch's progress cut short since it was read is not taken up from."""
    local = os.path.join(TMP, "cr-f.bin")
    chunk0 = b"X" * zsp.CHUNK
    with open(local + zsp.PART, "wb") as f:
        f.write(chunk0)
    with open(local + zsp.PART + ".meta", "wb") as f:
        f.write(zsp.put_bytes(b"id1") + hashlib.sha256(chunk0).digest())
    t = zsp.Transfer(False, local, "docs/f.bin")
    t.first_get()
    assert t.start == zsp.CHUNK
    with open(local + zsp.PART + ".meta", "wb") as f:
        f.write(zsp.put_bytes(b"id1"))  # cut short, since
    assert not t.open_part(b"id1", zsp.CHUNK)
    for f in (t.f, t.meta):
        if f:
            f.close()


if __name__ == "__main__":
    end_to_end.main(globals(), __file__)
