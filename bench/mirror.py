#!/usr/bin/env python3
"""What structured state costs a client, case by case: python3 bench/mirror.py [luau|ts] [rows...]

Each case runs as a process of its own: with only what leads to it, and with the case itself done n times, three times
each (five in TypeScript, in V8 on one thread). What leads to a case is collected before it (in Luau, which cannot collect
at once, churned until the collector is between rounds, before changes), and perf counts only while the case is done, told when through a
fifo. What the case costs is the difference of the middle ones, in instructions and cycles (perf, where there is one); the
time is measured within the process, the middle of the runs.

Opening is done once, and makes far more than it keeps, so the collector goes round many times while it is done, and what
that costs is in what is counted; the most the process held while it opened, above what it held before, is measured too.

A change is done 200 times (fewer in very long lists, so that what they make stays under a GB), after 3,000 not counted
(600 of those that copy a list of 100,000, and 200 moves heard), so that it is measured as it is once a client has been going a while, compiled
as it will stay and with what opening left let go of. Each is a small part of what is held, so whether the collector
happens to go round while they are done would be most of what is counted, and not the same from one run to the next. So
they are done with the collector kept from going round (in Luau, by a heap made
bigger first with strings it need not look into; in V8, by a young space of a GB), and what is counted is what the client
itself does; what collecting them will cost goes as what they made, which is measured too, in a process of its own that
says whether anything was collected after all.

What the heap holds once the collector has been round after a case, as it is run anywhere, is measured in a process of its
own (in TypeScript with what array buffers hold, which is not in V8's heap, and without code and bytecode, which is
what V8 happens to have compiled by then). Rows are 2,000, 20,000 and 100,000 unless said.

In Luau, where the luau CLI is there too, what a change makes and what the heap holds after a case are measured by it, as
the same bench: it can collect at once, which Lune cannot, so what is made is not less what was collected meanwhile, nor
what is held what churning happened to leave. Its data is put in a module beside it, as the CLI reads no files.
"""

import base64
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
TIMES = 200
QUIET_MB = 1024
ONCE = {"make", "open", "window", "window_rows", "notes_open"}
WHOLE = {"set_change", "update_change", "set_move", "update_move", "heard_move"}  # each copies the whole list
ORDER = ["make", "open", "set_change", "update_change", "set_move", "update_move", "heard_change", "heard_move",
         "window", "window_rows", "notes_open", "typing", "live_heard", "ask"]
SAYS = {
    "make": "made, all at once",
    "open": "opened by another, from what a node sends",
    "set_change": "one changed, by set",
    "update_change": "one changed, by update",
    "set_move": "one moved, by set",
    "update_move": "one moved, by update",
    "heard_change": "one changed by another, heard",
    "heard_move": "one moved by another, heard",
    "window": "a window of plain rows, all of them, opened",
    "window_rows": "the same, every row read",
    "notes_open": "a document with a text in each item, opened",
    "typing": "a character typed in one of those texts",
    "live_heard": "a character typed by another, heard live",
    "ask": "a question of the document, answered and stopped (mirror.ask)",
}


def times(case, rows):
    """How many times a case is done: once to open; 200 changes, fewer where a list is so long they would make a GB."""
    return 1 if case in ONCE else max(20, min(TIMES, 4_000_000 // rows))


def warm(case, rows):
    """How many times a change is done first, not counted: enough that V8 has compiled what it does as it will stay; fewer
    where each copies a list so long that it is all but all in loops compiled at once."""
    if case in ONCE:
        return 0
    if case == "heard_move":
        return 200  # each is heard with the whole of the list's order, longer with every move (MOVES in the bench)
    return 600 if case in WHOLE and rows > 20000 else 3000


def command(lang, rows, case, data, count, mode=None, quiet=False):
    """The command, and what it adds to the environment."""
    env = {"ZSP_WARM": str(warm(case, rows) if count > 0 else 0)}
    if lang == "luau":
        cmd = ["lune", "run", os.path.join(ROOT, "luau/tests/mirror_bench.luau"), str(rows), case, data, str(count)]
        if quiet:
            env["ZSP_QUIET"] = str(QUIET_MB)
    else:
        # One thread, so that what is counted is the client's work and not V8's compiling and collecting beside it.
        cmd = ["node", "--single-threaded", "--expose-gc"]
        if quiet:
            cmd += [f"--min-semi-space-size={QUIET_MB}", f"--max-semi-space-size={QUIET_MB}"]
        cmd += [os.path.join(ROOT, "web/test/mirror_bench.ts"), str(rows), case, data, str(count)]
    if mode:
        cmd.append(mode)
    return cmd, env


def measure(cmd, more=None, counted=True):
    """Instructions and cycles (or None), the most memory held in KB, and what the process printed. What is not counted
    runs without perf, which it would only wait on."""
    perf = shutil.which("perf") if counted else None
    with tempfile.NamedTemporaryFile("r", suffix=".txt") as stat, tempfile.NamedTemporaryFile("r", suffix=".txt") as rss, \
            tempfile.TemporaryDirectory() as fifos:
        full = ["/usr/bin/time", "-f", "%M", "-o", rss.name]
        env = dict(os.environ, **(more or {}))
        if perf:
            # Counting from nothing, and only while the case itself is done: the bench tells perf when, through a fifo.
            ctl, ack = os.path.join(fifos, "ctl"), os.path.join(fifos, "ack")
            os.mkfifo(ctl)
            os.mkfifo(ack)
            env["ZSP_PERF_CTL"], env["ZSP_PERF_ACK"] = ctl, ack
            full += [perf, "stat", "-x,", "-e", "instructions:u,cycles:u", "-D", "-1", f"--control=fifo:{ctl},{ack}",
                     "-o", stat.name]
        out = subprocess.run(full + cmd, capture_output=True, text=True, env=env)
        if out.returncode != 0:
            raise SystemExit(f"{' '.join(cmd)} failed:\n{out.stdout}{out.stderr}")
        counts = {}
        if perf:
            for line in open(stat.name):
                parts = line.strip().split(",")
                if len(parts) > 2 and parts[0].isdigit():
                    counts[parts[2].split(":")[0]] = int(parts[0])
        peak = int(open(rss.name).read().strip().splitlines()[-1])
    return counts.get("instructions"), counts.get("cycles"), peak, out.stdout


def middle(values):
    values = [v for v in values if v is not None]
    return sorted(values)[len(values) // 2] if values else None


def said(text, name):
    for line in text.splitlines():
        words = line.split()
        for i, w in enumerate(words[:-1]):
            if w == name:
                return float(words[i + 1])
    return None


LUAU_CLI = '''local B64 = {}
do
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for k = 1, 64 do
		B64[string.byte(chars, k)] = k - 1
	end
end
local function unb64(s: string): string
	local n = #s
	local pad = (if string.byte(s, n) == 61 then 1 else 0) + (if string.byte(s, n - 1) == 61 then 1 else 0)
	local out = buffer.create(n // 4 * 3 - pad)
	local o = 0
	for i = 1, n, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local v = B64[a] * 262144 + B64[b] * 4096 + (B64[c] or 0) * 64 + (B64[d] or 0)
		buffer.writeu8(out, o, v // 65536)
		o += 1
		if c ~= 61 then
			buffer.writeu8(out, o, (v // 256) % 256)
			o += 1
		end
		if d ~= 61 then
			buffer.writeu8(out, o, v % 256)
			o += 1
		end
	end
	return buffer.tostring(out)
end
local ARGS = { ... }
local fs = { readFile = function(_: string): string return unb64(require("./mirror-cli-data") :: any) end, writeFile = function(...) end }
local process = { args = ARGS, env = { ZSP_WARM = ARGS[6], ZSP_QUIET = ARGS[7] } }
local task = { wait = function(...) end }
'''


def luau_cli(rows, case, data, count, mode, quiet_mb):
    """What the bench prints of a case run by the luau CLI (see above), or None where there is none."""
    luau = shutil.which("luau")
    if not luau:
        return None
    build = os.path.join(ROOT, "build")
    script, module = os.path.join(build, "mirror-cli.luau"), os.path.join(build, "mirror-cli-data.luau")
    s = open(os.path.join(ROOT, "luau/tests/mirror_bench.luau")).read()
    for a, b in [('require("../zsp/codec")', 'require("../luau/zsp/codec")'), ('require("../zsp")', 'require("../luau/zsp")'),
                 ('local fs = require("@lune/fs")\n', ''), ('local process = require("@lune/process")\n', ''),
                 ('local task = require("@lune/task")\n', LUAU_CLI),
                 ("\t\tpaused()\n\t\tpaused()\n", '\t\tcollectgarbage("collect") -- at once, as the luau CLI can\n\t\tcollectgarbage("collect")\n'),
                 ("local function settled(): number\n",
                  'local function settled(): number\n\tdo\n\t\tcollectgarbage("collect") -- exactly, as the luau CLI can\n'
                  '\t\tcollectgarbage("collect")\n\t\treturn collectgarbage("count")\n\tend\n')]:
        assert s.count(a) == 1, a
        s = s.replace(a, b)
    open(script, "w").write(s)
    stamp = f"-- {data} {os.path.getmtime(data)}\n"
    if not os.path.exists(module) or open(module).readline() != stamp:
        with open(data, "rb") as f:
            open(module, "w").write(stamp + 'return "' + base64.b64encode(f.read()).decode() + '"\n')
    out = subprocess.run([luau, script, "-a", str(rows), case, "x", str(count), mode, str(warm(case, rows) if count > 0 else 0),
                          str(quiet_mb)], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"luau {script} {rows} {case} failed:\n{out.stdout}{out.stderr}")
    return out.stdout


def luau_exact(rows, case, data, n):
    """What a change makes, and whether anything was collected meanwhile, with a heap made bigger by a GB, or by 2.5 GB
    where that was not enough; and what the heap holds after the case. None where there is no luau CLI."""
    if not shutil.which("luau"):
        return None
    made = collected = None
    if case not in ONCE:
        for quiet_mb in (QUIET_MB, 2560):
            alloc = luau_cli(rows, case, data, n, "alloc", quiet_mb)
            made, collected = said(alloc, "alloc_kb"), said(alloc, "collected")
            if not collected:
                break
    held = said(luau_cli(rows, case, data, n, "memory", QUIET_MB), "heap_kb")
    return made, collected, held


def main():
    args = sys.argv[1:]
    lang = "luau"
    if args and args[0] in ("luau", "ts"):
        lang = args.pop(0)
    sizes = [int(a) for a in args] or [2000, 20000, 100000]
    os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
    print(f"| {lang} | rows | times | ms each | instructions each | cycles each | most held while (KB) | made each (KB) "
          f"| heap after (KB) | per row (B) |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    for rows in sizes:
        data = os.path.join(ROOT, "build", f"mirror-bench-{rows}.bin")
        if not os.path.exists(data):
            # Made by the Luau writers: the same bytes for both clients, which read each other's writing.
            subprocess.run(["lune", "run", os.path.join(ROOT, "luau/tests/mirror_bench.luau"), str(rows), "prep", data], check=True)
        for case in ORDER:
            n = times(case, rows)
            quiet = case not in ONCE
            runs = 5 if lang == "ts" else 3  # V8's numbers wander more
            base = [measure(*command(lang, rows, case, data, 0, quiet=quiet)) for _ in range(runs)]
            done = [measure(*command(lang, rows, case, data, n, quiet=quiet)) for _ in range(runs)]
            _, _, _, mem = measure(*command(lang, rows, case, data, n, "memory"), counted=False)
            seconds = middle([said(r[3], "seconds") for r in done])
            heap = said(mem, "heap_kb")
            exact = luau_exact(rows, case, data, n) if lang == "luau" else None
            if exact:
                heap = exact[2]

            def each(k):
                a, b = middle([r[k] for r in base]), middle([r[k] for r in done])
                return f"{(b - a) / n:,.0f}" if a is not None and b is not None else "-"

            peak, made = "", ""
            if quiet:
                if exact:
                    alloc_kb, collected = exact[0], exact[1]
                else:
                    _, _, _, alloc = measure(*command(lang, rows, case, data, n, "alloc", quiet=True), counted=False)
                    alloc_kb, collected = said(alloc, "alloc_kb"), said(alloc, "collected")
                made = f"{alloc_kb / n:,.1f}"
                if collected:
                    made += " (collected)"  # the young space or the heap was not big enough: what is counted is not alone
            else:
                peak = f"{max(middle([r[2] for r in done]) - middle([r[2] for r in base]), 0):,}"
            per_row = f"{heap * 1024 / rows:,.0f}" if case in ("open", "window", "window_rows", "notes_open") else ""
            print(f"| {SAYS[case]} | {rows:,} | {n} | {seconds * 1000 / n:.3f} | {each(0)} | {each(1)} | {peak} | {made} "
                  f"| {heap:,.0f} | {per_row} |", flush=True)


if __name__ == "__main__":
    main()
