"""Keeps who may do what in a space the same as your own directory of people says it should be.

Run it on a device that is an admin of the space, whenever the directory changes: it does only what differs, so it may be
run as often as you like. What it is given is yours: here, people with devices, teams of people, and scopes that say
which teams may read or write them.

    {
      "scopes": {"1": {"write": ["everyone"]}, "3": {"read": ["everyone"], "write": ["hr"], "vouch": ["website"]}},
      "teams":  {"hr": ["hana"]},
      "people": {"hana": ["<key>"], "ann": ["<key>", "<key>"], "website": ["<key>"]}
    }

A scope that some may only read has to be a signed one: `zspd scope <dir> signed`. Who may vouch writes for people who sign in
to it, and is believed about who they are.
"""

import json
import sys

from zspd import zspd

EVERYONE = "everyone"


def members(dir):
    """What the space says now: key -> (subject, {scope: "r", "w" or "v"}, whether it rules)."""
    found = {}
    for line in zspd("members", dir).splitlines():
        rest, _, subject = line.partition("\t")
        key, *words = rest.split()
        rights = {}
        for word in words:
            scope, colon, what = word.partition(":")
            if colon:
                rights[scope] = "v" if "v" in what else "w" if "w" in what else "r"
        found[key] = (subject, rights, words[-1:] in (["owner"], ["admin"]))
    return found


def wanted(directory):
    """What it should say: key -> (subject, {scope: "r", "w" or "v"})."""
    teams = {EVERYONE: list(directory["people"]), **directory.get("teams", {})}
    want = {}
    for person, devices in directory["people"].items():
        rights = {}
        for scope, rule in directory["scopes"].items():
            for right, who in (("r", rule.get("read", [])), ("w", rule.get("write", [])), ("v", rule.get("vouch", []))):
                if any(person == name or person in teams.get(name, []) for name in who):
                    rights[scope] = right
        for key in devices:
            want[key] = (person, rights)
    return want


def sync(dir, directory):
    """Makes it so. Says what it did."""
    have, want, did = members(dir), wanted(directory), []
    for key, (subject, rights, rules) in have.items():
        if rules:
            continue  # those who run the space hold all of it, and are not this script's to remove
        for scope in rights:
            if scope not in want.get(key, ("", {}))[1]:
                did.append(("revoke", key, scope))  # and the scope has a new key, which this device is not given
    for key, (person, rights) in want.items():
        subject, held, rules = have.get(key, ("", {}, False))
        if rules:
            continue
        for scope, right in rights.items():
            if held.get(scope) != right:
                did.append(("admit", key, scope, *{"r": ["read"], "w": [], "v": ["vouch"]}[right]))
        if subject != person and rights:
            did.append(("subject", key, person))
    for command, *args in did:
        zspd(command, dir, *args)
    return did


if __name__ == "__main__":
    with open(sys.argv[2]) as f:
        for step in sync(sys.argv[1], json.load(f)):
            print(*step)
