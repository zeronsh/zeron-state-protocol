"""A Zeron State Protocol client in the Python standard library.

It shows how little of SPEC.md a client needs: frames, cells, and the merge rule. No cryptography, because a
client speaks to its own device's node; no storage, because the node is that. And calls, whose credit is given
only as what comes is used.
"""

import base64, hashlib, os, socket, struct, time

HELLO, ROSTER, WATCH, UNWATCH, RECON, WANT, CELLS, ACK, LIVE, SYNCED, SIGNAL, PRESENCE, ERROR, SERVE, CALL, FLOW, AUTHOR = range(1, 18)
GRAVE, PLACE, VALUE, PIECE, BUNDLE = range(1, 6)
READ, WRITE, MAY_CALL, VOUCH, SAYS_WHOSE = 1, 2, 4, 8, 128
F_DATA, F_END, F_FAULT, F_CANCEL, F_CREDIT = range(5)
FAULTS = ("cancelled", "denied", "unreachable", "unserved", "lost", "overrun", "busy")
CALL_WINDOW = 256 << 10  # what a side may send beyond what the other has credited, and the most one message may be
WINDOW_MOST = 16 * CALL_WINDOW  # what a receiver may credit ahead
WINDOW_QUICK = 0.25  # a window used up within so many seconds grows
URGENCY = 3  # of a call's stream, unless it says otherwise: 0 the most urgent, 7 the least
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


class Fault(Exception):
    """A call failed, or was cancelled: fault is its code (SPEC.md 12)."""

    def __init__(self, fault):
        super().__init__(FAULTS[fault] if fault < len(FAULTS) else "fault %d" % fault)
        self.fault = fault


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
            raise Fault(self["fault"])
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

    def rest(self, timeout=10):
        """Everything else it says, until it ends."""
        out = []
        while True:
            message = self.read(timeout)
            if message is None:
                break
            out.append(message)
        if self["fault"]:
            raise Fault(self["fault"])
        self.end()
        return b"".join(out)


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

    def open(self, device, scope, method, first=b"", urgency=URGENCY):
        """Begins a call, to be spoken to and read as it goes: see Call. `urgency` is that of the stream it takes, 0 the
        most urgent and 7 the least: what someone types into wants 1, a bulk copy 6."""
        if len(first) > CALL_WINDOW:
            raise ValueError("a message is at most 256 KiB")
        if urgency not in range(8):
            raise ValueError("urgency is 0 to 7")
        self.next_call += 1
        call = self.calls[self.next_call] = Call(self, self.next_call, first)
        self.send(CALL, varint(self.next_call) + device + varint(scope) + put_bytes(method.encode()) + b"\0" + bytes([urgency]) + first)
        return call

    def call(self, device, scope, method, body=b"", timeout=10, urgency=URGENCY):
        """Calls with one message and gathers all that comes back: data, and fault if it failed."""
        call = self.open(device, scope, method, body, urgency)
        call.end()
        deadline, data = time.monotonic() + timeout, []
        while True:
            message = call.read(max(deadline - time.monotonic(), 0.001))
            if message is None:
                break
            data.append(message)
        call["data"] = data
        return call

    def author(self, row, slot):
        """Whom the last to write there goes by, and on which device, if that is known: (device, subject)."""
        stamps = [t for (s, _, t) in self.rows.get(row, ()) if s == slot]
        return self.authors.get(self.by.get((row, slot, max(stamps)))) if stamps else None

    def list(self, scope, name):
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
