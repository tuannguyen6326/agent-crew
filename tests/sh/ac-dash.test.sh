#!/usr/bin/env bash
# ac-dash.test.sh - the captain dashboard: sections render, crew and
# pending rooms appear, backlog counts add up, colors off when piped.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# Empty fleet renders every section with placeholders.
out="$("$BIN/ac-dash.sh")"
assert_contains "$out" "⚓ home" "header shows the fleet"
assert_contains "$out" "no crewmates in flight" "empty crew"
assert_contains "$out" "no rooms yet" "empty rooms"
assert_contains "$out" "no worktree pools yet" "empty pools"
case "$out" in *$'\033'*) fail "colors must be off when piped" ;; esac

# Crew, rooms, backlog and pools all show up.
printf 'kind=ship\nproject=alpha\nbackend=tmux\n' >"$AC_HOME/state/t1.meta"
printf '%s done: shipped\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/state/t1.status"
"$BIN/ac-room.sh" post t1 crewchief "GATE: awaiting captain" >/dev/null
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] t1 - thing (repo: alpha)

## Queued
- [ ] t2 - other
- [ ] t3 - more

## Done
- [x] t0 - past
EOF
mkdir -p "$AC_HOME/projects/alpha/.crew/slots"
printf 'leased=1\n' >"$AC_HOME/projects/alpha/.crew/slots/1.meta"
printf 'leased=0\n' >"$AC_HOME/projects/alpha/.crew/slots/2.meta"

out="$("$BIN/ac-dash.sh")"
assert_contains "$out" "t1" "crew row"
assert_contains "$out" "PENDING-CAPTAIN(1)" "pending room"
assert_contains "$out" "in-flight:1  queued:2  done:1" "backlog counts"
# A byte that is not UTF-8 in row prose is prose: under a UTF-8 locale it
# aborted the count walk and the section read "backlog unavailable".
cp "$AC_HOME/records/backlog.md" "$TMP/dash-backlog.keep"
printf -- '- [ ] t4 - caf\351 menu\n' >>"$AC_HOME/records/backlog.md"
assert_contains "$(LC_ALL=en_US.UTF-8 "$BIN/ac-dash.sh")" "in-flight:1  queued:2" "a non-UTF-8 byte never costs the backlog counts"
cp "$TMP/dash-backlog.keep" "$AC_HOME/records/backlog.md"
assert_contains "$out" "leased:1 avail:1" "pool counts"

# Verifier-only fleet: CREW says empty, the verify row shows under its own
# heading (ac_meta_is_verify is the predicate, never a verify-* re-match).
rm -f "$AC_HOME"/state/t1.meta "$AC_HOME"/state/t1.status
printf 'kind=verify-codereview\nproject=alpha\nbackend=tmux\n' >"$AC_HOME/state/v1.meta"
printf '%s done: reviewed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/state/v1.status"
out="$("$BIN/ac-dash.sh")"
assert_contains "$out" "no crewmates in flight" "verifier-only: CREW section stays empty"
assert_contains "$out" "v1" "verifier-only: verify row shows"
assert_contains "$out" "verification agents, not crew" "verifier-only: wording marks it as verify"

# Mixed fleet: a crew meta and a verify meta both in flight - the verify id
# must never land in the CREW section.
printf 'kind=ship\nproject=alpha\nbackend=tmux\n' >"$AC_HOME/state/t1.meta"
printf '%s done: shipped\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$AC_HOME/state/t1.status"
out="$("$BIN/ac-dash.sh")"
crew_section="$(awk '/^CREW$/{c=1;next} /^$/{c=0} c' <<<"$out")"
assert_contains "$crew_section" "t1" "mixed: crew section lists t1"
case "$crew_section" in *v1*) fail "mixed: verify id v1 leaked into the crew section" ;; esac
assert_contains "$out" "v1" "mixed: verify row still shown"

# Crew-only fleet: no verify section at all.
rm -f "$AC_HOME/state/v1.meta" "$AC_HOME/state/v1.status"
out="$("$BIN/ac-dash.sh")"
case "$out" in *"verification agents, not crew"*) fail "crew-only: no verify section should print" ;; esac

assert_fails "$BIN/ac-dash.sh" --bogus

# --- same-done-miscount-in-three-more-surfaces: BACKLOG done means real done -
# two-dashboards lead (ac-dash-crew-heading-swallows-verifiers): the last bug of
# this shape had to be fixed in both dashboards, so this terminal one gets its
# own fixture rather than assuming the bun-side fix covers it.
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog

## In flight

## Queued

## Done
- [x] fx-done - real success (merged 2026-08-03)
- [x] fx-failed [failed] - did not land (2026-08-03)
- [x] fx-abandoned [abandoned] - dropped (2026-08-03)
EOF
out="$("$BIN/ac-dash.sh")"
assert_contains "$out" "in-flight:0  queued:0  done:1" \
  "a [failed]/[abandoned] Done row must not count toward the terminal backlog's done tally"

# A backlog the parser could not read costs its own line, never the render:
# --watch runs render under set -e and would die on the first bad frame.
failbun="$TMP/failbun"
mkdir -p "$failbun"
printf '#!/bin/sh\nexit 1\n' >"$failbun/bun"
chmod +x "$failbun/bun"
rc=0
out="$(PATH="$failbun:$PATH" "$BIN/ac-dash.sh" 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "an unreadable backlog leaves the render's exit status alone"
assert_contains "$out" "WARN   backlog unavailable: the parser exited 2" "an unreadable backlog is named in its section"
assert_contains "$out" "leased:1 avail:1" "the sections after an unreadable backlog still render"

pass
