"""What `./x check` holds every .odin file here to, outside node_modules: no use of what odin-lang/Odin#8642 or #8646
breaks, and no test's logger set but through tests/testlog.

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

A test's logger. core:testing counts a test's failures in the logger it runs the test with: a test that sets
context.logger to another loses every failure it says, and passes having checked nothing. So a test sets it only to
what testlog.quiet gives (tests/testlog/testlog.odin, which says why that loses none), as the whole of a statement:
`context.logger = testlog.quiet(t, &q, .Code_Under_Test)`. In test code (a _test.odin file, or one that imports
core:testing) this fails on anything else that sets it or a part of it (`context.logger.lowest_level = .Error`,
`defer context.logger = saved`); on setting the whole context (`context = runtime.default_context()`), or a context's
logger (`ctx.logger = ...`, `Context{logger = ...}`), or taking context's address. core:testing may be imported only by
a _test.odin file, and testlog, so that every failure is said from a line of one, which quiet always passes on. In code
a test runs that is not a test's own (the other files of a package `odin test` builds, and what they import from here),
which may call back a test's own, as a hook does, this fails on the same, but in a package main's `main` and what only
it calls, as `odin test` runs a main of its own; and the whole context may be set in a procedure of another calling
convention, as the system calls, which has none to lose.

Where a failure is said from. A location is had only from #caller_location and #location(): in test code and in code a
test runs, this fails on any made by hand, which could say a test's failure from a line quiet does not pass on: on
Source_Code_Location named (in code a test runs, but as the type of a parameter of a procedure with a body: not of a
procedure type, a result, a field, a variable, a literal, a cast); on `#location(x)`, a declaration's, which may be
another file's; on a location's type had by type_of; and on a location's file_path set. And in test code, on a location
given a call, by name (`loc =`, `location =`) or by place to core:testing's procedures that say a failure, that is not
#caller_location, #location() or a parameter given #caller_location by default.

A thread started to say a test's failures and given no `context`: core:thread gives a thread not given one
runtime.default_context(), whose logger says nothing. Each call of core:thread in test code given no `context` fails if
its procedure may say a test's failures, or is one the lint cannot tell. Its procedure is followed wherever it is: a
literal; a procedure named, of any file of its package or of another package here; a local's every value; a
package variable's every value given it in any file; a field's every value given it in the file (`x.f = v`,
`x := T{f = v}`); a parameter's every value given it, at each call of its procedure in its package and, but for a
`@(private)` one, in each package here that imports it, or its default. A procedure may say a test's failures if it
names core:testing, or names or calls one that may, or calls one through a value the lint cannot tell (the context's
logger and allocator it can: they are runtime.default_context()'s, or what the rest of this holds them to). Where it
cannot tell, a line may say why it is fine, on it or the line before: `// lint-thread: why`, on a thread's call for all
of it, or on a call through a value within.

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
LOGGER_ISSUE = "a test's logger (no issue)"
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


def proc_bodies(toks):
    """Each procedure's body, as (open, close, name, convention, params, proc): the indices of its `{` and `}`, the name
    it is declared with (`name :: proc`) or None, the calling convention written after `proc` (`proc "c"`) or None, the
    index of the `(` of its parameters, and of its `proc`. A body is the `{` after a `proc`'s parameters and what it
    gives back, on the line its head ends on; a procedure type has none."""
    out = []
    for i, (kind, text, _) in enumerate(toks):
        if kind != "ident" or text != "proc":
            continue
        j = i + 1
        convention = None
        if j < len(toks) and toks[j][0] == "string":
            convention, j = toks[j][1], j + 1
        if j >= len(toks) or toks[j][1] != "(":
            continue  # proc groups, `proc{a, b}`
        k = matching(toks, j) + 1
        body = None
        while k < len(toks):
            t = toks[k]
            if t[0] == "punct" and t[1] in "([":
                k = matching(toks, k) + 1
                continue
            if t[0] == "punct" and t[1] == "{":
                body = k
                break
            if t[0] == "punct" and t[1] in (",", ")", "]", "}", ";", "=", ":="):
                break
            if t[2] > toks[k - 1][2] and toks[k - 1][1] not in ("->", ",") and t[1] != "where":
                break
            k += 1
        if body is None:
            continue
        name = toks[i - 2][1] if i >= 2 and toks[i - 1][1] == "::" and toks[i - 2][0] == "ident" else None
        out.append((body, matching(toks, body), name, convention, j, i))
    return out


def innermost(bodies, i):
    """The body of the procedure the token at i is in, innermost, or None."""
    best = None
    for b in bodies:
        if b[0] < i < b[1] and (best is None or b[0] > best[0]):
            best = b
    return best


def targets_begin(toks, i):
    """Whether toks[i] begins one of the names a statement assigns to: before it, back to where the statement begins,
    only names, fields of them and commas, `a, b.c, `; and not a field given in a literal, `{a = x, b`."""
    k = i - 1
    while k >= 0 and toks[k][1] == ",":
        k -= 1
        while k >= 1 and toks[k][0] == "ident" and toks[k - 1][1] == ".":
            k -= 2
        if k < 0 or toks[k][0] != "ident":
            return False
        k -= 1
    if k < 0:
        return True
    return toks[k][1] in ("{", ";", "}", ":", "defer", "do") or (toks[k + 1][2] > toks[k][2] and ends_line(toks[k]))


def field_given(toks, i):
    """Whether `name = value` at toks[i] gives a field of a literal, or an argument by name: what is given ends at a `,`
    or a `)`, or a `}` on its line; not at the end of its line, as a statement in a block does."""
    depth = 0
    for k in range(i + 2, len(toks)):
        t = toks[k]
        if depth == 0 and t[0] == "punct" and t[1] in (",", ")", "}"):
            return t[1] != "}" or t[2] == toks[k - 1][2]
        if t[0] == "punct" and t[1] in "([{":
            depth += 1
        elif t[0] == "punct" and t[1] in ")]}":
            depth -= 1
        elif depth == 0 and t[1] == ";":
            return False
        if depth == 0 and k + 1 < len(toks) and toks[k + 1][2] > t[2] and ends_line(t):
            return toks[k + 1][1] in (",", ")")
    return False


def assigned(toks, i, j):
    """Whether what is at toks[i:j] is assigned to: toks[j] is an assignment, or a `,` of names an assignment further
    on in the same statement assigns to, which begin a statement."""
    if j >= len(toks):
        return False
    if toks[j][0] == "punct" and toks[j][1] in ASSIGN:
        return True
    if toks[j][1] != "," or not targets_begin(toks, i):
        return False
    depth = 0
    for k in range(j, len(toks)):
        t = toks[k]
        if k > j and depth == 0 and t[2] > toks[k - 1][2] and ends_line(toks[k - 1]):
            return False
        if t[0] == "punct" and t[1] in "([{":
            depth += 1
        elif t[0] == "punct" and t[1] in ")]}":
            depth -= 1
            if depth < 0:
                return False
        elif depth == 0 and t[1] == ";":
            return False
        elif depth == 0 and t[0] == "punct" and t[1] in ASSIGN:
            return True
    return False


def chain_end(toks, j):
    """Past the fields and indices that follow toks[j - 1]: `.a.b[i]`."""
    while j < len(toks):
        if toks[j][1] == "." and j + 1 < len(toks) and toks[j + 1][0] == "ident":
            j += 2
        elif toks[j][1] == "[":
            j = matching(toks, j) + 1
        else:
            break
    return j


def logger_uses(toks, named, test_code, under_test, in_helper, main_only=frozenset(), unit=None, resolver=None):
    """The lines on which a test's logger is set otherwise than through tests/testlog (see LOGGER_ISSUE above), each as
    (line, what)."""
    found = []
    if not (test_code or under_test):
        return found
    helper = {alias for alias, p in named.items() if p.replace("\\", "/").rstrip("/").split("/")[-2:] == ["tests", "testlog"]}
    testing_names = {alias for alias, p in named.items() if p == "core:testing"}
    thread_names = {alias for alias, p in named.items() if p == "core:thread"}
    bodies = proc_bodies(toks)

    def excused(i, whole_context):
        """In code a test runs that is not a test's: in a package main's main, or what only it calls, which `odin test`
        never runs, as it makes a main of its own; or, for the whole context, in a procedure of another calling
        convention, as the system calls, given none to lose."""
        if test_code:
            return False
        b = innermost(bodies, i)
        if b is None:
            return False
        if whole_context and b[3] not in (None, "odin"):
            return True
        while innermost(bodies, b[0]) is not None:
            b = innermost(bodies, b[0])
        return b[2] in main_only

    def quieted(i, j):
        """Whether `context.logger = ` at toks[i:j+1] assigns exactly what testlog.quiet gives, and nothing else."""
        k = j + 1
        if not test_code or toks[j][1] != "=":
            return False
        if k + 2 < len(toks) and toks[k][1] in helper and toks[k + 1][1] == "." and toks[k + 2][1] == "quiet":
            k += 3
        elif in_helper and k < len(toks) and toks[k][1] == "quiet":
            k += 1
        else:
            return False
        if k >= len(toks) or toks[k][1] != "(":
            return False
        close = matching(toks, k)
        after = close + 1
        return after >= len(toks) or toks[after][2] > toks[close][2] or toks[after][1] in (";", "}")

    who = "a test" if test_code else "code a test runs"
    for i, (kind, text, line) in enumerate(toks):
        if kind != "ident":
            continue
        before = toks[i - 1][1] if i > 0 else ""
        if text == "context" and before != ".":
            if before == "&" and not excused(i, False):
                found.append((line, f"{who} takes context's address: whatever is set through it, its logger among it, is not quiet's"))
                continue
            j = chain_end(toks, i + 1)
            if not assigned(toks, i, j):
                continue
            if j == i + 1:
                if not excused(i, True):
                    found.append((line, f"{who} sets the whole context, and with it a logger that is not the test runner's"))
            elif toks[i + 2][1] == "logger" and not (j == i + 3 and quieted(i, j)) and not excused(i, False):
                found.append((line, f"{who} sets context.logger otherwise than to what testlog.quiet gives: what is said of a failure may never be counted"))
        elif text == "logger" and before == "." and not (i >= 2 and toks[i - 2][1] == "context" and (i < 3 or toks[i - 3][1] != ".")):
            owner = i - 2
            while owner >= 2 and toks[owner - 1][1] == "." and toks[owner - 2][0] == "ident":
                owner -= 2
            if assigned(toks, owner, chain_end(toks, i + 1)) and not excused(i, False):
                found.append((line, f"{who} sets a context's logger, as for a thread: one that is not quiet's"))
        elif text == "logger" and before in ("{", ",", "(") and i + 1 < len(toks) and toks[i + 1][1] == "=":
            if field_given(toks, i) and not (before == "," and targets_begin(toks, i)) and not excused(i, False):
                found.append((line, f"{who} makes a context with a logger of its own: one that is not quiet's"))
    found += location_uses(toks, bodies, test_code)
    if test_code:
        found += location_arguments(toks, bodies, testing_names)
        if thread_names and unit is not None:
            found += thread_failures(unit, resolver)
    return found


LOCATION_DIRECTIVES = ("caller_location", "location")
# The procedures of core:testing that say a failure, and how many arguments each takes before its location, by place.
FAILING = {"expect": 4, "expect_value": 3, "fail": 1, "fail_now": 2, "expectf": None}


def location_uses(toks, bodies, test_code):
    """The lines on which a location is made by hand (see LOGGER_ISSUE above), each as (line, what): the only locations
    are what #caller_location and #location() give."""
    found = []
    in_params = lambda i: any(b[4] < i < matching(toks, b[4]) for b in bodies)
    for i, (kind, text, line) in enumerate(toks):
        nxt = toks[i + 1][1] if i + 1 < len(toks) else ""
        if kind == "ident" and text == "Source_Code_Location":
            if test_code:
                found.append((line, "a test names Source_Code_Location, as to make a location by hand: it may take only what #caller_location gives"))
            elif not in_params(i):
                found.append((line, "code a test runs names Source_Code_Location but as a parameter's, as to make a location by hand"))
        elif kind == "punct" and text == "#" and nxt == "location" and i + 3 < len(toks) and toks[i + 2][1] == "(" and toks[i + 3][1] != ")":
            found.append((line, "#location of a declaration, which may be another file's: only #location() is of where it is said"))
        elif kind == "ident" and text == "type_of" and nxt == "(":
            close = matching(toks, i + 1)
            if any(toks[k][1] == "#" and toks[k + 1][1] in LOCATION_DIRECTIVES for k in range(i + 2, close)):
                found.append((line, "a location's type had by type_of, as to make one by hand"))
        elif kind == "ident" and text == "file_path":
            before = toks[i - 1][1] if i else ""
            if (before == "." and assigned(toks, i, chain_end(toks, i + 1))) or (before in ("{", ",", "(") and nxt == "=" and field_given(toks, i)):
                found.append((line, "a location's file set by hand"))
    return found


def caller_param(toks, bodies, i, name):
    """Whether name, at i, is a parameter of the procedure i is in, given by default where it is called from."""
    b = innermost(bodies, i)
    if b is None:
        return False
    close = matching(toks, b[4])
    for k in range(b[4] + 1, close - 3):
        if toks[k][1] == name and toks[k - 1][1] in ("(", ",") and toks[k + 1][1] == ":=" and toks[k + 2][1] == "#" and toks[k + 3][1] == "caller_location":
            return True
    return False


def location_arguments(toks, bodies, testing_names):
    """In test code, each location given a call by name (`loc =`, `location =`), or by place to one of core:testing's
    FAILING, that is not what #caller_location or #location() gives here, nor a parameter given by default where it is
    called from: a failure said there would be said from wherever it was had, which quiet may not pass on."""
    found = []

    def fine(a, b):
        words = [t[1] for t in toks[a:b]]
        if words in (["#", "caller_location"], ["#", "location", "(", ")"]):
            return True
        return b - a == 1 and toks[a][0] == "ident" and caller_param(toks, bodies, a, toks[a][1])

    for i, (kind, text, line) in enumerate(toks):
        if kind != "ident" or i + 1 >= len(toks) or toks[i + 1][1] != "(" or (i and toks[i - 1][1] == "#"):
            continue
        close = matching(toks, i + 1)
        failing = i >= 2 and toks[i - 1][1] == "." and toks[i - 2][1] in testing_names and text in FAILING
        args = split_depth0(toks, i + 2, close, {","}) if close > i + 2 else []
        for place, (a, b) in enumerate(args):
            if b == a:
                continue  # after a trailing comma
            if b - a >= 2 and toks[a][0] == "ident" and toks[a + 1][1] == "=":
                if toks[a][1] in ("loc", "location") and not fine(a + 2, b):
                    found.append((toks[a][2], "a location given that is not where it is said from: a failure said with it may not be passed on"))
            elif failing and FAILING[text] is not None and place >= FAILING[text] and not fine(a, b):
                found.append((toks[a][2], "a location given that is not where it is said from: a failure said with it may not be passed on"))
    return found


# Of core:thread's procedures, which argument, by place, is the procedure the thread runs (core/thread/thread.odin,
# thread_pool.odin).
THREAD_PROC = {"create": 0, "create_and_start": 0, "run": 0, "create_and_start_with_data": 1, "run_with_data": 1,
               "create_and_start_with_poly_data": 1, "run_with_poly_data": 1, "create_and_start_with_poly_data2": 2,
               "run_with_poly_data2": 2, "create_and_start_with_poly_data3": 3, "run_with_poly_data3": 3,
               "create_and_start_with_poly_data4": 4, "run_with_poly_data4": 4, "pool_add_task": 2}
UNRESOLVED = "unresolved"


class Unit:
    """A file, as the thread rule reads it."""

    def __init__(self, path, src):
        self.path, self.src = path, src
        self.toks = tokens(src)
        self.bodies = proc_bodies(self.toks)
        named = imports(self.toks)
        self.imports = named
        self.testing = {a for a, p in named.items() if p == "core:testing"}
        self.thread = {a for a, p in named.items() if p == "core:thread"}
        self.procs, self.vars, depth = {}, set(), 0
        for b in self.bodies:
            if b[2] and innermost(self.bodies, b[0]) is None:
                self.procs.setdefault(b[2], []).append(b)
        for i, t in enumerate(self.toks):
            if t[0] == "punct" and t[1] in "([{":
                depth += 1
            elif t[0] == "punct" and t[1] in ")]}":
                depth -= 1
            elif depth == 0 and t[0] == "ident" and i + 1 < len(self.toks) and self.toks[i + 1][1] in (":", ":=") and targets_begin(self.toks, i):
                self.vars.add(t[1])  # a variable of the package's, whose value may be any procedure

    def annotated(self, line):
        """Whether the line, or the one before, says why what the thread rule cannot tell is fine: `// lint-thread: why`."""
        lines = self.src.splitlines()
        return any(0 < n <= len(lines) and re.search(r"//\s*lint-thread:\s*\S", lines[n - 1]) for n in (line, line - 1))


class Resolver:
    """Every procedure of every package here, by name, across all its files, test or not: what the thread rule follows."""

    def __init__(self, root):
        self.root = root
        self.units, self.dirs, self.memo = {}, {}, {}

    def unit(self, path, src=None):
        path = os.path.normpath(path)
        if path not in self.units:
            if src is None:
                with open(path, encoding="utf-8", errors="replace") as f:
                    src = f.read()
            self.units[path] = Unit(path, src)
        return self.units[path]

    def package(self, d):
        d = os.path.normpath(d)
        if d not in self.dirs:
            self.dirs[d] = [self.unit(os.path.join(d, n)) for n in sorted(os.listdir(d)) if n.endswith(".odin")] if os.path.isdir(d) else []
        return self.dirs[d]

    def procs(self, unit, name):
        """The procedures of unit's package named so, each as (unit, body); and whether a variable of it is."""
        refs, var = [], False
        for u in self.package(os.path.dirname(unit.path)):
            refs += [(u, b) for b in u.procs.get(name, [])]
            var = var or name in u.vars
        return refs, var

    def imported(self, unit, alias):
        """The directory of a package unit imports from here by alias, or None for core's, or one not imported."""
        p = unit.imports.get(alias)
        if p is None or not p.startswith("."):
            return None
        return os.path.normpath(os.path.join(os.path.dirname(unit.path), p))

    def value(self, unit, a, depth):
        """The procedures an expression at unit.toks[a] may be, as (unit, body) each, or UNRESOLVED: a literal, a name,
        another package's, or a field of a name; anything else may be any."""
        toks = unit.toks
        b = a
        while b < len(toks) and toks[b][1] not in (",", ")", "}", ";") and not (b > a and toks[b][2] > toks[b - 1][2] and ends_line(toks[b - 1])):
            if toks[b][0] == "punct" and toks[b][1] in ("(", "[", "{"):
                b = matching(toks, b)
            b += 1
        if depth > 12:
            return UNRESOLVED
        if toks[a][1] == "proc":
            lit = [x for x in unit.bodies if x[5] == a]
            return [(unit, lit[0])] if lit else []  # with no body, foreign (`---`) or a type: none of ours
        if b - a == 1 and toks[a][1] == "nil":
            return []
        if b - a == 1 and toks[a][0] == "ident":
            return self.name(unit, a, toks[a][1], depth + 1, strict=True)
        if b - a == 3 and toks[a][0] == "ident" and toks[a + 1][1] == "." and toks[a + 2][0] == "ident":
            if toks[a][1] in unit.imports:
                return self.external(unit, toks[a][1], toks[a + 2][1])
            return self.field(unit, a, toks[a][1], toks[a + 2][1], depth + 1)
        return UNRESOLVED

    def external(self, unit, alias, name):
        d = self.imported(unit, alias)
        if d is None:
            return []  # core's, which says no test's failures but through what is given it, followed where it is given
        refs = [(u, b) for u in self.package(d) for b in u.procs.get(name, [])]
        if any(name in u.vars for u in self.package(d)):
            return UNRESOLVED
        return refs

    def name(self, unit, i, name, depth, strict=False):
        """What a name at i may be, as procedures: a local's every value, a parameter's any, the package's procedures of
        that name; nothing, if it is none of these (a type, a constant, the language's own), or UNRESOLVED if strict."""
        toks, refs = unit.toks, []
        b = innermost(unit.bodies, i)
        while b is not None:
            close = matching(toks, b[4])
            params = split_depth0(toks, b[4] + 1, close, {","}) if close > b[4] + 1 else []
            for place, (pa, pb) in enumerate(params):
                if pb > pa and toks[pa][1] == name and (pa + 1 == pb or toks[pa + 1][1] in (":", ":=", ",")):
                    return self.parameter(unit, b, place, name, params, depth)
            declared = False
            for k in range(b[0] + 1, b[1]):
                if toks[k][1] != name or toks[k][0] != "ident" or (k and toks[k - 1][1] == "."):
                    continue
                op = toks[k + 1][1] if k + 1 < len(toks) else ""
                if op in ("::", ":=", ":", "=") and targets_begin(toks, k):
                    declared = declared or op != "="
                    if op == "::":
                        v = toks[k + 2][1] if k + 2 < len(toks) else ""
                        r = self.value(unit, k + 2, depth) if v == "proc" else []
                    elif op == ":":
                        eq = [x for x in range(k + 2, len(toks)) if toks[x][1] == "=" or toks[x][2] > toks[k][2]]
                        r = self.value(unit, eq[0] + 1, depth) if eq and toks[eq[0]][1] == "=" else UNRESOLVED
                    else:
                        r = self.value(unit, k + 2, depth)
                    if r == UNRESOLVED:
                        return UNRESOLVED
                    refs += r
            if declared:
                return refs
            b = innermost(unit.bodies, b[0])
        found, var = self.procs(unit, name)
        if var:
            return self.assigned_values(unit, name, depth)
        if not found and strict:
            return UNRESOLVED
        return found

    def parameter(self, unit, b, place, name, params, depth):
        """What a parameter may be, as procedures: what each call of its procedure gives it, by place or by name, or its
        default where it is given nothing; UNRESOLVED if the procedure is a literal, called where the lint cannot see,
        or is variadic there. Its calls are looked for in its package, and, but for one of the package's own
        (`@(private)`), in each package here that imports it."""
        toks = unit.toks
        if depth > 12 or b[2] is None or innermost(unit.bodies, b[0]) is not None:
            return UNRESOLVED
        pa, pb = params[place]
        if any(toks[x][1] == ".." for x in range(pa, pb)):
            return UNRESOLVED
        default = next((x + 1 for x in range(pa, pb) if toks[x][1] in ("=", ":=")), None)
        decl = b[5] - 2
        private = any(toks[x][1] == "private" for x in range(max(0, decl - 8), decl) if toks[x][2] >= toks[decl][2] - 1)
        here = os.path.dirname(unit.path)
        places = [(u, None) for u in self.package(here)]
        if not private:
            for d in self.all_dirs():
                for u in self.package(d):
                    places += [(u, a) for a, p in u.imports.items() if p.startswith(".") and self.imported(u, a) == os.path.normpath(here)]
        refs, calls = [], 0
        for u, alias in places:
            ut = u.toks
            for k in range(len(ut) - 1):
                if ut[k][1] != b[2] or ut[k + 1][1] != "(" or (u is unit and k == decl):
                    continue
                if alias is None and k and ut[k - 1][1] == ".":
                    continue
                if alias is not None and not (k >= 2 and ut[k - 1][1] == "." and ut[k - 2][1] == alias):
                    continue
                calls += 1
                close = matching(ut, k + 1)
                args = [x for x in (split_depth0(ut, k + 2, close, {","}) if close > k + 2 else []) if x[1] > x[0]]
                given = next((a + 2 for a, e in args if e - a >= 2 and ut[a][1] == name and ut[a + 1][1] == "="), None)
                if given is None and place < len(args) and not (ut[args[place][0] + 1][1] == "=" and ut[args[place][0]][0] == "ident"):
                    given = args[place][0]
                if given is not None:
                    r = self.value(u, given, depth + 1)
                elif default is not None:
                    r = self.value(unit, default, depth + 1)
                else:
                    r = UNRESOLVED
                if r == UNRESOLVED:
                    return UNRESOLVED
                refs += r
        return refs

    def all_dirs(self):
        if not hasattr(self, "_dirs"):
            self._dirs = []
            for d, dirs, files in os.walk(self.root):
                dirs[:] = sorted(x for x in dirs if x not in ("node_modules", ".git"))
                if any(f.endswith(".odin") for f in files):
                    self._dirs.append(os.path.normpath(d))
        return self._dirs

    def of_context(self, unit, a):
        """Whether the owner at a is the context's logger or allocator, or a local copy of either: whose procedure, in a
        thread given no context, is runtime.default_context()'s, and anywhere is the runner's, quiet's, or one set in a
        package main's main, the lint holding everything else to that."""
        toks = unit.toks
        if a >= 2 and toks[a - 1][1] == "." and toks[a - 2][1] == "context" and toks[a][1] in ("logger", "allocator", "temp_allocator"):
            return True
        b = innermost(unit.bodies, a)
        while b is not None:
            for k in range(b[0] + 1, b[1] - 3):
                if toks[k][1] == toks[a][1] and toks[k + 1][1] == ":=" and toks[k + 2][1] == "context" and toks[k + 3][1] == "." and toks[k + 4][1] in ("logger", "allocator", "temp_allocator") and targets_begin(toks, k):
                    return True
            b = innermost(unit.bodies, b[0])
        return False

    def assigned_values(self, unit, name, depth):
        """What a variable of unit's package may be, as procedures: each value it is given, in any of its files."""
        refs = []
        for u in self.package(os.path.dirname(unit.path)):
            toks = u.toks
            for k in range(len(toks) - 2):
                if toks[k][1] != name or toks[k][0] != "ident" or (k and toks[k - 1][1] == ".") or not targets_begin(toks, k):
                    continue
                op = toks[k + 1][1]
                if op in ("=", ":="):
                    r = self.value(u, k + 2, depth + 1)
                elif op == ":":
                    eq = next((x for x in range(k + 2, len(toks)) if toks[x][1] == "=" or toks[x][2] > toks[k][2]), None)
                    if eq is None or toks[eq][1] != "=":
                        continue  # declared, given nothing: nil
                    r = self.value(u, eq + 1, depth + 1)
                else:
                    continue
                if r == UNRESOLVED:
                    return UNRESOLVED
                refs += r
        return refs

    def local(self, unit, i, name):
        """Whether name, at i, is a parameter or a local of the procedures it is in."""
        toks = unit.toks
        b = innermost(unit.bodies, i)
        while b is not None:
            close = matching(toks, b[4])
            if any(toks[k][1] == name and toks[k - 1][1] in ("(", ",") and toks[k + 1][1] in (":", ":=") for k in range(b[4] + 1, close)):
                return True
            if any(toks[k][1] == name and toks[k + 1][1] in ("::", ":=", ":") and toks[k - 1][1] != "." and targets_begin(toks, k) for k in range(b[0] + 1, b[1])):
                return True
            b = innermost(unit.bodies, b[0])
        return False

    def field(self, unit, i, owner, field, depth):
        """What owner.field may be, as procedures: each value it is given in the file, `owner.field = v`, or in a literal
        owner is made with, `owner := T{field = v}`; UNRESOLVED if it is given none there, or one that cannot be told."""
        toks, refs, given = unit.toks, [], False
        for k in range(len(toks) - 3):
            if toks[k][1] != owner or toks[k][0] != "ident" or (k and toks[k - 1][1] == "."):
                continue
            if toks[k + 1][1] == "." and toks[k + 2][1] == field and toks[k + 3][1] == "=":
                r, given = self.value(unit, k + 4, depth), True
            elif toks[k + 1][1] in (":=", "=", ":") and targets_begin(toks, k):
                lit = next((x for x in range(k + 2, min(len(toks), k + 8)) if toks[x][1] == "{"), None)
                if lit is None:
                    continue
                r = []
                for a, b in split_depth0(toks, lit + 1, matching(toks, lit), {","}):
                    if b - a >= 3 and toks[a][1] == field and toks[a + 1][1] == "=":
                        r, given = self.value(unit, a + 2, depth), True
            else:
                continue
            if r == UNRESOLVED:
                return UNRESOLVED
            refs += r
        return refs if given else UNRESOLVED

    def says(self, unit, body, seen=None):
        """Whether a procedure may say a test's failures: as (where, why) if it may, else None. It may if it names
        core:testing; or calls, or names, a procedure that may; or calls one through a value the lint cannot tell,
        unless that line says why it is fine (`// lint-thread: why`)."""
        key = (unit.path, body[0])
        top = seen is None
        if key in self.memo:
            return self.memo[key]
        seen = set() if top else seen
        if key in seen:
            return None
        seen.add(key)
        toks, out = unit.toks, None
        rel = os.path.relpath(unit.path, self.root)
        for a in range(body[0] + 1, body[1]):
            kind, text, line = toks[a]
            if kind != "ident" or text in KEYWORDS:
                continue
            before = toks[a - 1][1]
            call = a + 1 < len(toks) and toks[a + 1][1] == "("
            if text in unit.testing and toks[a + 1][1] == ".":
                out = (f"{rel}:{line}", "names core:testing")
                break
            if before == "#":
                continue
            if before == "." and call and text == "procedure" and toks[a - 2][0] == "ident" and self.of_context(unit, a - 2):
                continue  # the context's logger or allocator
            if before == "." and toks[a - 2][0] == "ident" and (a < 3 or toks[a - 3][1] != "."):
                owner = toks[a - 2][1]
                if owner in unit.imports:
                    refs = self.external(unit, owner, text)
                elif call:
                    refs = self.field(unit, a - 2, owner, text, 0)
                else:
                    continue
            elif before == "." and call:
                refs = UNRESOLVED  # a field of a field, or of what an expression gives
            elif before == ".":
                continue
            elif call:
                refs = self.name(unit, a, text, 0)
            elif toks[a + 1][1] in (":", "::", ":=", "=") or self.local(unit, a, text):
                continue  # what is declared or given, or a local, called where it is called
            else:
                refs = self.procs(unit, text)[0]  # a procedure named, given to whatever may call it
            if refs == UNRESOLVED:
                if unit.annotated(line):
                    continue
                out = (f"{rel}:{line}", f"calls {text} through a value the lint cannot tell")
                break
            for u, b in refs:
                out = self.says(u, b, seen)
                if out:
                    break
            if out:
                break
        if top:
            self.memo[key] = out  # what is found within a cycle may want what it is in, not yet known
        return out


def thread_failures(unit, resolver):
    """A thread started that may say a test's failures, with no logger of the test's: core:thread starts a thread given
    no context with runtime.default_context(), whose logger says nothing. Each call of core:thread given no `context`
    itself, whose procedure may (Resolver.says), or is one the lint cannot tell, unless it says why it is fine
    (`// lint-thread: why`)."""
    found, toks = [], unit.toks
    for i, (kind, text, line) in enumerate(toks):
        if kind != "ident" or text not in unit.thread or i + 3 >= len(toks) or toks[i + 1][1] != "." or toks[i + 3][1] != "(":
            continue
        what = toks[i + 2][1]
        k = i + 3
        close = matching(toks, k)
        args = split_depth0(toks, k + 1, close, {","}) if close > k + 1 else []
        procs = []
        for place, (a, b) in enumerate(args):
            if b - a >= 2 and toks[a][0] == "ident" and toks[a + 1][1] == "=":
                if toks[a][1] in ("fn", "procedure"):
                    procs.append(a + 2)
            elif THREAD_PROC.get(what) == place or (what not in THREAD_PROC and toks[a][1] == "proc"):
                procs.append(a)
        inner = [b for b in unit.bodies if k < b[0] < close]
        if any(toks[a][0] == "ident" and toks[a][1] == "context" and not any(b[0] < a < b[1] for b in inner) for a in range(k + 1, close)):
            continue
        if unit.annotated(line):
            continue
        for a in procs:
            refs = resolver.value(unit, a, 0)
            if refs == UNRESOLVED:
                found.append((line, f"a thread whose procedure the lint cannot tell is given no context: give it the test's (init_context = context), or say why it is fine (// lint-thread: why)"))
                continue
            for u, b in refs:
                says = resolver.says(u, b)
                if says:
                    found.append((line, f"a thread that may say a test's failures ({says[1]}, {says[0]}) is given no context, and so no logger of the test's: give it the test's (init_context = context), or say why it is fine (// lint-thread: why)"))
                    break
    return found


def lint_file(path, src, wasi_built, under_test=False, in_helper=False, main_only=frozenset(), resolver=None):
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
    test_code = os.path.basename(path).endswith("_test.odin") or "core:testing" in by_path
    if "core:testing" in by_path and not os.path.basename(path).endswith("_test.odin") and not in_helper:
        line = next(t[2] for t in toks if t[0] == "string" and t[1] == "core:testing")
        found.append((line, "core:testing imported outside a _test.odin file: a failure said from it is said from a line testlog.quiet does not pass on", LOGGER_ISSUE))
    resolver = resolver or Resolver(os.path.dirname(os.path.abspath(path)))
    unit = resolver.unit(path, src)
    for line, what in logger_uses(toks, named, test_code, under_test and not test_code, in_helper, main_only, unit, resolver):
        found.append((line, what, LOGGER_ISSUE))
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


def tested_packages(root):
    """The package directories `odin test` builds: those with a _test.odin file, and what they import from here, all the
    way down."""
    todo, seen = set(), set()
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in ("node_modules", ".git")]
        if any(f.endswith("_test.odin") for f in files):
            todo.add(os.path.normpath(d))
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


def package_name(toks):
    for i, t in enumerate(toks[:-1]):
        if t[0] == "ident" and t[1] == "package":
            return toks[i + 1][1]
    return None


def main_only(sources):
    """Of a package main's files ({path: source}), main and the procedures declared in them that only main calls, or
    another of these: each named somewhere in the package, and nowhere but in the body of one, outside its own. `odin
    test` runs none of them, as it runs no main but its own; and no package main is imported. Of another package's,
    none."""
    found = {}
    names = {}
    for path, src in sources.items():
        toks = tokens(src)
        if package_name(toks) != "main":
            return set()
        bodies = proc_bodies(toks)
        found[path] = (toks, bodies)
        for b in bodies:
            if b[2] and innermost(bodies, b[0]) is None:
                names[b[2]] = names.get(b[2], 0) + 1
    only = {"main"}
    while True:
        grown = set(only)
        for name, count in names.items():
            if name in only or count != 1:
                continue
            ok, named = True, False
            for toks, bodies in found.values():
                for i, t in enumerate(toks):
                    if t[0] != "ident" or t[1] != name or (i + 1 < len(toks) and toks[i + 1][1] == "::"):
                        continue
                    b = innermost(bodies, i)
                    while b is not None and innermost(bodies, b[0]) is not None:
                        b = innermost(bodies, b[0])
                    named = True
                    if b is None or b[2] not in only or b[2] == name:
                        ok = False
            if ok and named:
                grown.add(name)
        if grown == only:
            return only
        only = grown


def is_repro(rel, src):
    """Whether a file is one of the repros of what is broken, which must use it: in tests/upstream, and saying so in its
    first line."""
    parts = rel.replace(os.sep, "/").split("/")
    return parts[:2] == ["tests", "upstream"] and re.match(r"// Reproduces \S", src) is not None


def lint(root):
    """Each use under root, as (path, line, what, issue)."""
    wasi = wasi_packages(root)
    tested = tested_packages(root)
    helper = os.path.normpath(os.path.join(root, "tests", "testlog"))
    resolver = Resolver(root)
    mains = {}
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
                pkg = os.path.normpath(d)
                if pkg in tested and pkg not in mains:
                    sources = {}
                    for other in sorted(os.listdir(pkg)):
                        if other.endswith(".odin"):
                            with open(os.path.join(pkg, other), encoding="utf-8", errors="replace") as f:
                                sources[other] = f.read()
                    mains[pkg] = frozenset(main_only(sources))
                for line, what, issue in lint_file(path, src, pkg in wasi, pkg in tested, pkg == helper, mains.get(pkg, frozenset()), resolver):
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
    "d/quiet_test.odin": """package d
import "base:runtime"
import "core:log"
import "core:testing"
import "core:thread"
import "../tests/testlog"
import tl "../tests/testlog"
import "../e"
q :: proc(t: ^testing.T) {
	quieted: testlog.Quiet
	context.logger = testlog.quiet(t, &quieted, .Code_Under_Test)
	context.logger = tl.quiet(t, &quieted, .Below_Errors) // and a comment
	context.logger = testlog.quiet(
		t, &quieted, .Below_Errors,
	)
	if t != nil { context.logger = testlog.quiet(t, &quieted, .Below_Errors) }
	saved := context.logger
	logger := context.logger
	logger = context.logger
	a, logger2 := 1, context.logger
	b, logger = 2, saved
	{
		logger = saved
	}
	_, _, _ = a, b, logger2
	context.logger.procedure(context.logger.data, .Info, "x", context.logger.options)
	l := runtime.Logger{lowest_level = context.logger.lowest_level, procedure = context.logger.procedure}
	_ = l
	context.allocator = context.temp_allocator
	_ = "context.logger = log.nil_logger()"
	// context.logger = log.nil_logger()
	/* context = runtime.default_context() */
	e.run(t)
	th := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) {
		testing.expect(t, true)
	}, init_context = context)
	thread.join(th)
	th2 := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) {
		log.info("nothing of the test's")
	})
	thread.join(th2)
	th3 := thread.create_and_start_with_poly_data(t, says, context)
	thread.join(th3)
}
says :: proc(t: ^testing.T) {
	testing.expect(t, true)
}
""",
    "d/flagged_test.odin": """package d
import "base:runtime"
import "core:log"
import "core:testing"
import "core:thread"
import "../tests/testlog"
import other "../e"
Holder :: struct { ctx: runtime.Context }
f :: proc(t: ^testing.T) {
	q: testlog.Quiet
	context.logger = log.nil_logger() // use logger
	context.logger = runtime.Logger{} // use logger
	context . logger = // use logger
		log.nil_logger()
	context. // use logger
		logger = log.nil_logger()
	saved := context.logger
	defer context.logger = saved // use logger
	context.logger.lowest_level = .Error // use logger
	context.logger.options = {} // use logger
	context = runtime.default_context() // use logger
	ctx := context
	ctx.logger = log.nil_logger() // use logger
	ctx.logger.data = nil // use logger
	holder: Holder
	holder.ctx.logger = saved // use logger
	ctx2 := runtime.Context{logger = log.nil_logger()} // use logger
	ctx3 := runtime.Context{
		allocator = context.allocator,
		logger = saved, // use logger
	}
	p := &context // use logger
	pl := &context.logger // use logger
	_, _, _, _ = ctx2, ctx3, p, pl
	context.logger, ctx.allocator = saved, ctx.allocator // use logger
	context.logger = testlog.quiet(t, &q, .Below_Errors) if t != nil else saved // use logger
	context.logger = other.quiet(t, &q, .Below_Errors) // use logger
	context.logger = quiet(t, &q, .Below_Errors) // use logger
	if t != nil do context.logger = saved // use logger
	th := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) { // use logger
		testing.expect(t, false)
	})
	th2 := thread.create_and_start_with_poly_data(t, fails) // use logger
	th3 := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) { // use logger
		testing.expect(t, false)
	}, init_context = runtime.default_context())
	_, _, _ = th, th2, th3
}
fails :: proc(t: ^testing.T) {
	testing.expect(t, false)
}
""",
    "d/helpers.odin": """package d
import "core:testing" // use logger
h :: proc(t: ^testing.T) { testing.expect(t, false) }
""",
    "e/e.odin": """package e
import "base:runtime"
import "core:log"
run :: proc(_: rawptr) {
	context.logger = log.nil_logger() // use logger
	context = runtime.default_context() // use logger
	ctx := context
	ctx.logger = log.nil_logger() // use logger
	_ = ctx
	logger := context.logger
	_ = logger
}
main :: proc() {
	context.logger = log.nil_logger() // use logger
}
signalled :: proc "system" () {
	context = runtime.default_context()
	context.logger = log.nil_logger() // use logger
}
none :: proc "contextless" () {
	context = runtime.default_context()
}
""",
    "g/g.odin": """package main
import "base:runtime"
import "core:log"
main :: proc() {
	context.logger = log.nil_logger()
	start()
	both()
	_ = proc() { context.logger = log.nil_logger() }
}
start :: proc() {
	context.logger = log.nil_logger()
	context = runtime.default_context()
	deeper()
}
deeper :: proc() { context.logger = log.nil_logger() }
both :: proc() { context.logger = log.nil_logger() } // use logger
unnamed :: proc() { context.logger = log.nil_logger() } // use logger
""",
    "g/g_test.odin": """package main
import "core:testing"
t :: proc(t: ^testing.T) { both() }
""",
    "d/threads_test.odin": """package d
import "base:runtime"
import "core:testing"
import "core:thread"
import "../e"
Work :: struct { t: ^testing.T, fn: proc(t: ^testing.T), go: proc(t: ^testing.T) }
foreign import libc "system:c"
foreign libc { getpid :: proc "c" () -> i32 --- }
hook: proc(t: ^testing.T)
threads :: proc(t: ^testing.T, given: proc(t: ^testing.T)) {
	hook = fails_elsewhere
	a := thread.create_and_start_with_poly_data(t, fails_elsewhere) // use logger
	b := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) { // use logger
		check_elsewhere(t)
	})
	p := fails_elsewhere
	c := thread.create_and_start_with_poly_data(t, p) // use logger
	w := Work{t = t, fn = fails_elsewhere}
	d := thread.create_and_start_with_poly_data(t, w.fn) // use logger
	ee := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) { // use logger
		hook(t)
	})
	_ = ee
	f := thread.create_and_start_with_poly_data(t, pick()) // use logger
	g := thread.create_and_start_with_poly_data(t, pick()) // lint-thread: pick gives one that says nothing

	h := thread.create_and_start_with_poly_data(&w, proc(w: ^Work) { // use logger
		w.go(w.t)
	})
	i := thread.create_and_start_with_poly_data(&w, proc(w: ^Work) {
		w.go(w.t) // lint-thread: what is given go here says nothing
	})
	j := thread.create_and_start_with_poly_data(t, given) // use logger
	q := quiet_elsewhere
	k := thread.create_and_start_with_poly_data(t, q)
	l := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) {
		_ = getpid()
		_ = len("x")
		_ = runtime.default_logger()
	})
	m := thread.create_and_start_with_poly_data(t, fails_elsewhere, context)
	n := thread.create_and_start_with_poly_data(t, proc(t: ^testing.T) {
		l := context.logger
		l.procedure(l.data, .Info, "x", l.options)
		context.allocator.procedure(nil, .Free_All, 0, 0, nil, 0)
	})
	o := thread.create_and_start(proc() { // use logger
		data := new(int)
		free(data)
		hooks.fn(nil)
	})
	r := thread.create_and_start(proc() { // use logger
		e.fire()
	})
	s := thread.create_and_start(proc() {
		e.made()
	})
	_, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _, _ = a, b, c, d, f, g, h, i, j, k, l, m, n, o, r, s
}
hooks: Work
run_given :: proc(t: ^testing.T) { threads(t, fails_elsewhere) }
pick :: proc() -> proc(t: ^testing.T) { return quiet_elsewhere }
""",
    "d/elsewhere_test.odin": """package d
import "core:testing"
fails_elsewhere :: proc(t: ^testing.T) {
	testing.expect(t, false)
}
check_elsewhere :: proc(t: ^testing.T) {
	fails_elsewhere(t)
}
quiet_elsewhere :: proc(t: ^testing.T) {
	_ = t
}
""",
    "d/locations_test.odin": """package d
import "base:runtime"
import "core:testing"
check :: proc(t: ^testing.T, ok: bool, loc := #caller_location) {
	testing.expect(t, ok, loc = loc)
	testing.expect(t, ok, "m", "e", loc)
}
locations :: proc(t: ^testing.T) {
	testing.expect(t, true, loc = #location())
	testing.expect(t, true, "m", "e")
	testing.expect_value(t, 1, 1)
	testing.expect_value(
		t,
		1,
		1,
	)
	check(t, true)
	check(t, true, loc = #location())
	here := #location()
	_ = here.line
	l := runtime.Source_Code_Location{file_path = "host/host.odin"} // use logger
	testing.expect(t, false, loc = {file_path = "host/host.odin"}) // use logger
	testing.expect(t, false, "m", "e", here) // use logger
	testing.expect_value(t, 1, 2, here) // use logger
	testing.fail(t, here) // use logger
	testing.expect(t, false, loc = #location(check)) // use logger
	check(t, false, loc = here) // use logger
	check(t, false, loc = l) // use logger
	x: type_of(#location()) // use logger
	here.file_path = "host/host.odin" // use logger
	_ = x
}
""",
    "e/locations.odin": """package e
import "base:runtime"
Hooks :: struct { on: proc() }
hooks: Hooks
fire :: proc() { hooks.on() }
takes :: proc(l: runtime.Source_Code_Location, loc := #caller_location) { _, _ = l, loc }
gives :: proc() -> runtime.Source_Code_Location { return #location() } // use logger
Hook :: proc(l: runtime.Source_Code_Location) // use logger
Holder :: struct { l: runtime.Source_Code_Location } // use logger
made :: proc() {
	l := #location()
	l.file_path = "x_test.odin" // use logger
	takes(l)
}
""",
    "f/f.odin": """package f
import "base:runtime"
import "core:log"
g :: proc() {
	context.logger = log.nil_logger()
	context = runtime.default_context()
	_ = runtime.Source_Code_Location{file_path = "x_test.odin"}
}
""",
    "tests/testlog/testlog.odin": """package testlog
import "core:testing"
quiet :: proc(t: ^testing.T) -> int { return 0 }
""",
    "tests/testlog/testlog_test.odin": """package testlog
import "core:log"
import "core:testing"
q :: proc(t: ^testing.T) {
	context.logger = quiet(t)
	context.logger = log.nil_logger() // use logger
}
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
                m = re.search(r"// use( 8646| option| logger)?$", line.rstrip())
                if m:
                    issue = {None: ISSUE, " 8646": TRUNC_ISSUE, " option": OPTION_ISSUE, " logger": LOGGER_ISSUE}[m.group(1)]
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
        each = {i: sum(1 for w in want if w[2] == i) for i in (ISSUE, TRUNC_ISSUE, OPTION_ISSUE, LOGGER_ISSUE)}
        print(f"ok   the lint finds each of the {each[ISSUE]} uses of what {ISSUE} breaks, the {each[TRUNC_ISSUE]} of what"
              f" {TRUNC_ISSUE} does, the {each[OPTION_ISSUE]} of {OPTION_ISSUE}, and the {each[LOGGER_ISSUE]} places a"
              " test's logger is set but through testlog.quiet, put in its fixtures, however written, and nothing else")
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
        if issue == LOGGER_ISSUE:
            print(f"FAIL {n} places a test's logger is set but through testlog.quiet, which may lose a failure: see tests/testlog/testlog.odin")
            continue
        where = f"see https://github.com/{issue.replace('#', '/issues/')}" if "#" in issue else "see third_party/nbio/socket_option.odin"
        print(f"FAIL {n} uses of what {issue} breaks: {where}")
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
