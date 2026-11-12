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
#              the repo-knowledge record (the gate itself is src/lib-qa-gate.ts's
#              qaGateOk; tests/ts/qa-gate.test.ts holds it to explicit
#              answers arm by arm).
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

# ---- Case: --expect <sha> binds the land to the head the review read -------
# Review reads crew/<id> at one head; the land reads the ref again. A commit
# the crewmate adds between the two landed unreviewed. With --expect the land
# refuses unless the branch is still at that head (a unique prefix is enough).
rx="$(make_repo expecthead)"
add_crew "$rx" cx1
mk_meta cx1 "$rx"
reviewed="$(git -C "$rx" rev-parse crew/cx1)"
git -C "$rx" checkout -q crew/cx1
printf 'late\n' >"$rx/late.txt"; git -C "$rx" add -A; git -C "$rx" commit -qm "late commit"
git -C "$rx" checkout -q main
late="$(git -C "$rx" rev-parse crew/cx1)"
out="$("$BIN/ac-merge-local.sh" cx1 --expect "$(printf '%s' "$reviewed" | cut -c1-12)" 2>&1)" && fail "a branch past the reviewed head must not land: $out"
assert_contains "$out" "ERROR: crew/cx1 is at $late, not the reviewed $(printf '%s' "$reviewed" | cut -c1-12) - review what moved it (bin/ac-review-diff.sh cx1) and land with the head you read" "the refusal names both heads and the remedy"
if git -C "$rx" merge-base --is-ancestor "$reviewed" main; then fail "nothing landed on a refused --expect"; fi
out="$("$BIN/ac-merge-local.sh" cx1 --expect "$late" 2>&1)" || fail "the current head lands with --expect: $out"
assert_eq "$(git -C "$rx" rev-parse main)" "$late" "main fast-forwarded to the expected head"
out="$("$BIN/ac-merge-local.sh" cx1 --expect 2>&1)" && fail "--expect without a sha must be a usage error"
assert_contains "$out" "usage: ac-merge-local.sh <id> [--no-ff] [--expect <sha>]" "the usage names the flag"

# --- the entry end to end, one scenario per row ------------------------------
# One side root ($H): a home at $H/home whose projects/ clones (and the bare
# origins under $H/remotes) carry fixed-date commits, and a fresh watcher beat;
# env LC_ALL=C, GIT_AUTHOR_DATE/GIT_COMMITTER_DATE fixed so a commit made during
# the run is fixed too, AC_GUARD_ROOT at a non-repo dir; PATH stubs for `date`
# (one fixed instant) and `sleep` (logged, instant); cwd the side root, stdin
# /dev/null. A row reads the run's exit status, stdout and stderr (the side root
# spelled HOME, this checkout's distro root DISTRO) and what it left in the
# clones and the home.
H="$TMP/mside"
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
mlanded() { git -C "$H/home/projects/$1" merge-base --is-ancestor "crew/$2" main; }   # mlanded <repo> <family> - main contains crew/<family>
HOMELESS=0
ML_ENV=()
ML_PATH=""
ML_CWD=""
M_RC=0
mnorm() { LC_ALL=C sed -e "s#$H#HOME#g" -e "s#$ROOT#DISTRO#g" "$1"; }
mland() {  # mland <args...> - one run of the entry; HOME in an arg or an env value is the side root
  local x v a=() e=(LC_ALL=C "PATH=${ML_PATH:-$MSTUBS:$PATH}" "SLEEP_LOG=$H/sleep.log" "AC_GUARD_ROOT=$TMP/mguard-root" "GIT_AUTHOR_DATE=$FIXED" "GIT_COMMITTER_DATE=$FIXED")
  [ "$HOMELESS" = 1 ] || e+=("AC_HOME=$H/home")
  for x in ${ML_ENV[@]+"${ML_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$H}"); done
  for x in "$@"; do a+=("${x//HOME/$H}"); done
  M_RC=0
  (cd "$H/$ML_CWD" && env -u AC_HOME "${e[@]}" "$BIN/ac-merge-local.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/m.raw" 2>"$TMP/m.rawerr" || M_RC=$?
  mnorm "$TMP/m.raw" >"$TMP/m.out"; mnorm "$TMP/m.rawerr" >"$TMP/m.err"
}
m_out() { cat "$TMP/m.out"; }
m_err() { cat "$TMP/m.err"; }
kgap() {  # kgap <family> <repo> - the KNOWLEDGE-GAP warn
  printf "WARN: KNOWLEDGE-GAP: family %s is landing on %s with no repo-knowledge entry -\nrecord what it learned (DISTRO/bin/ac-know.sh add --home HOME/home --repo HOME/home/projects/%s --family %s --src-file <path>:<line> --fact '<what you learned>')\nor dismiss if it learned nothing about the codebase. Record: HOME/home/records/repo-knowledge/%s.md" "$1" "$2" "$2" "$1" "$2"
}
mkdir -p "$H/home/state" "$H/home/data" "$H/home/records" "$H/home/projects" "$H/remotes"
printf '%s\n' "$NOW" >"$H/home/state/.last-watcher-beat"

# 1. usage, exit 1, before the home: no id, an empty id, a second argument
#    that is neither flag; git absent from PATH refuses after the guard ran
mrepo r1; mcrew r1 c1; mmeta c1 r1
MUSAGE='ERROR: usage: ac-merge-local.sh <id> [--no-ff] [--expect <sha>]'
musage() {  # musage <why> <args...>
  local why="$1"; shift
  mland "$@"
  assert_eq "$M_RC:$(m_out):$(m_err)" "1::$MUSAGE" "1: $why"
}
musage "no id"
musage "an empty id" '' --no-ff
musage "a misspelt flag" c1 --noff
musage "any other second argument" c1 -n
NOGIT="$TMP/mnogit"; mkdir -p "$NOGIT"
for d in /usr/bin /bin "$(dirname "$(command -v bun)")"; do
  for f in "$d"/*; do [ -x "$f" ] && [ "$(basename "$f")" != git ] && [ ! -e "$NOGIT/$(basename "$f")" ] && ln -s "$f" "$NOGIT/$(basename "$f")"; done
done
ML_PATH="$MSTUBS:$NOGIT"; mland c1; ML_PATH=""
assert_eq "$M_RC:$(m_out):$(m_err)" "1::ERROR: required tool not found: git" "1: no git on PATH"
mlanded r1 c1 && fail "1: nothing landed"

# 2. the meta: homeless (the AC_HOME refusal first), no meta, an unreadable
#    one, a meta without worktree (the refusal names it empty), a project_dir
#    that is gone (its checkout reads DETACHED)
HOMELESS=1; mland c1; HOMELESS=0
assert_eq "$M_RC:$(m_out):$(sed -n 1p "$TMP/m.err")" "1::ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one" "2: homeless"
mland nosuch; assert_eq "$M_RC:$(m_err)" "1:ERROR: no crewmate meta for nosuch" "2: no meta"
if [ "$(id -u)" != 0 ]; then
  mmeta u2 r1; chmod 000 "$H/home/state/u2.meta"
  mland u2
  chmod 644 "$H/home/state/u2.meta"; rm -f "$H/home/state/u2.meta"
  assert_eq "$M_RC:$(m_out)" "1:" "2: an unreadable meta ends the run 1"
  assert_no_file "$H/home/state/u2.status" "2: ...nothing landed"
fi
printf 'project_dir=%s\n' "$H/home/projects/r1" >"$H/home/state/nob.meta"
mland nob
assert_eq "$M_RC:$(m_err)" "1:ERROR: branch crew/nob not found in HOME/home/projects/r1 (did the crewmate commit? worktree: )" "2: no worktree in the meta"
printf 'project_dir=%s\nworktree=x\n' "$H/home/projects/gone" >"$H/home/state/gone.meta"
mland gone
assert_eq "$M_RC:$(m_out):$(m_err)" "1::ERROR: primary checkout is on 'DETACHED', not 'main'" "2: a project_dir that is gone"

# W1: an EMPTY project_dir must refuse before any git call - `git -C ""` reads
# as no -C at all, so an unbound empty project_dir would judge against, and
# land into, the repo of the CALLER's cwd instead of this task's project.
printf 'project_dir=\nworktree=x\n' >"$H/home/state/noproj.meta"
mland noproj
assert_eq "$M_RC:$(m_out):$(m_err)" \
  "1::ERROR: empty project_dir in meta for noproj - refusing before any git call (a blank -C reads as the caller's own cwd, not this task's project)" \
  "2: an empty project_dir must refuse before any git call"

# 3. lands: a clean ff with its status line, timeline mirror and ledger
#    record; a staged id whose stage dir does not exist is its own family
mrepo r3; mcrew r3 c3; mmeta c3 r3
mland c3
assert_eq "$M_RC:$(m_out)" "0:fast-forwarded main to crew/c3" "3: a clean ff"
assert_eq "$(cat "$H/home/state/c3.status")" "$FIXED merged: local main" "3: the status line"
assert_eq "$(cat "$H/home/data/c3/timeline.log")" "$FIXED merged: local main" "3: its timeline mirror"
assert_eq "$(tail -n 1 "$H/home/state/.landings")" "$NOW	c3	c3.txt" "3: the ledger record"
mcrew r3 c7 c7.txt; mmeta c7-ship r3
mland c7-ship
assert_eq "$M_RC:$(m_err)" "1:ERROR: branch crew/c7-ship not found in HOME/home/projects/r3 (did the crewmate commit? worktree: HOME/home/projects/r3/.crew/worktrees/1)" "3: no stage dir - the id is its own family"

# 4. refusals, the clone untouched: tracked dirt (git's quoting, a rename),
#    detached, a side branch, diverged - under AC_CREW_ID alone, and with an
#    EMPTY scope (unscoped)
r4="$H/home/projects/r4"
minit "$r4"; printf 'a\n' >"$r4/a b.txt"; printf 'c\n' >"$r4/c.txt"; printf 'e\n' >"$r4/$(printf 'caf\303\251.txt')"
git -C "$r4" add -A; gitc -C "$r4" commit -qm files
mcrew r4 c4; mmeta c4 r4
printf 'more\n' >>"$r4/a b.txt"; printf 'more\n' >>"$r4/$(printf 'caf\303\251.txt')"; git -C "$r4" mv c.txt d.txt
mland c4
assert_eq "$M_RC:$(m_err)" '1:ERROR: primary checkout is dirty: "a b.txt" "caf\303\251.txt" c.txt -> d.txt (commit, stash, or discard, then retry)' "4: dirt named as git quotes it"
git -C "$r4" reset -q --hard; git -C "$r4" checkout -q --detach
mland c4; assert_eq "$M_RC:$(m_err)" "1:ERROR: primary checkout is on 'DETACHED', not 'main'" "4: detached"
git -C "$r4" checkout -q -b side
mland c4; assert_eq "$M_RC:$(m_err)" "1:ERROR: primary checkout is on 'side', not 'main'" "4: a side branch"
git -C "$r4" checkout -q main; mmain r4 mainfile.txt "main moved"
ML_ENV=(AC_CREW_ID=c4); mland c4; ML_ENV=()
assert_eq "$M_RC:$(tail -n 1 "$TMP/m.err")" "1:ERROR: crew/c4 is not fast-forwardable: main has diverged from it. --no-ff is not available here (the primary-checkout commit guard refuses it for a crewmate/roomchief) - rebase crew/c4 onto main and re-run the plain land, or hand the landing back to the crewchief" "4: diverged under AC_CREW_ID alone"
ML_ENV=(AC_SCOPE= AC_CREW_ID=); mland c4; ML_ENV=()
assert_eq "$M_RC:$(tail -n 1 "$TMP/m.err")" "1:ERROR: crew/c4 is not fast-forwardable: main has diverged from it. Land a conflict-free branch with 'ac-merge-local.sh c4 --no-ff', or rebase crew/c4 onto main first" "4: an EMPTY scope is unscoped"
mlanded r4 c4 && fail "4: nothing landed"

# 5. --no-ff: a clean land and the no-op re-land, each with its status line
mrepo r6; mcrew r6 c6; mmain r6 mainfile.txt "main moved"; mmeta c6 r6
mland c6 --no-ff
assert_eq "$M_RC:$(m_out)" "0:merged crew/c6 into main (--no-ff)" "5: a clean --no-ff land"
assert_eq "$(cat "$H/home/state/c6.status")" "$FIXED merged: local main (--no-ff)" "5: its status line"
mland c6 --no-ff
assert_eq "$M_RC:$(m_out)" "0:main already contains crew/c6; no merge commit created (--no-ff)" "5: the no-op"
assert_eq "$(sed -n 2p "$H/home/state/c6.status")" "$FIXED merged: local main" "5: the no-op's status line"

# 6. the landing ledger: a >7d record pruned, a <24h foreign record warned
#    with its live or ARCHIVED room, the own family and a >24h one silent, a
#    path with spaces; a lock held by a live pid (ten stubbed sleeps, the
#    UNSERIALIZED WARN, the records written, the lock left to its holder); an
#    unreadable ledger ends the run with 2 before the merge
ledger() { printf -- "$1" >"$H/home/state/.landings"; }
mrepo r7; mcrew r7 c7a 'a b.txt'; mmeta c7a r7
mput home/data/live/room.md 'x\n'; mput home/data/archive/2025/arch/room.md 'x\n'
ledger "$((NOW - 8 * 86400))\told\ta b.txt\n$((NOW - 3600))\tlive\ta b.txt\n$((NOW - 7200))\tarch\ta b.txt\n$((NOW - 60))\tc7a\ta b.txt\n$((NOW - 25 * 3600))\tstranger\ta b.txt\n"
mland c7a
assert_eq "$M_RC:$(m_err)" "0:WARN: LANDING-OVERLAP: a b.txt landed 1h ago by family live - required reading: HOME/home/data/live/room.md
WARN: LANDING-OVERLAP: a b.txt landed 2h ago by family arch - required reading: HOME/home/data/archive/2025/arch/room.md
$(kgap c7a r7)" "6: the foreign records warn, live and archived rooms"
assert_eq "$(cat "$H/home/state/.landings")" "$((NOW - 3600))	live	a b.txt
$((NOW - 7200))	arch	a b.txt
$((NOW - 60))	c7a	a b.txt
$((NOW - 25 * 3600))	stranger	a b.txt
$NOW	c7a	a b.txt" "6: the >7d record pruned, the land appended"
mcrew r7 c7b b.txt; mmeta c7b r7
mkdir -p "$H/home/state/.landings.lock"; printf '%s\n' "$$" >"$H/home/state/.landings.lock/pid"
mland c7b
assert_eq "$M_RC:$(tail -n 1 "$TMP/m.err")" "0:WARN: landing ledger: HOME/home/state/.landings.lock could not be acquired within 10s - recording UNSERIALIZED, so a concurrent landing's records may be lost and its <24h LANDING-OVERLAP warn may not fire for them" "6: the UNSERIALIZED WARN after the knowledge flag"
assert_eq "$(wc -l <"$H/sleep.log" | tr -d ' ')" 10 "6: ten waits, each a spawned sleep"
assert_eq "$(tail -n 1 "$H/home/state/.landings")" "$NOW	c7b	b.txt" "6: recorded anyway"
assert_eq "$(cat "$H/home/state/.landings.lock/pid")" "$$" "6: the holder keeps its lock"
rm -rf "$H/home/state/.landings.lock" "$H/sleep.log"
if [ "$(id -u)" != 0 ]; then
  mcrew r7 c7e e.txt; mmeta c7e r7
  ledger "$((NOW - 10))\tx\te.txt\n"
  chmod 000 "$H/home/state/.landings"
  mland c7e
  chmod 644 "$H/home/state/.landings"
  assert_eq "$M_RC:$(m_out)" "2:" "6: an unreadable ledger ends the run with 2"
  mlanded r7 c7e && fail "6: ...before the merge"
fi

# 7. the qa gate through the entry: map scopes with no yaml scopes (MODE
#    MISMATCH), the RETIRED legacy config (its die is the run's exit - no
#    blocked line), the require_for_ship spellings (anything but a false
#    spelling enforces: a quoted `true`, `True` and a comment after `true` do,
#    a quoted `No` with a comment and a CR does not, no key does not), an
#    unreadable yaml (its refusal is the run's exit), `00` counts (an invalid
#    marker), every key counting (a flow header, a nested false before a
#    quoted top-level true), and a project_dir that is a linked worktree
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
MBLOCKED='ERROR: local merge blocked by qa.require_for_ship (see message above)'
sha12() { git -C "$H/home/projects/$1" rev-parse "crew/$1" | cut -c1-12; }
nomark() { printf 'WARN: qa.require_for_ship: no passing crew-qa run recorded for %s - run crew-qa on this head before merging\n%s' "$(sha12 "$1")" "$MBLOCKED"; }
gate_repo q3 "$REQ"; mput home/records/repo-knowledge/q3.md '- scope orchid = orchid-service | src: cmd:true | at: d 2026-07-21 | by: fam\n'
mland q3
assert_eq "$M_RC" 1 "7: map scopes, no yaml - refused"
assert_contains "$(m_err)" "MODE MISMATCH - the repo-knowledge record declares scopes" "7: map scopes, no yaml"
gate_repo q5 "$REQ"; mput home/config/projects/q5.yaml "$REQ"
mland q5
assert_eq "$M_RC:$(m_err)" "1:ERROR: project config for 'q5' found at the RETIRED legacy path (HOME/home/config/projects/q5.yaml), which is no longer read - move it: mv \"HOME/home/config/projects/q5.yaml\" \"HOME/home/projects/q5.yaml\" (or delete it if HOME/home/projects/q5.yaml is already authoritative)" "7: RETIRED - the die is the exit"
gate_repo q6 'qa:\n  require_for_ship: "true"\n'
mland q6; assert_eq "$M_RC:$(m_err)" "1:$(nomark q6)" "7: a quoted true enforces"
gate_repo q7 'qa:\n  require_for_ship: True\n'
mland q7; assert_eq "$M_RC:$(m_err)" "1:$(nomark q7)" "7: True enforces"
gate_repo q8 'qa:\n  other: 1\n'
mland q8; assert_eq "$M_RC:$(m_out)" "0:fast-forwarded main to crew/q8" "7: no require_for_ship"
gate_repo q9 'qa:\r\n  require_for_ship: "No" # off\r\n'
mland q9; assert_eq "$M_RC:$(m_out)" "0:fast-forwarded main to crew/q9" "7: a false spelling is not enforced"
gate_repo qw1 'qa:\n  require_for_ship: true # on\n'
mland qw1; assert_eq "$M_RC:$(m_err)" "1:$(nomark qw1)" "7: a comment after true enforces"
if [ "$(id -u)" != 0 ]; then
  gate_repo qw3 "$REQ"
  chmod 000 "$H/home/projects/qw3.yaml"; mland qw3; chmod 644 "$H/home/projects/qw3.yaml"
  assert_eq "$M_RC:$(m_out)" "1:" "7: an unreadable yaml ends the run with 1, nothing landed"
  assert_eq "$(m_err)" "ERROR: qa.require_for_ship: the project policy HOME/home/projects/qw3.yaml cannot be read - refusing the merge rather than reading it as not enforced" "7: ...its refusal alone, no blocked line"
fi
gate_repo qw13 "$REQ"; marker qw13 ''
qw13f="$H/home/projects/qw13/.crew/qa/passed/$(git -C "$H/home/projects/qw13" rev-parse crew/qw13)"
LC_ALL=C sed -e 's/^cases_passed=1$/cases_passed=00/' -e 's/^cases_total=1$/cases_total=00/' "$qw13f" >"$qw13f.t"; mv "$qw13f.t" "$qw13f"
mland qw13
assert_eq "$M_RC:$(m_err)" "1:WARN: qa.require_for_ship: ignored invalid flat QA attestation for $(sha12 qw13): invalid case counts
$(nomark qw13)" "7: 00 case counts are an invalid marker"
gate_repo qk1 'qa: {serve: x, require_for_ship: true}\n'
mland qk1; assert_eq "$M_RC:$(m_err)" "1:$(nomark qk1)" "7: a flow mapping on the qa: header enforces"
gate_repo qk2 'qa:\n  app:\n    require_for_ship: false\n  "require_for_ship" : true\n'
mland qk2; assert_eq "$M_RC:$(m_err)" "1:$(nomark qk2)" "7: a nested false before a quoted top-level true enforces"
# The primary checkout moved off main, main checked out in the linked worktree
# $H/wt-qwt, which is the meta's project_dir.
gate_repo qwt "$REQ"; marker qwt ''
git -C "$H/home/projects/qwt" checkout -q -b side; git -C "$H/home/projects/qwt" worktree add -q "$H/wt-qwt" main
printf 'project_dir=%s\nworktree=%s\n' "$H/wt-qwt" "$H/home/projects/qwt/.crew/worktrees/1" >"$H/home/state/qwt.meta"
mland qwt
assert_eq "$M_RC:$(m_out)" "0:fast-forwarded main to crew/qwt" "7: a linked worktree lands on the main repo's yaml and marker"
assert_eq "$(git -C "$H/wt-qwt" rev-parse main)" "$(git -C "$H/home/projects/qwt" rev-parse crew/qwt)" "7: ...main moved in the worktree"

# 8. an epic or feature record: the deferred qa line on STDOUT, the target
#    only on origin (cut from it), the ref-only ff and its push=yes, the
#    no-op, the in-place ff (target checked out) and its failure, the ref-only
#    failure (target checked out in a linked worktree), a failing push (the
#    WARN, the landing stands), the target nowhere (epic and feature
#    remedies), --no-ff refused, the non-ff refused, an unreadable ledger, a
#    push=deferred feature landing (no push)
ep="$H/home/projects/ep"
minit "$H/src-ep"
git clone -q --bare "$H/src-ep" "$H/remotes/ep.git"
git clone -q "$H/remotes/ep.git" "$ep"
git -C "$ep" config user.email test@test; git -C "$ep" config user.name test
mput home/records/backlog.md '- [ ] e1-s1 [src:cap flow:direct mode:local-only qa:no] - story one; epic:e1 (repo: ep)\n- [ ] e1-s2 [src:cap flow:direct mode:local-only qa:no] - story two; epic:e1 (repo: ep)\n- [ ] f1-m1 [src:cap flow:direct mode:feature-pr qa:no] - member; feature:f1 (repo: ep)\n'
mput home/data/e1/branches 'ep epic/e1 push=yes\n'
mput home/data/f1/branches 'ep feat/f1 push=deferred\n'
mmeta e1-s1 ep; mmeta e1-s2 ep; mmeta f1-m1 ep
git -C "$ep" checkout -q -b crew/e1-s1; printf 's1\n' >"$ep/s1.txt"; git -C "$ep" add -A; gitc -C "$ep" commit -qm s1; git -C "$ep" checkout -q main
mland e1-s1
assert_eq "$M_RC:$(m_err)" "1:ERROR: epic target epic/e1 exists neither locally nor on origin - cut it first: ac-epic-branch.sh create <epic> ep" "8: the target nowhere"
git -C "$H/src-ep" branch epic/e1; git -C "$H/src-ep" push -q "$H/remotes/ep.git" epic/e1:epic/e1; git -C "$ep" fetch -q origin
mland e1-s1
assert_eq "$M_RC:$(tail -n 3 "$TMP/m.out")" "0:qa.require_for_ship: deferred to the epic gate (epic-branch landing)
fast-forwarded epic/e1 to crew/e1-s1 (ref-only)
pushed epic/e1 to origin (record push=yes)" "8: the target cut from origin, then the ref-only ff and its push"
assert_eq "$(cat "$H/home/state/e1-s1.status")" "$FIXED merged: local epic/e1 (epic)" "8: the epic status line"
assert_eq "$(git -C "$H/remotes/ep.git" rev-parse epic/e1)" "$(git -C "$ep" rev-parse crew/e1-s1)" "8: origin followed"
mland e1-s1
assert_eq "$M_RC:$(m_out)" "0:qa.require_for_ship: deferred to the epic gate (epic-branch landing)
epic/e1 already contains crew/e1-s1; nothing to move
pushed epic/e1 to origin (record push=yes)" "8: the no-op still pushes"
mland e1-s1 --no-ff
assert_eq "$M_RC:$(tail -n 1 "$TMP/m.err")" "1:ERROR: --no-ff is not available for an epic-branch landing: a merge commit onto epic/e1 belongs in a leased worktree, never the primary checkout - rebase crew/e1-s1 onto epic/e1 and land ff, or route the merge through the epic gate" "8: --no-ff refused"
git -C "$ep" checkout -q epic/e1; git -C "$ep" checkout -q -b crew/e1-s2; printf 's2\n' >"$ep/s2.txt"; git -C "$ep" add -A; gitc -C "$ep" commit -qm s2
git -C "$ep" checkout -q epic/e1; printf 'stray\n' >"$ep/s2.txt"
mland e1-s2
assert_eq "$M_RC" 1 "8: the in-place failure exits 1"
assert_contains "$(m_err)" "ERROR: ff of epic/e1 (checked out) from crew/e1-s2 failed: " "8: the in-place failure"
assert_contains "$(m_err)" "(epic/e1 untouched)" "8: ...epic/e1 untouched"
rm -f "$ep/s2.txt"
mland e1-s2
assert_eq "$M_RC:$(sed -n 2p "$TMP/m.out")" "0:fast-forwarded epic/e1 to crew/e1-s2 (in place)" "8: the in-place ff"
git -C "$ep" checkout -q -B crew/e1-s1 epic/e1~1
printf 's1 again\n' >"$ep/s1b.txt"; git -C "$ep" add -A; gitc -C "$ep" commit -qm s1b; git -C "$ep" checkout -q main
mland e1-s1
assert_eq "$M_RC:$(tail -n 1 "$TMP/m.err")" "1:ERROR: crew/e1-s1 is not fast-forwardable: epic/e1 has diverged from it (a sibling story landed first). Rebase crew/e1-s1 onto epic/e1 and re-run the plain land" "8: the non-ff epic"
git -C "$ep" checkout -q -B crew/e1-s1 epic/e1; printf 's1c\n' >"$ep/s1c.txt"; git -C "$ep" add -A; gitc -C "$ep" commit -qm s1c; git -C "$ep" checkout -q main
git -C "$ep" worktree add -q "$H/wt-ep" epic/e1
mland e1-s1
assert_eq "$M_RC" 1 "8: the ref-only failure exits 1"
assert_contains "$(m_err)" "ERROR: ff update of epic/e1 from crew/e1-s1 failed: " "8: the ref-only failure"
assert_contains "$(m_err)" "(epic/e1 untouched)" "8: ...epic/e1 untouched"
git -C "$ep" worktree remove --force "$H/wt-ep"; git -C "$ep" remote set-url origin "$H/nowhere.git"
mland e1-s1
assert_eq "$M_RC:$(tail -n 1 "$TMP/m.err")" "0:WARN: push of epic/e1 to origin FAILED - the landing stands; retry: git -C HOME/home/projects/ep push --no-verify origin epic/e1" "8: a failing push"
assert_eq "$(sed -n 2p "$TMP/m.out")" "fast-forwarded epic/e1 to crew/e1-s1 (ref-only)" "8: ...the landing stands"
git -C "$ep" checkout -q -b crew/f1-m1; printf 'm1\n' >"$ep/m1.txt"; git -C "$ep" add -A; gitc -C "$ep" commit -qm m1; git -C "$ep" checkout -q main
mland f1-m1
assert_eq "$M_RC:$(m_err)" "1:ERROR: feature target feat/f1 does not exist locally - cut it first: ac-feature.sh create <feature> ep" "8: the feature target missing"
git -C "$ep" branch feat/f1 main
mland f1-m1
assert_eq "$M_RC:$(m_out)" "0:qa.require_for_ship: deferred to the feature ship gate (feature-branch landing)
fast-forwarded feat/f1 to crew/f1-m1 (ref-only)" "8: the feature landing, never pushed"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H/home/records/backlog.md"; mland f1-m1; chmod 644 "$H/home/records/backlog.md"
  assert_eq "$M_RC:$(m_out):$(m_err)" "1::ERROR: cannot read the ledger to resolve the epic-branch fence for f1-m1" "8: an unreadable ledger"
fi

# 9. the guard rides first: a stale watcher beat is WATCHER-DOWN on stderr
#    before the entry's own lines, and stamps state/.guard-stamp
printf '1\n' >"$H/home/state/.last-watcher-beat"
mland nosuch
assert_eq "$M_RC:$(m_err)" "1:WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh
ERROR: no crewmate meta for nosuch" "9: the guard first"
[ -e "$H/home/state/.guard-stamp" ] || fail "9: the guard stamped"

# 10. the ROOT seam: a lab bin/ whose root links src/ starts the module from
#     the distro checkout, yet its guard and the remedy's ac-know.sh are the
#     LAB's - as the original's $(dirname "$0") and ac_root named its own bin/
#     (STARTED_BIN, never import.meta.dir). The gate is not the lab's: its
#     ac-qa-lib.sh override of ac_qa_gate_ok (a stray lib planted in the lab
#     bin/) would open the gate on a head with no marker, and the twin in
#     src/lib-qa-gate.ts refuses that head flat
LAB="$TMP/mlab"; mkdir -p "$LAB/bin"; cp "$BIN"/*.sh "$LAB/bin/"; ln -s "$ROOT/src" "$LAB/src"
rm -f "$LAB/bin/ac-guard.sh"
printf 'ac_qa_gate_ok() { printf '"'"'lab gate %%s\\n'"'"' "$3"; }\n' >"$LAB/bin/ac-qa-lib.sh"
gate_repo lab "$REQ"; rm -f "$H/home/state/.guard-stamp"
lab_land() { (cd "$H" && env -u AC_HOME LC_ALL=C PATH="$MSTUBS:$PATH" AC_HOME="$H/home" AC_GUARD_ROOT="$TMP/mguard-root" "$LAB/bin/ac-merge-local.sh" lab 2>"$TMP/lab.err"); }
out="$(lab_land)" && fail "10: the lab's gate override must not open the port's gate"
assert_eq "$out" "" "10: no land"
assert_eq "$(cat "$TMP/lab.err")" "$(nomark lab)" "10: the flat refusal - the lab's ac_qa_gate_ok is not consulted"
marker lab ''
out="$(lab_land)" || fail "10: the lab land"
assert_eq "$out" "fast-forwarded main to crew/lab" "10: no lab gate line"
case "$(cat "$TMP/lab.err")" in *WATCHER-DOWN*) fail "10: the lab has no guard, yet one ran" ;; esac
assert_contains "$(cat "$TMP/lab.err")" "record what it learned ($LAB/bin/ac-know.sh add" "10: the remedy names the lab's bin/"

# 11. --expect lands on a unique prefix of the branch's head
mrepo rx; mcrew rx x1; mmeta x1 rx
mland x1 --expect "$(git -C "$H/home/projects/rx" rev-parse crew/x1 | cut -c1-12)"
assert_eq "$M_RC:$(m_out)" "0:fast-forwarded main to crew/x1" "11: a unique prefix of the head lands"

pass
