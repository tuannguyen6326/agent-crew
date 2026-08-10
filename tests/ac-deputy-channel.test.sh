#!/usr/bin/env bash
# ac-deputy-channel.test.sh - the two cross-home verbs of the routing layer:
# `report` (deputy -> parent return: status line + ONE durable wake the parent's
# ordinary drain emits) and `handoff` (parent -> deputy queued-item move, all or
# nothing, backed up first).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

parent="$AC_HOME"

mk_deputy_home() {
  # mk_deputy_home <id> - a seeded deputy home under the parent, registered.
  local h="$parent/crewdeputies/$1"
  mkdir -p "$h/state" "$h/data" "$h/records"
  : >"$h/.ac-crewdeputy-home"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' >"$h/records/backlog.md"
  printf '# Crewdeputies\n\n- %s - duty - home: %s - scope: payments - projects: alpha (added 2026-07-19T00:00:00Z)\n' \
    "$1" "$h" >"$parent/records/crewdeputies.md"
  printf '%s\n' "$h"
}

dep="$(mk_deputy_home pay)"

# --- report: the durable return ------------------------------------------------
# The chief must never have to read deputy chat for an answer: the status line
# and the wake both live on disk, so the outcome survives a restart of BOTH
# sessions.

out="$(AC_HOME="$dep" "$BIN/ac-deputy.sh" report 'done: interest rounding fixed')"
assert_contains "$out" "pay" "report names the deputy it answered for"
assert_contains "$(cat "$parent/state/pay.status")" "report: done: interest rounding fixed" \
  "the answer lands on the PARENT's status log, not the deputy's"
assert_no_file "$dep/state/pay.status" "the deputy home records nothing for the parent"

drained="$("$BIN/ac-wake-drain.sh")"
assert_contains "$drained" "deputy pay done: interest rounding fixed" \
  "the parent's ORDINARY drain emits the return - no new consumer code"
assert_eq "$(printf '%s\n' "$drained" | grep -c '^deputy pay ' | tr -d ' ')" "1" \
  "exactly ONE wake record per report"

# --doc: a longer answer travels as a pointer into the deputy's own home.
mkdir -p "$dep/data/audit"
: >"$dep/data/audit/report.md"
AC_HOME="$dep" "$BIN/ac-deputy.sh" report 'done: audit finished' --doc "$dep/data/audit/report.md" >/dev/null
assert_contains "$(cat "$parent/state/pay.status")" "doc: $dep/data/audit/report.md" \
  "the status line carries the document path"
assert_contains "$("$BIN/ac-wake-drain.sh")" "doc: $dep/data/audit/report.md" \
  "the drained wake points at the document too"

# A tab or newline in the text must not tear the TSV record: the payload would
# be silently swallowed and the chief would drain a truncated answer.
AC_HOME="$dep" "$BIN/ac-deputy.sh" report "$(printf 'blocked: needs\ta decision\non rounding')" >/dev/null
drained="$("$BIN/ac-wake-drain.sh")"
assert_eq "$(printf '%s\n' "$drained" | grep -c '^deputy pay ' | tr -d ' ')" "1" \
  "a tab/newline payload still yields exactly ONE well-formed record"
assert_contains "$drained" "deputy pay blocked: needs a decision on rounding" \
  "tabs and newlines collapse to single spaces, nothing is lost"

# A parent that does not know this deputy still receives the answer: the send
# side is fail-closed because a misaddressed ORDER is worse than none, but a
# stranded ANSWER is pure loss.
printf '# Crewdeputies\n\n' >"$parent/records/crewdeputies.md"
err="$(AC_HOME="$dep" "$BIN/ac-deputy.sh" report 'done: still delivered' 2>&1 >/dev/null)"
assert_contains "$err" "no registry entry" "an unregistered deputy is warned about"
assert_contains "$("$BIN/ac-wake-drain.sh")" "deputy pay done: still delivered" \
  "the answer is delivered anyway"
dep="$(mk_deputy_home pay)"

# --- report: the refusals ------------------------------------------------------

assert_fails "$BIN/ac-deputy.sh" report 'from the parent home'
assert_fails env AC_HOME="$dep" "$BIN/ac-deputy.sh" report ''

# A deputy home with no parent fleet under it: a cross-home write with nowhere
# to land must refuse, never guess a state/ directory into existence.
orphan="$TMP/orphan/crewdeputies/px"
mkdir -p "$orphan/state"
: >"$orphan/.ac-crewdeputy-home"
assert_fails env AC_HOME="$orphan" "$BIN/ac-deputy.sh" report 'nowhere to land'
assert_no_file "$TMP/orphan/state" "a refused report creates nothing in the would-be parent"

# --- handoff: already-queued work follows the domain ---------------------------
# A deputy created for a domain must own its domain's QUEUE from day one; an
# invisible parent backlog is what this closes. Scope judgment stays with the
# chief - the tool moves exactly what it is told, or nothing at all.

qmove='- [ ] qmove [mode:direct-pr] - move me (repo: alpha)'
qlocal='- [ ] qlocal [mode:local-only] - land it locally (repo: locrepo)'
qnopin='- [ ] qnopin - no contract pin (repo: alpha)'
qepic='- [ ] qepic - a story (repo: alpha); epic:bigone'
own='- [ ] own1 - the deputy own queued work (repo: alpha)'
reset_backlog() {
  cat >"$parent/records/backlog.md" <<EOF
# Backlog

## In flight
- [ ] flying - already in flight (repo: alpha, since 2026-07-19)

## Queued
$qmove
- [ ] qkeep [mode:direct-pr] - keep me (repo: alpha)
- [ ] q1 - the blocker (repo: alpha)
- [ ] q2 - the dependent (repo: alpha) blocked-by: q1 - waits on q1
- [ ] qnorepo - a malformed line with no repo token
$qnopin
$qlocal
$qepic

## Done
- [x] donetask - landed (repo: alpha) - local main (merged 2026-07-19)
EOF
}
printf '# Projects\n\n- alpha [crew-ship] - a project (added 2026-07-19)\n- locrepo [local-only] - a local project (added 2026-07-19)\n' \
  >"$parent/records/projects.md"
reset_backlog
# The deputy already owns queued work: a handoff must land BEHIND it.
printf '# Backlog\n\n## In flight\n\n## Queued\n%s\n\n## Done\n' "$own" >"$dep/records/backlog.md"

out="$("$BIN/ac-deputy.sh" handoff pay qmove)"
assert_contains "$out" "$qmove" "the handoff prints every moved line"
assert_eq "$(grep -F -- "$qmove" "$dep/records/backlog.md")" "$qmove" \
  "the line lands in the deputy ledger BYTE-IDENTICALLY - a line mutated in transit is a second accounting"
assert_eq "$(awk '/^## Queued/ { q = 1; next } /^## / { q = 0 } q && /^- /' "$dep/records/backlog.md")" \
  "$(printf '%s\n%s' "$own" "$qmove")" \
  "it APPENDS at the end of ## Queued - inserting at the head would silently reprioritize the parent's items above the deputy's own"
case "$(cat "$parent/records/backlog.md")" in *"qmove"*) fail "the parent must not keep a copy" ;; esac
assert_contains "$(cat "$parent/state/pay.status")" "handoff: qmove" "the parent records what it handed over"
[ -n "$(find "$parent/state/backups" -name 'deputy-handoff-*.tar.gz' 2>/dev/null)" ] \
  || fail "a records mutation needs its pre-run backup - the reversibility floor"

# --- handoff: the refusals, none of which may move anything --------------------

refuses() {
  # refuses <needle> <arg>... - the handoff fails, names <needle>, and the
  # parent ledger is byte-unchanged.
  local needle="$1" before err; shift
  before="$(cat "$parent/records/backlog.md")"
  err="$("$BIN/ac-deputy.sh" handoff "$@" 2>&1)" && fail "handoff $* must be refused"
  assert_contains "$err" "$needle" "the refusal names its ground"
  assert_eq "$(cat "$parent/records/backlog.md")" "$before" "a refused handoff moves NOTHING"
}

reset_backlog
refuses "In flight" pay flying
refuses "Done" pay donetask
refuses "epic" pay qepic
refuses "blocked-by" pay q1
# AS1: a local landing in a deputy clone never reaches the parent's clone.
refuses "local-only" pay qlocal
# ...and with the registry out of the mode business (mode is per-task), an
# UNPINNED row is unresolvable: the boundary is the last point AS1 can be
# enforced, so it refuses and asks for the pin instead of waving it through.
refuses "pins no mode" pay qnopin
# AS1 is the single mechanical enforcement of the assumption most likely to be
# vetoed, so an input it cannot resolve must REFUSE, not wave the item through.
refuses "(repo: <name>) token" pay qnorepo
refuses "no line" pay nosuchitem
refuses "no line" pay qkeep nosuchitem
# All-or-nothing across a mixed set: the good id must not move either.
refuses "local-only" pay qkeep qlocal

# Unknown deputy, and a run from inside a deputy home, are refused too.
refuses "no crewdeputy" nosuchdeputy qkeep
assert_fails env AC_HOME="$dep" "$BIN/ac-deputy.sh" handoff pay qkeep

pass
