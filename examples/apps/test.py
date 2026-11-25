"""Applications on one machine, each with its own scopes: python3 examples/apps/test.py"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
from zspd import ROOT, zsp, zspd  # noqa: E402

APPS = os.path.join(ROOT, "build", "apps" + (".exe" if os.name == "nt" else ""))


def main(dir):
    zspd("create", dir)  # scope 1
    zspd("scope", dir)  # and 2
    zspd("scope", dir, "signed")  # and 3, where it is told who wrote what
    zspd("admit", dir, zspd("key", dir), "3", "vouch")  # this device knows its users, and is believed
    secrets = {name: os.urandom(16).hex() for name in ("notes", "dashboard", "zoe", "max", "nobody")}
    with open(os.path.join(dir, "apps"), "w") as f:
        f.write(f"{secrets['notes']} 1:rwc 2:rw\n{secrets['dashboard']} 1:r\n")
        f.write(f"{secrets['zoe']} 3:rwc as=zoe\n{secrets['max']} 3:rwc as=max\n")
    node = subprocess.Popen([APPS, dir], stdout=subprocess.PIPE, text=True)
    try:
        address = re.match(r"\w{64} listening on ws://(\S+)", node.stdout.readline())[1]
        notes = zsp.Client(address, secrets["notes"].encode())
        dashboard = zsp.Client(address, secrets["dashboard"].encode())
        notes.put(1, "notes", 1, [b"shared"])
        notes.put(2, "notes", 1, [b"private"])
        notes.until(lambda: notes.acked == notes.seq)
        # One reads what it may, and is not given what it may not.
        dashboard.watch(1, 1, "notes")
        dashboard.until(lambda: len(dashboard.list(1, "notes")) == 1)
        assert set(dashboard.scopes) == {1}
        dashboard.ask(1, 2)
        dashboard.until(lambda: dashboard.answers.get(1, {}).get("denied"))
        try:
            dashboard.put(1, "notes", 2, [b"not for it to write"])
            dashboard.until(lambda: dashboard.acked == dashboard.seq)
            raise AssertionError("it wrote")
        except (PermissionError, ConnectionError):
            pass
        assert notes.fetch(1)["total"] == 1
        # Two people of the one device: what each writes is theirs, to whoever reads it, and cannot be had otherwise.
        zoe = zsp.Client(address, secrets["zoe"].encode(), authors=True)
        max_ = zsp.Client(address, secrets["max"].encode(), authors=True)
        hers, his = zoe.put(3, "talk", 1, [b"hello"]), max_.put(3, "talk", 2, [b"hello yourself"])
        for c in (zoe, max_):
            c.watch(1, 3, "talk")
            c.until(lambda: len(c.list(3, "talk")) == 2 and c.author(hers, 16) and c.author(his, 16))
            assert c.author(hers, 16)[1] == b"zoe" and c.author(his, 16)[1] == b"max"
        assert zoe.authors[0][1] == b"zoe"
        assert zoe.fetch(3, zsp.equals(zsp.column(zsp.OF, 16), "max"))["rows"] == [his]
        assert [(n, v) for n, v in max_.fetch(3, totals=[(zsp.FACET, zsp.column(zsp.OF, 16), 10)])["totals"][0][1]] == [(1, b"max"), (1, b"zoe")]
        max_.serve(3, "whoami", lambda device, data: max_.caller)
        max_.drain(0.2)
        zoe.next_call += 1
        zoe.calls[zoe.next_call] = {"data": [], "ended": False, "fault": None}
        zoe.send(zsp.CALL, zsp.varint(zoe.next_call) + zoe.authors[0][0] + zsp.varint(3) + zsp.put_bytes(b"whoami") + zsp.put_bytes(b"the president"))
        max_.until(lambda: max_.caller is not None)
        zoe.until(lambda: zoe.calls[zoe.next_call]["data"])
        assert zoe.calls[zoe.next_call]["data"] == [b"zoe"]
        try:
            zsp.Client(address, secrets["nobody"].encode())
            raise AssertionError("anyone may")
        except (PermissionError, ConnectionError, AssertionError) as e:
            assert "anyone" not in str(e)
    finally:
        node.kill()
        node.wait()


if __name__ == "__main__":
    dir = tempfile.mkdtemp(prefix="zsp-apps-")
    try:
        main(dir)
        print("ok")
    finally:
        shutil.rmtree(dir, ignore_errors=True)
