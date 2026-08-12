#!/usr/bin/env bash
# ac-learn-loop.test.sh - fleet-local Learning contracts: compatibility land,
# canonical compaction/archive, promote refusal, complete-run gating, pane
# cleanup, generation-aware cadence, and legacy migration boundaries. Every
# dangerous path runs against the isolated temp $AC_HOME, never the live home.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
. "$BIN/ac-maintenance-lib.sh"

make_home

# --- ac_learn_backup: the Q8 reversibility floor ----------------------------

printf '## 2026-07-18 - fam (chief)\n- a durable lesson.\n' >"$AC_HOME/records/learnings.md"
printf 'captain policy line\n' >"$AC_HOME/records/captain.md"
mkdir -p "$AC_HOME/skills/existing"
printf 'an existing skill\n' >"$AC_HOME/skills/existing/SKILL.md"

arc="$(ac_learn_backup)"
assert_file "$arc" "backup archive created"
case "$arc" in
  "$AC_HOME/state/backups/"learn-*.tar.gz) ;;
  *) fail "backup lands under state/backups/ (got $arc)" ;;
esac
# Never loose in state/ where the state/*.meta glob would read it as a phantom crewmate.
assert_no_file "$AC_HOME/state/backups.tar.gz" "backup is in a subdir, not loose in state/"
tar -tzf "$arc" | grep -q 'records/learnings.md' || fail "records/ is in the backup"
tar -tzf "$arc" | grep -q 'skills/existing/SKILL.md' || fail "the skills store is in the backup"
# Restoring the archive recreates the files.
rm -f "$AC_HOME/records/learnings.md" "$AC_HOME/skills/existing/SKILL.md"
tar -xzf "$arc" -C "$AC_HOME"
assert_file "$AC_HOME/records/learnings.md" "restore recreates records/"
assert_file "$AC_HOME/skills/existing/SKILL.md" "restore recreates the skills store"

# --- land (skill): write origin:learned + compact the source bullet ----------

printf '## 2026-07-18 - fam (chief)\n- LESSON: always foo before bar, every time.\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: skill\n'
  printf 'name: foo-before-bar\n'
  printf 'description: Do foo before bar.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-18\tfoo-before-bar\t- LESSON: always foo before bar, every time.\n'
  printf '===skill===\n'
  printf '# foo-before-bar\n\nAlways foo before bar.\n'
} >"$TMP/cand-skill.md"

# Legacy-keyed seed ON PURPOSE: a live fleet mid-cadence lands its first
# learning run with a pre-rename .learn.meta - land's reset must migrate it.
printf 'stows=5\n' >"$AC_HOME/state/.learn.meta"
"$BIN/ac-learn.sh" land "$TMP/cand-skill.md"

skill="$AC_HOME/skills/foo-before-bar/SKILL.md"
assert_file "$skill" "skill SKILL.md written to the fleet store"
# Fix C: origin: learned is INDENTED under metadata: (agentskills-clean +
# hermes-style metadata.* convention), no longer a bare top-level key.
grep -qxF '  origin: learned' "$skill" || fail "SKILL.md carries '  origin: learned' indented under metadata"
if grep -qxF 'origin: learned' "$skill"; then fail "origin moved under metadata: no bare top-level key remains"; fi
# The indentation-agnostic seeding filter (ac-lib.sh ac_seed_crew_skills) matches it.
grep -qE '^[[:space:]]*origin:[[:space:]]*learned[[:space:]]*$' "$skill" || fail "origin line matches the indentation-agnostic seeding filter"
# The landed epoch is emitted as a QUOTED STRING: agentskills metadata values
# MUST be strings, so a bare integer (landed: 1784426868) is spec-invalid.
grep -qE '^  landed: "[0-9]+"$' "$skill" || fail "SKILL.md carries a QUOTED string landed stamp"
if grep -qE '^  landed: [0-9]' "$skill"; then fail "landed epoch must be quoted, never a bare integer"; fi
grep -qF 'Always foo before bar.' "$skill" || fail "SKILL.md carries the candidate body"
# The active ledger carries one fleet-local canonical pointer; the source is
# preserved verbatim in the per-skill evidence archive before it is removed.
grep -qF -- '- [distilled -> foo-before-bar] sources=1 updated=2026-07-18 ([skill](../skills/foo-before-bar/SKILL.md); [evidence](learnings-archive/foo-before-bar.md))' \
  "$AC_HOME/records/learnings.md" || fail "source compacted to the canonical fleet-local pointer"
assert_eq "$(grep -c '\[distilled -> foo-before-bar\]' "$AC_HOME/records/learnings.md")" "1" \
  "the active ledger carries one pointer per learned skill"
if grep -qF -- '- LESSON: always foo before bar, every time.' "$AC_HOME/records/learnings.md"; then
  fail "the verbatim source bullet is gone after compaction"
fi
evidence="$AC_HOME/records/learnings-archive/foo-before-bar.md"
assert_file "$evidence" "per-skill evidence archive written"
grep -qF -- '- LESSON: always foo before bar, every time.' "$evidence" \
  || fail "the consumed source survives verbatim in the evidence archive"
grep -qF 'source-count: 1' "$evidence" || fail "archive block records its source count"
find "$AC_HOME/state/.maintenance-transactions" -name journal -exec grep -q '^status=complete$' {} \; \
  || fail "manual compatibility land uses a completed maintenance transaction"
# Counter reset + last_run stamped (the reset Slice 2 deferred to here).
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "0" "counter reset to debriefs=0 after land (legacy key migrated)"
[ -n "$(ac_meta_get "$AC_HOME/state/.learn.meta" last_run)" ] || fail "last_run stamped after land"

# --- land: recognize a pointer by POSITION, not substring --------------------
# A prose bullet that merely QUOTES the `[distilled -> ...]` marker inside
# backticks must survive into Pending verbatim and mint no bogus pointer, while
# a real canonical pointer line still aggregates. The property moved here from
# the retired migrate command's test (audit-f7): land's learn_ledger_stage is
# now learn_ledger_split's one consumer.
printf 'debriefs=1\n' >"$AC_HOME/state/.learn.meta"
cat >"$AC_HOME/records/learnings.md" <<'EOF'
# Fleet learnings

## 2026-07-20 - fam (chief)

- [distilled -> canon-skill] sources=1 updated=2026-07-20 ([skill](../skills/canon-skill/SKILL.md); [evidence](learnings-archive/canon-skill.md))
- a real source bullet for the split case.
- MEASURE THE TARGET BEFORE BRIEFING IT - the order quoted `[distilled -> ...]` as an EXAMPLE, not a real pointer.
EOF
{
  printf 'kind: skill\n'
  printf 'name: split-skill\n'
  printf 'description: pointer-by-position case.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-20\tfam\t- a real source bullet for the split case.\n'
  printf '===skill===\n# split-skill\n\nbody.\n'
} >"$TMP/cand-split.md"
"$BIN/ac-learn.sh" land "$TMP/cand-split.md"
split_ledger="$(cat "$AC_HOME/records/learnings.md")"
assert_contains "$split_ledger" 'quoted `[distilled -> ...]` as an EXAMPLE' \
  "a prose bullet merely quoting the marker survives into Pending verbatim"
if grep -qE '^- \[distilled -> \.\.\.\]' <<<"$split_ledger"; then
  fail "a prose mention of the marker must never mint a bogus '...' pointer"
fi
assert_contains "$split_ledger" '[distilled -> canon-skill] sources=1' "the real canonical pointer survives the land"
assert_contains "$split_ledger" '[distilled -> split-skill] sources=1' "the landed skill mints its own canonical pointer"

# --- land (rule): append verbatim to captain.md ------------------------------

printf 'existing line 1\nexisting line 2\n' >"$AC_HOME/records/captain.md"
{
  printf 'kind: rule\n'
  printf 'approved: 1700000000\n'
  printf '===rule===\n'
  printf -- '- 2026-07-18: STANDING (captain): always do X, verbatim and unparaphrased.\n'
} >"$TMP/cand-rule.md"

printf 'debriefs=3\n' >"$AC_HOME/state/.learn.meta"
"$BIN/ac-learn.sh" land "$TMP/cand-rule.md"

expected="$(printf 'existing line 1\nexisting line 2\n\n- 2026-07-18: STANDING (captain): always do X, verbatim and unparaphrased.\n')"
assert_eq "$(cat "$AC_HOME/records/captain.md")" "$expected" "rule appended byte-for-byte; other lines untouched"
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "0" "counter reset after a rule land"

# --- land (crewmate): always-loaded method lesson into CREWMATE-learned.md ---
# The machine-owned crewmate layer (learning-output-reroute): a method lesson
# has no task trigger a skill description could match, so it lands as a labeled
# entry in $AC_HOME/CREWMATE-learned.md - seeded into every crew worktree as
# its own layer - with the SAME evidence compaction as a skill.

printf '## 2026-07-21 - fam (chief)\n- LESSON: look it up before you argue it.\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: crewmate\n'
  printf 'name: look-it-up\n'
  printf 'description: Check the source before asserting a mechanism.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-21\tlook-it-up\t- LESSON: look it up before you argue it.\n'
  printf '===crewmate===\n'
  printf 'Read the contract before asserting what it does.\nCite what you read.\n'
} >"$TMP/cand-crewmate.md"
"$BIN/ac-learn.sh" land "$TMP/cand-crewmate.md"

cml="$AC_HOME/CREWMATE-learned.md"
assert_file "$cml" "CREWMATE-learned.md created on first crewmate land"
grep -qF '# Fleet-learned crewmate lessons' "$cml" || fail "first write lays down the ownership header"
grep -qF 'captains edit CREWMATE.md instead' "$cml" || fail "header names the ownership boundary"
grep -qxF '## look-it-up' "$cml" || fail "entry heading is composed by the transaction"
grep -qF 'Read the contract before asserting what it does.' "$cml" || fail "entry carries the lesson body"
grep -qE '^\(learned [0-9]{4}-[0-9]{2}-[0-9]{2}\)$' "$cml" || fail "entry ends with a provenance line"
grep -qF -- '- [distilled -> look-it-up] sources=1' "$AC_HOME/records/learnings.md" \
  || fail "crewmate land compacts its source like a skill land"
assert_file "$AC_HOME/records/learnings-archive/look-it-up.md" "crewmate land writes the evidence archive"
assert_no_file "$AC_HOME/skills/look-it-up/SKILL.md" "a crewmate lesson mints NO skill package"

# A second lesson APPENDS - the first entry survives byte-for-byte (no silent loss).
{
  printf 'kind: crewmate\n'
  printf 'name: measure-first\n'
  printf 'description: Measure the premise you inherit.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '===crewmate===\n'
  printf 'Measure before briefing.\n'
} >"$TMP/cand-crewmate2.md"
"$BIN/ac-learn.sh" land "$TMP/cand-crewmate2.md"
grep -qxF '## look-it-up' "$cml" || fail "earlier entry survives a later crewmate land"
grep -qxF '## measure-first' "$cml" || fail "second entry appended"

# Dedup: a name already carried as a '## <name>' entry refuses, file untouched.
cml_before="$(cat "$cml")"
{
  printf 'kind: crewmate\nname: look-it-up\ndescription: dup.\napproved: 1700000000\n'
  printf '===sources===\n===crewmate===\nagain.\n'
} >"$TMP/cand-crewmate-dup.md"
assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-crewmate-dup.md"
assert_eq "$(cat "$cml")" "$cml_before" "dedup refusal writes nothing"

# Context budget: a body over 12 lines refuses (a lesson that long is a skill or a doc).
{
  printf 'kind: crewmate\nname: too-long\ndescription: too long.\napproved: 1700000000\n'
  printf '===sources===\n===crewmate===\n'
  for i in $(seq 13); do printf 'line %s\n' "$i"; done
} >"$TMP/cand-crewmate-long.md"
assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-crewmate-long.md"
assert_eq "$(cat "$cml")" "$cml_before" "12-line refusal writes nothing"

# Heading-spoof guard: a body carrying its own '## ' heading refuses - a
# candidate must not be able to mint a second entry under a smuggled name.
{
  printf 'kind: crewmate\nname: spoofer\ndescription: spoof.\napproved: 1700000000\n'
  printf '===sources===\n===crewmate===\nprose.\n## smuggled-entry\nmore.\n'
} >"$TMP/cand-crewmate-spoof.md"
assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-crewmate-spoof.md"
assert_eq "$(cat "$cml")" "$cml_before" "spoof refusal writes nothing"

# Total file budget: a land that would push CREWMATE-learned.md past 4096 bytes
# refuses and NAMES the remedy (pair the new entry with a retire candidate).
python3 - "$cml" <<'PYEOF'
import sys
p = sys.argv[1]
body = open(p).read()
entry = "\n## filler-entry\n\n" + ("x" * 70 + "\n") * 60 + "\n(learned 2026-08-05)\n"
open(p, "w").write(body + entry)
PYEOF
big_before="$(cat "$cml")"
{
  printf 'kind: crewmate\nname: over-budget\ndescription: over.\napproved: 1700000000\n'
  printf '===sources===\n===crewmate===\nshort lesson.\n'
} >"$TMP/cand-crewmate-over.md"
over_out="$("$BIN/ac-learn.sh" land "$TMP/cand-crewmate-over.md" 2>&1)" && fail "over-budget land must refuse"
assert_contains "$over_out" "retire" "over-budget refusal names the retire remedy"
assert_eq "$(cat "$cml")" "$big_before" "over-budget refusal writes nothing"
# Reset the file to the two real entries for the pointer test below.
printf '%s\n' "$cml_before" >"$cml"

# --- land (skill) also stages its discovery pointer (D3 coupling) ------------
# A learned skill's zero-invocation gap was a DISCOVERY gap: every skill land
# now also appends one trigger line to CREWMATE-learned.md's pointer section,
# so no learned skill exists without its always-loaded discovery line.
printf '## 2026-07-22 - fam (chief)\n- LESSON: rebases need the pin dance.\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: skill\n'
  printf 'name: pin-dance\n'
  printf 'description: recovering a rebase onto a moved pin.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-22\tpin-dance\t- LESSON: rebases need the pin dance.\n'
  printf '===skill===\n# pin-dance\n\nSteps.\n'
} >"$TMP/cand-skill-pointer.md"
"$BIN/ac-learn.sh" land "$TMP/cand-skill-pointer.md"
assert_file "$AC_HOME/skills/pin-dance/SKILL.md" "skill still lands in the store"
grep -qxF '## when to reach for a learned skill' "$cml" || fail "skill land creates the pointer section"
grep -qF -- '- when recovering a rebase onto a moved pin -> use skill pin-dance' "$cml" \
  || fail "skill land appends its discovery pointer line"
grep -qxF '## look-it-up' "$cml" || fail "pointer append preserves existing lesson entries"

# --- no-silent-loss guard (lib): a rewrite dropping an entry is refused ------
# The guard is the maintenance-lib property future rewriters (curate) must
# pass: every '## <slug>' present before and absent after must be accounted
# retired, else the rewrite refuses.
printf '# F\n\n## keep-me\n\nbody.\n\n## drop-me\n\nbody.\n' >"$TMP/nl-live.md"
printf '# F\n\n## keep-me\n\nbody.\n' >"$TMP/nl-staged.md"
if ac_crewmate_learned_no_loss "$TMP/nl-live.md" "$TMP/nl-staged.md" ""; then
  fail "dropping '## drop-me' with no retired accounting must refuse"
fi
printf 'retired: drop-me\n' >"$TMP/nl-retired.md"
ac_crewmate_learned_no_loss "$TMP/nl-live.md" "$TMP/nl-staged.md" "$TMP/nl-retired.md" \
  || fail "a drop accounted in the retired file passes"
ac_crewmate_learned_no_loss "$TMP/nl-live.md" "$TMP/nl-live.md" "" \
  || fail "an unchanged file passes trivially"

# --- crewmate layer rides the reversibility backup ---------------------------
arc2="$(ac_records_backup learn)"
tar -tzf "$arc2" | grep -q 'CREWMATE-learned.md' || fail "CREWMATE-learned.md is in the records backup"

# --- land refuses an UNAPPROVED candidate (no writes happen) -----------------

printf '## 2026-07-18 - fam (chief)\n- another lesson to keep.\n' >"$AC_HOME/records/learnings.md"
before_learn="$(cat "$AC_HOME/records/learnings.md")"
before_cap="$(cat "$AC_HOME/records/captain.md")"
{
  printf 'kind: skill\n'
  printf 'name: nope-skill\n'
  printf 'description: should never land.\n'
  printf '===sources===\n'
  printf '2026-07-18\tnope\t- another lesson to keep.\n'
  printf '===skill===\n# nope-skill\n\nbody.\n'
} >"$TMP/cand-unapproved.md"

assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-unapproved.md"
assert_no_file "$AC_HOME/skills/nope-skill/SKILL.md" "no skill written for an unapproved candidate"
assert_eq "$(cat "$AC_HOME/records/learnings.md")" "$before_learn" "learnings.md untouched by a refused land"
assert_eq "$(cat "$AC_HOME/records/captain.md")" "$before_cap" "captain.md untouched by a refused land"

# --- land (skill) fails closed when the source bullet is not verbatim --------

printf '## 2026-07-18 - fam (chief)\n- a real bullet.\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: skill\n'
  printf 'name: drift-skill\n'
  printf 'description: source drifted.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-18\tdrift\t- a bullet that does not match the ledger.\n'
  printf '===skill===\n# drift-skill\n\nbody.\n'
} >"$TMP/cand-drift.md"
drift_before="$(cat "$AC_HOME/records/learnings.md")"
assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-drift.md"
# Pre-validation means a drifted source is a clean refusal: nothing written.
assert_no_file "$AC_HOME/skills/drift-skill/SKILL.md" "no skill written when a source bullet drifted"
assert_eq "$(cat "$AC_HOME/records/learnings.md")" "$drift_before" "learnings.md untouched when a source drifted"

# --- land (skill, retro-only): EMPTY ===sources=== lands with a zero-source pointer --
# R3.7: a candidate supported only by the run's retro.md carries an EMPTY
# ===sources=== section. This already works with zero code change - land_skill/
# learn_validate_sources/learn_compact_sources iterate the sources section, so
# zero sources means zero validation and zero compaction; this proves it.

printf '## 2026-07-18 - fam (chief)\n- an unrelated bullet, left alone.\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: skill\n'
  printf 'name: retro-only-skill\n'
  printf 'description: distilled from this run'"'"'s retro alone.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '===skill===\n# retro-only-skill\n\nbody, from retro.md only.\n'
} >"$TMP/cand-retro-only.md"
"$BIN/ac-learn.sh" land "$TMP/cand-retro-only.md"
assert_file "$AC_HOME/skills/retro-only-skill/SKILL.md" "AC11: a retro-only candidate (empty sources) still lands the skill"
grep -qF -- '- an unrelated bullet, left alone.' "$AC_HOME/records/learnings.md" \
  || fail "AC11: unrelated Pending material survives a retro-only land"
grep -qF -- '- [distilled -> retro-only-skill] sources=0 updated=' "$AC_HOME/records/learnings.md" \
  || fail "AC11: a retro-only skill still receives one canonical pointer"
grep -qF 'source-count: 0' "$AC_HOME/records/learnings-archive/retro-only-skill.md" \
  || fail "AC11: retro-only evidence is represented explicitly"

# --- promote compatibility command: fleet ownership is permanent -------------

# The old verb remains readable but fails closed. It must neither move the
# skill nor rewrite its pointer; the migration verb is the only compatibility
# path for legacy container state.
printf -- '## 2026-07-18 - fam (chief)\n- 2026-07-18 [distilled -> foo-before-bar @fleet] foo-before-bar (see skills/foo-before-bar/SKILL.md)\n' >"$AC_HOME/records/learnings.md"
assert_file "$AC_HOME/skills/foo-before-bar/SKILL.md" "the fleet-local skill is present pre-promote"
container="$(dirname "$AC_HOME")/.claude/skills"
skill_before="$(cat "$AC_HOME/skills/foo-before-bar/SKILL.md")"
ledger_before="$(cat "$AC_HOME/records/learnings.md")"
rc=0
promote_out="$("$BIN/ac-learn.sh" promote foo-before-bar 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "promote must fail closed after fleet-local ownership lands"
assert_contains "$promote_out" "permanently fleet-local" "compatibility refusal explains the ownership rule"
assert_contains "$promote_out" "retired and never read" "compatibility refusal says the container store is retired"
assert_eq "$(cat "$AC_HOME/skills/foo-before-bar/SKILL.md")" "$skill_before" "promote leaves the fleet skill byte-identical"
assert_eq "$(cat "$AC_HOME/records/learnings.md")" "$ledger_before" "promote leaves the pointer byte-identical"
assert_no_file "$container/foo-before-bar" "promote creates no container copy"

# Fleet-local seeding still reaches a fresh worktree.
repo="$(make_repo seedrepo)"
ac_seed_crew_skills "$repo"
[ -L "$repo/.claude/skills/foo-before-bar" ] || fail "fleet-local skill seeded into a crew worktree"
grep -qxF '  origin: learned' "$repo/.claude/skills/foo-before-bar/SKILL.md" || fail "seeded fleet-local skill resolves"

# The compatibility command still validates its argument before the policy
# refusal so malformed input remains a clear usage error.
assert_fails "$BIN/ac-learn.sh" promote "bad name"       # invalid slug

# --- jq-gated: run (stubbed pane agent) + ac-gate learning-stage rejection ----

if command -v jq >/dev/null 2>&1; then
  # A stub pane agent: writes a report INTO its cwd (the run dir) and emits the
  # NDJSON done event ac-learn.sh run consumes. No real claude is spawned.
  cat >"$TMP/stub-pane.sh" <<'STUB'
#!/usr/bin/env bash
# reap-pane path (armed by cmd_run's EXIT trap): record the pane id, print a
# stdout marker that MUST be swallowed by the reap's redirect, honor a fail knob.
if [ "${1:-}" = reap-pane ]; then
  shift; pane=""
  while [ $# -gt 0 ]; do case "$1" in --pane) pane="$2"; shift 2 ;; *) shift ;; esac; done
  printf 'reap-pane %s\n' "$pane" >>"$AC_LEARN_REAP_LOG"
  echo "REAP-STDOUT-MARKER"
  # The real helper always exits 0 and reports the outcome on its event
  # instead (ac-pane-agent.sh REAP OUTCOME). AC_LEARN_REAP_STUCK names a pane
  # the close did NOT take on.
  if [ "$pane" = "${AC_LEARN_REAP_STUCK:-}" ]; then
    printf '{"event":"reap-pane-done","pane":"%s","closed":false}\n' "$pane"
  else
    printf '{"event":"reap-pane-done","pane":"%s","closed":true}\n' "$pane"
  fi
  [ "${AC_LEARN_REAP_FAIL:-0}" = 1 ] && exit 3
  exit 0
fi
# run path: write a report INTO its cwd (the run dir) and emit the NDJSON done
# event ac-learn.sh run consumes. No real claude is spawned. Also writes
# retro.md (Pass 1's output), the way a real scout would before proposing.
# The caller must hand the pane its FAMILY workspace (FAMILY WORKSPACE
# GROUPING): the scout sits beside crew:learning-chief, never orphaned in
# the fleet root group.
printf '%s
' "${AC_WINDOW_FAMILY:-}" >>"${AC_LEARN_WSFAM_LOG:-/dev/null}"
cwd=""; deliverable=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cwd) cwd="$2"; shift 2 ;;
    --deliverable) deliverable="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$deliverable" >"$cwd/stub.deliverable"
# A REVISION / candidate re-author pane spawned for this same run records
# itself in the run's pane ledger - the contract cmd_run's EXIT trap reaps by.
[ -n "${AC_LEARN_STUB_REVISION:-}" ] && printf '%s\n' "$AC_LEARN_STUB_REVISION" >>"$cwd/scout.panes"
printf '# Retro\n\nno cross-family pattern found (smoke).\n' >"$cwd/retro.md"
printf '## Retro\n\nsee ./retro.md.\n\nproposed nothing this run (smoke).\n' >"$cwd/report.md"
printf '{"event":"transcript","path":"/dev/null","session_id":"s1"}\n'
printf '{"event":"done","status":"ok","session_id":"s1","transcript":"/dev/null","pane":"p1"}\n'
STUB
  chmod +x "$TMP/stub-pane.sh"

  printf '## 2026-07-18 - fam (chief)\n- keep me exactly.\n' >"$AC_HOME/records/learnings.md"
  printf 'captain policy, untouched.\n' >"$AC_HOME/records/captain.md"
  mkdir -p "$AC_HOME/skills/pre"; printf 'pre-existing store.\n' >"$AC_HOME/skills/pre/SKILL.md"
  # patch-before-new snapshots only the owning fleet store. Legacy container
  # learned skills are migration inputs and never active scout context.
  cont="$(dirname "$AC_HOME")/.claude/skills"
  mkdir -p "$AC_HOME/skills/fleet-learned" "$cont/cont-learned" "$cont/cont-builtin"
  printf -- '---\nname: fleet-learned\ndescription: x\nmetadata:\n  origin: learned\n---\n# fleet-learned\n' >"$AC_HOME/skills/fleet-learned/SKILL.md"
  printf -- '---\nname: cont-learned\ndescription: x\nmetadata:\n  origin: learned\n---\n# cont-learned\n' >"$cont/cont-learned/SKILL.md"
  printf -- '---\nname: cont-builtin\ndescription: x\n---\n# cont-builtin\n' >"$cont/cont-builtin/SKILL.md"
  # The retired-skill archive is a reserved subdir, not a skill. A stray
  # SKILL.md at its root must not be lifted as a phantom "skills-archive".
  mkdir -p "$AC_HOME/skills/$AC_SKILLS_ARCHIVE_BASENAME"
  printf -- '---\nname: stray\ndescription: x\n---\n# stray at the archive root\n' \
    >"$AC_HOME/skills/$AC_SKILLS_ARCHIVE_BASENAME/SKILL.md"
  before_l="$(cat "$AC_HOME/records/learnings.md")"
  before_c="$(cat "$AC_HOME/records/captain.md")"
  before_s="$(cat "$AC_HOME/skills/pre/SKILL.md")"

  export AC_LEARN_REAP_LOG="$TMP/learn-reap.log"; : >"$AC_LEARN_REAP_LOG"
  export AC_LEARN_WSFAM_LOG="$TMP/wsfam.log"
  runout="$(AC_PANE_AGENT="$TMP/stub-pane.sh" "$BIN/ac-learn.sh" run)"
  assert_eq "$(head -1 "$AC_LEARN_WSFAM_LOG")" "learning" \
    "the scout pane is spawned INTO the stable learning family workspace (beside its roomchief)"

  # cmd_run best-effort REAPS the scout's pane (id from the done event's "pane")
  # via ac-pane-agent.sh reap-pane, armed as an EXIT trap. Pure cleanup: the
  # reap's own stdout is swallowed and never leaks into cmd_run's printed result.
  assert_contains "$(cat "$AC_LEARN_REAP_LOG")" "reap-pane p1" "cmd_run reaps the scout's pane after a normal run"
  case "$runout" in *REAP-STDOUT-MARKER*) fail "reap output leaked into cmd_run's printed result" ;; esac
  assert_contains "$runout" "AUTO-MAINTENANCE: no candidates" \
    "cmd_run reports a settled no-candidate automatic cycle"

  # A pre-run backup was taken.
  ls "$AC_HOME"/state/backups/learn-*.tar.gz >/dev/null 2>&1 || fail "run took a pre-run backup"
  # The run dir + the distill contract + the source snapshot exist.
  rundir="$(find "$AC_HOME/data" -maxdepth 1 -type d -name 'learning-*' | head -1)"
  [ -n "$rundir" ] || fail "run created a learning-<epoch> run dir"
  assert_file "$rundir/brief.md" "run wrote the distill contract brief.md"
  assert_file "$rundir/sources/learnings.md" "run snapshotted learnings.md into sources/"
  assert_file "$rundir/report.md" "the (stubbed) scout wrote report.md into the run dir"
  # cmd_run DECLARES that report.md to the pane helper, which is what stops an
  # idle pane from being harvested as a finished pass (ac-pane-agent.sh, IDLE
  # FALLBACK). Undeclared, a scout that stopped mid-pass - out of budget,
  # self-blocked - still exited status ok and consumed the retro window.
  assert_eq "$(cat "$rundir/stub.deliverable")" "$rundir/report.md" \
    "the scout's report.md is declared as the pane's deliverable"
  # REPORT-ONLY: stores + ledgers byte-identical after a run.
  assert_eq "$(cat "$AC_HOME/records/learnings.md")" "$before_l" "learnings.md byte-identical after run"
  assert_eq "$(cat "$AC_HOME/records/captain.md")" "$before_c" "captain.md byte-identical after run"
  assert_eq "$(cat "$AC_HOME/skills/pre/SKILL.md")" "$before_s" "skills store byte-identical after run"

  # AC7: brief.md carries the Pass 1 - RETRO section AHEAD of Pass 2 - DISTILL,
  # and instructs the scout to write retro.md before proposing candidates.
  assert_file "$rundir/sources/retro/window.md" "run wrote the retro window manifest before spawning the scout"
  pass1_line="$(grep -n '^## Pass 1 - RETRO' "$rundir/brief.md" | head -1 | cut -d: -f1)"
  pass2_line="$(grep -n '^## Pass 2 - DISTILL' "$rundir/brief.md" | head -1 | cut -d: -f1)"
  [ -n "$pass1_line" ] && [ -n "$pass2_line" ] || fail "brief.md carries both Pass 1 and Pass 2 headings"
  [ "$pass1_line" -lt "$pass2_line" ] || fail "Pass 1 - RETRO must appear ahead of Pass 2 - DISTILL in brief.md"
  assert_contains "$(cat "$rundir/brief.md")" './retro.md` BEFORE you propose any candidate' \
    "brief.md instructs the scout to write retro.md before proposing candidates"

  # AC9 (part 1): with the stub writing retro.md, the run summary prints its path.
  assert_file "$rundir/retro.md" "the (stubbed) scout wrote retro.md (Pass 1's output)"
  assert_contains "$runout" "retro: $rundir/retro.md" "cmd_run's summary prints the written retro.md path"

  # The fleet-local learned store is the only active snapshot source. Both
  # container shapes stay out until explicit migration copies fleet ownership.
  assert_file "$rundir/sources/skills/fleet-learned/SKILL.md" "run snapshotted the fleet-learned skill"
  assert_no_file "$rundir/sources/skills/cont-learned/SKILL.md" "run excluded the legacy container learned skill"
  assert_no_file "$rundir/sources/skills/cont-builtin/SKILL.md" "run did NOT snapshot the container non-learned skill"
  assert_no_file "$rundir/sources/skills/$AC_SKILLS_ARCHIVE_BASENAME/SKILL.md" \
    "run did NOT lift the archive root as a phantom skills-archive skill"

  # Learning is NOT a staged design gate: ac-gate.sh judges spec|architecture|
  # plan|design ONLY and REJECTS `learning` (before any profile resolution), so
  # the learning flow never invokes it. Prove the rejection is a hard input
  # error, not a judge run.
  gdir="$AC_HOME/data/learning-9999"
  mkdir -p "$gdir"
  printf '# report\ncandidate proposed.\n' >"$gdir/report.md"
  printf '# brief\nthe distill contract.\n' >"$gdir/brief.md"
  set +e
  "$BIN/ac-gate.sh" learning-9999 learning >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" != 0 ] && [ "$rc" != 4 ] || fail "ac-gate.sh must REJECT the learning stage as an input error (not judge it, not exit 4)"

  # A reap that FAILS (helper returns non-zero) changes neither cmd_run's exit
  # code nor its result/printed output - the `|| true` best-effort contract.
  : >"$AC_LEARN_REAP_LOG"
  set +e
  failout="$(AC_PANE_AGENT="$TMP/stub-pane.sh" AC_LEARN_REAP_FAIL=1 "$BIN/ac-learn.sh" run)"
  failrc=$?
  set -e
  assert_eq "$failrc" "0" "a failing reap does not change cmd_run's exit code"
  assert_contains "$failout" "AUTO-MAINTENANCE: no candidates" \
    "cmd_run's printed result is intact despite a failing reap"
  assert_contains "$(cat "$AC_LEARN_REAP_LOG")" "reap-pane p1" "the reap was attempted even though it failed"
  case "$failout" in *REAP-STDOUT-MARKER*) fail "a failing reap's output must not leak into cmd_run's result" ;; esac

  # --- the run reaps EVERY pane it spawned, not just the first --------------
  # The distill's pane ledger is $rundir/scout.panes; the EXIT trap reaps every
  # id IN IT rather than one id baked in at arm time, so a REVISION / candidate
  # re-author pane recorded for the same run is retired with the scout instead
  # of orphaning in the shared pane-agent workspace.
  : >"$AC_LEARN_REAP_LOG"
  AC_PANE_AGENT="$TMP/stub-pane.sh" AC_LEARN_STUB_REVISION=pREV "$BIN/ac-learn.sh" run >/dev/null
  reaped="$(cat "$AC_LEARN_REAP_LOG")"
  assert_contains "$reaped" "reap-pane p1" "the scout's own pane is still reaped"
  # This also pins the ledger PATH: the stub appends pREV to $cwd/scout.panes, so
  # a run reading any other path never reaps it.
  assert_contains "$reaped" "reap-pane pREV" "a revision pane recorded for the run is reaped too"

  # Same coverage on the ABORT path the trap already covers: a scout that emits
  # no done event ac_die's, and every recorded pane is still reaped.
  cat >"$TMP/stub-pane-nodone2.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = reap-pane ]; then
  shift; pane=""
  while [ $# -gt 0 ]; do case "$1" in --pane) pane="$2"; shift 2 ;; *) shift ;; esac; done
  printf 'reap-pane %s\n' "$pane" >>"$AC_LEARN_REAP_LOG"
  printf '{"event":"reap-pane-done","pane":"%s","closed":true}\n' "$pane"
  exit 0
fi
cwd=""
while [ $# -gt 0 ]; do case "$1" in --cwd) cwd="$2"; shift 2 ;; *) shift ;; esac; done
printf 'pREV2\n' >>"$cwd/scout.panes"
printf '{"event":"transcript","path":"/dev/null","session_id":"s1","pane":"p1"}\n'
STUB
  chmod +x "$TMP/stub-pane-nodone2.sh"
  : >"$AC_LEARN_REAP_LOG"
  set +e
  AC_PANE_AGENT="$TMP/stub-pane-nodone2.sh" "$BIN/ac-learn.sh" run >/dev/null 2>&1
  set -e
  assert_contains "$(cat "$AC_LEARN_REAP_LOG")" "reap-pane pREV2" \
    "an aborted run still reaps every pane its ledger recorded"

  # --- a reap that did NOT close its pane is SURFACED, not swallowed --------
  # reap-pane keeps its always-exit-0 contract, so the caller is the only place
  # a failed close can become visible. It goes to STDERR: cmd_run's stdout is a
  # parsed result and must stay byte-clean.
  : >"$AC_LEARN_REAP_LOG"
  set +e
  stuckout="$(AC_PANE_AGENT="$TMP/stub-pane.sh" AC_LEARN_REAP_STUCK=p1 \
    "$BIN/ac-learn.sh" run 2>"$TMP/learn-stuck.err")"
  stuckrc=$?
  set -e
  assert_eq "$stuckrc" "0" "an unclosed pane never changes cmd_run's exit code"
  assert_contains "$(cat "$TMP/learn-stuck.err")" "p1" "the unclosed pane id is named on stderr"
  assert_contains "$(cat "$TMP/learn-stuck.err")" "WARN" "an unclosed pane warns rather than passing silently"
  case "$stuckout" in *WARN*) fail "the reap warning must not pollute cmd_run's printed result" ;; esac

  # --- RETRO first-pass: window resolution against records/backlog.md --------
  # (AC1-AC6, AC8 extended, AC9-AC10)

  epoch_for_date() {
    # epoch_for_date <YYYY-MM-DD> -> epoch at 00:00:00Z. BSD then GNU fallback
    # (the test-fixture inverse of ac-learn.sh's own learn_epoch_to_date).
    date -u -j -f '%Y-%m-%d' "$1" +%s 2>/dev/null || date -u -d "$1" +%s
  }

  anchor_epoch="$(epoch_for_date 2026-07-15)"
  printf 'debriefs=0\nlast_run=%s\n' "$anchor_epoch" >"$AC_HOME/state/.learn.meta"

  backlog="$AC_HOME/records/backlog.md"
  {
    printf '# Backlog\n\n## Done\n'
    printf -- '- [x] fam-before - old work - local main (merged 2026-07-14)\n'
    printf -- '- [x] fam-oneday - same-day work - local main (merged 2026-07-15)\n'
    printf -- '- [x] fam-after1 - recent work - local main (merged 2026-07-16)\n'
    printf -- '- [x] fam-after2 [failed] - broke midway - retry needed (2026-07-17)\n'
    printf -- '- [x] fam-noroom - trivial work - local main (merged 2026-07-18)\n'
    # F1: a real annotated shape - the date is NOT the last thing in the
    # parenthetical, AND the parenthetical is not the last thing on the line
    # either (both are the dominant real-ledger forms, per the review's
    # frequency census of ac-homes/{drydock,lab} backlog.md).
    printf -- '- [x] fam-annotated - real annotated shape - local main @abc1234 (merged 2026-07-16; sequential). Queue finding: n/a\n'
    # F1b: a Done line whose date group carries no verb at all must be tagged
    # `unknown`, never an invented `merged`.
    printf -- '- [x] fam-noverb - no verb in the date group - local main (2026-07-16)\n'
    # F3 (E7): a family id outside [a-zA-Z0-9_-] must never get a room lookup,
    # even when a file happens to sit at the unsafe path it would resolve to.
    printf -- '- [x] ../escape - id outside the safe charset - local main (merged 2026-07-16)\n'
    # F1 follow-up: a NESTED paren tail (e.g. a citation like `§8(2)`) defeats
    # the non-nested last-group walk - the date must still be found via the
    # whole-line date fallback.
    printf -- '- [x] fam-nested - nested paren tail - local main (merged 2026-07-16; ref data/x/report.md §8(2))\n'
    # F1 follow-up: the verb+date sits OUTSIDE the trailing parenthetical
    # group entirely - must still be found via the whole-line date fallback.
    printf -- '- [x] fam-dateoutside - date sits outside the trailing group - local main - reviewed 2026-07-16 (captain-directed review; queued)\n'
    # A window member whose family bin/ac-archive.sh has already moved to
    # data/archive/<year>/. The retro is a HISTORY read: a landed family is
    # closed, so it is exactly the class that gets archived, and its lessons
    # must not vanish from the window the moment it moves.
    printf -- '- [x] fam-archived - landed then archived - local main (merged 2026-07-16)\n'
  } >"$backlog"

  mkdir -p "$AC_HOME/data/fam-oneday" "$AC_HOME/data/fam-after1" "$AC_HOME/data/fam-after2" "$AC_HOME/escape"
  printf '# Room: fam-oneday\n\n- [2026-07-15T09:00:00Z] crewchief> shipped same-day.\n' >"$AC_HOME/data/fam-oneday/room.md"
  printf '# Room: fam-after1\n\n- [2026-07-16T09:00:00Z] crewchief> shipped clean.\n' >"$AC_HOME/data/fam-after1/room.md"
  printf '# Room: fam-after2\n\n- [2026-07-17T09:00:00Z] crewchief> ASK: how to recover?\n' >"$AC_HOME/data/fam-after2/room.md"
  # F3 fixture: a room.md sitting at the path "../escape" would resolve to
  # (ac_data_dir()/../escape/room.md) - present so the ablation actually
  # discriminates (a widened guard would find and copy it).
  printf '# Room: escape\n\n- [2026-07-16T09:00:00Z] crewchief> should never be read.\n' >"$AC_HOME/escape/room.md"
  mkdir -p "$AC_HOME/data/archive/2026/fam-archived"
  printf '# Room: fam-archived\n\n- [2026-07-16T09:00:00Z] crewchief> CLOSED: landed, then archived.\n' \
    >"$AC_HOME/data/archive/2026/fam-archived/room.md"

  # (retro-window-cannot-see-stage-reports) fam-after1 also wrote a STAGE
  # report carrying the `## Lessons` section every crewmate is contracted to
  # produce - invisible to this loop until the window learned to lift it - plus
  # a second report with no such section, so the lift is shown to be selective
  # rather than a blanket copy.
  mkdir -p "$AC_HOME/data/fam-after1/spec" "$AC_HOME/data/fam-after1/implement"
  printf '# Spec\n\n## Findings\n\nctx\n\n## Lessons\n\n- the fifo OPEN is what blocks, not the read\n\n## Next\n\nnope\n' \
    >"$AC_HOME/data/fam-after1/spec/report.md"
  printf '# Implement\n\n## Notes\n\nnothing durable\n' \
    >"$AC_HOME/data/fam-after1/implement/report.md"

  before_bl="$(cat "$backlog")"
  AC_PANE_AGENT="$TMP/stub-pane.sh" "$BIN/ac-learn.sh" run >/dev/null
  rundir2="$(find "$AC_HOME/data" -maxdepth 1 -type d -name 'learning-*' ! -name 'learning-9999' | sort | tail -1)"
  window="$rundir2/sources/retro/window.md"
  assert_file "$window" "run wrote the retro window manifest"

  # AC1: families dated AFTER the anchor are listed with their date, and each
  # gets its room copied to sources/retro/rooms/<family>.md.
  grep -q '^fam-after1 2026-07-16 merged room lessons=1$' "$window" \
    || fail "AC1: fam-after1 listed with its date, tagged merged, room copied, lessons marked"

  # The LIFT: only the `## Lessons` section, only from reports that carry one.
  lifted="$rundir2/sources/retro/lessons/fam-after1.md"
  assert_file "$lifted" "a member's stage-report Lessons are lifted into sources/retro/lessons/"
  assert_contains "$(cat "$lifted")" "the fifo OPEN is what blocks" "the crewmate's own first-hand words are carried"
  assert_contains "$(cat "$lifted")" "fam-after1/spec/report.md" "each block names the report it came from"
  case "$(cat "$lifted")" in
    *"## Findings"*|*"## Next"*|*nope*) fail "only the Lessons SECTION is lifted, never the surrounding report" ;;
  esac
  assert_no_file "$rundir2/sources/retro/lessons/fam-after2.md" \
    "a member whose reports carry no Lessons section writes no file - absence is silent"
  assert_file "$rundir2/sources/retro/rooms/fam-after1.md" "AC1: fam-after1's room copied into sources/retro/rooms/"
  # AC4: a [failed] Done line in the window is tagged failed.
  grep -q '^fam-after2 2026-07-17 failed room$' "$window" || fail "AC4: fam-after2 ([failed]) tagged failed in window.md"
  assert_file "$rundir2/sources/retro/rooms/fam-after2.md" "AC1: fam-after2's room also copied"

  # An ARCHIVED family's room is still snapshotted: the retro resolves the room
  # live-first then archived (ac_room_file), so archiving a landed family never
  # silently empties the distill window.
  grep -q '^fam-archived 2026-07-16 merged room$' "$window" \
    || fail "an archived family must still be tagged room in the window manifest"
  assert_file "$rundir2/sources/retro/rooms/fam-archived.md" \
    "an archived family's room is copied into sources/retro/rooms/"
  assert_contains "$(cat "$rundir2/sources/retro/rooms/fam-archived.md")" \
    "landed, then archived" "and it is the archived room's real content"

  # AC2: a family dated BEFORE the anchor date never appears in window.md.
  if grep -q 'fam-before' "$window"; then fail "AC2: fam-before (dated before the anchor) leaked into the window"; fi

  # AC5: a window member with no room is marked no-room, carries its verbatim
  # backlog Done line, and gets no rooms/<family>.md.
  grep -q '^fam-noroom 2026-07-18 merged no-room$' "$window" || fail "AC5: fam-noroom marked no-room"
  grep -qF -- '- [x] fam-noroom - trivial work - local main (merged 2026-07-18)' "$window" \
    || fail "AC5: fam-noroom's verbatim backlog line is carried in window.md"
  assert_no_file "$rundir2/sources/retro/rooms/fam-noroom.md" "AC5: no room file written for a roomless member"

  # F2 (R1.2/E3): a family landed exactly on the anchor date is a member
  # (inclusive window) - `fam-oneday` had a fixture but no assertion.
  grep -q '^fam-oneday 2026-07-15 merged room$' "$window" \
    || fail "F2: fam-oneday (dated exactly on the anchor) is included and its room copied"

  # F1: the date group need not END the parenthetical - the trailing
  # annotation after the date must not defeat the parse.
  grep -q '^fam-annotated 2026-07-16 merged no-room$' "$window" \
    || fail "F1: the annotated (merged <date>; sequential) shape is parsed as a merged member"

  # F1b: no verb in the date group -> explicit `unknown`, never an invented
  # `merged`.
  grep -q '^fam-noverb 2026-07-16 unknown no-room$' "$window" \
    || fail "F1b: a Done line with no verb in its date group is tagged 'unknown', not guessed as 'merged'"

  # F3 (E7): an id outside [a-zA-Z0-9_-] never gets a room lookup, even
  # though a room.md sits at the unsafe path it would otherwise resolve to.
  grep -q '^\.\./escape 2026-07-16 merged no-room$' "$window" \
    || fail "F3: an id outside the safe charset is marked no-room without a room lookup"

  # F1 follow-up: a nested paren tail must not defeat the date fallback.
  grep -q '^fam-nested 2026-07-16 merged no-room$' "$window" \
    || fail "F1 follow-up: a nested paren tail (...report.md §8(2)) still finds the date"

  # F1 follow-up: a verb+date sitting outside the trailing group must still
  # be found via the whole-line fallback.
  grep -q '^fam-dateoutside 2026-07-16 reviewed no-room$' "$window" \
    || fail "F1 follow-up: a verb+date outside the trailing parenthetical group is still found"

  # AC8 (extended): Learning never mutates backlog.md; retro only reads it.
  assert_eq "$(cat "$backlog")" "$before_bl" "AC8: backlog.md byte-identical after a run"

  # AC3: with NO last_run key at all, the anchor is `none` and every dated
  # Done line - including the pre-anchor one - is listed (the full section).
  rm -f "$AC_HOME/state/.learn.meta"
  AC_PANE_AGENT="$TMP/stub-pane.sh" "$BIN/ac-learn.sh" run >/dev/null
  rundir3="$(find "$AC_HOME/data" -maxdepth 1 -type d -name 'learning-*' ! -name 'learning-9999' | sort | tail -1)"
  window3="$rundir3/sources/retro/window.md"
  grep -q '^anchor: none' "$window3" || fail "AC3: anchor: none when state/.learn.meta has no last_run key"
  grep -q '^fam-before 2026-07-14 merged no-room$' "$window3" \
    || fail "AC3: fam-before appears when there is no last_run (full Done section)"

  # AC6: a window with zero members (anchor far in the future) still produces
  # window.md stating so, and the run completes normally with ac_curate_tick
  # advanced by exactly one.
  printf 'debriefs=0\nlast_run=%s\n' "$(epoch_for_date 2099-01-01)" >"$AC_HOME/state/.learn.meta"
  curate_before="$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)"
  case "$curate_before" in '' | *[!0-9]*) curate_before=0 ;; esac
  AC_PANE_AGENT="$TMP/stub-pane.sh" "$BIN/ac-learn.sh" run >/dev/null
  rundir6="$(find "$AC_HOME/data" -maxdepth 1 -type d -name 'learning-*' ! -name 'learning-9999' | sort | tail -1)"
  window6="$rundir6/sources/retro/window.md"
  grep -qF 'no families landed in this window' "$window6" || fail "AC6: a zero-member window says so explicitly"
  curate_after="$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)"
  assert_eq "$curate_after" "$((curate_before + 1))" "AC6: ac_curate_tick still advances by one on a zero-member run"

  # AC9/AC10: the run summary's retro: line, and the warn-only guard when the
  # window has members but the scout writes no retro.md.
  cat >"$TMP/stub-pane-noretro.sh" <<'STUB2'
#!/usr/bin/env bash
if [ "${1:-}" = reap-pane ]; then exit 0; fi
cwd=""
while [ $# -gt 0 ]; do case "$1" in --cwd) cwd="$2"; shift 2 ;; *) shift ;; esac; done
printf 'proposed nothing (no retro written).\n' >"$cwd/report.md"
printf '{"event":"done","status":"ok","session_id":"s1","transcript":"/dev/null","pane":"p1"}\n'
STUB2
  chmod +x "$TMP/stub-pane-noretro.sh"

  printf 'debriefs=0\nlast_run=%s\n' "$anchor_epoch" >"$AC_HOME/state/.learn.meta"
  # `ac_now`'s 1-second resolution can collide with an EARLIER run dir from
  # this same suite (which DID write retro.md) - start this run's dir from a
  # clean slate so a leftover retro.md never masquerades as this run's own.
  rm -rf "${AC_HOME:?}"/data/learning-*
  set +e
  noretro_out="$(AC_PANE_AGENT="$TMP/stub-pane-noretro.sh" "$BIN/ac-learn.sh" run 2>"$TMP/noretro.err")"
  noretro_rc=$?
  set -e
  assert_eq "$noretro_rc" "0" "AC10: a non-empty window with no retro.md written still exits 0"
  assert_contains "$noretro_out" 'retro: (none written)' "AC9: retro: line prints (none written) when the scout skips it"
  assert_contains "$(cat "$TMP/noretro.err")" 'WARN' "AC10: a non-empty window with no retro.md warns on stderr"

  # --- the RUN consumes the cadence cycle --------------------------------------
  # ac_learn_reset moved from `land` to the END of cmd_run: the counter counts
  # debriefs-since-the-last-EXAMINATION, and `run` IS the examination. On `land`
  # a distill that legitimately proposed nothing left debriefs over threshold
  # forever - harmless while a human read the digest, a silently dead loop once
  # the trigger is automatic.
  old_anchor="$(epoch_for_date 2026-07-15)"
  printf 'debriefs=9\nlast_run=%s\n' "$old_anchor" >"$AC_HOME/state/.learn.meta"
  rm -rf "${AC_HOME:?}"/data/learning-*
  AC_PANE_AGENT="$TMP/stub-pane.sh" "$BIN/ac-learn.sh" run >/dev/null
  assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "0" "a completed run resets debriefs=0"
  new_anchor="$(ac_meta_get "$AC_HOME/state/.learn.meta" last_run)"
  [ "$new_anchor" -gt "$old_anchor" ] || fail "a completed run stamps a fresh last_run"

  # The ORDER, pinned on purpose: last_run is ALSO the retro window anchor, so
  # this reset moves the anchor from land-time to run-time (intended - a run that
  # lands nothing no longer re-examines the same window forever). The snapshot
  # must read the OLD anchor BEFORE the reset overwrites it; a reset that ran
  # first would anchor a run's window on itself and see an empty window.
  rundir_reset="$(find "$AC_HOME/data" -maxdepth 1 -type d -name 'learning-*' ! -name 'learning-9999' | sort | tail -1)"
  grep -qF "anchor: $old_anchor (2026-07-15)" "$rundir_reset/sources/retro/window.md" \
    || fail "the retro window is anchored on the OLD last_run, read before the reset overwrote it"

  # The PREMISE the two assertions above rest on: this stub proposed NOTHING (it
  # writes report.md and zero candidate-*.md). That is the case the reset exists
  # for - a distill that legitimately found nothing must still consume its cycle,
  # or it re-examines the same window forever. Pinned so the case cannot drift
  # into a proposed-something run while still claiming to cover it.
  assert_eq "$(find "$rundir_reset" -maxdepth 1 -name 'candidate-*.md' | wc -l | tr -d ' ')" "0" \
    "the run that consumed the cycle proposed NO candidates"

  # A run that ABORTS never consumes the cycle - the twin of the ac_curate_tick
  # placement assertion, and what keeps a failed run's crossing re-triggerable.
  cat >"$TMP/stub-pane-nodone.sh" <<'STUB3'
#!/usr/bin/env bash
if [ "${1:-}" = reap-pane ]; then exit 0; fi
printf '{"event":"transcript","path":"/dev/null","session_id":"s1"}\n'
STUB3
  chmod +x "$TMP/stub-pane-nodone.sh"
  printf 'debriefs=9\nlast_run=%s\n' "$old_anchor" >"$AC_HOME/state/.learn.meta"
  set +e
  AC_PANE_AGENT="$TMP/stub-pane-nodone.sh" "$BIN/ac-learn.sh" run >/dev/null 2>&1
  abort_rc=$?
  set -e
  [ "$abort_rc" != 0 ] || fail "a run whose scout emits no done event must abort"
  assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "9" "an aborted run leaves the counter untouched"
  assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" last_run)" "$old_anchor" "an aborted run leaves the window anchor untouched"

  # A run whose scout PRODUCED NOTHING never examined the window, so it must not
  # consume the cycle either - the twin of the aborted-run case above, for a scout
  # that reached its turn-end without writing report.md (out of budget,
  # self-blocked). LIVED: learning-1784802367 hit the org monthly spend limit
  # after 23 Reads, wrote no report.md, and the run still stamped last_run -
  # advancing the anchor past 43 members nothing had read, restored BY HAND
  # (data/learning/room.md 13:36:13Z). report.md is the artifact cmd_run declares
  # as the pane's --deliverable, so this shape now arrives as status error.
  cat >"$TMP/stub-pane-noreport.sh" <<'STUB4'
#!/usr/bin/env bash
if [ "${1:-}" = reap-pane ]; then exit 0; fi
printf '{"event":"transcript","path":"/dev/null","session_id":"s1"}\n'
printf '{"event":"done","status":"error","session_id":"s1","transcript":"/dev/null","pane":"p1","error":"the pane went idle without producing its deliverable"}\n'
STUB4
  chmod +x "$TMP/stub-pane-noreport.sh"
  printf 'debriefs=9\nlast_run=%s\n' "$old_anchor" >"$AC_HOME/state/.learn.meta"
  # A leftover run dir from THIS suite (ac_now has 1-second resolution) still
  # holds a report.md an earlier stub wrote - clear it so this run's verdict is
  # its own scout's, not a neighbour's artifact.
  rm -rf "${AC_HOME:?}"/data/learning-*
  set +e
  AC_PANE_AGENT="$TMP/stub-pane-noreport.sh" "$BIN/ac-learn.sh" run >/dev/null 2>"$TMP/noreport.err"
  noreport_rc=$?
  set -e
  assert_eq "$noreport_rc" "0" "an incomplete scout returns safely while preserving the due run"
  assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "9" \
    "a scout that produced no report.md leaves the counter untouched"
  assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" last_run)" "$old_anchor" \
    "a scout that produced no report.md leaves the retro window anchor untouched"
  assert_contains "$(cat "$TMP/noreport.err")" 'retro window is PRESERVED' \
    "the withheld cadence is said out loud, not left for a chief to notice by hand"
else
  printf 'SKIP: jq not available - run + gate learning-rejection smoke skipped\n'
fi

# --- Fix A: valid_slug is agentskills-strict (name == folder, hyphen rules) ---
# Tested behaviorally through `land` (the shared validator both land_skill and
# cmd_promote call). Empty ===sources=== => no compaction, so a well-formed name
# lands with no learnings.md dependency.

mk_named_cand() {  # mk_named_cand <name> -> path to a minimal APPROVED skill candidate
  local nm="$1" f="$TMP/cand-name.md"
  {
    printf 'kind: skill\n'
    printf 'name: %s\n' "$nm"
    printf 'description: a valid one-line description.\n'
    printf 'approved: 1700000000\n'
    printf '===sources===\n'
    printf '===skill===\n'
    printf '# %s\n\nbody.\n' "$nm"
  } >"$f"
  printf '%s\n' "$f"
}

name64="$(printf '%064d' 0 | tr '0' 'a')"   # 64 chars, all 'a' (the ceiling)
name65="$(printf '%065d' 0 | tr '0' 'a')"   # 65 chars (one over)

# VALID: a, a-b, a-b-c, a 64-char name -> all land.
for good in a a-b a-b-c "$name64"; do
  rm -rf "$AC_HOME/skills/$good"
  "$BIN/ac-learn.sh" land "$(mk_named_cand "$good")" >/dev/null \
    || fail "valid slug refused: '$good'"
  assert_file "$AC_HOME/skills/$good/SKILL.md" "valid slug '$good' landed"
done

# INVALID: leading/trailing/consecutive hyphen, uppercase, underscore, empty,
# >64 chars -> all refused (no skill dir written).
for bad in -a a- a--b A a_b "" "$name65"; do
  assert_fails "$BIN/ac-learn.sh" land "$(mk_named_cand "$bad")"
done
assert_no_file "$AC_HOME/skills/$name65/SKILL.md" "a >64-char name is refused, nothing written"

# --- Fix B: description non-empty and <=1024 (agentskills-strict) -------------

mk_desc_cand() {  # mk_desc_cand <name> <desc> -> path to a minimal APPROVED candidate
  local nm="$1" d="$2" f="$TMP/cand-desc.md"
  {
    printf 'kind: skill\n'
    printf 'name: %s\n' "$nm"
    printf 'description: %s\n' "$d"
    printf 'approved: 1700000000\n'
    printf '===sources===\n'
    printf '===skill===\n'
    printf '# %s\n\nbody.\n' "$nm"
  } >"$f"
  printf '%s\n' "$f"
}

desc1024="$(printf '%01024d' 0 | tr '0' 'd')"
desc1025="$(printf '%01025d' 0 | tr '0' 'd')"

# empty description -> refused, nothing written.
rm -rf "$AC_HOME/skills/desc-empty"
assert_fails "$BIN/ac-learn.sh" land "$(mk_desc_cand desc-empty '')"
assert_no_file "$AC_HOME/skills/desc-empty/SKILL.md" "empty description refused, nothing written"
# 1024-char description -> OK.
rm -rf "$AC_HOME/skills/desc-max"
"$BIN/ac-learn.sh" land "$(mk_desc_cand desc-max "$desc1024")" >/dev/null || fail "1024-char description refused"
assert_file "$AC_HOME/skills/desc-max/SKILL.md" "1024-char description landed"
# 1025-char description -> refused, nothing written.
rm -rf "$AC_HOME/skills/desc-over"
assert_fails "$BIN/ac-learn.sh" land "$(mk_desc_cand desc-over "$desc1025")"
assert_no_file "$AC_HOME/skills/desc-over/SKILL.md" "1025-char (over-limit) description refused"

# --- Container learned skills are migration-only, never active seed sources ---

cont="$(dirname "$AC_HOME")/.claude/skills"
mkdir -p "$cont/legacy-origin" "$cont/meta-origin"
printf -- '---\nname: legacy-origin\ndescription: x\norigin: learned\n---\n# legacy-origin\n' \
  >"$cont/legacy-origin/SKILL.md"
printf -- '---\nname: meta-origin\ndescription: x\nmetadata:\n  origin: learned\n  landed: 1\n---\n# meta-origin\n' \
  >"$cont/meta-origin/SKILL.md"
seedrepo2="$(make_repo seedrepo2)"
ac_seed_crew_skills "$seedrepo2"
assert_no_file "$seedrepo2/.claude/skills/legacy-origin" \
  "legacy top-level container origin is not seeded before migration"
assert_no_file "$seedrepo2/.claude/skills/meta-origin" \
  "metadata.origin container skill is not seeded before migration"

# --- land (patch): append a labeled subsection, no clobber (Part 3) -----------

# Patch a FLEET learned skill: appends the labeled `## ` subsection without
# clobbering the original body, removes the cited raw source, and updates the
# existing canonical pointer in place instead of appending a second pointer.
mkdir -p "$AC_HOME/skills/patch-target"
printf -- '---\nname: patch-target\ndescription: an existing learned skill.\nmetadata:\n  origin: learned\n  landed: 1\n---\n# patch-target\n\nOriginal body line, keep me.\n' \
  >"$AC_HOME/skills/patch-target/SKILL.md"
printf '## Pending\n\n### 2026-07-19 - fam (chief)\n- LESSON: also handle the edge case, always.\n\n## Distilled\n\n- [distilled -> patch-target] sources=2 updated=2026-07-18 ([skill](../skills/patch-target/SKILL.md); [evidence](learnings-archive/patch-target.md))\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: patch\n'
  printf 'name: patch-target\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-19\tedge-case\t- LESSON: also handle the edge case, always.\n'
  printf '===patch===\n'
  printf '## Edge case\n\nAlso handle the edge case, always.\n'
} >"$TMP/cand-patch.md"
"$BIN/ac-learn.sh" land "$TMP/cand-patch.md"

tgt="$AC_HOME/skills/patch-target/SKILL.md"
grep -qxF '## Edge case' "$tgt" || fail "patch appended the labeled subsection heading"
grep -qF 'Also handle the edge case, always.' "$tgt" || fail "patch appended the addition body"
grep -qF 'Original body line, keep me.' "$tgt" || fail "patch did NOT clobber the original body"
grep -qF -- '- [distilled -> patch-target] sources=3 updated=2026-07-19 ([skill](../skills/patch-target/SKILL.md); [evidence](learnings-archive/patch-target.md))' \
  "$AC_HOME/records/learnings.md" || fail "patch updates the canonical pointer source count and date"
assert_eq "$(grep -c '\[distilled -> patch-target\]' "$AC_HOME/records/learnings.md")" "1" \
  "patching never appends a second active pointer"
if grep -qF -- '- LESSON: also handle the edge case, always.' "$AC_HOME/records/learnings.md"; then
  fail "the verbatim source bullet is gone after a patch land"
fi
grep -qF -- '- LESSON: also handle the edge case, always.' \
  "$AC_HOME/records/learnings-archive/patch-target.md" \
  || fail "patch source survives verbatim in the per-skill archive"

# --- the ledger rewrite is EXACT: no undeclared byte moves -------------------

# A correct transaction is a FIXED POINT outside the two regions its plan
# declares (the cited source bullet it compacts, and the one pointer row it
# updates). Run it against the canonical shape AND against the accreted shape a
# live ledger is already in - surplus frame blanks are undeclared bytes too, so
# a rewrite that tidies them away is as broad as one that adds them. `cmp` over
# whole files, not a blank-line count and not "$(cat ...)" (which would delete
# the trailing newlines the comparison is supposed to pin).
mkdir -p "$AC_HOME/skills/exact-skill" "$AC_HOME/records/learnings-archive"
printf -- '---\nname: exact-skill\ndescription: an existing learned skill.\nmetadata:\n  origin: learned\n  landed: "1"\n---\n# exact-skill\n\nOriginal body.\n' \
  >"$AC_HOME/skills/exact-skill/SKILL.md"
# The archive DECLARES the two sources the pointer below claims: an archive
# holding N sources always carries their `source-count:` blocks, so a bare
# header paired with `sources=2` is a state no transaction can produce - and
# one learn_pointer_evidence_check now refuses.
printf '# Learning Evidence: exact-skill\n\n## 2026-07-18T00:00:00Z - tx0\n\nsource-count: 2\n' \
  >"$AC_HOME/records/learnings-archive/exact-skill.md"
blanks() { local i=0; while [ "$i" -lt "$1" ]; do printf '\n'; i=$((i + 1)); done; }
exact_ledger() {  # exact_ledger <surplus> <cited-bullet-or-empty> <sources> <updated>
  printf '# Learning Ledger\n\n## Pending\n\n'
  blanks "$1"
  printf '### 2026-07-19 - fam (chief)\n'
  printf -- '- LESSON: uncited bullet, keep me verbatim.\n'
  [ -z "$2" ] || printf -- '%s\n' "$2"
  printf '\n### 2026-07-20 - other (chief)\n'
  printf -- '- LESSON: a second section, keep its blank separator.\n'
  # A SECOND pending record carrying byte-identical text. The candidate cites
  # the source once, so exactly one occurrence is declared and this one must
  # survive: set-membership removal would take both and lose an undeclared
  # pending source.
  printf -- '- LESSON: cited bullet, compact me.\n'
  printf '\n'
  blanks "$1"
  printf '## Distilled\n\n'
  printf -- '- [distilled -> exact-skill] sources=%s updated=%s ([skill](../skills/exact-skill/SKILL.md); [evidence](learnings-archive/exact-skill.md))\n' \
    "$3" "$4"
}
exact_sources=2
for surplus in 0 4; do
  exact_ledger "$surplus" '- LESSON: cited bullet, compact me.' "$exact_sources" 2026-07-18 \
    >"$AC_HOME/records/learnings.md"
  {
    printf 'kind: patch\n'
    printf 'name: exact-skill\n'
    printf 'approved: 1700000000\n'
    printf '===sources===\n'
    printf '2026-07-19\texact\t- LESSON: cited bullet, compact me.\n'
    printf '===patch===\n'
    printf '## Exact %s\n\nbody.\n' "$surplus"
  } >"$TMP/cand-exact.md"
  "$BIN/ac-learn.sh" land "$TMP/cand-exact.md"
  exact_sources=$((exact_sources + 1))
  exact_ledger "$surplus" '' "$exact_sources" 2026-07-19 >"$TMP/exact-want.md"
  cmp -s "$TMP/exact-want.md" "$AC_HOME/records/learnings.md" || {
    diff "$TMP/exact-want.md" "$AC_HOME/records/learnings.md" >&2 || true
    fail "the rewrite moved a byte outside the compacted source and the pointer row (surplus=$surplus)"
  }
done

# The terminal state of the compaction loop is an EMPTY `## Pending`, and the
# seam arithmetic special-cases it. Both writer-producible spacings - one blank
# separating the markers, and the accreted three - must be fixed points.
for empty_gap in 1 3; do
  {
    printf '# Learning Ledger\n\n## Pending\n\n'
    blanks $((empty_gap - 1))
    printf '## Distilled\n\n'
    printf -- '- [distilled -> exact-skill] sources=%s updated=2026-07-19 ([skill](../skills/exact-skill/SKILL.md); [evidence](learnings-archive/exact-skill.md))\n' \
      "$exact_sources"
  } >"$TMP/exact-want.md"
  cp "$TMP/exact-want.md" "$AC_HOME/records/learnings.md"
  {
    printf 'kind: patch\n'
    printf 'name: exact-skill\n'
    printf 'approved: 1700000000\n'
    printf '===sources===\n'
    printf '===patch===\n'
    printf '## Empty %s\n\nbody.\n' "$empty_gap"
  } >"$TMP/cand-empty.md"
  "$BIN/ac-learn.sh" land "$TMP/cand-empty.md"
  # A sourceless patch dates the pointer today; every other byte must hold.
  sed "s/updated=2026-07-19/updated=$(date -u +%Y-%m-%d)/" "$TMP/exact-want.md" \
    >"$TMP/exact-want-today.md"
  cmp -s "$TMP/exact-want-today.md" "$AC_HOME/records/learnings.md" || {
    diff "$TMP/exact-want-today.md" "$AC_HOME/records/learnings.md" >&2 || true
    fail "an empty Pending section is not a fixed point (blank gap=$empty_gap)"
  }
done

# --- the index never promises an archive the transaction does not create -----

# A legacy rung-qualified pointer aggregates into a canonical row for a skill
# that never had a per-skill archive; the row must not link evidence that does
# not exist. The rewritten skill's own archive IS created by this transaction,
# so its link stays.
{
  printf '# Learning Ledger\n\n## Pending\n\n'
  printf '### 2026-07-19 - fam (chief)\n'
  printf -- '- LESSON: promise bullet, compact me.\n'
  printf '\n## Distilled\n\n'
  printf -- '- 2026-07-01 [distilled -> ghost-skill @fleet] sources=4\n'
} >"$AC_HOME/records/learnings.md"
{
  printf 'kind: skill\n'
  printf 'name: promise-skill\n'
  printf 'description: Prove the index only promises evidence that exists.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-19\tpromise\t- LESSON: promise bullet, compact me.\n'
  printf '===skill===\n'
  printf '# promise-skill\n\nbody.\n'
} >"$TMP/cand-promise.md"
"$BIN/ac-learn.sh" land "$TMP/cand-promise.md"
grep -qF -- '- [distilled -> promise-skill] sources=1 updated=2026-07-19 ([skill](../skills/promise-skill/SKILL.md); [evidence](learnings-archive/promise-skill.md))' \
  "$AC_HOME/records/learnings.md" \
  || fail "the archive this transaction creates keeps its evidence link"
grep -qF -- '- [distilled -> ghost-skill] sources=4 updated=2026-07-01 ([skill](../skills/ghost-skill/SKILL.md))' \
  "$AC_HOME/records/learnings.md" \
  || fail "a pointer with no archive on disk is written without an evidence link"
while IFS= read -r promised; do
  assert_file "$AC_HOME/records/$promised" "the index only links evidence that exists"
done < <(grep -o 'learnings-archive/[a-z0-9-]*\.md' "$AC_HOME/records/learnings.md")

# Variant: a legacy CONTAINER origin:learned target remains readable but is no
# longer a normal patch destination. The refusal preserves both target and
# source ledger and names the migration path.
contsk="$(dirname "$AC_HOME")/.claude/skills"
mkdir -p "$contsk/cont-patch-target"
printf -- '---\nname: cont-patch-target\ndescription: a promoted learned skill.\nmetadata:\n  origin: learned\n  landed: 1\n---\n# cont-patch-target\n\nPromoted body, keep me.\n' \
  >"$contsk/cont-patch-target/SKILL.md"
printf '## 2026-07-19 - fam (chief)\n- LESSON: container patch target bullet.\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: patch\n'
  printf 'name: cont-patch-target\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-19\tcont-hook\t- LESSON: container patch target bullet.\n'
  printf '===patch===\n'
  printf '## Container addition\n\nThe container skill gained a behaviour.\n'
} >"$TMP/cand-cont-patch.md"
ctgt="$contsk/cont-patch-target/SKILL.md"
ctgt_before="$(cat "$ctgt")"
ledger_before="$(cat "$AC_HOME/records/learnings.md")"
rc=0
patch_out="$("$BIN/ac-learn.sh" land "$TMP/cand-cont-patch.md" 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a container-only learned skill must not be patched"
assert_contains "$patch_out" "fleet-local" "container patch refusal names the required ownership"
assert_contains "$patch_out" "retired and never read" "container patch refusal says the container store is retired"
assert_eq "$(cat "$ctgt")" "$ctgt_before" "container target stays byte-identical"
assert_eq "$(cat "$AC_HOME/records/learnings.md")" "$ledger_before" "container patch refusal preserves the raw source"

# --- patch target pre-validation reject cases (Part 3) ------------------------

# Nonexistent target -> refused, nothing written.
{
  printf 'kind: patch\n'
  printf 'name: no-such-skill\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '===patch===\n'
  printf '## X\n\nbody.\n'
} >"$TMP/cand-patch-missing.md"
assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-patch-missing.md"
assert_no_file "$AC_HOME/skills/no-such-skill/SKILL.md" "no target created for a patch naming a nonexistent skill"

# Patch body with no `## ` heading -> refused, target body untouched.
mkdir -p "$AC_HOME/skills/nohead-target"
printf -- '---\nname: nohead-target\ndescription: a learned skill.\nmetadata:\n  origin: learned\n---\n# nohead-target\n\nUntouched body.\n' \
  >"$AC_HOME/skills/nohead-target/SKILL.md"
nohead_before="$(cat "$AC_HOME/skills/nohead-target/SKILL.md")"
printf '## 2026-07-19 - fam (chief)\n- LESSON: nohead bullet.\n' >"$AC_HOME/records/learnings.md"
{
  printf 'kind: patch\n'
  printf 'name: nohead-target\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-19\tnohead\t- LESSON: nohead bullet.\n'
  printf '===patch===\n'
  printf 'no heading here, just prose.\n'
} >"$TMP/cand-nohead.md"
assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-nohead.md"
assert_eq "$(cat "$AC_HOME/skills/nohead-target/SKILL.md")" "$nohead_before" "a headingless patch body leaves the target untouched"

# A container target that is NOT origin:learned -> refused (patch-before-new
# must never extend a built-in skill).
builtincont="$(dirname "$AC_HOME")/.claude/skills"
mkdir -p "$builtincont/builtin-noorigin"
printf -- '---\nname: builtin-noorigin\ndescription: a built-in skill.\n---\n# builtin-noorigin\n\nDo not touch.\n' \
  >"$builtincont/builtin-noorigin/SKILL.md"
noorigin_before="$(cat "$builtincont/builtin-noorigin/SKILL.md")"
{
  printf 'kind: patch\n'
  printf 'name: builtin-noorigin\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '===patch===\n'
  printf '## X\n\nbody.\n'
} >"$TMP/cand-noorigin.md"
assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-noorigin.md"
assert_eq "$(cat "$builtincont/builtin-noorigin/SKILL.md")" "$noorigin_before" "a non-learned container skill is never patched"

# --- note: a landing lesson lands where the transaction READS it ------------

# Every instruction site used to say "append your durable lessons to
# records/learnings.md" and name no section, so an actor appended at
# end-of-file - AFTER `## Distilled`, the one region learn_ledger_split drops.
# The two legs below hold everything constant except WHERE the identical
# lesson is written, and run the same transaction over both.
note_ledger() {  # note_ledger <extra-line-after-the-marker>
  printf '# Learning Ledger\n\n## Pending\n\n'
  printf '### 2026-07-19 - fam (chief)\n'
  printf -- '- LESSON: note-cited bullet, compact me.\n'
  printf '\n## Distilled\n\n'
  printf -- '- [distilled -> note-skill] sources=1 updated=2026-07-18 ([skill](../skills/note-skill/SKILL.md))\n'
  [ -z "$1" ] || printf -- '%s\n' "$1"
}
note_candidate() {
  printf 'kind: skill\n'
  printf 'name: note-target\n'
  printf 'description: Prove a landing lesson survives one transaction.\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-19\tnote\t- LESSON: note-cited bullet, compact me.\n'
  printf '===skill===\n'
  printf '# note-target\n\nbody.\n'
}
note_lesson='- LESSON: a landing lesson that must survive the next transaction.'

# LEG A - the pre-fix habit: hand-append at end-of-file. The lesson is lost.
rm -rf "$AC_HOME/skills/note-target" "$AC_HOME/records/learnings-archive/note-target.md"
note_ledger "$note_lesson" >"$AC_HOME/records/learnings.md"
note_candidate >"$TMP/cand-note.md"
"$BIN/ac-learn.sh" land "$TMP/cand-note.md"
if grep -qxF -- "$note_lesson" "$AC_HOME/records/learnings.md"; then
  fail "leg A must reproduce the defect: an end-of-file append is dropped by the transaction"
fi

# LEG B - the shipped way: `ac-learn.sh note` places it under `## Pending`.
rm -rf "$AC_HOME/skills/note-target" "$AC_HOME/records/learnings-archive/note-target.md"
note_ledger '' >"$AC_HOME/records/learnings.md"
"$BIN/ac-learn.sh" note "$note_lesson" >/dev/null
note_at="$(grep -nxF -- "$note_lesson" "$AC_HOME/records/learnings.md" | cut -d: -f1)"
note_marker="$(grep -nx '## Distilled' "$AC_HOME/records/learnings.md" | cut -d: -f1)"
[ -n "$note_at" ] || fail "note appends the lesson to the ledger"
[ "$note_at" -lt "$note_marker" ] \
  || fail "note places the lesson under ## Pending (line $note_at is not above the marker at $note_marker)"
note_candidate >"$TMP/cand-note.md"
"$BIN/ac-learn.sh" land "$TMP/cand-note.md"
grep -qxF -- "$note_lesson" "$AC_HOME/records/learnings.md" \
  || fail "a lesson placed by note SURVIVES the transaction that deletes an end-of-file append"

# note is a PURE INSERTION: it may add lines and must never drop or rewrite
# one. Everything the transaction has not consumed is still a pending source.
note_ledger '' >"$AC_HOME/records/learnings.md"
cp "$AC_HOME/records/learnings.md" "$TMP/note-before.md"
"$BIN/ac-learn.sh" note '' '### 2026-07-20 - fam (chief)' "$note_lesson" >/dev/null
diff "$TMP/note-before.md" "$AC_HOME/records/learnings.md" >"$TMP/note-diff" || true
if grep -q '^<' "$TMP/note-diff"; then
  cat "$TMP/note-diff" >&2
  fail "note removed or rewrote an existing ledger line"
fi
assert_eq "$(grep -c '^>' "$TMP/note-diff")" "3" "note added exactly the three lines it was given"

# A second section marker would make learn_ledger_split treat the whole index
# as the distilled region - refuse it rather than write it.
cp "$AC_HOME/records/learnings.md" "$TMP/note-guard-before.md"
assert_fails "$BIN/ac-learn.sh" note '## Distilled'
assert_eq "$(cat "$AC_HOME/records/learnings.md")" "$(cat "$TMP/note-guard-before.md")" \
  "a refused note leaves the ledger untouched"

# Absent ledger: note mints the canonical frame rather than failing, and the
# lesson still lands inside `## Pending`.
rm -f "$AC_HOME/records/learnings.md"
"$BIN/ac-learn.sh" note "$note_lesson" >/dev/null
grep -qx '## Pending' "$AC_HOME/records/learnings.md" || fail "note mints '## Pending' on an absent ledger"
grep -qxF -- "$note_lesson" "$AC_HOME/records/learnings.md" || fail "note writes the lesson into a minted ledger"

# --- a pointer can never claim more sources than its archive declares -------

# `learn_ledger_split` aggregates `counts[name] += count` over every pointer row
# sharing a name, so a duplicated row silently inflates a count and nothing ever
# reconciled it against the evidence the row links. When the archive EXISTS its
# `source-count:` lines are that evidence, and the transaction must refuse
# rather than publish a pointer that contradicts them.
mkdir -p "$AC_HOME/skills/evi-skill" "$AC_HOME/records/learnings-archive"
printf -- '---\nname: evi-skill\ndescription: an existing learned skill.\nmetadata:\n  origin: learned\n  landed: "1"\n---\n# evi-skill\n\nOriginal body.\n' \
  >"$AC_HOME/skills/evi-skill/SKILL.md"
evi_ledger() {  # evi_ledger <sources>
  printf '# Learning Ledger\n\n## Pending\n\n'
  printf '### 2026-07-19 - fam (chief)\n'
  printf -- '- LESSON: evidence bullet, compact me.\n'
  printf '\n## Distilled\n\n'
  printf -- '- [distilled -> evi-skill] sources=%s updated=2026-07-18 ([skill](../skills/evi-skill/SKILL.md); [evidence](learnings-archive/evi-skill.md))\n' "$1"
}
evi_candidate() {
  printf 'kind: patch\n'
  printf 'name: evi-skill\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-19\tevi\t- LESSON: evidence bullet, compact me.\n'
  printf '===patch===\n'
  printf '## Evidence\n\nbody.\n'
}
evi_candidate >"$TMP/cand-evi.md"

# CONTRADICTION: the archive declares 2 sources, the pointer claims 5.
printf '# Learning Evidence: evi-skill\n\n## 2026-07-18T00:00:00Z - tx0\n\nsource-count: 2\n' \
  >"$AC_HOME/records/learnings-archive/evi-skill.md"
evi_ledger 5 >"$AC_HOME/records/learnings.md"
evi_before="$(cat "$AC_HOME/records/learnings.md")"
evi_arch_before="$(cat "$AC_HOME/records/learnings-archive/evi-skill.md")"
assert_fails "$BIN/ac-learn.sh" land "$TMP/cand-evi.md"
assert_eq "$(cat "$AC_HOME/records/learnings.md")" "$evi_before" \
  "a contradictory pointer refuses the transaction and leaves the ledger untouched"
assert_eq "$(cat "$AC_HOME/records/learnings-archive/evi-skill.md")" "$evi_arch_before" \
  "a refused transaction writes nothing to the archive either"

# AGREEMENT: the same shape with a pointer the archive backs still lands, so
# the guard discriminates on the count and not merely on having an archive.
evi_ledger 2 >"$AC_HOME/records/learnings.md"
"$BIN/ac-learn.sh" land "$TMP/cand-evi.md"
grep -qF -- '- [distilled -> evi-skill] sources=3 updated=2026-07-19' "$AC_HOME/records/learnings.md" \
  || fail "a pointer its archive backs still publishes"

# NO ARCHIVE: nothing to reconcile against, so the pre-existing count is carried
# forward untouched and the transaction proceeds (the row is written without an
# [evidence] link, which is already the honest behaviour).
rm -f "$AC_HOME/records/learnings-archive/noarch-skill.md"
mkdir -p "$AC_HOME/skills/noarch-skill"
printf -- '---\nname: noarch-skill\ndescription: an existing learned skill.\nmetadata:\n  origin: learned\n  landed: "1"\n---\n# noarch-skill\n\nOriginal body.\n' \
  >"$AC_HOME/skills/noarch-skill/SKILL.md"
{
  printf '# Learning Ledger\n\n## Pending\n\n'
  printf '### 2026-07-19 - fam (chief)\n'
  printf -- '- LESSON: no-archive bullet, compact me.\n'
  printf '\n## Distilled\n\n'
  printf -- '- [distilled -> noarch-skill] sources=5 updated=2026-07-18 ([skill](../skills/noarch-skill/SKILL.md))\n'
} >"$AC_HOME/records/learnings.md"
{
  printf 'kind: patch\n'
  printf 'name: noarch-skill\n'
  printf 'approved: 1700000000\n'
  printf '===sources===\n'
  printf '2026-07-19\tnoarch\t- LESSON: no-archive bullet, compact me.\n'
  printf '===patch===\n'
  printf '## No archive\n\nbody.\n'
} >"$TMP/cand-noarch.md"
"$BIN/ac-learn.sh" land "$TMP/cand-noarch.md"
grep -qF -- '- [distilled -> noarch-skill] sources=6 updated=2026-07-19' "$AC_HOME/records/learnings.md" \
  || fail "a skill with no archive on disk reconciles against nothing and still lands"

pass
