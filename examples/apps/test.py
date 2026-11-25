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
    secrets = {name: os.urandom(16).hex() for name in ("notes", "dashboard", "nobody")}
    with open(os.path.join(dir, "apps"), "w") as f:
        f.write(f"{secrets['notes']} 1:rwc 2:rw\n{secrets['dashboard']} 1:r\n")
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
