"""A device, or a relay, run by `zspd`: what the examples share. See docs/scoping.md."""

import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "clients", "python"))
import zsp  # noqa: E402

BIN = os.environ.get("ZSPD") or os.path.join(ROOT, "build", "zspd" + (".exe" if os.name == "nt" else ""))


def zspd(*args):
    return subprocess.run([BIN, *map(str, args)], capture_output=True, text=True, check=True).stdout.strip()


class Device:
    """A directory, with a key of its own in it and a node to run there."""

    running = set()

    def __init__(self, dir, *options):
        self.dir, self.options, self.process = str(dir), options, None
        os.makedirs(self.dir, exist_ok=True)

    @property
    def key(self):
        return zspd("key", self.dir)

    def run(self, mode="run", listen="127.0.0.1:0"):
        self.process = subprocess.Popen(
            [BIN, mode, self.dir, "--listen=" + listen, "--no-udp", *self.options], stdout=subprocess.PIPE, text=True,
            stderr=subprocess.DEVNULL,
        )
        Device.running.add(self)
        self.name, self.address = re.match(r"(\w{64}) listening on ws://(\S+)", self.process.stdout.readline()).groups()
        return self

    def client(self, credential=None, **more):
        with open(os.path.join(self.dir, "token"), "rb") as f:
            return zsp.Client(self.address, credential or f.read(), **more)

    def stop(self):
        if self.process:
            self.process.kill()
            self.process.wait()
            self.process = None
            Device.running.discard(self)
