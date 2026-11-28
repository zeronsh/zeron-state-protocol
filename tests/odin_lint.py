"""What `./x check` holds every .odin file here to, outside node_modules: no use of what odin-lang/Odin#8642 or #8646
breaks.

#8642. The runtime's `__dynamic_map_entry` (`map_entry`) can give back the slot of another key, and the pointer an insertion
gives back (`map_insert`, `map_upsert`) can be to it too: what is written through it lands on another key. Inserting
itself is sound (`m[k] = v`, or `map_insert` with its pointer let go of), as is looking up. So this fails on:

- `map_entry`, or the runtime's own `__dynamic_map_entry` and `__dynamic_map_set*`, named at all;
- the pointer `map_insert` or `map_upsert` gives back, kept or used: each is to be called as a statement, or with that
  result assigned to `_`; and neither may be named but to call it, as `alias :: map_insert` would hide it;
- what of core uses them: `core:strings`'s `Intern` and `intern_*`; `core:os` in a file built for WASI (its environment
  is kept with `map_entry`); `core:net`'s `enumerate_interfaces` in a file built for macOS, OpenBSD or NetBSD;
  `core:nbio` (third_party/nbio is the copy to use, until #8642, #8644, #8645 and #8647 are fixed in a release);
  `core:text/i18n` (it interns); `core:container/topological_sort` (it keeps `map_insert`'s pointer).

#8646. On Windows, core:os opens a file with `.Trunc` but not `.Create` asking TRUNCATE_EXISTING with FILE_GENERIC_WRITE,
which Windows refuses as an invalid parameter (87), wanting GENERIC_WRITE itself. So in a file that imports `core:os`
and is built for Windows, flags made with `.Trunc` (or `O_TRUNC`) and not `.Create` (or `O_CREATE`) fail. Each flags
expression is read as a whole, wherever it is given (an argument, a return, an assignment), across lines: a set's
elements and the constants added, not those taken away (`-`, `&~`, `excl`) nor only asked of (`&`, a comparison,
`in`). What is assigned to a name is taken with all else assigned to it in the file (`incl` too), as flags built up.

core:net's set_option sets every integer option, and `bool` and `b8` ones, to the low bytes of a pointer (its type
switch lists several types in one case, where the value stays an `any`). So `net.set_option` fails outright, wherever
it is called: third_party/nbio's set_socket_option sets each option with the C type the system wants.

Formatting is no way round it: comments and strings are taken out, and what is left is read as tokens, in statements
split as Odin splits them. Each import is followed by the name it is given. A file is taken as built for an OS as Odin
builds it, by its name and its `#+build` lines (./x selftest holds that to Odin itself, target by target);
a package as built for WASI if a command here builds it so (`-target:wasi_...` in ./x or a workflow), with what it
imports from here. The one exception is the repros in tests/upstream, there to use what is broken: each file there that
says at its head what it reproduces ("// Reproduces ...").

    python3 tests/odin_lint.py [root]   says each use, and fails if there is any
    python3 tests/odin_lint.py --selftest   that it finds each use put in its fixtures, however written, and no other
"""

import os, re, sys, tempfile

ISSUE = "odin-lang/Odin#8642"
TRUNC_ISSUE = "odin-lang/Odin#8646"
OPTION_ISSUE = "core:net set_option (no issue)"
# Odin's target_os_names and target_arch_names (src/build_settings.cpp, as of the release CI builds with): there is no
# `unix`, neither as a build tag nor as the end of a file's name.
OSES = {"windows", "darwin", "linux", "freebsd", "openbsd", "netbsd", "wasi", "js", "orca", "freestanding"}
ARCHES = {"amd64", "i386", "arm32", "arm64", "wasm32", "wasm64p32", "riscv64"}
# The targets Odin builds for (`odin check -target:?`), as an OS and an arch: a file is built for an OS if it is for
# any target of it.
TARGETS = [
    "darwin_amd64", "darwin_arm64", "linux_i386", "linux_amd64", "linux_arm64", "linux_arm32", "linux_riscv64",
    "windows_i386", "windows_amd64", "freebsd_i386", "freebsd_amd64", "freebsd_arm64", "netbsd_amd64", "netbsd_arm64",
    "openbsd_amd64", "freestanding_wasm32", "wasi_wasm32", "js_wasm32", "orca_wasm32", "freestanding_wasm64p32",
    "js_wasm64p32", "wasi_wasm64p32", "freestanding_amd64_sysv", "freestanding_amd64_win64", "freestanding_amd64_mingw",
    "freestanding_arm64", "freestanding_arm32", "freestanding_riscv64",
]
OS_ARCHES = sorted({tuple(t.split("_")[:2]) for t in TARGETS})
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
            for p in ("&~=", "::", ":=", "..=", "..<", "->", "+=", "-=", "|=", "&=", "~=", "&~", "==", "!=", "<=", ">=", "&&", "||"):
                if src.startswith(p, i):
                    out.append(("punct", p, line))
                    i += len(p)
                    break
            else:
                out.append(("punct", c, line))
                i += 1
    return out


def build_lines(src):
    """The `#+build` tags of a file, each the text of its line after `#+build`, as Odin reads them: lines starting `#+`
    before `package`, among comments, each ending where a `/` begins (a comment after it)."""
    out = []
    for t in tokens_before_package(src):
        m = re.match(r"#\+build(?:\s+|$)(.*)", t)
        if m and not t.startswith("#+build-"):
            out.append(m.group(1))
    return out


def tokens_before_package(src):
    """Each `#+` tag before `package`, its text up to the end of its line or a `/`, as Odin's tokenizer takes it."""
    tags, i, n = [], 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if src.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif src.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
        elif src.startswith("#+", i):
            j = i
            while j < n and src[j] not in "\n/":
                j += 1
            tags.append(src[i:j].strip())
            i = j
        elif src[i].isspace():
            i += 1
        else:
            break  # `package`, or whatever comes first that is not a comment or a tag
    return tags


def tag_groups(text):
    """A `#+build` line as Odin's parse_build_tag reads it: groups, separated by commas, any of which may hold; in each,
    words, all of which must; a word `!` before a name to be not that; `ignore` a group that never holds."""
    groups, cur = [], []
    for w in re.findall(r"!?[A-Za-z0-9_:]+|,", text):
        if w == ",":
            groups.append(cur)
            cur = []
        else:
            cur.append(w)
    groups.append(cur)
    return [g for g in groups if g]


def group_admits(group, os_name, arch):
    """Whether a group holds for a target: each word for it (an `os:subtarget` word for some subtarget of the OS, so
    that a negated one does not exclude the OS)."""
    for w in group:
        neg = w.startswith("!")
        name = w.lstrip("!").lower()
        if name == "ignore":
            return False
        os_part, _, subtarget = name.partition(":")
        if os_part in OSES:
            if neg and not subtarget and os_part == os_name:
                return False
            if not neg and os_part != os_name:
                return False
        elif name in ARCHES:
            if (name == arch) == neg:
                return False
    return True


def suffix_builds(path, os_name, arch):
    """Whether a file's name lets it be built for a target, as Odin's is_excluded_target_filename reads it: by the
    last part after `_` (an OS or an arch), or the last two (`_os_arch` or `_arch_os`); a name starting with `.` is
    never built."""
    name = os.path.basename(path)[: -len(".odin")]
    if name.startswith("."):
        return False
    parts = name.split("_")
    if len(parts) < 2:
        return True
    last, before = parts[-1].lower(), (parts[-2].lower() if len(parts) >= 3 else "")
    if last in OSES and before in ARCHES:
        return last == os_name and before == arch
    if last in ARCHES and before in OSES:
        return last == arch and before == os_name
    if last in OSES:
        return last == os_name
    if last in ARCHES:
        return last == arch
    return True


def admits(path, src):
    """The set of OSes a file is built for, for some target of each, by Odin's rules: its name, and each of its
    `#+build` lines, all of which must hold (see tag_groups)."""
    lines = [tag_groups(line) for line in build_lines(src)]
    return {o for o, a in OS_ARCHES if suffix_builds(path, o, a) and all(any(group_admits(g, o, a) for g in groups) for groups in lines)}


def explicitly(path, src, os_name):
    """Whether a file is meant for that OS by name: its name builds it for that OS only, or one of its `#+build` lines
    (before `package`) names it, not negated."""
    if admits(path, "") == {os_name}:
        return True
    return any(os_name in [w.partition(":")[0].lower() for w in g] for line in build_lines(src) for g in tag_groups(line))


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


# Odin's keywords. A line ends a statement, as Odin puts a semicolon there, after a name, a literal, `)`, `]`, `}`, `^`
# or `?`, and after the keywords of ENDING: after any other token, or keyword, the statement goes on.
KEYWORDS = {"import", "foreign", "package", "typeid", "when", "where", "if", "else", "for", "switch", "in", "not_in", "do",
            "case", "break", "continue", "fallthrough", "defer", "return", "proc", "struct", "union", "enum", "bit_set",
            "bit_field", "map", "dynamic", "auto_cast", "cast", "transmute", "distinct", "using", "context", "or_else",
            "or_return", "or_break", "or_continue", "asm", "matrix"}
ENDING = {"break", "continue", "fallthrough", "return", "or_return", "or_break", "or_continue", "context"}


def ends_line(tok):
    """Whether a statement ends at the end of a line that ends with this token (see KEYWORDS)."""
    kind, text, _ = tok
    if kind in ("number", "string", "rune"):
        return True
    if kind == "ident":
        return text not in KEYWORDS or text in ENDING
    return text in (")", "]", "}", "^", "?")
# Words that, at the head of a statement, make the `{` that follows its block.
BLOCK_HEADS = {"if", "for", "switch", "when", "else", "proc", "struct", "enum", "union", "foreign", "defer"}
ASSIGN = {"=", ":=", "+=", "-=", "|=", "&=", "&~=", "~="}


def statements(toks):
    """Each statement as (start, end), indices of its tokens, end past its last: split at `;`, at a block's `{` and
    `}`, and at the end of a line not inside brackets and not going on. A block's contents are statements of their own;
    a literal's `{...}` is part of the expression it is in. A `{` is a block's if it begins a statement, or if a word of
    BLOCK_HEADS is in the statement before it, outside brackets."""
    out, stack, start, n = [], [], 0, len(toks)
    heads = False  # whether the statement so far has a word of BLOCK_HEADS outside brackets

    def close(end):
        nonlocal start, heads
        if end > start:
            out.append((start, end))
        start, heads = end + 1, False

    i = 0
    while i < n:
        kind, text, line = toks[i]
        inside = any(k != "block" for k in stack)
        if kind == "punct" and text in "([":
            stack.append("paren")
        elif kind == "punct" and text == "{":
            if not inside and (i == start or heads):
                close(i)
                stack.append("block")
            else:
                stack.append("literal")
        elif kind == "punct" and text in ")]}":
            k = stack.pop() if stack else "block"
            if k == "block":
                close(i)
        elif kind == "punct" and text == ";" and not inside:
            close(i)
        elif kind == "ident" and text in BLOCK_HEADS and not inside:
            heads = True
        if i + 1 < n and not any(k != "block" for k in stack) and toks[i + 1][2] > line and ends_line(toks[i]) and start <= i:
            out.append((start, i + 1))
            start, heads = i + 1, False
        i += 1
    if start < n:
        out.append((start, n))
    return out


def split_depth0(toks, s, e, seps):
    """The parts of toks[s:e] between separators at depth 0, as (start, end)."""
    parts, depth, b = [], 0, s
    for k in range(s, e):
        t = toks[k][1]
        if toks[k][0] == "punct" and t in "([{":
            depth += 1
        elif toks[k][0] == "punct" and t in ")]}":
            depth -= 1
        elif depth == 0 and t in seps:
            parts.append((b, k))
            b = k + 1
    parts.append((b, e))
    return parts


def matching(toks, i):
    """The index of the bracket that closes the one at i."""
    depth = 0
    for j in range(i, len(toks)):
        if toks[j][0] == "punct" and toks[j][1] in "([{":
            depth += 1
        elif toks[j][0] == "punct" and toks[j][1] in ")]}":
            depth -= 1
            if depth == 0:
                return j
    return len(toks) - 1


def statement_of(stmts, i):
    for s, e in stmts:
        if s <= i < e:
            return s, e
    return i, i + 1


def pointer_let_go(toks, stmts, i):
    """Whether the call whose name is the token at i gives back its pointer only to be let go of: the call the whole of
    its statement (after `defer`, `if`, `for`, `when` or `switch`, and with `or_return` after it), or the whole of what
    an assignment assigns, with the pointer's place `_`. map_insert gives the pointer first, map_upsert second."""
    name = toks[i][1]
    s, e = statement_of(stmts, i)
    start = i - 2 if i >= 2 and toks[i - 1][1] == "." and toks[i - 2][0] == "ident" else i  # runtime.map_insert
    end = matching(toks, i + 1) + 1
    if end < e and toks[end][1] == "or_return":
        end += 1
    if end != e:
        return False
    while s < start and toks[s][1] in ("defer", "if", "for", "when", "switch"):
        s += 1
    if start == s:
        return True
    if toks[start - 1][1] not in ("=", ":="):
        return False
    lhs_end = start - 1
    # Typed: `a, b: T = call`. The names are before the `:`.
    colon = [k for k in range(s, lhs_end) if toks[k][1] == ":" and toks[k][0] == "punct"]
    if colon and toks[start - 1][1] == "=":
        lhs_end = colon[0]
    lhs = split_depth0(toks, s, lhs_end, {","})
    place = 0 if name == "map_insert" else 1
    if place >= len(lhs):
        return False
    a, b = lhs[place]
    return b - a == 1 and toks[a][1] == "_"


def flags_added(toks, s, e, consts):
    """Of a flags expression, toks[s:e]: whether it adds .Trunc, and whether it adds .Create, as it reads: set elements
    and O_* constants added (by `+`, `|` or in a set), not taken away (by `-` or `&~`) nor only asked of (`&`, a
    comparison, `in`). consts names the core:os O_* constants: O_TRUNC is .Trunc, O_CREATE .Create. None if it is no
    flags expression at all but a test."""
    trunc, create = [], False  # the lines .Trunc is added on; whether .Create is
    sign, depth, k = 1, 0, s
    while k < e:
        kind, t, _ = toks[k]
        if kind == "punct" and t in ("==", "!=", "<=", ">=", "<", ">") and depth == 0:
            return None
        if kind == "ident" and t in ("in", "not_in") and depth == 0:
            return None
        if kind == "punct" and t in ("+", "|"):
            sign = 1
        elif kind == "punct" and t in ("-", "&~"):
            sign = -1
        elif kind == "punct" and t == "&":
            sign = 0
        elif kind == "punct" and t == "{":
            close = matching(toks, k)
            for a, b in split_depth0(toks, k + 1, close, {","}):
                words = [toks[x][1] for x in range(a, b)]
                if sign > 0 and words[-1:] == ["Trunc"]:
                    trunc.append(toks[b - 1][2])
                if sign > 0 and words[-1:] == ["Create"]:
                    create = True
            k = close
        elif kind == "punct" and t == "(":
            close = matching(toks, k)
            inner = flags_added(toks, k + 1, close, consts)
            if inner and sign > 0:
                trunc, create = trunc + inner[0], create or inner[1]
            k = close
        elif kind == "ident" and sign > 0 and (t in consts or (k >= 1 and toks[k - 1][1] == ".")):
            if t in ("O_TRUNC", "Trunc"):
                trunc.append(toks[k][2])
            create = create or t in ("O_CREATE", "Create")
        k += 1
    return trunc, create


def trunc_uses(toks, os_names):
    """The lines on which flags with .Trunc and not .Create are made (see #8646 above). Each flags expression is read
    as a whole (flags_added), wherever it is given: as an argument of a call, in a return, or assigned. What is
    assigned to a name is taken with all else assigned to that name in the file, as one set of flags built up: it adds
    .Trunc without .Create if some assignment adds .Trunc and none adds .Create (incl and excl count as assignments)."""
    consts = {"O_TRUNC", "O_CREATE"}
    stmts = statements(toks)
    found, by_name = [], {}

    def note(s, e, name=None):
        r = flags_added(toks, s, e, consts)
        if r is None or not (r[0] or r[1]):
            return
        if name is None:
            if r[0] and not r[1]:
                found.extend(r[0])
        else:
            entry = by_name.setdefault(name, [[], False])
            entry[0].extend(r[0])
            entry[1] = entry[1] or r[1]

    for s, e in stmts:
        # Calls in it, each argument.
        k = s
        while k < e:
            if toks[k][0] == "ident" and k + 1 < e and toks[k + 1][1] == "(":
                close = matching(toks, k + 1)
                args = split_depth0(toks, k + 2, close, {","})
                callee = toks[k][1]
                if callee in ("incl", "excl") and len(args) == 2:
                    # incl(&flags, x) adds x to flags, as flags += x would; excl takes it away.
                    a0, b0 = args[0]
                    a1, b1 = args[1]
                    if toks[a0][1] == "&":
                        a0 += 1
                    if callee == "incl":
                        note(a1, b1, name=" ".join(t[1] for t in toks[a0:b0]))
                else:
                    for a, b in args:
                        if b > a and not (b - a == 1 and toks[a][0] == "ident"):
                            note(a, b)
            k += 1
        # Returns, and assignments.
        if toks[s][1] == "return":
            for a, b in split_depth0(toks, s + 1, e, {","}):
                note(a, b)
            continue
        ops = [k for k in range(s, e) if toks[k][0] == "punct" and toks[k][1] in ASSIGN and not any(
            toks[x][1] in "([{" and matching(toks, x) > k for x in range(s, k) if toks[x][0] == "punct")]
        if not ops:
            continue
        op = ops[0]
        lhs_end = op
        colon = [k for k in range(s, op) if toks[k][1] == ":" and toks[k][0] == "punct"]
        if colon and toks[op][1] == "=":
            lhs_end = colon[0]
        names = [" ".join(t[1] for t in toks[a:b]) for a, b in split_depth0(toks, s, lhs_end, {","})]
        values = split_depth0(toks, op + 1, e, {","})
        if toks[op][1] in ("-=", "&~=", "&="):
            continue  # taken away, or asked of
        for idx, (a, b) in enumerate(values):
            name = names[idx] if idx < len(names) and len(names) == len(values) else None
            # A call assigned is read by its arguments above; a name assigned only as it stands is not a set built.
            if b - a >= 1 and toks[a][0] == "ident" and a + 1 < b and toks[a + 1][1] == "(" and matching(toks, a + 1) == b - 1:
                continue
            note(a, b, name=name)
    for trunc, create in by_name.values():
        if trunc and not create:
            found.extend(trunc)
    return sorted(set(found))


def lint_file(path, src, wasi_built):
    """Each use in a file, as (line, what, issue)."""
    toks = tokens(src)
    found = []
    named = imports(toks)
    by_path = {}
    for alias, p in named.items():
        by_path.setdefault(p, []).append(alias)
    oses = admits(path, src)
    stmts = statements(toks)
    for p, why in BANNED_IMPORTS.items():
        if p in by_path:
            line = next(t[2] for t in toks if t[0] == "string" and t[1] == p)
            found.append((line, why, ISSUE))
    if "core:os" in by_path and "wasi" in oses and (wasi_built or explicitly(path, src, "wasi")):
        line = next(t[2] for t in toks if t[0] == "string" and t[1] == "core:os")
        found.append((line, "core:os in a file built for WASI: its environment is kept with map_entry", ISSUE))
    strings_names = set(by_path.get("core:strings", []))
    net_names = set(by_path.get("core:net", [])) if oses & BSDS else set()
    all_net_names = set(by_path.get("core:net", []))
    for i, (kind, text, line) in enumerate(toks):
        if kind != "ident":
            continue
        if text in ("map_entry", "__dynamic_map_entry") or text.startswith("__dynamic_map_set"):
            found.append((line, f"{text}: it can give back another key's slot", ISSUE))
        elif text in ("map_insert", "map_upsert"):
            if i + 1 >= len(toks) or toks[i + 1][1] != "(":
                found.append((line, f"{text} named but to call it: the pointer it gives back is not to be had", ISSUE))
            elif not pointer_let_go(toks, stmts, i):
                found.append((line, f"{text}'s pointer kept or used: it may be another key's; call it as a statement, or assign that result to _", ISSUE))
        elif i >= 2 and toks[i - 1][1] == "." and toks[i - 2][0] == "ident":
            owner = toks[i - 2][1]
            if owner in strings_names and (text == "Intern" or text.startswith("intern_")):
                found.append((line, f"strings.{text}: interning uses map_entry", ISSUE))
            elif owner in net_names and text == "enumerate_interfaces":
                found.append((line, "net.enumerate_interfaces in a file built for macOS, OpenBSD or NetBSD: it gathers with map_entry there", ISSUE))
            if owner in all_net_names and text == "set_option":
                found.append((line, "net.set_option sets integer and bool options to the bytes of a pointer: use nbio.set_socket_option", OPTION_ISSUE))
    if "windows" in oses:
        if "core:os" in by_path:
            for line in trunc_uses(toks, by_path["core:os"]):
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
    return parts[:2] == ["tests", "upstream"] and re.match(r"// Reproduces \S", src) is not None


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
    "a/env_after.odin": """package a
import "core:os"
// #+build wasi, in a comment
TAG :: `
#+build wasi
`
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
    "b/trunc_more.odin": """package b
import "core:os"
import "base:runtime"
S :: struct { err: runtime.Allocator_Error }
m :: proc(p: string, mode: os.File_Flag, g: ^os.File_Flags, s: ^S, mp: ^map[int]int) {
	g^ &~= {.Trunc}
	g^ = g^ - {.Trunc}
	excl(g, os.File_Flag.Trunc)
	h := g^ &~ {.Trunc}
	_ = h
	_, _ = os.open(p, os.O_CREATE |
		os.O_TRUNC)
	if mode != .Create do _, _ = os.open(p, os.O_WRONLY | os.O_TRUNC) // use 8646
	fl := os.File_Flags{.Write, .Trunc}
	fl += {.Create}
	_, _ = os.open(p, fl)
	fl2 := os.File_Flags{.Write}
	fl2 |= {.Trunc} // use 8646
	_, _ = os.open(p, fl2)
	_, s.err = map_insert(mp, 1, 1)
	_, e: runtime.Allocator_Error = map_insert(mp, 2, 2)
	_ = e
	q: ^int = map_insert(mp, 3, 3) // use
	_ = q
	r := mp^[1] + 1
	_ = r
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
    "c/options.odin": """package c
import "core:net"
import n2 "core:net"
o :: proc(s: net.TCP_Socket) {
	net.set_option(s, .TCP_Nodelay, true) // use option
	net.set_option(s, .Receive_Buffer_Size, i32(1 << 20)) // use option
	_ = n2 .
		set_option(s, .Broadcast, b32(true)) // use option
	f :: net.set_option // use option
	_ = f
	set_option(s, .TCP_Nodelay, true)
	_ = "net.set_option"
}
set_option :: proc(_: net.TCP_Socket, _: int, _: bool) {}
""",
    "node_modules/x/y.odin": """package y
e :: proc(m: ^map[int]int) { map_entry(m, 1) }
""",
}


# Files and their `#+build` lines, each to be built as Odin builds it (see selftest_tags).
TAG_FIXTURES = {
    "tag_neg_first.odin": "#+build !arm64 windows\n",
    "tag_neg_second.odin": "#+build amd64 !windows\n",
    "tag_comment.odin": "#+build linux // only Linux\n",
    "tag_nospace.odin": "#+build linux,darwin\n",
    "tag_spaces.odin": "#+build  linux ,  darwin amd64\n",
    "tag_lines.odin": "#+build !windows\n#+build !linux\n",
    "tag_ignore.odin": "#+build ignore\n",
    "tag_group_ignore.odin": "#+build ignore, linux\n",
    "tag_subtarget.odin": "#+build !darwin:iphone\n",
    "tag_case.odin": "#+build Windows\n",
    "tag_after_comments.odin": "/* a block */\n// a line\n#+build freebsd\n",
    "x_unix.odin": "",
    "x_windows.odin": "",
    "x_amd64_linux.odin": "",
    "x_linux_arm64.odin": "",
    "x_arm64.odin": "",
    ".hidden.odin": "",
}
TAG_TARGETS = TARGETS


def selftest_tags():
    """That admits() takes each of TAG_FIXTURES to be built for the OSes Odin builds it for: each checked with odin, for
    each of TAG_TARGETS, as the one file beside a main, failing if it is built."""
    import shutil, subprocess
    from concurrent.futures import ThreadPoolExecutor

    odin = shutil.which("odin")
    if odin is None:
        print("FAIL no odin to hold the lint's reading of build tags to")
        return 1
    with tempfile.TemporaryDirectory() as root:
        dirs = {}
        for i, (name, tags) in enumerate(TAG_FIXTURES.items()):
            d = os.path.join(root, f"p{i}")
            os.makedirs(d)
            with open(os.path.join(d, "main.odin"), "w") as f:
                f.write("package p\nmain :: proc() {}\n")
            with open(os.path.join(d, name), "w") as f:
                f.write(tags + 'package p\n#assert(false, "BUILT")\n')
            dirs[name] = d

        def built(job):
            name, target = job
            r = subprocess.run([odin, "check", dirs[name], "-target:" + target], capture_output=True, text=True)
            return name, target, "BUILT" in r.stdout + r.stderr

        jobs = [(n, t) for n in TAG_FIXTURES for t in TAG_TARGETS]
        odin_says = {n: set() for n in TAG_FIXTURES}
        with ThreadPoolExecutor(4) as pool:
            for name, target, yes in pool.map(built, jobs):
                if yes:
                    odin_says[name].add(target.split("_")[0])
        failed = 0
        for name, tags in TAG_FIXTURES.items():
            mine = admits(name, tags + "package p\n")
            if mine != odin_says[name]:
                failed += 1
                print(f"FAIL the lint takes {name} ({tags.strip() or 'no tags'!r}) to be built for {sorted(mine)}; Odin builds it for {sorted(odin_says[name])}")
        if failed:
            return 1
        print(f"ok   the lint reads the build tags and names of {len(TAG_FIXTURES)} files as Odin does, for {len(TAG_TARGETS)} targets")
        return 0


def selftest():
    with tempfile.TemporaryDirectory() as root:
        want = set()
        for rel, src in FIXTURES.items():
            path = os.path.join(root, *rel.split("/"))
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write(src)
            for n, line in enumerate(src.splitlines(), 1):
                m = re.search(r"// use( 8646| option)?$", line.rstrip())
                if m:
                    issue = {None: ISSUE, " 8646": TRUNC_ISSUE, " option": OPTION_ISSUE}[m.group(1)]
                    want.add((os.path.join(*rel.split("/")), n, issue))
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
        each = {i: sum(1 for w in want if w[2] == i) for i in (ISSUE, TRUNC_ISSUE, OPTION_ISSUE)}
        print(f"ok   the lint finds each of the {each[ISSUE]} uses of what {ISSUE} breaks, the {each[TRUNC_ISSUE]} of what"
              f" {TRUNC_ISSUE} does, and the {each[OPTION_ISSUE]} of {OPTION_ISSUE}, put in its fixtures, however written,"
              " and nothing else")
        return 0


def main():
    if sys.argv[1:] == ["--selftest"]:
        return selftest() or selftest_tags()
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    found = lint(root)
    for p, line, what, issue in found:
        print(f"{p}:{line}: {what} ({issue})")
    for issue in sorted({f[3] for f in found}):
        n = sum(1 for f in found if f[3] == issue)
        where = f"see https://github.com/{issue.replace('#', '/issues/')}" if "#" in issue else "see third_party/nbio/socket_option.odin"
        print(f"FAIL {n} uses of what {issue} breaks: {where}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
