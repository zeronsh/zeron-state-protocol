"""What `./x check` holds every .odin file here to, outside node_modules: no use of what odin-lang/Odin#8642 or #8646
breaks.

#8642. 
The runtime's `__dynamic_map_entry` (`map_entry`) can give back the slot of another key, and the pointer an insertion
gives back (`map_insert`, `map_upsert`) can be to it too: what is written through it lands on another key. Inserting
itself is sound (`m[k] = v`, or `map_insert` with its pointer let go of), as is looking up. So this fails on:

- `map_entry`, or the runtime's own `__dynamic_map_entry` and `__dynamic_map_set*`, named at all;
- the pointer `map_insert` or `map_upsert` gives back, kept or used: each is to be called as a statement, or with that
  result assigned to `_`; and neither may be named but to call it, as `alias :: map_insert` would hide it;
- what of core uses them: `core:strings`'s `Intern` and `intern_*`; `core:os` in a file built for WASI (its environment
  is kept with `map_entry`); `core:net`'s `enumerate_interfaces` in a file built for macOS, OpenBSD or NetBSD;
  `core:nbio` (third_party/nbio is the copy to use, until #8642, #8644, #8645 and #8647 are fixed in a
  release);
  `core:text/i18n` (it interns); `core:container/topological_sort` (it keeps `map_insert`'s pointer).

#8646. On Windows, core:os opens a file with `.Trunc` but not `.Create` asking TRUNCATE_EXISTING with FILE_GENERIC_WRITE,
which Windows refuses as an invalid parameter (87), wanting GENERIC_WRITE itself. So in a file that imports `core:os`
and is built for Windows, `.Trunc` or `O_TRUNC` fails unless `.Create` or `O_CREATE` is with it: in the same set
(`{.Write, .Create, .Trunc}`), or, outside a set, in the same line (`os.O_RDWR + os.O_CREATE + os.O_TRUNC`). A set or
`.Trunc` only asked of (`.Trunc in flags`, `flags & {.Trunc} == {.Trunc}`) builds nothing, and passes. Flags it cannot
see the type of are taken for core:os's, so a file that imports it holds every `.Trunc` to this.

Formatting is no way round it: comments and strings are taken out, and what is left is read as tokens. Each import is
followed by the name it is given. A file is taken as built for an OS unless its name or `#+build` lines say it is not;
a package as built for WASI if a command here builds it so (`-target:wasi_...` in ./x or a workflow), with what it
imports from here. The one exception is the repros in tests/upstream, there to use what is broken: each file there that
says at its head which of the issues it reproduces ("Reproduces odin-lang/Odin#...").

    python3 tests/odin_lint.py [root]   says each use, and fails if there is any
    python3 tests/odin_lint.py --selftest   that it finds each use put in its fixtures, however written, and no other
"""

import os, re, sys, tempfile

ISSUE = "odin-lang/Odin#8642"
TRUNC_ISSUE = "odin-lang/Odin#8646"
OSES = {"windows", "darwin", "linux", "essence", "freebsd", "openbsd", "netbsd", "haiku", "wasi", "js", "orca", "freestanding"}
ARCHES = {"amd64", "i386", "arm32", "arm64", "wasm32", "wasm64p32", "riscv64"}
BSDS = {"darwin", "openbsd", "netbsd"}  # core:net's enumerate_interfaces gathers with map_entry on these
BANNED_IMPORTS = {
    "core:nbio": "core:nbio: import third_party/nbio, the copy fixed of it, until #8642, #8644, #8645 and #8647 are fixed in a release",
    "core:text/i18n": "core:text/i18n interns its strings with strings.Intern, which uses map_entry",
    "core:container/topological_sort": "core:container/topological_sort writes through map_insert's pointer",
}


def tokens(src):
    """(kind, text, line) for each token of Odin source, comments and whitespace taken out; strings kept as one token,
    their text what is between the quotes."""
    out, i, line, n = [], 0, 1, len(src)
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
        elif c in " \t\r\f\v":
            i += 1
        elif src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):  # they nest
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif src.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    line += src[i] == "\n"
                    i += 1
        elif c in "\"'":
            j, start = i + 1, line
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            out.append(("string" if c == '"' else "rune", src[i + 1 : j], start))
            i = j + 1
        elif c == "`":
            j = src.find("`", i + 1)
            j = n if j < 0 else j
            out.append(("string", src[i + 1 : j], line))
            line += src.count("\n", i, j)
            i = j + 1
        elif c.isalpha() or c == "_":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"):
                j += 1
            out.append(("ident", src[i:j], line))
            i = j
        elif c.isdigit():
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] in "_."):
                j += 1
            out.append(("number", src[i:j], line))
            i = j
        else:
            for p in ("::", ":=", "..=", "..<", "->", "+=", "-=", "==", "!=", "<=", ">="):
                if src.startswith(p, i):
                    out.append(("punct", p, line))
                    i += len(p)
                    break
            else:
                out.append(("punct", c, line))
                i += 1
    return out


def admits(path, src):
    """The set of OSes a file is built for, of its name and its `#+build` lines (each line one condition, all of which
    must hold; in a line, terms separated by commas, any of which may; a term an OS, an arch, or both, `!` before it
    to be not that)."""
    oses = set(OSES)
    parts = os.path.basename(path)[: -len(".odin")].split("_")
    if len(parts) >= 3 and parts[-2] in OSES and parts[-1] in ARCHES:
        oses &= {parts[-2]}
    elif len(parts) >= 2 and parts[-1] in OSES:
        oses &= {parts[-1]}
    for raw in src.splitlines():
        s = raw.strip()
        if s.startswith("package "):
            break
        m = re.match(r"#\+build\s+(.*)", s)
        if not m:
            continue
        line_oses = set()
        for term in m.group(1).split(","):
            words = term.split()
            if not words:
                continue
            if words[0] == "ignore":
                return set()
            neg = words[0].startswith("!")
            names = [w.lstrip("!") for w in words]
            term_os = [w for w in names if w in OSES]
            if neg:  # not this OS (or arch): every OS but it may be
                line_oses |= OSES - set(term_os) if term_os else set(OSES)
            else:
                line_oses |= set(term_os) if term_os else set(OSES)
        oses &= line_oses
    return oses


def explicitly(path, src, os_name):
    """Whether a file is meant for that OS by name: its name ends in it, or a `#+build` line names it, not negated."""
    parts = os.path.basename(path)[: -len(".odin")].split("_")
    if len(parts) >= 2 and (parts[-1] == os_name or (len(parts) >= 3 and parts[-2] == os_name and parts[-1] in ARCHES)):
        return True
    for raw in src.splitlines():
        m = re.match(r"\s*#\+build\s+(.*)", raw)
        if m and any(os_name in t.split() for t in m.group(1).split(",")):
            return True
    return False


def imports(toks):
    """{name: path} of a file's imports, each by the name it is given, or the last part of its path."""
    out, i = {}, 0
    while i < len(toks):
        if toks[i][1] == "import" and toks[i][0] == "ident":
            j = i + 1
            if toks[j][1] == "(":  # import ( a "x"  "y" )
                j += 1
                while j < len(toks) and toks[j][1] != ")":
                    alias = None
                    if toks[j][0] == "ident":
                        alias, j = toks[j][1], j + 1
                    if toks[j][0] == "string":
                        p = toks[j][1]
                        out[alias or re.split(r"[:/]", p)[-1]] = p
                    j += 1
            else:
                alias = None
                if toks[j][0] == "ident":
                    alias, j = toks[j][1], j + 1
                if j < len(toks) and toks[j][0] == "string":
                    p = toks[j][1]
                    out[alias or re.split(r"[:/]", p)[-1]] = p
            i = j
        i += 1
    return out


def matching(toks, i):
    """The index of the `)` that closes the `(` at i."""
    depth = 0
    for j in range(i, len(toks)):
        if toks[j][1] in "([{" and toks[j][0] == "punct":
            depth += 1
        elif toks[j][1] in ")]}" and toks[j][0] == "punct":
            depth -= 1
            if depth == 0:
                return j
    return len(toks) - 1


STATEMENT_START = {";", "{", "}", "defer", "if", "for", "switch", "when", "do", "else"}
CONTINUES = {",", "(", "[", "=", ":=", "+", "-", "*", "/", "%", "&", "|", "~", "<", ">", "!", "^", ".", "->", "?", ":", "::", "==", "!=", "<=", ">=", "&&", "||", "or_else", "or_return", "return", "in", "not_in"}


def starts_statement(toks, i):
    """Whether the token at i begins a statement: after one that cannot go on into it."""
    if i == 0:
        return True
    prev = toks[i - 1]
    if prev[1] in STATEMENT_START:
        return True
    return prev[2] < toks[i][2] and prev[1] not in CONTINUES


def ends_statement(toks, j):
    """Whether the statement ends after the token at j (perhaps with or_return)."""
    k = j + 1
    if k < len(toks) and toks[k][1] == "or_return":
        k += 1
    if k >= len(toks):
        return True
    nxt = toks[k]
    if nxt[1] in (";", "}"):
        return True
    return nxt[2] > toks[k - 1][2] and nxt[1] not in CONTINUES and nxt[1] not in (".", "^", "[", "(")


def pointer_let_go(toks, i, at):
    """Whether the call whose name is the token at i, ending at the token at `at`, gives back its pointer only to be let
    go of: called as a statement, or assigned with the pointer's place `_`. map_insert gives the pointer first,
    map_upsert second."""
    name = toks[i][1]
    start = i
    if start >= 2 and toks[start - 1][1] == "." and toks[start - 2][0] == "ident":  # runtime.map_insert
        start -= 2
    if not ends_statement(toks, at):
        return False
    if starts_statement(toks, start):
        return True
    if toks[start - 1][1] not in ("=", ":="):
        return False
    # The names assigned, back to where the statement starts.
    lhs, k = [], start - 2
    while k >= 0:
        if toks[k][0] != "ident":
            return False
        lhs.insert(0, toks[k][1])
        if starts_statement(toks, k):
            break
        if toks[k - 1][1] != ",":
            return False
        k -= 2
    place = 0 if name == "map_insert" else 1
    return len(lhs) > place and lhs[place] == "_"


def trunc_uses(toks):
    """The lines on which `.Trunc` or `O_TRUNC` is given without `.Create` or `O_CREATE` (see #8646 above)."""
    # Each `{` with its `}`, and whether what is between is a set: its elements, at its own depth, on a line of their own
    # only after a comma.
    close, stack = {}, []
    for i, (kind, text, _) in enumerate(toks):
        if kind == "punct" and text == "{":
            stack.append(i)
        elif kind == "punct" and text == "}" and stack:
            close[stack.pop()] = i

    def is_set(o):
        depth, prev = 0, toks[o]
        for k in range(o + 1, close[o]):
            t = toks[k]
            if depth == 0 and t[2] > prev[2] and prev[1] not in (",", "{"):
                return False
            if t[0] == "punct" and t[1] in "([{":
                depth += 1
            elif t[0] == "punct" and t[1] in ")]}":
                depth -= 1
            if depth == 0:
                prev = t
        return True

    def creates(ts):
        return any(t[0] == "ident" and t[1] in ("Create", "O_CREATE") for t in ts)

    found = []
    for i, (kind, text, line) in enumerate(toks):
        if kind != "ident" or text not in ("Trunc", "O_TRUNC"):
            continue
        if text == "Trunc" and (i == 0 or toks[i - 1][1] != "."):
            continue  # a name of another's, not the flag
        # The innermost set it is in, if any.
        inner = None
        for o in close:
            if o < i < close[o] and is_set(o) and (inner is None or o > inner):
                inner = o
        if inner is not None:
            group = toks[inner + 1 : close[inner]]
            asked = toks[inner - 1][1] in ("&", "==", "!=", "<=", ">=", "<", ">") or (
                close[inner] + 1 < len(toks) and toks[close[inner] + 1][1] in ("==", "!=", "&", "<=", ">=", "<", ">", "in", "not_in")
            )
            if not asked and not creates(group):
                found.append(line)
        else:
            if i + 1 < len(toks) and toks[i + 1][1] in ("in", "not_in"):
                continue
            if not creates(t for t in toks if t[2] == line):
                found.append(line)
    return found


def lint_file(path, src, wasi_built):
    """Each use in a file, as (line, what, issue)."""
    toks = tokens(src)
    found = []
    named = imports(toks)
    by_path = {}
    for alias, p in named.items():
        by_path.setdefault(p, []).append(alias)
    oses = admits(path, src)
    for p, why in BANNED_IMPORTS.items():
        if p in by_path:
            line = next(t[2] for t in toks if t[0] == "string" and t[1] == p)
            found.append((line, why, ISSUE))
    if "core:os" in by_path and "wasi" in oses and (wasi_built or explicitly(path, src, "wasi")):
        line = next(t[2] for t in toks if t[0] == "string" and t[1] == "core:os")
        found.append((line, "core:os in a file built for WASI: its environment is kept with map_entry", ISSUE))
    strings_names = set(by_path.get("core:strings", []))
    net_names = set(by_path.get("core:net", [])) if oses & BSDS else set()
    for i, (kind, text, line) in enumerate(toks):
        if kind != "ident":
            continue
        if text in ("map_entry", "__dynamic_map_entry") or text.startswith("__dynamic_map_set"):
            found.append((line, f"{text}: it can give back another key's slot", ISSUE))
        elif text in ("map_insert", "map_upsert"):
            if i + 1 >= len(toks) or toks[i + 1][1] != "(":
                found.append((line, f"{text} named but to call it: the pointer it gives back is not to be had", ISSUE))
            elif not pointer_let_go(toks, i, matching(toks, i + 1)):
                found.append((line, f"{text}'s pointer kept or used: it may be another key's; call it as a statement, or assign that result to _", ISSUE))
        elif i >= 2 and toks[i - 1][1] == "." and toks[i - 2][0] == "ident":
            owner = toks[i - 2][1]
            if owner in strings_names and (text == "Intern" or text.startswith("intern_")):
                found.append((line, f"strings.{text}: interning uses map_entry", ISSUE))
            elif owner in net_names and text == "enumerate_interfaces":
                found.append((line, "net.enumerate_interfaces in a file built for macOS, OpenBSD or NetBSD: it gathers with map_entry there", ISSUE))
    if "windows" in oses:
        if "core:os" in by_path:
            for line in trunc_uses(toks):
                found.append((line, ".Trunc without .Create, in a file built for Windows that imports core:os: core:os's open fails so with error 87 there", TRUNC_ISSUE))
    return found


def wasi_packages(root):
    """The package directories some command here builds for WASI, and what they import from here, all the way down."""
    texts = []
    places = [os.path.join(root, "x")]
    workflows = os.path.join(root, ".github", "workflows")
    if os.path.isdir(workflows):
        places += [os.path.join(workflows, f) for f in sorted(os.listdir(workflows))]
    for p in places:
        if os.path.isfile(p):
            with open(p, encoding="utf-8", errors="replace") as f:
                texts.append(f.read())
    todo = set()
    for text in texts:
        for line in text.splitlines():
            if "-target:wasi" in line:
                for m in re.finditer(r"odin\s+(?:build|check|test|run)\s+(\S+)", line):
                    todo.add(os.path.normpath(os.path.join(root, m.group(1))))
    seen = set()
    while todo:
        d = todo.pop()
        if d in seen or not os.path.isdir(d):
            continue
        seen.add(d)
        for name in os.listdir(d):
            if name.endswith(".odin"):
                with open(os.path.join(d, name), encoding="utf-8", errors="replace") as f:
                    for p in imports(tokens(f.read())).values():
                        if p.startswith("."):
                            todo.add(os.path.normpath(os.path.join(d, p)))
    return seen


def is_repro(rel, src):
    """Whether a file is one of the repros of what is broken, which must use it: in tests/upstream, and saying so in its
    first line."""
    parts = rel.replace(os.sep, "/").split("/")
    return parts[:2] == ["tests", "upstream"] and re.match(r"// Reproduces odin-lang/Odin#\d+", src) is not None


def lint(root):
    """Each use under root, as (path, line, what, issue)."""
    wasi = wasi_packages(root)
    out = []
    for d, dirs, files in os.walk(root):
        dirs[:] = sorted(x for x in dirs if x not in ("node_modules", ".git"))
        for name in sorted(files):
            if name.endswith(".odin"):
                path = os.path.join(d, name)
                with open(path, encoding="utf-8", errors="replace") as f:
                    src = f.read()
                if is_repro(os.path.relpath(path, root), src):
                    continue
                for line, what, issue in lint_file(path, src, os.path.normpath(d) in wasi):
                    out.append((os.path.relpath(path, root), line, what, issue))
    return out


# Each fixture: a file, and the lines on which it must be found to use what is broken (marked `// use`).
FIXTURES = {
    "x": "odin build wasm_pkg -target:wasi_wasm32 -out:build/w.wasm\n",
    "a/entry.odin": """package a
import "base:runtime"
e :: proc(m: ^map[int]int) {
	_, v, _, _ := map_entry(m, 1) // use
	v^ = 2
	_, w, _, _ := runtime.map_entry(m, 2) // use
	_ = w
	_, x, _, _ := map_entry // use
	(
		m, 3)
	_ = x
	f :: map_entry // use
	runtime.__dynamic_map_entry(nil, nil, nil, nil) // use
	runtime.__dynamic_map_set(nil, nil, 0, nil, nil) // use
	// map_entry in a comment, /* nested */ or not
	/* map_entry /* nested */ map_entry */
	s := "map_entry"
	r := `map_entry
	map_entry`
	_, _ = s, r
	encode_stream_map_entry :: proc() {}
	encode_stream_map_entry()
}
""",
    "a/insert.odin": """package a
import rt "base:runtime"
i :: proc(m: ^map[int]int) -> rt.Allocator_Error {
	map_insert(m, 1, 1)
	_ = map_insert(m, 2, 2)
	_, err := map_insert(m, 3, 3)
	_, err = rt.map_insert(m, 4, 4)
	map_insert(m, 5, 5) or_return
	if _, e := map_insert(m, 6, 6); e != nil { return e }
	defer map_insert(m, 7, 7)
	_, _, found := map_upsert(m, 8, 8)
	_ = found
	map_insert(
		m,
		9, 9,
	)
	p := map_insert(m, 10, 10) // use
	p^ = 1
	map_insert(m, 11, 11)^ = 2 // use
	q, err2 := map_insert(m, 12, 12) // use
	_, _ = q, err2
	g(map_insert(m, 13, 13)) // use
	_, r, _ := map_upsert(m, 14, 14) // use
	_ = r
	ins :: map_insert // use
	s := rt.map_insert(m, 15, 15) // use
	_ = s
	t := map_insert(m, 16, // use
		16)
	_ = t
	map_insert(m, 17, 17).x = 3 // use
	return err
}
g :: proc(_: ^int) {}
""",
    "a/intern.odin": """package a
import "core:strings"
import s2 "core:strings"
n :: proc() {
	in1: strings.Intern // use
	strings.intern_init(&in1) // use
	in2: s2 . Intern // use
	_, _ = s2.
		intern_get(&in2, "x") // use
	J :: strings.intern_get_cstring // use
	_ = strings.to_upper("intern_get")
	Intern :: struct {}
	_ = Intern{}
}
""",
    "a/imports.odin": """package a
import nb "core:nbio" // use
import "core:text/i18n" // use
import ts
	"core:container/topological_sort" // use
import "core:container/queue"
""",
    "a/net_darwin.odin": """package a
import "core:net"
d :: proc() { _, _ = net.enumerate_interfaces() } // use
""",
    "a/net_bsd.odin": """#+build openbsd, netbsd
package a
import n2 "core:net"
d2 :: proc() { _, _ = n2.enumerate_interfaces() } // use
""",
    "a/net_linux.odin": """package a
import "core:net"
d3 :: proc() { _, _ = net.enumerate_interfaces() }
""",
    "a/net_other.odin": """#+build !darwin
#+build !openbsd
#+build !netbsd
package a
import "core:net"
d4 :: proc() { _, _ = net.enumerate_interfaces() }
""",
    "a/env_wasi.odin": """package a
import "core:os" // use
""",
    "a/env_tagged.odin": """#+build wasi
package a
import o "core:os" // use
""",
    "a/env_native.odin": """package a
import "core:os"
""",
    "a/env_not_wasi.odin": """#+build !wasi
package a
import "core:os"
""",
    "wasm_pkg/main.odin": """package wasm_pkg
import "core:os" // use
import "../wasm_dep"
""",
    "wasm_pkg/native_only.odin": """#+build linux, darwin
package wasm_pkg
import "core:os"
""",
    "wasm_dep/dep.odin": """package wasm_dep
import "core:os" // use
""",
    "tests/upstream/odin_1/main.odin": """// Reproduces odin-lang/Odin#1: what it shows.
package odin_1
e :: proc(m: ^map[int]int) { _, v, _, _ := map_entry(m, 1); v^ = 1 }
""",
    "tests/upstream/odin_2/main.odin": """// Not a repro, though it is where they are.
package odin_2
e :: proc(m: ^map[int]int) { _, v, _, _ := map_entry(m, 1); v^ = 1 } // use
""",
    "tests/other/main.odin": """// Reproduces odin-lang/Odin#1: but not where the repros are.
package other
e :: proc(m: ^map[int]int) { _, v, _, _ := map_entry(m, 1); v^ = 1 } // use
""",
    "b/trunc.odin": """package b
import "core:os"
t :: proc(p: string) {
	_, _ = os.open(p, {.Write, .Trunc}) // use 8646
	_, _ = os.open(p, {.Read, .Write, .Trunc}, os.Permissions_Default_File) // use 8646
	_, _ = os.open(p, {
		.Read,
		.Trunc, // use 8646
		.Write,
	})
	_, _ = os.open(p, {.Write, .Create, .Trunc})
	_, _ = os.open(p, {
		.Write,
		.Trunc,
		.Create,
	})
	f := os.File_Flags{.Trunc, .Write} // use 8646
	g: os.File_Flags = {.Write}
	incl(&g, os.File_Flag.Trunc) // use 8646
	g += {.Trunc} // use 8646
	if .Trunc in g {
		_ = f & {.Trunc} == {.Trunc}
		_ = {.Trunc} <= g
	}
	_, _ = os.open(p, os.O_RDWR + os.O_TRUNC) // use 8646
	_, _ = os.open(p, os.O_RDWR + os.O_CREATE + os.O_TRUNC)
	if true { _, _ = os.open(p, {.Write, .Trunc}) } // use 8646
	Trunc :: 1
	_ = Trunc
	// {.Write, .Trunc} in a comment
	_ = "{.Write, .Trunc}"
}
""",
    "b/trunc_alias.odin": """package b
import o "core:os"
u :: proc(p: string) {
	_, _ = o.open(p, o.O_WRONLY | o.O_TRUNC) // use 8646
}
""",
    "b/trunc_linux.odin": """package b
import "core:os"
v :: proc(p: string) { _, _ = os.open(p, {.Write, .Trunc}) }
""",
    "b/trunc_not_windows.odin": """#+build !windows
package b
import "core:os"
w :: proc(p: string) { _, _ = os.open(p, {.Write, .Trunc}) }
""",
    "b/trunc_no_os.odin": """package b
import nbio "../third_party/nbio"
x :: proc(p: string) { nbio.open(p, nil, {.Write, .Trunc}) }
""",
    "node_modules/x/y.odin": """package y
e :: proc(m: ^map[int]int) { map_entry(m, 1) }
""",
}


def selftest():
    with tempfile.TemporaryDirectory() as root:
        want = set()
        for rel, src in FIXTURES.items():
            path = os.path.join(root, *rel.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(src)
            for n, line in enumerate(src.splitlines(), 1):
                m = re.search(r"// use( 8646)?$", line.rstrip())
                if m:
                    want.add((os.path.join(*rel.split("/")), n, TRUNC_ISSUE if m.group(1) else ISSUE))
        got = lint(root)
        have = {(p, line, issue) for p, line, _, issue in got}
        missed = sorted(want - have)
        extra = sorted((p, line, what, issue) for p, line, what, issue in got if (p, line, issue) not in want)
        for p, line, issue in missed:
            print(f"FAIL the lint missed a use of what {issue} breaks at {p}:{line}")
        for p, line, what, issue in extra:
            print(f"FAIL the lint took {p}:{line} for a use of what {issue} breaks: {what}")
        if missed or extra:
            return 1
        each = {i: sum(1 for w in want if w[2] == i) for i in (ISSUE, TRUNC_ISSUE)}
        print(f"ok   the lint finds each of the {each[ISSUE]} uses of what {ISSUE} breaks and the {each[TRUNC_ISSUE]} of what"
              f" {TRUNC_ISSUE} does, put in its fixtures, however written, and nothing else")
        return 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest()
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = lint(root)
    for p, line, what, issue in found:
        print(f"{p}:{line}: {what} ({issue})")
    for issue in sorted({f[3] for f in found}):
        n = sum(1 for f in found if f[3] == issue)
        print(f"FAIL {n} uses of what {issue} breaks: see https://github.com/{issue.replace('#', '/issues/')}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
