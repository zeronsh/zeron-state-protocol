"""Names and addresses as every application on this machine has them, once `zspd setup` has been run: real applications,
by name, through the system's own resolver. Run by `./x system`, which sets up and takes it back."""

import os, shutil, socket, subprocess, sys, tempfile, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from end_to_end import Node, Service, zspd, eventually, free_port, lan_address, procs, TMP, http_get

WINDOWS = os.name == "nt"


def run(*argv, user=None, timeout=10):
    if user:
        argv = ("sudo", "-n", "-u", user, *argv)
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def sshd(port):
    """A real SSH server, as this user, at a port of its own: it lets this user in by a key made for the purpose."""
    if WINDOWS or not shutil.which("ssh"):
        return None
    server = shutil.which("sshd") or "/usr/sbin/sshd"
    if not os.path.exists(server):
        return None
    d = tempfile.mkdtemp(prefix="sshd-", dir=TMP)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", d + "/host"], check=True)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", d + "/user"], check=True)
    shutil.copy(d + "/user.pub", d + "/authorized")
    os.chmod(d, 0o700)
    with open(d + "/config", "w") as f:
        f.write(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/host\nAuthorizedKeysFile {d}/authorized\nPidFile {d}/pid\n"
                "PasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\n")
    p = subprocess.Popen([server, "-D", "-e", "-f", d + "/config"], stderr=open(d + "/log", "w"))
    procs.append(p)
    time.sleep(0.5)
    return d


def main():
    relay = Node("sys-relay", "serve", "--no-udp").start()
    a = Node("sys-a", "run", "--no-udp")  # as zspd setup expects: every default
    b = Node("sys-b", "run", "--no-udp", "--loopback=127.88.0", "--dns=127.0.0.1:%d" % free_port(), "--catch=127.0.0.1:0", "--no-proxy")
    c = Node("sys-c", "run", "--no-udp", "--loopback=127.89.0", "--dns=127.0.0.1:%d" % free_port(), "--catch=127.0.0.1:0", "--no-proxy")
    sid = zspd("create", a.dir)
    url = "ws://localhost:" + relay.address.split(":")[1]
    zspd("relay", a.dir, relay.key, url)
    for d, name in ((b, "bee"), (c, "see")):
        zspd("admit", a.dir, zspd("key", d.dir), "1")
        zspd("name", a.dir, zspd("key", d.dir), name)
        zspd("join", d.dir, sid, relay.key, url)
    for d in (a, b, c):
        d.start()
    cb, cc = b.client(), c.client()
    port, quiet = free_port(), free_port()
    Service("127.0.0.1", port, says=b"bee's")
    cb.offer(port, 1)
    keys = sshd(quiet)
    if keys:
        cb.offer(quiet, 1)
    other = lan_address()
    if other:
        Service(other, port, says=b"see's")
        cc.offer(port, 1, host=other)

    # Any application, by name, through the system's own resolver.
    def found(name, address):
        try:
            return socket.gethostbyname(name) == address
        except OSError:
            return False  # not yet: the system remembers that there was none for five seconds

    eventually("the system finds the name", lambda: found("bee.zsp.internal", "127.77.0.3"), timeout=20)
    if shutil.which("curl"):
        eventually("curl reaches it", lambda: run("curl", "-s", "-m", "3", "http://bee.zsp.internal:%d/" % port).stdout == "bee's", timeout=15)
        print(f"ok   curl http://bee.zsp.internal:{port}/")
    assert http_get("bee.zsp.internal", port) == (200, b"bee's")
    print("ok   a socket of Python's, by name")
    if other:
        eventually("and the other, at the same port", lambda: found("see.zsp.internal", "127.77.0.4") and http_get("see.zsp.internal", port) == (200, b"see's"), timeout=20)
        assert http_get("bee.zsp.internal", port) == (200, b"bee's")
        print(f"ok   two devices at port {port}")
    if keys:
        ssh = ("ssh", "-i", keys + "/user", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=" + keys + "/known",
               "-o", "BatchMode=yes", "-p", str(quiet), "bee.zsp.internal", "echo", "hello from the other side")
        eventually("ssh reaches it", lambda: run(*ssh).stdout.strip() == "hello from the other side", timeout=15)
        print("ok   ssh bee.zsp.internal")
    # Nobody else on this machine may borrow what this device may reach.
    if not WINDOWS and run("sudo", "-n", "true").returncode == 0 and shutil.which("curl"):
        theirs = run("curl", "-s", "-m", "3", "-o", "/dev/null", "-w", "%{http_code}", "http://bee.zsp.internal:%d/" % port, user="nobody")
        assert theirs.stdout != "200", theirs
        print("ok   another user is refused")
    # The other way.
    try:
        assert socket.gethostbyaddr("127.77.0.3")[0] == "bee.zsp.internal"
        print("ok   127.77.0.3 is bee.zsp.internal")
    except (socket.herror, AssertionError):
        print("     (this system does not ask about addresses the other way)")


try:
    main()
    print("ok   system")
except BaseException as e:
    import traceback

    traceback.print_exc()
    for log in sorted(f for f in os.listdir(TMP) if f.endswith(".log")):
        with open(os.path.join(TMP, log), errors="replace") as f:
            print("".join(f"     {log}: {line}" for line in f.readlines()[-30:]), end="")
    sys.exit(1)
finally:
    for p in procs:
        p.kill()
        p.wait()
