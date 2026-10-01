#!/usr/bin/env bash
# line-citations.test.sh - a comment cites another file's code by SYMBOL, never
# by line number. A `<file>:<N>` pointer into another tracked file goes stale at
# that file's next edit, and nothing reads the comment to notice: three sweeps
# in two months each found most such citations already pointing at the wrong
# code (the last, 123 of 143). A backtick-wrapped `x.sh:N` is an example of the
# format, not a citation, and stays legal.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# scan <repo> - every comment line in the repo's tracked bin/, src/, dashboard/
# and tests/ sources that cites a line of ANOTHER tracked file. A citation is
# the citing file's own only when the path as written resolves to it - two
# tracked files may share a basename (src/lib.ts, dashboard/lib.ts).
scan() {
  (cd "$1" && git ls-files -z -- 'bin/*.sh' 'src/*.ts' 'dashboard/*.ts' 'tests/*.sh' 'tests/*.ts' \
    | python3 -c '
import os, re, sys
files = [f for f in sys.stdin.read().split("\0") if f]
tracked = os.popen("git ls-files").read().split()
cite = re.compile(r"(?<![A-Za-z0-9_.-])([A-Za-z0-9_./-]*[A-Za-z0-9_-]\.(?:sh|ts|md|awk|json)):[0-9]+")
comment = re.compile(r"^\s*(#|//|\*|/\*)")
names = lambda f, c: f == c or f.endswith("/" + c)
for f in files:
    for n, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        if not comment.match(line):
            continue
        for m in cite.finditer(re.sub(r"`[^`]*`", "", line)):
            c = m.group(1)
            if any(names(t, c) for t in tracked) and not names(f, c):
                print(f"{f}:{n}: {m.group(0)}")
')
}

assert_eq "$(scan "$ROOT")" "" "comments cite another file's code by symbol, never by line number"

# The guard itself: a cross-file citation between two files that share a
# basename is caught, while a self-citation and a backticked example are not.
fx="$TMP/citations-fixture"
mkdir -p "$fx/src" "$fx/dashboard"
printf '// the twin lives at dashboard/lib.ts:25\n// see lib.ts:3 below\n// e.g. `bin/x.sh:9`\nexport {};\n' >"$fx/src/lib.ts"
printf 'export {};\n' >"$fx/dashboard/lib.ts"
printf '#!/bin/sh\n' >"$fx/src/x.sh"
mkdir -p "$fx/bin"; printf '#!/bin/sh\n' >"$fx/bin/x.sh"
git -C "$fx" init -q && git -C "$fx" add -A
assert_eq "$(scan "$fx")" "src/lib.ts:1: dashboard/lib.ts:25" \
  "a citation into a same-basename file is cross-file; a self-citation and a backticked example are not"

pass
