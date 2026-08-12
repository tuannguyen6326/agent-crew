#!/usr/bin/env bash
# ac-deputy-registry.test.sh - the crewdeputy routing table: the ac-lib.sh
# parser (three validity classes, index-based field split, named reasons,
# legacy read-compatibility) and the ac-deputy.sh renderer (the three digest
# states, the four liveness states, the tally, and the strict `validate` twin).
#
# HERMETICITY: `list` probes backend liveness, so every case that can reach a
# probe runs against the fake herdr of tests/helpers.sh. The LIVE assertion is
# the tripwire - without the stub on PATH `pane get` fails and the entry
# renders DOWN - and the log assertion proves the probe hit the stub.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home

reg="$AC_HOME/records/crewdeputies.md"

lib() {
  # lib <script> - run a body with ac-lib.sh sourced, nothing else.
  bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; $1"
}

parse() { lib "ac_deputy_parse '$reg'"; }
field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" 'NR == 1 { print $n }'; }

# --- the shipped legacy line still reads ------------------------------------
# The one line on disk today, byte-unchanged: it must parse, and it must be
# visibly non-routable rather than silently absent.

printf '# Crewdeputies\n\n- demo - home: /abs/homes/fleet/crewdeputies/demo - no projects (added 2026-07-16T09:46:38Z)\n' >"$reg"
rec="$(parse)"
assert_eq "$(field "$rec" 1)" "LEGACY" "today's shipped line parses as LEGACY"
assert_eq "$(field "$rec" 2)" "demo" "legacy id"
assert_eq "$(field "$rec" 3)" "/abs/homes/fleet/crewdeputies/demo" "legacy home"
assert_eq "$(field "$rec" 4)" "(none)" "legacy charter renders as (none)"
assert_eq "$(field "$rec" 5)" "" "legacy scope is EMPTY - the field that makes it non-routable"
assert_eq "$(field "$rec" 6)" "none" "legacy 'no projects' normalizes to none"

# Legacy with clones: the space-separated tail normalizes to the comma grammar.
printf -- '- demo - home: /h/crewdeputies/demo - alpha beta (added 2026-07-16T09:46:38Z)\n' >"$reg"
assert_eq "$(field "$(parse)" 6)" "alpha,beta" "legacy space-separated clones normalize to a comma list"

# --- the v2 six-field line ---------------------------------------------------
# Spaces inside charter, scope and home must survive: routing decisions are
# made on the scope text, so a field-split bug that truncates it misroutes.

printf -- '- pay - payments triage and hotfix duty - home: /h/my homes/crewdeputies/pay - scope: production incidents on payments - alert noise, hotfix branches - projects: alpha,beta (added 2026-07-19T00:00:00Z)\n' >"$reg"
rec="$(parse)"
assert_eq "$(field "$rec" 1)" "VALID" "six-field line is VALID"
assert_eq "$(field "$rec" 2)" "pay" "v2 id"
assert_eq "$(field "$rec" 3)" "/h/my homes/crewdeputies/pay" "home keeps its spaces"
assert_eq "$(field "$rec" 4)" "payments triage and hotfix duty" "charter keeps its spaces"
assert_eq "$(field "$rec" 5)" "production incidents on payments - alert noise, hotfix branches" \
  "scope keeps its spaces AND an embedded ' - '"
assert_eq "$(field "$rec" 6)" "alpha,beta" "projects list"

# A seeded line's empty scope is VALID-shaped but carries no scope text.
printf -- '- pay - (charter unset) - home: /h/crewdeputies/pay - scope: - projects: none (added 2026-07-19T00:00:00Z)\n' >"$reg"
rec="$(parse)"
assert_eq "$(field "$rec" 1)" "VALID" "an empty scope is a VALID line, not a parse error"
assert_eq "$(field "$rec" 5)" "" "empty scope parses as empty - non-routable"

# --- INVALID lines carry a naming reason and their verbatim source -----------

inv_reason() {
  # inv_reason <line> - class+reason for one registry line.
  printf '# Crewdeputies\n\n%s\n' "$1" >"$reg"
  rec="$(parse)"
  printf '%s|%s|%s\n' "$(field "$rec" 1)" "$(field "$rec" 2)" "$(field "$rec" 7)"
}

assert_eq "$(inv_reason '- ops2 - home /abs - no projects (added 2026-07-19T00:00:00Z)')" \
  'INVALID|- ops2 - home /abs - no projects (added 2026-07-19T00:00:00Z)|missing "home:" field' \
  "a missing home: field is INVALID, reported with its verbatim source"
assert_eq "$(inv_reason '- ops2 - home: rel/path - no projects (added 2026-07-19T00:00:00Z)')" \
  'INVALID|- ops2 - home: rel/path - no projects (added 2026-07-19T00:00:00Z)|home path is not absolute' \
  "a relative home is INVALID"
assert_eq "$(inv_reason '- ops.2 - home: /h/crewdeputies/ops.2 - no projects (added 2026-07-19T00:00:00Z)')" \
  'INVALID|- ops.2 - home: /h/crewdeputies/ops.2 - no projects (added 2026-07-19T00:00:00Z)|bad id charset' \
  "an out-of-charset id is INVALID"
assert_eq "$(inv_reason '- ops - home: /h/crewdeputies/other - no projects (added 2026-07-19T00:00:00Z)')" \
  'INVALID|- ops - home: /h/crewdeputies/other - no projects (added 2026-07-19T00:00:00Z)|id does not match home basename' \
  "registry/disk drift (id != basename(home)) is INVALID"
assert_eq "$(inv_reason '- ops - home: /h/crewdeputies/ops - no projects')" \
  'INVALID|- ops - home: /h/crewdeputies/ops - no projects|missing "(added ...)"' \
  "a missing added stamp is INVALID"

# Duplicate id: the FIRST wins, the second is INVALID - two entries claiming
# one id would route work to whichever the reader happened to pick.
printf '# Crewdeputies\n\n- ops - home: /h/crewdeputies/ops - no projects (added 2026-07-19T00:00:00Z)\n- ops - c - home: /h/crewdeputies/ops - scope: s - projects: none (added 2026-07-19T00:00:00Z)\n' >"$reg"
rec="$(parse)"
assert_eq "$(printf '%s\n' "$rec" | wc -l | tr -d ' ')" "2" "both lines emit a record"
assert_eq "$(printf '%s\n' "$rec" | awk -F'\t' 'NR == 2 { print $1 "|" $7 }')" 'INVALID|duplicate id' \
  "the second claim on an id is INVALID"

# --- non-entry lines are ignored, never reported ----------------------------

printf '# Crewdeputies\n\nsome prose\n\n- ops - home: /h/crewdeputies/ops - no projects (added 2026-07-19T00:00:00Z)\n' >"$reg"
assert_eq "$(parse | wc -l | tr -d ' ')" "1" "heading, blanks and prose emit nothing"

# The parser is PURE: it must be safe from a read-only session.
rm -f "$reg"
assert_eq "$(parse)" "" "an absent registry parses to nothing"
assert_no_file "$reg" "parsing never creates the registry"

# --- list: ABSENT vs EMPTY vs entries ----------------------------------------
# The captain's order names this distinction: a shared "no deputies" line would
# erase the difference between "never registered" and "the ledger is empty".

out="$("$BIN/ac-deputy.sh" list)"
assert_contains "$out" "ABSENT: records/crewdeputies.md" "an absent registry says ABSENT"

printf '# Crewdeputies\n\n' >"$reg"
out="$("$BIN/ac-deputy.sh" list)"
assert_contains "$out" "EMPTY: records/crewdeputies.md present, 0 entries" "an entry-less registry says EMPTY"
case "$out" in *ABSENT*) fail "an EMPTY registry must not also report ABSENT" ;; esac

# --- list: the four liveness states -------------------------------------------
# Registry membership, not pane existence, is what puts a deputy in the table:
# seeded-but-never-spawned is the acceptance's headline failure when invisible.

mk_deputy_home() {
  # mk_deputy_home <id> - a seeded deputy home with its marker.
  mkdir -p "$AC_HOME/crewdeputies/$1/state"
  : >"$AC_HOME/crewdeputies/$1/.ac-crewdeputy-home"
  printf '%s\n' "$AC_HOME/crewdeputies/$1"
}

hlive="$(mk_deputy_home dlive)"
hdown="$(mk_deputy_home ddown)"
hidle="$(mk_deputy_home didle)"

# dlive: meta + a pane the fake herdr answers for.
printf 'backend=herdr\nkind=crewdeputy\n' >"$AC_HOME/state/dlive.meta"
printf 'pD1 tD1\n' >"$AC_HOME/state/.pane-dlive"
printf 'pD1\n' >"$FAKE_HERDR/tabs/tD1"
: >"$FAKE_HERDR/panes/pD1.buf"
# ddown: meta + a pane handle the backend cannot resolve - the pane died.
printf 'backend=herdr\nkind=crewdeputy\n' >"$AC_HOME/state/ddown.meta"
printf 'pGONE tGONE\n' >"$AC_HOME/state/.pane-ddown"
# didle: seeded, never spawned - no meta at all.
# dgone: registered, but its home is not on disk.

{
  printf '# Crewdeputies\n\n'
  printf -- '- dlive - payments duty - home: %s - scope: payments incidents - projects: alpha (added 2026-07-19T00:00:00Z)\n' "$hlive"
  printf -- '- ddown - ops duty - home: %s - scope: alert noise - projects: none (added 2026-07-19T00:00:00Z)\n' "$hdown"
  printf -- '- didle - home: %s - no projects (added 2026-07-19T00:00:00Z)\n' "$hidle"
  printf -- '- dgone - gone duty - home: %s/crewdeputies/dgone - scope: nothing - projects: none (added 2026-07-19T00:00:00Z)\n' "$AC_HOME"
  printf -- '- ops2 - home /abs - no projects (added 2026-07-19T00:00:00Z)\n'
} >"$reg"

out="$("$BIN/ac-deputy.sh" list)"
assert_contains "$out" "$(printf 'LIVE\tdlive\thome: %s\tprojects: alpha' "$hlive")" \
  "a live deputy renders LIVE with its home and clone list"
# The hermeticity tripwire: without the stub on PATH `pane get` fails and the
# entry above renders DOWN. The log proves the probe hit the fake, not a server.
assert_contains "$(cat "$FAKE_HERDR/log")" "pane get pD1" "the liveness probe went to the fake herdr"
assert_contains "$out" "$(printf '\tcharter: payments duty')" "charter on its own tab-indented line"
assert_contains "$out" "$(printf '\tscope: payments incidents')" "scope on its own tab-indented line"
case "$out" in *"recover: bin/ac-spawn.sh dlive"*) fail "a LIVE deputy must carry no recover hint" ;; esac

assert_contains "$out" "$(printf 'DOWN\tddown')" "a dead pane renders DOWN"
assert_contains "$out" "recover: bin/ac-spawn.sh ddown --crewdeputy --recover" "DOWN carries the exact recover command"
# The empty scope on this legacy entry is where a TSV reader that collapses
# tab runs shifts every later field: assert the projects column, not just the id.
assert_contains "$out" "$(printf 'NOT-RUNNING\tdidle\thome: %s\tprojects: none' "$hidle")" \
  "seeded-but-never-spawned renders NOT-RUNNING with its fields unshifted"
assert_contains "$out" "recover: bin/ac-spawn.sh didle --crewdeputy --recover" "NOT-RUNNING carries the exact recover command"
assert_contains "$out" "$(printf '\tcharter: (none)')" "a legacy line names its missing charter"
assert_contains "$out" "scope: (unset" "a scopeless entry is surfaced as not routable"
assert_contains "$out" "$(printf 'HOME-MISSING\tdgone')" "registry/disk disagreement renders HOME-MISSING"
case "$out" in *"recover: bin/ac-spawn.sh dgone"*) \
  fail "HOME-MISSING is a captain decision, not a recovery - no hint" ;; esac
assert_contains "$out" 'INVALID	- ops2 - home /abs - no projects (added 2026-07-19T00:00:00Z)	reason: missing "home:" field' \
  "an INVALID line prints its verbatim source plus one reason"
assert_contains "$out" "registered: 5 (live 1, down 1, not-running 1, home-missing 1, invalid 1)" \
  "the tally counts every entry line"

# --- fail-open where it must, fail-closed where it must -----------------------
# A bad ledger line may never take session start down; a deliberate check may.

"$BIN/ac-deputy.sh" list >/dev/null || fail "list must exit 0 even with a corrupt line"
assert_fails "$BIN/ac-deputy.sh" validate

printf '# Crewdeputies\n\n- didle - home: %s - no projects (added 2026-07-19T00:00:00Z)\n' "$hidle" >"$reg"
"$BIN/ac-deputy.sh" validate >/dev/null || fail "validate passes when every line parses"

pass
