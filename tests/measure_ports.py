"""What names and ports cost: ./x bench ports. Real processes on one machine, as tests/end_to_end.py runs them."""

import os, shutil, socket, struct, subprocess, sys, threading, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from end_to_end import Node, Service, zspd, eventually, free_port, procs, resolve, address_of, memory_of, CERTS, public_get, TMP


def private(pid):
    """Resident memory a process does not share: what it costs, the rest being libraries and file cache."""
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            return sum(int(line.split()[1]) * 1024 for line in f if line.startswith(("Private_Clean:", "Private_Dirty:")))
    except OSError:
        return 0


class Sink:
    """Serves `size` bytes to each connection, and echoes otherwise: the far end of what is measured."""

    def __init__(self, port, size):
        self.sock = socket.create_server(("127.0.0.1", port), backlog=4096)  # else the system's SYN cookies, not zspd, are measured
        self.size = size
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while True:
            try:
                c, _ = self.sock.accept()
            except OSError:
                return
            threading.Thread(target=self.one, args=(c,), daemon=True).start()

    def one(self, c):
        block = os.urandom(1 << 16)
        try:
            with c:
                c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                kind = c.recv(1)
                if kind == b"b":  # bulk
                    left = self.size
                    while left > 0:
                        n = min(left, len(block))
                        c.sendall(block[:n])
                        left -= n
                else:  # echo
                    while data := c.recv(65536):
                        c.sendall(data)
        except OSError:
            pass


def two(udp):
    tag = "u" if udp else "r"
    relay = Node("m-relay" + tag, "serve", "--no-udp").start()
    devices = []
    for i, name in enumerate(("ma" + tag, "mb" + tag)):
        d = Node(name, "run", *([] if udp else ["--no-udp"]), "--loopback=127.%d.0" % (95 + i), "--dns=127.0.0.1:%d" % free_port(),
                 "--catch=127.0.0.1:0", "--proxy=127.0.0.1:%d" % free_port())
        d.dns = d.options[-3].split("=")[1]
        devices.append(d)
    a, b = devices
    sid = zspd("create", a.dir)
    url = "ws://localhost:" + relay.address.split(":")[1]
    zspd("relay", a.dir, relay.key, url)
    zspd("admit", a.dir, zspd("key", b.dir), "1")
    zspd("name", a.dir, zspd("key", b.dir), "bee")
    zspd("join", b.dir, sid, relay.key, url)
    a.start(), b.start()
    for d in devices:
        eventually("every device hears who belongs", lambda: os.path.exists(os.path.join(d.dir, sid, "roster")))
    return relay, a, b


def main():
    size = 200 << 20
    port = free_port()
    Sink(port, size)
    for udp in (False, True):
        relay, a, b = two(udp)
        ca, cb = a.client(), b.client()
        ca.until(lambda: len(ca.devices) == 2)
        cb.offer(port, 1)
        resolve(a.dns, "bee.zsp.internal")
        eventually("the offer is heard", lambda: any(p["port"] == port for n in ca.nodes() for p in n["ports"]), timeout=20)
        bee = address_of(ca, b.key)
        path = "a direct link" if udp else "a relay"
        if udp:
            eventually("linked directly", lambda: any(n["direct"] for n in ca.nodes() if not n["here"]), timeout=20)

        if not udp:
            # An idle node: what it does in a quiet minute, and what it holds.
            time.sleep(2)
            calls = idle_calls(a.p.pid, 20)
            print(f"| an idle node, names, offers and proxy on | {calls} system calls in 20 s; {private(a.p.pid) >> 10} KB private |")
            # Names, as a resolver asks.
            n = 2000
            t = time.perf_counter()
            for _ in range(n):
                resolve(a.dns, "bee.zsp.internal")
            print(f"| a name, asked of a node | {(time.perf_counter() - t) / n * 1e6:.0f} µs, round trip by UDP, Python asking |")

        # A connection: made, and its first byte back; then a byte each way, over and over.
        n = 200
        t = time.perf_counter()
        for _ in range(n):
            s = socket.create_connection((bee, port), 10)
            s.sendall(b"ex")  # echo, and a byte to be echoed
            s.recv(1)
            s.close()
        connect = (time.perf_counter() - t) / n
        s = socket.create_connection((bee, port), 10)
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        s.sendall(b"ex")
        s.recv(1)
        n = 2000
        t = time.perf_counter()
        for _ in range(n):
            s.sendall(b"x")
            s.recv(1)
        rtt = (time.perf_counter() - t) / n
        s.close()
        print(f"| a connection to a device's port, through {path} | made and answered in {connect * 1e3:.2f} ms; then {rtt * 1e6:.0f} µs a round trip |")

        # Bulk: as fast as the slower side goes, both nodes on one core each.
        s = socket.create_connection((bee, port), 10)
        s.sendall(b"b")
        got, t = 0, time.perf_counter()
        while got < size:
            data = s.recv(1 << 20)
            if not data:
                break
            got += len(data)
        took = time.perf_counter() - t
        s.close()
        print(f"| {size >> 20} MB through {path} | {got / took / 1e6:.0f} MB/s |")

        if not udp:
            # What a held connection costs: many, idle, open at once.
            before = private(a.p.pid) + private(b.p.pid)
            held = []
            for _ in range(500):
                c = socket.create_connection((bee, port), 10)
                c.sendall(b"e")
                held.append(c)
            for c in held:
                c.sendall(b"x")
                c.recv(1)
            after = private(a.p.pid) + private(b.p.pid)
            print(f"| 500 idle forwarded connections | {(after - before) / 500 / 1024:.1f} KB each, both ends together |")
            for c in held:
                c.close()
        for p in procs:
            p.kill()
            p.wait()
        procs.clear()

    # The public, by TLS through zspd's relay.
    https = free_port()
    relay = Node("mx-relay", "serve", "--no-udp", "--expose=expose.test", "--https=127.0.0.1:%d" % https,
                 "--tls-cert=" + os.path.join(CERTS, "p256.pem"), "--tls-key=" + os.path.join(CERTS, "p256.key")).start()
    from end_to_end import space

    _, (a,) = space("mx", relay=relay)
    ca = a.client()
    web = free_port()
    Service("127.0.0.1", web, says=os.urandom(100 << 20))
    ca.expose(web)
    eventually("exposed", lambda: [r["status"] for e in ca.exposures() for r in e["relays"]] == [0])
    name = ca.exposures()[0]["label"] + ".expose.test"
    public_get(https, name)
    t = time.perf_counter()
    status, body, _ = public_get(https, name)
    took = time.perf_counter() - t
    print(f"| 100 MB exposed, by TLS through zspd's relay | {len(body) / took / 1e6:.0f} MB/s, one core for the relay's TLS |")
    print(f"| the relay, after exposing it | {private(relay.p.pid) >> 10} KB private |")
    for p in procs:
        p.kill()
        p.wait()


def idle_calls(pid, seconds):
    """System calls a process makes in so many seconds, as strace counts them; None where it cannot."""
    if not shutil.which("strace"):
        return None
    sudo = [] if os.geteuid() == 0 or open("/proc/sys/kernel/yama/ptrace_scope").read().strip() == "0" else ["sudo", "-n"]
    p = subprocess.Popen([*sudo, "strace", "-f", "-c", "-p", str(pid)], stderr=subprocess.PIPE, text=True)
    time.sleep(seconds)
    subprocess.run([*sudo, "kill", "-INT", str(p.pid)]) if sudo else p.send_signal(2)
    err = p.communicate()[1]
    for line in err.splitlines():
        if line.strip().endswith("total"):
            return int(line.split()[3])  # % time, seconds, µs a call, calls, [errors], total
    return 0 if "attached" in err else None


if __name__ == "__main__":
    main()
