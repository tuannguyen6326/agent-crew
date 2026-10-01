#!/usr/bin/env bash
# ac-backlog-sections.test.sh - a `## ` heading the grammar does not name (a
# hand-written `## Parked` or `## Notes`) ends the section above it, at every
# ledger reader. Six readers carried the previous section through it, so a
# note row under `## Notes` read as Done - satisfying a blocker, counted,
# offered for archiving - and a row under `## Parked` read as Queued and READY.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }
# shellcheck source=../../bin/ac-lib.sh
. "$BIN/ac-lib.sh"

make_home
ledger="$AC_HOME/records/backlog.md"
write_ledger() {
  cat >"$ledger" <<'EOF'
# Backlog

## In flight
- [ ] f1 - flying (repo: r, since 2026-01-01)

## Queued
- [ ] q1 - waits on the note row (repo: r) blocked-by: n1 - needs n1
- [ ] q2 - free to start (repo: r)

## Parked
- [ ] p1 - parked by hand; domain:dom

## Done
- [x] d1 - landed - local main (merged 2026-01-01)

## Notes
- [ ] n1 - a hand-written note row
- [x] n2 - an old checked note (merged 2025-01-01); domain:dom
EOF
}

write_ledger
ready="$("$BIN/ac-ready.sh")"
assert_contains "$ready" "READY  q2" "a free Queued row is ready"
case "$ready" in *"READY  q1"*) fail "a blocker under ## Notes is no Done row - q1 must stay blocked: $ready" ;; esac
case "$ready" in *p1*) fail "a row under ## Parked is not Queued: $ready" ;; esac
case "$("$BIN/ac-ready.sh" queued)" in *p1*) fail "ac-ready queued must not list a row under ## Parked" ;; esac

assert_eq "$(ac_domain_tally dom)" "0 0 0" "ac_domain_tally counts no row outside the three sections"

assert_contains "$("$BIN/ac-dash.sh" 2>/dev/null)" "in-flight:1  queued:2  done:1" \
  "the dashboard counts only rows inside the three sections"

curate="$(AC_CURATE_KEEP=0 "$BIN/ac-curate.sh" backlog)"
assert_contains "$curate" "move | - [x] d1" "a real Done row past keep is offered"
case "$curate" in *"- [x] n2"*) fail "curate must never archive a row under ## Notes: $curate" ;; esac

out="$("$BIN/ac-task.sh" start p1)"
case "$out" in ok*) fail "ac-task start must refuse a row under ## Parked: $out" ;; esac
assert_contains "$out" "no section" "...and say the row sits outside every section"
rc=0; out="$("$BIN/ac-task.sh" start q1 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "ac-task start must refuse q1 while its blocker sits under ## Notes: $out"
assert_contains "$out" "n1 (no section)" "...naming the blocker and where it sits"
out="$("$BIN/ac-task.sh" done n1 'resolved by hand')"
assert_contains "$out" "ok: merged n1" "a note row is not already Done - done moves it"
assert_eq "$(awk '/^## Done/{d=1;next} /^## /{d=0} d && /^- \[x\] n1 /{print "in-done"}' "$ledger")" "in-done" \
  "...into the Done section"
# A row already checked carries its outcome: it moves into Done as written -
# never re-checked into `- [x] - [x] n2`, whose id would parse as `-`.
out="$("$BIN/ac-task.sh" done n2 'resolved by hand')"
assert_contains "$out" "already checked" "a checked row says it moved as written"
assert_eq "$(awk '/^## Done/{d=1;next} /^## /{d=0} d' "$ledger" | grep -c '^- \[x\] n2 - an old checked note (merged 2025-01-01); domain:dom$')" "1" \
  "...byte for byte, into the Done section"
assert_contains "$("$BIN/ac-task.sh" done n2 'again')" "already: n2 is Done" "a second done is a no-op"

pass
