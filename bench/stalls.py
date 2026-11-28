"""What holds a node's event loop, and what that costs a link: python3 bench/stalls.py [options], run by ./x bench stalls.

Real processes on real sockets, each zspd with a loop of its own: a relay R, and devices A and B, linked directly over
UDP. A has a store already (--prefill MiB of rows); B starts empty, and is brought level with A as everything else
goes on. Meanwhile a client of A writes rows and edits them (--write MiB/s), each acknowledged once durable, and A
pours a bulk call (--bulk MiB) into B over the link; a client of B watches the list. B's loop may be made to stall, as
a tick that does that much work would (--stall ms,every ms, as many as wanted: one run each).

zspd is built with -define:ZSP_BENCH=true -define:ZSP_TICKS=true (see zspd/bench.odin, host/ticks.odin): each says, as
it stops, how long its ticks were and what the longest were doing, and what its links sent and lost. This says, for
each run and each process: ticks over 2, 5, 10 and 20 ms and the longest, of what the loop's time went to in the long
ones; the bulk's throughput, and the packets the link from A lost and sent again; CPU, the most memory resident, and
wakeups a second while idle; how long a write waited to be acknowledged, and B to be level.
"""

import argparse, json, os, re, shutil, signal, socket, subprocess, sys, tempfile, threading, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))
import zsp

BIN = os.environ.get("ZSPD", os.path.join(ROOT, "build", "zspd-bench"))
ROW = 4 << 10  # each row's value


def zspd(*args):
    p = subprocess.run([BIN, *args], capture_output=True, text=True)
    if p.returncode:
        raise SystemExit(f"zspd {args}: {p.stderr}")
    return p.stdout.strip()


class Node:
    def __init__(self, root, name, mode, *options, env=None):
        self.dir, self.log_path = os.path.join(root, name), os.path.join(root, name + ".log")
        self.name, self.mode, self.options, self.env = name, mode, list(options), env or {}

    def start(self):
        self.log = open(self.log_path, "a")
        self.p = subprocess.Popen(
            [BIN, self.mode, self.dir, "--listen=127.0.0.1:0", *self.options],
            stdout=subprocess.PIPE, stderr=self.log, text=True, env={**os.environ, **self.env},
        )
        self.key, self.address = re.match(r"(\w{64}) listening on ws://(\S+)", self.p.stdout.readline()).groups()
        return self

    def client(self):
        with open(os.path.join(self.dir, "token"), "rb") as f:
            return zsp.Client(self.address, f.read(), timeout=60)

    def said(self, what):
        with open(self.log_path) as f:
            return what in f.read()

    def switches(self):
        """Voluntary context switches so far, which is to say waits: Linux only."""
        try:
            with open(f"/proc/{self.p.pid}/status") as f:
                return int(re.search(r"voluntary_ctxt_switches:\s+(\d+)", f.read()).group(1))
        except (OSError, AttributeError):
            return None

    def peak(self):
        """The most it has had resident, where the system says so: rusage's would be the Python it was forked from."""
        try:
            with open(f"/proc/{self.p.pid}/status") as f:
                return int(re.search(r"VmHWM:\s+(\d+) kB", f.read()).group(1)) << 10
        except (OSError, AttributeError):
            return None

    def stop(self):
        """Politely, so that it says what it did: then its usage, as the system counted it."""
        peak = self.peak()
        self.p.send_signal(signal.SIGTERM)
        _, status, ru = os.wait4(self.p.pid, 0)
        self.p.returncode = status
        self.log.close()
        with open(self.log_path) as f:
            lines = [l for l in f if l.startswith("bench {")]
        self.report = json.loads(lines[-1][6:]) if lines else {}
        mul = 1 if sys.platform == "darwin" else 1024  # bytes there, KiB here
        self.usage = dict(cpu=ru.ru_utime + ru.ru_stime, rss=peak or ru.ru_maxrss * mul, nvcsw=ru.ru_nvcsw, nivcsw=ru.ru_nivcsw)


def eventually(what, f, timeout=60):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if f():
            return
        time.sleep(0.02)
    raise AssertionError("never: " + what)


def write_rows(c, rows, rate, acks, seconds=None, count=None, edits=0):
    """Writes new rows at `rate` bytes a second, for `seconds` or `count` writes, and edits an earlier one every `edits`
    writes, keeping no more than a few hundred unacknowledged: each write's wait to be acknowledged is put in `acks`."""
    value = os.urandom(ROW)
    sent = {}  # seq -> when
    start, n = time.monotonic(), 0
    while (time.monotonic() - start < seconds) if seconds is not None else n < count:
        due = start + n * ROW / rate
        while time.monotonic() < due:
            c.drain(min(due - time.monotonic(), 0.005)) if due - time.monotonic() > 0.001 else None
        if edits and n % edits == edits - 1 and rows:
            c.write((rows[(n * 7919) % len(rows)], 16, zsp.VALUE, value))
        else:
            rows.append(c.put(1, "w", len(rows), [value]))
        sent[c.seq] = time.monotonic()
        n += 1
        if c.seq - c.acked > 256:
            c.until(lambda: c.seq - c.acked <= 128, 60)
        for seq in [s for s in sent if s <= c.acked]:
            acks.append(time.monotonic() - sent.pop(seq))
    c.until(lambda: c.acked == c.seq, 60)
    now = time.monotonic()
    acks.extend(now - t for t in sent.values())  # at most when, as all were acknowledged by now
    return n


def percentile(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) * p // 100, len(xs) - 1)] if xs else 0


def run(args, stall):
    root = tempfile.mkdtemp(prefix="zsp-stalls-", dir=args.dir)
    nodes = []
    try:
        relay = Node(root, "r", "serve", "--no-udp").start()
        nodes.append(relay)
        a_dir, b_dir = os.path.join(root, "a"), os.path.join(root, "b")
        sid = zspd("create", a_dir)
        url = "ws://localhost:" + relay.address.split(":")[1]
        zspd("relay", a_dir, relay.key, url)
        zspd("admit", a_dir, zspd("key", b_dir), "1")
        zspd("join", b_dir, sid, relay.key, url)
        b_key = zspd("key", b_dir)[:64]
        a = Node(root, "a", "run", "--udp=0", env={"ZSP_BULK": f"{b_key},{args.bulk}"}).start()
        nodes.append(a)

        # What B has to be brought level with.
        ca = a.client()
        rows, acks = [], []
        t = time.monotonic()
        write_rows(ca, rows, 1 << 30, [], count=args.prefill * (1 << 20) // ROW)
        prefill_s = time.monotonic() - t

        b = Node(root, "b", "run", "--udp=0", env={"ZSP_STALL": stall} if stall else {}).start()
        nodes.append(b)
        began = time.monotonic()
        watched = threading.Event()

        def watch():
            cb = b.client()
            cb.until(lambda: 1 in cb.scopes, 60)  # once B has a roster
            cb.watch(1, 1, "w", limit=50)
            while not watched.is_set():
                cb.drain(0.1)

        watcher = threading.Thread(target=watch)
        watcher.start()
        # The writes go on until the bulk is over, and for --seconds at least.
        writing = threading.Thread(target=lambda: write_rows(ca, rows, args.write << 20, acks, seconds=args.seconds, edits=4))
        writing.start()
        eventually("the bulk call is over", lambda: a.said("bench: bulk over"), 600)
        bulk_s = time.monotonic() - began
        writing.join()
        # Level: B holds what A does, as their logs' ends say once B's store is synced. Judged by B's client instead, a
        # window of every row would cost this process more than both nodes.
        expect = len(rows)
        cb = b.client()
        cb.until(lambda: 1 in cb.scopes, 60)
        for window in range(2, 100000):
            cb.watch(window, 1, "w", limit=1, back=True)
            cb.until(lambda: window in cb.windows, 60)
            if cb.windows[window]["before"] + 1 >= expect:
                break
            cb.send(zsp.UNWATCH, zsp.varint(window))
            time.sleep(0.2)
        level_s = time.monotonic() - began
        watched.set()
        watcher.join()

        # Idle: what each wakes for when there is nothing to do.
        time.sleep(2)
        before = [n.switches() for n in nodes]
        time.sleep(args.idle)
        after = [n.switches() for n in nodes]
        idle = [None if x is None or y is None else (y - x) / args.idle for x, y in zip(before, after)]
        for n in nodes:
            n.stop()
        nodes = []
        return dict(
            stall=stall or "none", prefill_s=prefill_s, bulk_s=bulk_s, level_s=level_s, rows=expect,
            ack_p50=percentile(acks, 50), ack_p99=percentile(acks, 99), ack_max=max(acks or [0]),
            procs={n.name: dict(report=n.report, usage=n.usage, idle=i) for n, i in zip((relay, a, b), idle)},
        )
    finally:
        for n in nodes:
            try:
                n.p.kill()
                n.p.wait()
            except Exception:
                pass
        shutil.rmtree(root, ignore_errors=True)


def show(r, bulk):
    a, b, rl = r["procs"]["a"], r["procs"]["b"], r["procs"]["r"]
    sink = b["report"].get("sink", {})
    mbps = sink.get("bytes", 0) * 8 / max(sink.get("ms", 0), 1) / 1e3
    pk = a["report"].get("packets", {})
    loss = 100 * pk.get("direct_lost", 0) / max(pk.get("direct", 0), 1)
    print(f"\n  B stalls {r['stall']} ms: bulk of {bulk} MiB A to B at {mbps:.0f} Mbit/s; A's link sent {pk.get('direct', 0)} packets, lost and sent again {pk.get('direct_lost', 0)} ({loss:.3f}%)")
    print(f"    {r['rows']} rows; a write acknowledged in {r['ack_p50'] * 1e3:.0f} ms median, {r['ack_p99'] * 1e3:.0f} at the 99th, {r['ack_max'] * 1e3:.0f} at most; B level {r['level_s']:.1f} s after it began")
    print("    proc  ticks   >2ms  >5ms >10ms >20ms longest  of the long, the time in                      CPU s   RSS MiB  idle wakeups/s")
    for name in ("r", "a", "b"):
        p = r["procs"][name]
        loop = p["report"].get("loop") or {}
        worst = loop.get("worst") or [{}]
        phases = sorted((loop.get("long_phases") or {}).items(), key=lambda kv: -kv[1])[:3]
        where = ", ".join(f"{k} {v:.0f}" for k, v in phases) or "-"
        disk = loop.get("long_disk") or {}
        if disk:
            where += " (disk: " + ", ".join(f"{k} {v:.0f}" for k, v in sorted(disk.items(), key=lambda kv: -kv[1])[:2]) + ")"
        long = loop.get("long", [0, 0, 0, 0])
        idle = p["idle"]
        print(
            f"    {name:<5} {loop.get('ticks', 0):>6} {long[0]:>6}{long[1]:>6}{long[2]:>6}{long[3]:>6} {worst[0].get('ms', 0):>7.1f}  {where[:44]:<44} "
            f"{p['usage']['cpu']:>6.2f} {p['usage']['rss'] / (1 << 20):>8.0f}  {'-' if idle is None else f'{idle:.1f}':>8}"
        )


def acks(args):
    """A device alone and a client of it writing steadily: how long each write waits to be acknowledged, timed as the
    acknowledgement arrives, by a thread that does nothing but read; and how often the node syncs."""
    root = tempfile.mkdtemp(prefix="zsp-acks-", dir=args.dir)
    try:
        a = Node(root, "a", "run", "--no-udp")
        zspd("create", a.dir)
        a.start()
        c = a.client()
        c.until(lambda: 1 in c.scopes, 60)
        value = os.urandom(ROW)
        sent, heard = {}, []  # seq -> when sent; (acked seq, when heard)
        stop = threading.Event()

        def read():
            c.sock.settimeout(0.05)
            while not stop.is_set():
                try:
                    before = c.acked
                    c.step()
                    if c.acked != before:
                        heard.append((c.acked, time.perf_counter()))
                except (TimeoutError, socket.timeout):
                    pass

        reader = threading.Thread(target=read)
        reader.start()
        rate = args.write << 20
        start, n = time.perf_counter(), 0
        while time.perf_counter() - start < args.acks:
            due = start + n * ROW / rate
            while time.perf_counter() < due:
                time.sleep(max(due - time.perf_counter(), 0) / 2)
            seq = c.seq + 1
            sent[seq] = time.perf_counter()
            c.put(1, "w", n, [value])  # sends, and bumps c.seq: only this thread does
            n += 1
        deadline = time.perf_counter() + 30
        while (not heard or heard[-1][0] < c.seq) and time.perf_counter() < deadline:
            time.sleep(0.01)
        stop.set()
        reader.join()
        waits, i = [], 0
        for seq in sorted(sent):
            while i < len(heard) and heard[i][0] < seq:
                i += 1
            if i < len(heard):
                waits.append(heard[i][1] - sent[seq])
        switches = a.switches()
        a.stop()
        disk = (a.report.get("loop") or {}).get("asked", {})
        return dict(writes=n, acked=len(waits), p50=percentile(waits, 50), p90=percentile(waits, 90), p99=percentile(waits, 99), max=max(waits or [0]), syncs=disk.get("Log_Sync_Start", disk.get("Log_Sync", 0)), acks=len(heard))
    finally:
        shutil.rmtree(root, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--stall", action="append", help="B's loop held so many ms, every so many: 5,50; none for none")
    ap.add_argument("--bulk", type=int, default=1024, help="MiB A calls B with")
    ap.add_argument("--prefill", type=int, default=32, help="MiB of rows A has before B starts")
    ap.add_argument("--write", type=int, default=4, help="MiB a second A's client writes meanwhile")
    ap.add_argument("--seconds", type=float, default=5, help="that it writes for, at least")
    ap.add_argument("--idle", type=float, default=5, help="seconds idle wakeups are counted over")
    ap.add_argument("--dir", default=None, help="where stores go: a real disk, as their fsyncs are what is measured")
    ap.add_argument("--delay", type=float, default=0, help="ms each packet waits, each way, as on a longer path: Linux, in a network namespace of its own")
    ap.add_argument("--acks", type=float, default=0, help="seconds of a device alone and a client writing steadily: only how long writes wait to be acknowledged")
    ap.add_argument("--forced", action="store_true", help="with CAP_NET_ADMIN, so that SO_RCVBUFFORCE is allowed: by sudo, Linux")
    ap.add_argument("--json", default=os.path.join(ROOT, "build", "bench-stalls.json"))
    ap.add_argument("--in-namespace", action="store_true", help=argparse.SUPPRESS)
    args = ap.parse_args()
    if args.forced and not args.in_namespace:
        # The same as root makes it, run as this user with CAP_NET_ADMIN alone, as a systemd unit's
        # AmbientCapabilities=CAP_NET_ADMIN gives it: SO_RCVBUFFORCE is allowed.
        uid, gid = str(os.getuid()), str(os.getgid())
        os.execvp("sudo", ["sudo", "-n", "unshare", "--net", "--", "setpriv", "--reuid=" + uid, "--regid=" + gid, "--init-groups",
                           "--inh-caps=+net_admin", "--ambient-caps=+net_admin", "env", "PATH=" + os.environ["PATH"], "HOME=" + os.environ.get("HOME", "/"), "ZSPD=" + BIN,
                           sys.executable, *sys.argv, "--in-namespace"])
    if args.delay and not args.in_namespace:
        # A loopback of its own, slowed, that nothing else on the machine shares: a user namespace needs no privilege,
        # and grants none outside it, so a socket here is refused SO_RCVBUFFORCE as any unprivileged one is.
        os.execvp("unshare", ["unshare", "--user", "--map-root-user", "--net", sys.executable, *sys.argv, "--in-namespace"])
    if args.in_namespace:
        subprocess.run(["ip", "link", "set", "lo", "up"], check=True)
        # A queue long enough for all a fast link has on its way: netem's own, of 1000, would drop.
        if args.delay:
            subprocess.run(["tc", "qdisc", "add", "dev", "lo", "root", "netem", "delay", f"{args.delay}ms", "limit", "1000000"], check=True)
        print(f"  on a loopback of its own, each packet delayed {args.delay} ms each way" + (", SO_RCVBUFFORCE allowed" if args.forced else ""))
    if args.acks:
        r = acks(args)
        print(f"  {r['writes']} writes at {args.write} MiB/s, {r['acked']} acknowledged in {r['p50'] * 1e3:.1f} ms median, {r['p90'] * 1e3:.1f} at the 90th, {r['p99'] * 1e3:.1f} at the 99th, {r['max'] * 1e3:.1f} at most; {r['acks']} acknowledgements, {r['syncs']} log syncs")
        with open(args.json, "w") as f:
            json.dump(r, f)
        return
    stalls = [None if s == "none" else s for s in (args.stall or ["none", "2,50", "5,50", "10,50"])]
    results = []
    for stall in stalls:
        r = run(args, stall)
        results.append(r)
        show(r, args.bulk)
    with open(args.json, "w") as f:
        json.dump(results, f, indent=1)
    print(f"\n  all of it, the longest ticks each process had among it: {args.json}")


if __name__ == "__main__":
    main()
