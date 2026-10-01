#!/usr/bin/env bash
# line-citations.test.sh - a comment cites another file's code by SYMBOL, never
# by line number. A `<file>:<N>` pointer into another tracked file goes stale at
# that file's next edit, and nothing reads the comment to notice: three sweeps
# in two months each found most such citations already pointing at the wrong
# code (the last, 123 of 143). A backtick-wrapped `x.sh:N` is an example of the
# format, not a citation, and stays legal.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

hits="$(cd "$ROOT" && git ls-files -z -- 'bin/*.sh' 'src/*.ts' 'dashboard/*.ts' 'tests/*.sh' 'tests/*.ts' \
  | python3 -c '
import os, re, sys
files = [f for f in sys.stdin.read().split("\0") if f]
tracked = {os.path.basename(f) for f in os.popen("git ls-files").read().split()}
cite = re.compile(r"(?<![A-Za-z0-9_.-])([A-Za-z0-9_./-]*[A-Za-z0-9_-]\.(?:sh|ts|md|awk|json)):[0-9]+")
comment = re.compile(r"^\s*(#|//|\*|/\*)")
for f in files:
    for n, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
        if not comment.match(line):
            continue
        for m in cite.finditer(re.sub(r"`[^`]*`", "", line)):
            base = os.path.basename(m.group(1))
            if base in tracked and base != os.path.basename(f):
                print(f"{f}:{n}: {m.group(0)}")
')"
assert_eq "$hits" "" "comments cite another file's code by symbol, never by line number"

pass
