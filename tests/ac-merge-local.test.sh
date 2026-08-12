#!/usr/bin/env bash
# ac-merge-local.test.sh - land a local-only task by fast-forwarding the
# project's default branch to crew/<id>. Covers: clean ff lands; TRACKED
# working-tree dirt is refused with the offending path named - INCLUDING a
# .gitignore whose sole dirt is the worktree pool's /.crew/ line. There is no
# .gitignore special case: ac-tree.sh ignores /.crew/ per-clone via
# .git/info/exclude (never the tracked .gitignore), so a local-only land never
# self-inflicts .gitignore dirt. UNTRACKED dirt does not block a land (the
# incoming commits cannot touch a path they never mention); a genuine
# untracked/incoming path collision instead fails deeper, from git's own
# merge attempt, on both the --ff-only and --no-ff paths, cleanly (no
# stranded MERGE_HEAD, $default untouched).
# Landing interlock (ac-lib.sh landing-ledger block): the land appends one
# state/.landings record per landed file and prunes >7d records; a <24h
# foreign-family overlap warns (LANDING-OVERLAP, merge still lands); own-family
# and >24h records stay silent. The landed set is the branch's OWN commits
# (three-dot $default...$branch), so a land where main has advanced past the
# branch (multi-family history) records only this family's files, never a
# sibling family's whose file the naive two-dot diff would over-report.
# Pure git + meta - no backend needed.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# mk_meta <id> <repo> - the minimal crewmate meta ac-merge-local.sh reads.
mk_meta() {
  local m="$AC_HOME/state/$1.meta"
  mkdir -p "$AC_HOME/state"
  printf 'project_dir=%s\n' "$2" >"$m"
  printf 'worktree=%s\n' "$2/.crew/worktrees/1" >>"$m"
}

# add_crew <repo> <id> - branch crew/<id> one commit ahead of main, leaving
# the primary checkout back on a clean main.
add_crew() {
  local repo="$1" id="$2"
  git -C "$repo" checkout -q -b "crew/$id"
  printf 'crew change\n' >"$repo/crewfile.txt"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "crew work"
  git -C "$repo" checkout -q main
}

# diverge_main <repo> <file> <content> - commit an independent change on main
# AFTER add_crew already returned it there, so crew/<id> and main diverge and
# a bare ff-only becomes impossible. Same file as the crew commit -> conflict
# on --no-ff; a different file -> a clean --no-ff merge.
diverge_main() {
  local repo="$1" file="$2" content="$3"
  printf '%s\n' "$content" >"$repo/$file"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "main advanced: $file"
}

v2_marker() {
  # v2_marker <path> <sha> <profile-key> <scope> <app> <profile-sha>
  {
    printf 'schema=agentcrew.qa-attestation/v2\noutcome=passed\n'
    printf 'run=test-run\ntask=test-task\ncompleted_at=2026-07-24T00:00:00Z\n'
    printf 'source_sha=%s\nprofile_key=%s\n' "$2" "$3"
    printf 'profile_sha256=%s\nconfig_sha256=config-hash\n' "$6"
    printf 'cases_passed=1\ncases_total=1\nscope=%s\napp=%s\n' "$4" "$5"
  } >"$1"
}

# ---- Case 1: clean fast-forward works --------------------------------------
r1="$(make_repo c1repo)"
add_crew "$r1" c1
mk_meta c1 "$r1"
out="$("$BIN/ac-merge-local.sh" c1)"
assert_contains "$out" "fast-forwarded" "clean ff prints result"
assert_eq "$(git -C "$r1" rev-parse main)" "$(git -C "$r1" rev-parse crew/c1)" "main ff'd to crew/c1"
assert_file "$r1/crewfile.txt" "crew work present after clean ff"

# ---- Case 2: unrelated dirt -> refused, path named -------------------------
r2="$(make_repo c2repo)"
add_crew "$r2" c2
before="$(git -C "$r2" rev-parse main)"
printf 'tampered\n' >"$r2/file.txt"            # unrelated working-tree change
mk_meta c2 "$r2"
out="$("$BIN/ac-merge-local.sh" c2 2>&1)" && fail "expected refusal on unrelated dirt"
assert_contains "$out" "file.txt" "refusal names the dirty path"
assert_eq "$(git -C "$r2" rev-parse main)" "$before" "main untouched"
assert_no_file "$r2/crewfile.txt" "crew work not landed on refusal"

# ---- Case 3: .gitignore dirt but content is NOT solely /.crew/ -> refused ---
r3="$(make_repo c3repo)"
printf 'node_modules\n' >"$r3/.gitignore"
git -C "$r3" add .gitignore
git -C "$r3" commit -qm "add gitignore"
add_crew "$r3" c3
printf 'node_modules\n/.crew/\nsecret\n' >"$r3/.gitignore"   # pool line PLUS extra content
mk_meta c3 "$r3"
out="$("$BIN/ac-merge-local.sh" c3 2>&1)" && fail "expected refusal when added content is not solely /.crew/"
assert_contains "$out" ".gitignore" "refusal names .gitignore"
assert_no_file "$r3/crewfile.txt" "crew work not landed when .gitignore has extra content"

# ---- Case 4: sole dirt is a TRACKED .gitignore modified to exactly /.crew/ -
#             -> REFUSED. The former sanctioned exception is gone: ac-tree.sh
#             ignores the pool via .git/info/exclude, so a /.crew/ line in the
#             tracked .gitignore is now ordinary dirt and is refused like
#             anything else. Dirt is TRACKED here (committed first, then
#             modified, same shape as Case 3) so this proves the "exception is
#             gone" assertion on tracked dirt, independent of the untracked-
#             dirt policy proven by Case cu1 below.
r4="$(make_repo c4repo)"
printf 'node_modules\n' >"$r4/.gitignore"
git -C "$r4" add .gitignore
git -C "$r4" commit -qm "add gitignore"
add_crew "$r4" c4
before="$(git -C "$r4" rev-parse main)"
printf '/.crew/\n' >"$r4/.gitignore"           # tracked modification: sole dirt is /.crew/ only
mk_meta c4 "$r4"
out="$("$BIN/ac-merge-local.sh" c4 2>&1)" && fail "expected refusal on tracked /.crew/-only .gitignore dirt"
assert_contains "$out" ".gitignore" "refusal names .gitignore"
assert_eq "$(git -C "$r4" rev-parse main)" "$before" "main untouched by /.crew/-only refusal"
assert_no_file "$r4/crewfile.txt" "crew work not landed on /.crew/-only refusal"

# ---- Case cu1: sole dirt is UNTRACKED -> lands, untracked file untouched ----
#      An untracked file the incoming commits never touch is not the hazard
#      the dirty check guards against; git's own fast-forward cannot collide
#      with it, so the land proceeds and the stray file survives as-is.
rcu1="$(make_repo cu1repo)"
add_crew "$rcu1" cu1
printf 'stray scratch note\n' >"$rcu1/untracked.txt"
mk_meta cu1 "$rcu1"
out="$("$BIN/ac-merge-local.sh" cu1 2>&1)"
assert_contains "$out" "fast-forwarded" "sole untracked dirt does not block the land"
assert_eq "$(git -C "$rcu1" rev-parse main)" "$(git -C "$rcu1" rev-parse crew/cu1)" "main ff'd to crew/cu1 despite untracked dirt"
assert_file "$rcu1/crewfile.txt" "crew work present after landing past untracked dirt"
assert_file "$rcu1/untracked.txt" "the untracked file survives the land"
assert_eq "$(cat "$rcu1/untracked.txt")" "stray scratch note" "the untracked file's content is untouched"

# ---- Case ccol1: untracked file COLLIDES with an incoming path, --ff-only --
#      path -> git itself refuses the fast-forward before touching anything,
#      since removing the up-front refusal moves this failure deeper into git.
#      DISPUTED: whether git's own --ff-only merge blocks on an untracked
#      collision without creating any mid-merge state.
#      HELD-CONSTANT: same repo/branch shape as Case cu1 (a plain ff-eligible
#      crew branch), only the untracked file's PATH changes (it now matches
#      the incoming commit's path instead of being unrelated).
rccol1="$(make_repo ccol1repo)"
add_crew "$rccol1" ccol1
before="$(git -C "$rccol1" rev-parse main)"
printf 'untracked stray, not the crew content\n' >"$rccol1/crewfile.txt"   # same path add_crew's commit adds
mk_meta ccol1 "$rccol1"
out="$("$BIN/ac-merge-local.sh" ccol1 2>&1)" && fail "expected refusal on an untracked/incoming path collision (--ff-only)"
assert_contains "$out" "crewfile.txt" "the collision refusal names the colliding path"
assert_contains "$out" "fast-forward of" "the refusal is wrapped in the helper's own voice, not bare git stderr"
assert_contains "$out" "main untouched" "the wrapped refusal states the default branch was untouched"
assert_eq "$(git -C "$rccol1" rev-parse main)" "$before" "main untouched by the ff-only collision refusal"
git -C "$rccol1" rev-parse -q --verify MERGE_HEAD >/dev/null \
  && fail "MERGE_HEAD must not exist after an ff-only collision refusal"
assert_eq "$(cat "$rccol1/crewfile.txt")" "untracked stray, not the crew content" "the untracked file is left exactly as it was"

# ---- Case ccol2: same collision, forced onto the --no-ff path -------------
#      main is diverged first so the branch is not fast-forwardable; the
#      --no-ff --no-commit attempt hits the same untracked-collision refusal,
#      which creates no MERGE_HEAD (git never enters the merge), so it must
#      fall into the "never started" shape, not the "conflict" shape.
#      DISPUTED: whether --no-ff --no-commit also refuses an untracked
#      collision with no MERGE_HEAD created (vs. entering a real conflict).
#      HELD-CONSTANT: same diverge_main + add_crew shape as the existing
#      unrelated-history/conflict --no-ff cases above; only the untracked
#      file's path (matching the incoming commit) changes.
rccol2="$(make_repo ccol2repo)"
add_crew "$rccol2" ccol2
diverge_main "$rccol2" mainfile.txt "main moved, unrelated file"
before="$(git -C "$rccol2" rev-parse main)"
printf 'untracked stray, not the crew content\n' >"$rccol2/crewfile.txt"
mk_meta ccol2 "$rccol2"
out="$("$BIN/ac-merge-local.sh" ccol2 --no-ff 2>&1)" && fail "expected refusal on an untracked/incoming path collision (--no-ff)"
assert_contains "$out" "crewfile.txt" "the --no-ff collision refusal names the colliding path"
assert_eq "$(git -C "$rccol2" rev-parse main)" "$before" "main untouched by the --no-ff collision refusal"
assert_eq "$(git -C "$rccol2" symbolic-ref --short HEAD)" "main" "checkout stays on default branch after the --no-ff collision refusal"
git -C "$rccol2" rev-parse -q --verify MERGE_HEAD >/dev/null \
  && fail "MERGE_HEAD must not exist after a --no-ff collision refusal"
assert_eq "$(cat "$rccol2/crewfile.txt")" "untracked stray, not the crew content" "the untracked file is left exactly as it was"

# ---- Case 5: landing ledger - append shape + >7d prune ----------------------
ledger="$AC_HOME/state/.landings"
now="$(date +%s)"
r5="$(make_repo c5repo)"
add_crew "$r5" c5
mk_meta c5 "$r5"
printf '%s\told-fam\tstale.txt\n' "$((now - 8 * 86400))" >"$ledger"   # >7d: pruned
"$BIN/ac-merge-local.sh" c5 >/dev/null
grep -Eq "^[0-9]+	c5	crewfile.txt$" "$ledger" || fail "ledger records epoch<TAB>family<TAB>path for the landed file"
grep -q "old-fam" "$ledger" && fail "append prunes records older than 7 days"
assert_eq "$(wc -l <"$ledger" | tr -d ' ')" "1" "ledger holds exactly the landed file"

# ---- Case 6: <24h foreign-family overlap -> LANDING-OVERLAP warn, still lands
r6="$(make_repo c6repo)"
add_crew "$r6" c6
mk_meta c6 "$r6"
printf '%s\tdrain-race\tcrewfile.txt\n' "$((now - 3600))" >"$ledger"
out="$("$BIN/ac-merge-local.sh" c6 2>&1)"
assert_contains "$out" "LANDING-OVERLAP: crewfile.txt" "warn names the overlapping file"
assert_contains "$out" "family drain-race" "warn names the prior family"
assert_contains "$out" "data/drain-race/room.md" "warn names the prior family's room as required reading"
assert_eq "$(git -C "$r6" rev-parse main)" "$(git -C "$r6" rev-parse crew/c6)" "warn-only: merge still lands"

# ---- Case 7: own family (via stage suffix) and >24h entries stay silent -----
# The crewmate commits to the FAMILY branch crew/c7 (ac_crew_branch("c7-ship")
# == crew/c7, same derivation ac-brief.sh names in the brief) - never a
# hand-made crew/c7-ship alias.
r7="$(make_repo c7repo)"
add_crew "$r7" c7
# ac_family_of_id trusts a stage suffix only once its nested brief dir exists
# (family-of-id-suffix-collision) - a real c7-ship task always has one, since
# ac-brief.sh mkdirs it before any crewmate can commit.
mkdir -p "$AC_HOME/data/c7/ship"
mk_meta c7-ship "$r7"
printf '%s\tc7\tcrewfile.txt\n%s\tstranger\tcrewfile.txt\n' \
  "$((now - 3600))" "$((now - 25 * 3600))" >"$ledger"   # own family; foreign but >24h
out="$("$BIN/ac-merge-local.sh" c7-ship 2>&1)"
case "$out" in *LANDING-OVERLAP*) fail "own-family and >24h records must not warn" ;; esac
grep -Eq "^[0-9]+	c7	crewfile.txt$" "$ledger" || fail "a staged id lands under its FAMILY (c7-ship -> c7)"
grep -q "stranger" "$ledger" || fail "a >24h but <7d record survives the prune"

# ---- Case: family-scoped id - ac-brief.sh and ac-merge-local.sh AGREE -------
#      on the crew branch name, so no hand-made alias branch is ever needed to
#      land. ac-brief.sh names crew/<family> for a revision id like foo-r2
#      (asserted in tests/ac-brief.test.sh); this proves ac-merge-local.sh
#      looks for that SAME branch, via the shared ac_crew_branch helper.
r15="$(make_repo c15repo)"
add_crew "$r15" foo                                      # the branch the brief actually names
mk_meta foo-r2 "$r15"                                     # a family-scoped revision id
out="$("$BIN/ac-merge-local.sh" foo-r2 2>&1)"
assert_contains "$out" "fast-forwarded" "a family-scoped id lands crew/<family>, no alias branch needed"
assert_eq "$(git -C "$r15" rev-parse main)" "$(git -C "$r15" rev-parse crew/foo)" \
  "main ff'd to crew/foo, the SAME branch ac-brief.sh named for foo-r2"

# ---- Case 8: multi-family history - the landed set is the branch's OWN commits
#             main has advanced PAST crew/c8 (its work already landed, then a
#             SIBLING family landed siblingfile.txt), so crew/c8 is now an
#             ancestor of main and the ff is a no-op. The naive two-dot
#             `git diff main crew/c8` reverse-reports siblingfile.txt - a file
#             this branch never touched - and would stamp it under family c8.
#             The three-dot range records only what THIS branch adds beyond
#             main: nothing here, so no foreign record and no c8 record at all.
r8="$(make_repo c8repo)"
git -C "$r8" checkout -q -b crew/c8
printf 'c8 change\n' >"$r8/c8file.txt"
git -C "$r8" add -A && git -C "$r8" commit -qm "c8 work"
git -C "$r8" checkout -q main
git -C "$r8" merge --ff-only crew/c8 >/dev/null          # main now CONTAINS crew/c8
git -C "$r8" checkout -q -b crew/sibling
printf 'sibling change\n' >"$r8/siblingfile.txt"
git -C "$r8" add -A && git -C "$r8" commit -qm "sibling work"
git -C "$r8" checkout -q main
git -C "$r8" merge --ff-only crew/sibling >/dev/null     # main = base + c8file + siblingfile
mk_meta c8 "$r8"
: >"$ledger"                                             # clean ledger
"$BIN/ac-merge-local.sh" c8 >/dev/null
grep -q "siblingfile.txt" "$ledger" && fail "two-dot over-report: a sibling family's file recorded under c8"
grep -q "c8file.txt" "$ledger" && fail "already-landed work re-recorded: c8's own file is already in main"
assert_eq "$(wc -c <"$ledger" | tr -d ' ')" "0" "no-op multi-family land records nothing (branch adds nothing beyond main)"

# ---- Case 9: the KNOWLEDGE-GAP flag (AC15/AC16) ----------------------------
#              Warn-only and NOT behind the landed[] guard: a family that
#              recorded no repo-knowledge entry is flagged whatever its diff
#              looks like, the exit status is unchanged, and the merge happens.
r9="$(make_repo c9repo)"
add_crew "$r9" c9
mk_meta c9 "$r9"
out="$("$BIN/ac-merge-local.sh" c9 2>&1)"
assert_contains "$out" "KNOWLEDGE-GAP: family c9" "a landing with no knowledge entry is flagged"
assert_contains "$out" "c9repo" "the flag names the project"
assert_contains "$out" "$AC_HOME/records/repo-knowledge/c9repo.md" "the flag names the record path"
assert_eq "$(git -C "$r9" rev-parse main)" "$(git -C "$r9" rev-parse crew/c9)" "the flagged landing still merged"

# AC16: an entry attributable to THIS family silences it - the flag is a
# prompt, not unconditional noise. A sibling family's entry does not count.
r10="$(make_repo c10repo)"
add_crew "$r10" c10
mk_meta c10 "$r10"
mkdir -p "$AC_HOME/records/repo-knowledge"
printf -- '- fact learned something | src: cmd:true | at: deadbeef 2026-07-21 | by: someone-else\n' \
  >"$AC_HOME/records/repo-knowledge/c10repo.md"
out="$("$BIN/ac-merge-local.sh" c10 2>&1)" || fail "the flag must never fail a landing"
assert_contains "$out" "KNOWLEDGE-GAP" "another family's entry does not answer for this one"

r11="$(make_repo c11repo)"
add_crew "$r11" c11
mk_meta c11 "$r11"
printf -- '- fact learned something | src: cmd:true | at: deadbeef 2026-07-21 | by: c11\n' \
  >"$AC_HOME/records/repo-knowledge/c11repo.md"
out="$("$BIN/ac-merge-local.sh" c11 2>&1)"
case "$out" in *KNOWLEDGE-GAP*) fail "a family with an entry must not be flagged" ;; esac
assert_eq "$(git -C "$r11" rev-parse main)" "$(git -C "$r11" rev-parse crew/c11)" "silent landing still merged"

# ...and the entry is still found once the record OUTGROWS a pipe buffer. The
# `awk | grep -q` this replaced was a false positive under the callers'
# `set -o pipefail`: grep -q exits on the first match, the still-writing awk
# takes SIGPIPE, pipefail reports 141, and the flag fired WITH the entry
# present. R6 grows this record with every landing, forever, so every busy
# project reaches that size - and a flag that cries wolf is a flag chiefs
# learn to dismiss.
r14="$(make_repo c14repo)"
add_crew "$r14" c14
mk_meta c14 "$r14"
{ printf -- '- fact the match comes FIRST | src: cmd:true | at: deadbeef 2026-07-21 | by: c14\n'
  i=0
  while [ "$i" -lt 4000 ]; do
    printf -- '- fact filler %s padded so the live section clears 64 KiB well before the end | src: cmd:true | at: deadbeef 2026-07-21 | by: someone-else\n' "$i"
    i=$((i + 1))
  done
} >"$AC_HOME/records/repo-knowledge/c14repo.md"
[ "$(wc -c <"$AC_HOME/records/repo-knowledge/c14repo.md")" -gt 65536 ] \
  || fail "the fixture must exceed one pipe buffer or it proves nothing"
out="$("$BIN/ac-merge-local.sh" c14 2>&1)"
case "$out" in *KNOWLEDGE-GAP*) fail "AC16: the flag fired although the family's entry IS present (large record)" ;; esac
assert_eq "$(git -C "$r14" rev-parse main)" "$(git -C "$r14" rev-parse crew/c14)" "the landing still happened"

# ...and a SUPERSEDED entry does not answer either: history is not a claim.
r12="$(make_repo c12repo)"
add_crew "$r12" c12
mk_meta c12 "$r12"
printf -- '## Superseded\n- fact old news | src: cmd:true | at: deadbeef 2026-07-21 | by: c12\n' \
  >"$AC_HOME/records/repo-knowledge/c12repo.md"
out="$("$BIN/ac-merge-local.sh" c12 2>&1)"
assert_contains "$out" "KNOWLEDGE-GAP" "a superseded entry does not answer the landing flag"

# ---- Case 10: the SCOPED merge gate, driven through the HELPER -------------
#              This is the LAYERING proof, and its location is load-bearing:
#              ac_qa_gate_ok lives in ac-qa-lib.sh but reads the project yaml
#              through ac_yaml_has, which lives in ac-pipeline-lib.sh. A unit
#              test on the function passes even with the helper's source line
#              missing - which is exactly the bug. Only driving the SCRIPT
#              catches it.
mkdir -p "$AC_HOME/projects" "$AC_HOME/records/repo-knowledge"
rg1="$(make_repo g1repo)"
add_crew "$rg1" g1
mk_meta g1 "$rg1"
printf 'qa:
  require_for_ship: true
  scopes:
    orchid:
      seed: "true"
'   >"$AC_HOME/projects/g1repo.yaml"
# Half-migrated: the yaml declares scopes, the record declares none. The
# MISMATCH arm must refuse - never the FLAT arm, which would accept the bare
# marker sitting right there.
# The pool ignores /.crew/ per-clone via info/exclude (never the tracked
# .gitignore), which is what keeps the markers out of `git status`.
printf '/.crew/\n' >>"$rg1/.git/info/exclude"
mkdir -p "$rg1/.crew/qa/passed"
: >"$rg1/.crew/qa/passed/$(git -C "$rg1" rev-parse crew/g1)"
out="$("$BIN/ac-merge-local.sh" g1 2>&1)" && fail "a half-migrated project must refuse the land"
assert_contains "$out" "MODE MISMATCH" "the helper actually executed the two-sided gate"

# Declare the scope, and the bare marker STILL refuses (D14): it names no
# scope+app, so it proves nothing about which profile ran.
printf -- '- scope orchid = orchid-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam
'   >"$AC_HOME/records/repo-knowledge/g1repo.md"
out="$("$BIN/ac-merge-local.sh" g1 2>&1)" && fail "a bare marker must not land a scoped head"
assert_contains "$out" "bare sha-only marker IS on disk" "the bare marker is named, not silently missing"

# A scope+app-bearing marker for the same head lands it, and the gate prints
# the pairs so the chief judges coverage.
g1head="$(git -C "$rg1" rev-parse crew/g1)"
v2_marker "$rg1/.crew/qa/passed/$g1head.orchid.orchid-service" "$g1head" \
  g1repo/orchid/orchid-service orchid orchid-service orchid-profile
out="$("$BIN/ac-merge-local.sh" g1 2>&1)"
assert_contains "$out" "passed profiles" "the passing arm surfaces the proven pairs"
assert_contains "$out" "orchid/orchid-service" "naming the pair"
assert_eq "$(git -C "$rg1" rev-parse main)" "$(git -C "$rg1" rev-parse crew/g1)" "the scoped land happened"
rm -f "$AC_HOME/projects/g1repo.yaml" "$AC_HOME/records/repo-knowledge/g1repo.md"

# ---- Case: the required-profile MATRIX, driven through the HELPER ----------
#      Proves ac-merge-local forwards the task id so the manifest arm bites:
#      a task with two required profiles cannot land after only one passes, and
#      lands once both are present at the crew head.
rgm="$(make_repo matrixrepo)"
add_crew "$rgm" gm1
mk_meta gm1 "$rgm"
gmhead="$(git -C "$rgm" rev-parse crew/gm1)"
gm_before="$(git -C "$rgm" rev-parse main)"
printf 'qa:\n  require_for_ship: true\n' >"$AC_HOME/projects/matrixrepo.yaml"
mkdir -p "$AC_HOME/data/gm1/qa"
printf '{"task":"gm1","source_ref":"","required_profiles":[{"profile_key":"matrixrepo/orchid/orchid-service"},{"profile_key":"matrixrepo/cedar/cedar-service"}]}\n' \
  >"$AC_HOME/data/gm1/qa/manifest.json"
printf '/.crew/\n' >>"$rgm/.git/info/exclude"
mkdir -p "$rgm/.crew/qa/passed"
v2_marker "$rgm/.crew/qa/passed/$gmhead.orchid.orchid-service" "$gmhead" \
  matrixrepo/orchid/orchid-service orchid orchid-service aaaa
out="$("$BIN/ac-merge-local.sh" gm1 2>&1)" && fail "a required-profile manifest must refuse the land after only one profile passes"
assert_contains "$out" "no passing crew-qa attestation" "the matrix arm ran through the helper"
assert_contains "$out" "cedar/cedar-service" "naming the unmet required profile"
assert_eq "$(git -C "$rgm" rev-parse main)" "$gm_before" "main untouched while the matrix is unmet"
v2_marker "$rgm/.crew/qa/passed/$gmhead.cedar.cedar-service" "$gmhead" \
  matrixrepo/cedar/cedar-service cedar cedar-service bbbb
out="$("$BIN/ac-merge-local.sh" gm1 2>&1)"
assert_contains "$out" "required profile" "both present -> the matrix opens the gate"
assert_eq "$(git -C "$rgm" rev-parse main)" "$gmhead" "the matrix-gated land happened"
rm -f "$AC_HOME/projects/matrixrepo.yaml"; rm -rf "$AC_HOME/data/gm1"

# ---- Case: a RETIRED legacy config copy REFUSES the land -------------------
#      Config present at the retired legacy config/projects/<name>.yaml: the
#      merge gate resolves the config first (ac_qa_required) and ac_die's on
#      the retired path, so the SCRIPT exits non-zero and main never moves -
#      a legacy copy is never read and never silently ignored (audit-f7).
mkdir -p "$AC_HOME/config/projects"
rdc="$(make_repo dualcfg)"
add_crew "$rdc" dc1
mk_meta dc1 "$rdc"
dc_main_before="$(git -C "$rdc" rev-parse main)"
printf 'qa:\n  require_for_ship: true\n' >"$AC_HOME/projects/dualcfg.yaml"
printf 'qa:\n  require_for_ship: true\n' >"$AC_HOME/config/projects/dualcfg.yaml"
out="$("$BIN/ac-merge-local.sh" dc1 2>&1)" && fail "a retired legacy config copy must refuse the land, never be picked or ignored silently"
assert_contains "$out" "RETIRED" "the land refuses on the retired legacy copy, naming it"
assert_eq "$(git -C "$rdc" rev-parse main)" "$dc_main_before" "no land happened on a legacy-copy refusal"
rm -f "$AC_HOME/projects/dualcfg.yaml" "$AC_HOME/config/projects/dualcfg.yaml"

# Door: a missing/dead project_dir is silent and still exits 0.
r13="$(make_repo c13repo)"
add_crew "$r13" c13
mk_meta c13 "$r13"
printf -- '- fact x | src: cmd:true | at: deadbeef 2026-07-21 | by: c13\n' \
  >"$AC_HOME/records/repo-knowledge/c13repo.md"
out="$(bash -c ". '$BIN/ac-lib.sh'; ac_knowledge_warn c13 /nonexistent/dir; printf 'rc=%s' \$?" 2>&1)"
assert_eq "$out" "rc=0" "a dead project dir is silent and still returns 0"

# ---- Case: bare invocation on a non-fast-forwardable branch names --no-ff --
#      as the escape hatch instead of surfacing git's bare --ff-only error.
rna="$(make_repo cnarepo)"
add_crew "$rna" cna
diverge_main "$rna" mainfile.txt "main moved"
mk_meta cna "$rna"
main_before="$(git -C "$rna" rev-parse main)"
out="$("$BIN/ac-merge-local.sh" cna 2>&1)" && fail "expected refusal on a non-fast-forwardable branch"
assert_contains "$out" "not fast-forwardable" "the refusal names the ff problem"
assert_contains "$out" "--no-ff" "the refusal names the conflict-free escape hatch"
assert_eq "$(git -C "$rna" rev-parse main)" "$main_before" "main untouched by the bare refusal"
assert_no_file "$rna/crewfile.txt" "crew work not landed on the bare refusal"

# ---- Case: bare invocation under AC_SCOPE (roomchief) does not offer --no-ff -
#      the primary-checkout commit guard (bin/ac-tree.sh D2) refuses a --no-ff
#      merge commit for a scoped actor, so the refusal must not send it down a
#      path that will only fail late - it names the remedies that actor has.
rns="$(make_repo cnsrepo)"
add_crew "$rns" cns
diverge_main "$rns" mainfile.txt "main moved"
mk_meta cns "$rns"
main_before="$(git -C "$rns" rev-parse main)"
out="$(AC_SCOPE=test-family "$BIN/ac-merge-local.sh" cns 2>&1)" && fail "expected refusal on a non-fast-forwardable branch under AC_SCOPE"
assert_contains "$out" "not fast-forwardable" "the scoped refusal names the ff problem"
printf '%s' "$out" | grep -q -- "ac-merge-local.sh cns --no-ff" \
  && fail "the scoped refusal must not recommend running --no-ff (the commit guard refuses it)"
assert_contains "$out" "rebase" "the scoped refusal names the rebase remedy"
assert_contains "$out" "crewchief" "the scoped refusal names the hand-back-to-crewchief remedy"
assert_eq "$(git -C "$rns" rev-parse main)" "$main_before" "main untouched by the scoped refusal"
assert_no_file "$rns/crewfile.txt" "crew work not landed on the scoped refusal"

# ---- Case: --no-ff lands a clean but non-fast-forwardable branch -----------
rnb="$(make_repo cnbrepo)"
add_crew "$rnb" cnb
diverge_main "$rnb" mainfile.txt "main moved, unrelated file"
mk_meta cnb "$rnb"
main_before="$(git -C "$rnb" rev-parse main)"
branch_before="$(git -C "$rnb" rev-parse crew/cnb)"
: >"$ledger"
out="$("$BIN/ac-merge-local.sh" cnb --no-ff 2>&1)"
assert_contains "$out" "merged" "a clean --no-ff land prints its own path in the output"
assert_contains "$out" "--no-ff" "the --no-ff output identifies which path ran"
git -C "$rnb" merge-base --is-ancestor "$main_before" main \
  || fail "main advanced past its pre-merge tip"
git -C "$rnb" merge-base --is-ancestor "$branch_before" main \
  || fail "main now CONTAINS the crew branch tip (not IS its tree)"
assert_file "$rnb/crewfile.txt" "crew work present after the --no-ff land"
assert_file "$rnb/mainfile.txt" "main's own independent file survives the --no-ff land"
assert_eq "$(git -C "$rnb" status --porcelain)" "" "checkout is clean after a successful --no-ff land"
assert_eq "$(git -C "$rnb" symbolic-ref --short HEAD)" "main" "checkout stays on default branch after the --no-ff land"
grep -Eq "^[0-9]+	cnb	crewfile.txt$" "$ledger" \
  || fail "the --no-ff path records the branch's own file to the landing ledger"
grep -q "mainfile.txt" "$ledger" \
  && fail "the --no-ff path must not record main's own independent file under this family"

# ---- Case: --no-ff on a conflicting branch refuses and leaves the checkout -
#      exactly as it found it - clean, on default, not MERGING.
rnc="$(make_repo cncrepo)"
add_crew "$rnc" cnc
diverge_main "$rnc" crewfile.txt "main's conflicting version"   # SAME path -> add/add conflict
mk_meta cnc "$rnc"
main_before="$(git -C "$rnc" rev-parse main)"
out="$("$BIN/ac-merge-local.sh" cnc --no-ff 2>&1)" && fail "expected refusal on a conflicting --no-ff merge"
assert_contains "$out" "crewfile.txt" "the conflict refusal names the conflicting path"
assert_eq "$(git -C "$rnc" rev-parse main)" "$main_before" "main untouched by a conflicting --no-ff refusal"
assert_eq "$(git -C "$rnc" status --porcelain)" "" "checkout is clean after a conflicting --no-ff refusal"
assert_eq "$(git -C "$rnc" symbolic-ref --short HEAD)" "main" "checkout stays on default branch after a conflicting --no-ff refusal"
git -C "$rnc" rev-parse -q --verify MERGE_HEAD >/dev/null \
  && fail "MERGE_HEAD must not remain after a conflicting --no-ff refusal"

# ---- Case: --no-ff on an unrelated-history branch refuses in the helper's --
#      own voice - git refuses to even START this merge (no common ancestor),
#      so no MERGE_HEAD is ever created and `merge --abort` must not be
#      called on this leg (git itself errors on that: "no merge to abort").
rno="$(make_repo cnorepo)"
git -C "$rno" checkout -q --orphan crew/cno
git -C "$rno" rm -qrf . >/dev/null
printf 'orphan crew work\n' >"$rno/crewfile.txt"
git -C "$rno" add -A
git -C "$rno" commit -qm "orphan crew work"
git -C "$rno" checkout -q main
mk_meta cno "$rno"
main_before="$(git -C "$rno" rev-parse main)"
out="$("$BIN/ac-merge-local.sh" cno --no-ff 2>&1)" && fail "expected refusal on an unrelated-history --no-ff merge"
assert_contains "$out" "never started" "the refusal says the merge never started, not that it conflicted"
assert_eq "$(git -C "$rno" rev-parse main)" "$main_before" "main untouched by an unrelated-history --no-ff refusal"
assert_eq "$(git -C "$rno" status --porcelain)" "" "checkout is clean after an unrelated-history --no-ff refusal"
assert_eq "$(git -C "$rno" symbolic-ref --short HEAD)" "main" "checkout stays on default branch after an unrelated-history --no-ff refusal"
git -C "$rno" rev-parse -q --verify MERGE_HEAD >/dev/null \
  && fail "MERGE_HEAD must not exist - git never entered the merge"

# ---- Case: --no-ff when $default already CONTAINS $branch is a truthful --
#      no-op, not a raw git death. Same situation the bare path's --ff-only
#      already lands as a success (case 8 above) - git creates no MERGE_HEAD
#      and there is nothing to commit, so `git commit --no-edit` on it dies
#      "nothing to commit" under set -e unless this is handled explicitly.
rnd="$(make_repo cndrepo)"
add_crew "$rnd" cnd
git -C "$rnd" merge --ff-only crew/cnd >/dev/null   # land it normally first
mk_meta cnd "$rnd"
main_before="$(git -C "$rnd" rev-parse main)"
out="$("$BIN/ac-merge-local.sh" cnd --no-ff 2>&1)" \
  || fail "--no-ff must succeed (exit 0) as a no-op when main already contains the branch"
assert_contains "$out" "already contains" "the no-op output states the truth"
case "$out" in
  *"merged crew/cnd"*) fail "--no-ff no-op must not claim a merge commit was created" ;;
esac
assert_eq "$(git -C "$rnd" rev-parse main)" "$main_before" "main gains no new commit from a --no-ff no-op"
assert_eq "$(git -C "$rnd" status --porcelain)" "" "checkout is clean after a --no-ff no-op"
assert_eq "$(git -C "$rnd" symbolic-ref --short HEAD)" "main" "checkout stays on default branch after a --no-ff no-op"
git -C "$rnd" rev-parse -q --verify MERGE_HEAD >/dev/null \
  && fail "MERGE_HEAD must not exist after a --no-ff no-op"

# ---- Case: --no-ff whose COMMIT is refused (e.g. a pre-commit hook) must --
#      leave the checkout exactly as it found it - clean, on default, no
#      MERGE_HEAD - not stuck mid-merge. The merge itself is clean/no-
#      conflict; a trivial exit-1 hook stands in for any real guard.
rne="$(make_repo cnerepo)"
add_crew "$rne" cne
diverge_main "$rne" mainfile.txt "main moved, unrelated file"
mkdir -p "$rne/.git/hooks"
printf '#!/usr/bin/env bash\nexit 1\n' >"$rne/.git/hooks/pre-commit"
chmod +x "$rne/.git/hooks/pre-commit"
mk_meta cne "$rne"
main_before="$(git -C "$rne" rev-parse main)"
out="$("$BIN/ac-merge-local.sh" cne --no-ff 2>&1)" && fail "expected refusal when the commit hook rejects the --no-ff merge"
assert_contains "$out" "refused" "the refusal names that the commit was refused"
assert_eq "$(git -C "$rne" rev-parse main)" "$main_before" "main untouched when the --no-ff commit is refused"
assert_eq "$(git -C "$rne" status --porcelain)" "" "checkout is clean after a refused --no-ff commit"
assert_eq "$(git -C "$rne" symbolic-ref --short HEAD)" "main" "checkout stays on default branch after a refused --no-ff commit"
git -C "$rne" rev-parse -q --verify MERGE_HEAD >/dev/null \
  && fail "MERGE_HEAD must not remain after a refused --no-ff commit"

pass
