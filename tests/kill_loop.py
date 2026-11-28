"""A node killed outright, again and again, as it writes, rolls segments and checkpoints: after each start, every write it
acknowledged is there, and the store opens. Run by ./x test against a zspd with small segments (ZSPD_SMALL), so that
rolls and checkpoints come many times a second: python3 tests/kill_loop.py [rounds]

Killed, not stopped: SIGKILL, or TerminateProcess on Windows, mid-whatever. The system keeps what was written either
way, so this holds the order of what a node does to what a crash of it alone may leave; tests in zsp (power_test.odin)
hold it to what power lost leaves."""

import os, random, re, shutil, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))
import zsp

BIN = os.environ.get("ZSPD_SMALL", os.path.join(ROOT, "build", "zspd-small.exe" if os.name == "nt" else "zspd-small"))
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 16
ROWS = 300  # rows written and written again, so that segments fill with the dead and are evacuated


def zspd(*args):
    p = subprocess.run([BIN, *args], capture_output=True, text=True)
    if p.returncode:
        raise SystemExit(f"zspd {args}: {p.stderr}")
    return p.stdout.strip()


def start(d, log):
    p = subprocess.Popen([BIN, "run", d, "--listen=127.0.0.1:0", "--no-udp"], stdout=subprocess.PIPE, stderr=log, text=True)
    line = p.stdout.readline()
    m = re.match(r"(\w{64}) listening on ws://(\S+)", line)
    if not m:
        p.kill()
        p.wait()
        raise AssertionError("the node did not start again: " + line)
    with open(os.path.join(d, "token"), "rb") as f:
        return p, zsp.Client(m.group(2), f.read(), timeout=30)


def main():
    random.seed(int(os.environ.get("ZSP_SEED", "0")) or None)
    tmp = tempfile.mkdtemp(prefix="zsp-kill-")
    d = os.path.join(tmp, "a")
    zspd("create", d)
    log = open(os.path.join(tmp, "a.log"), "a")
    ids = {}  # n -> row id
    written = {}  # n -> [(seq, value)] in order
    acked_total = 0
    writes_acked = {}  # n -> the latest of its writes acknowledged
    try:
        for round in range(ROUNDS):
            p, c = start(d, log)
            c.until(lambda: 1 in c.scopes, 30)
            # What it holds is what was acknowledged before, or later: each row's value the last acknowledged or one
            # written after it.
            c.watch(1, 1, "k")
            c.until(lambda: 1 in c.windows, 60)
            held = {}
            for _, row, values in c.list(1, "k"):
                held[row] = values.get(16)
            for n, writes in written.items():
                acked = [i for i, (seq, _) in enumerate(writes) if seq <= writes_acked[n]] if n in writes_acked else []
                if not acked:
                    continue
                later = {v for _, v in writes[acked[-1]:]}
                got = held.get(ids[n])
                assert got in later, f"round {round}: row {n} holds {got and got[:12]!r}, which is none of what was written since its acknowledged {writes[acked[-1]][1][:12]!r}"
            # Writes from now on are this start's: what earlier ones left is held, and nothing acknowledged since.
            for n in written:
                got = held.get(ids[n])
                written[n] = [(0, got)] if got is not None else []
            writes_acked = {n: 0 for n in written if written[n]}
            seqs = {}  # seq -> n
            until = time.monotonic() + random.uniform(0.3, 1.2)
            while time.monotonic() < until:
                n = random.randrange(ROWS)
                value = os.urandom(random.choice((200, 2000, 6000)))
                if n in ids:
                    c.write((ids[n], 16, zsp.VALUE, value))
                else:
                    ids[n] = c.put(1, "k", n, [value])
                written.setdefault(n, []).append((c.seq, value))
                seqs[c.seq] = n
                if c.seq - c.acked > 64:
                    c.until(lambda: c.seq - c.acked <= 32, 30)
            c.drain(random.uniform(0, 0.15))  # perhaps mid-sync, perhaps just after
            p.kill()
            p.wait()
            for seq, n in seqs.items():
                if seq <= c.acked:
                    writes_acked[n] = max(writes_acked.get(n, 0), seq)
            acked_total += sum(1 for seq in seqs if seq <= c.acked)
            c.sock.close()
        p, c = start(d, log)
        c.until(lambda: 1 in c.scopes, 30)
        p.kill()
        p.wait()
        print(f"ok   killed {ROUNDS} times as it wrote, {acked_total} writes acknowledged, every one kept")
    finally:
        log.close()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
