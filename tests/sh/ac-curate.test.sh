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

# twin <expr> [<arg>...] - <expr> over src/lib.ts merged with src/lib-learn.ts and src/lib-curate.ts (L) and
# src/maintenance-receipt.ts (M), its arguments A, in one bun process: the code
# the fleet runs where a bash helper retired once src/learn.ts took its last
# caller. A string answer is printed; the status is a number answer, else 1
# for false or null and 0 for anything else.
twin() {
  local expr="$1"; shift
  (cd "$ROOT" && bun --no-env-file -e "const L = { ...await import('./src/lib.ts'), ...await import('./src/lib-learn.ts'), ...await import('./src/lib-curate.ts') }; const M = await import('./src/maintenance-receipt.ts'); const A = process.argv.slice(1); const v = await (async () => ($expr))(); if (typeof v === 'string') process.stdout.write(v); process.exit(typeof v === 'number' ? v : v === false || v === null ? 1 : 0);" "$@")
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

# --- backlog: the ledger lock -------------------------------------------------
# W5: backlog --apply takes records/.backlog.md.lock, the same lock every
# other backlog writer takes (ac-task.sh/ac-domain.sh/deputy.ts) - a live
# holder refuses the move with nothing written, never a silent race -
# bug-shaped-rows.md:516, src/curate.ts's curateBacklog.
rm -f "$records/backlog-archive.md"
{
  printf '## In flight\n\n## Queued\n\n## Done\n'
  for i in $(seq 22); do
    printf -- '- [x] k%02d - receipt - local main (merged 2026-03-%02d)\n' "$i" "$i"
  done
} >"$records/backlog.md"
lockbefore="$(cat "$records/backlog.md")"
mkdir "$records/.backlog.md.lock"; printf '%s\n' "$$" >"$records/.backlog.md.lock/pid"
rc=0
AC_TASK_LOCK_TIMEOUT=1 "$BIN/ac-curate.sh" backlog --apply >"$TMP/bl.out" 2>"$TMP/bl.err" || rc=$?
assert_eq "$rc" "1" "a live lock holder refuses backlog --apply, exit 1"
assert_eq "$(cat "$TMP/bl.err")" "ERROR: records/backlog.md is locked by another writer - nothing written" \
  "the same lock message every other backlog writer gives"
assert_eq "$(cat "$records/backlog.md")" "$lockbefore" "...and nothing is written while the lock is held"
assert_no_file "$records/backlog-archive.md" "...no archive move either"
assert_eq "$(cat "$records/.backlog.md.lock/pid")" "$$" "the holder's own lock is left as it was"
rm -rf "$records/.backlog.md.lock"
"$BIN/ac-curate.sh" backlog --apply >/dev/null
grep -qF -- '- [x] k21 - ' "$records/backlog-archive.md" || fail "the unlocked retry moves the ledger normally"

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

# curateReset (src/lib-curate.ts) returns the same false for a newer cadence
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


# --- the entry end to end, one scenario per row -------------------------------
# One side root ($H): a home at $H/home rebuilt per row (records, skills,
# state, data, project clones made by one git config); AC_HOME=$H/home and
# AC_GATE=the leg's stub gate unless a row names others; AC_TEST_HOOKS only on
# hook rows; cwd $H/cwd, an EMPTY dir, unless a row names another; stdin
# /dev/null; LC_ALL=C unless a row names en_US.UTF-8; TMPDIR $H/tmp; PATH stubs
# - date answering one instant per format, sleep logging each call and
# returning at once - plus a row's own. A row reads the run's exit status,
# stdout and stderr (the side root spelled @H, this checkout ROOT, the run id
# curate-RUN, every 64-hex digest SHA) and what it left under the home.
H="$TMP/xside"
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
XLC=C; XENV=(); XCWD=cwd; XHOME=@H/home; XPATH=""; XGATE="$XSTUBS/gate"; XPLANT=""; XBIN="$BIN"; XN_RC=0
xrun() {  # xrun <args...> - one run of the entry; @H in an argument or an XENV value is the side root; XPLANT=<path under the side> links <path>.<the entry's pid> to <side>/victim first
  local x v path a=() e
  path="$XSTUBS:$PATH"; [ -z "$XPATH" ] || path="${XPATH//@H/$H}"
  e=("LC_ALL=$XLC" "PATH=$path" "TMPDIR=$H/tmp" "STUB_DIR=$H/stub" "CURATE_LEG_BIN=$XBIN")
  [ -z "$XHOME" ] || e+=("AC_HOME=${XHOME//@H/$H}")
  [ -z "$XGATE" ] || e+=("AC_GATE=$XGATE")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$H}"); done
  for x in "$@"; do a+=("${x//@H/$H}"); done
  XN_RC=0
  # The group's stderr takes bash's own `Terminated` notice for a signalled row.
  { (cd "$H/$XCWD" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u CDPATH -u AC_LOCK_STALE_GRACE -u EPOCHSECONDS \
    -u AC_TEST_HOOKS -u AC_CURATE_KEEP -u AC_CURATE_STALE_DAYS -u AC_CURATE_SNAPSHOT_HOOK -u AC_GATE "${e[@]}" \
    /bin/sh -c '[ -z "$0" ] || ln -s "$1" "$0.$$"; shift; exec "$@"' \
    "${XPLANT:+$H/$XPLANT}" "$H/victim" "$XBIN/ac-curate.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/x.raw" 2>"$TMP/x.rawerr"; } 2>/dev/null || XN_RC=$?
  xnorm "$TMP/x.raw" >"$TMP/x.out"; xnorm "$TMP/x.rawerr" >"$TMP/x.err"
}
xnorm() {
  LC_ALL=C sed -E -e "s#$H#@H#g" -e "s#$ROOT#ROOT#g" -e 's/[0-9a-f]{64}/SHA/g' -e 's/curate-[0-9]{10}-[0-9]+/curate-RUN/g' "$1"
}
xout() { cat "$TMP/x.out"; }
xerr() { cat "$TMP/x.err"; }
xsubjects() { xout | LC_ALL=C grep -E '^  (auto-applied semantic subject|ask-captain|revise|settled|a-gate-line)' || true; }   # the semantic pass's verdict lines
xrefuse() {  # xrefuse <stderr> <args...> - exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xrun "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "curate refusal for '$*'"
}
xok() {  # xok <args...> - exit 0, nothing on stderr
  xrun "$@"
  assert_eq "$XN_RC:$(xerr)" "0:" "curate success for '$*'"
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
#    --apply` is the full automatic pass); every verb needs bun.
xstd
xput home/records/captain.md "$XCAP"
xbl 3
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
assert_contains "$(xout)" "PROPOSE-ONLY: 3 block(s) would move" "1: captain ignores --dry-run and proposes"
assert_eq "$(cat "$H/home/records/captain.md")" "${XCAP%$'\n'}" "1: ... writing nothing"
xok backlog --dry-run --dry-run
assert_contains "$(xout)" "ok: nothing to archive" "1: backlog ignores --dry-run"
xok projects --apply
xok skills-audit --dry-run --apply
xok skills-consolidate --dry-run
xok run --dry-run --dry-run --apply
assert_eq "$(xout | tail -n1)" "== curate dry-run complete; no backup, mutation, receipt, or cadence reset ==" "1: run reads --dry-run past --apply"
[ ! -e "$H/home/records/captain-archive.md" ] || fail "1: ... and moves nothing"
xok run --apply
assert_contains "$(xout)" "CURATED: moved 3 block(s) to @H/home/records/captain-archive.md" "1: run --apply is the full automatic pass"
XPATH="$(xwithout bun)"
xrun learnings
XPATH=""
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: required tool not found: bun" "1: every verb needs bun"

# 2. the home: relative (from the caller's cwd), a link to it (paths printed
#    physical), every verb on a bare home, homeless for every verb whose
#    first home read refuses; an AC_HOME cd cannot enter and a relative one
#    under CDPATH.
xseed
XCWD=.; XHOME=home
xok learnings
[ -d "$H/home/records" ] || fail "2: a relative AC_HOME resolves against the caller's cwd"
XCWD=cwd; XHOME=@H/home
xput home/records/captain.md "$XCAP"
ln -s home "$H/homelink"
XHOME=@H/homelink
xok captain
assert_contains "$(xout)" "would move to @H/home/records/captain-archive.md on --apply" "2: a linked home prints physical paths"
XHOME=@H/home
for xv in learnings captain backlog projects skills-audit skills-consolidate 'run --dry-run' run; do
  xseed
  # shellcheck disable=SC2086
  xok $xv
  case "$xv" in
    learnings) xwant="(no learnings.md - nothing to check)" ;;
    captain) xwant="(no captain.md - nothing to curate)" ;;
    backlog) xwant="(no backlog.md - nothing to archive)" ;;
    projects) xwant="(no projects.md - nothing to audit)" ;;
    skills-audit) xwant="(no learned skills - nothing to audit)" ;;
    skills-consolidate) xwant="ok: no prefix cluster with an umbrella - nothing to consolidate" ;;
    'run --dry-run') xwant="== curate dry-run complete; no backup, mutation, receipt, or cadence reset ==" ;;
    run) xwant="== curate pass complete: 0 changed record file(s)" ;;
  esac
  assert_contains "$(xout)" "$xwant" "2: '$xv' on a bare home"
done
XHOME=""
for xv in learnings 'captain --apply' 'backlog --apply' projects 'skills-consolidate --apply'; do
  xseed
  # shellcheck disable=SC2086
  xrefuse "$XNOHOME" $xv
done
XHOME=@H/home
xseed
XHOME=@H/nope
xrun learnings
XHOME=@H/home
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: AC_HOME is not a readable directory: @H/nope" "2: an AC_HOME cd cannot enter names the variable"
mkdir -p "$H/cdp/home"
XCWD=.; XHOME=home; XENV=(CDPATH=@H/cdp)
xrun learnings
XCWD=cwd; XHOME=@H/home; XENV=()
assert_eq "$XN_RC" 0 "2: a relative AC_HOME under CDPATH"
[ -d "$H/home/records" ] && [ ! -e "$H/cdp/home/records" ] || fail "2: a relative AC_HOME resolves against the cwd, never CDPATH"

# 3. learnings: canonical rows that resolve (a skill, a crewmate lesson); a
#    link gone, no link, a `)` inside the link, rung-qualified rows (several
#    on a line); a control byte and an invalid byte under C and en_US.UTF-8.
xstd
xput home/CREWMATE-learned.md 'lessons'
mkdir -p "$H/home/skills/live"
xput home/skills/live/SKILL.md 'x'
xput home/records/learnings.md '# Learning Ledger

- [distilled -> lessononly] sources=2 updated=2026-08-05 ([lesson](../CREWMATE-learned.md))
- [distilled -> live] sources=2 updated=2026-08-05 ([skill](../skills/live/SKILL.md))
'
xadd home/records/learnings.md '- [distilled -> gone] sources=1 updated=2026-08-05 ([skill](../skills/gone/SKILL.md))
- [distilled -> linkless] sources=1 updated=2026-08-05
- [distilled -> paren] x ([s](a)b.md)) and ](c.md)
- [distilled -> UPPER] not canonical ([s](x.md))
  - [distilled -> indented] not canonical either
- 2026 [distilled -> one @fleet] and [distilled -> two @container] on one line, [distilled -> three @other]
'
XLBROKEN="  BROKEN: [distilled -> gone] - distilled body vanished (link ../skills/gone/SKILL.md, missing @H/home/records/../skills/gone/SKILL.md)
  BROKEN: [distilled -> linkless] - pointer carries no link to its distilled body
  BROKEN: [distilled -> paren] - distilled body vanished (link a, missing @H/home/records/a)"
XLCOMPAT="  COMPATIBILITY DEFECT: [distilled -> one @fleet] - rung-qualified pointer remains; the migrate command is retired, so rewrite the pointer to the canonical fleet-local form by hand
  COMPATIBILITY DEFECT: [distilled -> two @container] - rung-qualified pointer remains; the migrate command is retired, so rewrite the pointer to the canonical fleet-local form by hand"
xok learnings
assert_eq "$(xout)" "== learnings: pointer-integrity check (propose-only; CURATE never compacts) ==
$XLBROKEN
$XLCOMPAT
  3 broken canonical pointer(s), 2 migration compatibility defect(s); propose-only" "3: the canonical rows that resolve pass, the rest are named"
xadd home/records/learnings.md "$(printf -- '- [distilled -> nul] has a \001 control byte ([s](n.md))\n- [distilled -> caf] caf\351 ([s](c.md))')"
for xl in C en_US.UTF-8; do
  XLC=$xl
  xok learnings
  assert_eq "$(xout)" "== learnings: pointer-integrity check (propose-only; CURATE never compacts) ==
$XLBROKEN
  BROKEN: [distilled -> nul] - distilled body vanished (link n.md, missing @H/home/records/n.md)
  BROKEN: [distilled -> caf] - distilled body vanished (link c.md, missing @H/home/records/c.md)
$XLCOMPAT
  5 broken canonical pointer(s), 2 migration compatibility defect(s); propose-only" "3: a control byte and an invalid byte, read as bytes ($xl)"
done
XLC=C

# 4. captain: an apply with only live notes, every class (STANDING+COMPLETED,
#    partial SUPERSEDED, continuation lines) applied twice, an unterminated
#    last line moved, an invalid byte under C and en_US.UTF-8, TMPDIR
#    unusable, a link planted at the temp and a 0600 record.
xstd
xput home/records/captain.md '# Captain notes

- 2026-01-01: a live rule.
'
xok captain --apply
assert_contains "$(xout)" "ok: no retirement markers found - nothing to consolidate or expire" "4: only live notes"
[ ! -e "$H/home/records/captain-archive.md" ] || fail "4: ... and no archive"
xput home/records/captain.md "$XCAP"
xok captain --apply
assert_contains "$(xout)" "CURATED: moved 3 block(s) to @H/home/records/captain-archive.md" "4: the apply"
xok captain --apply
assert_contains "$(xout)" "--apply: nothing to move (only informational supersede-chain notes)" "4: a second apply moves nothing"
assert_eq "$(grep -cFx 'Archived rulings: [captain-archive.md](captain-archive.md)' "$H/home/records/captain.md")" "1" "4: ... and keeps the one archive link"
xput home/records/captain.md "$(printf -- '- 2026-03-01: a kept rule\n- 2026-03-02: last order. [COMPLETED]')"
xok captain --apply
assert_contains "$(xout)" "CURATED: moved 1 block(s)" "4: an unterminated last block moves"
assert_contains "$(cat "$H/home/records/captain-archive.md")" "- 2026-03-02: last order. [COMPLETED]" "4: ... into the archive"
assert_contains "$(cat "$H/home/records/captain.md")" "- 2026-03-01: a kept rule" "4: ... and the rule before it stays"
case "$(cat "$H/home/records/captain.md")" in *"last order"*) fail "4: ... and leaves captain.md" ;; esac
xput home/records/captain.md "$(printf -- '- 2026-03-06: caf\351 rule. [COMPLETED]\n- 2026-03-07: kept\n')"
xok captain
assert_contains "$(xout)" "PROPOSE-ONLY: 1 block(s) would move" "4: a block holding an invalid byte, under C"
XLC=en_US.UTF-8
xok captain --apply
XLC=C
assert_contains "$(xout)" "CURATED: moved 1 block(s)" "4: ... and under en_US.UTF-8, read as bytes"
xstd
xput home/records/captain.md "$XCAP"
XENV=(TMPDIR=@H/nope)
xrun captain --apply
XENV=()
assert_eq "$XN_RC" "1" "4: an unusable TMPDIR ends the apply"
assert_eq "$(cat "$H/home/records/captain.md")" "${XCAP%$'\n'}" "4: ... before captain.md is rewritten"
xput home/records/captain.md "$XCAP"
printf victim >"$H/victim"
XPLANT=home/records/captain.md.tmp
xrun captain --apply
XPLANT=""
assert_eq "$XN_RC" "0" "4: a link planted at the temp name does not stop the apply"
assert_eq "$(cat "$H/victim")" "victim" "4: nothing is written through a planted temp"
[ -f "$H/home/records/captain.md" ] && [ ! -L "$H/home/records/captain.md" ] || fail "4: captain.md stays a regular file"
assert_contains "$(cat "$H/home/records/captain.md")" "always do X" "4: ... holding the survivors"
xstd
xput home/records/captain.md "$XCAP"
chmod 600 "$H/home/records/captain.md"
xok captain --apply
assert_eq "$(stat -f %Lp "$H/home/records/captain.md")" "600" "4: the rewrite keeps the record's mode"

# 5. backlog: keep 0 and 1; blocked-by and epic protection (an absent epic
#    row, an archived one), `## Notes`.
for xk in 0 1; do
  xstd; xbl 12
  XENV=("AC_CURATE_KEEP=$xk")
  xok backlog --apply
  assert_eq "$(grep -c '^- \[x\]' "$H/home/records/backlog.md"):$(grep -c '^- \[x\]' "$H/home/records/backlog-archive.md")" "$xk:$((12 - xk))" "5: AC_CURATE_KEEP=$xk keeps the $xk most recent"
done
grep -qx -- '- \[x\] d01 - receipt - local main (merged 2026-02-02)' "$H/home/records/backlog.md" || fail "5: ... the newest first"
XENV=()
xstd
xput home/records/backlog.md '## In flight
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
- [x] oldepic [EPIC] - archived itself (merged 2026-02-02)
- [x] dfree - unreferenced old (merged 2026-02-01)
'
XENV=(AC_CURATE_KEEP=1)
XMOVES="    move | - [x] s2 - a story of an archived epic; epic:oldepic (merged 2026-02-06)
    move | - [x] oldepic [EPIC] - archived itself (merged 2026-02-02)
    move | - [x] dfree - unreferenced old (merged 2026-02-01)"
xbefore="$(cat "$H/home/records/backlog.md")"
xok backlog
assert_contains "$(xout)" "$XMOVES
  PROPOSE-ONLY: 3 line(s) would move" "5: a live blocker, a story of a live or absent epic and a row outside the Done section stay"
assert_eq "$(cat "$H/home/records/backlog.md")" "$xbefore" "5: ... propose writes nothing"
xok backlog --apply
XENV=()
assert_contains "$(xout)" "$XMOVES" "5: the apply moves the same three"
for xr in dnew dblock s1 s3 noted; do grep -q -- "- \[x\] $xr " "$H/home/records/backlog.md" || fail "5: $xr stays"; done
for xr in s2 oldepic dfree; do
  ! grep -q -- "- \[x\] $xr " "$H/home/records/backlog.md" && grep -q -- "- \[x\] $xr " "$H/home/records/backlog-archive.md" || fail "5: $xr moves"
done

# 6. projects: a dangling link, a plain dir, a repo, a nested name, no
#    bracket, a prose bullet, a TAB inside a name, an invalid byte under C and
#    en_US.UTF-8.
xstd
xgit home/projects/realp
mkdir -p "$H/home/projects/plain" "$H/home/projects/a/b"
ln -s "$H/nowhere" "$H/home/projects/dangling"
xput home/records/projects.md "$(printf '# Projects\n\n- realp [local-only] - a real project (added 2026-02-01)\n- deadp [direct-pr] - gone (added 2026-02-01)\n- plain - a plain dir (added 2026-02-02)\n- dangling [x] - a dangling link\n- a/b - nested\n- a prose bullet is not a registry line\n- cafe [x] - caf\351 gone\n')"
xbefore="$(cat "$H/home/records/projects.md")"
for xl in C en_US.UTF-8; do
  XLC=$xl
  xok projects --apply
  assert_eq "$(xout)" "== projects: correctness-audit (propose-only; deletion stays a captain call) ==
  FLAG deadp: registered but projects/deadp is absent - dead project? (propose drop; deletion is a captain call)
  FLAG plain: projects/plain is not a git repo
  FLAG dangling: registered but projects/dangling is absent - dead project? (propose drop; deletion is a captain call)
  FLAG a/b: projects/a/b is not a git repo
  FLAG cafe: registered but projects/cafe is absent - dead project? (propose drop; deletion is a captain call)
  5 mismatch(es) proposed with evidence - NO mutation (projects.md audit is propose-only)" "6: the audit ($xl)"
done
XLC=C
assert_eq "$(cat "$H/home/records/projects.md")" "$xbefore" "6: ... writes nothing, even with --apply"

# 7. skills-audit: overlap (stop words, quoted descriptions, an indented key,
#    a CRLF frontmatter, the archive and dirs with no SKILL.md left out);
#    the stale predicates - landed quoted and unquoted, a SKILL.md mtime,
#    last_seeded, the evidence mtime, a pending candidate and a completed
#    journal, an active worktree link - and AC_CURATE_STALE_DAYS 0.
xstd
xskill ov-one 'verify crewmate briefing carefully, before anything'
xskill ov-two '"crewmate briefing verify twice before"'
xskill ov-three "'briefing crewmate verify anything again'"
xskill ov-solo 'rebase worktree landing dance'
xskill ov-pair-a 'migrate ledgers with care'
xskill ov-pair-b 'ledgers migrate nothing else'
mkdir -p "$H/home/skills/skills-archive/old" "$H/home/skills/nofile" "$H/home/skills/.hidden"
xput home/skills/skills-archive/old/SKILL.md '---
description: briefing crewmate verify
---'
xput home/skills/crlf/SKILL.md "$(printf -- '---\r\ndescription: crewmate briefing verify\r\n---\r\n')"
xput home/skills/indent/SKILL.md '---
   description:    crewmate	briefing in an indented key
---'
xok skills-audit
assert_contains "$(xout)" "  OVERLAP: ov-one ~ ov-three - share 4 territory word(s): verify, crewmate, briefing, anything (review for possible consolidation)
  OVERLAP: ov-one ~ ov-two - share 3 territory word(s): verify, crewmate, briefing (review for possible consolidation)
  OVERLAP: ov-pair-a ~ ov-pair-b - share 2 territory word(s): migrate, ledgers (review for possible consolidation)
  OVERLAP: ov-three ~ ov-two - share 3 territory word(s): briefing, crewmate, verify (review for possible consolidation)" "7: quoted descriptions and stop words"
case "$(xout)" in *"ov-solo"*|*" old"*) fail "7: a disjoint skill and the archive never overlap" ;; esac
assert_contains "$(xout)" "audited 8 learned skill(s)" "7: the archive and a dir with no SKILL.md are no skills"
xstd
for xs in st-old st-seeded st-evidence st-pending st-done st-active st-fresh st-bare; do xskill "$xs" "solitary $xs" '"1577836800"'; done
xskill st-unquoted 'solitary unquoted' 1577836800
xskill st-nolanded 'solitary nolanded'
for xs in "$H"/home/skills/st-*; do touch -t 202001010000 "$xs/SKILL.md"; done
touch -t 202512300000 "$H/home/skills/st-fresh/SKILL.md"
xput home/skills/st-seeded/.usage.meta 'last_seeded=1767225000
'
mkdir -p "$H/home/records/learnings-archive"
xput home/records/learnings-archive/st-evidence.md '# recent'
touch -t 202512310000 "$H/home/records/learnings-archive/st-evidence.md"
xput home/data/learning-a/candidate-st-pending.md 'kind: patch
name:   st-pending
'
xput home/data/learning-b/candidates/st-done.md 'name: st-done
'
xput home/state/.maintenance-transactions/learning-b-st-done/journal 'status=complete
'
mkdir -p "$H/wt/.claude/skills"
ln -s "$H/home/skills/st-active" "$H/wt/.claude/skills/st-active"
xput home/state/active.meta 'worktree=@H/wt
'
xstale() { xout | LC_ALL=C sed -n 's/^  STALE: \([^ ]*\) .*/\1/p' | tr '\n' ' '; }
xok skills-audit
assert_eq "$(xstale)" "st-bare st-done st-old st-unquoted " "7: stale - landed quoted or not; a completed candidate is no pending one"
XENV=(AC_CURATE_STALE_DAYS=0)
xok skills-audit
XENV=()
assert_eq "$(xstale)" "st-bare st-done st-evidence st-fresh st-old st-seeded st-unquoted " "7: AC_CURATE_STALE_DAYS=0 - only a pending candidate, an active worktree and no landed hold"

# 8. skills-consolidate: no cluster with --apply; umbrella-less groups (one
#    with an empty prefix); byte order under en_US.UTF-8.
xstd
xskill solo 'alone'
xok skills-consolidate --apply
assert_contains "$(xout)" "ok: no prefix cluster with an umbrella - nothing to consolidate" "8: --apply with no cluster is a no-op, exit 0"
xskill ship 'umbrella'
xskill ship-rebase 'rebase step'
xskill ship-attest 'attest step'
xskill bar-x 'no umbrella'
xskill bar-y 'no umbrella either'
xok skills-consolidate
assert_eq "$(xout)" "== skills-consolidate: prefix-cluster umbrella merge, MOVE-to-archive (move-only, never delete) ==
  CLUSTER ship: sibling ship-attest -> archive (umbrella ship stays)
  CLUSTER ship: sibling ship-rebase -> archive (umbrella ship stays)
  cluster bar-*: 2 sibling(s) but NO umbrella skill named \"bar\" - propose-only, not moved (create the umbrella first)
  PROPOSE-ONLY: 2 sibling(s) require automatic Curate maintenance-gate review before a recoverable move to @H/home/skills/skills-archive; 1 umbrella-less cluster(s) never move" "8: the clusters"
xskill x 'umbrella x'
xskill x-_c 'underscore'
xskill x-A 'capital'
XLC=en_US.UTF-8
xok skills-consolidate
XLC=C
assert_contains "$(xout)" "  CLUSTER x: sibling x-A -> archive (umbrella x stays)
  CLUSTER x: sibling x-_c -> archive (umbrella x stays)" "8: siblings in byte order under any locale"

# 9. run, deterministic: --dry-run and runs with nothing to do; a home path
#    holding \ & ' * [ ]; a symlinked record; another unsettled transaction;
#    a newer generation (the reset's WARN).
xstd
mkdir -p "$H/home/w\\&'*[]x"
XHOME="@H/home/w\\&'*[]x"
xput "home/w\\&'*[]x/records/captain.md" "$XCAP"
xok run
assert_contains "$(xout)" "CURATED: moved 3 block(s) to @H/home/w\\&'*[]x/records/captain-archive.md" "9: a home path holding \\ & ' * [ ] is named as it is"
assert_file "$H/home/w\\&'*[]x/records/captain-archive.md" "9: ... where the archive lands"
XHOME=@H/home
xstd
xput home/records/real.md "$XCAP"
ln -s real.md "$H/home/records/captain.md"
xrun run
assert_eq "$XN_RC:$(xerr)" "1:ERROR: Curate input manifest refused a non-file or symlink" "9: a symlinked record refuses the input manifest"
xstd
xput home/state/.maintenance-transactions/learning-x-y/journal 'status=applying
'
xrun run
assert_eq "$XN_RC:$(xerr | tail -n1)" "1:ERROR: Curate maintenance transaction could not apply or resume safely" "9: another unsettled transaction refuses the run"
assert_contains "$(xerr)" "another Learning/Curate transaction is still unsettled" "9: ... and says so"
xstd
xput home/state/.curate.meta 'runs_since=4
generation=2
'
xput hook.sh '#!/bin/sh
printf "runs_since=9\ngeneration=7\n" >"$1/../state/.curate.meta"
'
chmod +x "$H/hook.sh"
XENV=(AC_TEST_HOOKS=1 AC_CURATE_SNAPSHOT_HOOK=@H/hook.sh)
xrun run
XENV=()
assert_eq "$XN_RC:$(xerr)" "0:WARN: Curate committed, but did not reset its cadence: either a newer cadence generation exists and its late Learning ticks were preserved, or the cadence lock was not acquired (warned just above)" "9: a newer generation is the reset's WARN"
assert_contains "$(cat "$H/home/state/.curate.meta")" "runs_since=9" "9: ... and keeps its late ticks"

# 10. run, semantic: captain targets by below, above and date; ambiguous,
#     partial and duplicated first lines; absent projects incl. an invalid
#     byte; skill moves with nested files and .usage.meta, a CR-ended pointer
#     line, a missing pointer or evidence, an active worktree link, a symlink
#     inside; the gate answering continue, revise, ask-captain, 3 with a
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
- 2026-03-05: an unrelated live policy.
- 2026-03-01: the dated rule.
- 2026-02-02: STANDING lonely SUPERSEDES nothing named.
- 2026-02-01: STANDING partial SUPERSEDES the clause below.
- 2026-01-31: earlier policy; launch clause superseded, the rest holds.
'
  xput home/records/projects.md "$(printf '# Projects\n\n- realp [local-only] - a real project\n- deadp [direct-pr] - gone (added 2026-02-01)\n- cafep [x] - caf\351 gone\n')"
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
xsemantic
XENV=(CURATE_GATE_DECISION=continue)
xok run
assert_eq "$(xsubjects)" "  auto-applied semantic subject: captain-supersedes-1
  auto-applied semantic subject: captain-supersedes-4
  ask-captain: captain-supersedes-5 (no unique safe plan; no mutation)
  ask-captain: captain-supersedes-8 (no unique safe plan; no mutation)
  ask-captain: captain-supersedes-9 (no unique safe plan; no mutation)
  auto-applied semantic subject: project-deadp
  auto-applied semantic subject: project-cafep
  ask-captain: skill-ship-attest (no unique safe plan; no mutation)
  ask-captain: skill-ship-gone (no unique safe plan; no mutation)
  auto-applied semantic subject: skill-ship-rebase" "10: continue - targets by below and above applied; a date naming an already-targeted rule, nothing named, a partial clause, a missing pointer and missing evidence ask"
assert_eq "$(xout | tail -n1)" "== curate pass open: deterministic subjects committed; unresolved semantic/captain subject(s) preserve cadence=4/5 ==" "10: ... and the pass stays open"
assert_contains "$(cat "$H/home/records/captain-archive.md")" "- 2026-04-01: old named policy." "10: ... the named rule archived"
case "$(cat "$H/home/records/projects.md")" in *deadp*|*cafep*) fail "10: ... the absent projects leave the registry" ;; esac
assert_file "$H/home/skills/skills-archive/ship-rebase/refs/deep/notes.md" "10: ... the sibling moved with its nested files"
assert_contains "$(cat "$H/home/skills/skills-archive/ship-rebase/.usage.meta")" "seeded_count=3" "10: ... and its .usage.meta"
xok run
assert_eq "$(xsubjects | grep -c 'auto-applied' || true):$(xsubjects | sed -n 1,2p)" "0:  settled: captain-supersedes-1 (named target already archived under this live ruling)
  settled: captain-supersedes-2 (named target already archived under this live ruling)" "10: the next run reads the archive as settled"
for xd in revise ask-captain; do
  xsemantic
  xcap="$(cat "$H/home/records/captain.md")"
  XENV=("CURATE_GATE_DECISION=$xd")
  xok run
  case "$xd" in
    revise) xwant="revise: skill-ship-rebase (live records preserved; subject settled)" ;;
    *) xwant="ask-captain: skill-ship-rebase (gate could not prove the move; no mutation)" ;;
  esac
  assert_contains "$(xsubjects)" "  $xwant" "10: the gate's $xd"
  assert_eq "$(xsubjects | grep -c 'auto-applied' || true)" "0" "10: $xd applies nothing"
  assert_eq "$(cat "$H/home/records/captain.md")" "$xcap" "10: $xd leaves captain.md"
  assert_file "$H/home/skills/ship-rebase/SKILL.md" "10: $xd leaves the sibling live"
done
XENV=()
xsemantic
xput home/records/learnings.md "- [distilled -> ship-rebase] sources=3 updated=2026-07-20 ([skill](../skills/ship-rebase/SKILL.md); [evidence](learnings-archive/ship-rebase.md))"$'\r\n'
xok run
assert_contains "$(xout)" "auto-applied semantic subject: skill-ship-rebase" "10: a CR-ended pointer line still yields its sources= and updated="
xsemantic
XENV=(CURATE_GATE_RC=3 'CURATE_GATE_DIAG=maintenance-gate[stub]: engine did not produce a valid decision')
xok run
assert_contains "$(xsubjects)" "  ask-captain: skill-ship-rebase (gate unavailable; no mutation)" "10: a gate exiting 3"
for xr in 4 1; do
  xsemantic
  XENV=("CURATE_GATE_RC=$xr")
  xok run
  assert_contains "$(xsubjects)" "  ask-captain: skill-ship-rebase (gate unavailable; no mutation)" "10: a gate exiting $xr"
  assert_file "$H/home/skills/ship-rebase/SKILL.md" "10: ... moves nothing"
done
xsemantic
XENV=(CURATE_GATE_BAD=1)
xok run
assert_contains "$(xsubjects)" "  ask-captain: skill-ship-rebase (invalid gate receipt; no mutation)" "10: a receipt bound to no plan"
assert_eq "$(xsubjects | grep -c 'auto-applied' || true)" "0" "10: ... applies nothing"
xsemantic
XENV=(CURATE_GATE_SAY=a-gate-line CURATE_GATE_TOUCH=skills/ship/SKILL.md)
xok run
assert_contains "$(xsubjects)" "  a-gate-line
  auto-applied semantic subject: captain-supersedes-1" "10: the gate's output is printed indented"
assert_contains "$(xsubjects)" "  ask-captain: skill-ship-rebase (post-gate input drift; no mutation)" "10: a manifest input moved under the decision"
assert_file "$H/home/skills/ship-rebase/SKILL.md" "10: ... moves nothing"
xsemantic
XENV=(CURATE_GATE_TOUCH=skills/skills-archive/ship-rebase/refs/deep/notes.md CURATE_GATE_TOUCH_SUBJECT=skill-ship-rebase)
xrun run
assert_contains "$(xerr)" "WARN: continue receipt for Curate subject skill-ship-rebase became stale or could not resume" "10: a target moved under the decision refuses its apply"
XENV=()
xsemantic
mkdir -p "$H/home/data/curate"
chmod 555 "$H/home/data/curate"
xrun run
chmod 755 "$H/home/data/curate"
assert_contains "$(xerr)" "WARN: captain escalation for Curate subject" "10: a room that cannot be written is the run's WARN"
xsemantic
xput home/records/curate-acknowledged.md "$(printf -- '- captain-supersedes-9 material=%s ruling: never\n- x material=y ruling:\n' "$(printf '' | shasum -a 256 | cut -d' ' -f1)")"
xok run
case "$(xout)" in *settled:*) fail "10: an acknowledgement of other or empty material settles nothing" ;; esac
assert_contains "$(xsubjects)" "  ask-captain: captain-supersedes-9 (no unique safe plan; no mutation)" "10: ... the subject still asks"
xstd
xput home/records/captain.md '- 2026-06-05: STANDING duplicated SUPERSEDES the clause below.
- 2026-06-05: STANDING duplicated SUPERSEDES the clause below.
- 2026-06-04: earlier policy.
'
xok run
assert_eq "$(xsubjects)" "  ask-captain: captain-supersedes-1 (no unique safe plan; no mutation)
  ask-captain: captain-supersedes-2 (no unique safe plan; no mutation)" "10: duplicated first lines are ambiguous"
xstd
xskill run 'umbrella'
xskill run-a 'a sibling with a link inside'
ln -s ../run/SKILL.md "$H/home/skills/run-a/linked.md"
xskill run-c 'a sibling an active worktree seeds'
mkdir -p "$H/wt/.claude/skills"
ln -s "$H/home/skills/run-c" "$H/wt/.claude/skills/run-c"
xput home/state/active.meta 'worktree=@H/wt
'
mkdir -p "$H/home/records/learnings-archive"
for xs in run-a run-c; do xput "home/records/learnings-archive/$xs.md" '# evidence'; done
xput home/records/learnings.md '- [distilled -> run-a] sources=1 updated=2026-07-20 ([skill](../skills/run-a/SKILL.md))
- [distilled -> run-c] sources=1 updated=2026-07-20 ([skill](../skills/run-c/SKILL.md))
'
xok run
assert_eq "$(xsubjects)" "  ask-captain: skill-run-a (no unique safe plan; no mutation)
  ask-captain: skill-run-c (no unique safe plan; no mutation)" "10: a symlink inside and an active worktree link each hold the move"
assert_file "$H/home/skills/run-a/SKILL.md" "10: ... run-a stays live"
assert_file "$H/home/skills/run-c/SKILL.md" "10: ... run-c stays live"
xsemantic
mkdir -p "$TMP/xdef/bin"
cp "$BIN"/*.sh "$TMP/xdef/bin/"
ln -sfn "$ROOT/src" "$TMP/xdef/src"; ln -sfn "$ROOT/dashboard" "$TMP/xdef/dashboard"; cp "$XSTUBS/gate" "$TMP/xdef/bin/ac-gate.sh"
XBIN="$TMP/xdef/bin"; XGATE=""
xok run
assert_contains "$(xsubjects)" "  auto-applied semantic subject: skill-ship-rebase" "10: with no AC_GATE the gate beside the entry decides"
assert_file "$H/stub/gate.log" "10: ... and it ran"
XBIN="$BIN"; XGATE="$XSTUBS/gate"

# 11. a write landing inside a compatibility apply's backup window (a PATH
#     tar that appends, then runs the real one) is kept; TERM during the
#     snapshot hook ends the run at once, 143, the run dir left, nothing
#     applied.
xstd
xput tarstub/tar '#!/bin/sh
printf -- "- 2026-04-01: a rule added during the backup\n" >>"$AC_HOME/records/captain.md"
printf -- "- [x] late - a row landed during the backup (2026-04-01)\n" >>"$AC_HOME/records/backlog.md"
exec /usr/bin/tar "$@"
'
chmod +x "$H/tarstub/tar"
xput home/records/captain.md '- 2026-03-01: a kept rule
- 2026-03-02: last order. [COMPLETED]
'
xput home/records/backlog.md '## In flight

## Queued

## Done
- [x] d1 - receipt (2026-01-01)
- [x] d2 - receipt (2026-01-02)
'
XPATH="@H/tarstub:$XSTUBS:$PATH" xok captain --apply
assert_contains "$(cat "$H/home/records/captain.md")" "a rule added during the backup" "11: a captain rule added during the backup survives the apply"
XENV=(AC_CURATE_KEEP=0)
XPATH="@H/tarstub:$XSTUBS:$PATH" xok backlog --apply
XENV=()
assert_contains "$(cat "$H/home/records/backlog.md")" "- [x] late - a row landed during the backup" "11: a Done row landed during the backup stays in the backlog"
xstd
xput home/records/captain.md "$XCAP"
xput hook.sh '#!/bin/sh
kill -TERM "$PPID"
/bin/sleep 1
'
chmod +x "$H/hook.sh"
XENV=(AC_TEST_HOOKS=1 AC_CURATE_SNAPSHOT_HOOK=@H/hook.sh)
xrun run
XENV=()
assert_eq "$XN_RC" "143" "11: TERM ends the run at once"
[ -d "$(ls -d "$H"/home/data/curate-* | head -1)" ] && [ ! -e "$H/home/records/captain-archive.md" ] || fail "11: the run dir stays and nothing is applied"

pass
