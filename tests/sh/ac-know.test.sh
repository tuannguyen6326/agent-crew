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

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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
cp "$BIN/ac-know.sh" "$BIN/ac-bun.sh" "$BIN/ac-lib.sh" "$BIN/ac-harness.sh" "$fake/bin/"
ln -s "$ROOT/src" "$fake/src"
out="$(env -u AC_HOME "$fake/bin/ac-know.sh" add --repo "$repo" --family fam-one \
  --src-file file.txt:1 --fact 'a homeless call must refuse, not write here' 2>&1)" \
  && fail "a homeless add must REFUSE, never adopt the checkout"
assert_contains "$out" "no fleet home" "the refusal names what is missing"
assert_contains "$out" "--home" "and the first fix"
assert_contains "$out" "AC_HOME" "and the second"
assert_contains "$out" "brief" "and points a crewmate at the --home-carrying line its brief already baked"
assert_no_file "$fake/records/repo-knowledge/proj.md" "a refused homeless add writes NOTHING into the checkout"

# `verify` was the LAST rung-3 holdout (it inlined its own ladder instead of
# calling settle_home like every other verb here) - the same refusal, same
# fake checkout, and it must neither read a phantom record nor write a
# phantom stamp.
vout_homeless="$(env -u AC_HOME "$fake/bin/ac-know.sh" verify --repo "$repo" 2>&1)" \
  && fail "a homeless verify must REFUSE, never adopt the checkout as home"
assert_contains "$vout_homeless" "no fleet home" "the refusal names what is missing"
assert_no_file "$fake/records/repo-knowledge/proj.md" "a refused homeless verify reads/writes NOTHING in the checkout"
assert_no_file "$fake/state/.know-verify-proj.meta" "a refused homeless verify leaves no stamp in the checkout"

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
# A phrase that DOES match, narrowed to a --by family no matching entry
# carries, is not "nothing matched" - the same defect cite's C5b names.
out="$(rretire --quote 'widens to the full suite' --by fam-x --why 'probe' 2>&1)" \
  && fail "retire with a --by no entry carries must refuse"
assert_contains "$out" "matches 1 live entry, none by family fam-x" "retire names the family mismatch"
assert_contains "$out" "fam-r" "...and the family that wrote the match"
case "$out" in *"no live fact entry contains that phrase"*) fail "a matching phrase must not be reported as absent: $out" ;; esac

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
out="$(rretire --quote 'widens to the full suite when empty' --why 'contradicts run-suite.sh EMPTY-SELECTION EXIT, NOT a widen')"
assert_contains "$out" "retired from $rrec" "retire prints the record it wrote"
live2="$(awk '/^## Superseded/ { exit } /^- /' "$rrec")"
sup2="$(awk 'seen && /^- /; /^## Superseded/ { seen = 1 }' "$rrec")"
case "$live2" in
  *"the --changed selector widens"*) fail "the retired line must not remain live" ;;
esac
assert_contains "$sup2" "$false_line" "the retired line moved byte-identical under Superseded"
assert_contains "$live2" "- fact retired: contradicts run-suite.sh EMPTY-SELECTION EXIT, NOT a widen" \
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
mkdir -p "$TMP/fastsleep"; printf '#!/bin/sh\nexit 0\n' >"$TMP/fastsleep/sleep"; chmod +x "$TMP/fastsleep/sleep"
PATH="$TMP/fastsleep:$PATH" refuses "lock timeout" rretire --quote 'a selector fact' --why 'must not land while locked'
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
# C5b: --by is the ENTRY's author family, not the caller's - and a caller that
# passes its own family (measured live 2026-09-16: a solo chief citing a fact
# it had just recalled) got "no live fact entry contains that phrase", which
# is false and sends it to re-derive a fact that is on the record. The refusal
# names the real mismatch: the phrase matches, no entry is by that family,
# and these are the families that wrote the matches.
out="$(ccite --quote 'the pool' --by fam-x 2>&1)" && fail "C5b: a --by no entry carries must refuse"
assert_contains "$out" "matches 3 live entries, none by family fam-x" "C5b: the refusal names the family mismatch, not a missing phrase"
assert_contains "$out" "fam-c" "C5b: ...and lists the families that did write the matches"
assert_contains "$out" "fam-d" "C5b: ...all of them"
case "$out" in *"no live fact entry contains that phrase"*) fail "C5b: a phrase that matches must not be reported as absent: $out" ;; esac

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
PATH="$TMP/fastsleep:$PATH" refuses "lock timeout" ccite --quote 'prune skips a dirty slot'
assert_eq "$(cat "$crec")" "$cbefore" "C8: the record is unchanged while the lock is held"
rm -rf "$crec.lock"

# C9: a quote carrying a BACKSLASH addresses the entry whose text carries it.
# Passed through `awk -v` the phrase is escape-cooked (`\d` arrives as `d`),
# so a verbatim quote of the entry's own text read as "nothing matched".
cadd 'the pattern \d+ matches a run of digits in the parser'
out="$(ccite --quote 'pattern \d+ matches' 2>&1)" \
  || fail "C9: a backslash-carrying quote must match the entry it was quoted from: $out"
assert_contains "$out" 'the pattern \d+ matches a run of digits in the parser | src:' "C9: cite prints that entry"

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

# D6: the guard judges the text that will be WRITTEN. Through `awk -v` the new
# fact was escape-cooked (`\b` became a backspace, so `\bpolicy` tokenized as
# `policy`, never the stored `bpolicy`), and a verbatim restatement shared no
# token with the stored entry.
dadd --new --fact 'the \bpolicy\b \bmatcher\b \bselector\b \banchor\b regex' >/dev/null
refuses "already has a live entry" dadd --fact 'a \bpolicy\b \bmatcher\b \bselector\b \banchor\b pattern'

# --- SUPERSEDED-SET ADDRESSING: add/retire/cite load $sup already but never
# search it (repo-knowledge-superseded-set-is-loaded-never-searched). Two
# symptoms of one root: a phrase quoted from a superseded entry reads as
# "nothing matched" - indistinguishable from a typo, and from "unaddressable
# by any sanctioned path" - and a phrase short enough to also match the
# superseded entry a live entry quotes lets a WRITE verb hit the wrong one
# silently (--by cannot save it: it filters on the MATCHED entry's own
# family, not on what the caller meant).
hrepo="$(make_repo hiderepo)"
hrec="$AC_HOME/records/repo-knowledge/hiderepo.md"
hadd() { "$KNOW" add --home "$AC_HOME" --repo "$hrepo" --family fam-h --src-file file.txt:1 "$@"; }
hretire() { "$KNOW" retire --home "$AC_HOME" --repo "$hrepo" --family fam-h-fix --src-file file.txt:1 "$@"; }
hcite() { "$KNOW" cite --home "$AC_HOME" --repo "$hrepo" "$@"; }

hadd --fact 'the pool lease survives a restart because the slot meta is durable on disk' >/dev/null
hretire --quote 'slot meta is durable on disk' --why 'measured wrong, see the successor entry' >/dev/null

# H1/H2/H3 (Arm A, all three verbs): the phrase now lives ONLY under
# Superseded - each refusal must NAME that entry (its own family and text),
# not the plain zero-match message.
out="$(hretire --quote 'slot meta is durable on disk' --why 'second attempt' 2>&1)" \
  && fail "H1: retire must refuse a phrase that lives only in a superseded entry"
assert_contains "$out" "SUPERSEDED" "H1: retire names the class"
assert_contains "$out" "by: fam-h" "H1: retire names the superseded entry's own family"
assert_contains "$out" "slot meta is durable on disk" "H1: retire quotes the superseded entry's own text"

out="$(hcite --quote 'slot meta is durable on disk' 2>&1)" \
  && fail "H2: cite must refuse a phrase that lives only in a superseded entry"
assert_contains "$out" "SUPERSEDED" "H2: cite names the class"

before_h3="$(cat "$hrec")"
out="$(hadd --supersede 'slot meta is durable on disk' --fact 'a replacement nobody asked for' 2>&1)" \
  && fail "H3: add --supersede must refuse a phrase that lives only in a superseded entry"
assert_contains "$out" "SUPERSEDED" "H3: add --supersede names the class"
assert_eq "$(cat "$hrec")" "$before_h3" "H3: the refusal writes nothing"

# A live successor that itself quotes the superseded entry's own text -
# exactly the "already retired a fact by mistake" shape from the header.
"$KNOW" add --home "$AC_HOME" --repo "$hrepo" --family fam-h2 --src-file file.txt:1 \
  --fact 'the pool lease now checks a leasefile instead of trusting that slot meta is durable on disk' >/dev/null

# H4/H5 (Arm B, WRITE verbs): one live match AND one superseded match -
# refuse, show both sides, write nothing.
before_armb="$(cat "$hrec")"
out="$(hretire --quote 'slot meta is durable on disk' --why 'trying again' 2>&1)" \
  && fail "H4: retire must refuse when the phrase matches one live entry AND a superseded entry"
assert_contains "$out" "SUPERSEDED" "H4: retire names the class"
assert_contains "$out" "leasefile" "H4: retire's refusal shows the live side too"
assert_eq "$(cat "$hrec")" "$before_armb" "H4: the refusal writes nothing"

out="$(hadd --supersede 'slot meta is durable on disk' --fact 'another replacement' 2>&1)" \
  && fail "H5: add --supersede must refuse when the phrase matches one live entry AND a superseded entry"
assert_contains "$out" "SUPERSEDED" "H5: add --supersede names the class"
assert_eq "$(cat "$hrec")" "$before_armb" "H5: the refusal writes nothing"

# H6 (Arm B, cite): a read receipt is not a supersession - it WARNS instead
# of refusing (an intake read must not break on a ranking-only side effect),
# and still bumps heat on the live match it already resolved.
out="$(hcite --quote 'slot meta is durable on disk' 2>&1)" \
  || fail "H6: cite must not refuse on a live+superseded double match"
assert_contains "$out" "warning" "H6: cite warns about the double match"
assert_contains "$out" "heat: 1" "H6: cite still bumps heat on the resolved live match"

# H7/H8/H9 (do-not-break): a phrase matching exactly one live entry and
# nothing superseded behaves exactly as before the fix, for all three verbs.
"$KNOW" add --home "$AC_HOME" --repo "$hrepo" --family fam-h3 --src-file file.txt:1 \
  --fact 'the pool watcher heartbeat interval is fifteen seconds' >/dev/null
out="$(hcite --quote 'heartbeat interval is fifteen seconds')"
assert_contains "$out" "heat: 1" "H7: cite is unaffected by an ordinary live-only match"

"$KNOW" add --home "$AC_HOME" --repo "$hrepo" --family fam-h4 --src-file file.txt:1 \
  --fact 'the pool retry backoff caps at five attempts' >/dev/null
out="$(hretire --quote 'retry backoff caps at five attempts' --why 'ordinary retire, no superseded overlap')"
assert_contains "$out" "retired from $hrec" "H8: retire is unaffected by an ordinary live-only match"

"$KNOW" add --home "$AC_HOME" --repo "$hrepo" --family fam-h5 --src-file file.txt:1 \
  --fact 'the pool health check timeout is two seconds' >/dev/null
out="$(hadd --supersede 'health check timeout is two seconds' \
  --fact 'the pool health check timeout is now three seconds after measurement')"
assert_contains "$out" "recorded in $hrec" "H9: add --supersede is unaffected by an ordinary live-only match"

# --- the DUPLICATE GUARD is blind to the SUPERSEDED set ----------------------
# fact_near_duplicates on the plain `add` path only ever searched the live
# set, so a fact that merely repeats a RETIRED entry landed with no signal at
# all - the same root as the H-block above (the superseded set is loaded and
# never searched) but a different verb path. Unlike a live duplicate (always
# the defect: two live claims about one subject), a superseded near-duplicate
# is often the SANCTIONED correction path (`retire` then `add`), which always
# restates the retired subject - so this is a WARN that still lands the
# write, not a refusal.
irepo="$(make_repo addsuprepo)"
irec="$AC_HOME/records/repo-knowledge/addsuprepo.md"
iadd() { "$KNOW" add --home "$AC_HOME" --repo "$irepo" --family fam-i --src-file file.txt:1 "$@"; }
iretire() { "$KNOW" retire --home "$AC_HOME" --repo "$irepo" --family fam-i-fix --src-file file.txt:1 "$@"; }

iadd --fact 'the pool worker retries exactly three times before giving up' >/dev/null
iretire --quote 'retries exactly three times before giving up' --why 'measured wrong' >/dev/null

# I1: a near-duplicate of a superseded entry with NO live successor must
# still land, and stderr names the retired entry it duplicates.
out="$(iadd --fact 'the pool worker retries exactly three times before it gives up' 2>&1)" \
  || fail "I1: a near-duplicate of a superseded entry must still land"
assert_contains "$out" "recorded in $irec" "I1: the write succeeds"
assert_contains "$out" "SUPERSEDED" "I1: the warning names the class"
assert_contains "$out" "retries exactly three times before giving up" \
  "I1: the warning quotes the retired entry's own text"
case "$out" in
  *"replaced by"*) fail "I1: no live successor exists yet, must not claim one" ;;
esac
assert_contains "$(awk '/^## Superseded/ { exit } /^- fact/' "$irec")" \
  "before it gives up" "I1: the new fact landed live"

# I2: when a live entry near-duplicates the RETIRED entry's own subject, that
# live entry is named as the successor - reusing the same measure, never a
# new link field.
iadd --fact 'the queue drains oldest jobs first because insertion order is preserved' >/dev/null
iretire --quote 'insertion order is preserved' --why 'measured wrong, see successor' >/dev/null
iadd --fact 'the queue drains oldest jobs first because a monotonic sequence number orders them' >/dev/null 2>&1

out="$(iadd --fact 'the queue drains oldest jobs first since insertion order is preserved' 2>&1)" \
  || fail "I2: a near-duplicate of a superseded entry with a successor must still land"
assert_contains "$out" "recorded in $irec" "I2: the write succeeds"
assert_contains "$out" "insertion order is preserved" "I2: the warning quotes the retired entry"
assert_contains "$out" "replaced by" "I2: the warning names the successor relationship"
assert_contains "$out" "monotonic sequence number orders them" "I2: and quotes the live successor's own text"

# I3: a fact that ALSO matches a LIVE entry refuses on the live guard - the
# stronger defect wins the ordering, and the superseded warning never fires.
iadd --fact 'the pool lease survives a restart because the slot meta is durable on disk' >/dev/null
iretire --quote 'slot meta is durable on disk' --why 'measured wrong' >/dev/null
iadd --fact 'the pool lease now checks a leasefile instead of trusting that slot meta is durable on disk' >/dev/null
before_i3="$(cat "$irec")"
out="$(iadd --fact 'the pool lease now checks a leasefile instead of trusting that slot meta is durable on disk, always' 2>&1)" \
  && fail "I3: a live duplicate must still refuse even when a superseded entry also matches"
assert_contains "$out" "already has a live entry" "I3: the live refusal fires"
case "$out" in
  *"near-duplicates a SUPERSEDED"*) fail "I3: the superseded warning must not fire once the live guard already refused" ;;
esac
assert_eq "$(cat "$irec")" "$before_i3" "I3: the refusal writes nothing"

# I4: --new remains the declared bypass and this guard stands aside for it,
# exactly as the live guard does.
out="$(iadd --new --fact 'the pool worker retries exactly three times before it gives up, always' 2>&1)" \
  || fail "I4: --new must let a declared-distinct subject through"
assert_contains "$out" "recorded in $irec" "I4: it landed"
case "$out" in
  *"SUPERSEDED"*) fail "I4: --new must bypass the superseded warning too" ;;
esac

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
radd2 'the lease grace window is counted in whole seconds'

# R1: only entries clearing the TERM FLOOR are offered. Measured on the real
# record: a floor of 1 matched 304 of 454 live facts for an ordinary question,
# so the floor is 60% of the query's distinctive terms (never below 2).
out="$(recall 'watcher beacon stale grace')"
assert_contains "$out" "== facts (L1 - repo-knowledge) ==" "R1: the fact tier is labelled"
assert_contains "$out" "watcher beacon goes stale past the re-arm grace" "R1: the on-topic fact is offered"
case "$out" in
  *"worktree pool lease"*) fail "R1: an off-topic fact must not clear the term floor" ;;
  *"lease grace window"*) fail "R1: one shared term (grace) is below the floor of 3" ;;
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

# R6: a ZERO budget truncates like any other - both counts pass the digits
# check, and an absence line over hits the budget merely hid is the false
# "nothing is known" intake then writes into a brief. The inverse holds too: a
# real miss under a zero budget is still an absence.
out7="$(recall 'worktree pool lease restart' --max 0)"
case "$out7" in *"no hit in any layer"*) fail "R6: --max 0 over real hits must not report an absence: $out7" ;; esac
assert_contains "$out7" "TRUNCATED at --max 0" "R6: --max 0 states the truncation"
out7="$(recall 'worktree pool lease restart' --bytes 0)"
case "$out7" in *"no hit in any layer"*) fail "R6: --bytes 0 over real hits must not report an absence: $out7" ;; esac
assert_contains "$out7" "TRUNCATED at --max 8 / --bytes 0" "R6: --bytes 0 states the truncation"
out7="$(recall 'kubernetes ingress certificate rotation' --max 0)"
assert_contains "$out7" "no hit in any layer" "R6: a real miss under a zero budget is still an absence"

# R7: the cite hand-over's phrase survives the shell. An apostrophe in the
# subject closed the single-quoted phrase early and the line did not parse -
# 87 of drydock's 681 live entries on 2026-09-28.
radd2 "the chief's watcher beacon grace is three hundred seconds"
hand="$(recall "chief's watcher beacon grace" | awk '/cite: ac-know.sh cite/ && /chief/ { l = $0 } END { print l }')"
out8="$(eval "\"\$KNOW\" cite --home \"\$AC_HOME\" --repo \"\$rrepo2\" --quote ${hand##*--quote }" 2>&1)" \
  || fail "R7: the printed cite hand-over must parse and address its entry: $hand -> $out8"
assert_contains "$out8" "the chief's watcher beacon grace is three hundred seconds | src:" "R7: it cites the entry it was printed for"

# R8: a question ABOUT a flag is still a question. The usage is
# `recall <question words>...` and intake passes the question as one quoted
# word, so a quoted question starting with - died as "unknown flag".
radd2 'the --changed selector widens the diff to every file the base touched'
out9="$(recall '--changed selector widens' 2>&1)" \
  || fail "R8: a question word beginning with - must reach the query: $out9"
assert_contains "$out9" "the --changed selector widens the diff" "R8: and the question finds its entry"
# The inverse: a bare dash-word that is not one of the four flags is a typo'd
# or unsupported flag. Taken as a question term it raises the floor and matches
# nothing, so recall would print a false absence (or a silently narrowed "all
# hits") instead of refusing.
refuses "unknown flag: --limit" recall 'watcher beacon stale grace' --limit 3
refuses "unknown flag: --max=3" recall 'watcher beacon stale grace' --max=3
out9="$(recall -- --changed 2>&1)" \
  || fail "R8: a one-word question beginning with - must pass after --: $out9"
assert_contains "$out9" "the --changed selector widens the diff" "R8: and -- ends the flags"

# --- differential: src/know.ts against the frozen bash original ------------
# DISPUTED: the implementation (tests/fixtures/ac-know.sh under bash vs src/know.ts through bin/ac-know.sh)
# HELD-CONSTANT: two side roots seeded alike ($XOH for the oracle, $XNH for the shim) - a home at <side>/home (records/repo-knowledge/<name>.md, records/scenes/*.md and a planted lock seeded per row), clones under <side>/home/projects/ and <side>/out built by the same commands with fixed author/committer dates and one git config (GIT_CONFIG_GLOBAL, no system config) so every sha matches; argv and env (the side root spelled @H, substituted in values only); cwd (<side>/cwd, an EMPTY dir, unless a row names another); stdin (/dev/null); LC_ALL=C unless a row names en_US.UTF-8; TMPDIR <side>/tmp; PATH stubs on both sides - date answering one instant per format, sleep logging each call and returning at once, mktemp honouring TMPDIR - plus a row's own; the live bin/ beside each entry (the oracle bin's copies, $BIN's own); exit status, stdout and stderr compared whole (the side root spelled @H, either bin root ROOT, the entry's pid PID), then the world a row may touch: every path under the side root (git internals aside), every file under home/, out/, tmp/ and stub/ with its mode and bytes (the whole record, its lock and .prev, the verify stamp, each proposal dir, the temps left in TMPDIR), each clone's porcelain, and the sleep log (the lock's waits).
xobin="$(make_oracle_bin ac-know)"
cmp -s "$xobin/ac-know.sh" "$ROOT/tests/fixtures/ac-know.sh" || fail "the oracle bin holds the frozen original"
XOH="$TMP/xside-o"; XNH="$TMP/xside-n"
XSTUBS="$TMP/xstubs"; mkdir -p "$XSTUBS"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig"
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in
  *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;;
  *%Y%m%d-*) echo 20260101-000000 ;;
  *%F*) echo 2026-01-01 ;;
  *%s*) echo 1767225600 ;;
  *) exec /bin/date "$@" ;;
esac
STUB
cat >"$XSTUBS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/sleep.log"
STUB
# macOS mktemp(1) with no template ignores TMPDIR (its per-user temp dir
# wins), so the original's temps would land - and, past a crash, stay -
# outside the world.
cat >"$XSTUBS/mktemp" <<'STUB'
#!/bin/sh
[ $# -ne 0 ] || exec /usr/bin/mktemp "$TMPDIR/tmp.XXXXXXXX"
exec /usr/bin/mktemp "$@"
STUB
chmod +x "$XSTUBS/date" "$XSTUBS/sleep" "$XSTUBS/mktemp"
xboth() {  # xboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$XOH" "$XNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
xseed() { rm -rf "$H"; mkdir -p "$H/home" "$H/cwd" "$H/tmp" "$H/stub" "$H/out"; }
xput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # xput <path under the side> <bytes>
xrepo() {  # xrepo <path under the side> - a repo with one commit on main: file.txt, three.txt, apps/a/main.ts, sub/s.txt, link.ts
  git init -q -b main "$H/$1"
  printf 'hello\n' >"$H/$1/file.txt"; printf 'one\ntwo\nthree\n' >"$H/$1/three.txt"
  mkdir -p "$H/$1/apps/a" "$H/$1/sub"; printf 'x\n' >"$H/$1/apps/a/main.ts"; printf 's\n' >"$H/$1/sub/s.txt"
  ln -s apps/a/main.ts "$H/$1/link.ts"
  git -C "$H/$1" add -A; git -C "$H/$1" commit -qm init
}
xcommit() {  # xcommit <repo under the side> <file> <line> - one more commit there
  mkdir -p "$(dirname "$H/$1/$2")"; printf '%s\n' "$3" >"$H/$1/$2"; git -C "$H/$1" add -A; git -C "$H/$1" commit -qm "$2"
}
xstd() { xseed; xrepo home/projects/proj; }
XP=home/projects/proj
XREC=home/records/repo-knowledge/proj.md
XBOILER1='<!-- One entry per line. Grammar owner: bin/ac-know.sh. Write with `ac-know.sh add`; retire with `ac-know.sh retire`; record a read with `ac-know.sh cite` - it bumps the entry `heat:` usage counter in place, the one sanctioned in-place field. Never edit a line by hand; correct a fact by retire then add. -->'
XBOILER2='<!-- Moved here byte-identical by `ac-know.sh retire` / `scope-proposal --replace` / `--retire`. add/retire/cite search it to name a superseded-only or double match; never edited, never trusted as live. -->'
xrecord() {  # xrecord <live lines> [<superseded lines>] - the record, rendered as the writer renders it
  xput "$XREC" "# Repo knowledge: proj

$XBOILER1

$1
## Superseded

$XBOILER2

${2:-}"
}
XLC=C; XENV=(); XCWD=cwd; XPRE=""; XPATH=""; XPLANT=""; XNBIN="$BIN"
xrun_side() {  # xrun_side <bin> <side root> <prefix> <args...> - XPLANT=<path under the side> links <path>.<the entry's pid> to <side>/victim first
  local bin="$1" h="$2" p="$3" x v path; shift 3
  path="$XSTUBS:$PATH"; [ -z "$XPRE" ] || path="${XPRE//@H/$h}:$path"; [ -z "$XPATH" ] || path="${XPATH//@H/$h}"
  local a=() e=("LC_ALL=$XLC" "PATH=$path" "TMPDIR=$h/tmp" "STUB_DIR=$h/stub")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  (cd "$h/$XCWD" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u CDPATH -u AC_LOCK_STALE_GRACE -u EPOCHSECONDS \
    "${e[@]}" /bin/sh -c 'printf %s "$$" >"$0"; [ -z "$1" ] || ln -s "$2" "$1.$$"; shift 2; exec "$@"' \
    "$TMP/$p.pid" "${XPLANT:+$h/$XPLANT}" "$h/victim" "$bin/ac-know.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
xnorm() {  # xnorm <file> <side root> <pid> - the pid only where the entry writes one (a lock's pid file, the default proposal id): a record's own numbers stay
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-know#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e "s/^$3\$/PID/" -e "s/-000000-$3([^0-9a-f]|\$)/-000000-PID\\1/g" "$1"
}
XO_RC=0; XN_RC=0
xpair() {  # xpair <args...> - both sides run, outputs normalised, nothing compared yet
  XO_RC=0; XN_RC=0
  xrun_side "$xobin" "$XOH" xo "$@" || XO_RC=$?
  xrun_side "$XNBIN" "$XNH" xn "$@" || XN_RC=$?
  xnorm "$TMP/xo.raw" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.out"; xnorm "$TMP/xo.err" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.err2"
  xnorm "$TMP/xn.raw" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.out"; xnorm "$TMP/xn.err" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.err2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xsame_rc_out() {
  assert_eq "$XN_RC" "$XO_RC" "know differential exit for '$*' at line $(xrow)"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "know differential stdout differs for '$*' at line $(xrow): $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 8)"
}
xsame_err() {
  cmp -s "$TMP/xo.err2" "$TMP/xn.err2" || fail "know differential stderr differs for '$*' at line $(xrow): $(diff "$TMP/xo.err2" "$TMP/xn.err2" | head -n 8)"
}
xworld() {  # xworld <side root> - what a row may change
  local h="$1" f r
  (cd "$h" && { find . -path '*/.git' -prune -o -print 2>/dev/null || true; } | LC_ALL=C sort)
  (cd "$h" && { find home out tmp stub -path '*/.git' -prune -o \( -type f -o -type l \) -print 2>/dev/null || true; } | LC_ALL=C sort) | while IFS= read -r f; do
    if [ -L "$h/$f" ]; then printf '== %s -> %s\n' "$f" "$(readlink "$h/$f")"; continue; fi
    printf '== %s %s\n' "$f" "$(ls -l "$h/$f" | cut -c1-10)"; cat "$h/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'
  done
  for r in "$h"/home/projects/* "$h"/out/*; do
    [ -e "$r/.git" ] || continue
    printf '== porcelain %s\n' "$r"; git -C "$r" status --porcelain 2>&1 || true
  done
}
xsame_world() {
  xworld "$XOH" >"$TMP/xo.world"; xworld "$XNH" >"$TMP/xn.world"
  xnorm "$TMP/xo.world" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.world2"; xnorm "$TMP/xn.world" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.world2"
  cmp -s "$TMP/xo.world2" "$TMP/xn.world2" || fail "know differential world differs after '$*' at line $(xrow): $(diff "$TMP/xo.world2" "$TMP/xn.world2" | head -n 12)"
}
xsame() { xpair "$@"; xsame_rc_out "$@"; xsame_err "$@"; xsame_world "$@"; }
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err2"; }
xoout() { cat "$TMP/xo.out"; }
xoerr() { cat "$TMP/xo.err2"; }
xfile() { xnorm "$XNH/$1" "$XNH" "$(cat "$TMP/xn.pid")"; }   # xfile <path under the side> - the shim side's file, normalised
xrefuse() {  # xrefuse <stderr> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xsame "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "know refusal for '$*' at line $(xrow)"
}
xok() {  # xok <args...> - both sides succeed alike, nothing on stderr
  xsame "$@"
  assert_eq "$XN_RC:$(xerr)" "0:" "know success for '$*' at line $(xrow)"
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
xusage() {  # xusage <args...> - both sides print the header's Usage block on stdout, exit 1
  xsame "$@"
  assert_eq "$XN_RC:$(xerr)" "1:" "know usage for '$*' at line $(xrow)"
  cmp -s "$TMP/xn.out" "$TMP/xusage" || fail "know usage block for '$*' at line $(xrow): $(diff "$TMP/xusage" "$TMP/xn.out" | head -n 8)"
}
xinstall() {  # xinstall <args...> - scope-install on both sides alike, but for the record's mode: the original leaves it 0600, the port keeps 0644 (W7, named)
  xpair scope-install "$@"
  xsame_rc_out scope-install "$@"; xsame_err scope-install "$@"
  assert_eq "$XN_RC:$(xerr):$(ls -l "$XNH/$XREC" | cut -c1-10):$(ls -l "$XOH/$XREC" | cut -c1-10)" "0::-rw-r--r--:-rw-------" "know install for '$*' at line $(xrow) (W7, named)"
  chmod 644 "$XOH/$XREC"
  xsame_world scope-install "$@"
}
sed -n '/^# Usage:/,/^#$/p' "$ROOT/tests/fixtures/ac-know.sh" | sed 's/^# \{0,1\}//' >"$TMP/xusage"
XROOTED=0; [ "$(id -u)" != 0 ] || XROOTED=1
XH=(--home @H/home --repo @H/$XP)
XNOHOME='ERROR: no fleet home: pass --home <abs>, or set AC_HOME. This checkout is NOT one - a record written here lands where no fleet reads it, and in a leased worktree it is discarded on return. A crewmate pane never carries AC_HOME by design, which is exactly why bin/ac-brief.sh bakes a --home-carrying command line into every brief (ac-brief.sh knowledge()) - run the line the brief gave you.'

# 1. dispatch and flags, every one before any repo or home read: no verb,
#    -h, --help and '' print the Usage block (stdout, exit 1); an unknown
#    verb; each verb's value flags as the last word; a value flag swallowing
#    the next word, last wins; add's and recall's own unknown-flag texts;
#    recall's dash words and --; scope-install's id-first grammar (W15).
xboth xseed
xusage
xusage ''
xusage -h
xusage --help
xrefuse "ERROR: unknown verb: bogus" bogus
xrefuse "ERROR: unknown verb: -x" -x
for xf in --home --repo --family --src-file --src-cmd --at --fact --supersede; do xrefuse "ERROR: $xf needs a value" add "$xf"; done
for xf in --home --repo --family --src-file --src-cmd --at --quote --by --why; do xrefuse "ERROR: $xf needs a value" retire "$xf"; done
for xf in --home --repo --quote --by; do xrefuse "ERROR: $xf needs a value" cite "$xf"; done
for xf in --home --repo --max --bytes; do xrefuse "ERROR: $xf needs a value" recall q "$xf"; done
for xf in --home --repo; do xrefuse "ERROR: $xf needs a value" verify "$xf"; done
for xf in --home --repo --family --src-file --src-cmd --at --scope --apps --why --id; do xrefuse "ERROR: $xf needs a value" scope-proposal "$xf"; done
for xf in --home --repo; do xrefuse "ERROR: $xf needs a value" scope-install p1 "$xf"; done
xusage add
xusage add --new --repo ''
xusage retire --repo x --repo ''
xusage cite --quote q
xusage verify --home @H/home
xusage scope-proposal --replace --retire
xrefuse "ERROR: unknown flag: --help (ac-know.sh add writes facts; the scope map is not writable here)" add --help
xrefuse "ERROR: unknown flag: --scope (ac-know.sh add writes facts; the scope map is not writable here)" add --fact x --scope orchid --apps a
xrefuse "ERROR: unknown flag: -h" retire -h
xrefuse "ERROR: unknown flag: --new" cite --new
xrefuse "ERROR: unknown flag: --max" verify --max 1
xrefuse "ERROR: unknown flag: --new" scope-proposal --new
xrefuse "ERROR: unknown flag: --max=3 (a question word that starts with - goes after --)" recall q --max=3
xrefuse "ERROR: unknown flag: --limit (a question word that starts with - goes after --)" recall q --limit 3
xrefuse "ERROR: unknown flag: -x (a question word that starts with - goes after --)" recall -x
xrefuse "ERROR: entry rejected: no question - pass the order's subject/mechanism/terms" recall
xrefuse "ERROR: entry rejected: no question - pass the order's subject/mechanism/terms" recall --repo x --
xrefuse "ERROR: --bytes must be a byte count (got: '-1')" recall q --bytes -1
xrefuse "ERROR: --max must be a count (got: '')" recall q --max ''
xrefuse "ERROR: --max must be a count (got: '1x')" recall q --max 9 --max 1x
xrefuse "ERROR: --bytes must be a byte count (got: '0x10')" recall q --bytes 0x10
xusage recall -- --x
xusage recall '-x y' 'and more'
xusage recall q --max 00 --bytes 99999999999999999999
xrefuse "ERROR: usage: ac-know.sh scope-install <proposal-id> --home <abs> --repo <dir>" scope-install
xrefuse "ERROR: usage: ac-know.sh scope-install <proposal-id> --home <abs> --repo <dir>" scope-install ''
xrefuse "ERROR: unknown flag: @H/home" scope-install --home @H/home --repo @H/$XP p1
xrefuse "ERROR: unknown flag: p1" scope-install x --home @H/home p1
xrefuse "ERROR: invalid proposal id: a/b" scope-install a/b
xrefuse "ERROR: invalid proposal id: a b" scope-install 'a b'
xusage scope-install --home
xusage scope-install -x

# 2. the repo and the home (settle_repo, then ac_home_resolve's ladder): the
#    repo missing, no directory, no repo, relative, a subdirectory (W5, at
#    parity: the binding and the grade read cwd-relative); --home relative,
#    unreadable, inside the repo, a link back inside, a home holding its
#    clone, one inside a linked worktree outside the main dir (W16); AC_HOME
#    alone, inside the repo (W16), relative; and the named divergences - an
#    AC_HOME cd cannot enter (HOME RESOLUTION: the original's own cd line), a
#    relative AC_HOME under an exported CDPATH (cd's echo doubled the home),
#    and bun off PATH.
xboth xstd
XS="$(git -C "$XNH/$XP" rev-parse HEAD)"; XS12="${XS:0:12}"
xrefuse "ERROR: --repo is not a directory: @H/nope" verify --home @H/home --repo @H/nope
xrefuse "ERROR: --repo is not a directory: @H/$XP/file.txt" verify --home @H/home --repo @H/$XP/file.txt
xrefuse "ERROR: --repo is not a git repo: @H/cwd" verify --home @H/home --repo @H/cwd
xrefuse "ERROR: --home must be an ABSOLUTE path outside the project repo (got 'home')" verify --home home --repo @H/$XP
xrefuse "ERROR: --home is not a readable directory: @H/nope" verify --home @H/nope --repo @H/$XP
xrefuse "ERROR: --home is not a readable directory: @H/$XP/file.txt" verify --home @H/$XP/file.txt --repo @H/$XP
xboth mkdir -p @H/$XP/.crew/h
xrefuse "ERROR: --home must be an ABSOLUTE path outside the project repo: @H/$XP/.crew/h resolves to @H/$XP/.crew/h, inside @H/$XP" verify --home @H/$XP/.crew/h --repo @H/$XP
xrefuse "ERROR: --home must be an ABSOLUTE path outside the project repo: @H/$XP resolves to @H/$XP, inside @H/$XP" verify --home @H/$XP --repo @H/$XP
xboth ln -s @H/$XP/.crew/h @H/evil
xrefuse "ERROR: --home must be an ABSOLUTE path outside the project repo: @H/evil resolves to @H/$XP/.crew/h, inside @H/$XP" verify --home @H/evil --repo @H/$XP
xrefuse "ERROR: --home must be an ABSOLUTE path outside the project repo: @H/evil/ resolves to @H/$XP/.crew/h, inside @H/$XP" verify --home @H/evil/ --repo @H/$XP/sub
xok verify --home @H/home --repo @H/$XP
assert_eq "$(xout)" "no repo-knowledge record yet: @H/$XREC" "2: verify with no record says so and stamps nothing"
xok verify --home @H/home/ --repo @H/$XP/
xok verify --home @H/$XP/../.. --repo @H/$XP/./sub/..
xboth mkdir -p @H/proj2home
xok add --home @H/proj2home --repo @H/$XP --family f1 --src-file file.txt:1 --fact 'a home beside the clone holds its record'
XCWD=home/projects
xok add --home @H/home --repo proj --family f1 --src-file three.txt:2 --fact 'a relative repo binds from the caller cwd'
XCWD=cwd
xboth git -C @H/$XP worktree add -q --detach @H/out/wt
xboth mkdir -p @H/out/wt/h
xok add --home @H/out/wt/h --repo @H/out/wt --family w16 --src-file file.txt:1 --fact 'W16: a home inside an outside linked worktree is accepted'
assert_contains "$(xfile out/wt/h/records/repo-knowledge/proj.md)" "by: w16" "2 (W16, at parity): the record lands in the linked worktree"
xrefuse "$XNOHOME" verify --repo @H/$XP
xrefuse "$XNOHOME" add --repo @H/$XP --family f1 --src-file file.txt:1 --fact x
XENV=("AC_HOME=@H/home")
xok cite --repo @H/$XP --quote 'relative repo'
XENV=("AC_HOME=@H/$XP/inhome")
xboth mkdir -p @H/$XP/inhome
xok add --repo @H/$XP --family w16 --src-file file.txt:1 --fact 'W16: an AC_HOME inside the repo is not guarded'
XCWD=.; XENV=("AC_HOME=home")
xok cite --repo home/projects/proj --quote 'relative repo binds'
XCWD=cwd; XENV=("AC_HOME=@H/nope")
xpair verify --repo @H/$XP
xsame_rc_out verify; xsame_world verify
assert_eq "$XN_RC:$(xerr)" "1:ERROR: AC_HOME is not a readable directory: @H/nope" "2 (HOME RESOLUTION, named): an AC_HOME cd cannot enter is named"
case "$(xoerr)" in "ROOT/bin/ac-lib.sh: line "*": cd: @H/nope: No such file or directory") ;; *) fail "2: the original's line for it is cd's own: $(xoerr)" ;; esac
XCWD=.; XENV=("AC_HOME=home" "CDPATH=@H")
xpair verify --repo @H/$XP
assert_eq "$XN_RC:$(xerr)" "0:" "2 (HOME RESOLUTION, named): CDPATH never moves the home..."
assert_contains "$(xout)" "FRESH   - fact a relative repo binds from the caller cwd" "2: ...so the port verifies the home's record"
assert_eq "$XO_RC:$(xoout)" "0:no repo-knowledge record yet: /repo-knowledge/proj.md" "2: the original's cd echo doubled the home, and the record path fell to /"
assert_contains "$(xoerr)" ": No such file or directory" "2: ...past cd's own line"
XCWD=cwd; XENV=()
xboth xstd
XPATH="$(xwithout bun)"
xpair verify --home @H/home --repo @H/$XP
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: required tool not found: bun" "2 (BUN, named): the shim refuses without bun"
assert_eq "$XO_RC:$(xoout)" "0:no repo-knowledge record yet: @H/$XREC" "2: the original ran without it"
xboth rm -rf @H/home/records
XPATH=""
XPATH="$(xwithout git)"
xrefuse "ERROR: required tool not found: git" verify --home @H/home --repo @H/$XP
xrefuse "ERROR: required tool not found: git" -h
XPATH=""

# 3. add: every field refusal in code order, the provenance and the binding
#    (doors A unstaged and staged, B, G, E, a cmd in a dirty tree, a tree git
#    cannot read, door N and its same-branch inverse, W5's subdirectory), the
#    --src-file shapes (W10's line 0 and 01 at parity), the line-pointer
#    guard both ways, and the composed entry and the record's first render.
xboth xstd
XA=(add --home @H/home --repo @H/$XP --family f1)
xrefuse "ERROR: entry rejected: no subject - pass --fact <text>" "${XA[@]}" --src-file file.txt:1
xrefuse "ERROR: entry rejected: no subject - pass --fact <text>" "${XA[@]}" --fact ''
xrefuse "ERROR: entry rejected: --fact must be a single line (no newline or carriage return)" "${XA[@]}" --fact $'a\nb'
xrefuse "ERROR: entry rejected: --fact must be a single line (no newline or carriage return)" "${XA[@]}" --fact $'a\rb' --family ''
xrefuse "ERROR: entry rejected: '|' is the field separator, so it cannot appear in --fact" "${XA[@]}" --fact 'a | b'
xrefuse "ERROR: entry rejected: --fact cites the repo-knowledge record by line number, which has no stable identity to point at (quote the entry's own text instead): CORRECTS repo-knowledge:169" "${XA[@]}" --fact 'CORRECTS repo-knowledge:169'
xrefuse "ERROR: entry rejected: --fact cites the repo-knowledge record by line number, which has no stable identity to point at (quote the entry's own text instead): see records/repo-knowledge/agent-crew.md:9x" "${XA[@]}" --fact 'see records/repo-knowledge/agent-crew.md:9x'
xrefuse "ERROR: entry rejected: no attribution - pass --family <family>" add --home @H/home --repo @H/$XP --fact x
xrefuse "ERROR: entry rejected: --family must match [a-z0-9-] (got 'Bad_Family')" "${XA[@]}" --family Bad_Family --fact x
xrefuse "ERROR: entry rejected: --family must match [a-z0-9-] (got 'f.1')" "${XA[@]}" --family f.1 --fact x
xrefuse "ERROR: entry rejected: an entry has ONE provenance - pass --src-file or --src-cmd, not both" "${XA[@]}" --src-file file.txt:1 --src-cmd ls --fact x
xrefuse "ERROR: entry rejected: no provenance - pass --src-file <path>:<line> or --src-cmd <command>" "${XA[@]}" --src-file '' --src-cmd '' --fact x
xrefuse "ERROR: entry rejected: --at 'nosuchref' does not resolve to a commit in this repo" "${XA[@]}" --src-file file.txt:1 --at nosuchref --fact x
xrefuse "ERROR: entry rejected: --at 'HEAD^{tree}' does not resolve to a commit in this repo" "${XA[@]}" --src-file file.txt:1 --at 'HEAD^{tree}' --fact x
xrefuse "ERROR: entry rejected: --src-file must be a single line (no newline or carriage return)" "${XA[@]}" --src-file $'file.txt\n:1' --fact x
xrefuse "ERROR: entry rejected: '|' is the field separator, so it cannot appear in --src-file" "${XA[@]}" --src-file 'a|b:1' --fact x
xrefuse "ERROR: entry rejected: --src-file wants <path>:<line> (got 'file.txt')" "${XA[@]}" --src-file file.txt --fact x
xrefuse "ERROR: entry rejected: --src-file wants <path>:<line> (got 'file.txt:1y')" "${XA[@]}" --src-file file.txt:1y --fact x
xrefuse "ERROR: entry rejected: --src-file wants <path>:<line> (got 'file.txt:')" "${XA[@]}" --src-file file.txt: --fact x
xrefuse "ERROR: entry rejected: --src-file names no path (got ':1') - it wants <path>:<line>" "${XA[@]}" --src-file :1 --fact x
xrefuse "ERROR: entry rejected: --src-file must be repo-relative (no absolute path, no ..): ../x" "${XA[@]}" --src-file ../x:1 --fact x
xrefuse "ERROR: entry rejected: --src-file must be repo-relative (no absolute path, no ..): /etc/passwd" "${XA[@]}" --src-file /etc/passwd:1 --fact x
xrefuse "ERROR: entry rejected: --src-file must be repo-relative (no absolute path, no ..): a..b" "${XA[@]}" --src-file a..b:1 --fact x
xrefuse "ERROR: entry rejected: nope.txt does not exist at $XS12 - the citation cannot be followed" "${XA[@]}" --src-file nope.txt:1 --fact x
xrefuse "ERROR: entry rejected: file.txt:1 does not exist at $XS12 - the citation cannot be followed" "${XA[@]}" --src-file file.txt:1:1 --fact x
xrefuse "ERROR: entry rejected: apps is a tree at $XS12, not a file - a <path>:<line> citation into it is not followable by any reader" "${XA[@]}" --src-file apps:1 --fact x
xrefuse "ERROR: entry rejected: apps/ is a tree at $XS12, not a file - a <path>:<line> citation into it is not followable by any reader" "${XA[@]}" --src-file apps/:1 --fact x
xrefuse "ERROR: entry rejected: file.txt has 1 lines at $XS12; the citation names line 2" "${XA[@]}" --src-file file.txt:2 --fact x
xrefuse "ERROR: entry rejected: three.txt has 3 lines at $XS12; the citation names line 99999999999999999999" "${XA[@]}" --src-file three.txt:99999999999999999999 --fact x
xrefuse "ERROR: entry rejected: --src-cmd must be a single line (no newline or carriage return)" "${XA[@]}" --src-cmd $'ls\rx' --fact x
xrefuse "ERROR: entry rejected: '|' is the field separator, so it cannot appear in --src-cmd" "${XA[@]}" --src-cmd 'ls | wc' --fact x
xok "${XA[@]}" --src-file file.txt:1 --fact 'file.txt holds the greeting'
assert_eq "$(xout)" "recorded in @H/$XREC" "3: the write prints the path it used"
assert_eq "$(xfile "$XREC")" "# Repo knowledge: proj

$XBOILER1

- fact file.txt holds the greeting | src: file:file.txt:1 | at: $XS 2026-01-01 | by: f1

## Superseded

$XBOILER2" "3: the first render, byte for byte"
xok "${XA[@]}" --src-cmd 'ls *.txt' --fact 'two txt files at the root, counted by ls'
xok "${XA[@]}" --src-file link.ts:1 --fact 'a symlink cites its target and is followable'
xok "${XA[@]}" --src-file three.txt:0 --new --fact 'W10: line 0 is accepted'
xok "${XA[@]}" --src-file three.txt:03 --new --fact 'W10: line 03 is recorded as given'
xok "${XA[@]}" --src-file 'apps/a/main.ts:1' --at main --new --fact 'G: a branch at is recorded resolved'
xok "${XA[@]}" --src-file 'apps/a/main.ts:1' --at "${XS:0:7}" --new --fact 'E: a short sha at is recorded resolved'
xok "${XA[@]}" --src-file file.txt:1 --new --fact $'a TAB\tand trailing blanks are kept  '
xok "${XA[@]}" --src-file file.txt:1 --new --fact 'an ordinary code citation bin/ac-tree.sh:405 is kept'
xok "${XA[@]}" --src-file file.txt:1 --new --fact 'a backslash \d+ and an apostrophe in the chief'"'"'s words'
xok "${XA[@]}" --src-file file.txt:1 --family -x --new --fact 'W11: a dash-led family passes at parity'
# Door A, unstaged then staged; the per-path binding lets a clean citation
# through a dirty tree; a cmd: binds the whole tree; door B.
xboth sh -c 'printf "changed\n" >"$0/file.txt"' @H/$XP
xrefuse "ERROR: entry rejected: file.txt differs between the worktree and $XS12 - the fact you observed is not what that ref holds. Commit the file first, or pass --at <ref> that contains what you saw" "${XA[@]}" --src-file file.txt:1 --fact 'door A, unstaged'
xboth git -C @H/$XP add file.txt
xrefuse "ERROR: entry rejected: file.txt differs between the worktree and $XS12 - the fact you observed is not what that ref holds. Commit the file first, or pass --at <ref> that contains what you saw" "${XA[@]}" --src-file file.txt:1 --fact 'door A, staged'
xok "${XA[@]}" --src-file three.txt:1 --fact 'a clean citation through a dirty tree still binds per path'
xrefuse "ERROR: entry rejected: the tracked tree differs from $XS, so a cmd: provenance cannot be bound to it. Check out that commit with a clean tree, or cite the specific file with --src-file" "${XA[@]}" --src-cmd ls --fact 'a cmd in a dirty tree'
# W5 (at parity): a --repo that is a subdirectory binds file.txt against
# sub/file.txt, which is absent, and the default HEAD is an ancestor of
# itself - so the diff runs cwd-relative and finds nothing dirty.
xok "${XA[@]}" --repo @H/$XP/sub --src-file file.txt:1 --new --fact 'W5: a subdirectory repo binds vacuously'
xboth git -C @H/$XP reset -q --hard
xboth xcommit $XP file.txt 'second'
XS2="$(git -C "$XNH/$XP" rev-parse HEAD)"
xrefuse "ERROR: entry rejected: file.txt differs between the worktree and $XS12 - the fact you observed is not what that ref holds. Commit the file first, or pass --at <ref> that contains what you saw" "${XA[@]}" --src-file file.txt:1 --at "$XS" --fact 'door B'
xrefuse "ERROR: entry rejected: the tracked tree differs from $XS, so a cmd: provenance cannot be bound to it. Check out that commit with a clean tree, or cite the specific file with --src-file" "${XA[@]}" --src-cmd ls --at "$XS" --fact 'door B, cmd'
xok "${XA[@]}" --src-file file.txt:1 --at "$XS2" --new --fact 'door B, the right at'
# Door N: a path only an integration branch holds binds with no diff; one
# this branch deleted (its at an ancestor of HEAD) still refuses.
xboth git -C @H/$XP checkout -qb integration
xboth xcommit $XP apps/only/feature.sh 'integration only'
XSI="$(git -C "$XNH/$XP" rev-parse HEAD)"
xboth git -C @H/$XP checkout -q main
xrefuse "ERROR: entry rejected: apps/only/feature.sh does not exist at ${XS2:0:12} - the citation cannot be followed" "${XA[@]}" --src-file apps/only/feature.sh:1 --fact 'door N, default at'
xok "${XA[@]}" --src-file apps/only/feature.sh:1 --at "$XSI" --fact 'door N: an integration-only feature line'
xok "${XA[@]}" --src-file apps/only/feature.sh:1 --at integration --new --fact 'door N through the branch name'
xboth xcommit $XP gone.txt 'doomed'
XSG="$(git -C "$XNH/$XP" rev-parse HEAD)"
xboth git -C @H/$XP rm -q gone.txt
xboth git -C @H/$XP commit -qm 'remove gone'
xrefuse "ERROR: entry rejected: gone.txt differs between the worktree and ${XSG:0:12} - the fact you observed is not what that ref holds. Commit the file first, or pass --at <ref> that contains what you saw" "${XA[@]}" --src-file gone.txt:1 --at "$XSG" --fact 'a same-branch deletion refuses'
# A tree git cannot read: the commit resolves, its tree is gone, so the
# diff errors (above 1) and the binding fails closed with git's own lines.
xboth xrepo out/broke
xboth sh -c 't="$(git -C "$0" rev-parse "HEAD^{tree}")"; rm -f "$0/.git/objects/$(printf %s "$t" | cut -c1-2)/$(printf %s "$t" | cut -c3-)"' @H/out/broke
xsame add --home @H/home --repo @H/out/broke --family f1 --src-cmd ls --fact 'unreadable tree'
assert_eq "$XN_RC" 1 "3: a tree git cannot read refuses"
assert_contains "$(xerr)" "ERROR: entry rejected: cannot compare the tracked tree against " "3: ...failing closed"
assert_contains "$(xerr)" "(git diff exited 128) - failing closed; an unreadable tree is not evidence of an unchanged one" "3: ...naming git's status"

# 4. the near-duplicate guard and --supersede, both through the lock: the
#    refusal with two candidates tied on shared tokens (sort -rn's reversed
#    whole-row order), --new, the superseded-near-duplicate warning with and
#    without a live successor, every --supersede arm, byte-identical twins
#    (W12, at parity), a hand-written non-entry line the next write drops, and
#    a hand-written CR before the LF every write carries.
xboth xstd
XD=(add --home @H/home --repo @H/$XP --family d1 --src-file file.txt:1)
xboth xrecord "- fact the pooled worktree lease survives a restart because the slot meta is durable on disk | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a1
- fact Bravo pooled worktree lease survives restart reading the slot meta durable | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a2
- fact alpha pooled worktree lease survives restart reading the slot meta durable | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 4 | by: a3
a hand note between entries
- fact the qa store freezes its coverage manifest before any case executes | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a4
- fact the queue drains oldest jobs first because a monotonic sequence number orders them | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a5
- fact a hand-edited entry ending in a carriage return | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a6"$'\r'"
" "- fact the queue drains oldest jobs first because insertion order is preserved | src: file:file.txt:1 | at: $XS 2026-01-01 | by: s1
- fact the pool worker retries exactly three times before giving up | src: file:file.txt:1 | at: $XS 2026-01-01 | by: s2
"
xsame "${XD[@]}" --fact 'the pooled worktree lease survives a restart since its slot meta is durable on disk'
assert_eq "$XN_RC" 1 "4: a near-duplicate is refused"
assert_eq "$(xerr)" "ERROR: this subject already has a live entry (nothing written) - two claims about one subject is the defect this guard exists to stop:
- fact the pooled worktree lease survives a restart because the slot meta is durable on disk | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a1
- fact alpha pooled worktree lease survives restart reading the slot meta durable | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 4 | by: a3
- fact Bravo pooled worktree lease survives restart reading the slot meta durable | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a2

  correct the existing one:  --supersede '<phrase quoted from it>'   (retires it and adds yours in one write)
  genuinely distinct:        --new                                    (declares it, and the guard stands aside)" "4: the refusal names every candidate, most shared first, ties by sort -rn's reversed whole row"
xok "${XD[@]}" --fact 'the qa store is unrelated to the pooled lease subject entirely'
xsame "${XD[@]}" --fact 'the queue drains oldest jobs first since insertion order is preserved'
assert_eq "$XN_RC:$(xout)" "0:recorded in @H/$XREC" "4: a superseded near-duplicate still lands"
assert_eq "$(xerr)" "add: warning - this subject near-duplicates a SUPERSEDED entry; the fleet already judged this wording wrong or stale once:
- fact the queue drains oldest jobs first because insertion order is preserved | src: file:file.txt:1 | at: $XS 2026-01-01 | by: s1
  replaced by:
    - fact the queue drains oldest jobs first because a monotonic sequence number orders them | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a5" "4: ...warning, naming the live successor"
xsame "${XD[@]}" --fact 'the pool worker retries exactly three times before it gives up'
assert_eq "$XN_RC" 0 "4: a near-duplicate with no successor lands"
assert_eq "$(xerr)" "add: warning - this subject near-duplicates a SUPERSEDED entry; the fleet already judged this wording wrong or stale once:
- fact the pool worker retries exactly three times before giving up | src: file:file.txt:1 | at: $XS 2026-01-01 | by: s2" "4: ...the entry being written is no successor yet"
xok "${XD[@]}" --new --fact 'the pooled worktree lease survives a restart since its slot meta is durable on disk'
xok "${XD[@]}" --new --fact 'W12: a twin entry written twice'
xok "${XD[@]}" --new --fact 'W12: a twin entry written twice'
xrefuse "ERROR: --supersede matched nothing: no live fact contains 'no such phrase' (nothing written)" "${XD[@]}" --supersede 'no such phrase' --fact 'a replacement nobody asked for'
xrefuse "ERROR: --supersede 'twin entry' is ambiguous - 2 live entries match, quote a longer phrase (nothing written):
- fact W12: a twin entry written twice | src: file:file.txt:1 | at: $XS 2026-01-01 | by: d1
- fact W12: a twin entry written twice | src: file:file.txt:1 | at: $XS 2026-01-01 | by: d1" "${XD[@]}" --supersede 'twin entry' --fact 'W12 at parity: twins are unaddressable'
xrefuse "ERROR: --supersede 'giving up' matches no LIVE fact, but matches a SUPERSEDED entry - a superseded entry cannot be corrected again; find the live entry that replaced it and quote that instead (nothing written):
- fact the pool worker retries exactly three times before giving up | src: file:file.txt:1 | at: $XS 2026-01-01 | by: s2" "${XD[@]}" --supersede 'giving up' --fact x
xrefuse "ERROR: --supersede 'insertion order is preserved' matches one live entry AND a SUPERSEDED entry - ambiguous which the caller means; quote a longer, disambiguating phrase (nothing written):
  live: - fact the queue drains oldest jobs first since insertion order is preserved | src: file:file.txt:1 | at: $XS 2026-01-01 | by: d1
- fact the queue drains oldest jobs first because insertion order is preserved | src: file:file.txt:1 | at: $XS 2026-01-01 | by: s1" "${XD[@]}" --supersede 'insertion order is preserved' --fact x
xok "${XD[@]}" --supersede 'coverage manifest' --new --fact 'the qa store freezes the manifest only once the run starts'
assert_eq "$(xout)" "recorded in @H/$XREC" "4: --supersede lands in one write"
case "$(xfile "$XREC")" in *"a hand note"*) fail "4: a non-entry line is dropped by the next write" ;; esac
assert_contains "$(xfile "$XREC")" "| by: a6"$'\r\n' "4: a CR before the LF is carried byte for byte"
xrefuse "ERROR: --supersede 'pooled worktree lease survives restart' is ambiguous - 2 live entries match, quote a longer phrase (nothing written):
- fact Bravo pooled worktree lease survives restart reading the slot meta durable | src: file:file.txt:1 | at: $XS 2026-01-01 | by: a2
- fact alpha pooled worktree lease survives restart reading the slot meta durable | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 4 | by: a3" "${XD[@]}" --supersede Bravo --supersede 'pooled worktree lease survives restart' --fact 'the last --supersede wins'
xrefuse "ERROR: --supersede matched nothing: no live fact contains 'by: a2' (nothing written)" "${XD[@]}" --supersede 'by: a2' --fact 'a quote is matched against the subject only'
xok "${XD[@]}" --supersede 'Bravo pooled' --fact 'Bravo was wrong about the lease'

# 5. retire and cite, addressed by a quoted phrase: no target, no why, the
#    provenance, zero matches, a --by that empties real matches (one family,
#    several - sort -u's byte order), superseded-only, ambiguous, one live
#    plus a superseded hit (retire refuses, cite warns), the happy MOVE and
#    receipt; cite's heat arms (absent, 1, 010 and 08 - W13 through bash's
#    arithmetic, int64's edge and past it, x, a second heat field) and an
#    entry with no `| by: `; backslashes in the quote (C9).
xboth xstd
XR=(retire --home @H/home --repo @H/$XP --family r9 --src-file file.txt:1)
XC=(cite --home @H/home --repo @H/$XP)
xrefuse "ERROR: cite: no repo-knowledge record yet: @H/$XREC" "${XC[@]}" --quote x
xboth xrecord "- fact the --changed selector widens to the full suite when empty | src: file:file.txt:1 | at: $XS 2026-01-01 | by: fam-r
- fact a selector fact still needs its own citation | src: file:file.txt:1 | at: $XS 2026-01-01 | by: fam-b
- fact a selector fact twice over | src: file:file.txt:1 | at: $XS 2026-01-01 | by: Fam-a
- fact the pool lease survives a restart because the slot record persists | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 7 | by: h1
- fact the pool lease now checks a leasefile, not that the slot meta is durable | src: file:file.txt:1 | at: $XS 2026-01-01 | by: h2
- fact heat ten in octal 010 | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 010 | by: h3
- fact heat at the int64 edge | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 9223372036854775807 | by: h4
- fact heat past int64 | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 99999999999999999999 | by: h5
- fact heat that is no number | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: x | by: h6
- fact two heat fields | heat: 3 here | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 5 | by: h7
- fact an entry with no by field | src: file:file.txt:1 | at: $XS 2026-01-01
- fact the pattern \d+ matches a run of digits | src: file:file.txt:1 | at: $XS 2026-01-01 | by: h8
- scope gw = gateway | src: file:file.txt:1 | at: $XS 2026-01-01 | by: s1
" "- fact the retired claim lives only here now | src: file:file.txt:1 | at: $XS 2026-01-01 | by: old
- fact the slot meta is durable on disk, an old claim | src: file:file.txt:1 | at: $XS 2026-01-01 | by: old
"
xrefuse "ERROR: entry rejected: no target - pass --quote '<phrase from the entry's own text>'" "${XR[@]}" --why w
xrefuse "ERROR: entry rejected: a retirement records WHY - pass --why <text>" "${XR[@]}" --quote q
xrefuse "ERROR: entry rejected: --why must be a single line (no newline or carriage return)" "${XR[@]}" --quote q --why $'a\nb'
xrefuse "ERROR: entry rejected: '|' is the field separator, so it cannot appear in --why" "${XR[@]}" --quote q --why 'a|b'
xrefuse "ERROR: entry rejected: no attribution - pass --family <family>" "${XR[@]}" --family '' --quote q --why w
xrefuse "ERROR: entry rejected: no target - pass --quote '<phrase from the entry own text>'" "${XC[@]}"
xrefuse "ERROR: retire: nothing matched 'no such phrase' - no live fact entry contains that phrase" "${XR[@]}" --quote 'no such phrase' --why w
xrefuse "ERROR: retire: nothing matched 'no such phrase' by family fam-r - no live fact entry contains that phrase" "${XR[@]}" --quote 'no such phrase' --by fam-r --why w
xrefuse "ERROR: retire: nothing matched 'gateway' - no live fact entry contains that phrase" "${XR[@]}" --quote gateway --why 'a scope line is never a fact'
xrefuse "ERROR: retire: 'widens to the full' matches 1 live entry, none by family fam-x - --by is the entry's author family, and these wrote the matches: fam-r (narrow with one of them, or a longer quote)" "${XR[@]}" --quote 'widens to the full' --by fam-x --why w
xrefuse "ERROR: cite: 'selector' matches 3 live entries, none by family zz - --by is the entry's author family, and these wrote the matches: Fam-a fam-b fam-r (narrow with one of them, or a longer quote)" "${XC[@]}" --quote selector --by zz
xrefuse "ERROR: retire: 'selector' is ambiguous - 3 live entries match, narrow with --by <family>:
- fact the --changed selector widens to the full suite when empty | src: file:file.txt:1 | at: $XS 2026-01-01 | by: fam-r
- fact a selector fact still needs its own citation | src: file:file.txt:1 | at: $XS 2026-01-01 | by: fam-b
- fact a selector fact twice over | src: file:file.txt:1 | at: $XS 2026-01-01 | by: Fam-a" "${XR[@]}" --quote selector --why w
xrefuse "ERROR: cite: 'selector fact' is ambiguous - 2 live entries match, narrow with --by <family>:
- fact a selector fact still needs its own citation | src: file:file.txt:1 | at: $XS 2026-01-01 | by: fam-b
- fact a selector fact twice over | src: file:file.txt:1 | at: $XS 2026-01-01 | by: Fam-a" "${XC[@]}" --quote 'selector fact'
xrefuse "ERROR: retire: 'lives only here' matches no LIVE fact, but matches a SUPERSEDED entry - a superseded entry cannot be retired again; find the live entry that replaced it and quote that instead:
- fact the retired claim lives only here now | src: file:file.txt:1 | at: $XS 2026-01-01 | by: old" "${XR[@]}" --quote 'lives only here' --why w
xrefuse "ERROR: retire: 'lives only here' by family old matches no LIVE fact, but matches a SUPERSEDED entry - a superseded entry cannot be retired again; find the live entry that replaced it and quote that instead:
- fact the retired claim lives only here now | src: file:file.txt:1 | at: $XS 2026-01-01 | by: old" "${XR[@]}" --quote 'lives only here' --by old --why w
xrefuse "ERROR: cite: 'lives only here' matches no LIVE fact, but matches a SUPERSEDED entry - find the live entry that replaced it and quote that instead:
- fact the retired claim lives only here now | src: file:file.txt:1 | at: $XS 2026-01-01 | by: old" "${XC[@]}" --quote 'lives only here'
xrefuse "ERROR: retire: 'slot meta is durable' matches one live entry AND a SUPERSEDED entry - ambiguous which the caller means; quote a longer, disambiguating phrase (nothing written):
  live: - fact the pool lease now checks a leasefile, not that the slot meta is durable | src: file:file.txt:1 | at: $XS 2026-01-01 | by: h2
- fact the slot meta is durable on disk, an old claim | src: file:file.txt:1 | at: $XS 2026-01-01 | by: old" "${XR[@]}" --quote 'slot meta is durable' --why w
xsame "${XC[@]}" --quote 'slot meta is durable'
assert_eq "$XN_RC:$(xout)" "0:- fact the pool lease now checks a leasefile, not that the slot meta is durable | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 1 | by: h2
cited in @H/$XREC" "5: cite bumps the live match of a double match"
assert_eq "$(xerr)" "cite: warning - slot meta is durable also matches a SUPERSEDED entry; heat is bumped on the live match only:
- fact the slot meta is durable on disk, an old claim | src: file:file.txt:1 | at: $XS 2026-01-01 | by: old" "5: ...and warns"
xok "${XC[@]}" --quote 'pool lease survives'
assert_contains "$(xout)" "| heat: 8 | by: h1" "5: an existing heat increments in place"
xok "${XC[@]}" --quote 'octal 010'
assert_contains "$(xout)" "| heat: 9 | by: h3" "5 (W13, at parity): 010 is octal to bash's arithmetic"
xok "${XC[@]}" --quote 'int64 edge'
assert_contains "$(xout)" "| heat: -9223372036854775808 | by: h4" "5 (W13, at parity): int64 wraps"
xok "${XC[@]}" --quote 'past int64'
assert_contains "$(xout)" "| heat: 7766279631452241920 | by: h5" "5 (W13, at parity): past int64 wraps as the shell read it"
xrefuse "ERROR: cite: malformed heat field on the matched entry (got: '| heat: x'): - fact heat that is no number | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: x | by: h6" "${XC[@]}" --quote 'no number'
xok "${XC[@]}" --quote 'two heat fields'
assert_contains "$(xout)" "| heat: 3 here | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 6 | by: h7" "5: the LAST heat field before the LAST by is the counter"
xrefuse "ERROR: cite: malformed heat field on the matched entry (got: '| heat: -9223372036854775808'): - fact heat at the int64 edge | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: -9223372036854775808 | by: h4" "${XC[@]}" --quote 'int64 edge'
xrefuse "ERROR: cite: matched entry carries no '| by:' field - not a grammar line this verb can bump: - fact an entry with no by field | src: file:file.txt:1 | at: $XS 2026-01-01" "${XC[@]}" --quote 'no by field'
xok "${XC[@]}" --quote 'pattern \d+ matches'
assert_contains "$(xout)" 'the pattern \d+ matches a run of digits | src:' "5 (C9): a backslash quote addresses its entry"
xok "${XC[@]}" --quote 'pattern \d+' --by h8
xok "${XR[@]}" --quote 'widens to the full suite' --by fam-r --why 'contradicts run-suite.sh, not a widen'
assert_eq "$(xout)" "retired from @H/$XREC" "5: retire prints the record it wrote"
xok "${XR[@]}" --src-cmd 'grep -c x file.txt' --src-file '' --quote 'twice over' --why 'a cmd receipt'
xok "${XR[@]}" --quote 'slot meta is durable' --by h2 --why 'a --by narrows the superseded search too'
# heat 08 is no octal number: bash's arithmetic ended the run 1 past the
# lock, leaving it and the two temps (SHELL-OWN STDERR; NO TEMPS, named).
xboth sh -c 'printf -- "- fact heat in bad octal | src: file:file.txt:1 | at: x 2026-01-01 | heat: 08 | by: h9\n" >"$0.add"; awk -v f="$0.add" "/^## Superseded/ { while ((getline l < f) > 0) print l } { print }" "$0" >"$0.new" && mv "$0.new" "$0" && rm -f "$0.add"' @H/$XREC
xpair "${XC[@]}" --quote 'bad octal'
xsame_rc_out cite
assert_eq "$XN_RC:$(xerr)" "1:" "5 (W13, at parity; SHELL-OWN STDERR, named): heat 08 ends the run 1"
assert_contains "$(xoerr)" ": 08: value too great for base (error token is \"08\")" "5: the original's line is bash's own"
[ -d "$XNH/$XREC.lock" ] && [ -d "$XOH/$XREC.lock" ] || fail "5 (W13): both leave the lock held"
assert_eq "$(ls "$XNH/tmp" | wc -l | tr -d ' '):$(ls "$XOH/tmp" | wc -l | tr -d ' ')" "0:2" "5 (NO TEMPS, named): the original left its two temps, the port makes none"
cmp -s "$XNH/$XREC" "$XOH/$XREC" || fail "5 (W13): neither side wrote the record"

# 6. the record's lock: a live holder (30 PATH sleeps, then the timeout,
#    nothing written) for add, retire, cite and scope-install - a draft
#    takes no lock; a dead
#    holder's lock and a pid-less one older than the grace are reclaimed; a
#    pid-less young one is waited out like a live holder.
xboth xstd
xboth xrecord "- fact the lock guards every write | src: file:file.txt:1 | at: $XS 2026-01-01 | by: l1
"
xboth mkdir @H/$XREC.lock
xboth sh -c 'printf "%s\n" "$0" >"$1"' "$$" @H/$XREC.lock/pid
xrefuse "ERROR: ac-know: lock timeout for proj" add --home @H/home --repo @H/$XP --family l2 --src-file file.txt:1 --new --fact 'must not land while locked'
assert_eq "$(wc -l <"$XNH/stub/sleep.log" | tr -d ' ')" "30" "6: thirty PATH sleeps before the timeout"
xboth rm -f @H/stub/sleep.log
xrefuse "ERROR: ac-know: lock timeout for proj" retire --home @H/home --repo @H/$XP --family l2 --src-file file.txt:1 --quote 'lock guards' --why w
xboth rm -f @H/stub/sleep.log
xrefuse "ERROR: ac-know: lock timeout for proj" cite --home @H/home --repo @H/$XP --quote 'lock guards'
xboth rm -f @H/stub/sleep.log
xok scope-proposal --home @H/home --repo @H/$XP --family l2 --src-file file.txt:1 --scope lk --apps l --id lk
xrefuse "ERROR: scope-install: lock timeout for proj" scope-install lk --home @H/home --repo @H/$XP
xboth rm -f @H/stub/sleep.log
xboth sh -c 'printf "999999\n" >"$0"' @H/$XREC.lock/pid
xok cite --home @H/home --repo @H/$XP --quote 'lock guards'
assert_eq "$(cat "$XNH/stub/sleep.log" 2>/dev/null || true)" "" "6: a dead holder's lock is reclaimed at once"
xboth mkdir @H/$XREC.lock
xboth touch -t 202001010000 @H/$XREC.lock
xok cite --home @H/home --repo @H/$XP --quote 'lock guards'
xboth mkdir @H/$XREC.lock
xrefuse "ERROR: ac-know: lock timeout for proj" cite --home @H/home --repo @H/$XP --quote 'lock guards'
assert_eq "$(wc -l <"$XNH/stub/sleep.log" | tr -d ' ')" "30" "6: a young pid-less lock is waited out"
xboth rm -rf @H/$XREC.lock @H/stub/sleep.log

# 7. recall: scenes (L2) then facts (L1), each ranked by term hits, then
#    heat, then the whole row in BYTE order; the term floor at 1, 2 and 3; a
#    question with no 4-character term (W17: it can never hit); an absence;
#    --max and --bytes cutting hits and a miss, past int64 (W14, at parity -
#    bash's own `[:` lines not reproduced); heat parsed as the header says;
#    a scope line never offered; the cite hand-over's quote (apostrophes
#    escaped); scenes with no summary, a multi-heat line 2, no heat, a
#    directory named *.md; and an unreadable scene (sed's line not
#    reproduced, exit 1 kept).
xboth xstd
xboth xrecord "- fact the watcher beacon goes stale past the re-arm grace and the fleet watcher covers the panes | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r1
- fact the worktree pool lease is recorded in a slot meta that survives a restart | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r2
- fact the watcher skip self-revokes when its scoped beacon is stale past grace | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 2 | by: r3
- fact the lease grace window is counted in whole seconds | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r4
- fact Zeta zebra tiebreak entry | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r5
- fact alpha zebra tiebreak entry | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r6
- fact the chief's watcher beacon grace is three hundred seconds, it's said | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r7
- fact heat parsing beacon watcher entry | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: x | by: r8
- fact two heat beacon watcher entry | heat: 9 | src: file:file.txt:1 | at: $XS 2026-01-01 | heat: 010 | by: r9
- scope watcher = beacon-app | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r10
- fact a superseded-looking line still counts until the marker | src: cmd:true | at: $XS 2026-01-01 | by: r11
" "- fact the retired watcher beacon claim | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r0
"
xboth xput home/records/scenes/watcher-beacon.md '# Scene: watcher-beacon
META: created=2026-01-01T00:00:00Z updated=2026-01-01T00:00:00Z heat=3
summary: watcher beacon, skip and grace in one read

the whole watcher beacon and skip protocol, stale past grace, consolidated.
'
xboth xput home/records/scenes/aaa-nosummary.md '# Scene: aaa-nosummary
META: heat=1 heat=5
the watcher beacon scene with no summary line, stale grace
'
xboth xput home/records/scenes/bbb-noheat.md '# Scene: bbb-noheat
META: created=x
summary: a beacon watcher without heat
'
xboth xput home/records/scenes/zzz-offtopic.md '# Scene: zzz-offtopic
META: heat=9
summary: nothing about it
'
xboth mkdir -p @H/home/records/scenes/dir.md
XQ=(recall --home @H/home --repo @H/$XP)
xok "${XQ[@]}" 'watcher beacon stale grace'
assert_contains "$(xout)" "== scenes (L2 - a topic restored in one read) ==
    (hits 5, heat aaa-nosummary)
"'    '"
    open: ac-scene.sh show  --cite
  watcher-beacon  (hits 4, heat 3)
    watcher beacon, skip and grace in one read
    open: ac-scene.sh show watcher-beacon --cite" "7: the scene tier first - a multi-heat line 2 split its row in two, at parity"
assert_contains "$(xout)" "  (hits 4, heat 2) - fact the watcher skip self-revokes" "7: facts ranked by hits then heat"
xok "${XQ[@]}" watcher beacon
xok "${XQ[@]}" beacon
xok "${XQ[@]}" 'beacon xy' --max 3
xok "${XQ[@]}" -- --beacon
xok "${XQ[@]}" 'zebra tiebreak'
xok "${XQ[@]}" 'zebra tiebreak' --max 1
assert_contains "$(xout)" "- fact Zeta zebra tiebreak entry" "7: a tie at the cut goes to the lower byte row"
xok "${XQ[@]}" 'kubernetes ingress certificate rotation'
assert_eq "$(xout)" "no hit in any layer for: kubernetes ingress certificate rotation (needed 3 of its distinctive terms)
(state the absence explicitly in the brief - intake-triage skill)" "7: an absence is stated"
xok "${XQ[@]}" 'a b' cd
assert_contains "$(xout)" "(needed 1 of its distinctive terms)" "7 (W17, at parity): a question with no 4-character term never hits"
xok "${XQ[@]}" 'watcher beacon stale grace' --max 0
xok "${XQ[@]}" 'watcher beacon stale grace' --bytes 0
xok "${XQ[@]}" 'watcher beacon stale grace' --bytes 1 --max 2
xok "${XQ[@]}" 'kubernetes ingress certificate' --max 0 --bytes 0
xok "${XQ[@]}" "chief's watcher beacon grace"
assert_contains "$(xout)" "    cite: ac-know.sh cite --repo <clone> --quote 'the chief'\\''s watcher beacon grace is three hundred seconds, i'" "7: the quote's apostrophes are escaped, cut at 60 characters"
xok "${XQ[@]}" 'heat parsing two beacon watcher'
xok "${XQ[@]}" 'superseded-looking line marker'
xok "${XQ[@]}" 'gateway beacon-app watcher'
xpair "${XQ[@]}" 'watcher beacon stale grace' --max 99999999999999999999
xsame_rc_out recall; xsame_world recall
assert_eq "$XN_RC:$(xerr)" "0:" "7 (W14, at parity; SHELL-OWN STDERR, named): --max past int64 cuts the scenes, prints every fact"
assert_contains "$(xoerr)" "integer expression expected" "7: the original's lines are bash's own"
xpair "${XQ[@]}" 'watcher beacon stale grace' --bytes 99999999999999999999 --max 2
xsame_rc_out recall; xsame_world recall
if [ "$XROOTED" = 0 ]; then
  xboth chmod 000 @H/home/records/scenes/zzz-offtopic.md
  xpair "${XQ[@]}" 'watcher beacon'
  xsame_rc_out recall
  assert_eq "$XN_RC:$(xerr)" "1:" "7 (TOOL-OWN STDERR, named): an unreadable scene ends the run 1"
  assert_contains "$(xoerr)" "zzz-offtopic.md: Permission denied" "7: the original's line is sed's"
  assert_eq "$(ls "$XNH/tmp" | wc -l | tr -d ' '):$(ls "$XOH/tmp" | wc -l | tr -d ' ')" "0:1" "7 (NO TEMPS, named): the original left its scene list in TMPDIR"
  xboth chmod 644 @H/home/records/scenes/zzz-offtopic.md
  xboth sh -c 'rm -f "$0"/tmp/*' @H
fi
xboth rm -rf @H/home/records/scenes
xok "${XQ[@]}" 'watcher beacon stale grace'
xboth rm -f @H/$XREC
xok "${XQ[@]}" 'watcher beacon stale grace'

# 8. verify: one line per LIVE entry in record order - FRESH, SUSPECT
#    (changed, deleted), UNVERIFIABLE (an at that does not resolve, no
#    worktree copy, a diff that errors with git's own lines), MANUAL - a
#    heat-bearing entry, a scope line, lines with no fields, superseded
#    entries skipped; the stamp; W9 (an unreadable record stamps zeros, awk's
#    lines not reproduced; an unborn repo's head) and W5 at parity; a link
#    planted at the stamp's temp (EXCLUSIVE TEMPS, named).
xboth xstd
xboth git -C @H/$XP checkout -qb integration
xboth xcommit $XP apps/only/feature.sh 'integration only'
XSI="$(git -C "$XNH/$XP" rev-parse HEAD)"
xboth git -C @H/$XP checkout -q main
xboth xcommit $XP gone.txt 'doomed'
xboth git -C @H/$XP rm -q gone.txt
xboth git -C @H/$XP commit -qm 'remove gone'
XSG="$(git -C "$XNH/$XP" rev-parse HEAD~1)"
xboth xrecord "- fact keep is stable | src: file:file.txt:1 | at: $XS 2026-01-01 | by: v1
- fact three changes | src: file:three.txt:2 | at: $XS 2026-01-01 | heat: 3 | by: v1
- fact gone will go | src: file:gone.txt:1 | at: $XSG 2026-01-01 | by: v1
- fact the ref vanished | src: file:file.txt:1 | at: 0000000000000000000000000000000000000000 2026-01-01 | by: v1
- fact integration only | src: file:apps/only/feature.sh:1 | at: $XSI 2026-01-01 | by: v1
- fact three txt files | src: cmd:ls *.txt | at: $XS 2026-01-01 | by: v1
- scope apps = a, b | src: file:apps/a/main.ts:1 | at: $XS 2026-01-01 | by: v1
- a line with no fields at all
- fact no at | src: file:file.txt:1 | at:  | by: v1
- fact path:with:colons | src: file:dir:x/f.txt:3 | at: $XS 2026-01-01 | by: v1
" "- fact superseded claim | src: file:file.txt:1 | at: $XS 2026-01-01 | by: v0
"
xboth sh -c 'printf "moved\n" >"$0/three.txt"' @H/$XP
XV=(verify --home @H/home --repo @H/$XP)
xok "${XV[@]}"
assert_contains "$(xout)" "FRESH   - fact keep is stable" "8: FRESH"
assert_contains "$(xout)" "SUSPECT - fact three changes | src: file:three.txt:2 | at: $XS 2026-01-01 | heat: 3 | by: v1  (three.txt changed since $XS12)" "8: SUSPECT, the worktree compared"
assert_contains "$(xout)" "MANUAL  - fact three txt files | src: cmd:ls *.txt | at: $XS 2026-01-01 | by: v1  (re-run: ls *.txt)" "8: MANUAL"
assert_eq "$(xfile home/state/.know-verify-proj.meta)" "record=proj.md
fresh=2
suspect=3
unverifiable=4
manual=1
head=$(git -C "$XNH/$XP" rev-parse HEAD)
ran=2026-01-01T00:00:00Z" "8: the stamp"
xok verify --home @H/home --repo @H/$XP/sub
assert_contains "$(xout)" "SUSPECT - fact keep is stable | src: file:file.txt:1 | at: $XS 2026-01-01 | by: v1  (file.txt no longer exists)" "8 (W5, at parity): a subdirectory repo misgrades"
xboth sh -c 'printf "%s\n" "- fact one | src: file:f.txt:1 | at: 1111111111111111111111111111111111111111 2026-01-01 | by: u1" >"$0"' @H/home/records/repo-knowledge/unborn.md
xboth git init -q -b main @H/out/unborn
xok verify --home @H/home --repo @H/out/unborn
assert_contains "$(xfile home/state/.know-verify-unborn.meta)" "head=HEAD
-
ran=" "8 (W9, at parity): an unborn repo's head is rev-parse's stdout and the fallback"
xboth xrepo out/broke
xboth sh -c 't="$(git -C "$0" rev-parse "HEAD^{tree}")"; rm -f "$0/.git/objects/$(printf %s "$t" | cut -c1-2)/$(printf %s "$t" | cut -c3-)"' @H/out/broke
XSB="$(git -C "$XNH/out/broke" rev-parse HEAD)"
xboth sh -c 'printf "%s\n" "- fact broke | src: file:file.txt:1 | at: $1 2026-01-01 | by: b1" >"$0"' @H/home/records/repo-knowledge/broke.md "$XSB"
xsame verify --home @H/home --repo @H/out/broke
assert_contains "$(xout)" "UNVERIFIABLE - fact broke | src: file:file.txt:1 | at: $XSB 2026-01-01 | by: b1  (cannot compare file.txt against ${XSB:0:12})" "8: a diff that errors is UNVERIFIABLE"
if [ "$XROOTED" = 0 ]; then
  xboth chmod 000 @H/$XREC
  xpair "${XV[@]}"
  xsame_rc_out verify; xsame_world verify
  assert_eq "$XN_RC:$(xerr)" "0:" "8 (W9, at parity; TOOL-OWN STDERR, named): an unreadable record verifies nothing and exits 0"
  assert_contains "$(xoerr)" "awk: can't open file @H/$XREC" "8: the original printed awk's lines"
  assert_contains "$(xfile home/state/.know-verify-proj.meta)" "fresh=0
suspect=0
unverifiable=0
manual=0" "8 (W9): ...and stamped zeros"
  xboth chmod 644 @H/$XREC
fi
xboth sh -c 'printf victim >"$0/victim"' @H
XPLANT=home/state/.know-verify-proj.meta.tmp
xpair "${XV[@]}"
XPLANT=""
xsame_rc_out verify
assert_eq "$XN_RC:$(xerr)" "0:" "8 (EXCLUSIVE TEMPS, named): a link at the stamp's temp"
assert_eq "$(cat "$XNH/victim")" "victim" "8: the port never writes through it"
assert_contains "$(cat "$XOH/victim")" "record=proj.md" "8: the original wrote the stamp into the link's target..."
[ -L "$XOH/home/state/.know-verify-proj.meta" ] && [ ! -L "$XNH/home/state/.know-verify-proj.meta" ] || fail "8: ...and left the stamp a link, where the port's is a file"

# 9. scope-proposal and scope-install: the draft's refusals in code order,
#    the id (given, the default from date and the pid, `..`, `.`, a
#    collision), --replace, --retire with and without a live scope, the
#    overlap notes, a trailing comma (W6, at parity: the installed map then
#    refuses through the bash reader), an empty first line (bash's unbound
#    array, exit 1), a newline in --apps (W18, at parity: a second physical
#    line), a relative --repo (W15); the install's refusals, the conflict,
#    `.prev` kept and absent, the receipts, the installed record's mode (W7,
#    named: the port keeps it).
xboth xstd
XSP=(scope-proposal --home @H/home --repo @H/$XP --family s1 --src-file apps/a/main.ts:1)
XSI_=(--home @H/home --repo @H/$XP)
xrefuse "ERROR: entry rejected: no scope named - pass --scope <name>" "${XSP[@]}" --apps a
xrefuse "ERROR: entry rejected: orchid@x is not addressable as a yaml path segment (--scope must match [A-Za-z0-9_-])" "${XSP[@]}" --scope 'orchid@x' --apps a
xrefuse "ERROR: entry rejected: a retirement records WHY - pass --why <text>" "${XSP[@]}" --scope gw --retire
xrefuse "ERROR: entry rejected: --why must be a single line (no newline or carriage return)" "${XSP[@]}" --scope gw --retire --why $'a\rb'
xrefuse "ERROR: entry rejected: --retire removes a scope from the list; it takes no --apps" "${XSP[@]}" --scope gw --retire --why w --apps x
xrefuse "ERROR: entry rejected: a scope with no members - pass --apps <app>,<app>" "${XSP[@]}" --scope gw
xrefuse "ERROR: entry rejected: a scope with no members - pass --apps <app>,<app>" "${XSP[@]}" --scope gw --apps '  '
xrefuse "ERROR: entry rejected: b@c is not addressable as a yaml path segment (--apps must match [A-Za-z0-9_-])" "${XSP[@]}" --scope gw --apps 'a, b@c'
xrefuse "ERROR: entry rejected:  is not addressable as a yaml path segment (--apps must match [A-Za-z0-9_-])" "${XSP[@]}" --scope gw --apps ','
xrefuse "ERROR: entry rejected:  is not addressable as a yaml path segment (--apps must match [A-Za-z0-9_-])" "${XSP[@]}" --scope gw --apps 'a,,b'
xpair "${XSP[@]}" --scope gw --apps $'\nx'
xsame_rc_out scope-proposal; xsame_world scope-proposal
assert_eq "$XN_RC:$(xerr)" "1:" "9 (SHELL-OWN STDERR, named): an --apps whose first line is empty ends the run 1"
assert_contains "$(xoerr)" "app_list[@]: unbound variable" "9: the original's line is bash's own"
xrefuse "ERROR: entry rejected: no provenance - pass --src-file <path>:<line> or --src-cmd <command>" scope-proposal --home @H/home --repo @H/$XP --family s1 --scope gw --apps a
xrefuse "ERROR: invalid proposal id: a/b" "${XSP[@]}" --scope gw --apps a --id a/b
xrefuse "ERROR: scope-proposal: id already exists: .." "${XSP[@]}" --scope gw --apps a --id ..
xrefuse "ERROR: scope-proposal: id already exists: ." "${XSP[@]}" --scope gw --apps a --id .
xok "${XSP[@]}" --scope orchid --apps 'orchid-service, orchid-worker' --id p1
assert_eq "$(xout)" "proposal_id: p1
proposal written:
  @H/$XP/.crew/knowledge-proposals/p1/proposal.patch
  @H/$XP/.crew/knowledge-proposals/p1/proposed.md
target: @H/$XREC
base_sha256: e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
install (CHIEF, after review - never the drafting agent): ROOT/bin/ac-know.sh scope-install p1 --home @H/home --repo @H/$XP" "9: the draft's receipt"
xrefuse "ERROR: scope-proposal: id already exists: p1" "${XSP[@]}" --scope cedar --apps c --id p1
xrefuse "ERROR: scope-install: no staged proposal p9 at @H/$XP/.crew/knowledge-proposals/p9" scope-install p9 "${XSI_[@]}"
xinstall p1 "${XSI_[@]}"
assert_eq "$(xout)" "installed proposal p1: @H/$XP/.crew/knowledge-proposals/p1/proposed.md -> @H/$XREC
receipt (post to the family room): KNOWLEDGE-INSTALLED: @H/$XREC sha256=$(shasum -a 256 <"$XNH/$XREC" | cut -d' ' -f1) proposal=p1 - drafted by the task agent, reviewed + installed by the chief; captain veto: restore (no previous record)" "9: the install's receipt, no previous record"
xrefuse "ERROR: entry rejected: scope orchid is already live - pass --replace to supersede it:
- scope orchid = orchid-service, orchid-worker | src: file:apps/a/main.ts:1 | at: $XS 2026-01-01 | by: s1" "${XSP[@]}" --scope orchid --apps x
xok "${XSP[@]}" --scope orchid --apps 'orchid-service,orchid-worker,orchid-cron' --replace --id p2
xok "${XSP[@]}" --scope cedar --apps cedar-service --id race-a
xsame "${XSP[@]}" --scope shared --apps 'orchid-worker,orchid-service,cedar-service' --id race-b
assert_eq "$XN_RC:$(xerr)" "0:note: orchid-worker is also live in scope orchid
note: orchid-service is also live in scope orchid" "9: an overlap is a note, never a refusal"
xinstall race-a "${XSI_[@]}"
assert_contains "$(xout)" "(previous kept at @H/$XREC.prev)" "9: .prev is the veto net"
xrefuse "ERROR: scope-install: proposal race-b conflicts with a newer installed record (base=$(cat "$XNH/$XP/.crew/knowledge-proposals/race-b/base.sha256") current=$(shasum -a 256 <"$XNH/$XREC" | cut -d' ' -f1)); re-draft it" scope-install race-b "${XSI_[@]}"
xrefuse "ERROR: scope-install: proposal p2 conflicts with a newer installed record (base=$(cat "$XNH/$XP/.crew/knowledge-proposals/p2/base.sha256") current=$(shasum -a 256 <"$XNH/$XREC" | cut -d' ' -f1)); re-draft it" scope-install p2 "${XSI_[@]}"
xrefuse "ERROR: entry rejected: no live entry for scope ghost - nothing to retire" "${XSP[@]}" --retire --scope ghost --why gone
xok "${XSP[@]}" --retire --scope cedar --why 'cedar moved to its own repo' --id p3
xinstall p3 "${XSI_[@]}"
xboth mkdir -p @H/$XP/.crew/knowledge-proposals/wrong @H/$XP/.crew/knowledge-proposals/nobase
xboth xput $XP/.crew/knowledge-proposals/wrong/proposed.md 'x'
xboth xput $XP/.crew/knowledge-proposals/wrong/project 'other
'
xboth xput $XP/.crew/knowledge-proposals/nobase/proposed.md 'x'
xboth xput $XP/.crew/knowledge-proposals/nobase/project 'proj

'
xrefuse "ERROR: scope-install: proposal wrong does not target project proj" scope-install wrong "${XSI_[@]}"
xrefuse "ERROR: scope-install: proposal nobase has no base hash" scope-install nobase "${XSI_[@]}"
xok "${XSP[@]}" --scope orchard --apps 'a,' --id w6
assert_contains "$(xfile $XP/.crew/knowledge-proposals/w6/proposed.md)" "- scope orchard = a,  | src: " "9 (W6, at parity): a trailing comma is written"
xinstall w6 "${XSI_[@]}"
for xh in "$XOH" "$XNH"; do
  rc=0; AC_HOME="$xh/home" bash -c ". '$BIN/ac-lib.sh'; ac_knowledge_scopes '$xh/$XP'" >/dev/null 2>&1 || rc=$?
  assert_eq "$rc" 2 "9 (W6): the installed map refuses through the bash reader on both sides"
done
xok "${XSP[@]}" --scope forged --apps $'z\nb-x' --id w18
assert_contains "$(xfile $XP/.crew/knowledge-proposals/w18/proposed.md)" "- scope forged = z
b-x | src: " "9 (W18, at parity): a newline in --apps past its first line writes a second physical line"
xsame "${XSP[@]}" --scope dflt --apps d
assert_eq "$XN_RC" 0 "9: the default id"
assert_contains "$(xout)" "proposal_id: 20260101-000000-PID" "9: the default id is date's local stamp and the pid"
xboth sh -c 'rm -rf "$0"/.crew/knowledge-proposals/20260101-000000-*' @H/$XP
XCWD=$XP
xok scope-proposal --home @H/home --repo . --family s1 --src-file file.txt:1 --scope rel --apps r --id w15
assert_contains "$(xout)" "  ./.crew/knowledge-proposals/w15/proposal.patch" "9 (W15, at parity): a relative repo is echoed as given"
assert_contains "$(xout)" "scope-install w15 --home @H/home --repo ." "9 (W15): ...in the install line too"
xinstall w15 --home @H/home --repo .
XCWD=cwd
xok "${XSP[@]}" --scope mode --apps m --id w7
xboth chmod 640 @H/$XREC
xpair scope-install w7 "${XSI_[@]}"
xsame_rc_out scope-install; xsame_err scope-install
assert_eq "$(ls -l "$XNH/$XREC" | cut -c1-10):$(ls -l "$XOH/$XREC" | cut -c1-10)" "-rw-r-----:-rw-------" "9 (W7, named): the port keeps the record's mode where the original left it 0600"
assert_eq "$(ls -l "$XNH/$XREC.prev" | cut -c1-10):$(ls -l "$XOH/$XREC.prev" | cut -c1-10)" "-rw-r--r--:-rw-r--r--" "9: .prev is cp's, the same either way"
xboth chmod 644 @H/$XREC
xsame_world scope-install

# 10. locale and bytes: a byte that is no UTF-8 in the live section, the
#     superseded section and a scene (W1, named: the port reads bytes where
#     the original's awk aborted under en_US.UTF-8 - identical under C); a
#     non-ASCII --fact; a latin1 --fact (BYTES, named: argv arrives
#     decoded); --family Bad and café (W11, named: refused per the text under
#     any locale), the other brackets; W3 reproduced - the byte budget and
#     the 60-character quote count characters under UTF-8, bytes under C; W2
#     (named: ties in BYTE order, where the original's sort collated); the
#     dash word with a no-break space; awk's tolower over U+212A (named).
xboth xstd
XL1="- fact caf"$'\xe9'" latin1 entry under any locale | src: file:file.txt:1 | at: $XS 2026-01-01 | by: b1"
xboth xrecord "- fact a plain entry before the byte | src: file:file.txt:1 | at: $XS 2026-01-01 | by: b1
$XL1
- fact a plain entry after the byte | src: file:file.txt:1 | at: $XS 2026-01-01 | by: b1
"
xok add --home @H/home --repo @H/$XP --family b2 --src-file file.txt:1 --fact 'under C the byte is carried whole'
xok cite --home @H/home --repo @H/$XP --quote 'latin1 entry'
xok recall --home @H/home --repo @H/$XP 'latin1 entry locale'
xok verify --home @H/home --repo @H/$XP
XLC=en_US.UTF-8
xpair add --home @H/home --repo @H/$XP --family b2 --src-file file.txt:1 --new --fact 'under UTF-8 the port carries it too'
assert_eq "$XN_RC:$(xout):$(xerr)" "0:recorded in @H/$XREC:" "10 (W1, named): the port writes past the byte"
assert_eq "$XO_RC:$(xoout)" "2:" "10: the original's awk aborted..."
assert_contains "$(xoerr)" "towc: multibyte conversion failure" "10: ...in towc"
[ -d "$XOH/$XREC.lock" ] || fail "10 (W1): ...leaving its lock"
cmp -s "$XNH/$XREC" "$XOH/$XREC" && fail "10 (W1): the port's record moved on"
xboth rm -rf @H/$XREC.lock @H/tmp
xboth mkdir @H/tmp
xpair recall --home @H/home --repo @H/$XP 'latin1 entry locale'
assert_eq "$XN_RC:$(xerr)" "0:" "10 (W1, named): recall reads past the byte"
assert_contains "$(xout)" "latin1 entry under any locale" "10: ...and offers the entry"
assert_eq "$XO_RC:$(xoout)" "2:" "10: the original's recall died with nothing printed"
xboth sh -c 'rm -f "$0"/tmp/*' @H
xpair verify --home @H/home --repo @H/$XP
assert_eq "$XN_RC:$(xerr)" "0:" "10 (W1, named): verify grades every entry"
assert_contains "$(xfile home/state/.know-verify-proj.meta)" "fresh=5" "10: ...all five"
assert_contains "$(xnorm "$XOH/home/state/.know-verify-proj.meta" "$XOH" 0)" "fresh=1" "10: the original stamped only the entries before the byte"
XLC=C
xboth xstd
xboth xput home/records/scenes/latin.md "# Scene: latin
META: heat=2
summary: a latin1 scene caf"$'\xe9'" beacon

beacon watcher caf"$'\xe9'"
"
xok recall --home @H/home --repo @H/$XP 'beacon watcher'
XLC=en_US.UTF-8
xpair recall --home @H/home --repo @H/$XP 'beacon watcher'
assert_eq "$XN_RC:$(xerr)" "0:" "10 (W1, named): a latin1 scene is read as bytes"
assert_contains "$(xout)" "  latin  (hits 2, heat 2)" "10: ...and offered"
assert_eq "$XO_RC" 2 "10: the original's awk aborted on it"
xboth rm -rf @H/home/records/scenes @H/tmp
xboth mkdir @H/tmp
xok add --home @H/home --repo @H/$XP --family u1 --src-file file.txt:1 --fact 'unicode budget probe a é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é é'
xok add --home @H/home --repo @H/$XP --family u1 --src-file file.txt:1 --new --fact 'unicode budget probe b plain'
xok recall --home @H/home --repo @H/$XP 'unicode budget probe' --bytes 200
assert_contains "$(xout)" "-- 0 scene(s), 2 fact(s) shown (all hits) --" "10 (W3, reproduced): under UTF-8 the budget counts characters"
assert_contains "$(xout)" "--quote 'unicode budget probe a é é é é é é é é é é é é é é é é é é é'" "10 (W3): ...and the quote cuts at 60 characters"
XLC=C
xok recall --home @H/home --repo @H/$XP 'unicode budget probe' --bytes 200
assert_contains "$(xout)" "-- 0 scene(s), 1 fact(s) shown; TRUNCATED at --max 8 / --bytes 200 (2 fact hits total) --" "10 (W3): under C it counts bytes"
assert_contains "$(xout)" "--quote 'unicode budget probe a é é é é é é é é é é é é "$'\xc3'"'" "10 (W3): ...and the quote ends mid-sequence"
xpair add --home @H/home --repo @H/$XP --family u1 --src-file file.txt:1 --new --fact "caf"$'\xe9'" from argv"
xsame_rc_out add; xsame_err add
assert_contains "$(xfile "$XREC")" "- fact caf"$'\xef\xbf\xbd'" from argv | src:" "10 (BYTES, named): argv arrives decoded"
assert_contains "$(xnorm "$XOH/$XREC" "$XOH" 0)" "- fact caf"$'\xe9'" from argv | src:" "10: the original wrote the byte"
xboth xstd
xrefuse "ERROR: entry rejected: --family must match [a-z0-9-] (got 'Bad')" add --home @H/home --repo @H/$XP --family Bad --src-file file.txt:1 --new --fact x
XLC=en_US.UTF-8
for xf in Bad 'café'; do
  xpair add --home @H/home --repo @H/$XP --family "$xf" --src-file file.txt:1 --new --fact "W11 $xf"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: entry rejected: --family must match [a-z0-9-] (got '$xf')" "10 (W11, named): $xf is refused per the text"
  assert_eq "$XO_RC" 0 "10: the original's bracket took $xf under UTF-8"
  assert_contains "$(xnorm "$XOH/$XREC" "$XOH" 0)" "| by: $xf" "10: ...and wrote it"
done
xpair scope-proposal --home @H/home --repo @H/$XP --family s1 --src-file file.txt:1 --scope 'Écl' --apps a --id w11
assert_eq "$XN_RC:$(xerr)" "1:ERROR: entry rejected: Écl is not addressable as a yaml path segment (--scope must match [A-Za-z0-9_-])" "10 (W11, named): --scope per the text"
assert_eq "$XO_RC" 0 "10: the original's bracket took it under UTF-8"
xboth xstd
xpair recall --home @H/home --repo @H/$XP $'-x\xc2\xa0y'
xsame_rc_out recall; xsame_err recall
assert_eq "$XN_RC" 0 "10: under UTF-8 a no-break space makes a dash word a question"
xok recall --home @H/home --repo @H/$XP 'zebra tiebreak entry'
XLC=C
xrefuse "ERROR: unknown flag: -x"$'\xc2\xa0'"y (a question word that starts with - goes after --)" recall --home @H/home --repo @H/$XP $'-x\xc2\xa0y'
xboth xstd
xboth xrecord "- fact Zeta zebra tiebreak entry | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r5
- fact alpha zebra tiebreak entry | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r6
- fact the K"$'\xe2\x84\xaa'"ELVIN sign folds | src: file:file.txt:1 | at: $XS 2026-01-01 | by: r7
"
XLC=en_US.UTF-8
xpair recall --home @H/home --repo @H/$XP 'zebra tiebreak' --max 1
assert_eq "$XN_RC:$(xerr)" "0:" "10 (W2, named)"
assert_contains "$(xout)" "- fact Zeta zebra tiebreak entry" "10 (W2, named): the port breaks a tie at the cut in byte order"
assert_contains "$(xoout)" "- fact alpha zebra tiebreak entry" "10 (W2): the original's sort collated, a different shown set"
xpair recall --home @H/home --repo @H/$XP 'kkelvin'
assert_contains "$(xout)" "no hit in any layer" "10 (TOLOWER, named): the port folds ASCII only"
assert_contains "$(xoout)" "the K"$'\xe2\x84\xaa'"ELVIN sign folds" "10: the original's tolower folded U+212A to k"
XLC=C

# 11. the brief's contract: the baked lines run from a pool worktree and a
#     subdirectory of it, --repo its toplevel; the KNOWLEDGE-GAP and repo
#     fact hints' add line filled in; a home path with a space, which the
#     brief bakes unquoted - the split argv.
xboth xstd
xboth git -C @H/$XP worktree add -q --detach @H/$XP/.crew/worktrees/1
XCWD=$XP/.crew/worktrees/1/sub
xok recall "your question - subject/mechanism/terms" --home @H/home --repo @H/$XP/.crew/worktrees/1
xok verify --home @H/home --repo @H/$XP/.crew/worktrees/1
xok add --home @H/home --repo @H/$XP/.crew/worktrees/1 --family wt1 --src-file sub/s.txt:1 --fact 'a fact recorded from a pool worktree binds the worktree'
assert_contains "$(xout)" "recorded in @H/$XREC" "11: a pool worktree resolves its main repo's record"
xok verify --home @H/home --repo @H/$XP/.crew/worktrees/1
XCWD=cwd
xok add --home @H/home --repo @H/$XP --family solo-1 --src-file file.txt:1 --fact '<verified fact>'
xboth mkdir -p '@H/my home'
xrefuse "ERROR: unknown flag: home (ac-know.sh add writes facts; the scope map is not writable here)" add --home @H/my home --repo @H/$XP --family f1 --src-file file.txt:1 --fact x
xrefuse "ERROR: unknown flag: home" verify --home @H/my home --repo @H/$XP
xrefuse "ERROR: --home is not a readable directory: @H/my" recall 'a question' --home @H/my home --repo @H/$XP
xok recall 'a question' --home '@H/my home' --repo @H/$XP

# 12. the record is fleet memory: every write verb on a large real-shaped
#     record (synthetic - 848 live and 76 superseded entries, heat on some,
#     cmd: provenance, non-ASCII, backslashes, apostrophes, a 4 KB line; or a
#     real one when XKNOW_RECORD names it) round-trips the whole file byte
#     for byte except the intended change; then a link planted at the
#     record's temp (EXCLUSIVE TEMPS, named).
xboth xstd
if [ -n "${XKNOW_RECORD:-}" ]; then
  xboth mkdir -p @H/home/records/repo-knowledge
  xboth cp "$XKNOW_RECORD" @H/$XREC
  xboth chmod 644 @H/$XREC
else
  awk -v sha="$XS" -v b1="$XBOILER1" -v b2="$XBOILER2" 'BEGIN {
    split("alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo sierra tango uniform victor whiskey xray yankee zulu", w, " ")
    printf "# Repo knowledge: agent-crew\n\n%s\n\n", b1
    for (i = 1; i <= 924; i++) {
      if (i == 849) printf "\n## Superseded\n\n%s\n\n", b2
      s = sprintf("entry%04d %s%d %s%d %s%d", i, w[i % 26 + 1], i, w[(i * 7) % 26 + 1], i * 3, w[(i * 11) % 26 + 1], i * 5)
      if (i % 97 == 0) s = s " carries \\d+ and a chief'"'"'s apostrophe"
      if (i % 151 == 0) s = s " \342\200\224 a dash \342\206\222 an arrow caf\303\251"
      if (i == 400) { pad = ""; for (j = 0; j < 400; j++) pad = pad " padding"; s = s pad }
      src = (i % 65 == 0) ? "cmd:ls *.txt" : "file:file.txt:1"
      heat = (i % 13 == 0) ? sprintf(" | heat: %d", i % 7 + 1) : ""
      kind = (i % 211 == 0) ? "fact retired: " : "fact "
      printf "- %s%s | src: %s | at: %s 2026-01-%02d%s | by: fam-%d\n", kind, s, src, sha, i % 28 + 1, heat, i % 40
    }
  }' >"$TMP/xbig.md"
  xboth mkdir -p @H/home/records/repo-knowledge
  xboth cp "$TMP/xbig.md" @H/$XREC
fi
XB=(--home @H/home --repo @H/$XP)
xok add "${XB[@]}" --family big1 --src-file file.txt:1 --fact 'the needle subject quartz marigold ferrous lanthanum is fresh'
xok add "${XB[@]}" --family big1 --src-file three.txt:3 --new --fact 'a declared distinct needle subject quartz marigold ferrous lanthanum'
xok add "${XB[@]}" --family big2 --src-file file.txt:1 --supersede 'quartz marigold ferrous lanthanum is fresh' --fact 'the needle subject corrected in one write'
xok cite "${XB[@]}" --quote 'corrected in one write'
xok cite "${XB[@]}" --quote 'corrected in one write' --by big2
xok retire "${XB[@]}" --family big3 --src-cmd 'grep -c needle' --quote 'declared distinct needle' --why 'retired on the large record'
xok scope-proposal "${XB[@]}" --family big4 --src-file apps/a/main.ts:1 --scope bigscope --apps big-a,big-b --id big
xinstall big "${XB[@]}"
xok add "${XB[@]}" --family big5 --src-file file.txt:1 --new --fact 'a write after the install restores nothing it should not'
xboth sh -c 'printf victim >"$0/victim"' @H
XPLANT=$XREC.tmp
xpair add "${XB[@]}" --family big6 --src-file file.txt:1 --new --fact 'a link planted at the temp'
XPLANT=""
xsame_rc_out add; xsame_err add
assert_eq "$(cat "$XNH/victim")" "victim" "12 (EXCLUSIVE TEMPS, named): the port never writes through a planted temp"
assert_contains "$(cat "$XOH/victim")" "a link planted at the temp" "12: the original wrote the record into the link's target..."
[ -L "$XOH/$XREC" ] && [ -f "$XNH/$XREC" ] && [ ! -L "$XNH/$XREC" ] || fail "12: ...and left the record a link, where the port's is a file"

pass
