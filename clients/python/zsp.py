"""A Zeron State Protocol client in the Python standard library.

It shows how little of SPEC.md a client needs: frames, cells, and the merge rule. No cryptography, because a
client speaks to its own device's node; no storage, because the node is that. And what devices share of
themselves: files, commands, terminals and ports, as calls whose credit is given only as what comes is used.
"""

import base64, hashlib, os, socket, stat, struct, time

HELLO, ROSTER, WATCH, UNWATCH, RECON, WANT, CELLS, ACK, LIVE, SYNCED, SIGNAL, PRESENCE, ERROR, SERVE, CALL, FLOW, AUTHOR = range(1, 18)
GRAVE, PLACE, VALUE, PIECE, BUNDLE = range(1, 6)
READ, WRITE, MAY_CALL, VOUCH, MAY_SHELL, MAY_FILES, SAYS_WHOSE = 1, 2, 4, 8, 16, 32, 128
F_DATA, F_END, F_FAULT, F_CANCEL, F_CREDIT = range(5)
FAULTS = ("cancelled", "denied", "unreachable", "unserved", "lost", "overrun", "busy")
CALL_WINDOW = 256 << 10  # what a side may send beyond what the other has credited, and the most one message may be
WINDOW_MOST = 16 * CALL_WINDOW  # what a receiver may credit ahead
WINDOW_QUICK = 0.25  # a window used up within so many seconds grows
OK, DENIED, NOT_OFFERED, REFUSED, UNREACHABLE, TIMED_OUT, NOT_FOUND, FAILED, CHANGED, EXISTS, MALFORMED = range(11)
STATUSES = ("ok", "denied", "not offered", "refused", "unreachable", "timed out", "not found", "failed", "changed", "exists", "malformed")
INPUT, SIGNAL_TO, RESIZE = 0, 1, 2  # what a process is told
OUTPUT, ERRORS, EXITED = 1, 2, 3  # what it says
HANGUP, INTERRUPT, QUIT, KILL, TERMINATE, CONTINUE, STOP = 1, 2, 3, 9, 15, 18, 19
FILE, FOLDER, OTHER = 1, 2, 3
CHUNK_BYTES, CHUNK_HASH, FILE_DONE = 1, 2, 3
CHUNK = 1 << 20  # a file is hashed in chunks of this
FILE_READ = 64 << 10  # at most, in one message
PART = ".zsp-part"  # what a file being fetched is called until it is whole
DATA_WATCH, LIVE_WATCH, BACK, ADOPT, KNOWN = 1, 2, 4, 8, 16
KEY_MAX = b"\xff" * 40
ASK, UNASK, ANSWER, FETCH = 32, 33, 34, 35
BYTES, FOLD, NUMBER, BOOL, ID, WORDS, CREATED, MODIFIED, ORDER, OF = range(1, 11)
SUM, MIN, MAX, COUNT, FACET = range(1, 6)


def varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append(n & 0x7F | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


class Reader:
    def __init__(self, buf):
        self.buf, self.pos = buf, 0

    def take(self, n):
        if self.pos + n > len(self.buf):
            raise ValueError("short")
        self.pos += n
        return self.buf[self.pos - n : self.pos]

    def u8(self):
        return self.take(1)[0]

    def u16(self):
        return struct.unpack(">H", self.take(2))[0]

    def u64(self):
        return struct.unpack(">Q", self.take(8))[0]

    def varint(self):
        v = shift = 0
        while True:
            b = self.u8()
            v |= (b & 0x7F) << shift
            if b < 0x80:
                return v
            shift += 7

    def bytes(self):
        return self.take(self.varint())

    def key(self):
        n = self.u8()
        return KEY_MAX if n == 0xFF else self.take(n).ljust(40, b"\0")

    def done(self):
        return self.pos == len(self.buf)


def put_key(k):
    if k == KEY_MAX:
        return b"\xff"
    k = k.rstrip(b"\0")
    return bytes([len(k)]) + k


def frame(kind, body):
    return varint(len(body) + 1) + bytes([kind]) + body


def key_after(prefix):
    """The least 40-byte key greater than every key with this prefix."""
    n = int.from_bytes(prefix, "big") + 1
    return n.to_bytes(len(prefix), "big").ljust(40, b"\0")


# -- questions, as bytes: SPEC.md 15


def column(kind, slot=0, path="", tag=b""):
    if kind in (CREATED, MODIFIED):
        return bytes([kind])
    if kind == OF:
        return bytes([kind, slot])
    return bytes([kind]) + (tag if kind == ORDER else bytes([slot]) + put_bytes(path.encode()))


def put_bytes(b):
    return varint(len(b)) + b


def put_value(v):
    if isinstance(v, bool):
        v = b"\1" if v else b"\0"
    elif isinstance(v, (int, float)):
        v = struct.pack(">d", v)
    elif isinstance(v, str):
        v = v.encode()
    return put_bytes(v)


ALL = b"\0"


def every(*of):
    return b"\1" + varint(len(of)) + b"".join(of)


def some(*of):
    return b"\2" + varint(len(of)) + b"".join(of)


def no(of):
    return b"\3" + of


def between(col, lo=None, hi=None, lo_in=True, hi_in=True):
    flags = (lo is not None) | (hi is not None) << 1 | lo_in << 2 | hi_in << 3
    return b"\4" + col + bytes([flags]) + (put_value(lo) if lo is not None else b"") + (put_value(hi) if hi is not None else b"")


def equals(col, v):
    return between(col, v, v)


def among(col, *of):
    return b"\5" + col + varint(len(of)) + b"".join(map(put_value, of))


def begins(col, s):
    return b"\6" + col + put_bytes(s.encode())


def contains(col, s):
    return b"\7" + col + put_bytes(s.encode())


def exists(col):
    return b"\x08" + col


def in_list(tag):
    return b"\x09" + tag


def matches(col, text, mode=0, prefix=False, inside=False, edits=0):
    edits = max(0, min(int(edits), 3))  # a whole number of letters, three at most: no more bits than that
    return b"\x0a" + col + bytes([mode, prefix | inside << 1 | edits << 2]) + put_bytes(text.encode())


def rows(*ids):
    return b"\x0b" + varint(len(ids)) + b"".join(ids)


def refers(col, scope, where):
    return b"\x0c" + col + varint(scope) + where


def referred(col, scope, where, least=1, most=2**64 - 1):
    return b"\x0d" + col + varint(scope) + varint(least) + varint(most) + where


def by(col, desc=False):
    return b"\0" + bytes([desc]) + col


BEST, NEWEST, OLDEST = b"\1\0", b"\2\1", b"\2\0"


def question(scope, where=ALL, order=(NEWEST,), offset=0, limit=50, from_end=False, totals=()):
    out = varint(scope) + where + varint(len(order)) + b"".join(order) + bytes([from_end]) + varint(offset) + varint(limit)
    return out + varint(len(totals)) + b"".join(bytes([fn]) + col + varint(top) for fn, col, top in totals)


# -- streams and services, as bytes: SPEC.md 16


def put_text(s):
    return put_bytes(s.encode() if isinstance(s, str) else s)


def put_texts(items):
    return varint(len(items)) + b"".join(map(put_text, items))


def first_tcp(port, host=""):
    """The first message of zsp.tcp: a port there, or by default on its loopback."""
    return struct.pack(">H", port) + host.encode()


def first_exec(argv, env=(), cwd=""):
    """The first message of zsp.exec: the program's own arguments, never through a shell; environment entries
    NAME=value over the host's, NAME alone removing one; and where to start, or the user's home."""
    return b"\0" + put_texts(argv) + put_texts(env) + put_text(cwd)


def first_pty(rows, cols, term="xterm-256color", env=(), cwd=""):
    """The first message of zsp.pty: the user's shell, with a terminal of that size and kind."""
    return struct.pack(">HH", rows, cols) + put_text(term) + put_texts(()) + put_texts(env) + put_text(cwd)


def first_list(path):
    return put_text(path)


def first_get(path, offset=0, identity=b""):
    """The first message of zsp.get: from where a fetch broke off, if the file there is the one it was by identity."""
    return put_text(path) + varint(offset) + put_bytes(identity)


def first_put(path, size, modified, identity, replace=False, folders=True):
    return put_text(path) + varint(size) + varint(modified) + put_bytes(identity) + bytes([replace | folders << 1])


def input_message(data):
    return bytes([INPUT]) + data


def signal_message(n):
    return bytes([SIGNAL_TO, n])


def resize_message(rows, cols):
    return bytes([RESIZE]) + struct.pack(">HH", rows, cols)


def hash_message(chunk):
    return bytes([CHUNK_HASH]) + chunk


MAX_DEPTH = 64  # how deep a folder is fetched, at most
TRAIL = (1 + 32) + (2 + 32)  # what follows a file's last bytes: the last chunk's hash, then the end and the file's hash


def done_message(status, whole=b""):
    return bytes([FILE_DONE, status]) + whole


def status_of(message):
    """The status that begins a service's answer, and what follows it: for a failure, the reason."""
    return message[0], message[1:]


def services_of(body):
    """What zsp.services lists, after its status: dicts of kind shell, files or tcp."""
    r, out = Reader(body), []
    while not r.done():
        kind = r.u8()
        if kind == 1:
            flags = r.u8()
            out.append(dict(kind="shell", terminal=bool(flags & 1), commands=bool(flags & 2)))
        elif kind == 2:
            flags = r.u8()
            out.append(dict(kind="files", read=bool(flags & 1), write=bool(flags & 2), name=r.bytes().decode()))
        elif kind == 3:
            out.append(dict(kind="tcp", port=r.u16(), host=r.bytes().decode(), name=r.bytes().decode()))
        else:
            raise ValueError("a service of no known kind")
    return out


def entries_of(message):
    """What a message of zsp.list holds: (kind, name, size, modified in ms), kind FILE, FOLDER or OTHER."""
    r, out = Reader(message), []
    while not r.done():
        out.append((r.u8(), r.bytes().decode(errors="surrogateescape"), r.varint(), r.varint()))
    return out


def get_answer(body):
    """What zsp.get says after its status: the file's size, when it was written (ms), its identity, and from where it comes."""
    r = Reader(body)
    return r.varint(), r.varint(), bytes(r.bytes()), r.varint()


def put_answer(body):
    """What zsp.put says after its status: from where the file is wanted."""
    return Reader(body).varint()


def from_process(message):
    """What a process said: (OUTPUT, bytes), (ERRORS, bytes), or (EXITED, (code, signal))."""
    if message[0] == EXITED:
        r = Reader(message[1:])
        return EXITED, (r.varint(), r.u8())
    return message[0], message[1:]


class Hashing:
    """A file's hash as it goes by: each chunk of a MiB by SHA-256, and the file by SHA-256 of its chunks' hashes."""

    def __init__(self):
        self.chunk, self.filled, self.file = hashlib.sha256(), 0, hashlib.sha256()

    def feed(self, data):
        """Takes what of data fits in the chunk under way; says how much that was, and whether the chunk is full."""
        taken = min(len(data), CHUNK - self.filled)
        self.chunk.update(data[:taken])
        self.filled += taken
        return taken, self.filled == CHUNK

    def end_chunk(self):
        h = self.chunk.digest()
        self.file.update(h)
        self.chunk, self.filled = hashlib.sha256(), 0
        return h


def file_hashes(data):
    """The hashes of a file's chunks, and of the file."""
    h, chunks = Hashing(), []
    for at in range(0, len(data), CHUNK):
        h.feed(data[at : at + CHUNK])
        chunks.append(h.end_chunk())
    return chunks, h.file.digest()


def file_identity(st):
    """What says a file is the one it was, as host/files.odin says it: its size, when it was written, and which it is on its disk."""
    ino = st.st_ino & (2**128 - 1)
    return varint(st.st_size) + varint(max(st.st_mtime_ns, 0)) + varint(ino & (2**64 - 1)) + varint(ino >> 64) + varint(st.st_dev & (2**64 - 1))


def good_chunks(f, hashes):
    """How many of a part's first chunks are what their recorded hashes say, read again here: what was checked as it
    came may have been changed since on this disk, and nothing is taken up from that it does not still prove."""
    for i in range(len(hashes) // 32):
        f.seek(i * CHUNK)
        data = f.read(CHUNK)
        if len(data) != CHUNK or hashlib.sha256(data).digest() != hashes[i * 32 : i * 32 + 32]:
            return i
    return len(hashes) // 32


class Refused(Exception):
    """A service would not do what was asked, or could not: status is its code (SPEC.md 16), reason what it said."""

    def __init__(self, status, reason=""):
        name = STATUSES[status] if status < len(STATUSES) else "status %d" % status
        super().__init__(name + (": " + reason if reason else ""))
        self.status, self.reason = status, reason


def fault_refusal(fault):
    """A call's fault, as a service's status: as host/transfer.odin takes it."""
    status = UNREACHABLE if fault == 2 else DENIED if fault == 1 else FAILED
    return Refused(status, FAULTS[fault] if fault < len(FAULTS) else "fault %d" % fault)


class Call(dict):
    """A call this client made (SPEC.md 12): messages each way, each within credit. What comes is held here until it is
    read, and credited only then, so that a reader that falls behind holds up whoever sends rather than piling up here;
    and nothing is sent beyond what the other side has credited. As a dict, it is what `call` always answered:
    data, ended, fault; and room, what may be sent yet."""

    def __init__(self, client, id, first):
        super().__init__(data=[], ended=False, fault=None, room=CALL_WINDOW - len(first))
        self.client, self.id = client, id
        self.window, self.used, self.since = CALL_WINDOW, 0, time.monotonic()
        self.said_end = False

    def held(self):
        """How many bytes have come and not been read."""
        return sum(map(len, self["data"]))

    def over(self):
        return self["fault"] is not None or (self["ended"] and self.said_end)

    def next(self, timeout=10):
        """The next message, left uncredited until `consumed` says it is done with; None once no more will come."""
        self.client.until(lambda: self["data"] or self["ended"], timeout)
        return self["data"].pop(0) if self["data"] else None

    def read(self, timeout=10):
        """The next message, credited as it is taken; None once no more will come."""
        message = self.next(timeout)
        if message is not None:
            self.consumed(len(message))
        return message

    def consumed(self, n):
        """Says that n bytes that came are done with, so that as many more may come. A window used up quickly grows,
        to 4 MiB, which is what a long path needs and a slow reader never gets."""
        if self["ended"] or n <= 0:
            return  # nothing more is coming
        credit = n
        self.used += n
        if self.used >= self.window:
            now = time.monotonic()
            if now - self.since < WINDOW_QUICK and self.window < WINDOW_MOST:
                credit += self.window
                self.window *= 2
            self.used, self.since = 0, now
        self.client.flow(self.id, 0, F_CREDIT, varint(credit))

    def send(self, message, timeout=10):
        """Sends a message once there is credit for it."""
        if len(message) > CALL_WINDOW:
            raise ValueError("a message is at most 256 KiB")
        self.client.until(lambda: self["room"] >= len(message) or self["fault"] is not None, timeout)
        if self["fault"] is not None:
            raise fault_refusal(self["fault"])
        self["room"] -= len(message)
        self.client.flow(self.id, 0, F_DATA, message)

    def end(self):
        """Says that no more will be sent."""
        if not self.said_end and self["fault"] is None:
            self.said_end = True
            self.client.flow(self.id, 0, F_END)
        if self.over():
            self.client.calls.pop(self.id, None)

    def cancel(self):
        """Ends the call at once: nothing more of it is wanted."""
        if not self.over():
            self.client.flow(self.id, 0, F_CANCEL)
            self["ended"], self["fault"] = True, 0
        self.client.calls.pop(self.id, None)

    def answer(self, timeout=10):
        """The status that begins a service's answer (SPEC.md 16): what follows it in its message, if it is ok; and
        otherwise Refused, with what was said."""
        message = self.read(timeout)
        if message is None or message[0] != OK:
            self.end()
            if message is not None:
                raise Refused(message[0], message[1:].decode(errors="replace"))
            raise fault_refusal(self["fault"]) if self["fault"] else Refused(FAILED, "it ended early")
        return message[1:]

    def rest(self, timeout=10):
        """Everything else it says, until it ends."""
        out = []
        while True:
            message = self.read(timeout)
            if message is None:
                break
            out.append(message)
        if self["fault"]:
            raise fault_refusal(self["fault"])
        self.end()
        return b"".join(out)


class Process:
    """A process on a device, by zsp.exec (SPEC.md 16). What it says is taken as it is read, into output and error, and
    credited then: one whose reader stops waits, there, at its own pipe. exit is (code, signal) once it has ended."""

    def __init__(self, call):
        self.call, self.output, self.error, self.exit = call, bytearray(), bytearray(), None

    def write(self, data, wait=True, timeout=10):
        """Gives it input as credit allows: all of it, or with wait=False what may go now. Says how much went. One that
        answers as it reads must be read meanwhile, as run() does, or each waits for the other."""
        data, sent = memoryview(data), 0
        while sent < len(data):
            room = min(self.call["room"], 1 + FILE_READ) - 1
            if room <= 0:
                if not wait:
                    break
                self.call.client.until(lambda: self.call["room"] > 1 or self.call["fault"] is not None, timeout)
                if self.call["fault"] is not None:
                    raise fault_refusal(self.call["fault"])
                continue
            piece = bytes(data[sent : sent + room])
            self.call.send(input_message(piece), timeout)
            sent += len(piece)
        return sent

    def close_stdin(self):
        """No more input: its stdin is closed once it has taken what came."""
        self.call.end()

    def signal(self, n):
        """Sends it a signal by its POSIX number (HANGUP, INTERRUPT, TERMINATE...), to all it started too."""
        self.call.send(signal_message(n))

    def kill(self):
        """Cancels the call, which kills it and all it started."""
        self.call.cancel()

    def read(self, timeout=10):
        """Takes what it says next, kept in output or error too: (OUTPUT or ERRORS, bytes). None once it has exited, or
        the call is over without that, as when it was killed or lost (call["fault"] says)."""
        while self.exit is None:
            message = self.call.read(timeout)
            if message is None:
                return None
            kind, body = from_process(message)
            if kind == OUTPUT:
                self.output += body
            elif kind == ERRORS:
                self.error += body
            elif kind == EXITED:
                self.exit = body
                self.call.end()
                continue
            return kind, body
        return None

    def wait(self, timeout=10):
        """Reads all it says until it exits, and returns exit: None if the call ended without it."""
        deadline = time.monotonic() + timeout
        while self.read(max(deadline - time.monotonic(), 0.001)) is not None:
            pass
        return self.exit


class Terminal(Process):
    """The user's shell with a terminal of its own, by zsp.pty: what is typed goes in by write, and all it shows comes
    out, as output. End of input is ^D, as for whoever types; close() hangs up."""

    def resize(self, rows, cols):
        self.call.send(resize_message(rows, cols))

    def close(self, timeout=2):
        """Hangs up, as closing its window does; what has not gone a while after is killed, with all it started."""
        if self.exit is None and not self.call.over():
            self.signal(HANGUP)
            self.call.end()
            try:
                self.wait(timeout)
            except TimeoutError:
                pass
        if self.exit is None:
            self.kill()
        return self.exit


class Stream:
    """A TCP connection a device made on this client's behalf, by zsp.tcp: bytes each way, shutdown a half-close,
    close a reset."""

    def __init__(self, call):
        self.call = call

    def send(self, data, timeout=10):
        data = memoryview(data)
        for at in range(0, len(data), FILE_READ):
            self.call.send(bytes(data[at : at + FILE_READ]), timeout)

    def recv(self, timeout=10):
        """What came next; b"" once the other end has said all it will. A reset is ConnectionResetError."""
        message = self.call.read(timeout)
        if message is None:
            if self.call["fault"]:
                raise ConnectionResetError(FAULTS[self.call["fault"]] if self.call["fault"] < len(FAULTS) else "reset")
            return b""
        return message

    def shutdown(self):
        """Says no more will be sent; what comes back still comes."""
        self.call.end()

    def close(self):
        self.call.cancel()


class Transfer:
    """The fetching or sending end of zsp.get or zsp.put, as host/transfer.odin is. A file being fetched is kept, until
    it is whole, beside where it is going as `<name>.zsp-part`, with `<name>.zsp-part.meta` saying which file it is
    there and holding the hashes of the chunks taken: so a fetch begun again takes up where the last stopped, as long
    as the file there is the one it was. Every chunk is checked as it comes, and the file when it is all there."""

    def __init__(self, put, local, remote):
        self.put, self.local, self.remote = put, local, remote
        self.call = self.f = self.meta = None
        self.size = self.modified = self.at = self.start = 0
        self.hashing, self.pending, self.identity, self.said = Hashing(), b"", b"", OK
        self.awaiting = self.begun = self.sent_all = self.finished = False
        self.status, self.reason, self.bytes, self.resumed, self.hash = OK, "", 0, 0, b""

    def first_get(self):
        """The first message of a fetch: from the end of the chunks of a part that still prove good, if there is one."""
        part, known = self.local + PART, None
        try:
            with open(part + ".meta", "rb") as f:
                kept = f.read()
        except OSError:
            kept = None
        if kept is not None:
            r = Reader(kept)
            try:
                identity = bytes(r.bytes())
                chunks = (len(kept) - r.pos) // 32
                fits = chunks * CHUNK <= os.stat(part).st_size
            except (ValueError, OSError):
                fits = False
            if fits:
                try:
                    with open(part, "rb") as f:
                        chunks = good_chunks(f, kept[r.pos : r.pos + chunks * 32])
                    known, self.start = identity, chunks * CHUNK
                except OSError:
                    pass
        return first_get(self.remote, self.start if known is not None else 0, known or b"")

    def first_put(self, replace, folders):
        """The first message of a send. OSError if the file cannot be read."""
        self.f = open(self.local, "rb")
        st = os.fstat(self.f.fileno())
        if not stat.S_ISREG(st.st_mode):
            self.f.close()
            raise IsADirectoryError(self.local + " is no file")
        self.size, self.modified = st.st_size, max(st.st_mtime_ns, 0) // 1_000_000
        self.identity = file_identity(st)
        return first_put(self.remote, self.size, self.modified, self.identity, replace, folders)

    def on_data(self, message):
        if self.finished or not message:
            return
        if not self.begun:
            self.begun = True
            status, body = status_of(message)
            if status != OK:
                return self.finish(status, body.decode(errors="replace"))
            try:
                if self.put:
                    start = put_answer(body)
                else:
                    size, modified, identity, start = get_answer(body)
            except ValueError:
                return self.finish(MALFORMED)
            if self.put:
                if start % CHUNK or start > self.size:
                    return self.finish(MALFORMED)
                # What the other end has, it has checked; its hashes, here, are read again, for the file's.
                self.start, self.at, self.resumed = start, 0, start
                while self.at < start:
                    n = min(FILE_READ, start - self.at, CHUNK - self.hashing.filled)
                    self.f.seek(self.at)
                    got = self.f.read(n)
                    if len(got) != n:
                        return self.finish(FAILED, "cannot read the file")
                    if self.hashing.feed(got)[1]:
                        self.hashing.end_chunk()
                    self.at += n
                return
            if start > size or start % CHUNK or (start != 0 and start != self.start):
                return self.finish(MALFORMED)
            self.size, self.modified = size, modified
            if not self.open_part(identity, start):
                return self.finish(FAILED, "cannot write the file")
            return
        if self.put:
            # The verdict, once all is sent: an Ok before then, or after this end said the file changed, is no success.
            status = message[0]
            if status == OK and not self.sent_all:
                status = MALFORMED
            elif status == OK and self.said != OK:
                status = self.said
            return self.finish(status)
        kind, payload = message[0], memoryview(message)[1:]
        if kind == CHUNK_BYTES:
            if self.awaiting or self.at + len(payload) > self.size:
                return self.fail(MALFORMED)
            while len(payload) > 0:
                taken, ended = self.hashing.feed(payload)
                self.f.seek(self.at)
                if self.f.write(payload[:taken]) != taken:
                    return self.fail(FAILED)
                self.at += taken
                payload = payload[taken:]
                if ended or self.at == self.size:
                    self.pending, self.awaiting = self.hashing.end_chunk(), True
                    if len(payload) > 0:
                        return self.fail(MALFORMED)  # a chunk's hash comes between its bytes and the next chunk's
        elif kind == CHUNK_HASH:
            if not self.awaiting or bytes(payload) != self.pending:
                return self.fail(CHANGED)
            self.awaiting = False
            self.meta.write(payload)  # taken, and known good
        elif kind == FILE_DONE:
            if len(payload) < 1 or payload[0] != OK:
                return self.fail(payload[0] if len(payload) > 0 else MALFORMED)
            if self.awaiting or self.at != self.size:
                return self.fail(MALFORMED)
            self.hash = self.hashing.file.digest()
            # From the start, the file's hash comes and must agree; taken up later, every chunk's has, kept or come.
            if (self.start == 0 and len(payload) != 33) or (len(payload) == 33 and bytes(payload[1:]) != self.hash):
                return self.fail(CHANGED)
            self.commit()
        else:
            self.fail(MALFORMED)

    def open_part(self, identity, start):
        """The part, taken up where it was if it is the same file there, or begun afresh."""
        part = self.local + PART
        binary = getattr(os, "O_BINARY", 0)
        try:
            self.f = os.fdopen(os.open(part, os.O_RDWR | os.O_CREAT | binary, 0o600), "r+b", buffering=0)
            if start == 0:
                self.f.truncate(0)
                self.meta = os.fdopen(os.open(part + ".meta", os.O_RDWR | os.O_CREAT | os.O_TRUNC | binary, 0o600), "r+b", buffering=0)
                self.meta.write(put_bytes(identity))
            else:
                self.meta = os.fdopen(os.open(part + ".meta", os.O_RDWR | binary), "r+b", buffering=0)
                kept = self.meta.read()
                r = Reader(kept)
                r.bytes()
                chunks = start // CHUNK
                if len(kept) < r.pos + chunks * 32:
                    return False  # cut short since it was read: nothing to take up from
                for i in range(chunks):
                    self.hashing.file.update(kept[r.pos + i * 32 : r.pos + i * 32 + 32])
                self.meta.truncate(r.pos + chunks * 32)
                self.meta.seek(0, os.SEEK_END)
                self.f.truncate(start)
        except (OSError, ValueError):
            return False
        self.start = self.at = self.resumed = start
        return True

    def wants_room(self):
        return self.put and self.begun and not self.finished and not self.sent_all

    def pump(self):
        """Sends as much of the file as credit allows, each chunk followed by its hash; then the end."""
        if not self.wants_room():
            return
        while True:
            # Credit for what follows the last bytes is kept back from them, so that it can always go when they have.
            room = min(self.call["room"], CALL_WINDOW)
            if self.at < self.size:
                if room < 1 + 1 + TRAIL:
                    return
                n = min(room - 1 - TRAIL, FILE_READ, self.size - self.at, CHUNK - self.hashing.filled)
                self.f.seek(self.at)
                got = self.f.read(n)
                if not got:
                    return self.fail(CHANGED)
                self.call.send(bytes([CHUNK_BYTES]) + got)
                self.hashing.feed(got)
                self.at += len(got)
                self.bytes += len(got)
                if self.hashing.filled < CHUNK and self.at < self.size:
                    continue
            elif room < TRAIL:
                return
            if self.hashing.filled > 0:
                self.call.send(hash_message(self.hashing.end_chunk()))
            if self.at == self.size:
                # Still the file it was, all the while? If not, what went may be some of each, and is said to be.
                try:
                    same = file_identity(os.fstat(self.f.fileno())) == self.identity
                except OSError:
                    same = False
                self.hash = self.hashing.file.digest()
                self.said = OK if same else CHANGED
                self.call.send(done_message(OK, self.hash) if same else done_message(CHANGED))
                self.sent_all = True
                self.call.end()
                return

    def on_end(self):
        """The call ended from the other side before the transfer did, well or by a fault."""
        if self.finished:
            return
        fault = self.call["fault"]
        if fault:
            refusal = fault_refusal(fault)
            self.finish(refusal.status, refusal.reason)
        else:
            self.finish(FAILED, "it ended early")

    def commit(self):
        """Whole and checked: made durable, put in place with the sender's time, its record of progress let go."""
        os.fsync(self.f.fileno())
        self.f.close()
        self.f = None
        self.meta.close()
        self.meta = None
        part = self.local + PART
        ns = self.modified * 1_000_000
        try:
            os.utime(part, ns=(ns, ns))
        except OSError:
            pass
        try:
            os.replace(part, self.local)
        except OSError:
            return self.finish(FAILED, "cannot put the file in place")
        try:
            os.remove(part + ".meta")
        except OSError:
            pass
        self.bytes = self.at - self.start
        self.finish(OK)
        self.call.end()

    def fail(self, status):
        if status in (CHANGED, MALFORMED) and self.meta is not None:
            self.meta.truncate(0)  # nothing to take up from
        self.finish(status)

    def finish(self, status, reason=""):
        if self.finished:
            return
        self.finished, self.status, self.reason = True, status, reason
        if not self.put and self.f is not None:
            os.fsync(self.f.fileno())  # what came is kept, to take up from
        if self.meta is not None:
            os.fsync(self.meta.fileno())

    def close(self):
        for f in (self.f, self.meta):
            if f is not None:
                f.close()
        self.f = self.meta = None


class Client:
    def __init__(self, address, credential, timeout=10, authors=False):
        host, port = address.rsplit(":", 1)
        self.sock = socket.create_connection((host, int(port)), timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            f"GET / HTTP/1.1\r\nHost: {address}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\n\r\n".encode()
        )
        self.raw, self.stream = b"", b""
        while b"\r\n\r\n" not in self.raw:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("refused")
            self.raw += chunk
        head, self.raw = self.raw.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise ConnectionError(head.split(b"\r\n")[0].decode())
        self.clock = self.seq = self.acked = 0
        self.scopes = {}  # number -> (rights, list key)
        self.rows = {}  # id -> {(slot, kind, stamp): body}
        self.windows = {}  # watch id -> dict(lo, hi, before, after, settled)
        self.lives = []  # (row, slot, piece, offset, bytes)
        self.answers = {}  # question id -> dict(rows, total, first, settled, totals), or what is said instead
        self.devices = []  # reachable: (key, subject), this one first
        self.authors = {}  # number -> (device, subject): 0 is this client
        self.by = {}  # (row, slot, stamp) -> author's number
        self.caller = None  # the subject of whoever's call is being answered
        self.handlers = {}  # (scope, method) -> function(device, bytes) -> bytes
        self.calls = {}  # id -> {"data": [], "ended": bool, "fault": int or None}
        self.next_call = 0
        self.send(HELLO, bytes([1, 4 if authors else 0]) + bytes(32) + varint(0) + varint(len(credential)) + credential)
        while self.step() != ROSTER:
            pass

    # -- the pipe

    def send(self, kind, body):
        data = frame(kind, body)
        mask = os.urandom(4)
        n = len(data)
        head = bytes([0x82]) + (
            bytes([n | 0x80]) if n < 126 else bytes([254]) + struct.pack(">H", n) if n < 65536 else bytes([255]) + struct.pack(">Q", n)
        )
        masked = (int.from_bytes(data, "big") ^ int.from_bytes((mask * (n // 4 + 1))[:n], "big")).to_bytes(n, "big")
        self.sock.sendall(head + mask + masked)

    def recv_message(self):
        while True:
            if len(self.raw) >= 2:
                n, at = self.raw[1] & 0x7F, 2
                if n == 126 and len(self.raw) >= 4:
                    n, at = struct.unpack(">H", self.raw[2:4])[0], 4
                elif n == 127 and len(self.raw) >= 10:
                    n, at = struct.unpack(">Q", self.raw[2:10])[0], 10
                elif n >= 126:
                    at = 1 << 60
                if len(self.raw) >= at + n:
                    op, payload = self.raw[0] & 15, self.raw[at : at + n]
                    self.raw = self.raw[at + n :]
                    if op == 8:
                        raise ConnectionError("closed")
                    if op == 2:
                        return payload
                    continue
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("closed")
            self.raw += chunk

    def step(self):
        """Handles one frame and returns its type."""
        while True:
            r = Reader(self.stream)
            try:
                body = r.bytes()
                break
            except ValueError:
                self.stream += self.recv_message()
        self.stream = self.stream[r.pos :]
        r = Reader(body)
        kind = r.u8()
        if kind == ROSTER:
            self.clock = max(self.clock, r.u64())
            self.scopes = {}
            while not r.done():
                scope = r.varint()
                rights = r.u8()
                self.scopes[scope] = (rights, r.take(32))
        elif kind == CELLS:
            r.varint()
            row = None
            while not r.done():
                tag = r.u8()
                if not tag & 0x80:
                    row = r.take(16)
                slot, stamp, value = r.u8(), r.take(16), r.bytes()
                if tag & 0x40:
                    self.by[(row, slot, stamp)] = r.varint()
                self.merge(row, slot, tag & 0x3F, stamp, value)
        elif kind == AUTHOR:
            number = r.varint()
            self.authors[number] = (r.take(32), r.bytes())
        elif kind == ACK:
            self.acked = r.varint()
        elif kind == SYNCED:
            window, flags = r.varint(), r.u8()
            self.windows[window] = dict(
                settled=flags & 1, restart=flags & 2, denied=flags & 4, lo=r.key(), hi=r.key(), before=r.varint(), after=r.varint()
            )
        elif kind == LIVE:
            row, slot, piece, offset = r.take(16), r.u8(), r.take(8), r.varint()
            r.take(16)
            self.lives.append((row, slot, piece, offset, r.take(len(body) - r.pos)))
        elif kind == PRESENCE:
            self.devices = []
            while not r.done():
                self.devices.append((r.take(32), r.bytes()))
        elif kind == CALL:
            call, device, scope, method = r.varint(), r.take(32), r.varint(), r.bytes().decode()
            self.caller = r.bytes()
            answer = self.handlers[(scope, method)](device, r.take(len(body) - r.pos))
            self.flow(call, 1, F_DATA, answer)
            self.flow(call, 1, F_END)
        elif kind == FLOW:
            tag, what = r.varint(), r.u8()
            payload = r.take(len(body) - r.pos)
            call = self.calls.get(tag >> 1) if tag & 1 else None
            if call is not None:
                # Held, and credited as it is read: see Call.
                if what == F_DATA:
                    call["data"].append(payload)
                elif what == F_END:
                    call["ended"] = True
                elif what in (F_FAULT, F_CANCEL):
                    call["ended"], call["fault"] = True, payload[0] if payload else 0
                elif what == F_CREDIT:
                    # As the node counts it, which is what it holds this side to.
                    call["room"] = min(call.get("room", 0) + (Reader(payload).varint() & 0xFFFFFF), WINDOW_MOST)
                if what in (F_FAULT, F_CANCEL) or (what == F_END and getattr(call, "said_end", False)):
                    self.calls.pop(tag >> 1, None)  # over: nothing more will come of it
        elif kind == ANSWER:
            which, flags = r.varint(), r.u8()
            if flags & 16:
                self.answers.pop(which, None)
            elif flags & 14:
                self.answers[which] = dict(denied=flags & 2, faulty=flags & 4, waiting=r.u8() if flags & 8 else None)
            else:
                a = self.answers[which] = dict(settled=flags & 1, total=r.varint(), first=r.varint())
                a["rows"] = [r.take(16) for _ in range(r.varint())]
                a["totals"] = []
                for _ in range(r.varint()):
                    have, number = r.u8(), struct.unpack(">d", r.take(8))[0]
                    a["totals"].append((number if have else None, [(r.varint(), r.bytes()) for _ in range(r.varint())]))
        elif kind == ERROR:
            raise PermissionError(f"fault {r.u8()}")
        return kind

    def until(self, condition, timeout=10):
        deadline = time.monotonic() + timeout
        while not condition():
            self.sock.settimeout(max(deadline - time.monotonic(), 0.001))
            try:
                self.step()
            except socket.timeout as e:  # a TimeoutError only from Python 3.10
                raise TimeoutError(*e.args) from e
        return self

    def drain(self, seconds):
        """Handles whatever arrives for a while."""
        deadline = time.monotonic() + seconds
        try:
            while True:
                self.sock.settimeout(max(deadline - time.monotonic(), 0.001))
                self.step()
        except (TimeoutError, socket.timeout):  # one and the same, from Python 3.10
            self.sock.settimeout(10)

    # -- the merge rule

    def merge(self, row, slot, kind, stamp, body):
        self.clock = max(self.clock, struct.unpack(">Q", stamp[:8])[0])
        cells = self.rows.setdefault(row, {})
        if any(k == GRAVE for (_, k, _) in cells) and kind != GRAVE:
            return
        for (s, k, t), b in list(cells.items()):
            if kind == GRAVE:
                del cells[(s, k, t)]
            elif s == slot:
                if k in (PLACE, VALUE) and stamp <= t:
                    return
                if k == BUNDLE and kind in (PIECE, BUNDLE) and stamp in stamps_of(b):
                    return
                if (kind in (PLACE, VALUE) and t < stamp) or (kind == BUNDLE and k in (PIECE, BUNDLE) and t in stamps_of(body)):
                    del cells[(s, k, t)]
        cells[(slot, kind, stamp)] = body

    # -- what a client does

    def tag(self, scope, name):
        return struct.pack(">I", scope) + hashlib.sha256(self.scopes[scope][1] + name.encode()).digest()[:12]

    def stamp(self):
        self.clock = max(self.clock + 1, int(time.time() * 1000) << 16)
        return struct.pack(">Q", self.clock) + os.urandom(8)

    def new_id(self, scope):
        now = int(time.time() * 1000)
        self.clock = max(self.clock, now << 16)  # as late as anything heard of: so, than any right known to have ended
        return struct.pack(">II", scope, (self.clock >> 16) // 1000) + os.urandom(8)

    def write(self, *cells):
        """cells: (row, slot, kind, body). Applied here at once, acknowledged when durable."""
        self.seq += 1
        out, last = varint(self.seq), None
        for row, slot, kind, body in cells:
            stamp = self.stamp()
            self.merge(row, slot, kind, stamp, body)
            out += bytes([kind | (0x80 if row == last else 0)]) + (b"" if row == last else row)
            out += bytes([slot]) + stamp + varint(len(body)) + body
            last = row
        self.send(CELLS, out)
        return self.seq

    def put(self, *args, **more):
        """put(scope, name, order, values) writes a row: see put_row. put(device, scope, local, remote) sends a file to a
        device: see put_file."""
        return (self.put_row if isinstance(args[0], int) else self.put_file)(*args, **more)

    def put_row(self, scope, name, order, values, row=None, slot=1):
        row = row or self.new_id(scope)
        place = (row, slot, PLACE, self.tag(scope, name) + struct.pack(">Q", order))
        self.write(place, *((row, 16 + i, VALUE, v) for i, v in enumerate(values)))
        return row

    def live(self, row, slot, piece, offset, data):
        self.send(LIVE, row + bytes([slot]) + piece + varint(offset) + bytes(16) + data)

    def watch(self, window, scope, name, limit=0, back=True, lo=None, hi=None, live=True):
        prefix = self.tag(scope, name)
        lo = lo if lo is not None else prefix.ljust(40, b"\0")
        hi = hi if hi is not None else key_after(prefix)
        flags = DATA_WATCH | (LIVE_WATCH if live else 0) | (BACK if back else 0)
        self.windows.pop(window, None)
        self.send(WATCH, varint(window) + bytes([flags]) + put_key(lo) + put_key(hi) + varint(limit))

    def flow(self, call, side, kind, payload=b""):
        self.send(FLOW, varint(call << 1 | side) + bytes([kind]) + payload)

    def serve(self, scope, method, handler):
        self.handlers[(scope, method)] = handler
        self.send(SERVE, varint(scope) + b"\1" + varint(len(method)) + method.encode())

    def ask(self, which, *args, **more):
        """Asks a question, which stays asked: see `question`, and self.answers."""
        self.send(ASK, varint(which) + question(*args, **more))

    def fetch(self, *args, **more):
        """Asks a question once. Says what the answer was, and the rows in it as they were."""
        self.next_fetch = getattr(self, "next_fetch", 1 << 20) + 1
        which = self.next_fetch
        self.send(FETCH, varint(which) + question(*args, **more))
        self.until(lambda: self.answers.get(which, {}).get("rows") is not None or any(self.answers.get(which, {}).get(k) for k in ("denied", "faulty")))
        a = self.answers.pop(which)
        a["cells"] = {row: dict(self.rows[row]) for row in a.get("rows", ())}
        return a

    def unask(self, which):
        self.send(UNASK, varint(which))

    def answer(self, which):
        self.until(lambda: "rows" in self.answers.get(which, {}))
        return self.answers[which]

    def open(self, device, scope, method, first=b""):
        """Begins a call, to be spoken to and read as it goes: see Call."""
        if len(first) > CALL_WINDOW:
            raise ValueError("a message is at most 256 KiB")
        self.next_call += 1
        call = self.calls[self.next_call] = Call(self, self.next_call, first)
        self.send(CALL, varint(self.next_call) + device + varint(scope) + varint(len(method)) + method.encode() + b"\0" + first)
        return call

    def call(self, device, scope, method, body=b"", timeout=10):
        """Calls with one message and gathers all that comes back: data, and fault if it failed."""
        call = self.open(device, scope, method, body)
        call.end()
        deadline, data = time.monotonic() + timeout, []
        while True:
            message = call.read(max(deadline - time.monotonic(), 0.001))
            if message is None:
                break
            data.append(message)
        call["data"] = data
        return call

    # -- what devices share of themselves: SPEC.md 16

    def own_device(self):
        self.until(lambda: self.devices)
        return self.devices[0][0]

    def services(self, device, scope, timeout=10):
        """What a device offers in a scope, as far as this one's rights let it use it: dicts of kind shell (terminal,
        commands), files (name, read, write) or tcp (port, host, name). Its own device lists all it shares."""
        call = self.open(device, scope, "zsp.services")
        call.end()
        body = call.answer(timeout)
        return services_of(body + call.rest(timeout))

    def shares(self, timeout=10):
        """What this client's own device shares, as the text zsp.share takes."""
        call = self.open(self.own_device(), self.share_scope(), "zsp.share")
        call.end()
        body = call.answer(timeout)
        return (body + call.rest(timeout)).decode()

    def set_shares(self, text, timeout=10):
        """Puts new shares in place of this device's, in force at once: whatever they no longer allow is ended."""
        call = self.open(self.own_device(), self.share_scope(), "zsp.share", (text or "\n").encode())  # empty would ask
        call.end()
        call.answer(timeout)
        call.rest(timeout)

    def share_scope(self):
        """A scope this client may call in, as zsp.share is called in one, whichever."""
        self.until(lambda: any(rights & MAY_CALL for rights, _ in self.scopes.values()))
        return min(scope for scope, (rights, _) in self.scopes.items() if rights & MAY_CALL)

    def exec(self, device, scope, argv, env=(), cwd="", timeout=10):
        """Runs a program on a device, with its own arguments: a Process, once it has started. Refused if it would not."""
        call = self.open(device, scope, "zsp.exec", first_exec(argv, env, cwd))
        call.answer(timeout)
        return Process(call)

    def run(self, device, scope, argv, env=(), cwd="", input=b"", timeout=30):
        """Runs a program to its end, its input given as it takes it and its output read meanwhile: (code, signal,
        stdout, stderr)."""
        p = self.exec(device, scope, argv, env, cwd, timeout)
        pending = memoryview(input)
        if not pending:
            p.close_stdin()
        deadline = time.monotonic() + timeout
        while p.exit is None:
            if pending:
                pending = pending[p.write(pending, wait=False) :]
                if not pending:
                    p.close_stdin()
            self.until(lambda: p.call["data"] or p.call["ended"] or (pending and p.call["room"] > 1), deadline - time.monotonic())
            if p.call["data"]:
                p.read(0)
            elif p.call["ended"]:
                break
        if p.exit is None:
            raise fault_refusal(p.call["fault"]) if p.call["fault"] else Refused(FAILED, "it ended without exiting")
        return p.exit[0], p.exit[1], bytes(p.output), bytes(p.error)

    def terminal(self, device, scope, rows, cols, term="xterm-256color", env=(), cwd="", timeout=10):
        """The user's shell on a device, with a terminal so big: a Terminal."""
        call = self.open(device, scope, "zsp.pty", first_pty(rows, cols, term, env, cwd))
        call.answer(timeout)
        return Terminal(call)

    def connect(self, device, scope, port, host="", timeout=20):
        """A TCP connection a device makes, to its own port or, if it offers that, another's: a Stream."""
        call = self.open(device, scope, "zsp.tcp", first_tcp(port, host))
        call.answer(timeout)
        return Stream(call)

    def list_files(self, device, scope, path, timeout=10):
        """What is in a folder a device shares: (kind, name, size, modified in ms), kind FILE, FOLDER or OTHER. A path is
        a share's name and then the path within it, with / between; an empty one lists the shares of files."""
        call = self.open(device, scope, "zsp.list", first_list(path))
        call.end()
        out = entries_of(call.answer(timeout))
        while True:
            message = call.read(timeout)
            if message is None:
                break
            out += entries_of(message)
        if call["fault"]:
            raise fault_refusal(call["fault"])
        return out

    def get(self, device, scope, remote, local, progress=None, timeout=30):
        """Fetches a file from a device, resumably, as host/transfer.odin does: dict(size, bytes carried this time,
        resumed from where, hash). Refused if it could not be had; what came is kept, to take up from next time.
        progress(at, size), if given, is told as it goes."""
        t = Transfer(False, local, remote)
        t.call = self.open(device, scope, "zsp.get", t.first_get())
        return self.transfer(t, progress, timeout)

    def put_file(self, device, scope, local, remote, replace=False, folders=True, progress=None, timeout=30):
        """Sends a file to a device, resumably: there it is kept apart until it is whole, then put in place, with this
        one's time, or not at all. replace says it may take the place of one that is there; folders, that the folders
        on the way may be made. As get answers, or Refused."""
        t = Transfer(True, local, remote)
        t.call = self.open(device, scope, "zsp.put", t.first_put(replace, folders))
        return self.transfer(t, progress, timeout)

    def transfer(self, t, progress, timeout):
        c = t.call
        try:
            while not t.finished:
                self.until(lambda: c["data"] or c["ended"] or (t.wants_room() and c["room"] >= 1 + 1 + TRAIL), timeout)
                if c["data"]:
                    message = c.next(0)
                    t.on_data(message)
                    c.consumed(len(message))  # written on, or done with
                    if progress is not None and not t.finished:
                        progress(t.at, t.size)
                elif c["ended"]:
                    t.on_end()
                t.pump()
        finally:
            t.close()
        if t.status != OK:
            c.cancel()  # what it still says is of no use
            raise Refused(t.status, t.reason)
        c.end()
        return dict(size=t.size, bytes=t.bytes, resumed=t.resumed, hash=t.hash)

    def get_tree(self, device, scope, remote, local, timeout=30, depth=0):
        """Fetches a folder and all in it, walking it by zsp.list; each file as get fetches it. Says how many files
        came, and how many bytes. No deeper than MAX_DEPTH folders: a device whose every folder holds another is not
        followed for ever."""
        os.makedirs(local, exist_ok=True)
        files = carried = 0
        for kind, name, _, _ in self.list_files(device, scope, remote, timeout):
            if name in ("", ".", "..") or any(c in name for c in "/\\:\0"):
                raise Refused(MALFORMED, "a name that would lead elsewhere: " + name)
            if depth >= MAX_DEPTH:
                raise Refused(MALFORMED, "folders deeper than " + str(MAX_DEPTH))
            there, here = remote.rstrip("/") + "/" + name, os.path.join(local, name)
            if kind == FOLDER:
                more, also = self.get_tree(device, scope, there, here, timeout, depth + 1)
                files, carried = files + more, carried + also
            elif kind == FILE:
                carried += self.get(device, scope, there, here, timeout=timeout)["bytes"]
                files += 1
        return files, carried

    def put_tree(self, device, scope, local, remote, replace=False, timeout=30):
        """Sends a folder and all in it, its folders made there as files need them (an empty one is not sent). Parts
        of fetches under way here are passed over. Says how many files went, and how many bytes."""
        files = carried = 0
        for at, folders, names in os.walk(local):
            folders.sort()
            for name in sorted(names):
                if name.endswith(PART) or name.endswith(PART + ".meta"):
                    continue
                path = os.path.join(at, name)
                there = remote.rstrip("/") + "/" + os.path.relpath(path, local).replace(os.sep, "/")
                carried += self.put_file(device, scope, path, there, replace, True, timeout=timeout)["bytes"]
                files += 1
        return files, carried

    def author(self, row, slot):
        """Whom the last to write there goes by, and on which device, if that is known: (device, subject)."""
        stamps = [t for (s, _, t) in self.rows.get(row, ()) if s == slot]
        return self.authors.get(self.by.get((row, slot, max(stamps)))) if stamps else None

    def list(self, *args, **more):
        """list(scope, name) is the rows of a list: see list_rows. list(device, scope, path) is what is in a folder a
        device shares: see list_files."""
        return (self.list_rows if isinstance(args[0], int) else self.list_files)(*args, **more)

    def list_rows(self, scope, name):
        """Rows of a list in order: (order, id, {slot: value})."""
        prefix, out = self.tag(scope, name), []
        for row, cells in self.rows.items():
            for (slot, kind, _), body in cells.items():
                if kind == PLACE and body[:16] == prefix:
                    values = {s: b for (s, k, _), b in cells.items() if k == VALUE}
                    out.append((struct.unpack(">Q", body[16:24])[0], row, values))
        return sorted(out)


def stamps_of(bundle):
    n = struct.unpack(">I", bundle[:4])[0]
    return {bundle[4 + i * 16 : 20 + i * 16] for i in range(n)}
