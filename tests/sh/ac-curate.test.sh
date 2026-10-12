#!/usr/bin/env bash
# ac-curate.test.sh - automatic Curate policy and semantic maintenance:
# generation-aware cadence, recoverable deterministic captain/backlog moves,
# hash-gated named supersession/project/skill subjects, complete stale
# predicates, canonical pointer-integrity, unresolved-captain behavior, and
# idempotent resume. Every dangerous path runs against an isolated temp AC_HOME.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
. "$BIN/ac-maintenance-lib.sh"

# twin <expr> [<arg>...] - <expr> over src/lib.ts (L) and
# src/maintenance-receipt.ts (M), its arguments A, in one bun process: the code
# the fleet runs where a bash helper retired once src/learn.ts took its last
# caller (the bash one is frozen at tests/fixtures/ac-maintenance-retired.sh,
# and tests/ts holds each twin to it). A string answer is printed; the status
# is a number answer, else 1 for false or null and 0 for anything else.
twin() {
  local expr="$1"; shift
  (cd "$ROOT" && bun --no-env-file -e "const L = await import('./src/lib.ts'); const M = await import('./src/maintenance-receipt.ts'); const A = process.argv.slice(1); const v = await (async () => ($expr))(); if (typeof v === 'string') process.stdout.write(v); process.exit(typeof v === 'number' ? v : v === false || v === null ? 1 : 0);" "$@")
}

make_home
records="$AC_HOME/records"

# --- absent-ledger no-op cases (pristine home) -------------------------------
# Every verb on an absent ledger is graceful and creates no archive.

"$BIN/ac-curate.sh" learnings >/dev/null
"$BIN/ac-curate.sh" captain --apply >/dev/null
assert_no_file "$records/captain-archive.md" "captain --apply on an absent ledger creates no archive"
"$BIN/ac-curate.sh" backlog --apply >/dev/null
assert_no_file "$records/backlog-archive.md" "backlog --apply on an absent ledger creates no archive"
"$BIN/ac-curate.sh" projects >/dev/null

# --- the interval gate: tick advances once, due pure & numeric-safe, reset ----

read -r n x < <(ac_curate_due)
assert_eq "$n" "0" "fresh runs_since is 0"
assert_eq "$x" "5" "default curate-every is 5"

twin 'L.curateTick()'
read -r n x < <(ac_curate_due)
assert_eq "$n" "1" "one tick advances runs_since to 1"
twin 'L.curateTick()'
read -r n x < <(ac_curate_due)
assert_eq "$n" "2" "a second tick advances exactly once (never double-counts)"

# DOT-PREFIXED so it stays out of the state/*.meta task-meta glob (namespace lesson).
assert_file "$AC_HOME/state/.curate.meta" "counter lives at state/.curate.meta"
assert_no_file "$AC_HOME/state/curate.meta" "counter is NOT the bare curate.meta (phantom crewmate)"

# due is PURE: a read never advances the counter.
read -r n x < <(ac_curate_due); read -r n2 _ < <(ac_curate_due)
assert_eq "$n" "$n2" "ac_curate_due is pure (reads do not advance the counter)"

# Numeric-safe: garbage runs_since -> 0, garbage/absent curate-every -> 5.
printf 'runs_since=abc\n' >"$AC_HOME/state/.curate.meta"
read -r n x < <(ac_curate_due)
assert_eq "$n" "0" "garbage runs_since reads as 0"
printf '3\n' >"$AC_HOME/config/curate-every"
read -r n x < <(ac_curate_due)
assert_eq "$x" "3" "config/curate-every is honored"
printf 'xx\n' >"$AC_HOME/config/curate-every"
read -r n x < <(ac_curate_due)
assert_eq "$x" "5" "garbage config/curate-every falls back to 5"
rm -f "$AC_HOME/config/curate-every"

# reset zeroes the counter and stamps last_run.
printf 'runs_since=9\n' >"$AC_HOME/state/.curate.meta"
twin 'L.curateReset()'
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "0" "reset zeroes runs_since"
[ -n "$(ac_meta_get "$AC_HOME/state/.curate.meta" last_run)" ] || fail "reset stamps last_run"

# --- the Q8 reversibility floor: shared backup + restore roundtrip -----------

printf '## 2026-07-18 - fam\n- a durable lesson.\n' >"$records/learnings.md"
printf 'captain policy line\n' >"$records/captain.md"
mkdir -p "$AC_HOME/skills/existing"
printf 'an existing skill\n' >"$AC_HOME/skills/existing/SKILL.md"

arc="$(twin 'L.recordsBackup("curate")')"
assert_file "$arc" "curate backup archive created"
case "$arc" in
  "$AC_HOME/state/backups/"curate-*.tar.gz) ;;
  *) fail "curate backup lands under state/backups/ with a curate- prefix (got $arc)" ;;
esac
assert_no_file "$AC_HOME/state/backups.tar.gz" "backup is in a subdir, not loose in state/"
grep -q 'records/learnings.md' < <(tar -tzf "$arc") || fail "records/ is in the backup"
grep -q 'skills/existing/SKILL.md' < <(tar -tzf "$arc") || fail "the skills store is in the backup"
rm -f "$records/learnings.md" "$AC_HOME/skills/existing/SKILL.md"
tar -xzf "$arc" -C "$AC_HOME"
assert_file "$records/learnings.md" "restore recreates records/"
assert_file "$AC_HOME/skills/existing/SKILL.md" "restore recreates the skills store"

# The existing caller keeps its `learn-` prefix (the factor did not break it).
larc="$(twin 'L.recordsBackup("learn")')"
case "$larc" in
  "$AC_HOME/state/backups/"learn-*.tar.gz) ;;
  *) fail "the learn backup keeps the learn- prefix (got $larc)" ;;
esac

# --- learnings: pointer-integrity check (PROPOSE ONLY) -----------------------

mkdir -p "$AC_HOME/skills/goodskill"
printf 'a live skill\n' >"$AC_HOME/skills/goodskill/SKILL.md"
{
  printf '## 2026-07-18 - fam\n'
  printf -- '- 2026-07-18 [distilled -> goodskill @fleet] good hook (see skills/goodskill/SKILL.md)\n'
  printf -- '- 2026-07-18 [distilled -> goneskill @fleet] gone hook (see skills/goneskill/SKILL.md)\n'
  printf -- '- 2026-07-18 [distilled -> contgone @container] cont hook (see ../.claude/skills/contgone/SKILL.md)\n'
} >"$records/learnings.md"
learn_before="$(cat "$records/learnings.md")"

out="$("$BIN/ac-curate.sh" learnings)"
assert_contains "$out" "goneskill" "legacy @fleet pointer flagged for migration"
assert_contains "$out" "contgone" "legacy @container pointer flagged for migration"
compat="$(printf '%s\n' "$out" | grep -c 'COMPATIBILITY DEFECT')"
assert_eq "$compat" "3" "every remaining rung-qualified pointer is a compatibility defect"
# PROPOSE-ONLY: the file is never mutated, even with --apply.
"$BIN/ac-curate.sh" learnings --apply >/dev/null
assert_eq "$(cat "$records/learnings.md")" "$learn_before" "learnings.md unchanged (propose-only, never compacts)"

# --- canonical pointers resolve by their OWN link, not by the slug name -------
# learn_ledger_stage (ac-learn.sh) writes a crewmate-landed lesson's pointer as
# [lesson](../CREWMATE-learned.md) and a skill's as [skill](../skills/<n>/SKILL.md).
# The checker must honour that link: a retired skill package whose lesson lives
# in the always-loaded layer is RESOLVED, while a link naming a file that is
# really gone still BREAKS - a checker that goes green on everything is worse
# than one that reads the wrong path.

mkdir -p "$AC_HOME/skills/liveskill"
printf 'a live skill\n' >"$AC_HOME/skills/liveskill/SKILL.md"
printf '# Fleet-learned crewmate lessons\n\n## lessononly\n\nthe lesson.\n' \
  >"$AC_HOME/CREWMATE-learned.md"
{
  printf '## Distilled\n\n'
  printf -- '- [distilled -> lessononly] sources=2 updated=2026-08-05 ([lesson](../CREWMATE-learned.md))\n'
  printf -- '- [distilled -> liveskill] sources=2 updated=2026-08-05 ([skill](../skills/liveskill/SKILL.md))\n'
} >"$records/learnings.md"
out="$("$BIN/ac-curate.sh" learnings)"
assert_contains "$out" "ok: all distilled pointers resolve" \
  "a crewmate-owned pointer resolves with no skill package on disk"

# It still bites, in BOTH directions: a link to a file that is genuinely gone.
printf -- '- [distilled -> deadskill] sources=1 updated=2026-08-05 ([skill](../skills/deadskill/SKILL.md))\n' \
  >>"$records/learnings.md"
printf -- '- [distilled -> deadlesson] sources=1 updated=2026-08-05 ([lesson](../gone/CREWMATE-learned.md))\n' \
  >>"$records/learnings.md"
out="$("$BIN/ac-curate.sh" learnings)"
assert_contains "$out" "BROKEN: [distilled -> deadskill]" "a dangling skill link still breaks"
assert_contains "$out" "BROKEN: [distilled -> deadlesson]" "a dangling lesson link still breaks"
assert_contains "$out" "2 broken canonical pointer(s)" "only the two dangling links break"

# A canonical row carrying no link at all is a defect, not a pass (fail-closed).
printf -- '- [distilled -> linkless] sources=1 updated=2026-08-05\n' >>"$records/learnings.md"
out="$("$BIN/ac-curate.sh" learnings)"
assert_contains "$out" "BROKEN: [distilled -> linkless]" "a canonical row with no link is broken"

rm -f "$AC_HOME/CREWMATE-learned.md"
rm -rf "$AC_HOME/skills/liveskill"

# --- captain: verbatim-preservation, move-only, conservative detection --------

cat >"$records/captain.md" <<'CAP'
# Captain notes

- 2026-01-01: STANDING (captain): always do X, verbatim.
- 2026-01-02: temp migration order, do Y once. [COMPLETED 2026-01-03]
- 2026-01-04: STANDING (captain): SUPERSEDES the Z clause; do Z2 now.
- 2026-01-05: old Z rule, do Z. [SUPERSEDED 2026-01-04 by the Z2 rule above]
- 2026-01-06: launch clause SUPERSEDED 2026-01-04; the rest holds.
CAP
cap_before="$(cat "$records/captain.md")"

# Propose-only: two blocks proposed, nothing written.
out="$("$BIN/ac-curate.sh" captain)"
assert_eq "$(cat "$records/captain.md")" "$cap_before" "captain propose does not mutate captain.md"
assert_no_file "$records/captain-archive.md" "captain propose creates no archive"
assert_contains "$out" "PROPOSE-ONLY" "captain default is propose-only"
assert_contains "$out" "2 block(s) would move" "the two retirable blocks are counted"

# Apply: the two retired blocks MOVE; the three survivors stay byte-identical.
"$BIN/ac-curate.sh" captain --apply >/dev/null
grep -qxF -- '- 2026-01-01: STANDING (captain): always do X, verbatim.' "$records/captain.md" \
  || fail "living standing rule kept byte-identical (conservative detector does not move it)"
grep -qxF -- '- 2026-01-04: STANDING (captain): SUPERSEDES the Z clause; do Z2 now.' "$records/captain.md" \
  || fail "the live SUPERSEDES ruling is kept byte-identical"
grep -qxF -- '- 2026-01-06: launch clause SUPERSEDED 2026-01-04; the rest holds.' "$records/captain.md" \
  || fail "the partial (the rest holds) supersession is kept - NOT auto-moved"
if grep -qF 'do Y once' "$records/captain.md"; then fail "the completed one-time order is gone from captain.md"; fi
if grep -qF 'old Z rule' "$records/captain.md"; then fail "the fully-superseded rule is gone from captain.md"; fi

assert_file "$records/captain-archive.md" "retired wording moves to captain-archive.md"
grep -qxF -- '- 2026-01-02: temp migration order, do Y once. [COMPLETED 2026-01-03]' "$records/captain-archive.md" \
  || fail "the expired order is archived VERBATIM"
grep -qxF -- '- 2026-01-05: old Z rule, do Z. [SUPERSEDED 2026-01-04 by the Z2 rule above]' "$records/captain-archive.md" \
  || fail "the superseded rule is archived VERBATIM"
assert_eq "$(grep -cFx 'Archived rulings: [captain-archive.md](captain-archive.md)' "$records/captain.md")" "1" \
  "captain.md carries one stable archive reference"
ls "$AC_HOME"/state/backups/curate-*.tar.gz >/dev/null 2>&1 || fail "captain --apply took a pre-run backup"

# No-op safety: a file whose only chains are a live SUPERSEDES + a partial
# (the rest holds) moves NOTHING - byte-identical after --apply.
cat >"$records/captain.md" <<'CAP2'
- 2026-02-01: STANDING (captain): SUPERSEDES the old clause; do new.
- 2026-02-02: launch clause SUPERSEDED above; the rest holds.
CAP2
noop_before="$(cat "$records/captain.md")"
"$BIN/ac-curate.sh" captain --apply >/dev/null
assert_eq "$(cat "$records/captain.md")" "$noop_before" "conservative no-op: partial/SUPERSEDES chains move nothing"

# --- backlog: keep-N=20 boundary (byte-identical move) -----------------------

rm -f "$records/backlog-archive.md"
{
  printf '## In flight\n\n## Queued\n\n## Done\n'
  for i in $(seq 22); do
    printf -- '- [x] d%02d - receipt - local main @sha%02d (merged 2026-02-%02d)\n' "$i" "$i" "$i"
  done
} >"$records/backlog.md"

"$BIN/ac-curate.sh" backlog --apply >/dev/null
grep -qF -- '- [x] d20 - ' "$records/backlog.md" || fail "the 20th-most-recent Done is kept (keep-N=20)"
if grep -qF -- '- [x] d21 - ' "$records/backlog.md"; then fail "the 21st Done is archived (past keep-N=20)"; fi
if grep -qF -- '- [x] d22 - ' "$records/backlog.md"; then fail "the 22nd Done is archived"; fi
grep -qxF -- '- [x] d21 - receipt - local main @sha21 (merged 2026-02-21)' "$records/backlog-archive.md" \
  || fail "d21 archived byte-identical"
grep -qxF -- '- [x] d22 - receipt - local main @sha22 (merged 2026-02-22)' "$records/backlog-archive.md" \
  || fail "d22 archived byte-identical"

# A move longer than one BSD sed script line (2048 bytes) moves whole.
rm -f "$records/backlog-archive.md"
{
  printf '## In flight\n\n## Queued\n\n## Done\n'
  for i in $(seq 600); do printf -- '- [x] l%03d - receipt - local main (merged 2026-01-01)\n' "$i"; done
} >"$records/backlog.md"
AC_CURATE_KEEP=0 "$BIN/ac-curate.sh" backlog --apply >/dev/null || fail "a 600-line move completes"
assert_eq "$(grep -c '^- \[x\] l' "$records/backlog-archive.md")" "600" "a 600-line move archives every line"

# --- backlog: blocked-by-safety (a live blocker Done is never archived) -------

rm -f "$records/backlog-archive.md"
cat >"$records/backlog.md" <<'BL'
## In flight

## Queued
- [ ] q1 - needs the blocker (repo: x) blocked-by: dblock - waiting

## Done
- [x] dnew - recent - local main (merged 2026-02-05)
- [x] dblock - the blocker Done - local main (merged 2026-02-04)
- [x] dfree - unreferenced old - local main (merged 2026-02-03)
BL
AC_CURATE_KEEP=1 "$BIN/ac-curate.sh" backlog --apply >/dev/null
grep -qF -- '- [x] dblock ' "$records/backlog.md" || fail "a Done referenced by a live blocked-by is NEVER archived"
grep -qF -- '- [x] dnew ' "$records/backlog.md" || fail "the most-recent Done is kept"
if grep -qF -- '- [x] dfree ' "$records/backlog.md"; then fail "an unreferenced old Done IS archived"; fi
grep -qF -- '- [x] dfree ' "$records/backlog-archive.md" || fail "dfree moved to the archive"
if grep -qF -- '- [x] dblock ' "$records/backlog-archive.md"; then fail "the blocker is NOT in the archive"; fi

# --- backlog: epic-safety (a Done story is kept while its epic line survives) --

rm -f "$records/backlog-archive.md"
cat >"$records/backlog.md" <<'BL2'
## In flight
- [ ] bigepic [EPIC] - the epic stories: s1 (repo: x, since 2026-02-01)

## Queued

## Done
- [x] dnew2 - recent - local main (merged 2026-02-05)
- [x] s1 - a done story; epic:bigepic - local main (merged 2026-02-02)
- [x] dfree2 - unreferenced - local main (merged 2026-02-01)
BL2
AC_CURATE_KEEP=1 "$BIN/ac-curate.sh" backlog --apply >/dev/null
grep -qF -- '- [x] s1 ' "$records/backlog.md" || fail "a Done story line is kept while its epic line survives"
if grep -qF -- '- [x] dfree2 ' "$records/backlog.md"; then fail "an unreferenced old Done IS archived (epic-safety is not over-broad)"; fi
grep -qF -- '- [x] dfree2 ' "$records/backlog-archive.md" || fail "dfree2 moved to the archive"

# empty backlog (headers only) is a byte-identical no-op.
rm -f "$records/backlog-archive.md"
printf '## In flight\n\n## Queued\n\n## Done\n' >"$records/backlog.md"
empty_before="$(cat "$records/backlog.md")"
"$BIN/ac-curate.sh" backlog --apply >/dev/null
assert_eq "$(cat "$records/backlog.md")" "$empty_before" "an empty Done section archives nothing (byte-identical)"
assert_no_file "$records/backlog-archive.md" "no archive created for an empty backlog"

# --- projects: correctness-audit (PROPOSE ONLY, even with --apply) -----------

mkdir -p "$AC_HOME/projects"
git init -q "$AC_HOME/projects/realp"
git init -q "$AC_HOME/projects/yolop"
cat >"$records/projects.md" <<'PROJ'
# Projects

- realp [local-only] - a real project (added 2026-02-01)
- deadp [direct-pr] - ASSUMED mode, since gone (added 2026-02-01)
- deadq [local-only] - another absent project (added 2026-02-02)
- yolop [+yolo] - a live project in the current grammar (added 2026-02-03)
- barep - an absent project with no bracket (added 2026-02-04)
- a prose bullet is not a registry line
PROJ
proj_before="$(cat "$records/projects.md")"
out="$("$BIN/ac-curate.sh" projects --apply)"
assert_eq "$(cat "$records/projects.md")" "$proj_before" "projects audit is propose-only (byte-identical even with --apply)"
assert_contains "$out" "deadp" "the dead project is surfaced"
# The registry carries no delivery mode (bin/ac-project-mode.sh header), so a
# line's prose saying one was assumed is nothing for the captain to confirm.
case "$out" in *"delivery mode is ASSUMED"*) fail "a registry line is never flagged for a mode the registry does not carry" ;; esac
assert_contains "$out" "absent" "the missing project dir is flagged as a proposed drop"
# The bracket is optional and only +yolo in it means anything (bin/ac-project-mode.sh header).
assert_contains "$out" "FLAG barep: registered but projects/barep is absent" \
  "a registry line with no bracket is audited"
case "$out" in *"FLAG yolop"*) fail "a live [+yolo] project is not flagged: +yolo is not a delivery mode" ;; esac
case "$out" in *"FLAG a:"*) fail "a prose bullet is never read as a registry line" ;; esac
# Read byte-wise whatever the caller's locale: under UTF-8
# the host awk stops at an invalid byte, and the audit must not pass on the rest.
printf '# Projects\n\n- cafep [local-only] - caf\351 gone (added 2026-02-05)\n- afterp - absent, after the byte (added 2026-02-06)\n' \
  >"$records/projects.md"
out="$(LC_ALL=en_US.UTF-8 "$BIN/ac-curate.sh" projects 2>&1)"
assert_contains "$out" "FLAG cafep: registered but projects/cafep is absent" \
  "a registry line holding an invalid UTF-8 byte is audited"
assert_contains "$out" "FLAG afterp: registered but projects/afterp is absent" \
  "every registry line after an invalid UTF-8 byte is audited"
printf '%s\n' "$proj_before" >"$records/projects.md"

# --- run: automatic by default; --dry-run is byte-identical ------------------

gate_stub="$TMP/curate-gate"
cat >"$gate_stub" <<'GATE'
#!/usr/bin/env bash
mode=""; run=""; subject=""; manifest=""; plan=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    maintenance) shift ;;
    --mode) mode="$2"; shift 2 ;;
    --run) run="$2"; shift 2 ;;
    --subject) subject="$2"; shift 2 ;;
    --manifest) manifest="$2"; shift 2 ;;
    --plan) plan="$2"; shift 2 ;;
    *) shift ;;
  esac
done
decision="${CURATE_GATE_DECISION:-continue}"
[ "$subject" != "${CURATE_GATE_ASK_SUBJECT:-}" ] || decision=ask-captain
mkdir -p "$run/gates/$subject"
input_sha="$(shasum -a 256 <"$manifest" | awk '{print $1}')"
plan_sha="$(shasum -a 256 <"$plan" | awk '{print $1}')"
cat >"$run/gates/$subject/decision.md" <<EOF
---
schema: "agentcrew.maintenance-gate/v1"
mode: "$mode"
subject: "$subject"
decision: "$decision"
authority: "second-chief"
engine: "stub"
model: "targeted-test"
input_manifest_sha256: "$input_sha"
action_plan_sha256: "$plan_sha"
reviewed_at: "2026-07-26T00:00:00Z"
---
# Maintenance Gate Decision
## Decision
$decision
## Grounds
The targeted fixture proves the exact recoverable action plan.
## Inputs Read
- INPUT MANIFEST QUOTE: $(awk '{ if (length($0) > length(best)) best = $0 } END { print best }' "$manifest")
- ACTION PLAN NEW SHA-256: $(jq -r '.actions[0].new_sha256' "$plan")
- STAGED PAYLOAD QUOTE: $(prun="$(dirname "$plan")"; [ "$(basename "$prun")" != plans ] || prun="$(dirname "$prun")"; awk '{ if (length($0) > length(best)) best = $0 } END { print best }' "$prun/$(jq -r '.actions[0].staged' "$plan")")
## Proposed Process
Apply or preserve only the hash-bound subject.
EOF
GATE
chmod +x "$gate_stub"

printf '%s\n' '- 2026-03-01: one-time cleanup. [COMPLETED 2026-03-02]' >"$records/captain.md"
printf 'runs_since=4\ngeneration=0\n' >"$AC_HOME/state/.curate.meta"
run_cap_before="$(cat "$records/captain.md")"
"$BIN/ac-curate.sh" run --dry-run >/dev/null
assert_eq "$(cat "$records/captain.md")" "$run_cap_before" "--dry-run leaves captain.md byte-identical"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "4" \
  "--dry-run does not reset cadence"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "records-wide CURATE pass (automatic deterministic apply)" \
  "run applies deterministic Curate policy by default"
assert_contains "$out" "transaction + policy receipt committed" \
  "automatic run reports its recoverable authorization boundary"
# The passes run against a shadow copy, but the transaction writes the live
# records - so that is the path the report owes its reader.
assert_contains "$out" "to $records/captain-archive.md" "the run report names the live archive"
case "$out" in */shadow/*) fail "the run report names the shadow copy, which nothing reads again: $out" ;; esac
assert_contains "$(cat "$AC_HOME"/data/curate-*/report.md)" "to $records/captain-archive.md" \
  "...and so does the report.md the run leaves"
ls "$AC_HOME"/state/backups/curate-*.tar.gz >/dev/null 2>&1 || fail "run left a curate backup on disk"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "0" "run resets the interval gate"
grep -qF 'one-time cleanup' "$records/captain-archive.md" \
  || fail "default run automatically archives an explicitly completed captain block"
assert_eq "$(grep -cFx 'Archived rulings: [captain-archive.md](captain-archive.md)' "$records/captain.md")" "1" \
  "automatic Curate keeps one idempotent captain archive reference"
grep -R -q '^status=complete$' "$AC_HOME/state/.maintenance-transactions" \
  || fail "automatic Curate records a completed maintenance transaction"
grep -qxF -- '- deadp [direct-pr] - ASSUMED mode, since gone (added 2026-02-01)' \
  "$records/projects-archive.md" \
  || fail "semantic project archival moves the registry line verbatim"
grep -qxF -- '- deadq [local-only] - another absent project (added 2026-02-02)' \
  "$records/projects-archive.md" \
  || fail "multiple project subjects use current exact-line identity, not stale line numbers"
if grep -qF -- '- deadp ' "$records/projects.md"; then
  fail "maintenance-gate continue removes the archived project registry line"
fi
grep -qxF -- '- barep - an absent project with no bracket (added 2026-02-04)' \
  "$records/projects-archive.md" \
  || fail "an absent project with no bracket is archived verbatim too"
if grep -qF -- '- barep ' "$records/projects.md"; then
  fail "the archived bracketless registry line leaves the registry"
fi
grep -qxF -- '- yolop [+yolo] - a live project in the current grammar (added 2026-02-03)' \
  "$records/projects.md" || fail "a live [+yolo] project stays registered"
grep -qxF -- '- a prose bullet is not a registry line' "$records/projects.md" \
  || fail "a prose bullet is never archived as a dead project"
assert_file "$AC_HOME/projects/realp/.git/HEAD" \
  "Curate registry archival cannot delete an existing project clone"

# The archive move matches its registry line byte-wise too, or a line holding
# an invalid UTF-8 byte asks the captain on every pass.
cafe_line="$(printf -- '- cafep [local-only] - caf\351 gone (added 2026-02-05)')"
printf '%s\n' "$cafe_line" >>"$records/projects.md"
printf 'runs_since=4\ngeneration=0\n' >"$AC_HOME/state/.curate.meta"
LC_ALL=en_US.UTF-8 AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run >/dev/null 2>&1
LC_ALL=C grep -qxF -- "$cafe_line" "$records/projects-archive.md" \
  || fail "an absent project whose line holds an invalid UTF-8 byte is archived verbatim"
if LC_ALL=C grep -qF -- '- cafep ' "$records/projects.md"; then
  fail "the archived invalid-byte registry line leaves the registry"
fi

# The backlog pass reports through the same shadow home: its moved lines land
# in the live archive, and the report names that file.
printf '## In flight\n\n## Queued\n\n## Done\n- [x] oldone - landed - local main (merged 2026-01-01)\n' >"$records/backlog.md"
printf 'runs_since=4\ngeneration=0\n' >"$AC_HOME/state/.curate.meta"
out="$(AC_CURATE_KEEP=0 AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "to $records/backlog-archive.md" "the backlog pass names the live archive"
case "$out" in */shadow/*) fail "the backlog pass names the shadow copy: $out" ;; esac
grep -qF -- '- [x] oldone ' "$records/backlog-archive.md" || fail "...where the moved Done line really landed"

# curateReset (src/lib.ts) returns the same false for a newer cadence
# generation and for a busy cadence lock, so the run's own warning has to
# stand for both. Held by a
# live pid, the lock costs the reset's real 10s timeout.
printf 'runs_since=4\ngeneration=2\n' >"$AC_HOME/state/.curate.meta"
mkdir "$AC_HOME/state/.curate-cadence.lock"
printf '%s\n' "$$" >"$AC_HOME/state/.curate-cadence.lock/pid"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run 2>&1)"
rm -rf "$AC_HOME/state/.curate-cadence.lock"
assert_contains "$out" "curate reset: cadence lock" "the busy lock carries the lib's own warning"
assert_contains "$(printf '%s\n' "$out" | grep '^WARN: Curate committed')" "cadence lock" \
  "the run's warning names a busy cadence lock as a cause, not only a newer generation"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "4" \
  "a busy cadence lock does not reset the Curate counter"

# --- ac-learn.sh run advances the curate counter EXACTLY once (jq-gated) ------

if command -v jq >/dev/null 2>&1; then
  cat >"$TMP/stub-pane.sh" <<'STUB'
#!/usr/bin/env bash
cwd=""
while [ $# -gt 0 ]; do case "$1" in --cwd) cwd="$2"; shift 2 ;; *) shift ;; esac; done
printf 'proposed nothing this run (smoke).\n' >"$cwd/report.md"
printf '# Retro\n\nno recurring pattern.\n' >"$cwd/retro.md"
printf '{"event":"done","status":"ok","session_id":"s1","transcript":"/dev/null","pane":"p1"}\n'
STUB
  chmod +x "$TMP/stub-pane.sh"
  printf 'runs_since=0\n' >"$AC_HOME/state/.curate.meta"
  AC_PANE_AGENT="$TMP/stub-pane.sh" "$BIN/ac-learn.sh" run >/dev/null
  assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "1" "one ac-learn.sh run ticks the curate counter exactly once"
else
  printf 'SKIP: jq not available - ac-learn.sh run curate-tick smoke skipped\n'
fi

# --- skills: a clean pair of learned stores for the two skill policies --------

sk="$AC_HOME/skills"
container="$(dirname "$AC_HOME")/.claude/skills"
rm -rf "$sk" "$container"
mkdir -p "$sk" "$container"
mkskill() {
  # mkskill <store> <name> <description> [<landed-epoch>]
  local dir="$1/$2"
  mkdir -p "$dir"
  {
    printf -- '---\nname: %s\ndescription: %s\norigin: learned\n' "$2" "$3"
    [ -n "${4:-}" ] && printf 'metadata:\n  landed: %s\n' "$4"
    printf -- '---\n# %s\nbody\n' "$2"
  } >"$dir/SKILL.md"
}
now="$(ac_now)"
old=$((now - 200 * 86400))

# --- skills-audit: absent stores are a graceful no-op ------------------------

out="$("$BIN/ac-curate.sh" skills-audit)"
assert_contains "$out" "no learned skills" "skills-audit on empty stores is a graceful no-op"

# --- skills-audit: territory overlap (descriptions-first, propose-only) -------

mkskill "$sk" ov-one   "verify crewmate briefing carefully"
mkskill "$sk" ov-two   "crewmate briefing verify twice"
mkskill "$sk" ov-solo  "rebase worktree landing dance"
out="$("$BIN/ac-curate.sh" skills-audit)"
assert_contains "$out" "OVERLAP: ov-one ~ ov-two" "two skills sharing >=2 territory words are flagged as overlapping"
case "$out" in *ov-solo*OVERLAP* | *OVERLAP*ov-solo*) fail "the disjoint skill is never flagged for overlap" ;; esac
# PROPOSE-ONLY: --apply mutates nothing (no archive, stores byte-identical).
before="$(cat "$sk"/ov-one/SKILL.md "$sk"/ov-two/SKILL.md)"
"$BIN/ac-curate.sh" skills-audit --apply >/dev/null
assert_eq "$(cat "$sk"/ov-one/SKILL.md "$sk"/ov-two/SKILL.md)" "$before" "skills-audit --apply mutates nothing (propose-only)"
rm -rf "$sk"/ov-one "$sk"/ov-two "$sk"/ov-solo

# --- skills-audit: complete stale predicate, quoted legacy landed ------------

mkskill "$sk" st-old      "solitary domain aaaa" "\"$old\""
mkskill "$sk" st-seeded   "solitary domain bbbb" "\"$old\""
mkskill "$sk" st-evidence "solitary domain cccc" "\"$old\""
mkskill "$sk" st-pending  "solitary domain dddd" "\"$old\""
mkskill "$sk" st-active   "solitary domain eeee" "\"$old\""
mkskill "$sk" st-fresh    "solitary domain ffff" "\"$now\""
for name in st-old st-seeded st-evidence st-pending st-active; do
  touch -t 202001010000 "$sk/$name/SKILL.md"
done
ac_meta_set "$sk/st-seeded/.usage.meta" last_seeded "$now"
mkdir -p "$records/learnings-archive" "$AC_HOME/data/learning-pending" \
  "$TMP/active-wt/.claude/skills"
printf '# recent evidence\n' >"$records/learnings-archive/st-evidence.md"
cat >"$AC_HOME/data/learning-pending/candidate-st-pending.md" <<'CAND'
kind: patch
name: st-pending
CAND
ln -s "$sk/st-active" "$TMP/active-wt/.claude/skills/st-active"
printf 'worktree=%s\nkind=ship\n' "$TMP/active-wt" >"$AC_HOME/state/active.meta"
out="$("$BIN/ac-curate.sh" skills-audit)"
assert_contains "$out" "STALE: st-old" \
  "a quoted old landed value with no recent activity is a stale candidate"
case "$out" in *"STALE: st-seeded"*) fail "recent last_seeded prevents stale classification" ;; esac
case "$out" in *"STALE: st-evidence"*) fail "recent archive evidence prevents stale classification" ;; esac
case "$out" in *"STALE: st-pending"*) fail "a pending Learning candidate prevents stale classification" ;; esac
case "$out" in *"STALE: st-active"*) fail "an active worktree dependency prevents stale classification" ;; esac
case "$out" in *"STALE: st-fresh"*) fail "a fresh quoted landed value is not stale" ;; esac
rm -rf "$sk"/st-old "$sk"/st-seeded "$sk"/st-evidence "$sk"/st-pending \
  "$sk"/st-active "$sk"/st-fresh "$AC_HOME/data/learning-pending" \
  "$TMP/active-wt"
rm -f "$AC_HOME/state/active.meta" "$records/learnings-archive/st-evidence.md"

# --- skills-consolidate: no cluster is a no-op -------------------------------

mkskill "$sk" solo "a lonely skill"
out="$("$BIN/ac-curate.sh" skills-consolidate)"
assert_contains "$out" "nothing to consolidate" "no prefix cluster with an umbrella is a no-op"
assert_no_file "$sk/skills-archive" "a no-op consolidate creates no archive"

# --- skills-consolidate: direct apply refuses; automatic gate moves atomically -

mkskill "$sk" ship        "the ship umbrella"
mkskill "$sk" ship-rebase "rebase step"
mkskill "$sk" ship-attest "attest step"
mkskill "$sk" bar-x       "no umbrella here"
mkskill "$sk" bar-y       "no umbrella either"
ac_meta_set "$sk/ship-rebase/.usage.meta" seeded_count 3   # sidecar must ride the move
sib_before="$(cat "$sk/ship-rebase/SKILL.md")"
mkdir -p "$records/learnings-archive"
printf '# evidence\n' >"$records/learnings-archive/ship-rebase.md"
printf '# evidence\n' >"$records/learnings-archive/ship-attest.md"
cat >"$records/learnings.md" <<'LEARN'
# Learning Ledger

## Pending

## Distilled

- [distilled -> ship-rebase] sources=3 updated=2026-07-20 ([skill](../skills/ship-rebase/SKILL.md); [evidence](learnings-archive/ship-rebase.md))
- [distilled -> ship-attest] sources=2 updated=2026-07-21 ([skill](../skills/ship-attest/SKILL.md); [evidence](learnings-archive/ship-attest.md))
LEARN

# Propose-only: lists the movers + the umbrella-less group, moves nothing.
out="$("$BIN/ac-curate.sh" skills-consolidate)"
assert_contains "$out" "CLUSTER ship: sibling ship-rebase" "the umbrella'd sibling is a move candidate"
assert_contains "$out" "CLUSTER ship: sibling ship-attest" "both siblings are move candidates"
assert_contains "$out" "NO umbrella skill named \"bar\"" "the umbrella-less prefix group is propose-only"
assert_file "$sk/ship-rebase/SKILL.md" "propose-only moves nothing"
assert_no_file "$sk/skills-archive" "propose-only creates no archive"

# Direct --apply is no longer an authorization surface and cannot leave a
# broken pointer.
if "$BIN/ac-curate.sh" skills-consolidate --apply >/dev/null 2>&1; then
  fail "direct skills-consolidate --apply must refuse semantic mutation"
fi
assert_file "$sk/ship-rebase/SKILL.md" "refused direct apply leaves the skill live"
grep -qF '[distilled -> ship-rebase]' "$records/learnings.md" \
  || fail "refused direct apply leaves its canonical pointer active"

# Automatic run gates each sibling and commits the skill bytes plus both pointer
# ledgers in one shared transaction.
printf 'Archived rulings: [captain-archive.md](captain-archive.md)\n' >"$records/captain.md"
printf 'runs_since=4\ngeneration=1\n' >"$AC_HOME/state/.curate.meta"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "auto-applied semantic subject: skill-ship-rebase" \
  "maintenance-gate continue applies the first sibling"
assert_contains "$out" "auto-applied semantic subject: skill-ship-attest" \
  "maintenance-gate continue applies the second sibling"
assert_no_file "$sk/ship-rebase" "ship-rebase moved out of the live store"
assert_no_file "$sk/ship-attest" "ship-attest moved out of the live store"
assert_file "$sk/ship/SKILL.md" "the umbrella ship stays live"
assert_file "$sk/bar-x/SKILL.md" "an umbrella-less sibling is never moved"
assert_file "$sk/bar-y/SKILL.md" "an umbrella-less sibling is never moved (both)"
assert_file "$sk/skills-archive/ship-rebase/SKILL.md" "ship-rebase landed in the archive"
assert_eq "$(cat "$sk/skills-archive/ship-rebase/SKILL.md")" "$sib_before" "the moved folder is byte-identical"
assert_eq "$(ac_meta_get "$sk/skills-archive/ship-rebase/.usage.meta" seeded_count)" "3" ".usage.meta rides inside the moved folder"
if grep -qF '[distilled -> ship-rebase]' "$records/learnings.md"; then
  fail "successful consolidation removes the active canonical pointer"
fi
grep -qF -- '- [distilled -> ship-rebase] sources=3 updated=2026-07-20 ([skill](../../skills/skills-archive/ship-rebase/SKILL.md); [evidence](ship-rebase.md))' \
  "$records/learnings-archive/index.md" \
  || fail "successful consolidation writes the archived canonical pointer"
assert_eq "$(grep -cF '[distilled -> ship-rebase]' "$records/learnings-archive/index.md")" \
  "1" "archive index contains exactly one pointer per consolidated skill"

# --- live named supersession: semantic gate moves only the named target -------

cat >"$records/captain.md" <<'CAPSEM'
- 2026-04-02: STANDING new policy SUPERSEDES the named rule below.
- 2026-04-01: old named policy.
- 2026-03-31: unrelated active policy.
CAPSEM
printf 'runs_since=4\ngeneration=2\n' >"$AC_HOME/state/.curate.meta"
AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run >/dev/null
grep -qxF -- '- 2026-04-02: STANDING new policy SUPERSEDES the named rule below.' \
  "$records/captain.md" || fail "the live SUPERSEDES ruling is never moved"
if grep -qF -- '- 2026-04-01: old named policy.' "$records/captain.md"; then
  fail "maintenance-gate continue moves the uniquely named target"
fi
grep -qF -- '- 2026-04-01: old named policy.' "$records/captain-archive.md" \
  || fail "named supersession archives the target verbatim"
AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run >/dev/null
grep -qxF -- '- 2026-03-31: unrelated active policy.' "$records/captain.md" \
  || fail "resume recognizes the settled live ruling and never retargets the next block"

# A partial chain has no safe plan: it raises the six-part captain escalation
# and keeps cadence due.
cat >"$records/captain.md" <<'CAPPART'
- 2026-05-02: STANDING launch policy SUPERSEDES the clause below.
- 2026-05-01: earlier policy; launch clause superseded, the rest holds.
CAPPART
printf 'runs_since=4\ngeneration=3\n' >"$AC_HOME/state/.curate.meta"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "curate pass open" "an unresolved partial supersession keeps the run open"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "4" \
  "ask-captain prevents cadence reset"
room="$AC_HOME/data/curate/room.md"
assert_file "$room" "Curate writes a durable captain escalation"
for field in 'why:' 'subject:' 'action-plan-sha256:' 'options:' 'tradeoffs:' \
  'recommendation:' 'candidate=' 'gate=' 'evidence='; do
  grep -qF "$field" "$room" || fail "Curate escalation is missing $field"
done

# A resumed run never repeats already committed semantic subjects. The two skill
# pointers and the project registry line stay singletons while the unresolved
# partial captain subject remains open.
skill_index_before="$(grep -cF '[distilled -> ship-' "$records/learnings-archive/index.md")"
project_archive_before="$(grep -cF -- '- deadp ' "$records/projects-archive.md")"
AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run >/dev/null
assert_eq "$(grep -cF '[distilled -> ship-' "$records/learnings-archive/index.md")" \
  "$skill_index_before" "resume does not repeat committed skill subjects"
assert_eq "$(grep -cF -- '- deadp ' "$records/projects-archive.md")" \
  "$project_archive_before" "resume does not repeat a committed project subject"

# A cluster without traceable pointer/evidence becomes an unresolved captain
# subject; it is never moved merely because a prefix umbrella exists.
printf 'Archived rulings: [captain-archive.md](captain-archive.md)\n' >"$records/captain.md"
mkskill "$sk" run-a "run cluster a"
mkskill "$sk" run   "run umbrella"
printf 'runs_since=4\ngeneration=4\n' >"$AC_HOME/state/.curate.meta"
AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run >/dev/null
assert_file "$sk/run-a/SKILL.md" \
  "automatic Curate refuses consolidation without canonical pointer and evidence"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "4" \
  "unsafe skill subject keeps Curate due"

# --- acknowledged subjects: a recorded ruling settles an unplannable subject --
# A subject with no safe plan asks the captain every cycle and pins the WHOLE
# cadence, so `CURATE DUE` never clears. The only exit that deletes no policy is
# recording that the captain already ruled on it. The captain subject below and
# the still-live run-a skill cluster are acknowledged in the SAME run, so the
# mechanism is proved generic rather than a captain-* special case.

cat >"$records/captain.md" <<'CAPACK'
- 2026-06-02: STANDING launch policy SUPERSEDES the clause below.
- 2026-06-01: earlier policy; launch clause superseded, the rest holds.
CAPACK
rm -f "$records/curate-acknowledged.md"
printf 'runs_since=4\ngeneration=6\n' >"$AC_HOME/state/.curate.meta"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "curate pass open" "an UNacknowledged subject still asks"
ack_cap="$(printf '%s\n' "$out" \
  | sed -n 's/^ *\(- captain-supersedes-1 material=[0-9a-f]\{64\}\) .*/\1/p')"
[ -n "$ack_cap" ] || fail "the ask publishes a paste-ready acknowledgement line for the captain subject"
ack_skill="$(printf '%s\n' "$out" \
  | sed -n 's/^ *\(- skill-run-a material=[0-9a-f]\{64\}\) .*/\1/p')"
[ -n "$ack_skill" ] || fail "the ask publishes one for a skill subject too (not a captain-* special case)"

# (a) ACKNOWLEDGED: both subjects settle, no record moves, the cadence resets.
{
  printf '# curate-acknowledged - subjects the captain has already ruled on\n\n'
  printf '%s ruling: records/captain.md:1 - keep both entries, the rest holds\n' "$ack_cap"
  printf '%s ruling: records/captain.md:1 - the cluster stays live by ruling\n' "$ack_skill"
} >"$records/curate-acknowledged.md"
cap_ack_before="$(cat "$records/captain.md")"
printf 'runs_since=4\ngeneration=7\n' >"$AC_HOME/state/.curate.meta"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "settled: captain-supersedes-1 (acknowledged" \
  "a recorded ruling settles the captain subject instead of asking again"
assert_contains "$out" "keep both entries, the rest holds" \
  "the settle line CITES the ruling that decided it (not a mute button)"
assert_contains "$out" "settled: skill-run-a (acknowledged" \
  "the same records line settles a skill subject"
assert_contains "$out" "curate pass complete" "acknowledged subjects close the run"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "0" \
  "an acknowledged subject lets the run reset cadence (CURATE DUE clears)"
assert_eq "$(cat "$records/captain.md")" "$cap_ack_before" \
  "acknowledging moves or deletes no policy line"
assert_file "$sk/run-a/SKILL.md" "acknowledging a skill subject moves no skill"

# The KEY is the material, not the index-derived subject id: a block added ABOVE
# shifts every later id, and the acknowledgement must follow its material.
{
  printf -- '- 2026-06-03: an unrelated live rule.\n'
  cat "$records/captain.md"
} >"$records/captain.md.new"
mv "$records/captain.md.new" "$records/captain.md"
printf 'runs_since=4\ngeneration=8\n' >"$AC_HOME/state/.curate.meta"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "settled: captain-supersedes-2 (acknowledged" \
  "an unrelated captain.md edit shifts the subject id but never wipes the acknowledgement"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "0" \
  "an id shift alone does not reopen the cadence"

# (b) the MATERIAL changed, so the recorded ruling no longer describes it and
# Curate MUST ask again - while every other acknowledgement stands.
cat >"$records/captain.md" <<'CAPACK2'
- 2026-06-03: an unrelated live rule.
- 2026-06-02: STANDING launch policy SUPERSEDES the clause below.
- 2026-06-01: earlier policy REWRITTEN by the captain; launch clause superseded, the rest holds.
CAPACK2
printf 'runs_since=4\ngeneration=9\n' >"$AC_HOME/state/.curate.meta"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "ask-captain: captain-supersedes-2" \
  "an acknowledged subject whose source material CHANGED asks again"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "4" \
  "a changed acknowledged subject keeps Curate due"
assert_contains "$out" "settled: skill-run-a (acknowledged" \
  "one subject's material change never wipes another's acknowledgement"
grep -qF -- "$ack_cap" "$records/curate-acknowledged.md" \
  || fail "the stale acknowledgement stays visible in records - Curate never rewrites it"

# A subject whose material this run cannot identify has NO key at all: hashing
# nothing would hand every such subject the one empty-string digest, and a
# single acknowledgement would silence a DIFFERENT subject.
cat >"$records/captain.md" <<'CAPDUP'
- 2026-06-05: STANDING duplicated ruling SUPERSEDES the clause below.
- 2026-06-05: STANDING duplicated ruling SUPERSEDES the clause below.
- 2026-06-04: earlier policy; the rest holds.
CAPDUP
printf -- '- captain-supersedes-1 material=%s ruling: never\n' \
  "$(printf '' | shasum -a 256 | awk '{print $1}')" >>"$records/curate-acknowledged.md"
printf 'runs_since=4\ngeneration=10\n' >"$AC_HOME/state/.curate.meta"
out="$(AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "ask-captain: captain-supersedes-1" \
  "a subject with no identifiable material is never acknowledged by an empty-material key"

# --- gate-diagnostic-is-swallowed-and-the-captain-link-is-dead: the diagnostic
# the gate actually produced must reach the captain-facing ask for Curate too,
# not only Learning. curate_gate_subject already wrote a receipt on this arm
# (curate_ask_receipt, unlike learn's matching arm) - re-verified as a
# regression guard, not a defect this diff introduces.

rm -rf "$AC_HOME/skills"
mkdir -p "$AC_HOME/skills"
printf '# Projects\n\n' >"$records/projects.md"
cat >"$records/captain.md" <<'CAPFAIL'
- 2026-08-02: STANDING launch policy SUPERSEDES the clause below.
- 2026-08-01: earlier policy, now fully retired.
CAPFAIL
rm -f "$records/captain-archive.md" "$records/curate-acknowledged.md"
printf 'runs_since=4\ngeneration=20\n' >"$AC_HOME/state/.curate.meta"

gate_fail_stub="$TMP/curate-gate-fail"
cat >"$gate_fail_stub" <<'GATEFAIL'
#!/usr/bin/env bash
printf 'maintenance-gate[stub] curate/captain-supersedes-1: engine did not produce a valid maintenance decision (turn did not end ok)\n' >&2
printf 'CURATE-DISTINCT-DIAGNOSTIC-9c1e\n' >&2
exit 3
GATEFAIL
chmod +x "$gate_fail_stub"

out="$(AC_GATE="$gate_fail_stub" "$BIN/ac-curate.sh" run)"
assert_contains "$out" "ask-captain: captain-supersedes-1" \
  "curate: a gate that ran and failed still escalates the exact subject"
room_curate="$(cat "$AC_HOME/data/curate/room.md")"
assert_contains "$room_curate" 'CURATE-DISTINCT-DIAGNOSTIC-9c1e' \
  "curate: the gate's own diagnostic reaches the captain-facing escalation message, not just the chat line"
gate_link_curate="$(printf '%s\n' "$room_curate" \
  | grep -o 'gate=data/curate-[^;]*decision\.md' | tail -1 | sed 's/^gate=//')"
[ -n "$gate_link_curate" ] || fail "curate: escalation message carries no gate= link"
assert_file "$AC_HOME/$gate_link_curate" \
  "curate: the receipt the gate= link points at was actually written - no dead link"

# --- F3: a captain write landing during the run's shadow passes must never be
# silently reverted by the automatic deterministic apply --------------------
# AC_CURATE_SNAPSHOT_HOOK fires right after the pristine snapshot is taken and
# before the (here-instant) shadow passes run, standing in for a captain write
# landing inside that real multi-second window - a deterministic seam, not a
# timing race.

snapshot_hook="$TMP/curate-snapshot-hook.sh"
cat >"$snapshot_hook" <<'HOOK'
#!/usr/bin/env bash
printf -- '- 2026-07-28: concurrent captain write landed mid-run.\n' >>"$1/captain.md"
HOOK
chmod +x "$snapshot_hook"

printf -- '- 2026-03-01: one-time cleanup. [COMPLETED 2026-03-02]\n' >"$records/captain.md"
rm -f "$records/captain-archive.md"
printf 'runs_since=4\ngeneration=5\n' >"$AC_HOME/state/.curate.meta"

# DISPUTED: whether the plan's old_sha256 for captain.md reflects the
# pristine pre-pass snapshot or a live re-read taken after the passes finish.
# HELD-CONSTANT: captain.md's starting content, the deterministic archive
# transform it undergoes, the gate stub's continue decision, and the hook's
# injected write (fires exactly once, at the same point in the run either way).
rc=0
out="$(AC_GATE="$gate_stub" AC_CURATE_SNAPSHOT_HOOK="$snapshot_hook" \
  "$BIN/ac-curate.sh" run 2>&1)" || rc=$?

grep -qF 'concurrent captain write landed mid-run' "$records/captain.md" \
  || fail "F3: a captain write during the curate run must survive - it was silently reverted (rc=$rc, out: $out)"
[ "$rc" -ne 0 ] || fail "F3: a concurrent write during the run must make the automatic apply refuse, not silently succeed (out: $out)"
assert_contains "$out" "Curate maintenance transaction could not apply or resume safely" \
  "F3: the race is caught as the machinery's own fail-closed refusal"

# --- run: the report's path rewrite is linear --------------------------------
# The passes write the report naming the shadow copy, and run rewrites it to
# the live records. bash 3.2's ${body//pat/rep} took 140 s under C on a 226 KB
# report and never finished under UTF-8, so Curate stalled every DISTILL that
# called it; a drydock-size report must settle under UTF-8 well inside 60 s.
# Its rows name paths as real Done rows do: every `/` was a place the old
# substitution tried every end of the body (measured: 47 KB took 29 s under
# C with paths in its rows, 0.14 s without). A home of its own, so no
# earlier row's transaction state reaches it.
bighome="$TMP/bighome"
mkdir -p "$bighome/records" "$bighome/state" "$bighome/data" "$bighome/config"
printf 'runs_since=4\ngeneration=0\n' >"$bighome/state/.curate.meta"
awk 'BEGIN { pad = ""; for (j = 0; j < 30; j++) pad = pad "src/x.ts "
  printf "## In flight\n\n## Queued\n\n## Done\n"
  for (i = 1; i <= 700; i++) printf "- [x] big%04d - receipt %s (merged 2026-01-01)\n", i, pad }' >"$bighome/records/backlog.md"
set -m
( bigrc=0
  AC_HOME="$bighome" LC_ALL=en_US.UTF-8 AC_CURATE_KEEP=0 AC_GATE="$gate_stub" "$BIN/ac-curate.sh" run >"$TMP/big.out" 2>&1 || bigrc=$?
  printf '%s\n' "$bigrc" >"$TMP/big.rc" ) &
bigpid=$!
set +m
i=0
while [ ! -e "$TMP/big.rc" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done
if [ ! -e "$TMP/big.rc" ]; then
  kill -KILL -- "-$bigpid" 2>/dev/null || true
  fail "a drydock-size Curate run did not finish within 60 s under en_US.UTF-8"
fi
assert_eq "$(cat "$TMP/big.rc")" "0" "the drydock-size run settles: $(tail -n 3 "$TMP/big.out")"
bigreport="$(ls "$bighome"/data/curate-*/report.md)"
[ "$(wc -c <"$bigreport" | tr -d ' ')" -gt 200000 ] || fail "the row's report is drydock-size (got $(wc -c <"$bigreport") bytes)"
assert_contains "$(cat "$bigreport")" "to $bighome/records/backlog-archive.md" "the big report names the live archive"
case "$(cat "$bigreport")" in */shadow/*) fail "the big report still names the shadow copy" ;; esac


# --- differential: src/curate.ts against the frozen bash original ----------
# DISPUTED: the implementation (tests/fixtures/ac-curate.sh under bash vs src/curate.ts through bin/ac-curate.sh)
# HELD-CONSTANT: two side roots seeded alike ($XOH for the oracle, $XNH for the shim) - a home at <side>/home rebuilt per row by the same commands (records, skills, state, data, project clones made by one git config), or copies of real fleet homes when XCURATE_HOMES names them; argv and env (the side root spelled @H, substituted in values only; AC_HOME=<side>/home and AC_GATE=the leg's stub gate unless a row names others; AC_TEST_HOOKS only on hook rows); cwd (<side>/cwd, an EMPTY dir, unless a row names another); stdin (/dev/null); LC_ALL=C unless a row names en_US.UTF-8; TMPDIR <side>/tmp; PATH stubs on both sides - date answering one instant per format, sleep logging each call and returning at once - plus a row's own; the live bin/ beside each entry (the oracle bin's copies, $BIN's own); exit status, stdout and stderr compared whole once normalised (the side root @H, either bin root ROOT, the run id curate-RUN, the entry's pid where it names a temp or a lock, every 64-hex digest SHA, a mktemp suffix XXXXXX), then the world: every path under home/, tmp/ and stub/ with its mode and bytes (records, archives, skills and skills-archive, the run dir, journals, .curate.meta, the room), each backup as its sorted tar listing; and each side's plans, receipts and journals checked against the hashes of ITS OWN files.
xobin="$(make_oracle_bin ac-curate)"
# The frozen entry calls the cadence and transaction helpers retired from
# bin/ac-maintenance-lib.sh and bin/ac-lib.sh once src/learn.ts took their
# last caller; the oracle's own lib copy gets them back, frozen at
# tests/fixtures/ac-maintenance-retired.sh.
cat "$ROOT/tests/fixtures/ac-maintenance-retired.sh" >>"$xobin/ac-maintenance-lib.sh"
cmp -s "$xobin/ac-curate.sh" "$ROOT/tests/fixtures/ac-curate.sh" || fail "the oracle bin holds the frozen original"
XOH="$TMP/xside-o"; XNH="$TMP/xside-n"
XSTUBS="$TMP/xstubs"; mkdir -p "$XSTUBS"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig"
# The room stamps its posts `+%Y-%m-%d %H:%M` through date(1) too.
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in
  *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;;
  *%H:%M*) echo '2026-01-01 07:00' ;;
  *%s*) echo 1767225600 ;;
  *) exec /bin/date "$@" ;;
esac
STUB
cat >"$XSTUBS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/sleep.log"
STUB
# The maintenance gate: a receipt for <subject> under its run, deciding
# CURATE_GATE_DECISION (continue), ask-captain for CURATE_GATE_ASK_SUBJECT;
# CURATE_GATE_RC exits with that status after CURATE_GATE_DIAG on stderr;
# CURATE_GATE_SAY is printed on stdout; CURATE_GATE_BAD binds the receipt to a
# hash no plan has; CURATE_GATE_TOUCH appends a line to that home path after
# the receipt for CURATE_GATE_TOUCH_SUBJECT (any) is written - a live input
# or target moving under the decision.
cat >"$XSTUBS/gate" <<'GATE'
#!/usr/bin/env bash
mode=""; run=""; subject=""; manifest=""; plan=""
printf '%s\n' "$*" >>"$STUB_DIR/gate.log"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --run) run="$2"; shift 2 ;;
    --subject) subject="$2"; shift 2 ;;
    --manifest) manifest="$2"; shift 2 ;;
    --plan) plan="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [ -n "${CURATE_GATE_RC:-}" ]; then
  [ -z "${CURATE_GATE_DIAG:-}" ] || printf '%s\n' "$CURATE_GATE_DIAG" >&2
  exit "$CURATE_GATE_RC"
fi
decision="${CURATE_GATE_DECISION:-continue}"
[ "$subject" != "${CURATE_GATE_ASK_SUBJECT:-}" ] || decision=ask-captain
[ -z "${CURATE_GATE_SAY:-}" ] || printf '%s\n' "$CURATE_GATE_SAY"
mkdir -p "$run/gates/$subject"
input_sha="$(shasum -a 256 <"$manifest" | awk '{print $1}')"
plan_sha="$(shasum -a 256 <"$plan" | awk '{print $1}')"
[ -z "${CURATE_GATE_BAD:-}" ] || plan_sha=0000000000000000000000000000000000000000000000000000000000000000
cat >"$run/gates/$subject/decision.md" <<EOF
---
schema: "agentcrew.maintenance-gate/v1"
mode: "$mode"
subject: "$subject"
decision: "$decision"
authority: "second-chief"
engine: "stub"
model: "leg"
input_manifest_sha256: "$input_sha"
action_plan_sha256: "$plan_sha"
reviewed_at: "2026-01-01T00:00:00Z"
---
# Maintenance Gate Decision
## Decision
$decision
## Grounds
The leg's stub judged the exact recoverable action plan.
## Inputs Read
- INPUT MANIFEST QUOTE: $(awk '{ if (length($0) > length(best)) best = $0 } END { print best }' "$manifest")
- ACTION PLAN NEW SHA-256: $(jq -r '.actions[0].new_sha256' "$plan")
- STAGED PAYLOAD QUOTE: $(prun="$(dirname "$plan")"; [ "$(basename "$prun")" != plans ] || prun="$(dirname "$prun")"; awk '{ if (length($0) > length(best)) best = $0 } END { print best }' "$prun/$(jq -r '.actions[0].staged' "$plan")")
## Proposed Process
Apply or preserve only the hash-bound subject.
EOF
[ -z "${CURATE_GATE_TOUCH:-}" ] || [ "${CURATE_GATE_TOUCH_SUBJECT:-$subject}" != "$subject" ] || { mkdir -p "$(dirname "$AC_HOME/$CURATE_GATE_TOUCH")"; printf 'moved under the gate\n' >>"$AC_HOME/$CURATE_GATE_TOUCH"; }
exit 0
GATE
chmod +x "$XSTUBS/date" "$XSTUBS/sleep" "$XSTUBS/gate"
xboth() {  # xboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$XOH" "$XNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
xseed() { [ ! -e "$H" ] || chmod -R u+rwX "$H"; rm -rf "$H"; mkdir -p "$H/home" "$H/cwd" "$H/tmp" "$H/stub"; }
xstd() { xseed; mkdir -p "$H/home/records" "$H/home/state" "$H/home/data" "$H/home/config" "$H/home/projects" "$H/home/skills"; }
xput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # xput <path under the side> <bytes>
xadd() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >>"$H/$1"; }  # xadd <path under the side> <bytes> - appended
xgit() { git init -q "$H/$1"; }   # xgit <path under the side> - an empty clone
xskill() {  # xskill <name> <description> [<landed>] - a learned skill in the side's fleet store
  mkdir -p "$H/home/skills/$1"
  { printf -- '---\nname: %s\ndescription: %s\norigin: learned\n' "$1" "$2"
    [ -z "${3:-}" ] || printf 'metadata:\n  landed: %s\n' "$3"
    printf -- '---\n# %s\nbody\n' "$1"; } >"$H/home/skills/$1/SKILL.md"
}
XLC=C; XENV=(); XCWD=cwd; XHOME=@H/home; XPATH=""; XGATE="$XSTUBS/gate"; XPLANT=""; XOBIN="$xobin"; XNBIN="$BIN"; XNOBIND=""
xrun_side() {  # xrun_side <bin> <side root> <prefix> <args...> - XPLANT=<path under the side> links <path>.<the entry's pid> to <side>/victim first
  local bin="$1" h="$2" p="$3" x v path rc=0; shift 3
  path="$XSTUBS:$PATH"; [ -z "$XPATH" ] || path="${XPATH//@H/$h}"
  local a=() e=("LC_ALL=$XLC" "PATH=$path" "TMPDIR=$h/tmp" "STUB_DIR=$h/stub" "CURATE_LEG_BIN=$bin")
  [ -z "$XHOME" ] || e+=("AC_HOME=${XHOME//@H/$h}")
  [ -z "$XGATE" ] || e+=("AC_GATE=$XGATE")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  # The group's stderr takes bash's own `Terminated` notice for a signalled row.
  { (cd "$h/$XCWD" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u CDPATH -u AC_LOCK_STALE_GRACE -u EPOCHSECONDS \
    -u AC_TEST_HOOKS -u AC_CURATE_KEEP -u AC_CURATE_STALE_DAYS -u AC_CURATE_SNAPSHOT_HOOK -u AC_GATE "${e[@]}" \
    /bin/sh -c 'printf %s "$$" >"$0"; [ -z "$1" ] || ln -s "$2" "$1.$$"; shift 2; exec "$@"' \
    "$TMP/$p.pid" "${XPLANT:+$h/$XPLANT}" "$h/victim" "$bin/ac-curate.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"; } 2>/dev/null || rc=$?
  cat "$TMP/$p.pid" >>"$h/.pids"; printf '\n' >>"$h/.pids"
  return "$rc"
}
xpids() {  # xpids <side root> - every run of the side since its seed, in order (each entry pid, then each a hook started)
  cat "$1/.pids" "$1/stub/nested.pid" 2>/dev/null || true
}
xnorm() {  # xnorm <file> <side root> - the side root @H, bin roots ROOT, digests SHA, the k-th run's id curate-RUN<k>, the last entry's pid in its temps and locks PID
  local e=() k=0 p last
  last="$(sed -n '$p' "$2/.pids" 2>/dev/null)"
  while IFS= read -r p; do [ -z "$p" ] || { k=$((k + 1)); e+=(-e "s/curate-[0-9]{10}-$p([^0-9]|\$)/curate-RUN$k\\1/g" -e "s/^$p\$/PID$k/"); }; done < <(xpids "$2")
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-curate#ROOT#g" -e "s#$TMP/xdef-[on]#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e 's/[0-9a-f]{64}/SHA/g' ${e[@]+"${e[@]}"} \
    -e "s/\\.tmp\\.${last:-none}/.tmp.PID/g" -e "s/\\.maintenance\\.${last:-none}\\./.maintenance.PID./g" -e "s/^${last:-none}\$/PID/" \
    -e 's/(ac-curate-[a-z]+)\.[A-Za-z0-9]{6}/\1.XXXXXX/g' "$1"
}
XO_RC=0; XN_RC=0
xpair() {  # xpair <args...> - both sides run, outputs normalised, nothing compared yet
  XO_RC=0; XN_RC=0
  xrun_side "$XOBIN" "$XOH" xo "$@" || XO_RC=$?
  xrun_side "$XNBIN" "$XNH" xn "$@" || XN_RC=$?
  xnorm "$TMP/xo.raw" "$XOH" >"$TMP/xo.out"; xnorm "$TMP/xo.err" "$XOH" >"$TMP/xo.err2"
  xnorm "$TMP/xn.raw" "$XNH" >"$TMP/xn.out"; xnorm "$TMP/xn.err" "$XNH" >"$TMP/xn.err2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xsame_rc_out() {
  assert_eq "$XN_RC" "$XO_RC" "curate differential exit for '$*' at line $(xrow)"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "curate differential stdout differs for '$*' at line $(xrow): $(diff -a "$TMP/xo.out" "$TMP/xn.out" | head -n 8)"
}
xsame_err() {
  cmp -s "$TMP/xo.err2" "$TMP/xn.err2" || fail "curate differential stderr differs for '$*' at line $(xrow): $(diff -a "$TMP/xo.err2" "$TMP/xn.err2" | head -n 8)"
}
xworld() {  # xworld <side root> - every path under home/ tmp/ stub/ in normalised byte order, with its mode and bytes (a backup: its tar listing)
  local h="$1" f n i p k last
  local -a names=() modes=() pids=()
  while IFS= read -r p; do [ -z "$p" ] || pids+=("$p"); done < <(xpids "$h")
  last="$(sed -n '$p' "$h/.pids" 2>/dev/null)"
  while IFS= read -r -d '' f; do names+=("$f"); done < <(cd "$h" && find home tmp stub -print0 2>/dev/null)
  [ "${#names[@]}" -eq 0 ] || while IFS= read -r f; do modes+=("$f"); done < <(cd "$h" && printf '%s\0' "${names[@]}" | xargs -0 stat -f '%Sp')
  for i in "${!names[@]}"; do
    n="${names[i]}"; k=0
    # shellcheck disable=SC2076
    for p in ${pids[@]+"${pids[@]}"}; do k=$((k + 1)); [[ $n =~ ^(.*curate-)[0-9]{10}-$p($|[^0-9].*)$ ]] && n="${BASH_REMATCH[1]}RUN$k${BASH_REMATCH[2]}"; done
    n="${n//.tmp.${last:-none}/.tmp.PID}"; n="${n//.maintenance.${last:-none}./.maintenance.PID.}"
    [[ $n =~ ^(.*ac-curate-[a-z]+\.)[A-Za-z0-9]{6}$ ]] && n="${BASH_REMATCH[1]}XXXXXX"
    printf '%s\t%s\n' "${n//$'\n'/\\n}" "$i"
  done | LC_ALL=C sort | while IFS=$'\t' read -r n i; do
    f="${names[i]}"
    if [ -L "$h/$f" ]; then printf '== %s -> %s\n' "$n" "$(readlink "$h/$f")"; continue; fi
    printf '== %s %s\n' "$n" "${modes[i]}"
    [ ! -d "$h/$f" ] || continue
    case "$f" in
      */state/backups/*.tar.gz) tar -tzf "$h/$f" 2>&1 | LC_ALL=C sort ;;
      *) cat "$h/$f" 2>/dev/null || printf '<unreadable>'; printf '\n' ;;
    esac
  done
}
xhashes() {  # xhashes <side root> - each plan binds its manifest, each receipt its plan and manifest, each journal its plan
  local h="$1" run p s m r j sha
  sha() { shasum -a 256 <"$1" | cut -d' ' -f1; }
  for run in "$h"/home/data/curate-*; do
    [ -d "$run" ] || continue
    for p in "$run"/plans/*.json; do
      [ -f "$p" ] || continue
      s="$(basename "$p" .json)"; m="$run/manifests/$s.json"; [ "$s" != deterministic-records ] || m="$run/input-manifest.json"
      [ ! -s "$m" ] || [ "$(jq -r .input_manifest_sha256 "$p")" = "$(sha "$m")" ] || fail "curate differential: $p does not bind $m (line $(xrow))"
      r="$run/gates/$s/decision.md"
      [ ! -f "$r" ] || [ -n "$XNOBIND" ] || grep -qxF "action_plan_sha256: \"$(sha "$p")\"" "$r" || fail "curate differential: $r does not bind $p (line $(xrow))"
      [ ! -f "$r" ] || [ ! -s "$m" ] || grep -qxF "input_manifest_sha256: \"$(sha "$m")\"" "$r" || fail "curate differential: $r does not bind $m (line $(xrow))"
    done
  done
  for j in "$h"/home/state/.maintenance-transactions/*/journal; do
    [ -f "$j" ] || continue
    p="$(sed -n 's/^plan=//p' "$j" | tail -1)"
    [ ! -f "$p" ] || [ "$(sed -n 's/^plan_sha256=//p' "$j" | tail -1)" = "$(sha "$p")" ] || fail "curate differential: $j does not bind $p (line $(xrow))"
  done
}
xsame_world() {
  xhashes "$XOH"; xhashes "$XNH"
  xworld "$XOH" >"$TMP/xo.world"; xworld "$XNH" >"$TMP/xn.world"
  xnorm "$TMP/xo.world" "$XOH" >"$TMP/xo.world2"; xnorm "$TMP/xn.world" "$XNH" >"$TMP/xn.world2"
  cmp -s "$TMP/xo.world2" "$TMP/xn.world2" || fail "curate differential world differs after '$*' at line $(xrow): $(diff -a "$TMP/xo.world2" "$TMP/xn.world2" | head -n 12)"
}
xsame() { xpair "$@"; xsame_rc_out "$@"; xsame_err "$@"; xsame_world "$@"; }
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err2"; }
xoout() { cat "$TMP/xo.out"; }
xoerr() { cat "$TMP/xo.err2"; }
xrefuse() {  # xrefuse <stderr> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xsame "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "curate refusal for '$*' at line $(xrow)"
}
xok() {  # xok <args...> - both sides succeed alike, nothing on stderr
  xsame "$@"
  assert_eq "$XN_RC:$(xerr)" "0:" "curate success for '$*' at line $(xrow)"
}
xwithout() {  # xwithout <tool> - the leg's PATH with every dir holding <tool> mirrored without it
  local dirs d f key mirror out=""
  IFS=: read -r -a dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$1" ]; then
      key="$(cd "$d" && pwd -P)"; mirror="$TMP/no$1$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
      if [ ! -d "$mirror" ]; then
        mkdir -p "$mirror"
        for f in "$key"/*; do [ "$(basename "$f")" = "$1" ] || ln -sf "$f" "$mirror/$(basename "$f")" 2>/dev/null || true; done
      fi
      d="$mirror"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$XSTUBS:$out"
}
XUSAGE='ERROR: usage: ac-curate.sh learnings|captain [--apply]|backlog [--apply]|projects|skills-audit|skills-consolidate [--apply]|run [--dry-run]'
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
XCAP='# Captain notes

- 2026-01-01: STANDING (captain): always do X, verbatim.
- 2026-01-02: temp migration order, do Y once. [COMPLETED 2026-01-03]
  continued on an indented line
	and a tab-indented one
- 2026-01-04: STANDING (captain): SUPERSEDES the Z clause; do Z2 now.
- 2026-01-05: old Z rule, do Z. [SUPERSEDED 2026-01-04 by the Z2 rule above]
- 2026-01-06: launch clause SUPERSEDED 2026-01-04; the rest HOLDS.
- 2026-01-07: STANDING watch rule [EXPIRED 2026-01-08]
- 2026-01-09: one-time cleanup, EXPIRED.
prose after the blocks
'
xbl() {  # xbl <done-count> - a ledger with <n> Done rows, newest first
  local i
  { printf '## In flight\n\n## Queued\n\n## Done\n'
    for i in $(seq "$1"); do printf -- '- [x] d%02d - receipt - local main (merged 2026-02-%02d)\n' "$i" "$(( (i % 28) + 1 ))"; done
  } >"$H/home/records/backlog.md"
}

# 1. dispatch and flags, every one before any home read: no verb, -h, --help,
#    '' and an unknown verb print the one usage line; a flag that is neither
#    --apply nor --dry-run refuses before the verb is read; both flags pass
#    every verb, repeated, honoured only where the verb reads them (`run
#    --apply` is the full automatic pass).
xboth xstd
xboth xput home/records/captain.md "$XCAP"
xboth xbl 3
xrefuse "$XUSAGE"
xrefuse "$XUSAGE" ''
xrefuse "$XUSAGE" -h
xrefuse "$XUSAGE" --help
xrefuse "$XUSAGE" bogus
xrefuse "ERROR: unknown flag: --x" bogus --x
xrefuse "ERROR: unknown flag: x" learnings x
xrefuse "ERROR: unknown flag: -h" captain --apply -h
xrefuse "ERROR: unknown flag: --nope" run --dry-run --nope
xok learnings --apply --dry-run --apply
xok captain --dry-run
xok backlog --dry-run --dry-run
xok projects --apply
xok skills-audit --dry-run --apply
xok skills-consolidate --dry-run
xok run --dry-run --dry-run --apply
xok run --apply
# BUN, named: the original ran learnings with no bun on PATH; the shim
# refuses before the verb is read.
XPATH="$(xwithout bun)"
xpair learnings
XPATH=""
assert_eq "$XO_RC:$(xoerr)" "0:" "1 (BUN, named): the original's learnings needs no bun"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: required tool not found: bun" "1 (BUN, named): the shim refuses without bun"

# 2. the home: relative (from the caller's cwd), a link to it (paths printed
#    physical), every bare-dir verb's minted dirs, homeless for every verb
#    whose first home read refuses (never skills-audit or run - their
#    homeless arms read and write the host root, W14, named and pinned by
#    tests/ts/curate.test.ts instead); an AC_HOME cd cannot enter and a
#    CDPATH-relative one (HOME RESOLUTION, named).
xboth xseed
XCWD=.; XHOME=home
xok learnings
XCWD=cwd; XHOME=@H/home
xboth xput home/records/captain.md "$XCAP"
xboth ln -s home @H/homelink
XHOME=@H/homelink
xok captain
XHOME=@H/home
for xv in learnings captain backlog projects skills-audit skills-consolidate 'run --dry-run' run; do
  xboth xseed
  # shellcheck disable=SC2086
  xok $xv
done
XHOME=""
for xv in learnings 'captain --apply' 'backlog --apply' projects 'skills-consolidate --apply'; do
  xboth xseed
  # shellcheck disable=SC2086
  xrefuse "$XNOHOME" $xv
done
XHOME=@H/home
xboth xseed
XHOME=@H/nope
xpair learnings
XHOME=@H/home
assert_eq "$XO_RC:$XN_RC:$(xoout)$(xout)" "1:1:" "2 (HOME RESOLUTION, named): an AC_HOME cd cannot enter refuses on both sides"
assert_contains "$(xoerr)" "cd: @H/nope: No such file or directory" "2: the original printed cd's own line"
assert_eq "$(xerr)" "ERROR: AC_HOME is not a readable directory: @H/nope" "2: the port names the variable"
xboth mkdir -p @H/cdp/home
XCWD=.; XHOME=home; XENV=(CDPATH=@H/cdp)
xpair learnings
XCWD=cwd; XHOME=@H/home; XENV=()
assert_eq "$XO_RC:$XN_RC" "0:0" "2 (HOME RESOLUTION, named): a relative AC_HOME under CDPATH"
[ -d "$XNH/home/records" ] && [ ! -e "$XNH/cdp/home/records" ] || fail "2: the port resolves a relative AC_HOME without CDPATH"
[ ! -e "$XOH/home/records" ] && [ -d "$XOH/cdp/home"$'\n' ] || fail "2: the original took cd's echo of the CDPATH match into the home and minted a dir named by it"

# 3. learnings: absent; canonical rows that resolve (a skill, a crewmate
#    lesson); a link gone, no link, a `)` inside the link, rung-qualified
#    rows (several on a line); a NUL inside the first 32 KB (grep reads the
#    file as binary: one `Binary file ... matches` row) and past it (the row
#    read without its NUL); an invalid byte under C and en_US.UTF-8.
xboth xstd
xok learnings
xboth xput home/CREWMATE-learned.md 'lessons'
xboth mkdir -p @H/home/skills/live
xboth xput home/skills/live/SKILL.md 'x'
xboth xput home/records/learnings.md '# Learning Ledger

- [distilled -> lessononly] sources=2 updated=2026-08-05 ([lesson](../CREWMATE-learned.md))
- [distilled -> live] sources=2 updated=2026-08-05 ([skill](../skills/live/SKILL.md))
'
xok learnings
xboth xadd home/records/learnings.md '- [distilled -> gone] sources=1 updated=2026-08-05 ([skill](../skills/gone/SKILL.md))
- [distilled -> linkless] sources=1 updated=2026-08-05
- [distilled -> paren] x ([s](a)b.md)) and ](c.md)
- [distilled -> UPPER] not canonical ([s](x.md))
  - [distilled -> indented] not canonical either
- 2026 [distilled -> one @fleet] and [distilled -> two @container] on one line, [distilled -> three @other]
'
xok learnings
xboth xadd home/records/learnings.md "$(printf -- '- [distilled -> nul] has a \001 control byte ([s](n.md))\n- [distilled -> caf] caf\351 ([s](c.md))')"
xok learnings
XLC=en_US.UTF-8
xok learnings
XLC=C
xboth sh -c 'printf -- "- [distilled -> nul] a \\000 nul ([s](n.md))\\n- [distilled -> x @fleet] y\\n" >>"$0/home/records/learnings.md"' @H
xok learnings
xboth sh -c 'awk "BEGIN { for (i = 0; i < 700; i++) printf \"filler line %04d padding padding padding padding\\n\", i }" >"$0/home/records/learnings.md"; printf -- "- [distilled -> late] a \\000 nul past 32 KB ([s](n.md))\\n" >>"$0/home/records/learnings.md"' @H
xok learnings

# 4. captain: absent, no marker, every class (STANDING+COMPLETED, partial
#    SUPERSEDED, continuation lines), propose, apply, an apply with only
#    notes, an existing archive and link, an unterminated last line moved
#    and kept, a NUL in a moved block and in a survivor (W6, at parity), an
#    invalid byte under C and en_US.UTF-8 (W8, named), a backup that cannot
#    be taken (W4, at parity), TMPDIR unusable, a link planted at the temp
#    and a 0600 record (W15, named).
xboth xstd
xok captain
xboth xput home/records/captain.md '# Captain notes

- 2026-01-01: a live rule.
'
xok captain --apply
xboth xput home/records/captain.md "$XCAP"
xok captain
xok captain --apply
xok captain --apply
xboth xput home/records/captain.md '- 2026-02-01: STANDING (captain): SUPERSEDES the old clause; do new.
- 2026-02-02: launch clause SUPERSEDED above; the rest holds.
- 2026-02-03: STANDING order COMPLETED once, still standing.'
xok captain --apply
xboth xput home/records/captain.md "$(printf -- '- 2026-03-01: a kept rule\n- 2026-03-02: last order. [COMPLETED]')"
xok captain --apply
xboth sh -c 'printf -- "- 2026-03-03: retired order [EXPIRED] with \000 a nul\n- 2026-03-04: a kept \000 nul rule\n- 2026-03-05: kept unterminated" >"$0/home/records/captain.md"' @H
xok captain --apply
xboth xput home/records/captain.md "$(printf -- '- 2026-03-06: caf\351 rule. [COMPLETED]\n- 2026-03-07: kept\n')"
xok captain
XLC=en_US.UTF-8
xpair captain --apply
XLC=C
assert_eq "$XO_RC:$XN_RC" "2:0" "4 (W8, named): under UTF-8 the original's awk aborts at the invalid byte, the port reads bytes"
assert_contains "$(xoerr)" "towc" "4 (W8): the original's own awk diagnostic"
assert_contains "$(xout)" "CURATED: moved 1 block(s)" "4 (W8): the port moves the block"
xboth xstd
xboth xput home/records/captain.md "$XCAP"
xboth mkdir -p @H/home/state/backups
xboth chmod 555 @H/home/state/backups
xsame captain --apply
assert_contains "$(xout)" $'  pre-run backup: \n  CURATED: moved' "4 (W4): a failed backup prints an empty path, and the apply goes on"
xboth chmod 755 @H/home/state/backups
xboth xput home/records/captain.md "$XCAP"
XENV=(TMPDIR=@H/nope)
xsame captain --apply
XENV=()
assert_eq "$XN_RC" "1" "4: an unusable TMPDIR ends the apply"
xboth xput home/records/captain.md "$XCAP"
xboth sh -c 'printf victim >"$0/victim"' @H
XPLANT=home/records/captain.md.tmp
xpair captain --apply
XPLANT=""
xsame_rc_out captain --apply; xsame_err captain --apply
assert_eq "$(cat "$XNH/victim")" "victim" "4 (W15, named): the port never writes through a planted temp"
assert_contains "$(cat "$XOH/victim")" "always do X" "4 (W15): the original wrote the survivors into the link's target..."
[ -L "$XOH/home/records/captain.md" ] && [ -f "$XNH/home/records/captain.md" ] && [ ! -L "$XNH/home/records/captain.md" ] || fail "4 (W15): ...and left the record a link, where the port's is a file"
xboth xstd
xboth xput home/records/captain.md "$XCAP"
xboth chmod 600 @H/home/records/captain.md
xpair captain --apply
xsame_rc_out captain --apply; xsame_err captain --apply
assert_eq "$(stat -f %Lp "$XOH/home/records/captain.md"):$(stat -f %Lp "$XNH/home/records/captain.md")" "644:600" "4 (W15, named): the original left the rewrite at the umask's mode, the port keeps the record's"
xboth chmod 644 @H/home/records/captain.md
xsame_world captain --apply

# 5. backlog: keep default, 0, 1 and the strnum spellings (W12, at parity),
#    an escape in the keep (awk -v), blocked-by and epic protection (an
#    absent epic row, a chain whose middle epic leaves, one whose outcome
#    awk's hash order decides), `## Notes`, a 600-line move, an empty Done,
#    NUL (W6) and an unterminated last row moved twice (W7), the ledger lock
#    held (W5, at parity); BUN (named).
xboth xstd
xok backlog --apply
xboth xbl 22
xok backlog
xok backlog --apply
for xk in 0 1 abc -1 1e1 0x3 ' 3' 1.5 010 08 99999999999999999999 '\061' -inf nan; do
  xboth xbl 12
  XENV=("AC_CURATE_KEEP=$xk")
  xok backlog --apply
done
XENV=()
xboth xput home/records/backlog.md '## In flight
- [ ] bigepic [EPIC] - the epic stories: s1 (repo: x, since 2026-02-01)

## Queued
- [ ] q1 - needs the blocker (repo: x) blocked-by: dblock,dother - waiting

## Notes
- [x] noted - a row outside the three sections

## Done
- [x] dnew - recent - local main (merged 2026-02-09)
- [x] dblock - the blocker Done (merged 2026-02-08)
- [x] s1 - a done story; epic:bigepic (merged 2026-02-07)
- [x] s2 - a story of an archived epic; epic:oldepic (merged 2026-02-06)
- [x] s3 - a story of an absent epic; epic:nowhere (merged 2026-02-05)
- [x] s4 - a story of a middle epic; epic:midepic (merged 2026-02-04)
- [x] midepic [EPIC] - a sub-epic; epic:topepic (merged 2026-02-03)
- [x] oldepic [EPIC] - archived itself (merged 2026-02-02)
- [x] dfree - unreferenced old (merged 2026-02-01)
'
XENV=(AC_CURATE_KEEP=1)
xok backlog
xok backlog --apply
# awk walks the tentative rows in its hash order, not the ledger's: line 23
# (the middle epic, whose own epic is absent) is visited and dropped before
# line 21, its story, which then stays too.
xboth sh -c '{ printf "## In flight\n\n## Queued\n\n## Done\n"; for i in $(seq 6 20); do printf -- "- [x] f%02d - filler (merged 2026-01-01)\n" "$i"; done; printf -- "- [x] s4 - a story of a middle epic; epic:midepic (merged 2026-01-01)\n- [x] f22 - filler\n- [x] midepic [EPIC] - a sub-epic; epic:topepic (merged 2026-01-01)\n- [x] f24 - filler\n"; } >"$0/home/records/backlog.md"' @H
XENV=(AC_CURATE_KEEP=0)
xok backlog --apply
grep -q 'f20 - filler' "$XNH/home/records/backlog-archive.md" && grep -q 's4 - a story' "$XNH/home/records/backlog.md" || fail "5: the story whose epic awk dropped first stays"
xboth sh -c 'awk "BEGIN { printf \"## In flight\\n\\n## Queued\\n\\n## Done\\n\"; for (i = 1; i <= 600; i++) printf \"- [x] l%03d - receipt - local main (merged 2026-01-01)\\n\", i }" >"$0/home/records/backlog.md"' @H
XENV=(AC_CURATE_KEEP=0)
xok backlog --apply
xboth sh -c 'printf "## In flight\n\n## Queued\n- [ ] q1 - has a \000 nul (repo: x)\n\n## Done\n- [x] d3 - keep\n- [x] d2 - has \000 nul (merged 2026-02-02)\n- [x] d1 - last (merged 2026-01-01)" >"$0/home/records/backlog.md"' @H
XENV=(AC_CURATE_KEEP=1)
xok backlog --apply
xboth xadd home/records/backlog.md "$(printf -- '- [x] d0 - moved again (merged 2026-01-01)')"
xok backlog --apply
XENV=()
xboth xbl 22
xboth mkdir -p @H/home/records/.backlog.md.lock
xboth sh -c 'printf "%s\n" "$PPID" >"$0/home/records/.backlog.md.lock/pid"' @H
xok backlog --apply
xboth rm -rf @H/home/records/.backlog.md.lock
xboth xbl 22
XPATH="$(xwithout bun)"
xpair backlog
XPATH=""
assert_eq "$XO_RC:$XN_RC" "2:1" "5 (BUN, named): the original's parser exits 2 without bun, the shim refuses 1"
assert_contains "$(xoerr)" "ERROR: the backlog parser failed on" "5 (BUN): the original names its parser"
assert_eq "$(xerr)" "ERROR: required tool not found: bun" "5 (BUN): the shim names bun"

# 6. projects: absent, a dangling link, a link to a file, a plain dir, a
#    repo, a nested name, `..` (W16, at parity), no bracket, a prose bullet,
#    a TAB inside a name, an invalid byte under en_US.UTF-8; then the home
#    inside a git work tree (W16).
xboth xstd
xok projects
xboth xgit home/projects/realp
xboth mkdir -p @H/home/projects/plain @H/home/projects/a/b
xboth ln -s @H/nowhere @H/home/projects/dangling
xboth xput home/projects-file 'f'
xboth ln -s @H/home/projects-file @H/home/projects/tofile
xboth xput home/records/projects.md "$(printf '# Projects\n\n- realp [local-only] - a real project (added 2026-02-01)\n- deadp [direct-pr] - gone (added 2026-02-01)\n- plain - a plain dir (added 2026-02-02)\n- dangling [x] - a dangling link\n- tofile - a link to a file\n- a/b - nested\n- .. - x\n- a prose bullet is not a registry line\n- ta\tb [x] - a tab in the name\n- cafe [x] - caf\351 gone\n')"
xok projects --apply
XLC=en_US.UTF-8
xok projects
XLC=C
xboth git init -q @H/home
xok projects

# 7. skills-audit: no skills; overlap (stop words, quoted descriptions, an
#    indented key, a CRLF frontmatter); every stale predicate - landed
#    quoted and unquoted, a SKILL.md mtime, last_seeded, the evidence mtime,
#    a pending candidate and a completed journal, an active worktree link -
#    and AC_CURATE_STALE_DAYS 0, 010, 08 and 15 digits (W13, at parity).
xboth xstd
xok skills-audit
xboth xskill ov-one 'verify crewmate briefing carefully, before anything'
xboth xskill ov-two '"crewmate briefing verify twice before"'
xboth xskill ov-three "'briefing crewmate verify anything again'"
xboth xskill ov-solo 'rebase worktree landing dance'
xboth xskill ov-pair-a 'migrate ledgers with care'
xboth xskill ov-pair-b 'ledgers migrate nothing else'
xboth mkdir -p @H/home/skills/skills-archive/old @H/home/skills/nofile @H/home/skills/.hidden
xboth xput home/skills/skills-archive/old/SKILL.md '---
description: briefing crewmate verify
---'
xboth xput home/skills/crlf/SKILL.md "$(printf -- '---\r\ndescription: crewmate briefing verify\r\n---\r\n')"
xboth xput home/skills/indent/SKILL.md '---
   description:    crewmate	briefing in an indented key
---'
xok skills-audit
xboth xstd
for xs in st-old st-seeded st-evidence st-pending st-done st-active st-fresh st-bare; do xboth xskill "$xs" "solitary $xs" '"1577836800"'; done
xboth xskill st-unquoted 'solitary unquoted' 1577836800
xboth xskill st-octal 'solitary octal' 0100
xboth xskill st-nolanded 'solitary nolanded'
xboth sh -c 'for d in "$0"/home/skills/st-*; do touch -t 202001010000 "$d/SKILL.md"; done; touch -t 202512300000 "$0/home/skills/st-fresh/SKILL.md"' @H
xboth xput home/skills/st-seeded/.usage.meta 'last_seeded=1767225000
'
xboth mkdir -p @H/home/records/learnings-archive
xboth xput home/records/learnings-archive/st-evidence.md '# recent'
xboth touch -t 202512310000 @H/home/records/learnings-archive/st-evidence.md
xboth xput home/data/learning-a/candidate-st-pending.md 'kind: patch
name:   st-pending
'
xboth xput home/data/learning-b/candidates/st-done.md 'name: st-done
'
xboth xput home/state/.maintenance-transactions/learning-b-st-done/journal 'status=complete
'
xboth mkdir -p @H/wt/.claude/skills
xboth ln -s @H/home/skills/st-active @H/wt/.claude/skills/st-active
xboth xput home/state/active.meta 'worktree=@H/wt
'
xok skills-audit
for xd in 0 010 999999999999999; do
  XENV=("AC_CURATE_STALE_DAYS=$xd")
  xok skills-audit
done
XENV=(AC_CURATE_STALE_DAYS=08)
xpair skills-audit
XENV=()
xsame_rc_out skills-audit
assert_eq "$XO_RC:$XN_RC" "1:1" "7 (W13, at parity): an octal-invalid AC_CURATE_STALE_DAYS ends the audit 1"
assert_contains "$(xoerr)" "08: value too great for base" "7 (SHELL-OWN STDERR, named): the original's arithmetic line, not reproduced"
assert_eq "$(xerr)" "" "7 (SHELL-OWN STDERR): the port exits with nothing of its own"

# 8. skills-consolidate: no cluster; umbrella-less groups (one with an empty
#    prefix); movers propose and --apply (exit 2); names that collate
#    differently under en_US.UTF-8 (W18 ORDER, named).
xboth xstd
xboth xskill solo 'alone'
xok skills-consolidate --apply
xboth xskill ship 'umbrella'
xboth xskill ship-rebase 'rebase step'
xboth xskill ship-attest 'attest step'
xboth xskill bar-x 'no umbrella'
xboth xskill bar-y 'no umbrella either'
xboth xskill -lead 'an empty prefix'
xboth xskill -led 'an empty prefix too'
xok skills-consolidate
xsame skills-consolidate --apply
assert_eq "$XN_RC" "2" "8: a direct --apply with movers refuses 2"
xboth xskill x 'umbrella x'
xboth xskill x-_c 'underscore'
xboth xskill x-A 'capital'
xok skills-consolidate
XLC=en_US.UTF-8
xpair skills-consolidate
XLC=C
assert_eq "$XO_RC:$XN_RC" "0:0" "8 (W18 ORDER, named): both sides list the cluster"
cmp -s "$TMP/xo.out" "$TMP/xn.out" && fail "8 (W18): under en_US.UTF-8 the original's sort orders x-_c and x-A by collation"
assert_contains "$(xout)" "sibling x-A -> archive (umbrella x stays)
  CLUSTER x: sibling x-_c" "8 (W18): the port keeps byte order under any locale"

# 9. run, deterministic: --dry-run, nothing to do (a zero-action claim and
#    backup, W3), captain and backlog moves (the report's shadow paths named
#    live, a home path holding \ & ' * [ ]), a symlinked record, the snapshot
#    hook's concurrent write (the refusal and the held claim, W2), another
#    unsettled transaction, a busy cadence lock and a newer generation (the
#    reset's WARN), an unreadable file under skills/ (a held backup, W3), and
#    a drydock-size report under C and en_US.UTF-8.
xboth xstd
xboth xput home/state/.curate.meta 'runs_since=4
generation=0
'
xok run --dry-run
xok run
xok run
xboth xput home/records/captain.md "$XCAP"
xboth xbl 23
xboth xput home/state/.curate.meta 'runs_since=4
generation=0
'
xok run --dry-run
xok run
xboth xstd
xboth mkdir -p "@H/home/w\\&'*[]x"
XHOME="@H/home/w\\&'*[]x"
xboth xput "home/w\\&'*[]x/records/captain.md" "$XCAP"
xok run
XHOME=@H/home
xboth xstd
xboth xput home/records/real.md "$XCAP"
xboth ln -s real.md @H/home/records/captain.md
xsame run
assert_eq "$XN_RC:$(xerr)" "1:ERROR: Curate input manifest refused a non-file or symlink" "9: a symlinked record refuses the input manifest"
xboth xstd
xboth xput home/records/captain.md "$XCAP"
xboth xput hook.sh '#!/bin/sh
printf -- "- 2026-07-28: concurrent captain write landed mid-run.\n" >>"$1/captain.md"
'
xboth chmod +x @H/hook.sh
XENV=(AC_TEST_HOOKS=1 AC_CURATE_SNAPSHOT_HOOK=@H/hook.sh)
xsame run
assert_eq "$XN_RC" "1" "9 (W2): the concurrent write refuses the deterministic apply"
assert_contains "$(xerr)" "is HELD (target records/captain.md no longer matches" "9 (W2): ...and holds the claim"
XENV=()
xsame run
assert_contains "$(xerr)" "another Learning/Curate transaction is still unsettled" "9 (W2, at parity): the held claim refuses the next run"
xboth xstd
xboth xput home/state/.maintenance-transactions/learning-x-y/journal 'status=applying
'
xsame run
assert_eq "$XN_RC" "1" "9: another unsettled transaction refuses the run"
xboth xstd
xboth xput home/state/.curate.meta 'runs_since=4
generation=2
'
xboth mkdir -p @H/home/state/.curate-cadence.lock
xboth sh -c 'printf "%s\n" "$PPID" >"$0/home/state/.curate-cadence.lock/pid"' @H
xsame run
assert_contains "$(xerr)" "WARN: Curate committed, but did not reset its cadence" "9: a busy cadence lock is the run's WARN"
xboth rm -rf @H/home/state/.curate-cadence.lock
xboth xput hook.sh '#!/bin/sh
printf "runs_since=9\ngeneration=7\n" >"$1/../state/.curate.meta"
'
xboth chmod +x @H/hook.sh
XENV=(AC_TEST_HOOKS=1 AC_CURATE_SNAPSHOT_HOOK=@H/hook.sh)
xsame run
XENV=()
assert_contains "$(xerr)" "WARN: Curate committed, but did not reset its cadence" "9: a newer generation keeps its late ticks"
xboth xstd
xboth xskill locked 'an unreadable file inside'
xboth xput home/skills/locked/secret 'x'
xboth chmod 000 @H/home/skills/locked/secret
xsame run
assert_contains "$(xerr)" "is HELD (the pre-mutation backup could not be taken)" "9 (W3, at parity): a backup tar cannot finish holds even a zero-action claim"
xsame run
xboth chmod 644 @H/home/skills/locked/secret
for xl in C en_US.UTF-8; do
  xboth xstd
  xboth sh -c 'awk "BEGIN { pad = \"\"; for (j = 0; j < 30; j++) pad = pad \"src/x.ts \"; printf \"## In flight\\n\\n## Queued\\n\\n## Done\\n\"; for (i = 1; i <= 700; i++) printf \"- [x] big%04d - receipt %s (merged 2026-01-01)\\n\", i, pad }" >"$0/home/records/backlog.md"' @H
  XLC=$xl; XENV=(AC_CURATE_KEEP=0)
  xok run
  XLC=C; XENV=()
  [ "$(wc -c <"$(ls "$XNH"/home/data/curate-*/report.md)" | tr -d ' ')" -gt 200000 ] || fail "9: the drydock-size row's report is drydock-size ($xl)"
done

# 10. run, semantic: captain targets by below, above and date; a date with a
#     stray `above` (W9, at parity); ambiguous, partial and duplicated first
#     lines; settled by the archive on the next run; acknowledged, its
#     material changed, an empty material; absent projects incl. a
#     TAB-ended line (W11, at parity) and an invalid byte; skill moves with
#     nested files and .usage.meta, a missing pointer or evidence,
#     an active worktree link, a symlink inside, an LF-named file (W10, at
#     parity); the gate answering continue, revise, ask-captain, 3 with a
#     diagnostic, 4, 1, a receipt bound to no plan, a manifest input moved
#     under the decision, an action target moved under it; the room that
#     cannot be written (its WARN); the default gate beside the entry.
xsemantic() {  # xsemantic - a home with one subject of each kind
  xstd
  xput home/records/captain.md '- 2026-04-02: STANDING new policy SUPERSEDES the named rule below.
- 2026-04-01: old named policy.
- 2026-03-31: unrelated active policy.
- 2026-03-30: STANDING keeper SUPERSEDES the rule above.
- 2026-03-20: STANDING dated SUPERSEDES the 2026-03-31 policy.
- 2026-03-09: STANDING new SUPERSEDES the 2026-03-01 rule (context in the note above).
- 2026-03-05: an unrelated live policy.
- 2026-03-01: the dated rule.
- 2026-02-02: STANDING lonely SUPERSEDES nothing named.
- 2026-02-01: STANDING partial SUPERSEDES the clause below.
- 2026-01-31: earlier policy; launch clause superseded, the rest holds.
'
  xput home/records/projects.md "$(printf '# Projects\n\n- realp [local-only] - a real project\n- deadp [direct-pr] - gone (added 2026-02-01)\n- tabp [x] - a tab-ended line\t\n- cafep [x] - caf\351 gone\n')"
  xgit home/projects/realp
  xskill ship 'the ship umbrella'
  xskill ship-rebase 'rebase step'
  mkdir -p "$H/home/skills/ship-rebase/refs/deep"
  xput home/skills/ship-rebase/refs/deep/notes.md 'nested notes'
  xput home/skills/ship-rebase/.usage.meta 'seeded_count=3
'
  xskill ship-attest 'attest step, no evidence'
  xskill ship-gone 'no pointer'
  xskill solo-x 'no umbrella'
  mkdir -p "$H/home/records/learnings-archive"
  xput home/records/learnings-archive/ship-rebase.md '# evidence'
  xput home/records/learnings-archive/ship-gone.md '# evidence'
  xput home/records/learnings.md '# Learning Ledger

## Distilled

- [distilled -> ship-rebase] sources=3 updated=2026-07-20 ([skill](../skills/ship-rebase/SKILL.md); [evidence](learnings-archive/ship-rebase.md))
- [distilled -> ship-attest] sources=2 updated=2026-07-21 ([skill](../skills/ship-attest/SKILL.md))
'
  xput home/state/.curate.meta 'runs_since=4
generation=0
'
}
for xd in continue revise ask-captain; do
  xboth xsemantic
  XENV=("CURATE_GATE_DECISION=$xd")
  xok run
  xok run
done
XENV=()
xboth xsemantic
XENV=(CURATE_GATE_RC=3 'CURATE_GATE_DIAG=maintenance-gate[stub]: engine did not produce a valid decision')
xok run
for xr in 4 1; do
  xboth xsemantic
  XENV=("CURATE_GATE_RC=$xr")
  xok run
done
xboth xsemantic
XENV=(CURATE_GATE_BAD=1); XNOBIND=1
xok run
XNOBIND=""
xboth xsemantic
XENV=(CURATE_GATE_SAY=a-gate-line CURATE_GATE_TOUCH=skills/ship/SKILL.md)
xok run
xboth xsemantic
XENV=(CURATE_GATE_TOUCH=skills/skills-archive/ship-rebase/refs/deep/notes.md CURATE_GATE_TOUCH_SUBJECT=skill-ship-rebase)
xsame run
assert_contains "$(xerr)" "WARN: continue receipt for Curate subject skill-ship-rebase became stale or could not resume" "10: a target moved under the decision refuses its apply"
XENV=()
xboth xsemantic
xboth mkdir -p @H/home/data/curate
xboth chmod 555 @H/home/data/curate
xsame run
assert_contains "$(xerr)" "WARN: captain escalation for Curate subject" "10: a room that cannot be written is the run's WARN"
xboth chmod 755 @H/home/data/curate
xboth xsemantic
XENV=(CURATE_GATE_DECISION=ask-captain)
xok run
sed -n 's/^ *\(- [a-z0-9-]* material=[0-9a-f]\{64\}\) .*/\1 ruling: records\/captain.md:1 - kept by ruling/p' "$TMP/xo.raw" >"$TMP/xack"
[ -s "$TMP/xack" ] || fail "10: the asks print paste-ready acknowledgement lines"
xboth cp "$TMP/xack" @H/home/records/curate-acknowledged.md
XENV=()
xok run
xboth xsemantic
xboth xput home/records/curate-acknowledged.md "$(printf -- '- captain-supersedes-9 material=%s ruling: never\n- x material=y ruling:\n' "$(printf '' | shasum -a 256 | cut -d' ' -f1)")"
xok run
xboth xstd
xboth xput home/records/captain.md '- 2026-06-05: STANDING duplicated SUPERSEDES the clause below.
- 2026-06-05: STANDING duplicated SUPERSEDES the clause below.
- 2026-06-04: earlier policy.
'
xok run
xboth xstd
xboth xskill run 'umbrella'
xboth xskill run-a 'a sibling with a link inside'
xboth ln -s ../run/SKILL.md @H/home/skills/run-a/linked.md
xboth xskill run-b 'a sibling whose package has an LF-named file'
xboth sh -c 'printf x >"$0/home/skills/run-b/a
b.md"' @H
xboth xskill run-c 'a sibling an active worktree seeds'
xboth mkdir -p @H/wt/.claude/skills
xboth ln -s @H/home/skills/run-c @H/wt/.claude/skills/run-c
xboth xput home/state/active.meta 'worktree=@H/wt
'
xboth mkdir -p @H/home/records/learnings-archive
for xs in run-a run-b run-c; do xboth xput "home/records/learnings-archive/$xs.md" '# evidence'; done
xboth xput home/records/learnings.md '- [distilled -> run-a] sources=1 updated=2026-07-20 ([skill](../skills/run-a/SKILL.md))
- [distilled -> run-b] sources=1 updated=2026-07-20 ([skill](../skills/run-b/SKILL.md))
- [distilled -> run-c] sources=1 updated=2026-07-20 ([skill](../skills/run-c/SKILL.md))
'
xpair run
xsame_rc_out run; xsame_world run
grep -v 'ac-lib\.sh: line [0-9]*: ' "$TMP/xo.err2" >"$TMP/xo.err3" || true
cmp -s "$TMP/xo.err3" "$TMP/xn.err2" || fail "10 (W10): stderr past the original's own redirect lines differs: $(diff "$TMP/xo.err3" "$TMP/xn.err2" | head -n 8)"
assert_contains "$(xoerr)" "ac-lib.sh: line" "10 (SHELL-OWN STDERR, named): the original's redirect line for each half of the LF-named file"
assert_contains "$(xerr)" "cp: " "10 (W10, at parity): both copy the two halves of the LF-named file and fail, the move going on"
xboth xsemantic
mkdir -p "$TMP/xdef-o/bin" "$TMP/xdef-n/bin"
cp "$xobin"/*.sh "$TMP/xdef-o/bin/"; cp "$BIN"/*.sh "$TMP/xdef-n/bin/"
for xd in xdef-o xdef-n; do ln -sfn "$ROOT/src" "$TMP/$xd/src"; ln -sfn "$ROOT/dashboard" "$TMP/$xd/dashboard"; cp "$XSTUBS/gate" "$TMP/$xd/bin/ac-gate.sh"; done
XOBIN="$TMP/xdef-o/bin"; XNBIN="$TMP/xdef-n/bin"; XGATE=""
xok run
XOBIN="$xobin"; XNBIN="$BIN"; XGATE="$XSTUBS/gate"

# 11. concurrency and signals: a whole run started by the snapshot hook inside
#     another's window (W2, at parity: the outer run ends HELD 0/1, the next
#     run is refused); TERM during the snapshot hook (143 at once, the run
#     dir left, nothing applied); a write landing inside a compatibility
#     apply's backup window (a PATH tar that appends, then runs the real one)
#     is kept, as the shell's sed and awk read the record at the write.
xboth xstd
xboth xput tarstub/tar '#!/bin/sh
printf -- "- 2026-04-01: a rule added during the backup\n" >>"$AC_HOME/records/captain.md"
printf -- "- [x] late - a row landed during the backup (2026-04-01)\n" >>"$AC_HOME/records/backlog.md"
exec /usr/bin/tar "$@"
'
xboth chmod +x @H/tarstub/tar
xboth xput home/records/captain.md '- 2026-03-01: a kept rule
- 2026-03-02: last order. [COMPLETED]
'
xboth xput home/records/backlog.md '## In flight

## Queued

## Done
- [x] d1 - receipt (2026-01-01)
- [x] d2 - receipt (2026-01-02)
'
XPATH="@H/tarstub:$XSTUBS:$PATH" xok captain --apply
assert_contains "$(cat "$XNH/home/records/captain.md")" "a rule added during the backup" "11: a captain rule added during the backup survives the apply"
XENV=(AC_CURATE_KEEP=0)
XPATH="@H/tarstub:$XSTUBS:$PATH" xok backlog --apply
XENV=()
assert_contains "$(cat "$XNH/home/records/backlog.md")" "- [x] late - a row landed during the backup" "11: a Done row landed during the backup stays in the backlog"
xboth xstd
xboth xput home/records/captain.md "$XCAP"
mkdir -p "$TMP/xlater"
sed 's/2026-01-01T/2026-01-02T/; s/1767225600/1767312000/' "$XSTUBS/date" >"$TMP/xlater/date"
chmod +x "$TMP/xlater/date"
xboth xput hook.sh '#!/bin/sh
PATH="$CURATE_LEG_LATER:$PATH" env -u AC_TEST_HOOKS /bin/sh -c '"'"'printf "%s\n" "$$" >>"$0"; exec "$@"'"'"' "$STUB_DIR/nested.pid" "$CURATE_LEG_BIN/ac-curate.sh" run >"$STUB_DIR/nested.out" 2>&1
'
xboth chmod +x @H/hook.sh
XENV=(AC_TEST_HOOKS=1 AC_CURATE_SNAPSHOT_HOOK=@H/hook.sh "CURATE_LEG_LATER=$TMP/xlater")
xsame run
XENV=()
assert_contains "$(cat "$XNH/stub/nested.out")" "curate pass open: deterministic subjects committed" "11 (W2): the run the hook started commits its deterministic moves"
assert_eq "$XN_RC" "1" "11 (W2): the outer run is refused"
assert_contains "$(xerr)" "0 of its 1 action(s) are already committed" "11 (W2): ...and HELD with nothing committed"
xsame run
assert_contains "$(xerr)" "another Learning/Curate transaction is still unsettled" "11 (W2): the held claim refuses the next run"
xboth xstd
xboth xput home/records/captain.md "$XCAP"
xboth xput hook.sh '#!/bin/sh
kill -TERM "$PPID"
/bin/sleep 1
'
xboth chmod +x @H/hook.sh
XENV=(AC_TEST_HOOKS=1 AC_CURATE_SNAPSHOT_HOOK=@H/hook.sh)
xsame run
XENV=()
assert_eq "$XN_RC" "143" "11 (SIGNALS): TERM ends the run at once"
[ -d "$(ls -d "$XNH"/home/data/curate-* | head -1)" ] && [ ! -e "$XNH/home/records/captain-archive.md" ] || fail "11: the run dir stays and nothing is applied"

# 12. the records are fleet memory: every verb (the two compatibility
#     mutators with --apply), and `run` with the gate answering continue,
#     revise, ask-captain and 3, on copies of real fleet homes (records/,
#     skills/, state/.curate.meta, config/curate-every, each registered
#     project an empty clone) - the homes XCURATE_HOMES names, one
#     drydock-size among them. Skipped, said so, when it names none.
xreal() {  # xreal <home> - the side home rebuilt from a READ-ONLY copy of a real one
  local n
  xstd
  cp -R "$1/records/." "$H/home/records/"
  [ ! -d "$1/skills" ] || cp -R "$1/skills/." "$H/home/skills/"
  [ ! -f "$1/state/.curate.meta" ] || cp "$1/state/.curate.meta" "$H/home/state/.curate.meta"
  [ ! -f "$1/config/curate-every" ] || cp "$1/config/curate-every" "$H/home/config/curate-every"
  while IFS= read -r n; do git init -q "$H/home/projects/$n"; done < <(LC_ALL=C awk '/^- [A-Za-z0-9._-]+ (\[|- )/ { n = substr($0, 3); sub(/ .*/, "", n); print n }' "$H/home/records/projects.md" 2>/dev/null)
}
if [ -z "${XCURATE_HOMES:-}" ]; then
  printf 'NOTE: section 12 (real fleet homes) skipped - XCURATE_HOMES names none\n'
fi
for xhome in ${XCURATE_HOMES:-}; do
  for xv in learnings 'captain --apply' 'backlog --apply' 'projects --apply' 'skills-audit --apply' skills-consolidate 'run --dry-run'; do
    xboth xreal "$xhome"
    # shellcheck disable=SC2086
    xsame $xv
  done
  for xd in continue revise ask-captain rc3; do
    xboth xreal "$xhome"
    case "$xd" in rc3) XENV=(CURATE_GATE_RC=3 CURATE_GATE_DIAG=diag) ;; *) XENV=("CURATE_GATE_DECISION=$xd") ;; esac
    xsame run
    XENV=()
  done
done

pass
