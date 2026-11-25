"""A company: one space, with a scope for everyone, one for a team, announcements that few may write, a guest, and
someone who leaves. Run it: python3 examples/organization.py. Each step says what holds, and it is checked.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import time

import directory
from zspd import ROOT, Device, zspd

EVERYONE, ENGINEERING, NEWS, ANN = 1, 2, 3, 4  # scopes


def say(text):
    print("  " + text)


def put(client, scope, name, text):
    row = client.put(scope, name, 1, [text.encode()])
    client.until(lambda: client.acked == client.seq)
    return row


def sees(client, scope, name, text):
    """Whether a row with that text reaches a client."""
    which = client.watches = getattr(client, "watches", 0) + 1
    client.watch(which, scope, name)
    try:
        client.until(lambda: any(v.get(16) == text.encode() for _, _, v in client.list(scope, name)), 5)
        return True
    except TimeoutError:
        return False


def denied(client, scope):
    """Whether a client may not so much as ask."""
    which = client.asks = getattr(client, "asks", 100) + 1
    client.ask(which, scope)
    client.until(lambda: which in client.answers)
    return bool(client.answers[which].get("denied"))


def main(work):
    devices = {name: Device(os.path.join(work, name)) for name in ("office", "server", "ann-laptop", "ann-phone", "bob", "hana", "guest")}
    office, server = devices["office"], devices["server"]
    relay = Device(os.path.join(work, "relay")).run("serve")

    # The company is a space. The device that makes it owns it, so make it somewhere safe.
    space = zspd("create", office.dir)  # with a first scope: everyone
    zspd("scope", office.dir)  # engineering
    zspd("scope", office.dir, "signed")  # news, which most may only read
    zspd("scope", office.dir)  # Ann's own
    zspd("relay", office.dir, relay.name, "ws://" + relay.address)

    # Day to day it is run by a server, which may be replaced, and not by the device that owns it.
    zspd("admin", office.dir, server.key)
    zspd("join", server.dir, space, relay.name, "ws://" + relay.address)
    office.run()
    server.run()
    roster = os.path.join(server.dir, space, "roster")
    while not os.path.exists(roster):
        time.sleep(0.01)

    # Who may do what is kept as your directory of people has it.
    people = {
        "scopes": {
            str(EVERYONE): {"write": ["everyone"]},
            str(ENGINEERING): {"write": ["engineering", "guest"]},
            str(NEWS): {"read": ["everyone"], "write": ["hr"]},
            str(ANN): {"write": ["ann"]},
        },
        "teams": {"engineering": ["ann"], "hr": ["hana"]},
        "people": {
            "ann": [devices["ann-laptop"].key, devices["ann-phone"].key],
            "bob": [devices["bob"].key],
            "hana": [devices["hana"].key],
        },
    }
    directory.sync(server.dir, people)
    assert directory.sync(server.dir, people) == []
    for name, device in devices.items():
        if device not in (office, server):
            zspd("join", device.dir, space, relay.name, "ws://" + relay.address)
            device.run()
    ann, phone, bob, hana, boss = (devices[n].client() for n in ("ann-laptop", "ann-phone", "bob", "hana", "office"))

    put(bob, EVERYONE, "chat", "hello, all")
    assert sees(ann, EVERYONE, "chat", "hello, all") and sees(hana, EVERYONE, "chat", "hello, all")
    say("what Bob says in the company's scope reaches everyone")

    put(ann, ENGINEERING, "plans", "ship it")
    assert sees(phone, ENGINEERING, "plans", "ship it")
    say("what Ann writes for engineering reaches her other device, for both are hers")
    assert denied(bob, ENGINEERING)
    say("Bob is not an engineer: his device has no key to it, and is sent none of it")

    put(ann, ANN, "diary", "a bad day")
    assert sees(phone, ANN, "diary", "a bad day") and denied(hana, ANN)
    say("Ann's own scope is on her devices; nobody else's")
    assert sees(boss, ANN, "diary", "a bad day")
    say("but for the owner's, who holds every scope: what is to be hers alone belongs in a space she owns")

    put(hana, NEWS, "news", "new coffee")
    assert sees(bob, NEWS, "news", "new coffee")
    try:
        bob.put(NEWS, "news", 2, [b"free lunch"])
        bob.until(lambda: bob.acked == bob.seq, 5)
        raise AssertionError("Bob wrote the news")
    except (PermissionError, ConnectionError, OSError):
        pass
    assert not sees(ann, NEWS, "news", "free lunch")
    say("all may read the news, and only HR write it: every replica checks who signed")

    # A guest has one scope, and the rest of the company is not there.
    people["people"]["guest"] = [devices["guest"].key]
    people["scopes"][str(EVERYONE)] = {"write": ["ann", "bob", "hana"]}
    people["scopes"][str(NEWS)] = {"read": ["ann", "bob"], "write": ["hr"]}
    directory.sync(server.dir, people)
    guest = devices["guest"].client()
    guest.until(lambda: ENGINEERING in guest.scopes, 10)
    assert sees(guest, ENGINEERING, "plans", "ship it") and denied(guest, EVERYONE)
    say("a guest reads what engineering has written, and nothing else is there for them")

    # Ann leaves. Her devices give up their keys when they hear of it, and can open nothing written after. (What she has
    # already read, she has read: nothing can take that back.)
    people["people"].pop("ann")
    people["scopes"][str(EVERYONE)] = {"write": ["bob", "hana"]}
    people["scopes"][str(NEWS)] = {"read": ["bob"], "write": ["hr"]}
    people["scopes"].pop(str(ANN))
    people["teams"]["engineering"] = []
    did = directory.sync(server.dir, people)
    assert {step[0] for step in did} == {"revoke"}
    put(guest, ENGINEERING, "plans", "after Ann")
    assert sees(boss, ENGINEERING, "plans", "after Ann")
    fresh = devices["ann-laptop"].client()
    assert denied(fresh, ENGINEERING) and denied(fresh, EVERYONE)
    say("Ann has left: her devices may read nothing, and the scopes she had have new keys")

    # An application in Luau, which names its scopes once and cannot then mistake them.
    if shutil.which("lune"):
        with open(os.path.join(devices["bob"].dir, "token")) as f:
            token = f.read()
        script = os.path.join(ROOT, "examples", "luau", "main.luau")
        subprocess.run(["lune", "run", script, devices["bob"].address, token], check=True, timeout=60)


if __name__ == "__main__":
    work = tempfile.mkdtemp(prefix="zsp-organization-")
    try:
        main(work)
        print("ok")
    finally:
        for device in list(Device.running):
            device.stop()
        shutil.rmtree(work, ignore_errors=True)
        sys.stdout.flush()
