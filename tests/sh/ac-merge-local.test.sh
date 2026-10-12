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

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
#      (asserted in tests/sh/ac-brief.test.sh); this proves ac-merge-local.sh
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
out="$("$BIN/ac-merge-local.sh" c8)" || fail "a no-op re-land succeeds: $out"
# main already holds crew/c8 and more, so nothing moved and the trees differ:
# the line must say so, never assert the fast-forward that did not happen.
assert_contains "$out" "main already contains crew/c8; nothing to move" "a no-op re-land says so"
case "$out" in *fast-forwarded*) fail "a no-op re-land must not claim a fast-forward: $out" ;; esac
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
#              The two-sided gate end to end: the entry hands it the project
#              and the crew head, and it reads both the yaml's qa.scopes and
#              the repo-knowledge record (the gate itself is src/lib.ts's
#              qaGateOk; tests/ts/qa-gate.test.ts holds it to ac_qa_gate_ok
#              arm by arm).
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
grep -q -- "ac-merge-local.sh cns --no-ff" <<<"$out" \
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

# ---- Case: the qa gate and the merge see the SAME head ----------------------
# A git shim advances crew/<id> the moment the merge runs - a crewmate commit
# landing between the gate and the merge. Only the attested sha may land.
real_git="$(command -v git)"
race_shim="$TMP/race-shim"
mkdir -p "$race_shim"
for race_mode in ff no-ff; do
  rrace="$(make_repo "race-$race_mode")"
  add_crew "$rrace" "rc-$race_mode"
  mk_meta "rc-$race_mode" "$rrace"
  printf 'qa:\n  require_for_ship: true\n' >"$AC_HOME/projects/race-$race_mode.yaml"
  printf '/.crew/\n' >>"$rrace/.git/info/exclude"
  gated="$(git -C "$rrace" rev-parse "crew/rc-$race_mode")"
  mkdir -p "$rrace/.crew/qa/passed"
  printf 'schema=agentcrew.qa-attestation/v2\noutcome=passed\nrun=r\ntask=t\ncompleted_at=2026-07-24T00:00:00Z\nsource_sha=%s\nprofile_key=race-%s\nprofile_sha256=p\nconfig_sha256=c\ncases_passed=1\ncases_total=1\n' \
    "$gated" "$race_mode" >"$rrace/.crew/qa/passed/$gated"
  [ "$race_mode" = no-ff ] && diverge_main "$rrace" side.txt "main moved"
  cat >"$race_shim/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" merge "*)
    if [ ! -e "$rrace/.raced" ]; then
      : >"$rrace/.raced"
      late="\$("$real_git" -C "$rrace" commit-tree "crew/rc-$race_mode^{tree}" -p "crew/rc-$race_mode" -m late)"
      "$real_git" -C "$rrace" update-ref "refs/heads/crew/rc-$race_mode" "\$late"
    fi ;;
esac
exec "$real_git" "\$@"
EOF
  chmod +x "$race_shim/git"
  flag=""; [ "$race_mode" = no-ff ] && flag=--no-ff
  PATH="$race_shim:$PATH" "$BIN/ac-merge-local.sh" "rc-$race_mode" $flag >/dev/null 2>&1 \
    || fail "$race_mode: the gated head must still land"
  assert_file "$rrace/.raced"
  late="$(git -C "$rrace" rev-parse "crew/rc-$race_mode")"
  [ "$late" != "$gated" ] || fail "fixture broken: the shim must have advanced the branch"
  git -C "$rrace" merge-base --is-ancestor "$gated" main || fail "$race_mode: the attested head must be on main"
  git -C "$rrace" merge-base --is-ancestor "$late" main \
    && fail "$race_mode: a commit pushed after the qa gate must not ride the merge"
done

# --- differential: src/merge-local.ts against the frozen bash original -------
# DISPUTED: the implementation (tests/fixtures/ac-merge-local.sh under bash vs src/merge-local.ts through bin/ac-merge-local.sh)
# HELD-CONSTANT: two side roots seeded alike ($OH for the oracle, $NH for the shim) - a home at <side>/home whose projects/ clones (and the bare origins under <side>/remotes) carry the same fixed-date commits so every sha agrees - argv and env (the side root spelled HOME, substituted in values only), cwd (the side root, or a repo under it where a row says), stdin /dev/null, LC_ALL=C, GIT_AUTHOR_DATE/GIT_COMMITTER_DATE fixed so a commit made during the run agrees too, AC_GUARD_ROOT at a non-repo dir (the guard's checkout checks name where bin/ sits, which differs by construction) and a fresh watcher beat in each home, PATH stubs for `date` (one fixed instant) and `sleep` (logged, instant); exit status, stdout and stderr compared whole (the side root spelled HOME, the oracle's and this checkout's distro roots spelled DISTRO), then the world a row may touch: every clone's and origin's refs, HEAD, MERGE_HEAD, porcelain status and working-tree files, the names under state/, the landing ledger, every status log and timeline, and the sleep log.
obin="$(make_oracle_bin ac-merge-local)"
OROOT="$(dirname "$obin")"
OH="$TMP/mside-o"; NH="$TMP/mside-n"
MSTUBS="$TMP/mstubs"; mkdir -p "$MSTUBS" "$TMP/mguard-root"
cat >"$MSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in *%s*) echo 1767225600 ;; *) echo 2026-01-01T00:00:00Z ;; esac
STUB
cat >"$MSTUBS/sleep" <<'STUB'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$SLEEP_LOG"
STUB
chmod +x "$MSTUBS/date" "$MSTUBS/sleep"
NOW=1767225600
FIXED=2026-01-01T00:00:00Z
gitc() { GIT_AUTHOR_DATE=$FIXED GIT_COMMITTER_DATE=$FIXED git "$@"; }
both() {  # both <fn> <args...> - run a seeding step with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
mseed() { mkdir -p "$H/home/state" "$H/home/data" "$H/home/records" "$H/home/projects" "$H/remotes"; printf '%s\n' "$NOW" >"$H/home/state/.last-watcher-beat"; }
minit() {  # minit <dir> - a repo with one fixed-date commit on main
  git init -q -b main "$1"; git -C "$1" config user.email test@test; git -C "$1" config user.name test
  printf 'hello\n' >"$1/file.txt"; git -C "$1" add -A; gitc -C "$1" commit -qm init
}
mrepo() { minit "$H/home/projects/$1"; }
mcrew() {  # mcrew <repo> <family> [<file>, default <family>.txt] - crew/<family> one fixed-date commit ahead of the checked-out branch, then back on it
  local r="$H/home/projects/$1" cur
  cur="$(git -C "$r" symbolic-ref --short HEAD)"
  git -C "$r" checkout -q -b "crew/$2"; printf 'crew %s\n' "$2" >"$r/${3:-$2.txt}"
  git -C "$r" add -A; gitc -C "$r" commit -qm "crew $2"; git -C "$r" checkout -q "$cur"
}
mmain() {  # mmain <repo> <file> <content> - the checked-out branch advances by one fixed-date commit
  local r="$H/home/projects/$1"
  printf '%s\n' "$3" >"$r/$2"; git -C "$r" add -A; gitc -C "$r" commit -qm "main: $2"
}
mmeta() { printf 'project_dir=%s\nworktree=%s\n' "$H/home/projects/$2" "$H/home/projects/$2/.crew/worktrees/1" >"$H/home/state/$1.meta"; }
mput() { mkdir -p "$(dirname "$H/$1")"; printf -- "$2" >"$H/$1"; }
HOMELESS=0
ML_ENV=()
ML_PATH=""
ML_CWD=""
mrun() {  # mrun <bin> <side root> <prefix> <args...> - HOME in an arg or an env value is that side's root
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=(LC_ALL=C "PATH=${ML_PATH:-$MSTUBS:$PATH}" "SLEEP_LOG=$h/sleep.log" "AC_GUARD_ROOT=$TMP/mguard-root" "GIT_AUTHOR_DATE=$FIXED" "GIT_COMMITTER_DATE=$FIXED")
  [ "$HOMELESS" = 1 ] || e+=("AC_HOME=$h/home")
  for x in ${ML_ENV[@]+"${ML_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  (cd "$h/$ML_CWD" && env -u AC_HOME "${e[@]}" "$bin/ac-merge-local.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
mnorm() { LC_ALL=C sed -e "s#$2#HOME#g" -e "s#$OROOT#DISTRO#g" -e "s#$ROOT#DISTRO#g" "$1"; }
O_RC=0; N_RC=0
mpair() {  # mpair <args...> - both sides run, outputs normalised, nothing compared yet
  O_RC=0; N_RC=0
  mrun "$obin" "$OH" o "$@" || O_RC=$?
  mrun "$BIN" "$NH" n "$@" || N_RC=$?
  mnorm "$TMP/o.raw" "$OH" >"$TMP/o.out"; mnorm "$TMP/o.err" "$OH" >"$TMP/o.err2"
  mnorm "$TMP/n.raw" "$NH" >"$TMP/n.out"; mnorm "$TMP/n.err" "$NH" >"$TMP/n.err2"
}
same_io() {
  assert_eq "$N_RC" "$O_RC" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 6)"
}
mworld() {  # mworld <side root> - what a row may change
  local h="$1" r f
  for r in "$h"/home/projects/* "$h"/remotes/*.git "$h"/cwdrepo "$h"/wt-*; do
    [ -d "$r" ] || continue
    printf '== %s\n' "$r"
    git -C "$r" for-each-ref --format='%(refname) %(objectname)' 2>&1 || true
    printf 'HEAD %s %s\n' "$(git -C "$r" symbolic-ref -q HEAD || printf detached)" "$(git -C "$r" rev-parse -q --verify HEAD || printf none)"
    if git -C "$r" rev-parse -q --verify MERGE_HEAD >/dev/null; then printf 'MERGING\n'; fi
    if [ "$(git -C "$r" rev-parse --is-bare-repository)" = false ]; then
      git -C "$r" status --porcelain --untracked-files=all
      (cd "$r" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$f" "$(cksum <"$f" 2>&1 || true)"; done)
    fi
  done
  printf '== state\n'; ls -A "$h/home/state"
  for f in "$h"/home/state/.landings "$h"/home/state/*.status "$h"/home/data/*/timeline.log "$h"/home/data/*/*/timeline.log "$h"/sleep.log; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"; cat "$f" 2>&1 || true; printf '\n'
  done
}
same_world() {
  mworld "$OH" >"$TMP/o.world"; mworld "$NH" >"$TMP/n.world"
  mnorm "$TMP/o.world" "$OH" >"$TMP/o.world2"; mnorm "$TMP/n.world" "$NH" >"$TMP/n.world2"
  cmp -s "$TMP/o.world2" "$TMP/n.world2" || fail "differential world differs after '$*': $(diff "$TMP/o.world2" "$TMP/n.world2" | head -n 8)"
}
msame() { mpair "$@"; same_io "$@"; same_world "$@"; }
m_out() { cat "$TMP/n.out"; }
m_err() { cat "$TMP/n.err2"; }
o_err() { cat "$TMP/o.err2"; }
MUSAGE='ERROR: usage: ac-merge-local.sh <id> [--no-ff]'
kgap() {  # kgap <family> <repo> - the KNOWLEDGE-GAP warn as both sides print it
  printf "WARN: KNOWLEDGE-GAP: family %s is landing on %s with no repo-knowledge entry -\nrecord what it learned (DISTRO/bin/ac-know.sh add --home HOME/home --repo HOME/home/projects/%s --family %s --src-file <path>:<line> --fact '<what you learned>')\nor dismiss if it learned nothing about the codebase. Record: HOME/home/records/repo-knowledge/%s.md" "$1" "$2" "$2" "$1" "$2"
}
both mseed

# 1. usage, exit 1, before the home: no id, an empty id, a second argument
#    that is not exactly --no-ff; W9 - a third argument is ignored (the land
#    runs as --no-ff); git absent from PATH refuses after the guard ran
both mrepo r1; both mcrew r1 c1; both mmeta c1 r1
msame; assert_eq "$(m_err)" "$MUSAGE" "1: no id"; assert_eq "$N_RC" 1 "1: usage exits 1"
msame '' --no-ff; assert_eq "$(m_err)" "$MUSAGE" "1: an empty id"
msame c1 --noff; assert_eq "$(m_err)" "$MUSAGE" "1: a misspelt flag"
msame c1 -n; assert_eq "$(m_err)" "$MUSAGE" "1: any other second argument"
msame c1 --no-ff extra
assert_eq "$(m_out)" "merged crew/c1 into main (--no-ff)" "1: W9 - a third argument is ignored"
assert_eq "$(m_err)" "$(kgap c1 r1)" "1: the knowledge flag rides the land"
NOGIT="$TMP/mnogit"; mkdir -p "$NOGIT"
for d in /usr/bin /bin "$(dirname "$(command -v bun)")"; do
  for f in "$d"/*; do [ -x "$f" ] && [ "$(basename "$f")" != git ] && [ ! -e "$NOGIT/$(basename "$f")" ] && ln -s "$f" "$NOGIT/$(basename "$f")"; done
done
ML_PATH="$MSTUBS:$NOGIT"; msame c1; ML_PATH=""
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: required tool not found: git" "1: no git on PATH"

# 2. the meta: homeless (the refusal, then the entry's own line), no meta, an
#    unreadable one (metaGet's WARN alone, exit 1 - W2), a meta without
#    project_dir run from a repo cwd (W1: `git -C ""` lands in the caller's
#    cwd), a meta without worktree (the refusal names it empty)
HOMELESS=1; msame c1; HOMELESS=0
assert_eq "$(m_err)" "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one
ERROR: no crewmate meta for c1" "2: homeless"
msame nosuch; assert_eq "$(m_err)" "ERROR: no crewmate meta for nosuch" "2: no meta"
if [ "$(id -u)" != 0 ]; then
  lockmeta() { mmeta u2 r1; chmod 000 "$H/home/state/u2.meta"; }
  both lockmeta
  msame u2
  assert_eq "$(tail -n 1 "$TMP/n.err2")" "WARN: cannot read meta file HOME/home/state/u2.meta" "2: W2 - an unreadable meta is the WARN alone"
  assert_eq "$N_RC" 1 "2: W2 - exit 1"
  unlockmeta() { chmod 644 "$H/home/state/u2.meta"; rm -f "$H/home/state/u2.meta"; }
  both unlockmeta
fi
w1seed() {
  minit "$H/cwdrepo"; git -C "$H/cwdrepo" checkout -q -b crew/w1; printf 'w1\n' >"$H/cwdrepo/w1.txt"
  git -C "$H/cwdrepo" add -A; gitc -C "$H/cwdrepo" commit -qm w1; git -C "$H/cwdrepo" checkout -q main
  printf 'worktree=%s\n' "$H/wt" >"$H/home/state/w1.meta"
}
both w1seed
ML_CWD=cwdrepo; msame w1; ML_CWD=""
assert_eq "$(m_out)" "fast-forwarded main to crew/w1" "2: W1 - an empty project_dir lands the caller's cwd repo"
assert_eq "$(m_err)" "" "2: W1 - no knowledge flag for an empty repo"
assert_eq "$(git -C "$NH/cwdrepo" rev-parse main)" "$(git -C "$NH/cwdrepo" rev-parse crew/w1)" "2: W1 - the cwd repo's main moved"
nowt() { printf 'project_dir=%s\n' "$H/home/projects/r1" >"$H/home/state/nob.meta"; }
both nowt
msame nob
assert_eq "$(m_err)" "ERROR: branch crew/nob not found in HOME/home/projects/r1 (did the crewmate commit? worktree: )" "2: no worktree in the meta"
gone() { printf 'project_dir=%s\nworktree=x\n' "$H/home/projects/gone" >"$H/home/state/gone.meta"; }
both gone
mpair gone
assert_eq "$N_RC $O_RC" "1 1" "2: a project_dir that is gone: exit 1 on both sides"
assert_eq "$(m_out)$(cat "$TMP/o.out")" "" "2: ...nothing on stdout"
assert_eq "$(o_err)" "fatal: cannot change to 'HOME/home/projects/gone': No such file or directory
fatal: cannot change to 'HOME/home/projects/gone': No such file or directory
ERROR: primary checkout is on 'DETACHED', not 'main'" "2: ...the original's default-branch probe printed git's two lines"
assert_eq "$(m_err)" "ERROR: primary checkout is on 'DETACHED', not 'main'" "2: ...defaultBranch (src/lib.ts) drops them - named"
same_world "gone"

# 3. lands: a clean ff, the no-op re-land, a family-scoped id, a staged id
#    whose stage dir exists (its family's branch) and one whose does not (its
#    own); the status line and its timeline mirror ride the world
both mrepo r3; both mcrew r3 c3; both mmeta c3 r3
msame c3
assert_eq "$(m_out)" "fast-forwarded main to crew/c3" "3: a clean ff"
assert_eq "$(cat "$NH/home/state/c3.status")" "$FIXED merged: local main" "3: the status line"
assert_eq "$(cat "$NH/home/data/c3/timeline.log")" "$FIXED merged: local main" "3: its timeline mirror"
assert_eq "$(tail -n 1 "$NH/home/state/.landings")" "$NOW	c3	c3.txt" "3: the ledger record"
msame c3
assert_eq "$(m_out)" "main already contains crew/c3; nothing to move" "3: the no-op re-land"
both mcrew r3 foo foo.txt; both mmeta foo-r2 r3
msame foo-r2; assert_eq "$(m_out)" "fast-forwarded main to crew/foo" "3: a revision id lands its family"
both mcrew r3 c7 c7.txt; both mmeta c7-ship r3
stagedir() { mkdir -p "$H/home/data/c7/ship"; }
msame c7-ship; assert_eq "$(m_err)" "ERROR: branch crew/c7-ship not found in HOME/home/projects/r3 (did the crewmate commit? worktree: HOME/home/projects/r3/.crew/worktrees/1)" "3: no stage dir - the id is its own family"
both stagedir
msame c7-ship; assert_eq "$(m_out)" "fast-forwarded main to crew/c7" "3: a stage dir - the family's branch"

# 4. refusals, the clone untouched: tracked dirt (git's quoting, a rename),
#    detached, a side branch, diverged - bare, AC_SCOPE, AC_CREW_ID
dirt() {
  local r="$H/home/projects/r4"
  minit "$r"; printf 'a\n' >"$r/a b.txt"; printf 'c\n' >"$r/c.txt"; printf 'e\n' >"$r/$(printf 'caf\303\251.txt')"
  git -C "$r" add -A; gitc -C "$r" commit -qm files
  mcrew r4 c4; mmeta c4 r4
  printf 'more\n' >>"$r/a b.txt"; printf 'more\n' >>"$r/$(printf 'caf\303\251.txt')"; git -C "$r" mv c.txt d.txt
}
both dirt
msame c4
assert_eq "$(m_err)" 'ERROR: primary checkout is dirty: "a b.txt" "caf\303\251.txt" c.txt -> d.txt (commit, stash, or discard, then retry)' "4: dirt named as git quotes it"
undirt() { git -C "$H/home/projects/r4" reset -q --hard; git -C "$H/home/projects/r4" checkout -q --detach; }
both undirt
msame c4; assert_eq "$(m_err)" "ERROR: primary checkout is on 'DETACHED', not 'main'" "4: detached"
onside() { git -C "$H/home/projects/r4" checkout -q -b side; }
both onside
msame c4; assert_eq "$(m_err)" "ERROR: primary checkout is on 'side', not 'main'" "4: a side branch"
diverge() { git -C "$H/home/projects/r4" checkout -q main; mmain r4 mainfile.txt "main moved"; }
both diverge
msame c4
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: crew/c4 is not fast-forwardable: main has diverged from it. Land a conflict-free branch with 'ac-merge-local.sh c4 --no-ff', or rebase crew/c4 onto main first" "4: diverged, unscoped"
SCOPED="ERROR: crew/c4 is not fast-forwardable: main has diverged from it. --no-ff is not available here (the primary-checkout commit guard refuses it for a crewmate/roomchief) - rebase crew/c4 onto main and re-run the plain land, or hand the landing back to the crewchief"
ML_ENV=(AC_SCOPE=fam); msame c4; ML_ENV=()
assert_eq "$(tail -n 1 "$TMP/n.err2")" "$SCOPED" "4: diverged under AC_SCOPE"
ML_ENV=(AC_CREW_ID=c4); msame c4; ML_ENV=()
assert_eq "$(tail -n 1 "$TMP/n.err2")" "$SCOPED" "4: diverged under AC_CREW_ID alone"
ML_ENV=(AC_SCOPE= AC_CREW_ID=); msame c4; ML_ENV=()
assert_contains "$(m_err)" "Land a conflict-free branch" "4: an EMPTY scope is unscoped"

# 5. an untracked file colliding with an incoming path: git refuses the ff and
#    the --no-ff merge never starts, in the entry's voice, nothing moved
both mrepo r5; both mcrew r5 c5; both mmeta c5 r5
collide() { printf 'stray\n' >"$H/home/projects/r5/c5.txt"; }
both collide
msame c5
assert_contains "$(m_err)" "ERROR: fast-forward of crew/c5 failed: error: The following untracked working tree files would be overwritten by merge:" "5: the ff collision"
assert_contains "$(m_err)" "(main untouched)" "5: ...main untouched"
uncollide() { rm -f "$H/home/projects/r5/c5.txt"; }
both uncollide; both mmain r5 mainfile.txt "main moved"; both collide
msame c5 --no-ff
assert_contains "$(m_err)" "ERROR: --no-ff merge of crew/c5 never started: error: The following untracked working tree files would be overwritten by merge:" "5: the --no-ff collision never started"
assert_contains "$(m_err)" "(checkout untouched, still clean on main)" "5: ...the checkout untouched"

# 6. --no-ff: a clean land, a conflict (aborted, clean), unrelated history
#    (never started - and W5: its three-dot diff fails, so the landed set is
#    silently empty), the no-op, a commit a hook refuses (aborted, restored)
both mrepo r6; both mcrew r6 c6; both mmain r6 mainfile.txt "main moved"; both mmeta c6 r6
msame c6 --no-ff
assert_eq "$(m_out)" "merged crew/c6 into main (--no-ff)" "6: a clean --no-ff land"
assert_eq "$(cat "$NH/home/state/c6.status")" "$FIXED merged: local main (--no-ff)" "6: its status line"
msame c6 --no-ff
assert_eq "$(m_out)" "main already contains crew/c6; no merge commit created (--no-ff)" "6: the no-op"
assert_eq "$(sed -n 2p "$NH/home/state/c6.status")" "$FIXED merged: local main" "6: the no-op's status line"
both mcrew r6 cx; both mmain r6 cx.txt "main's own version"; both mmeta cx r6
msame cx --no-ff
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: --no-ff merge of crew/cx conflicts on: cx.txt (checkout left clean on main)" "6: a conflict"
orphan() {
  local r="$H/home/projects/r6"
  git -C "$r" checkout -q --orphan crew/co; git -C "$r" rm -qrf . >/dev/null
  printf 'orphan\n' >"$r/orphan.txt"; git -C "$r" add -A; gitc -C "$r" commit -qm orphan; git -C "$r" checkout -q main
  mmeta co r6
}
both orphan
msame co --no-ff
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: --no-ff merge of crew/co never started: fatal: refusing to merge unrelated histories (checkout untouched, still clean on main)" "6: unrelated history"
assert_contains "$(m_err)" "fatal: main...refs/heads/crew/co: no merge base" "6: W5 - the three-dot diff failed, git's line passed, the landed set empty"
hook() { mcrew r6 ch ch.txt; mmeta ch r6; printf '#!/bin/sh\necho hook says no\nexit 1\n' >"$H/home/projects/r6/.git/hooks/pre-commit"; chmod +x "$H/home/projects/r6/.git/hooks/pre-commit"; }
both hook
msame ch --no-ff
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: --no-ff commit of crew/ch was refused: hook says no (checkout restored, clean on main)" "6: a refused commit"

# 7. the landing ledger: a >7d record pruned, a header line (W6: its epoch
#    reads 0 - silent, then pruned), a <24h foreign record warned with its
#    live or ARCHIVED room, the own family and a >24h one silent, a path with
#    spaces; a lock held by a live pid (ten stubbed sleeps, the UNSERIALIZED
#    WARN, the records written, the lock left to its holder); W10: an
#    EMPTY-family record shifts the read and its path dies in the shell's
#    arithmetic before the merge; an unreadable ledger dies with awk's 2
ledger() { printf -- "$1" >"$H/home/state/.landings"; }
both mrepo r7; both mcrew r7 c7a 'a b.txt'; both mmeta c7a r7
rooms() { mput home/data/live/room.md 'x\n'; mput home/data/archive/2025/arch/room.md 'x\n'; }
both rooms
both ledger "epoch\tfamily\ta b.txt\n$((NOW - 8 * 86400))\told\ta b.txt\n$((NOW - 3600))\tlive\ta b.txt\n$((NOW - 7200))\tarch\ta b.txt\n$((NOW - 60))\tc7a\ta b.txt\n$((NOW - 25 * 3600))\tstranger\ta b.txt\n"
msame c7a
assert_eq "$(m_err)" "WARN: LANDING-OVERLAP: a b.txt landed 1h ago by family live - required reading: HOME/home/data/live/room.md
WARN: LANDING-OVERLAP: a b.txt landed 2h ago by family arch - required reading: HOME/home/data/archive/2025/arch/room.md
$(kgap c7a r7)" "7: the foreign records warn, live and archived rooms"
assert_eq "$(cat "$NH/home/state/.landings")" "$((NOW - 3600))	live	a b.txt
$((NOW - 7200))	arch	a b.txt
$((NOW - 60))	c7a	a b.txt
$((NOW - 25 * 3600))	stranger	a b.txt
$NOW	c7a	a b.txt" "7: the >7d record and the header pruned, the land appended"
both mcrew r7 c7b b.txt; both mmeta c7b r7
held() { mkdir -p "$H/home/state/.landings.lock"; printf '%s\n' "$$" >"$H/home/state/.landings.lock/pid"; }
both held
msame c7b
assert_eq "$(tail -n 1 "$TMP/n.err2")" "WARN: landing ledger: HOME/home/state/.landings.lock could not be acquired within 10s - recording UNSERIALIZED, so a concurrent landing's records may be lost and its <24h LANDING-OVERLAP warn may not fire for them" "7: the UNSERIALIZED WARN after the knowledge flag"
assert_eq "$(wc -l <"$NH/sleep.log" | tr -d ' ')" 10 "7: ten waits, each a spawned sleep"
assert_eq "$(tail -n 1 "$NH/home/state/.landings")" "$NOW	c7b	b.txt" "7: recorded anyway"
assert_eq "$(cat "$NH/home/state/.landings.lock/pid")" "$$" "7: the holder keeps its lock"
unheld() { rm -rf "$H/home/state/.landings.lock" "$H/sleep.log"; }
both unheld
both mcrew r7 c7c g; both mmeta c7c r7
both ledger "$((NOW - 10))\t\tg\n"
mpair c7c
assert_eq "$N_RC $O_RC" "1 1" "7: W10 - an empty-family record ends the run with 1 on both sides"
assert_contains "$(o_err)" "g: unbound variable" "7: W10 - the original died in the shell's arithmetic"
assert_eq "$(m_err)" "" "7: W10 - the port names no shell line (SHELL-OWN STDERR)"
assert_eq "$(m_out)" "" "7: W10 - nothing landed"
same_world "W10"
both ledger "$((NOW - 10))\t\t5\n"
both mcrew r7 c7d 5; both mmeta c7d r7
msame c7d
assert_eq "$(sed -n 1p "$TMP/n.err2")" "WARN: LANDING-OVERLAP:  landed 0h ago by family 10 - required reading: HOME/home/data/10/room.md" "7: W10 - a numeric path shifts quietly"
if [ "$(id -u)" != 0 ]; then
  both mcrew r7 c7e e.txt; both mmeta c7e r7
  both ledger "$((NOW - 10))\tx\te.txt\n"
  shut() { chmod 000 "$H/home/state/.landings"; }
  both shut
  mpair c7e
  open_ledger() { chmod 644 "$H/home/state/.landings"; }
  both open_ledger
  assert_eq "$N_RC $O_RC" "2 2" "7: an unreadable ledger ends the run with awk's 2"
  assert_contains "$(o_err)" "can't open file" "7: ...awk's own line on the original"
  assert_eq "$(m_err)" "" "7: ...not reproduced"
  same_world "unreadable ledger"
fi

# 8. KNOWLEDGE-GAP through the entry: the family's own entry silences it, a
#    sibling's or a superseded one does not
both mrepo r8; both mcrew r8 c8; both mmeta c8 r8
know() { mput home/records/repo-knowledge/r8.md "$1"; }
both know '- fact x | src: cmd:true | at: d 2026-07-21 | by: other\n## Superseded\n- fact y | by: c8\n'
msame c8; assert_eq "$(m_err)" "$(kgap c8 r8)" "8: a sibling's and a superseded entry"
both mcrew r8 c8b c8b.txt; both mmeta c8b r8
both know '- fact x | src: cmd:true | at: d 2026-07-21 | by: c8b\n'
msame c8b; assert_eq "$(m_err)" "" "8: the family's own entry"

# 9. the qa gate, src/lib.ts's twin on the port's side and the original's own
#    sourcing of the bash function on the other: flat with and without a
#    marker, MODE MISMATCH both ways, the bare marker on a scoped project, the
#    scoped pass, the required-profile matrix, the RETIRED legacy config (its
#    die is the run's exit - no blocked line), the require_for_ship spellings
#    (anything but a false spelling enforces: `True` and a comment after
#    `true` do, a quoted `No` with a comment and a CR does not), an unreadable
#    yaml (its refusal is the run's exit, as the RETIRED one), W8 a CRLF scope
#    line, W10 a string manifest entry, W11 a shifted pin, `00` counts (an
#    invalid marker), every key counting (a flow header, a nested false
#    before a quoted top-level true), and a project_dir that is a linked
#    worktree. A repo git refuses never reaches the gate here: the checkout's
#    own `symbolic-ref` reads it DETACHED first
gate_repo() {  # gate_repo <name> <yaml> - a clone with crew/<name>, its yaml, the markers dir ignored
  mrepo "$1"; mcrew "$1" "$1"; mmeta "$1" "$1"
  [ -z "$2" ] || printf -- "$2" >"$H/home/projects/$1.yaml"
  printf '/.crew/\n' >>"$H/home/projects/$1/.git/info/exclude"; mkdir -p "$H/home/projects/$1/.crew/qa/passed"
}
marker() {  # marker <name> <suffix> [<scope> <app>] - a passing v2 attestation for crew/<name>'s head
  local r="$H/home/projects/$1" sha
  sha="$(git -C "$r" rev-parse "crew/$1")"
  { printf 'schema=agentcrew.qa-attestation/v2\noutcome=passed\nrun=r\ntask=t\ncompleted_at=2026-07-24T00:00:00Z\nsource_sha=%s\nprofile_key=%s/%s/%s\n' "$sha" "$1" "${3:-flat}" "${4:-flat}"
    printf 'profile_sha256=p\nconfig_sha256=c\ncases_passed=1\ncases_total=1\n'
    [ -z "${3:-}" ] || printf 'scope=%s\napp=%s\n' "$3" "$4"; } >"$r/.crew/qa/passed/$sha$2"
}
REQ='qa:\n  require_for_ship: true\n'
SCOPED_YAML='qa:\n  require_for_ship: true\n  scopes:\n    orchid:\n      seed: "true"\n'
sha12() { git -C "$NH/home/projects/$1" rev-parse "crew/$1" | cut -c1-12; }
both gate_repo q1 "$REQ"
msame q1
assert_eq "$(m_err)" "WARN: qa.require_for_ship: no passing crew-qa run recorded for $(sha12 q1) - run crew-qa on this head before merging
ERROR: local merge blocked by qa.require_for_ship (see message above)" "9: flat, no marker"
both marker q1 ''
msame q1; assert_eq "$(m_out)" "fast-forwarded main to crew/q1" "9: flat, a marker"
both gate_repo q2 "$SCOPED_YAML"; both marker q2 ''
msame q2; assert_contains "$(m_err)" "MODE MISMATCH - the fleet-home config declares scopes" "9: yaml scopes, no map"
mapq() { mput "home/records/repo-knowledge/$1.md" '- scope orchid = orchid-service | src: cmd:true | at: d 2026-07-21 | by: fam\n'; }
both gate_repo q3 "$REQ"; both mapq q3
msame q3; assert_contains "$(m_err)" "MODE MISMATCH - the repo-knowledge record declares scopes" "9: map scopes, no yaml"
both mapq q2
msame q2; assert_contains "$(m_err)" "A bare sha-only marker IS on disk" "9: the bare marker on a scoped project"
both marker q2 .orchid.orchid-service orchid orchid-service
msame q2
assert_eq "$(m_out)" "qa: passed profiles for $(sha12 q2): orchid/orchid-service
fast-forwarded main to crew/q2" "9: the scoped pass prints its pairs"
manifest() { mput "home/data/$1/qa/manifest.json" "{\"required_profiles\":[{\"profile_key\":\"$1/orchid/orchid-service\"},{\"profile_key\":\"$1/cedar/cedar-service\"}]}\n"; }
both gate_repo q4 "$REQ"; both manifest q4; both marker q4 .orchid.orchid-service orchid orchid-service
msame q4
assert_contains "$(m_err)" "WARN: qa.require_for_ship: required profile 'q4/cedar/cedar-service' has no passing crew-qa attestation for $(sha12 q4)" "9: the matrix, one of two"
both marker q4 .cedar.cedar-service cedar cedar-service
msame q4
assert_eq "$(sed -n 1p "$TMP/n.out")" "qa: all 2 required profile(s) satisfied for $(sha12 q4): q4/orchid/orchid-service q4/cedar/cedar-service" "9: the matrix, both"
retired() { mput home/config/projects/q5.yaml "$REQ"; }
both gate_repo q5 "$REQ"; both retired
msame q5
assert_eq "$(m_err)" "ERROR: project config for 'q5' found at the RETIRED legacy path (HOME/home/config/projects/q5.yaml), which is no longer read - move it: mv \"HOME/home/config/projects/q5.yaml\" \"HOME/home/projects/q5.yaml\" (or delete it if HOME/home/projects/q5.yaml is already authoritative)" "9: RETIRED - the die is the exit"
assert_eq "$N_RC" 1 "9: RETIRED exits 1"
both gate_repo q6 'qa:\n  require_for_ship: "true"\n'
msame q6; assert_contains "$(m_err)" "no passing crew-qa run recorded" "9: a quoted true is required"
MBLOCKED='ERROR: local merge blocked by qa.require_for_ship (see message above)'
both gate_repo q7 'qa:\n  require_for_ship: True\n'
msame q7
assert_eq "$(m_err)" "WARN: qa.require_for_ship: no passing crew-qa run recorded for $(sha12 q7) - run crew-qa on this head before merging
$MBLOCKED" "9: True enforces"
both gate_repo q8 'qa:\n  other: 1\n'
msame q8; assert_eq "$(m_out)" "fast-forwarded main to crew/q8" "9: no require_for_ship"
both gate_repo q9 'qa:\r\n  require_for_ship: "No" # off\r\n'
msame q9; assert_eq "$(m_out)" "fast-forwarded main to crew/q9" "9: a false spelling is not enforced"
both gate_repo qw1 'qa:\n  require_for_ship: true # on\n'
msame qw1
assert_eq "$(m_err)" "WARN: qa.require_for_ship: no passing crew-qa run recorded for $(sha12 qw1) - run crew-qa on this head before merging
$MBLOCKED" "9: a comment after true enforces"
if [ "$(id -u)" != 0 ]; then
  both gate_repo qw3 "$REQ"
  shuty() { chmod 000 "$H/home/projects/qw3.yaml"; }
  openy() { chmod 644 "$H/home/projects/qw3.yaml"; }
  both shuty; msame qw3; both openy
  assert_eq "$N_RC" 1 "9: an unreadable yaml ends the run with 1"
  assert_eq "$(m_err)" "ERROR: qa.require_for_ship: the project policy HOME/home/projects/qw3.yaml cannot be read - refusing the merge rather than reading it as not enforced" "9: ...its refusal alone, no blocked line"
  assert_eq "$(m_out)" "" "9: ...nothing landed"
fi
crlfmap() { mput "home/records/repo-knowledge/$1.md" '- scope orchid = orchid-service\r\n'; }
both gate_repo qw8 "$SCOPED_YAML"; both crlfmap qw8
msame qw8
assert_eq "$(m_err)" "WARN: qa.require_for_ship: the project's scope map is AMBIGUOUS (two live entries for one scope, or a malformed line) - refusing the merge rather than guessing which profile a marker proves. Fix it with bin/ac-know.sh scope-proposal, then re-run: bin/ac-know.sh verify
$MBLOCKED" "9: W8 - a CRLF scope line is AMBIGUOUS"
both gate_repo qw10 "$REQ"; both mput home/data/qw10/qa/manifest.json '{"required_profiles":["qw10/orchid/orchid-service"]}\n'
msame qw10
assert_eq "$(m_err)" "WARN: qa.require_for_ship: the task's required-profile manifest is empty or unreadable (HOME/home/data/qw10/qa/manifest.json) - refusing rather than merging against an undefined required set
$MBLOCKED" "9: W10 - a string entry reads as no manifest"
both gate_repo qw11 "$REQ"; both marker qw11 .orchid.orchid-service orchid orchid-service
both mput home/data/qw11/qa/manifest.json '{"required_profiles":[{"profile_key":"qw11/orchid/orchid-service","e2e_sha":"E"}]}\n'
msame qw11
assert_eq "$(m_err)" "WARN: qa.require_for_ship: the attestation for 'qw11/orchid/orchid-service' is invalid (profile hash mismatch) - re-run crew-qa for this exact profile and head
$MBLOCKED" "9: W11 - an e2e pin with no profile pin lands in the profile pin"
zeroes() {  # zeroes <name> - the flat marker's case counts spelled 00
  local f; f="$H/home/projects/$1/.crew/qa/passed/$(git -C "$H/home/projects/$1" rev-parse "crew/$1")"
  LC_ALL=C sed -e 's/^cases_passed=1$/cases_passed=00/' -e 's/^cases_total=1$/cases_total=00/' "$f" >"$f.t"; mv "$f.t" "$f"
}
both gate_repo qw13 "$REQ"; both marker qw13 ''; both zeroes qw13
msame qw13
assert_eq "$(m_err)" "WARN: qa.require_for_ship: ignored invalid flat QA attestation for $(sha12 qw13): invalid case counts
WARN: qa.require_for_ship: no passing crew-qa run recorded for $(sha12 qw13) - run crew-qa on this head before merging
$MBLOCKED" "9: 00 case counts are an invalid marker"
both gate_repo qk1 'qa: {serve: x, require_for_ship: true}\n'
msame qk1
assert_eq "$(m_err)" "WARN: qa.require_for_ship: no passing crew-qa run recorded for $(sha12 qk1) - run crew-qa on this head before merging
$MBLOCKED" "9: a flow mapping on the qa: header enforces"
both gate_repo qk2 'qa:\n  app:\n    require_for_ship: false\n  "require_for_ship" : true\n'
msame qk2
assert_eq "$(m_err)" "WARN: qa.require_for_ship: no passing crew-qa run recorded for $(sha12 qk2) - run crew-qa on this head before merging
$MBLOCKED" "9: a nested false before a quoted top-level true enforces"
wtland() {  # the primary checkout moved off main, main checked out in the linked worktree <side>/wt-qwt, the meta's project_dir
  gate_repo qwt "$REQ"; marker qwt ''
  git -C "$H/home/projects/qwt" checkout -q -b side; git -C "$H/home/projects/qwt" worktree add -q "$H/wt-qwt" main
  printf 'project_dir=%s\nworktree=%s\n' "$H/wt-qwt" "$H/home/projects/qwt/.crew/worktrees/1" >"$H/home/state/qwt.meta"
}
both wtland
msame qwt
assert_eq "$(m_out)" "fast-forwarded main to crew/qwt" "9: a linked worktree lands on the main repo's yaml and marker"
assert_eq "$(git -C "$NH/wt-qwt" rev-parse main)" "$(git -C "$NH/home/projects/qwt" rev-parse crew/qwt)" "9: ...main moved in the worktree"

# 10. an epic or feature record: the deferred qa line on STDOUT, the target
#     only on origin (W4: git's tracking line on stdout), the ref-only ff and
#     its push=yes, the no-op, the in-place ff (target checked out) and its
#     failure, the ref-only failure (target checked out in a linked worktree),
#     a failing push (the WARN, the landing stands), the target nowhere
#     (epic and feature remedies), --no-ff refused, the non-ff refused, an
#     unreadable ledger, a push=deferred feature landing (no push)
epic_seed() {
  minit "$H/src-ep"
  git clone -q --bare "$H/src-ep" "$H/remotes/ep.git"
  git clone -q "$H/remotes/ep.git" "$H/home/projects/ep"
  git -C "$H/home/projects/ep" config user.email test@test; git -C "$H/home/projects/ep" config user.name test
  mput home/records/backlog.md '- [ ] e1-s1 [src:cap flow:direct mode:local-only qa:no] - story one; epic:e1 (repo: ep)\n- [ ] e1-s2 [src:cap flow:direct mode:local-only qa:no] - story two; epic:e1 (repo: ep)\n- [ ] f1-m1 [src:cap flow:direct mode:feature-pr qa:no] - member; feature:f1 (repo: ep)\n'
  mput home/data/e1/branches 'ep epic/e1 push=yes\n'
  mput home/data/f1/branches 'ep feat/f1 push=deferred\n'
  mmeta e1-s1 ep; mmeta e1-s2 ep; mmeta f1-m1 ep
  local r="$H/home/projects/ep"
  git -C "$r" checkout -q -b crew/e1-s1; printf 's1\n' >"$r/s1.txt"; git -C "$r" add -A; gitc -C "$r" commit -qm s1; git -C "$r" checkout -q main
}
both epic_seed
msame e1-s1
assert_eq "$(m_err)" "ERROR: epic target epic/e1 exists neither locally nor on origin - cut it first: ac-epic-branch.sh create <epic> ep" "10: the target nowhere"
publish() { git -C "$H/src-ep" branch epic/e1; git -C "$H/src-ep" push -q "$H/remotes/ep.git" epic/e1:epic/e1; git -C "$H/home/projects/ep" fetch -q origin; }
both publish
msame e1-s1
assert_eq "$(m_out)" "branch 'epic/e1' set up to track 'origin/epic/e1'.
qa.require_for_ship: deferred to the epic gate (epic-branch landing)
fast-forwarded epic/e1 to crew/e1-s1 (ref-only)
pushed epic/e1 to origin (record push=yes)" "10: W4 - git's tracking line, then the ref-only ff and its push"
assert_eq "$(cat "$NH/home/state/e1-s1.status")" "$FIXED merged: local epic/e1 (epic)" "10: the epic status line"
assert_eq "$(git -C "$NH/remotes/ep.git" rev-parse epic/e1)" "$(git -C "$NH/home/projects/ep" rev-parse crew/e1-s1)" "10: origin followed"
msame e1-s1
assert_eq "$(m_out)" "qa.require_for_ship: deferred to the epic gate (epic-branch landing)
epic/e1 already contains crew/e1-s1; nothing to move
pushed epic/e1 to origin (record push=yes)" "10: the no-op still pushes"
msame e1-s1 --no-ff
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: --no-ff is not available for an epic-branch landing: a merge commit onto epic/e1 belongs in a leased worktree, never the primary checkout - rebase crew/e1-s1 onto epic/e1 and land ff, or route the merge through the epic gate" "10: --no-ff refused"
inplace() {
  local r="$H/home/projects/ep"
  git -C "$r" checkout -q epic/e1; git -C "$r" checkout -q -b crew/e1-s2; printf 's2\n' >"$r/s2.txt"; git -C "$r" add -A; gitc -C "$r" commit -qm s2
  git -C "$r" checkout -q epic/e1; printf 'stray\n' >"$r/s2.txt"
}
both inplace
msame e1-s2
assert_contains "$(m_err)" "ERROR: ff of epic/e1 (checked out) from crew/e1-s2 failed: error: The following untracked working tree files would be overwritten by merge:" "10: the in-place failure"
assert_contains "$(m_err)" "(epic/e1 untouched)" "10: ...epic/e1 untouched"
unstray() { rm -f "$H/home/projects/ep/s2.txt"; }
both unstray
msame e1-s2
assert_eq "$(sed -n 2p "$TMP/n.out")" "fast-forwarded epic/e1 to crew/e1-s2 (in place)" "10: the in-place ff"
sibling() {
  local r="$H/home/projects/ep"
  git -C "$r" checkout -q -B crew/e1-s1 epic/e1~1
  printf 's1 again\n' >"$r/s1b.txt"; git -C "$r" add -A; gitc -C "$r" commit -qm s1b; git -C "$r" checkout -q main
}
both sibling
msame e1-s1
assert_eq "$(tail -n 1 "$TMP/n.err2")" "ERROR: crew/e1-s1 is not fast-forwardable: epic/e1 has diverged from it (a sibling story landed first). Rebase crew/e1-s1 onto epic/e1 and re-run the plain land" "10: the non-ff epic"
lockwt() {
  local r="$H/home/projects/ep"
  git -C "$r" checkout -q -B crew/e1-s1 epic/e1; printf 's1c\n' >"$r/s1c.txt"; git -C "$r" add -A; gitc -C "$r" commit -qm s1c; git -C "$r" checkout -q main
  git -C "$r" worktree add -q "$H/wt-ep" epic/e1
}
both lockwt
msame e1-s1
assert_contains "$(m_err)" "ERROR: ff update of epic/e1 from crew/e1-s1 failed: fatal: refusing to fetch into branch 'refs/heads/epic/e1' checked out at 'HOME/wt-ep' (epic/e1 untouched)" "10: the ref-only failure"
unwt() { git -C "$H/home/projects/ep" worktree remove --force "$H/wt-ep"; git -C "$H/home/projects/ep" remote set-url origin "$H/nowhere.git"; }
both unwt
msame e1-s1
assert_eq "$(tail -n 1 "$TMP/n.err2")" "WARN: push of epic/e1 to origin FAILED - the landing stands; retry: git -C HOME/home/projects/ep push --no-verify origin epic/e1" "10: a failing push"
assert_eq "$(sed -n 2p "$TMP/n.out")" "fast-forwarded epic/e1 to crew/e1-s1 (ref-only)" "10: ...the landing stands"
mcrewf() { local r="$H/home/projects/ep"; git -C "$r" checkout -q -b crew/f1-m1; printf 'm1\n' >"$r/m1.txt"; git -C "$r" add -A; gitc -C "$r" commit -qm m1; git -C "$r" checkout -q main; }
both mcrewf
msame f1-m1
assert_eq "$(m_err)" "ERROR: feature target feat/f1 does not exist locally - cut it first: ac-feature.sh create <feature> ep" "10: the feature target missing"
cutf() { git -C "$H/home/projects/ep" branch feat/f1 main; }
both cutf
msame f1-m1
assert_eq "$(m_out)" "qa.require_for_ship: deferred to the feature ship gate (feature-branch landing)
fast-forwarded feat/f1 to crew/f1-m1 (ref-only)" "10: the feature landing, never pushed"
if [ "$(id -u)" != 0 ]; then
  shutl() { chmod 000 "$H/home/records/backlog.md"; }
  openl() { chmod 644 "$H/home/records/backlog.md"; }
  both shutl; mpair f1-m1; both openl
  assert_eq "$N_RC $O_RC" "1 1" "10: an unreadable ledger exits 1 on both sides"
  assert_eq "$(tail -n 1 "$TMP/o.err2")" "ERROR: cannot read the ledger to resolve the epic-branch fence for f1-m1" "10: an unreadable ledger"
  assert_contains "$(o_err)" "can't open file" "10: ...after the original's awk line"
  assert_eq "$(m_err)" "ERROR: cannot read the ledger to resolve the epic-branch fence for f1-m1" "10: ...which epicBaseFor (src/lib.ts) does not print - named"
  same_world "unreadable ledger"
fi

# 11. the gate and the merge see the SAME head: a PATH git stub (keyed on
#     " merge " in its argv, as the original leg's) advances crew/<id> the
#     moment the merge runs; only the attested sha lands, ff and --no-ff
REAL_GIT="$(command -v git)"
RSTUB="$TMP/mrace"; mkdir -p "$RSTUB"
cat >"$RSTUB/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *" merge "*)
    if [ ! -e "\$RACE_REPO/.raced" ]; then
      : >"\$RACE_REPO/.raced"
      late="\$("$REAL_GIT" -C "\$RACE_REPO" commit-tree "\$RACE_BRANCH^{tree}" -p "\$RACE_BRANCH" -m late)"
      "$REAL_GIT" -C "\$RACE_REPO" update-ref "refs/heads/\$RACE_BRANCH" "\$late"
    fi ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$RSTUB/git"
for rmode in ff no-ff; do
  both gate_repo "race$rmode" "$REQ"; both marker "race$rmode" ''
  [ "$rmode" = ff ] || both mmain "race$rmode" side.txt "main moved"
  gated="$(git -C "$NH/home/projects/race$rmode" rev-parse "crew/race$rmode")"
  ML_PATH="$RSTUB:$MSTUBS:$PATH"; ML_ENV=("RACE_REPO=HOME/home/projects/race$rmode" "RACE_BRANCH=crew/race$rmode")
  flag=""; [ "$rmode" = ff ] || flag=--no-ff
  msame "race$rmode" $flag
  ML_PATH=""; ML_ENV=()
  assert_eq "$N_RC" 0 "11: $rmode - the gated head lands"
  late="$(git -C "$NH/home/projects/race$rmode" rev-parse "crew/race$rmode")"
  [ "$late" != "$gated" ] || fail "11: $rmode - the stub must have advanced the branch"
  git -C "$NH/home/projects/race$rmode" merge-base --is-ancestor "$gated" main || fail "11: $rmode - the attested head is on main"
  git -C "$NH/home/projects/race$rmode" merge-base --is-ancestor "$late" main && fail "11: $rmode - the late commit must not ride the merge"
done

# 12. the status append runs bare after the merge: a status path that cannot
#     take the append ends the run with 1, the land already done (the shell's
#     own redirection line is not reproduced)
both mrepo r12; both mcrew r12 c12; both mmeta c12 r12
nostatus() { mkdir -p "$H/home/state/c12.status"; rm -f "$H/home/state/.landings"; }
both nostatus
mpair c12
assert_eq "$N_RC $O_RC" "1 1" "12: the failed append exits 1 on both sides"
assert_eq "$(m_out)" "" "12: no landing line"
assert_contains "$(o_err)" "Is a directory" "12: the original's shell line"
assert_eq "$(m_err)" "$(kgap c12 r12)" "12: the port's entry lines only"
same_world "unwritable status"
assert_eq "$(git -C "$NH/home/projects/r12" rev-parse main)" "$(git -C "$NH/home/projects/r12" rev-parse crew/c12)" "12: the land happened first"

# 13. the guard rides first: a stale watcher beat is WATCHER-DOWN on stderr
#     before the entry's own lines, and stamps state/.guard-stamp alike
stale() { printf '1\n' >"$H/home/state/.last-watcher-beat"; }
both stale
msame nosuch
assert_eq "$(m_err)" "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh
ERROR: no crewmate meta for nosuch" "13: the guard first"
[ -e "$NH/home/state/.guard-stamp" ] || fail "13: the guard stamped"

# 14. the ROOT seam: a lab bin/ whose root links src/ starts the module from
#     the distro checkout, yet its guard and the remedy's ac-know.sh are the
#     LAB's - as the original's $(dirname "$0") and ac_root named its own bin/
#     (STARTED_BIN, never import.meta.dir). The gate is not the lab's: its
#     ac-qa-lib.sh override of ac_qa_gate_ok (the frozen lib planted in the
#     lab bin/) would open the gate on a head with no marker, and the twin in
#     src/lib.ts refuses that head flat
LAB="$TMP/mlab"; mkdir -p "$LAB/bin"; cp "$BIN"/*.sh "$ROOT/tests/fixtures/ac-qa-lib.sh" "$LAB/bin/"; ln -s "$ROOT/src" "$LAB/src"
rm -f "$LAB/bin/ac-guard.sh"
printf '\nac_qa_gate_ok() { printf '"'"'lab gate %%s\\n'"'"' "$3"; }\n' >>"$LAB/bin/ac-qa-lib.sh"
H="$NH"; gate_repo lab "$REQ"; rm -f "$NH/home/state/.guard-stamp"
lab_land() { (cd "$NH" && env -u AC_HOME LC_ALL=C PATH="$MSTUBS:$PATH" AC_HOME="$NH/home" AC_GUARD_ROOT="$TMP/mguard-root" "$LAB/bin/ac-merge-local.sh" lab 2>"$TMP/lab.err"); }
out="$(lab_land)" && fail "14: the lab's gate override must not open the port's gate"
assert_eq "$out" "" "14: no land"
assert_eq "$(cat "$TMP/lab.err")" "WARN: qa.require_for_ship: no passing crew-qa run recorded for $(sha12 lab) - run crew-qa on this head before merging
$MBLOCKED" "14: the flat refusal - the lab's ac_qa_gate_ok is not consulted"
marker lab ''
out="$(lab_land)" || fail "14: the lab land"
assert_eq "$out" "fast-forwarded main to crew/lab" "14: no lab gate line"
case "$(cat "$TMP/lab.err")" in *WATCHER-DOWN*) fail "14: the lab has no guard, yet one ran" ;; esac
assert_contains "$(cat "$TMP/lab.err")" "record what it learned ($LAB/bin/ac-know.sh add" "14: the remedy names the lab's bin/"

pass
