#!/usr/bin/env bash
# grep-q-pipes.test.sh - no script in bin/ or tests/ pipes into `grep -q`.
# Under pipefail, `writer | grep -q` reads a match as a miss whenever grep
# exits on its first match while the writer still has output: the writer
# dies on the closed pipe (SIGPIPE, or EPIPE where that is ignored) and the
# pipeline fails - a registered domain read as an orphan, a read knob counted
# as unread. A here-string or a process substitution feeds grep with no
# writer in the pipeline.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

big="MATCH
$(head -c 200000 /dev/zero | tr '\0' x)"
rc=0; printf '%s\n' "$big" 2>/dev/null | grep -q MATCH || rc=$?
[ "$rc" != 0 ] || fail "the hazard: a writer past the pipe buffer dies on the closed pipe, and the match reads as a miss"
grep -q MATCH <<<"$big" || fail "a here-string reads the same match as a match"

hits="$(LC_ALL=C grep -n -E '(^|[^|])\|[[:space:]]*grep([[:space:]]+-[[:alnum:]]+)*[[:space:]]+-[[:alpha:]]*q' \
  "$BIN"/*.sh "$ROOT"/tests/sh/*.sh | LC_ALL=C grep -v -E '^[^:]+:[0-9]+:[[:space:]]*#|/grep-q-pipes\.test\.sh:' || true)"
assert_eq "$hits" "" "no bin/ or tests/ script pipes into grep -q"

pass
