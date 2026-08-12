#!/usr/bin/env bash
# ac-curate.test.sh - automatic Curate policy and semantic maintenance:
# generation-aware cadence, recoverable deterministic captain/backlog moves,
# hash-gated named supersession/project/skill subjects, complete stale
# predicates, canonical pointer-integrity, unresolved-captain behavior, and
# idempotent resume. Every dangerous path runs against an isolated temp AC_HOME.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
. "$BIN/ac-maintenance-lib.sh"

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

ac_curate_tick
read -r n x < <(ac_curate_due)
assert_eq "$n" "1" "one tick advances runs_since to 1"
ac_curate_tick
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
ac_curate_reset
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "0" "reset zeroes runs_since"
[ -n "$(ac_meta_get "$AC_HOME/state/.curate.meta" last_run)" ] || fail "reset stamps last_run"

# --- the Q8 reversibility floor: shared backup + restore roundtrip -----------

printf '## 2026-07-18 - fam\n- a durable lesson.\n' >"$records/learnings.md"
printf 'captain policy line\n' >"$records/captain.md"
mkdir -p "$AC_HOME/skills/existing"
printf 'an existing skill\n' >"$AC_HOME/skills/existing/SKILL.md"

arc="$(ac_records_backup curate)"
assert_file "$arc" "curate backup archive created"
case "$arc" in
  "$AC_HOME/state/backups/"curate-*.tar.gz) ;;
  *) fail "curate backup lands under state/backups/ with a curate- prefix (got $arc)" ;;
esac
assert_no_file "$AC_HOME/state/backups.tar.gz" "backup is in a subdir, not loose in state/"
tar -tzf "$arc" | grep -q 'records/learnings.md' || fail "records/ is in the backup"
tar -tzf "$arc" | grep -q 'skills/existing/SKILL.md' || fail "the skills store is in the backup"
rm -f "$records/learnings.md" "$AC_HOME/skills/existing/SKILL.md"
tar -xzf "$arc" -C "$AC_HOME"
assert_file "$records/learnings.md" "restore recreates records/"
assert_file "$AC_HOME/skills/existing/SKILL.md" "restore recreates the skills store"

# The existing caller keeps its `learn-` prefix (the factor did not break it).
larc="$(ac_learn_backup)"
case "$larc" in
  "$AC_HOME/state/backups/"learn-*.tar.gz) ;;
  *) fail "ac_learn_backup keeps the learn- prefix (got $larc)" ;;
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
cat >"$records/projects.md" <<'PROJ'
# Projects

- realp [local-only] - a real project (added 2026-02-01)
- deadp [direct-pr] - ASSUMED mode, since gone (added 2026-02-01)
- deadq [local-only] - another absent project (added 2026-02-02)
PROJ
proj_before="$(cat "$records/projects.md")"
out="$("$BIN/ac-curate.sh" projects --apply)"
assert_eq "$(cat "$records/projects.md")" "$proj_before" "projects audit is propose-only (byte-identical even with --apply)"
assert_contains "$out" "deadp" "the dead project is surfaced"
assert_contains "$out" "ASSUMED" "an ASSUMED mode is flagged"
assert_contains "$out" "absent" "the missing project dir is flagged as a proposed drop"

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
assert_file "$AC_HOME/projects/realp/.git/HEAD" \
  "Curate registry archival cannot delete an existing project clone"

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

pass
