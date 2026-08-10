#!/usr/bin/env bash
# ac-know.test.sh - the per-project repo-knowledge record (bin/ac-know.sh).
#
# Covers, guard class by guard class (the script header owns the contracts):
#   - the record file: header, `## Superseded` marker, and the exact composed
#     entry line, plus the `recorded in <path>` receipt;
#   - AC13, the validating writer: every refusal NAMES the missing part;
#   - HOME MISRESOLUTION - all five doors of ac_home_resolve's ladder,
#     including the SYMLINK that resolves back inside the repo and the
#     directional inverse (a fleet home legitimately contains its clones);
#   - EVIDENCE/REF DIVERGENCE (the false-FRESH class) - one case per door:
#     A dirty (unstaged AND staged), B clean tree with a wrong --at, G a
#     moving symbolic ref, E an abbreviated sha, plus an unresolvable ref and
#     a `git diff` that ERRORS rather than differs;
#   - RECORD INJECTION - newline/CR/`|` in every free-form field, --family
#     outside the id grammar, and the forgery case counted in PHYSICAL lines;
#   - UNFOLLOWABLE PROVENANCE - the four --src-file checks;
#   - AC20, the digest bound: 1 entry vs 50 costs the session-start digest a
#     constant, not 49 lines;
#   - RETIRE - a `fact` addressed by quoted phrase (never a line number),
#     narrowed by `--by` on ambiguity, zero/multiple-match refusals, the
#     byte-identical move plus its own `--why` receipt, `verify` reporting
#     live entries only afterwards, and the record's own lock actually being
#     taken (a held lock makes retire TIME OUT rather than write);
#   - the CITATION GUARD on `add --fact`: both directions - a
#     `repo-knowledge:<n>` / `.../repo-knowledge/<name>.md:<n>` pointer is
#     refused, an ordinary code citation like `bin/ac-tree.sh:405` is not.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
KNOW="$BIN/ac-know.sh"

refuses() {
  # refuses <named-part> <cmd...> - the command FAILS and its message NAMES
  # what is missing. AC13 is about the second half: a refusal that does not
  # say what is wrong is a refusal the author cannot act on.
  local want="$1" out
  shift
  out="$("$@" 2>&1)" && fail "expected refusal (wanted '$want'): $*"
  assert_contains "$out" "$want" "refusal names '$want'"
}

# --- happy path: the composed entry, byte for byte ---------------------------
repo="$(make_repo proj)"
rec="$AC_HOME/records/repo-knowledge/proj.md"
sha="$(git -C "$repo" rev-parse HEAD)"
today="$(date -u +%F)"

out="$("$KNOW" add --home "$AC_HOME" --repo "$repo" --family fam-one \
  --src-file file.txt:1 --fact 'file.txt holds the greeting')"
assert_file "$rec" "the first add creates the record"
assert_contains "$out" "recorded in $rec" "the write prints the path it used"
body="$(cat "$rec")"
assert_contains "$body" "# Repo knowledge: proj" "record carries its header"
assert_contains "$body" "## Superseded" "record carries the section marker from the start"
assert_contains "$body" \
  "- fact file.txt holds the greeting | src: file:file.txt:1 | at: $sha $today | by: fam-one" \
  "the composed entry line"

# A second entry, cmd: provenance - it lands LIVE, above the marker.
"$KNOW" add --home "$AC_HOME" --repo "$repo" --family fam-two \
  --src-cmd 'ls file.txt' --fact 'one tracked file at the root' >/dev/null
assert_contains "$(cat "$rec")" "| src: cmd:ls file.txt |" "cmd: provenance is tagged, never guessed"
assert_eq "$(awk '/^## Superseded/ { exit } /^- /' "$rec" | wc -l | tr -d ' ')" "2" \
  "both entries are LIVE (above the marker)"

# --- AC13: the writer refusals, each naming the missing part -----------------
add() { "$KNOW" add --home "$AC_HOME" --repo "$repo" --family fam-one "$@"; }

refuses "no provenance" add --fact 'no source at all'
refuses "ONE provenance" add --src-file file.txt:1 --src-cmd ls --fact 'two sources'
refuses "no subject" add --src-file file.txt:1
refuses "unknown flag" "$KNOW" add --home "$AC_HOME" --repo "$repo" --family fam-one \
  --src-file file.txt:1 --scope orchid --apps a,b
refuses "no attribution" "$KNOW" add --home "$AC_HOME" --repo "$repo" \
  --src-file file.txt:1 --fact 'unattributed'

# --- guard class: UNFOLLOWABLE PROVENANCE (the four --src-file checks) -------
refuses "--src-file wants <path>:<line>" add --src-file file.txt --fact 'no line'
refuses "repo-relative" add --src-file /etc/passwd:1 --fact 'absolute'
refuses "repo-relative" add --src-file 'a/../../etc/passwd:1' --fact 'dot dot'
refuses "does not exist at" add --src-file nope.txt:1 --fact 'unaddressable'
refuses "has 1 lines at" add --src-file file.txt:99 --fact 'past EOF'
# ...and the door that is NOT a bad path but a path naming something that is
# not a FILE. `cat-file -e` succeeds for a tree and `cat-file -p` prints its
# LISTING, so `apps:2` clears an existence check AND a line-bound check and
# means "line 2 of a directory" - a citation no reader can follow, which
# `verify` would then stamp FRESH. Every shape of that door, closed by one
# object-type test:
mkdir -p "$repo/apps/a"
printf 'x\n' >"$repo/apps/a/main.ts"
ln -s apps/a/main.ts "$repo/link.ts"
git -C "$repo" add -A && git -C "$repo" commit -qm apps
refuses "is a tree" add --src-file apps:1 --fact 'a directory is not a file'
refuses "is a tree" add --src-file apps/:1 --fact 'nor is one with a trailing slash'
refuses "names no path" add --src-file :1 --fact 'and <at>: is the ROOT tree, which also has lines'
# A SYMLINK is a blob whose single line is its target, so its citation IS
# followable and stays legal - the guard is "not a file", not "not a regular
# source file".
add --src-file link.ts:1 --fact 'a symlink cites its target and is followable' >/dev/null

# --- guard class: HOME MISRESOLUTION -----------------------------------------
# (ii) relative --home.
refuses "ABSOLUTE" "$KNOW" add --home rel/home --repo "$repo" --family fam-one \
  --src-file file.txt:1 --fact 'relative home'
# (iii) --home textually inside the repo.
refuses "inside" "$KNOW" add --home "$repo" --repo "$repo" --family fam-one \
  --src-file file.txt:1 --fact 'home inside repo'
# (iv) a SYMLINK resolving back inside the repo - the door a textual
# comparison walks straight past.
mkdir -p "$repo/.crew/evil"
ln -s "$repo/.crew/evil" "$TMP/evil-home"
refuses "inside" "$KNOW" add --home "$TMP/evil-home" --repo "$repo" --family fam-one \
  --src-file file.txt:1 --fact 'symlinked home'
assert_no_file "$repo/.crew/evil/records" "the refusal minted nothing inside the repo"
# (v) the inverse that must NOT refuse: a fleet home legitimately CONTAINS its
# clones, so the containment test is directional. A symmetric guard would
# refuse every standard fleet.
outer="$TMP/outerhome"
mkdir -p "$outer/projects"
inner="$(cd "$outer/projects" && git init -q -b main inner && cd inner \
  && git config user.email t@t && git config user.name t \
  && printf 'x\n' >f.txt && git add -A && git commit -qm init && pwd -P)"
"$KNOW" add --home "$outer" --repo "$inner" --family fam-one \
  --src-file f.txt:1 --fact 'a home containing its clone is the normal layout' >/dev/null
assert_file "$outer/records/repo-knowledge/inner.md" "home containing the repo is accepted"

# (i) NO RUNG 3: no --home, no AC_HOME -> REFUSE. It was the last silent path
# by which the distro checkout became a fleet home, and it caught only calls
# that had lost their --home - "catching" them by writing into whatever
# checkout owned the running bin/, which in a leased worktree is discarded on
# return. Run from a COPY of bin/ so a regression writes into the copy rather
# than the live checkout, and assert BOTH that it refuses and that it wrote
# nothing.
fake="$TMP/fakecheckout"
mkdir -p "$fake/bin"
cp "$BIN/ac-know.sh" "$BIN/ac-lib.sh" "$BIN/ac-harness.sh" "$BIN/ac-pipeline-lib.sh" "$fake/bin/"
out="$(env -u AC_HOME "$fake/bin/ac-know.sh" add --repo "$repo" --family fam-one \
  --src-file file.txt:1 --fact 'a homeless call must refuse, not write here' 2>&1)" \
  && fail "a homeless add must REFUSE, never adopt the checkout"
assert_contains "$out" "no fleet home" "the refusal names what is missing"
assert_contains "$out" "--home" "and the first fix"
assert_contains "$out" "AC_HOME" "and the second"
assert_contains "$out" "brief" "and points a crewmate at the --home-carrying line its brief already baked"
assert_no_file "$fake/records/repo-knowledge/proj.md" "a refused homeless add writes NOTHING into the checkout"

# --- guard class: EVIDENCE/REF DIVERGENCE (the false-FRESH class) ------------
bind="$(make_repo bindrepo)"
printf 'v-A\n' >"$bind/code.txt"
git -C "$bind" add -A && git -C "$bind" commit -qm A
sha_a="$(git -C "$bind" rev-parse HEAD)"
printf 'v-B\n' >"$bind/code.txt"
git -C "$bind" add -A && git -C "$bind" commit -qm B
sha_b="$(git -C "$bind" rev-parse HEAD)"
badd() { "$KNOW" add --home "$AC_HOME" --repo "$bind" --family fam-bind "$@"; }

# Door A - the cited path is dirty. UNSTAGED and STAGED are two cases: a
# HEAD-relative `git status` reading would miss neither, but a commit-to-commit
# diff misses both, and that is the shape that manufactured the false FRESH.
printf 'v-C\n' >"$bind/code.txt"
refuses "differs between the worktree" badd --src-file code.txt:1 --fact 'unstaged evidence'
git -C "$bind" add code.txt
refuses "differs between the worktree" badd --src-file code.txt:1 --fact 'staged evidence'
git -C "$bind" checkout -q -- . && git -C "$bind" reset -q --hard >/dev/null

# ...and the strictness lands where the danger is and NOWHERE else: the check
# is PER-PATH, so citing a clean file while editing another one succeeds.
printf 'other\n' >"$bind/file.txt"
badd --src-file code.txt:1 --fact 'a clean citation in a dirty tree is still bound' >/dev/null
# cmd: is stricter by nature - its output can depend on any part of the tree.
refuses "the tracked tree differs from" badd --src-cmd 'ls' --fact 'cmd in a dirty tree'
git -C "$bind" checkout -q -- file.txt

# Door B - CLEAN tree at B, entry claims A. r4's HEAD-relative check accepted
# this; the tree is clean *relative to HEAD*, which says nothing about <at>.
refuses "differs between the worktree" badd --at "$sha_a" --src-file code.txt:1 --fact 'wrong ref, clean tree'
refuses "the tracked tree differs from" badd --at "$sha_a" --src-cmd 'ls' --fact 'wrong ref, cmd'

# Door G - a symbolic ref binds today and re-points tomorrow, so it may never
# survive into the record: what lands is the RESOLVED sha.
git -C "$bind" branch tracker "$sha_b"
brec="$AC_HOME/records/repo-knowledge/bindrepo.md"
badd --at tracker --src-file code.txt:1 --fact 'bound through a branch name' >/dev/null
assert_contains "$(cat "$brec")" "at: $sha_b " "a branch --at is recorded as its resolved 40-char sha"
git -C "$bind" branch -f tracker "$sha_a"
assert_contains "$(cat "$brec")" "at: $sha_b " "moving the branch changes no recorded entry"

# Door E - an abbreviation is a rendering, not an identity.
badd --at "${sha_b:0:7}" --src-file code.txt:1 --fact 'bound through a short sha' >/dev/null
assert_contains "$(grep 'bound through a short sha' "$brec")" "at: $sha_b " \
  "a short --at is expanded to the full sha"

# An unresolvable --at refuses rather than defaulting to anything.
refuses "does not resolve to a commit" badd --at nosuchref --src-file code.txt:1 --fact 'ghost ref'

# ...and a `git diff` that ERRORS refuses like a difference. Exit >1 is an
# ERROR, never "clean": the commit object still resolves, but its tree is gone,
# so nothing can be compared against it. cmd: is the tag that reaches the
# binding first (file: refuses one check earlier, on addressability).
broke="$(make_repo brokerepo)"
tree="$(git -C "$broke" rev-parse 'HEAD^{tree}')"
rm -f "$broke/.git/objects/${tree:0:2}/${tree:2}"
if git -C "$broke" diff --quiet HEAD >/dev/null 2>&1; then
  fail "fixture is not broken: git diff still reads the tree"
fi
refuses "failing closed" "$KNOW" add --home "$AC_HOME" --repo "$broke" --family fam-bind \
  --src-cmd 'ls' --fact 'unreadable tree'

# --- guard class: RECORD INJECTION -------------------------------------------
before_lines="$(wc -l <"$rec" | tr -d ' ')"
for bad in $'a\nb' $'a\rb'; do
  refuses "single line" add --src-file file.txt:1 --fact "$bad"
  refuses "single line" add --src-cmd "$bad" --fact 'cmd with a break'
  refuses "single line" add --src-file "$bad:1" --fact 'src-file with a break'
done
refuses "field separator" add --src-file file.txt:1 --fact 'a | b'
refuses "--family must match" "$KNOW" add --home "$AC_HOME" --repo "$repo" --family 'Bad_Family' \
  --src-file file.txt:1 --fact 'bad family'

# The forgery, counted in PHYSICAL lines: a --fact carrying a whole second
# entry is REJECTED, so the record gains nothing. This script's own printf
# stays the only source of lines in the file.
refuses "single line" add --src-file file.txt:1 \
  --fact "$(printf 'benign\n- scope orchid = evil-app | src: file:a:1 | at: x 2026-07-21 | by: other-family')"
assert_eq "$(wc -l <"$rec" | tr -d ' ')" "$before_lines" "a rejected forgery adds no physical line"

# --- AC18: verify - one line per LIVE entry, one token per state -------------
# The load-bearing case is FRESH-vs-SUSPECT under a WORKTREE-ONLY change: an
# <at>..HEAD compare sees neither the index nor the worktree, and reporting
# FRESH for a fact its own ref never held is worse than no detector at all.
vrepo="$(make_repo verifyrepo)"
printf 'stable\n' >"$vrepo/keep.txt"
printf 'moves\n' >"$vrepo/churn.txt"
printf 'doomed\n' >"$vrepo/gone.txt"
git -C "$vrepo" add -A && git -C "$vrepo" commit -qm seed
vadd() { "$KNOW" add --home "$AC_HOME" --repo "$vrepo" --family fam-v "$@" >/dev/null; }
vadd --src-file keep.txt:1 --fact 'keep is stable'
vadd --src-file churn.txt:1 --fact 'churn is not'
vadd --src-file gone.txt:1 --fact 'gone will go'
vadd --src-cmd 'ls *.txt' --fact 'three txt files'

# A record with no entry for a ref that still exists is verified against the
# WORKTREE, so an uncommitted edit is what makes the entry SUSPECT.
printf 'moved\n' >"$vrepo/churn.txt"
rm "$vrepo/gone.txt"
vout="$("$KNOW" verify --home "$AC_HOME" --repo "$vrepo")"
assert_contains "$vout" "FRESH   - fact keep is stable" "an unchanged citation is FRESH"
assert_contains "$vout" "SUSPECT - fact churn is not" "a WORKTREE-only change is SUSPECT, never FRESH"
assert_contains "$vout" "(churn.txt changed since" "the SUSPECT line names what moved"
assert_contains "$vout" "(gone.txt no longer exists)" "a deleted citation is SUSPECT and says so"
assert_contains "$vout" "MANUAL  - fact three txt files" \
  "a cmd: entry has nothing to diff, so it never reports FRESH"
assert_contains "$vout" "(re-run: ls *.txt)" "the MANUAL line hands back the command to re-run"

# The ref itself can vanish (a squash, a prune) - that is UNVERIFIABLE, which
# is distinguishable from both FRESH and SUSPECT.
vrec="$AC_HOME/records/repo-knowledge/verifyrepo.md"
sed -e 's/at: [0-9a-f]\{40\} /at: 0000000000000000000000000000000000000000 /' "$vrec" >"$vrec.x"
mv "$vrec.x" "$vrec"
assert_contains "$("$KNOW" verify --home "$AC_HOME" --repo "$vrepo")" "UNVERIFIABLE" \
  "a ref that no longer resolves in this clone is UNVERIFIABLE"

# --- AC19: door N - an app tree that lives ONLY on an integration branch this
# clone never checked out (ship-config-and-know-citation-blind-spots defect
# 2). This is the REAL situation, not a fixture standing in for it: a genuine
# second branch, a genuine path this checkout's tree never had, verified with
# --at naming that branch's own commit exactly as the order's remedy names it. -
irepo="$(make_repo introrepo)"
printf 'base\n' >"$irepo/README"
git -C "$irepo" add -A && git -C "$irepo" commit -qm base
git -C "$irepo" checkout -qb integration
mkdir -p "$irepo/apps/onlyintegration"
printf 'line1\nline2\nline3\n' >"$irepo/apps/onlyintegration/feature.sh"
git -C "$irepo" add -A && git -C "$irepo" commit -qm 'integration-only app tree'
int_sha="$(git -C "$irepo" rev-parse HEAD)"
git -C "$irepo" checkout -q main
# Both doors were shut before this fix: the default --at HEAD dies at
# validate_src_file (the path does not exist on main at all), and the
# remedy the OLD refusal named - an explicit --at that contains what was
# seen - died at assert_bound instead, because the checked-out tree does not
# hold that integration tree. Reproduce the first door, then take the
# remedy's own advice for the second and prove it now succeeds.
refuses "does not exist" "$KNOW" add --home "$AC_HOME" --repo "$irepo" --family fam-int \
  --src-file apps/onlyintegration/feature.sh:2 --fact 'default --at HEAD cannot see an integration-only path'
iout="$("$KNOW" add --home "$AC_HOME" --repo "$irepo" --family fam-int \
  --src-file apps/onlyintegration/feature.sh:2 --at "$int_sha" \
  --fact 'integration-only feature line 2')"
assert_contains "$iout" "recorded in" \
  "an integration-only citation, --at the branch that actually holds it, is no longer refused"
irec="$AC_HOME/records/repo-knowledge/introrepo.md"
assert_contains "$(cat "$irec")" "fact integration-only feature line 2" \
  "the integration-only fact is durably recorded, not merely accepted and dropped"

# verify reports it honestly: not FRESH (no live copy to prove unchanged), and
# NOT SUSPECT (nothing about it rotted) - UNVERIFIABLE, naming why.
ivout="$("$KNOW" verify --home "$AC_HOME" --repo "$irepo")"
assert_contains "$ivout" "UNVERIFIABLE - fact integration-only feature line 2" \
  "an integration-only fact verifies as UNVERIFIABLE, never a false FRESH or a false SUSPECT"
assert_contains "$ivout" "no worktree copy in this clone to compare against ${int_sha:0:12}" \
  "the UNVERIFIABLE line names why: no live copy in this clone, not rot"

# Door A/B stay SHUT: a path this branch's own history really did delete
# (<at> IS an ancestor of HEAD) must still refuse, proving door N is scoped to
# "never on this branch," not loosened into "absent from disk, no questions
# asked."
printf 'temp\n' >"$irepo/deleteme.txt"
git -C "$irepo" add -A && git -C "$irepo" commit -qm 'add deleteme'
del_sha="$(git -C "$irepo" rev-parse HEAD)"
git -C "$irepo" rm -q deleteme.txt && git -C "$irepo" commit -qm 'remove deleteme'
refuses "differs between the worktree" "$KNOW" add --home "$AC_HOME" --repo "$irepo" --family fam-int \
  --src-file deleteme.txt:1 --at "$del_sha" --fact 'a same-branch deletion must still refuse'

# ...and the same door, on its OWN-BRANCH edge: a LOCAL, UNCOMMITTED deletion
# under the DEFAULT --at HEAD (mirrors gone.txt's verify-side shape, on the add
# path this time - HEAD is trivially its own ancestor, so this must refuse
# exactly like any other dirty-worktree door A case, never fall through door N).
printf 'here for now\n' >"$irepo/localgone.txt"
git -C "$irepo" add -A && git -C "$irepo" commit -qm 'add localgone'
rm "$irepo/localgone.txt"
refuses "differs between the worktree" "$KNOW" add --home "$AC_HOME" --repo "$irepo" --family fam-int \
  --src-file localgone.txt:1 --fact 'a local uncommitted deletion must still refuse under default --at HEAD'

# `## Superseded` is history, not a claim: it is never verified.
printf -- '- fact superseded claim | src: file:keep.txt:1 | at: %s 2026-07-21 | by: fam-old\n' \
  "$(git -C "$vrepo" rev-parse HEAD)" >>"$vrec"
assert_eq "$("$KNOW" verify --home "$AC_HOME" --repo "$vrepo" | grep -c 'superseded claim')" "0" \
  "superseded entries are history and are not verified"

# --- RETIRE: the crewmate-tier, locked inverse of `add` for a `fact` --------
# Addressed by a phrase QUOTED from the entry's own text, never a line number
# (the record has no stable per-entry identity - see the header).
rrepo="$(make_repo retrepo)"
rrec="$AC_HOME/records/repo-knowledge/retrepo.md"
radd() { "$KNOW" add --home "$AC_HOME" --repo "$rrepo" --family fam-r --src-file file.txt:1 --fact "$1" >/dev/null; }
rretire() { "$KNOW" retire --home "$AC_HOME" --repo "$rrepo" --family fam-r-fix --src-file file.txt:1 "$@"; }

radd 'the --changed selector widens to the full suite when empty'
"$KNOW" add --home "$AC_HOME" --repo "$rrepo" --family fam-other --src-file file.txt:1 \
  --fact 'a selector fact still needs its own citation, unrelated to the first' >/dev/null

# Zero matches - refuse, and say nothing matched.
refuses "nothing matched" rretire --quote 'no such phrase anywhere' --why 'typo probe'

# Ambiguous - both live facts share the substring "selector"; refuse AND print
# both candidates so the caller can narrow, rather than guessing one.
out="$(rretire --quote selector --why 'ambiguous probe' 2>&1)" && fail "an ambiguous quote must refuse, not pick one"
assert_contains "$out" "ambiguous" "the refusal names the ambiguity"
assert_contains "$out" "the --changed selector widens" "the refusal prints the first candidate"
assert_contains "$out" "a selector fact still needs its own citation" "the refusal prints the second candidate"

# --by narrows an otherwise-ambiguous quote to exactly one entry's own family.
out="$(rretire --quote selector --by fam-other --why 'narrowed by family')"
assert_contains "$out" "retired from $rrec" "a --by narrow resolves the ambiguity and retires"
live1="$(awk '/^## Superseded/ { exit } /^- /' "$rrec")"
case "$live1" in
  *"a selector fact still needs its own citation"*) fail "the --by-narrowed entry must not remain live" ;;
esac
assert_contains "$live1" "the --changed selector widens" "the untouched sibling entry stays live"
assert_contains "$live1" "- fact retired: narrowed by family | src:" "the retirement's own live receipt carries --why"
assert_contains "$live1" "by: fam-r-fix" "the receipt carries the retiring family (--family), not the target's (--by)"

# Happy path: retire the false entry (now uniquely addressable), byte-identical
# move under Superseded, plus its own live receipt.
false_line="$(awk '/^## Superseded/ { exit } /^- fact the --changed selector/' "$rrec")"
out="$(rretire --quote 'widens to the full suite when empty' --why 'contradicts tests/run-suite.sh:74, NOT a widen')"
assert_contains "$out" "retired from $rrec" "retire prints the record it wrote"
live2="$(awk '/^## Superseded/ { exit } /^- /' "$rrec")"
sup2="$(awk 'seen && /^- /; /^## Superseded/ { seen = 1 }' "$rrec")"
case "$live2" in
  *"the --changed selector widens"*) fail "the retired line must not remain live" ;;
esac
assert_contains "$sup2" "$false_line" "the retired line moved byte-identical under Superseded"
assert_contains "$live2" "- fact retired: contradicts tests/run-suite.sh:74, NOT a widen" \
  "the second retirement's own live receipt carries its --why"

# `verify` parses the record afterwards and reports on LIVE entries only: the
# retired text is gone from its report, the new receipt entries are present.
vout2="$("$KNOW" verify --home "$AC_HOME" --repo "$rrepo")"
case "$vout2" in
  *"the --changed selector widens"*) fail "verify must not report a superseded line" ;;
esac
assert_eq "$(printf '%s\n' "$vout2" | grep -c 'fact retired:')" "2" \
  "verify reports both live retirement receipts"

# The record's own lock is ACTUALLY taken: a held lock (owned by this test's
# own live pid, never reclaimed as stale) makes retire TIME OUT rather than
# write - this is the last use of $rrec, so the lock is never released.
mkdir -p "$rrec.lock"
printf '%s\n' "$$" >"$rrec.lock/pid"
before_lock="$(cat "$rrec")"
refuses "lock timeout" rretire --quote 'a selector fact' --why 'must not land while locked'
assert_eq "$(cat "$rrec")" "$before_lock" "the record is unchanged while the lock is held"
rm -rf "$rrec.lock"

# --- CITATION GUARD on `add --fact`: both directions -------------------------
# A pointer that cites THIS record by physical line is refused (the record has
# no stable per-entry identity - a retire renumbers it); an ordinary CODE
# citation is the record's normal provenance shape and stays legal.
refuses "line number" add --src-file file.txt:1 \
  --fact 'CORRECTS repo-knowledge:169, which is STALE ON THE MECHANISM'
refuses "line number" add --src-file file.txt:1 \
  --fact 'see records/repo-knowledge/agent-crew.md:169 for the prior claim'
add --src-file file.txt:1 --fact 'see bin/ac-tree.sh:405 for the lock idiom' >/dev/null
assert_contains "$(cat "$rec")" "bin/ac-tree.sh:405" "an ordinary code citation is still accepted"

# --- S5: the scope map, and it is NOT writable from the crewmate-facing verb --
# The closed list decides which qa profile a run may claim, so it enters only
# through the two-step route the fleet-home config already uses: agent DRAFTS,
# chief INSTALLS, captain vetoes by restoring `.prev`.
srepo="$(make_repo scoperepo)"
mkdir -p "$srepo/apps"
printf 'orchid\n' >"$srepo/apps/orchid.txt"
printf 'cedar\n' >"$srepo/apps/cedar.txt"
git -C "$srepo" add -A && git -C "$srepo" commit -qm apps
srec="$AC_HOME/records/repo-knowledge/scoperepo.md"
prop() { "$KNOW" scope-proposal --home "$AC_HOME" --repo "$srepo" --family fam-s "$@"; }
inst() { "$KNOW" scope-install "$1" --home "$AC_HOME" --repo "$srepo"; }
scopes() { bash -c ". '$BIN/ac-lib.sh'; ac_knowledge_scopes '$srepo'"; }

# `add --scope` is an UNKNOWN FLAG - the crewmate-facing verb has no scope
# path at all, so it cannot write the closed list even by accident.
refuses "unknown flag" "$KNOW" add --home "$AC_HOME" --repo "$srepo" --family fam-s \
  --src-file apps/orchid.txt:1 --scope orchid --apps orchid-service

# Draft-time refusals: every S1 guard runs at DRAFT time, so what the chief
# reviews is already known well-formed.
refuses "no scope named" prop --src-file apps/orchid.txt:1 --apps orchid-service
refuses "a scope with no members" prop --src-file apps/orchid.txt:1 --scope orchid
refuses "not addressable as a yaml path segment" prop --src-file apps/orchid.txt:1 --scope 'orchid@x' --apps a
refuses "not addressable as a yaml path segment" prop --src-file apps/orchid.txt:1 --scope orchid --apps 'a,b@c'
refuses "no provenance" prop --scope orchid --apps orchid-service

# A proposal alone changes the record by ZERO bytes: nothing is installed
# until a chief installs it.
prop --id p1 --src-file apps/orchid.txt:1 --scope orchid --apps orchid-service,orchid-worker >/dev/null
assert_no_file "$srec" "a draft alone writes nothing to the record"
assert_file "$srepo/.crew/knowledge-proposals/p1/proposed.md" "the draft is staged in the repo"
assert_file "$srepo/.crew/knowledge-proposals/p1/proposal.patch" "the draft carries its review diff"
refuses "id already exists" prop --id p1 --src-file apps/orchid.txt:1 --scope cedar --apps cedar-service

# AC14: the round trip. Installed, the map reads back exactly.
out="$(inst p1)"
assert_contains "$out" "KNOWLEDGE-INSTALLED: $srec" "the install prints the chief's receipt"
assert_file "$srec" "the install creates the record"
assert_eq "$(scopes)" "$(printf 'orchid\torchid-service,orchid-worker')" "AC14: the map round-trips through the resolver"

# A stale draft REFUSES rather than overwriting the winner: two proposals race,
# the loser is told to re-draft.
prop --id race-a --src-file apps/cedar.txt:1 --scope cedar --apps cedar-service >/dev/null
prop --id race-b --src-file apps/cedar.txt:1 --scope gw --apps gateway >/dev/null
inst race-a >/dev/null
refuses "conflicts with a newer installed record" "$KNOW" scope-install race-b --home "$AC_HOME" --repo "$srepo"
assert_eq "$(scopes | wc -l | tr -d ' ')" "2" "the loser's draft never landed"

# `.prev` is the captain's veto net.
before="$(cat "$srec")"
prop --id p2 --src-file apps/orchid.txt:1 --scope gw --apps gateway >/dev/null
inst p2 >/dev/null
assert_eq "$(cat "$srec.prev")" "$before" "the install keeps the pre-install record as the veto net"

# U1: at most ONE live entry per scope name. A second one REFUSES and names
# the line it would have shadowed; --replace MOVES the old line byte-identical
# under `## Superseded` - a receipt is durable, never rewritten.
refuses "already live" prop --src-file apps/orchid.txt:1 --scope orchid --apps orchid-service
old_line="$(awk '/^## Superseded/ { exit } /^- scope orchid = /' "$srec")"
prop --id p3 --src-file apps/orchid.txt:1 --scope orchid --apps orchid-service,orchid-worker,orchid-cron --replace >/dev/null
inst p3 >/dev/null
assert_eq "$(scopes | awk -F'\t' '$1=="orchid" { print $2 }')" "orchid-service,orchid-worker,orchid-cron" "--replace installs the new members"
assert_contains "$(awk 'seen && /^- /; /^## Superseded/ { seen = 1 }' "$srec")" "$old_line" \
  "the superseded line is moved byte-identical, never rewritten"
assert_eq "$(scopes | wc -l | tr -d ' ')" "3" "exactly one live entry per scope name survives"

# U3: retirement rides the same route - the live line moves to `## Superseded`
# and a `fact` records WHY. Without it the closed list could only grow, and a
# dead scope name would stay acceptable to the resolver forever.
refuses "nothing to retire" prop --retire --scope ghost --why gone --src-file apps/orchid.txt:1
refuses "takes no --apps" prop --retire --scope gw --why gone --apps x --src-file apps/orchid.txt:1
prop --id p4 --retire --scope gw --why 'gateway moved to its own repo' --src-file apps/orchid.txt:1 >/dev/null
inst p4 >/dev/null
assert_eq "$(scopes | awk -F'\t' '$1=="gw"')" "" "a retired scope leaves the closed list"
assert_contains "$(cat "$srec")" "- fact retired scope gw: gateway moved to its own repo" \
  "the retirement is recorded as a fact with its own provenance"

# D15: an app MAY belong to more than one scope. The writer NOTES it and
# writes anyway - the note is visibility, not a rule - and the map still
# resolves, because every resolution is per-PAIR.
err="$(prop --id p5 --src-file apps/cedar.txt:1 --scope shared --apps orchid-worker,shared-only 2>&1 >/dev/null)"
assert_contains "$err" "note: orchid-worker is also live in scope orchid" "overlap is NOTED"
inst p5 >/dev/null
assert_eq "$(scopes | awk -F'\t' '$1=="shared" { print $2 }')" "orchid-worker,shared-only" "overlap is accepted, not refused"

# U4: the READ side never picks a winner. Two live entries for one scope name,
# or a malformed live scope line, is exit 2 with BOTH lines printed - and it
# must stay distinguishable from "no scopes", or a scoped project silently
# drops to FLAT.
cp "$srec" "$srec.good"
inject() { awk -v bad="$1" '!d && /^- / { print bad; d = 1 } { print }' "$srec.good" >"$srec"; }
inject '- scope orchid = imposter | src: cmd:true | at: x 2026-07-21 | by: forger'
out="$(scopes 2>&1)" && fail "an ambiguous map must refuse, not resolve"
assert_contains "$out" "AMBIGUOUS" "the ambiguity is named"
assert_contains "$out" "imposter" "both offending lines are printed"
rc=0; bash -c ". '$BIN/ac-lib.sh'; ac_knowledge_scopes '$srepo'" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "ambiguity is exit 2, distinguishable from empty"
cp "$srec.good" "$srec"

# ...and a malformed live scope line is the same refusal, not a silent skip.
inject '- scope broken-no-equals | src: cmd:true | at: x 2026-07-21 | by: forger'
rc=0; bash -c ". '$BIN/ac-lib.sh'; ac_knowledge_scopes '$srepo'" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "a malformed live scope line refuses instead of reading as empty"
cp "$srec.good" "$srec"

# A record with facts but no scope entries is EMPTY, exit 0 - a legal, common
# state that must not be confused with the ambiguity above.
assert_eq "$(bash -c ". '$BIN/ac-lib.sh'; ac_knowledge_scopes '$repo'")" "" "facts-only record declares no scopes"

# --- AC20: the digest is O(1) in the number of entries -----------------------
# Two fixture homes identical except that one project's record carries 1 entry
# and the other 50. The record lives OUTSIDE records/projects.md (which the
# digest cats whole), so the delta is a constant, not 49 lines. This is the
# regression guard against a future per-entry digest line - the only way the
# record-home decision can be undone.
digest_len() {
  local home="$1" n="$2" i
  mkdir -p "$home/state" "$home/data" "$home/records" "$home/config" "$home/projects"
  printf 'off\n' >"$home/config/wedge-alarm"
  printf -- '- proj [local-only] - the fixture project (added 2026-07-21)\n' >"$home/records/projects.md"
  mkdir -p "$home/records/repo-knowledge"
  : >"$home/records/repo-knowledge/proj.md"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf -- '- fact entry %s | src: cmd:true | at: %s 2026-07-21 | by: fam-one\n' "$i" "$sha" \
      >>"$home/records/repo-knowledge/proj.md"
    i=$((i + 1))
  done
  AC_HOME="$home" "$BIN/ac-session-start.sh" 2>/dev/null | wc -c | tr -d ' '
}
one="$(digest_len "$TMP/home-1" 1)"
fifty="$(digest_len "$TMP/home-50" 50)"
delta=$(( fifty > one ? fifty - one : one - fifty ))
[ "$delta" -le 200 ] || fail "AC20: 49 extra knowledge entries moved the digest by $delta chars - the digest must be O(1) in entries"


# --- CITE: the mechanical usage counter (repo-knowledge-has-no-usage-signal) --
# Measured before the verb existed: 415 of the drydock record's 487 facts
# graded SUSPECT with NO signal for which to re-verify or retire first - both
# decisions were re-argued from scratch every time. `cite` is the increment
# path intake uses instead of bare grep: it PRINTS the entry (the read) and
# bumps an optional `| heat: <n>` field IN PLACE. The field sits BEFORE
# `| by:` because fact_live_candidates takes the by-family after the LAST
# `| by: ` and verify takes `at` as the first word after `| at: ` - this
# position breaks neither parser, while a field after `by:` breaks the first.
crepo="$(make_repo citerepo)"
crec="$AC_HOME/records/repo-knowledge/citerepo.md"
csha="$(git -C "$crepo" rev-parse HEAD)"
cadd() { "$KNOW" add --home "$AC_HOME" --repo "$crepo" --family fam-c --src-file file.txt:1 --fact "$1" >/dev/null; }
ccite() { "$KNOW" cite --home "$AC_HOME" --repo "$crepo" "$@"; }

cadd 'the pool lease survives a restart'
cadd 'the pool prune skips a dirty slot'
cline1="- fact the pool lease survives a restart | src: file:file.txt:1 | at: $csha $today | by: fam-c"
cline1_hot="- fact the pool lease survives a restart | src: file:file.txt:1 | at: $csha $today | heat: 1 | by: fam-c"

# C1: the first cite mints `| heat: 1` immediately before `| by:`, IN PLACE -
# the entry keeps its position (first live line) and every other byte.
out="$(ccite --quote 'lease survives a restart')"
assert_contains "$out" "$cline1_hot" "C1: cite prints the updated entry"
assert_eq "$(awk '/^## Superseded/ { exit } /^- /' "$crec" | head -1)" "$cline1_hot" \
  "C1: the cited entry gains heat in place and keeps its position"
if grep -qFx -- "$cline1" "$crec"; then fail "C1: the pre-heat line must be REWRITTEN, not duplicated"; fi

# C2: a second cite INCREMENTS the field - never mints a second one.
ccite --quote 'lease survives a restart' >/dev/null
cline="$(awk '/^## Superseded/ { exit } /^- fact the pool lease/' "$crec")"
assert_contains "$cline" "| heat: 2 | by: fam-c" "C2: heat increments in place"
assert_eq "$(printf '%s\n' "$cline" | awk -F'\\| heat: ' '{print NF-1}')" "1" "C2: exactly one heat field on the line"

# C3/C4/C5: the SAME addressing contract as retire - loud zero-match refusal,
# loud ambiguity refusal printing the candidates, --by narrowing to one.
refuses "nothing matched" ccite --quote 'no such phrase anywhere'
"$KNOW" add --home "$AC_HOME" --repo "$crepo" --family fam-d --src-file file.txt:1 \
  --fact 'the pool report names each slot holder' >/dev/null
out="$(ccite --quote 'the pool' 2>&1)" && fail "C4: an ambiguous quote must refuse, not pick one"
assert_contains "$out" "ambiguous" "C4: the refusal names the ambiguity"
out="$(ccite --quote 'the pool' --by fam-d)"
assert_contains "$out" "| heat: 1 | by: fam-d" "C5: --by narrows to the one entry and cites it"

# C6: verify parses a heat-bearing line like any other - the field rides the
# printed entry and the grade is unaffected (file.txt unchanged at HEAD).
vout="$("$KNOW" verify --home "$AC_HOME" --repo "$crepo")"
cfresh="$(printf '%s\n' "$vout" | grep '^FRESH' | grep -c 'lease survives a restart' || true)"
assert_eq "$cfresh" "1" "C6: a heat-bearing entry still verifies FRESH"
assert_contains "$vout" "| heat: 2 | by: fam-c" "C6: verify's report carries the heat field"

# C7: retire still addresses a heat-bearing entry by its subject phrase, and
# the superseded move keeps the field (byte-identical, heat included).
"$KNOW" retire --home "$AC_HOME" --repo "$crepo" --family fam-c-fix --src-file file.txt:1 \
  --quote 'lease survives a restart' --why 'heat rides the retire move' >/dev/null
csup="$(awk 'seen && /^- /; /^## Superseded/ { seen = 1 }' "$crec")"
assert_contains "$csup" "| heat: 2 | by: fam-c" "C7: the superseded line keeps its heat byte-identical"

# C8: cite takes the record's own lock - held, it refuses and writes nothing.
mkdir -p "$crec.lock"
printf '%s\n' "$$" >"$crec.lock/pid"
cbefore="$(cat "$crec")"
refuses "lock timeout" ccite --quote 'prune skips a dirty slot'
assert_eq "$(cat "$crec")" "$cbefore" "C8: the record is unchanged while the lock is held"
rm -rf "$crec.lock"

# --- the DUPLICATE GUARD on `add` -------------------------------------------
# `add` appended unconditionally, so the same subject landed twice whenever two
# families verified it - the normal case for a record whose purpose is that the
# next family does not re-derive what an earlier one proved. The guard is
# MECHANICAL (distinctive-token overlap over the subject text, scored against
# the SHORTER subject), calibrated on the real 454-entry drydock record where
# it flags 10 entries - the shape that actually recurs, not every fact about
# one file.
drepo="$(make_repo duprepo)"
drec="$AC_HOME/records/repo-knowledge/duprepo.md"
dadd() { "$KNOW" add --home "$AC_HOME" --repo "$drepo" --family fam-d1 --src-file file.txt:1 "$@"; }

dadd --fact 'the pooled worktree lease survives a restart because the slot meta is durable on disk' >/dev/null

# D1: a second family restating the SAME subject is refused, and the refusal
# prints the existing entry plus BOTH exits.
out="$(dadd --fact 'the pooled worktree lease survives a restart since its slot meta is durable on disk' 2>&1)" \
  && fail "D1: a near-duplicate subject must be refused"
assert_contains "$out" "already has a live entry" "D1: the refusal names the defect"
assert_contains "$out" "the pooled worktree lease survives a restart because" "D1: it prints the entry that already covers the subject"
assert_contains "$out" "--supersede" "D1: it offers the correct-the-old exit"
assert_contains "$out" "--new" "D1: and the genuinely-distinct exit"
assert_eq "$(awk '/^## Superseded/ { exit } /^- fact/' "$drec" | wc -l | tr -d ' ')" "1" \
  "D1: a refused add writes NOTHING"

# D2: an UNRELATED subject about the same file passes untouched - the guard
# must not fire on the ordinary case of many facts about one path.
dadd --fact 'the qa store freezes its coverage manifest before any case executes' >/dev/null \
  || fail "D2: an unrelated subject must pass"
assert_eq "$(awk '/^## Superseded/ { exit } /^- fact/' "$drec" | wc -l | tr -d ' ')" "2" "D2: it landed"

# D3: --new DECLARES the subject distinct and the guard stands aside.
dadd --new --fact 'the pooled worktree lease survives a restart since its slot meta is durable on disk' >/dev/null \
  || fail "D3: --new must let a declared-distinct subject through"
assert_eq "$(awk '/^## Superseded/ { exit } /^- fact/' "$drec" | wc -l | tr -d ' ')" "3" "D3: it landed on the declaration"

# D4: --supersede is ONE locked write - the old entry moves byte-identical to
# Superseded and the new one lands, so a reader never sees both claims or none.
old_line="$(awk '/^## Superseded/ { exit } /^- fact the pooled worktree lease survives a restart because/' "$drec")"
dadd --supersede 'lease survives a restart because' \
  --fact 'the pooled worktree lease is released on teardown, not on restart - the slot meta records the holder' >/dev/null \
  || fail "D4: --supersede must land"
live_now="$(awk '/^## Superseded/ { exit } /^- fact/' "$drec")"
sup_now="$(awk 'seen && /^- /; /^## Superseded/ { seen = 1 }' "$drec")"
case "$live_now" in
  *"survives a restart because"*) fail "D4: the superseded entry must leave the live section" ;;
esac
assert_contains "$sup_now" "$old_line" "D4: the superseded entry moved BYTE-IDENTICAL"
assert_contains "$live_now" "released on teardown, not on restart" "D4: and the correction landed in the same write"

# D5: --supersede refuses loudly when its phrase matches nothing or is
# ambiguous, and writes nothing either way.
before_d5="$(cat "$drec")"
refuses "matched nothing" dadd --supersede 'no such phrase at all' --fact 'a replacement nobody asked for'
refuses "ambiguous" dadd --supersede 'the pooled worktree lease' --fact 'a replacement for two entries at once'
assert_eq "$(cat "$drec")" "$before_d5" "D5: both refusals leave the record byte-unchanged"

# --- RECALL: the tiered read across the knowledge layers ---------------------
# (knowledge-read-has-no-tiered-recall) Intake used to GREP the record flat:
# 383KB / 487 entries, no ranking, no budget, and no way to tell a fresh fact
# from one of the 415 the record's own verify grades suspect. recall walks
# scenes (L2) BEFORE facts (L1), ranks by (terms matched, then heat), caps the
# output, and says so when it truncates.
rrepo2="$(make_repo recallrepo)"
radd2() { "$KNOW" add --home "$AC_HOME" --repo "$rrepo2" --family fam-r2 --src-file file.txt:1 --new --fact "$1" >/dev/null; }
recall() { "$KNOW" recall --home "$AC_HOME" --repo "$rrepo2" "$@"; }

radd2 'the watcher beacon goes stale past the re-arm grace and the fleet watcher covers the panes'
radd2 'the worktree pool lease is recorded in a slot meta that survives a restart'
radd2 'the watcher skip self-revokes when its scoped beacon is stale past grace'

# R1: only entries clearing the TERM FLOOR are offered. Measured on the real
# record: a floor of 1 matched 304 of 454 live facts for an ordinary question,
# so the floor is 60% of the query's distinctive terms (never below 2).
out="$(recall 'watcher beacon stale grace')"
assert_contains "$out" "== facts (L1 - repo-knowledge) ==" "R1: the fact tier is labelled"
assert_contains "$out" "watcher beacon goes stale past the re-arm grace" "R1: the on-topic fact is offered"
case "$out" in
  *"worktree pool lease"*) fail "R1: an off-topic fact must not clear the term floor" ;;
esac
assert_contains "$out" "cite: ac-know.sh cite" "R1: each hit hands over its cite command"
assert_contains "$out" "recall PRINTS; it never cites" \
  "R1: and the tail states why recall does not bump heat itself"

# R2: HEAT breaks the ranking tie - the fact the fleet actually reaches for
# outranks the one nobody has opened.
"$KNOW" cite --home "$AC_HOME" --repo "$rrepo2" --quote 'skip self-revokes' >/dev/null
"$KNOW" cite --home "$AC_HOME" --repo "$rrepo2" --quote 'skip self-revokes' >/dev/null
# Read the WHOLE stream and keep the first match, rather than stopping at it:
# any early-exiting reader (`grep -m1`, `awk ... exit`, `head -1`) closes the
# pipe, the writing side takes SIGPIPE, and pipefail turns that 141 into a
# suite death that looks nothing like the assertion it interrupted.
first="$(recall 'watcher beacon stale grace' | awk '/^  \(hits/ && !seen { line = $0; seen = 1 } END { print line }')"
assert_contains "$first" "self-revokes" "R2: equal term-hits break by heat, so a cited fact ranks first"
assert_contains "$first" "heat 2" "R2: and the heat it ranked on is shown"

# R3: SCENES come FIRST - a topic restored in one read outranks the specifics.
printf 'the whole watcher beacon and skip protocol, consolidated.\n' \
  | "$BIN/ac-scene.sh" new watcher-beacon --summary 'watcher beacon, skip and grace in one read' >/dev/null
out3="$(recall 'watcher beacon stale grace')"
assert_contains "$out3" "== scenes (L2" "R3: the scene tier is present"
[ "$(printf '%s\n' "$out3" | grep -n '== scenes' | cut -d: -f1)" \
  -lt "$(printf '%s\n' "$out3" | grep -n '== facts' | cut -d: -f1)" ] \
  || fail "R3: scenes must be walked BEFORE facts"
assert_contains "$out3" "open: ac-scene.sh show watcher-beacon --cite" "R3: the scene hands over its own open command"

# R4: the BUDGET truncates loudly - a silent cut reads as "that is all there is".
out4="$(recall 'watcher beacon stale grace' --max 1)"
assert_contains "$out4" "TRUNCATED at --max 1" "R4: truncation is stated, with the cap that caused it"
assert_contains "$out4" "hits total" "R4: and the total the caller did not see"
out5="$(recall 'watcher beacon stale grace')"
assert_contains "$out5" "(all hits)" "R4: an untruncated answer says so, so the caller knows it saw everything"

# R5: a miss is an explicit ABSENCE - intake must state it, never assume none.
out6="$(recall 'kubernetes ingress certificate rotation')"
assert_contains "$out6" "no hit in any layer" "R5: a miss is reported as a miss"
assert_contains "$out6" "state the absence explicitly" "R5: and names the intake obligation it creates"

pass
