#!/usr/bin/env bash
# ac-pr-merge.test.sh - gh argv construction: no spurious empty argument when
# no `-- <gh flags>` tail is given, verbatim pass-through when a tail is
# (including flags containing spaces), the `-- --squash` / `-- --merge` method
# overrides, and the --repo/-R rejection. gh is stubbed with a logging fake.
# Plus the landing interlock (ac-lib.sh landing-ledger block): the PR's files
# (gh pr diff --name-only) warn on a <24h foreign-family overlap and land in
# the state/.landings ledger after the merge.
# Plus the qa.require_for_ship fail-closed gate: an unresolvable head (gh error
# OR empty) REFUSES the merge when qa is required, a drifted head refuses (the
# old sha's pass does not authorize the new head), the exact-sha pass proceeds,
# and a project that does not require qa still merges with an unresolved head.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
stub="$TMP/stubbin"
mkdir -p "$stub"
export GHLOG="$TMP/gh.log"
export GHPRFILES="$TMP/gh.prfiles"   # `gh pr diff --name-only` answer, if set
export GHVIEW=""                     # `gh pr view --json headRefOid` behavior
export GHVIEWSEQ="$TMP/gh.viewseq"   # when non-empty: successive headRefOid answers, one line each
export GHMERGESTATE="MERGED"         # `gh pr view --json state` read-back ("fail" = API error)
export GHMERGEFAIL=""                # 1 -> `gh pr merge` itself exits 1 ("already merged")

# Logging gh fake: one bracketed line per argv element, so an empty-string
# argument would show up as a bare `[]` line and break the exact match.
# (Each call truncates the log, so GHLOG always holds the LAST call's argv -
# the `pr merge` one the argv asserts care about.)
# `pr view` is driven by GHVIEW to inject the fail-closed cases: "fail" exits
# nonzero (gh API error), "empty" prints nothing (empty head sha), any other
# value is printed as the resolved head sha.
cat >"$stub/gh" <<'EOF'
#!/usr/bin/env bash
# Only `pr merge` argv is logged: the outcome read-back (`pr view --json
# state`) runs AFTER the merge and would otherwise overwrite the very argv
# the exact-match asserts exist for.
if [ "$1 $2" = "pr merge" ]; then
  : >"$GHLOG"
  for a in "$@"; do printf '[%s]\n' "$a" >>"$GHLOG"; done
  [ "${GHMERGEFAIL:-}" = 1 ] && { printf 'already merged\n' >&2; exit 1; }
fi
if [ "$1 $2" = "pr view" ]; then
  case "$*" in
    *headRefOid*)
      if [ -s "$GHVIEWSEQ" ]; then
        head -n 1 "$GHVIEWSEQ"; tail -n +2 "$GHVIEWSEQ" >"$GHVIEWSEQ.next"; mv "$GHVIEWSEQ.next" "$GHVIEWSEQ"; exit 0
      fi
      case "${GHVIEW:-}" in
        fail)  exit 1 ;;
        empty) exit 0 ;;
        *)     printf '%s\n' "$GHVIEW"; exit 0 ;;
      esac ;;
    *state*)
      case "${GHMERGESTATE:-MERGED}" in
        fail) exit 1 ;;
        *)    printf '%s\n' "${GHMERGESTATE:-MERGED}"; exit 0 ;;
      esac ;;
  esac
  exit 0
fi
[ "$1 $2" = "pr diff" ] && cat "$GHPRFILES" 2>/dev/null
exit 0
EOF
chmod +x "$stub/gh"

url=https://github.com/acme/widget/pull/7
printf 'backend=tmux\npr=%s\npr_head=abc111\n' "$url" >"$AC_HOME/state/t1.meta"

merge() { PATH="$stub:$PATH" "$BIN/ac-pr-merge.sh" "$@"; }
argv() { cat "$GHLOG"; }
v2_marker() {
  # v2_marker <path> <sha> <profile-key> [<scope> <app> <profile-sha>]
  {
    printf 'schema=agentcrew.qa-attestation/v2\noutcome=passed\n'
    printf 'run=test-run\ntask=test-task\ncompleted_at=2026-07-24T00:00:00Z\n'
    printf 'source_sha=%s\nprofile_key=%s\n' "$2" "$3"
    printf 'profile_sha256=%s\nconfig_sha256=config-hash\n' "${6:-profile-hash}"
    printf 'cases_passed=1\ncases_total=1\n'
    [ -z "${4:-}" ] || { printf 'scope=%s\n' "$4"; printf 'app=%s\n' "$5"; }
  } >"$1"
}

# No tail: exactly `pr merge <url> --squash`, no trailing empty argument.
out="$(merge t1 "$url")"
assert_contains "$out" "merged $url" "merge reported"
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--match-head-commit]\n[abc111]\n' "$url")" "no-tail argv"
assert_contains "$(cat "$AC_HOME/state/t1.meta")" "pr_merged=1" "meta records merge"
assert_contains "$(cat "$AC_HOME/state/t1.meta")" "pr=$url" "pr= rides the proven merge"

# The merge OUTCOME is proven, never assumed: a zero-exit merge call whose
# read-back does not answer MERGED (auto-merge queued on a protected branch,
# an unreadable API) must NOT set pr_merged - teardown trusts that field as
# landed proof, so an unproved 1 lets work be discarded before it landed.
# And an unproven attempt must not arm teardown's OTHER proof either: pr= is
# exactly --pr-ready's precondition, so only the ATTEMPT is recorded before
# the merge call (pr_attempt=) and pr= is written beside the proof alone -
# a bogus URL can neither land a task nor overwrite ac-pr-check's validated
# record.
printf 'backend=tmux\npr=%s\npr_head=abc111\n' "$url" >"$AC_HOME/state/t2.meta"
GHMERGESTATE=OPEN
out="$(merge t2 "$url" 2>&1)" && fail "an unproven merge outcome must exit non-zero" || true
assert_contains "$out" "NOT proven" "the refusal names the unproven outcome"
assert_contains "$out" "state=OPEN" "quoting the forge's own answer"
grep -q "pr_merged=1" "$AC_HOME/state/t2.meta" && fail "an unproven outcome must not mark pr_merged" || true
assert_eq "$(grep -c '^pr=' "$AC_HOME/state/t2.meta")" "1" "an unproven outcome leaves ac-pr-check's pr= record as it was"
assert_contains "$(cat "$AC_HOME/state/t2.meta")" "pr_attempt=$url" "the attempt is still bookkept"
GHMERGESTATE=fail
out="$(merge t2 "$url" 2>&1)" && fail "an unreadable outcome must exit non-zero" || true
assert_contains "$out" "state=unreadable" "an unreadable read-back stays unproven"
GHMERGESTATE=MERGED

# RECOVERY: a re-run after transient read-after-write lag hits a merge call
# that fails ("already merged") while the PR is provably MERGED - the proof
# must still be recordable, or no scripted invocation can ever set
# pr_merged=1 for that task.
printf 'backend=tmux\npr=%s\npr_head=abc111\n' "$url" >"$AC_HOME/state/t3.meta"
GHMERGEFAIL=1
out="$(GHVIEW=abc111 merge t3 "$url" 2>&1)" || fail "a failed merge call over a MERGED PR must record the proof, not die"
assert_contains "$out" "merged $url" "the proof is reported"
assert_contains "$out" "earlier attempt" "the recovery names what happened"
assert_contains "$(cat "$AC_HOME/state/t3.meta")" "pr_merged=1" "the proof reaches the meta"
assert_contains "$(cat "$AC_HOME/state/t3.meta")" "pr=$url" "pr= rides the proof"
assert_contains "$(cat "$AC_HOME/state/t3.meta")" "pr_merged_head=abc111" "the recovered proof carries the head the forge says merged"
# No pinned call of THIS run merged it, so the merged head is only what the
# forge reports: an unreadable one records no proof, and a PR merged by hand at
# a head other than the approved one is refused until that head is recorded.
printf 'backend=tmux\npr=%s\npr_head=abc111\n' "$url" >"$AC_HOME/state/t3b.meta"
out="$(GHVIEW="" merge t3b "$url" 2>&1)" && fail "a recovery whose merged head cannot be read must not record the proof"
grep -q "pr_merged=1" "$AC_HOME/state/t3b.meta" && fail "no proof without the merged head" || true
printf 'backend=tmux\npr=%s\npr_head=abc111\n' "$url" >"$AC_HOME/state/t3c.meta"
out="$(GHVIEW=def222 merge t3c "$url" 2>&1)" && fail "a PR merged at another head than the recorded one must not record the proof"
assert_contains "$out" "moved since it was recorded" "...it names the head that moved"
grep -q "pr_merged=1" "$AC_HOME/state/t3c.meta" && fail "no proof for a head nobody approved" || true
# ...and when the head could not be read BEFORE the call, the recovery's own
# read is the only check left: a merged head other than the approved one
# still records no proof.
printf 'backend=tmux\npr=%s\npr_head=abc111\n' "$url" >"$AC_HOME/state/t3d.meta"
printf '\ndef222\n' >"$GHVIEWSEQ"
out="$(merge t3d "$url" 2>&1)" && fail "a recovery that finds another head merged must not record the proof"
assert_contains "$out" "not the approved head" "...it names the unapproved merged head"
grep -q "pr_merged=1" "$AC_HOME/state/t3d.meta" && fail "no proof for a merged head nobody approved" || true
: >"$GHVIEWSEQ"
GHMERGEFAIL=""

# The captain approves THE PR as recorded: a recorded pr_head pins the merge
# even when qa is not required, so a push between the approval and the merge
# cannot land commits nobody approved; a head that already moved refuses before
# the call; and the merged head is recorded so teardown can bind to it.
printf 'backend=tmux\npr=%s\npr_head=abc111\n' "$url" >"$AC_HOME/state/t5.meta"
merge t5 "$url" >/dev/null || fail "a merge at the recorded head proceeds"
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--match-head-commit]\n[abc111]\n' "$url")" \
  "the recorded PR head pins the merge"
# No recorded head for THIS PR means no head was ever put to the captain, so
# nothing can bind the merge: refuse and name the record step.
printf 'backend=tmux\npr=https://github.com/acme/widget/pull/8\npr_head=abc111\n' >"$AC_HOME/state/t6.meta"
: >"$GHLOG"
out="$(merge t6 "$url" 2>&1)" && fail "another PR's recorded head must not authorize this merge"
assert_contains "$out" "ac-pr-check.sh t6 $url" "the refusal names the record step"
assert_eq "$(argv)" "" "an unrecorded head never reaches the merge call"
printf 'backend=tmux\n' >"$AC_HOME/state/t8.meta"
out="$(merge t8 "$url" 2>&1)" && fail "a merge with no recorded head must refuse"
grep -q "pr_merged=1" "$AC_HOME/state/t8.meta" && fail "a refused merge records no proof" || true
printf 'backend=tmux\npr=%s\npr_head=abc111\n' "$url" >"$AC_HOME/state/t7.meta"
: >"$GHLOG"
out="$(GHVIEW=def222 merge t7 "$url" 2>&1)" && fail "a PR head that moved since it was recorded must refuse"
assert_contains "$out" "moved since it was recorded" "the refusal names the moved head"
assert_eq "$(argv)" "" "a moved head never reaches the merge call"
merge t7 "$url" >/dev/null
assert_contains "$(cat "$AC_HOME/state/t7.meta")" "pr_merged_head=abc111" \
  "the merged head is the pinned head, recorded even when the forge answers no head"

# Tail passes through verbatim; a method flag in the tail is not doubled.
merge t1 "$url" -- --squash --admin >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--admin]\n[--match-head-commit]\n[abc111]\n' "$url")" "tail verbatim, --squash not doubled"

# The `-- --squash` workaround alone still yields a single --squash.
merge t1 "$url" -- --squash >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--match-head-commit]\n[abc111]\n' "$url")" "-- --squash workaround"

# `-- --merge` replaces the default method.
merge t1 "$url" -- --merge >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--merge]\n[--match-head-commit]\n[abc111]\n' "$url")" "-- --merge overrides method"

# A flag value containing a space survives quoting as one argv element.
merge t1 "$url" -- --subject "release: two words" >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--subject]\n[release: two words]\n[--match-head-commit]\n[abc111]\n' "$url")" "spaced flag stays one arg"

# --- W2: a tail not introduced by a literal `--` must REFUSE, not be dropped
# silently - the dropped words used to let `<id> <url> --merge --admin` merge
# with the default --squash instead of the merge it actually asked for.
: >"$GHLOG"
assert_fails_with "unrecognised tail" -- merge t1 "$url" --merge --admin
assert_eq "$(argv)" "" "an unrecognised tail never reaches the merge call"

# --- W3: a flag's VALUE must never be read as a merge-method flag - here
# `--subject` takes the literal text "--merge" as its VALUE, which must not
# be mistaken for a request to merge with --merge instead of --squash.
merge t1 "$url" -- --subject --merge >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--subject]\n[--merge]\n[--match-head-commit]\n[abc111]\n' "$url")" \
  "a --subject value spelled --merge must not drop --squash"

# --repo/-R overrides are still rejected.
assert_fails merge t1 "$url" -- --repo acme/other
assert_fails merge t1 "$url" -- -R acme/other

# Landing interlock: a <24h foreign-family ledger record on a PR file warns
# (merge still runs), and the merged files are recorded under t1's family.
ledger="$AC_HOME/state/.landings"
printf 'src/pay.go\n' >"$GHPRFILES"
printf '%s\tdrain-race\tsrc/pay.go\n' "$(($(date +%s) - 3600))" >"$ledger"
out="$(merge t1 "$url" 2>&1)"
assert_contains "$out" "LANDING-OVERLAP: src/pay.go" "warn names the overlapping PR file"
assert_contains "$out" "data/drain-race/room.md" "warn names the prior family's room"
assert_contains "$out" "merged $url" "warn-only: merge still ran"
grep -Eq "^[0-9]+	t1	src/pay.go$" "$ledger" || fail "merged PR file recorded to the ledger under t1"

# --- qa.require_for_ship fail-closed gate ------------------------------------
# A project whose merge-target config enforces qa.require_for_ship must never
# merge on an unresolvable head: the enforced decision is read WITHOUT a head,
# so a gh error or an empty head SHA REFUSES rather than silently skips.
: >"$GHPRFILES"   # no landing overlap noise for the qa cases

qarepo="$(make_repo qarepo)"
mkdir -p "$AC_HOME/projects"
cat >"$AC_HOME/projects/qarepo.yaml" <<'YAML'
qa:
  require_for_ship: true
YAML
head="$(git -C "$qarepo" rev-parse HEAD)"
printf 'backend=tmux\nproject_dir=%s\npr=%s\npr_head=%s\n' "$qarepo" "$url" "$head" >"$AC_HOME/state/q1.meta"

# (a) gh pr view API failure -> merge REFUSED (gate reached without a head).
GHVIEW=fail
out="$(merge q1 "$url" 2>&1)" && fail "gh failure must refuse the merge" || true
assert_contains "$out" "head SHA could not be resolved" "gh failure -> refused, gate not skipped"
grep -q "pr_merged=1" "$AC_HOME/state/q1.meta" && fail "gh failure must not mark the merge" || true

# (b) empty head SHA -> merge REFUSED.
GHVIEW=empty
out="$(merge q1 "$url" 2>&1)" && fail "empty head must refuse the merge" || true
assert_contains "$out" "head SHA could not be resolved" "empty head -> refused"

# (c) drifted head -> REFUSED: a pass recorded for the OLD sha does not
# authorize a head that changed since the qa run.
mkdir -p "$qarepo/.crew/qa/passed"
v2_marker "$qarepo/.crew/qa/passed/$head" "$head" qarepo # pass on the committed head
GHVIEW=0000000000000000000000000000000000000000          # gh reports a drifted head
out="$(merge q1 "$url" 2>&1)" && fail "drifted head must refuse the merge" || true
assert_contains "$out" "no passing crew-qa run recorded" "drift -> old sha's pass does not authorize the new head"

# (d) valid exact-SHA with a recorded pass -> merge proceeds.
GHVIEW="$head"
out="$(merge q1 "$url" 2>&1)"
assert_contains "$out" "merged $url" "exact-sha pass -> merge proceeds"
assert_contains "$(cat "$AC_HOME/state/q1.meta")" "pr_merged=1" "meta records the gated merge"
# The gate read the head BEFORE the merge; a push in between must not ride an
# attestation it never earned, so the merge is pinned to the gated sha.
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--match-head-commit]\n[%s]\n' "$url" "$head")" \
  "a qa-gated merge is pinned to the attested head"

# (e) a project that does NOT require qa still merges with an unresolved head.
noqarepo="$(make_repo noqarepo)"                          # no fleet-home config -> qa not enforced
printf 'backend=tmux\nproject_dir=%s\npr=%s\npr_head=abc111\n' "$noqarepo" "$url" >"$AC_HOME/state/q2.meta"
GHVIEW=fail
out="$(merge q2 "$url" 2>&1)"
assert_contains "$out" "merged $url" "qa not required -> unresolved head is no false refusal"

# --- the SCOPED merge gate, driven through the HELPER ------------------------
# The two-sided gate end to end: the entry hands it the project and the head,
# and it reads both the yaml's qa.scopes and the repo-knowledge record (the
# gate itself is src/lib-qa-gate.ts's qaGateOk; tests/ts/qa-gate.test.ts holds it to
# explicit answers arm by arm).
mkdir -p "$AC_HOME/records/repo-knowledge"
grepo2="$(make_repo scopedqarepo)"
ghead="$(git -C "$grepo2" rev-parse HEAD)"
printf 'backend=tmux\nproject_dir=%s\npr=%s\npr_head=%s\n' "$grepo2" "$url" "$ghead" >"$AC_HOME/state/g1.meta"
printf 'qa:\n  require_for_ship: true\n  scopes:\n    orchid:\n      seed: "true"\n' \
  >"$AC_HOME/projects/scopedqarepo.yaml"
mkdir -p "$grepo2/.crew/qa/passed"
: >"$grepo2/.crew/qa/passed/$ghead"
GHVIEW="$ghead"
# Half-migrated: yaml scoped, record silent -> the MISMATCH arm refuses,
# never the FLAT arm that would accept the bare marker sitting right there.
out="$(merge g1 "$url" 2>&1)" && fail "a half-migrated project must refuse the merge"
assert_contains "$out" "MODE MISMATCH" "the helper actually executed the two-sided gate"
# Declared, but the marker still names no scope+app (D14) -> refuse.
printf -- '- scope orchid = orchid-service | src: cmd:true | at: deadbeef 2026-07-21 | by: fam\n' \
  >"$AC_HOME/records/repo-knowledge/scopedqarepo.md"
out="$(merge g1 "$url" 2>&1)" && fail "a bare marker must not merge a scoped head"
assert_contains "$out" "bare sha-only marker IS on disk" "the bare marker is named, not silently missing"
# A scope+app-bearing marker merges it, surfacing the pairs.
v2_marker "$grepo2/.crew/qa/passed/$ghead.orchid.orchid-service" \
  "$ghead" scopedqarepo/orchid/orchid-service orchid orchid-service
out="$(merge g1 "$url" 2>&1)"
assert_contains "$out" "orchid/orchid-service" "the passing arm surfaces the proven pair"
assert_contains "$out" "merged $url" "the scoped merge proceeded"
rm -f "$AC_HOME/projects/scopedqarepo.yaml" "$AC_HOME/records/repo-knowledge/scopedqarepo.md"

# --- the required-profile MATRIX, driven through the SCRIPT ------------------
# Proves the caller forwards the task id so the manifest arm bites end-to-end:
# a task with two required profiles cannot merge after only one passes, and
# merges once both are present at the head.
mrepo="$(make_repo matrixqarepo)"
mhead="$(git -C "$mrepo" rev-parse HEAD)"
printf 'backend=tmux\nproject_dir=%s\npr=%s\npr_head=%s\n' "$mrepo" "$url" "$mhead" >"$AC_HOME/state/m1.meta"
printf 'qa:\n  require_for_ship: true\n' >"$AC_HOME/projects/matrixqarepo.yaml"
mkdir -p "$AC_HOME/data/m1/qa" "$mrepo/.crew/qa/passed"
printf '{"task":"m1","source_ref":"","required_profiles":[{"profile_key":"matrixqarepo/orchid/orchid-service"},{"profile_key":"matrixqarepo/cedar/cedar-service"}]}\n' \
  >"$AC_HOME/data/m1/qa/manifest.json"
mk_pass() {
  local scope="${1%%.*}" app="${1#*.}"
  v2_marker "$mrepo/.crew/qa/passed/$mhead.$1" "$mhead" \
    "matrixqarepo/$scope/$app" "$scope" "$app" "$2"
}
GHVIEW="$mhead"
mk_pass orchid.orchid-service aaaa
out="$(merge m1 "$url" 2>&1)" && fail "a required-profile manifest must refuse after only one profile passes"
assert_contains "$out" "no passing crew-qa attestation" "the matrix arm ran through the script"
assert_contains "$out" "cedar/cedar-service" "and names the unmet required profile"
grep -q "pr_merged=1" "$AC_HOME/state/m1.meta" && fail "the unmet matrix must not mark the merge" || true
mk_pass cedar.cedar-service bbbb
out="$(merge m1 "$url" 2>&1)"
assert_contains "$out" "required profile" "both present -> the matrix opens the gate"
assert_contains "$out" "merged $url" "the matrix-gated merge proceeded"
rm -f "$AC_HOME/projects/matrixqarepo.yaml"; rm -rf "$AC_HOME/data/m1"

# --- the KNOWLEDGE-GAP landing flag (AC15/AC16) -----------------------------
# Warn-only, and NOT behind the landed[] guard: `gh pr diff` failing into
# `|| true` is exactly a landing with an empty file list, and it owes its
# knowledge entry like any other. The merge still happens, unchanged.
GHVIEW=""
GHPRFILES="$TMP/none.files"                              # unresolvable file list
krepo="$(make_repo krepo)"
printf 'backend=tmux\nproject_dir=%s\npr=%s\npr_head=abc111\n' "$krepo" "$url" >"$AC_HOME/state/k1.meta"
out="$(merge k1 "$url" 2>&1)"
assert_contains "$out" "KNOWLEDGE-GAP: family k1" "an empty file list is still a landing that owes an entry"
assert_contains "$out" "krepo" "the flag names the project"
assert_contains "$out" "$AC_HOME/records/repo-knowledge/krepo.md" "the flag names the record path"
assert_contains "$out" "merged $url" "the flag is warn-only - the merge still happened"

# AC16: an entry attributable to this family silences it.
mkdir -p "$AC_HOME/records/repo-knowledge"
printf -- '- fact learned something | src: cmd:true | at: deadbeef 2026-07-21 | by: k1\n' \
  >"$AC_HOME/records/repo-knowledge/krepo.md"
out="$(merge k1 "$url" 2>&1)"
case "$out" in *KNOWLEDGE-GAP*) fail "a family with an entry must not be flagged" ;; esac
assert_contains "$out" "merged $url" "the silent landing still merged"

# --- the entry, row by row ----------------------------------------------------
# One side root ($DNH) holding a home whose project clones carry fixed-date
# commits; cwd the side root, stdin /dev/null, LC_ALL=C unless a row names a
# locale, PATH stubs for `gh` (every call logged as its argv, answers from D_*
# env and answer queues), `sleep` (logged into the same log, instant, exiting
# D_SLEEPRC) and `date` (one fixed instant). HOME in an argument, an env value
# or a seeded file is the side root, and the side root reads HOME, this
# checkout DISTRO and a temp's pid PID in what a run printed.
DNH="$TMP/pside-n"; H="$DNH"
DSTUBS="$TMP/pstubs"; mkdir -p "$DSTUBS"
cat >"$DSTUBS/gh" <<'STUB'
#!/bin/sh
{ printf 'gh'; printf ' [%s]' "$@"; printf '\n'; } >>"$D_LOG"
case "$1 $2" in
  "pr merge")
    [ -z "${D_MERGEOUT-}" ] || printf '%s\n' "$D_MERGEOUT"
    [ -z "${D_MERGEERR-}" ] || printf '%s\n' "$D_MERGEERR" >&2
    [ -z "${D_MERGEKILL-}" ] || kill -TERM $$
    exit "${D_MERGERC:-0}" ;;
  "pr diff") printf '%b' "${D_FILES-}"; exit "${D_DIFFRC:-0}" ;;
  "pr view")
    if [ "$5" = headRefOid ]; then q="${D_VIEWQ-}"; a="${D_VIEW-}"; else q="${D_STATEQ-}"; a="${D_STATE-MERGED}"; fi
    if [ -s "$q" ]; then head -n 1 "$q"; tail -n +2 "$q" >"$q.next"; mv "$q.next" "$q"; exit 0; fi
    [ "$a" != fail ] || exit 1
    [ -z "$a" ] || printf '%b\n' "$a"
    exit 0 ;;
esac
exit 1
STUB
cat >"$DSTUBS/sleep" <<'STUB'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$D_LOG"
exit "${D_SLEEPRC:-0}"
STUB
cat >"$DSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in *%s*) echo 1767225600 ;; *) echo 2026-01-01T00:00:00Z ;; esac
STUB
chmod +x "$DSTUBS/gh" "$DSTUBS/sleep" "$DSTUBS/date"
DNOW=1767225600
DFIXED=2026-01-01T00:00:00Z
DU=https://github.com/acme/widget/pull/7
DUSAGE='ERROR: usage: ac-pr-merge.sh <id> <pr-url> [-- <gh flags>]'
dput() {  # dput <path under the side root> <printf-format> - HOME in the format is the side root
  mkdir -p "$(dirname "$H/$1")"; printf -- "${2//HOME/$H}" >"$H/$1"
}
dmeta() { dput "home/state/$1.meta" "$2"; }
drepo() {  # drepo <name> - home/projects/<name>: one fixed-date commit on main, its qa markers dir ignored
  local r="$H/home/projects/$1"
  git init -q -b main "$r"; git -C "$r" config user.email test@test; git -C "$r" config user.name test
  printf 'hello\n' >"$r/file.txt"; git -C "$r" add -A
  GIT_AUTHOR_DATE=$DFIXED GIT_COMMITTER_DATE=$DFIXED git -C "$r" commit -qm init
  printf '/.crew/\n' >>"$r/.git/info/exclude"; mkdir -p "$r/.crew/qa/passed"
}
dsha() { git -C "$DNH/home/projects/$1" rev-parse HEAD; }
D_ENV=()
D_PATH=""
D_NRC=0
dgo() {  # dgo <exit> <args...> - the shim from the side root, its exit asserted; HOME in an arg or an env value is the side root
  local want="$1" x v; shift
  local a=() e=(LC_ALL=C "PATH=${D_PATH:-$DSTUBS:$PATH}" "D_LOG=$DNH/calls.log" "AC_HOME=$DNH/home")
  for x in ${D_ENV[@]+"${D_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$DNH}"); done
  for x in "$@"; do a+=("${x//HOME/$DNH}"); done
  : >"$DNH/calls.log"
  D_NRC=0
  (cd "$DNH" && env -u AC_HOME "${e[@]}" "$BIN/ac-pr-merge.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/n.raw" 2>"$TMP/n.err" || D_NRC=$?
  dnorm "$TMP/n.raw" >"$TMP/n.out"; dnorm "$TMP/n.err" >"$TMP/n.err2"
  assert_eq "$D_NRC" "$want" "exit for '$*'"
}
dnorm() { LC_ALL=C sed -e "s#$DNH#HOME#g" -e "s#$ROOT#DISTRO#g" -e 's#\.tmp\.[0-9][0-9]*#.tmp.PID#g' "$1"; }
dout() { cat "$TMP/n.out"; }
derr() { cat "$TMP/n.err2"; }
dcalls() { cat "$DNH/calls.log"; }
dmerge_call() { LC_ALL=C grep '^gh \[pr\] \[merge\]' "$DNH/calls.log" || true; }
dsleeps() { LC_ALL=C grep -c '^sleep 1$' "$DNH/calls.log" || true; }
dview() { printf 'gh [pr] [view] [%s] [--json] [headRefOid] [-q] [.headRefOid]' "$DU"; }
dstate() { printf 'gh [pr] [view] [%s] [--json] [state] [-q] [.state]' "$DU"; }
dpin() { printf 'gh [pr] [merge] [%s] %s[--match-head-commit] [%s]' "$DU" "$1" "${2:-abc111}"; }
dkgap() {  # dkgap <family> <repo> <name> - the KNOWLEDGE-GAP warn
  printf "WARN: KNOWLEDGE-GAP: family %s is landing on %s with no repo-knowledge entry -\nrecord what it learned (DISTRO/bin/ac-know.sh add --home HOME/home --repo %s --family %s --src-file <path>:<line> --fact '<what you learned>')\nor dismiss if it learned nothing about the codebase. Record: HOME/home/records/repo-knowledge/%s.md" "$1" "$3" "$2" "$1" "$3"
}
dseed() { mkdir -p "$H/home/state" "$H/home/projects"; }
dseed

# 1. the prelude, each refusal before any gh call: no gh on PATH (before the
#    usage), no args, one arg, an empty id, no meta (checked before the url), a
#    url the
#    glob refuses; the shapes it accepts (`*` spans `/`, anything may follow
#    the digit); an id naming a meta outside state/
DNOGH="$TMP/pnogh"; mkdir -p "$DNOGH"
ln -s "$(command -v bun)" "$DNOGH/bun"; ln -s "$DSTUBS/date" "$DNOGH/date"; ln -s "$DSTUBS/sleep" "$DNOGH/sleep"
D_PATH="$DNOGH:/usr/bin:/bin"
(PATH="$D_PATH"; command -v gh >/dev/null) && fail "1: the no-gh PATH must hold no gh"
dgo 1 t1 "$DU"; D_PATH=""
assert_eq "$(derr)" "ERROR: required tool not found: gh" "1: no gh on PATH"
D_PATH="$DNOGH:/usr/bin:/bin"; dgo 1; D_PATH=""
assert_eq "$(derr)" "ERROR: required tool not found: gh" "1: ...before the usage"
dgo 1; assert_eq "$(derr)" "$DUSAGE" "1: no args"
dgo 1 t1; assert_eq "$(derr)" "$DUSAGE" "1: one arg"
dgo 1 '' "$DU"; assert_eq "$(derr)" "$DUSAGE" "1: an empty id"
dgo 1 nosuch https://example.com/x; assert_eq "$(derr)" "ERROR: no crewmate meta for nosuch" "1: the meta before the url"
dmeta t1 "backend=tmux\npr=$DU\npr_head=abc111\n"
dgo 1 t1 https://github.com/a/pull/7
assert_eq "$(derr)" "ERROR: not a full GitHub PR URL: https://github.com/a/pull/7" "1: one owner segment"
dgo 1 t1 https://GitHub.com/acme/widget/pull/7
assert_eq "$(derr)" "ERROR: not a full GitHub PR URL: https://GitHub.com/acme/widget/pull/7" "1: the host's case"
assert_eq "$(dcalls)" "" "1: no gh call"
dgo 1 t1 https://github.com//b/pull/7
assert_contains "$(derr)" "ERROR: merge refused: no head is recorded for https://github.com//b/pull/7 on t1" "1: an empty owner passes the glob"
dgo 1 t1 https://github.com/acme/widget/pull/7x
assert_contains "$(derr)" "ERROR: merge refused: no head is recorded for https://github.com/acme/widget/pull/7x on t1" "1: anything may follow the digit"
DU3=https://github.com/a/b/c/pull/7
dmeta t1b "pr=$DU3\npr_head=abc111\n"
dgo 0 t1b "$DU3"; assert_eq "$(dout)" "merged $DU3" "1: \`*\` spans a slash"
dput home/x.meta "pr=$DU\npr_head=abc111\n"
dgo 0 ../x "$DU"; assert_eq "$(dout)" "merged $DU" "1: ../x names <home>/x.meta"
assert_contains "$(cat "$DNH/home/x.meta")" "pr_merged=1" "1: ...and writes the proof there"

# 2. the tail: none, a bare `--`, flags passed verbatim (a method flag not
#    doubled, one replacing --squash, a spaced value one element), the
#    --repo/-R refusals before any gh call
dmeta t2 "backend=tmux\npr=$DU\npr_head=abc111\n"
dgo 0 t2 "$DU"
assert_eq "$(dcalls)" "$(dview)
gh [pr] [diff] [$DU] [--name-only]
$(dpin '[--squash] ')
$(dstate)" "2: the call sequence, the merge pinned"
assert_eq "$(dout)" "merged $DU" "2: merged"
dgo 0 t2 "$DU" --; assert_eq "$(dmerge_call)" "$(dpin '[--squash] ')" "2: a bare --"
dgo 0 t2 "$DU" -- --squash --admin; assert_eq "$(dmerge_call)" "$(dpin '[--squash] [--admin] ')" "2: --squash not doubled"
dgo 0 t2 "$DU" -- --merge; assert_eq "$(dmerge_call)" "$(dpin '[--merge] ')" "2: --merge replaces --squash"
dgo 0 t2 "$DU" -- --rebase; assert_eq "$(dmerge_call)" "$(dpin '[--rebase] ')" "2: --rebase replaces --squash"
dgo 0 t2 "$DU" -- --subject "release: two words"
assert_eq "$(dmerge_call)" "$(dpin '[--squash] [--subject] [release: two words] ')" "2: a spaced value is one element"
for t in "--repo x" "--repo=x" "-R a/b"; do
  dgo 1 t2 "$DU" -- $t
  assert_eq "$(derr)" "ERROR: --repo/-R overrides are not allowed; the PR URL decides" "2: refused: $t"
  assert_eq "$(dcalls)" "" "2: no gh call: $t"
done

# 3. the head pin, refused before any gh call: pr_head missing, an empty
#    pr_head=, another PR's pr=, a pr= with a trailing space; the live head
#    equal (merges), moved (refused before the merge), unreadable (merges on
#    the record); a moved head cut at 12 characters - per character under a
#    UTF-8 locale, per byte under C
for m in "pr=$DU\n" "pr=$DU\npr_head=\n" "pr=https://github.com/acme/widget/pull/8\npr_head=abc111\n" "pr=$DU \npr_head=abc111\n"; do
  dmeta t3 "$m"
  dgo 1 t3 "$DU"
  assert_eq "$(derr)" "ERROR: merge refused: no head is recorded for $DU on t3, so no approved head can bind the merge - record it (bin/ac-pr-check.sh t3 $DU), have the captain approve that head, then merge" "3: refused: $m"
  assert_eq "$(dcalls)" "" "3: no gh call: $m"
done
dmeta t3 "pr=$DU\npr_head=abc111\n"
D_ENV=(D_VIEW=abc111); dgo 0 t3 "$DU"; D_ENV=()
assert_eq "$(dout)" "merged $DU" "3: the live head equal"
D_ENV=(D_VIEW=def222); dgo 1 t3 "$DU"; D_ENV=()
assert_eq "$(derr)" "ERROR: merge refused: the PR head moved since it was recorded (recorded abc111, now def222) - the approval covered the recorded head; re-record it (bin/ac-pr-check.sh t3 $DU) and ask again" "3: a moved head"
assert_eq "$(dcalls)" "$(dview)" "3: ...refused before the diff and the merge"
D_ENV=(D_VIEW=fail); dgo 0 t3 "$DU"; D_ENV=()
assert_eq "$(dout)" "merged $DU" "3: an unreadable live head merges on the record"
dmeta t3u "pr=$DU\npr_head=$(printf '\\303\\251%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13)\n"
D_ENV=(D_VIEW=def222 LC_ALL=en_US.UTF-8); dgo 1 t3u "$DU"; D_ENV=()
assert_contains "$(derr)" "(recorded $(printf '\303\251%.0s' 1 2 3 4 5 6 7 8 9 10 11 12), now def222)" "3: twelve characters under UTF-8"
D_ENV=(D_VIEW=def222); dgo 1 t3u "$DU"; D_ENV=()
assert_contains "$(derr)" "(recorded $(printf '\303\251%.0s' 1 2 3 4 5 6), now def222)" "3: twelve bytes under C"

# 4. the proof: OPEN on every read, the unproven status line, only the attempt bookkept; MERGED on the third
#    read (two sleeps); an unreadable state; `merged` in lower case; a sleep
#    that fails ends the run with its own status
dmeta t4 "pr=$DU\npr_head=abc111\n"
D_ENV=(D_STATE=OPEN); dgo 1 t4 "$DU"; D_ENV=()
assert_eq "$(derr)" "ERROR: merge NOT proven for $DU - gh pr merge exited 0 and the forge answered state=OPEN across 3 reads (auto-merge queued? protected branch? unreadable API?). pr= and pr_merged stay unset so teardown keeps refusing; re-check with: gh pr view $DU --json state, then re-run this command" "4: OPEN on every read"
assert_eq "$(cat "$DNH/home/state/t4.status")" "$DFIXED merge-unproven: $DU state=OPEN merge_rc=0" "4: the unproven status line"
assert_eq "$(cat "$DNH/home/state/t4.meta")" "pr=$DU
pr_head=abc111
pr_attempt=$DU" "4: only the attempt is bookkept"
dput stateq 'OPEN\nOPEN\nMERGED\n'
D_ENV=(D_STATEQ=HOME/stateq); dgo 0 t4 "$DU"; D_ENV=()
assert_eq "$(dsleeps)" 2 "4: MERGED on the third read - two sleeps"
assert_eq "$(dout)" "merged $DU" "4: ...merged"
D_ENV=(D_STATE=fail); dgo 1 t4 "$DU"; D_ENV=()
assert_contains "$(derr)" "state=unreadable across 3 reads" "4: an unreadable state"
D_ENV=(D_STATE=merged); dgo 1 t4 "$DU"; D_ENV=()
assert_contains "$(derr)" "state=merged across 3 reads" "4: lower-case merged is no proof"
D_ENV=(D_STATE=OPEN D_SLEEPRC=3); dgo 3 t4 "$DU"; D_ENV=()
assert_eq "$(tail -n 2 "$DNH/calls.log")" "$(dstate)
sleep 1" "4: ...after the first read"

# 5. a merge call that fails (`already merged`), judged by a FRESH head read:
#    the approved head (the note, the proof recorded, pr= moved last), no head,
#    another head - the queue answers "" to the pin's read and def222 to the
#    recovery's, the order of the two reads frozen; gh's own stdout and
#    stderr pass through
dmeta t5 "pr=$DU\npr_head=abc111\n"
D_ENV=(D_MERGERC=1 "D_MERGEERR=already merged" "D_MERGEOUT=gh says hi" D_VIEW=abc111); dgo 0 t5 "$DU"; D_ENV=()
assert_eq "$(dout)" "gh says hi
note: the merge call failed (exit 1) but the PR is MERGED - an earlier attempt landed; recording the proof.
merged $DU" "5: the recovery records the proof"
assert_eq "$(derr)" "already merged" "5: gh's stderr passes"
assert_eq "$(cat "$DNH/home/state/t5.meta")" "pr_head=abc111
pr_attempt=$DU
pr=$DU
pr_merged_head=abc111
pr_merged=1" "5: the proof, pr= moved to the end"
D_ENV=(D_MERGERC=1 D_VIEW=); dgo 1 t5 "$DU"; D_ENV=()
assert_eq "$(derr)" "ERROR: the PR is MERGED, but no pinned call of this run merged it and the forge answered no merged head - pr_merged stays unset so teardown keeps refusing; re-run once gh pr view $DU --json headRefOid answers" "5: no merged head"
assert_eq "$(tail -n 1 "$DNH/home/state/t5.status")" "$DFIXED merge-unproven: $DU is MERGED but its merged head is unreadable" "5: its status line"
dmeta t5b "pr=$DU\npr_head=abc111\n"
dput viewq '\ndef222\n'
D_ENV=(D_MERGERC=1 D_VIEWQ=HOME/viewq); dgo 1 t5b "$DU"; D_ENV=()
assert_eq "$(derr)" "ERROR: the PR is MERGED at def222, not the approved head abc111 - pr_merged stays unset; re-record the merged head (bin/ac-pr-check.sh t5b $DU), get it approved, then re-run" "5: another merged head"
assert_eq "$(tail -n 1 "$DNH/home/state/t5b.status")" "$DFIXED merge-unproven: $DU merged at def222, not the approved abc111" "5: its status line"
assert_eq "$(dcalls)" "$(dview)
gh [pr] [diff] [$DU] [--name-only]
$(dpin '[--squash] ')
$(dstate)
$(dview)" "5: the head read before the merge and again after it"

# 6. a merge call a signal ends is 128+signal, judged like any failure
dmeta t6 "pr=$DU\npr_head=abc111\n"
D_ENV=(D_MERGEKILL=1 D_STATE=OPEN); dgo 1 t6 "$DU"; D_ENV=()
assert_contains "$(derr)" "gh pr merge exited 143 and the forge answered state=OPEN" "6: 143, unproven"
D_ENV=(D_MERGEKILL=1 D_VIEW=abc111); dgo 0 t6 "$DU"; D_ENV=()
assert_eq "$(sed -n 1p "$TMP/n.out")" "note: the merge call failed (exit 143) but the PR is MERGED - an earlier attempt landed; recording the proof." "6: 143, recovered"

# 7. the ledger: a TAB in a path is kept and the unterminated last line of
#    `gh pr diff` is dropped; a diff that fails after printing keeps what it
#    printed; a <24h record of another family warns with its live or ARCHIVED
#    room while the own family, a 25 h record and a >7 d one (pruned) stay
#    silent; an unreadable ledger ends the run 2 before the merge, silently; a
#    held lock costs ten spawned sleeps and the UNSERIALIZED WARN
dmeta t7 "pr=$DU\npr_head=abc111\n"
D_ENV=('D_FILES=a.go\nb\tc.go\nlast.go'); dgo 0 t7 "$DU"; D_ENV=()
assert_eq "$(cat "$DNH/home/state/.landings")" "$(printf '%s\tt7\ta.go\n%s\tt7\tb\tc.go' $DNOW $DNOW)" "7: the TAB kept, the unterminated last line dropped"
D_ENV=('D_FILES=p1.go\np2.go\n' D_DIFFRC=1); dgo 0 t7 "$DU"; D_ENV=()
assert_eq "$(tail -n 2 "$DNH/home/state/.landings")" "$(printf '%s\tt7\tp1.go\n%s\tt7\tp2.go' $DNOW $DNOW)" "7: a failing diff keeps what it printed"
dledger() { printf -- "$1" >"$H/home/state/.landings"; }
drooms() { dput home/data/live/room.md 'x\n'; dput home/data/archive/2025/arch/room.md 'x\n'; }
drooms
dledger "$((DNOW - 8 * 86400))\told\tov.go\n$((DNOW - 3600))\tlive\tov.go\n$((DNOW - 7200))\tarch\tov.go\n$((DNOW - 60))\tt7\tov.go\n$((DNOW - 25 * 3600))\tstranger\tov.go\n"
D_ENV=('D_FILES=ov.go\n'); dgo 0 t7 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: LANDING-OVERLAP: ov.go landed 1h ago by family live - required reading: HOME/home/data/live/room.md
WARN: LANDING-OVERLAP: ov.go landed 2h ago by family arch - required reading: HOME/home/data/archive/2025/arch/room.md" "7: the foreign records warn"
assert_eq "$(cat "$DNH/home/state/.landings")" "$(printf '%s\tlive\tov.go\n%s\tarch\tov.go\n%s\tt7\tov.go\n%s\tstranger\tov.go\n%s\tt7\tov.go' $((DNOW - 3600)) $((DNOW - 7200)) $((DNOW - 60)) $((DNOW - 25 * 3600)) $DNOW)" "7: the >7d record pruned, the land appended"
if [ "$(id -u)" != 0 ]; then
  dledger "$((DNOW - 10))\tx\tu.go\n"
  dshut() { chmod 000 "$H/home/state/.landings"; }
  dopen() { chmod 644 "$H/home/state/.landings"; }
  dshut; D_ENV=('D_FILES=u.go\n'); dgo 2 t7 "$DU"; D_ENV=(); dopen
  assert_eq "$(dout):$(derr)" ":" "7: an unreadable ledger ends the run 2, silently"
  assert_eq "$(dmerge_call)" "" "7: ...before the merge"
fi
dheld() { mkdir -p "$H/home/state/.landings.lock"; printf '%s\n' "$$" >"$H/home/state/.landings.lock/pid"; }
dheld
D_ENV=('D_FILES=h.go\n'); dgo 0 t7 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: landing ledger: HOME/home/state/.landings.lock could not be acquired within 10s - recording UNSERIALIZED, so a concurrent landing's records may be lost and its <24h LANDING-OVERLAP warn may not fire for them" "7: the UNSERIALIZED WARN"
assert_eq "$(dsleeps)" 10 "7: ten waits, each a spawned sleep"
assert_eq "$(tail -n 1 "$DNH/home/state/.landings")" "$(printf '%s\tt7\th.go' $DNOW)" "7: recorded anyway"
dunheld() { rm -rf "$H/home/state/.landings.lock"; }
dunheld

# 8. the KNOWLEDGE-GAP flag through the entry, records/ minted by the look: no
#    record, the family's own entry (silent), another family's and one past
#    `## Superseded`
[ ! -e "$DNH/home/records" ] || fail "8: no row before this one reads records/"
drepo krepo
dmeta k1 "project_dir=HOME/home/projects/krepo\npr=$DU\npr_head=abc111\n"
dgo 0 k1 "$DU"
assert_eq "$(derr)" "$(dkgap k1 HOME/home/projects/krepo krepo)" "8: no record"
[ -d "$DNH/home/records" ] || fail "8: records/ minted"
dknow() { dput home/records/repo-knowledge/krepo.md "$1"; }
dknow '- fact x | src: cmd:true | at: d 2026-07-21 | by: k1\n'
dgo 0 k1 "$DU"; assert_eq "$(derr)" "" "8: the family's own entry"
dknow '- fact x | src: cmd:true | at: d 2026-07-21 | by: other\n## Superseded\n- fact y | by: k1\n'
dgo 0 k1 "$DU"; assert_eq "$(derr)" "$(dkgap k1 HOME/home/projects/krepo krepo)" "8: another family's, and one past Superseded"

# 9. the qa gate (src/lib-qa-gate.ts's twins): a project_dir that is no
#    repo (not enforced); enforced with the head unreadable or empty (refused
#    after the one read), drifted (the gate's WARN), exact with a v2 marker
#    (ONE headRefOid read in all, the merge pinned to it); the RETIRED legacy
#    config (its die is the exit, before any gh call), also with no temp file
#    in TMPDIR, where a project that does not enforce qa merges; MODE MISMATCH, the bare marker on a scoped head, the scoped
#    pass; the matrix one and both; a linked worktree (the main repo's
#    markers, yaml and record name); the require_for_ship spellings (a comment
#    after `true` enforces, a quoted `No` with a comment and a CR does not,
#    and every key counts - a nested flow false before a top-level true
#    enforces); a policy that cannot be read - an unreadable yaml, no git on
#    PATH, a .git git refuses - whose refusal is the run's exit before any gh
#    call; a CRLF scope line, a string manifest entry, a shifted pin, `00`
#    counts (an invalid marker)
dput home/plain/x 'x\n'
dmeta q0 "project_dir=HOME/home/plain\npr=$DU\npr_head=abc111\n"
dgo 0 q0 "$DU"; assert_eq "$(dout)" "merged $DU" "9: a project_dir that is no repo"
DREQ='qa:\n  require_for_ship: true\n'
dqrepo() { drepo "$1"; dput "home/projects/$1.yaml" "$2"; }
dmarker() {  # dmarker <repo> <suffix> [<scope> <app>] - a passing v2 attestation for the repo's HEAD
  local r="$H/home/projects/$1" sha; sha="$(git -C "$r" rev-parse HEAD)"
  { printf 'schema=agentcrew.qa-attestation/v2\noutcome=passed\nrun=r\ntask=t\ncompleted_at=2026-07-24T00:00:00Z\nsource_sha=%s\nprofile_key=%s/%s/%s\n' "$sha" "$1" "${3:-flat}" "${4:-flat}"
    printf 'profile_sha256=p\nconfig_sha256=c\ncases_passed=1\ncases_total=1\n'
    [ -z "${3:-}" ] || printf 'scope=%s\napp=%s\n' "$3" "$4"; } >"$r/.crew/qa/passed/$sha$2"
}
dqrepo qf "$DREQ"
QF="$(dsha qf)"
dmeta g1 "project_dir=HOME/home/projects/qf\npr=$DU\npr_head=$QF\n"
D_ENV=(D_VIEW=fail); dgo 1 g1 "$DU"; D_ENV=()
assert_eq "$(derr)" "ERROR: merge blocked: qa.require_for_ship is enforced but the PR head SHA could not be resolved (gh pr view failed or returned empty) - run crew-qa and retry once the head resolves" "9: the head unreadable"
assert_eq "$(dcalls)" "$(dview)" "9: ...refused after the one read"
D_ENV=(D_VIEW=); dgo 1 g1 "$DU"; D_ENV=()
assert_contains "$(derr)" "head SHA could not be resolved" "9: the head empty"
dmarker qf ''
D_ENV=(D_VIEW=0000000000000000000000000000000000000000); dgo 1 g1 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: qa.require_for_ship: no passing crew-qa run recorded for 000000000000 - run crew-qa on this head before merging
ERROR: merge blocked by qa.require_for_ship (see message above)" "9: a drifted head"
D_ENV=(D_VIEW=$QF); dgo 0 g1 "$DU"; D_ENV=()
assert_eq "$(dout)" "merged $DU" "9: the exact head with a marker"
assert_eq "$(LC_ALL=C grep -c headRefOid "$DNH/calls.log")" 1 "9: one headRefOid read in all"
assert_eq "$(dmerge_call)" "$(dpin '[--squash] ' "$QF")" "9: the merge pinned to the attested head"
dqrepo ql "$DREQ"
dput home/config/projects/ql.yaml "$DREQ"
dmeta g2 "project_dir=HOME/home/projects/ql\npr=$DU\npr_head=abc111\n"
dgo 1 g2 "$DU"
assert_eq "$(derr)" "ERROR: project config for 'ql' found at the RETIRED legacy path (HOME/home/config/projects/ql.yaml), which is no longer read - move it: mv \"HOME/home/config/projects/ql.yaml\" \"HOME/home/projects/ql.yaml\" (or delete it if HOME/home/projects/ql.yaml is already authoritative)" "9: RETIRED - the die is the exit"
assert_eq "$(dcalls)" "" "9: ...before any gh call"
dmeta g2t "project_dir=HOME/home/projects/ql\npr=$DU\npr_head=abc111\n"
D_ENV=(TMPDIR=HOME/no-tmp); dgo 1 g2t "$DU"; D_ENV=()
assert_eq "$(derr)" "ERROR: project config for 'ql' found at the RETIRED legacy path (HOME/home/config/projects/ql.yaml), which is no longer read - move it: mv \"HOME/home/config/projects/ql.yaml\" \"HOME/home/projects/ql.yaml\" (or delete it if HOME/home/projects/ql.yaml is already authoritative)" "9: ...its line alone"
assert_eq "$(dcalls)" "" "9: ...before any gh call"
dqrepo qn 'name: qn\n'
dmeta g2n "project_dir=HOME/home/projects/qn\npr=$DU\npr_head=abc111\n"
D_ENV=(TMPDIR=HOME/no-tmp); dgo 0 g2n "$DU"; D_ENV=()
assert_eq "$(dout)" "merged $DU" "9: no TMPDIR, qa not enforced - merged"
dundo_g2t() { rm -rf "$H/home/state/g2t.meta" "$H/home/state/g2t.status" "$H/home/data/g2t" "$H/home/state/g2n.meta" "$H/home/state/g2n.status" "$H/home/data/g2n"; }
dundo_g2t
DSCOPED='qa:\n  require_for_ship: true\n  scopes:\n    orchid:\n      seed: "true"\n'
dqrepo qs "$DSCOPED"; dmarker qs ''
QS="$(dsha qs)"
dmeta g3 "project_dir=HOME/home/projects/qs\npr=$DU\npr_head=$QS\n"
D_ENV=(D_VIEW=$QS); dgo 1 g3 "$DU"; D_ENV=()
assert_contains "$(derr)" "MODE MISMATCH - the fleet-home config declares scopes" "9: yaml scopes, no map"
dmapq() { dput "home/records/repo-knowledge/$1.md" '- scope orchid = orchid-service | src: cmd:true | at: d 2026-07-21 | by: fam\n'; }
dmapq qs
D_ENV=(D_VIEW=$QS); dgo 1 g3 "$DU"; D_ENV=()
assert_contains "$(derr)" "A bare sha-only marker IS on disk" "9: the bare marker on a scoped head"
dmarker qs .orchid.orchid-service orchid orchid-service
D_ENV=(D_VIEW=$QS); dgo 0 g3 "$DU"; D_ENV=()
assert_eq "$(dout)" "qa: passed profiles for ${QS:0:12}: orchid/orchid-service
merged $DU" "9: the scoped pass prints its pairs"
dqrepo qm "$DREQ"
QM="$(dsha qm)"
dmeta g4 "project_dir=HOME/home/projects/qm\npr=$DU\npr_head=$QM\n"
dput home/data/g4/qa/manifest.json '{"required_profiles":[{"profile_key":"qm/orchid/orchid-service"},{"profile_key":"qm/cedar/cedar-service"}]}\n'
dmarker qm .orchid.orchid-service orchid orchid-service
D_ENV=(D_VIEW=$QM); dgo 1 g4 "$DU"; D_ENV=()
assert_contains "$(derr)" "WARN: qa.require_for_ship: required profile 'qm/cedar/cedar-service' has no passing crew-qa attestation for ${QM:0:12}" "9: the matrix, one of two"
dmarker qm .cedar.cedar-service cedar cedar-service
D_ENV=(D_VIEW=$QM); dgo 0 g4 "$DU"; D_ENV=()
assert_eq "$(sed -n 1p "$TMP/n.out")" "qa: all 2 required profile(s) satisfied for ${QM:0:12}: qm/orchid/orchid-service qm/cedar/cedar-service" "9: the matrix, both"
dwt() { git -C "$H/home/projects/qf" worktree add -q --detach "$H/wt-qf"; }
dwt
dmeta g5 "project_dir=HOME/wt-qf\npr=$DU\npr_head=$QF\n"
D_ENV=(D_VIEW=$QF); dgo 0 g5 "$DU"; D_ENV=()
assert_eq "$(dout)" "merged $DU" "9: a linked worktree reads the main repo's markers"
assert_eq "$(derr)" "$(dkgap g5 HOME/wt-qf qf)" "9: ...and its yaml and record name"
DBLOCKED='ERROR: merge blocked by qa.require_for_ship (see message above)'
dqgate() {  # dqgate <id> <repo> <yaml> - a clone with its yaml and a meta pinned to its head
  dqrepo "$2" "$3"
  dmeta "$1" "project_dir=HOME/home/projects/$2\npr=$DU\npr_head=$(git -C "$H/home/projects/$2" rev-parse HEAD)\n"
}
dqgate x1 qx1 'qa:\n  require_for_ship: true # on\n'
D_ENV=("D_VIEW=$(dsha qx1)"); dgo 1 x1 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: qa.require_for_ship: no passing crew-qa run recorded for $(dsha qx1 | cut -c1-12) - run crew-qa on this head before merging
$DBLOCKED" "9: a comment after true enforces"
dqgate x2 qx2 'qa:\r\n  require_for_ship: "No" # off\r\n'
D_ENV=("D_VIEW=$(dsha qx2)"); dgo 0 x2 "$DU"; D_ENV=()
assert_eq "$(dout)" "merged $DU" "9: a false spelling is not enforced"
if [ "$(id -u)" != 0 ]; then
  dqrepo qx3 "$DREQ"
  dmeta x3 "project_dir=HOME/home/projects/qx3\npr=$DU\npr_head=abc111\n"
  dshuty() { chmod 000 "$H/home/projects/qx3.yaml"; }
  dopeny() { chmod 644 "$H/home/projects/qx3.yaml"; }
  dshuty; dgo 1 x3 "$DU"; dopeny
  assert_eq "$(derr)" "ERROR: qa.require_for_ship: the project policy HOME/home/projects/qx3.yaml cannot be read - refusing the merge rather than reading it as not enforced" "9: ...its refusal alone"
  assert_eq "$(dcalls)" "" "9: ...before any gh call"
fi
DNOGIT="$TMP/pnogit"; mkdir -p "$DNOGIT"
for f in /usr/bin/* /bin/*; do t="${f##*/}"; [ "$t" != git ] && [ ! -e "$DNOGIT/$t" ] && ln -s "$f" "$DNOGIT/$t"; done
ln -s "$(command -v bun)" "$DNOGIT/bun"
dqgate x6 qx6 "$DREQ"
D_PATH="$DSTUBS:$DNOGIT"
(PATH="$D_PATH"; command -v git >/dev/null) && fail "9: the no-git PATH must hold no git"
dgo 1 x6 "$DU"; D_PATH=""
assert_eq "$(derr)" "ERROR: qa.require_for_ship: git did not run (is it on PATH?), so the project policy for 'HOME/home/projects/qx6' cannot be resolved - refusing the merge rather than reading it as not enforced" "9: ...its refusal alone"
assert_eq "$(dcalls)" "" "9: ...before any gh call"
dcrlf() { dput "home/records/repo-knowledge/$1.md" '- scope orchid = orchid-service\r\n'; }
dqgate x8 qx8 "$DSCOPED"; dcrlf qx8
D_ENV=("D_VIEW=$(dsha qx8)"); dgo 1 x8 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: qa.require_for_ship: the project's scope map is AMBIGUOUS (two live entries for one scope, or a malformed line) - refusing the merge rather than guessing which profile a marker proves. Fix it with bin/ac-know.sh scope-proposal, then re-run: bin/ac-know.sh verify
$DBLOCKED" "9: a CRLF scope line is AMBIGUOUS"
dqgate x10 qx10 "$DREQ"
dput home/data/x10/qa/manifest.json '{"required_profiles":["qx10/orchid/orchid-service"]}\n'
D_ENV=("D_VIEW=$(dsha qx10)"); dgo 1 x10 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: qa.require_for_ship: the task's required-profile manifest is empty or unreadable (HOME/home/data/x10/qa/manifest.json) - refusing rather than merging against an undefined required set
$DBLOCKED" "9: a string entry reads as no manifest"
dqgate x11 qx11 "$DREQ"; dmarker qx11 .orchid.orchid-service orchid orchid-service
dput home/data/x11/qa/manifest.json '{"required_profiles":[{"profile_key":"qx11/orchid/orchid-service","e2e_sha":"E"}]}\n'
D_ENV=("D_VIEW=$(dsha qx11)"); dgo 1 x11 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: qa.require_for_ship: the attestation for 'qx11/orchid/orchid-service' is invalid (profile hash mismatch) - re-run crew-qa for this exact profile and head
$DBLOCKED" "9: an e2e pin with no profile pin lands in the profile pin"
dzeroes() {  # dzeroes <repo> - the flat marker's case counts spelled 00
  local f; f="$H/home/projects/$1/.crew/qa/passed/$(git -C "$H/home/projects/$1" rev-parse HEAD)"
  LC_ALL=C sed -e 's/^cases_passed=1$/cases_passed=00/' -e 's/^cases_total=1$/cases_total=00/' "$f" >"$f.t"; mv "$f.t" "$f"
}
dqgate x13 qx13 "$DREQ"; dmarker qx13 ''; dzeroes qx13
D_ENV=("D_VIEW=$(dsha qx13)"); dgo 1 x13 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: qa.require_for_ship: ignored invalid flat QA attestation for $(dsha qx13 | cut -c1-12): invalid case counts
WARN: qa.require_for_ship: no passing crew-qa run recorded for $(dsha qx13 | cut -c1-12) - run crew-qa on this head before merging
$DBLOCKED" "9: 00 case counts are an invalid marker"
dqgate x14 qx14 'qa: {app: {require_for_ship: false}, require_for_ship: true}\n'
D_ENV=("D_VIEW=$(dsha qx14)"); dgo 1 x14 "$DU"; D_ENV=()
assert_eq "$(derr)" "WARN: qa.require_for_ship: no passing crew-qa run recorded for $(dsha qx14 | cut -c1-12) - run crew-qa on this head before merging
$DBLOCKED" "9: a nested flow false before a top-level true enforces"
dput home/projects/qx15/.git 'gitdir: HOME/nowhere\n'
dmeta x15 "project_dir=HOME/home/projects/qx15\npr=$DU\npr_head=abc111\n"
dgo 1 x15 "$DU"
assert_eq "$(derr)" "ERROR: qa.require_for_ship: git could not read the repo at 'HOME/home/projects/qx15' (it holds .git, but git rev-parse failed there - a corrupt repo, or one safe.directory refuses), so its project policy cannot be resolved - refusing the merge rather than reading it as not enforced" "9: ...its refusal alone"
assert_eq "$(dcalls)" "" "9: ...before any gh call"

# 10. a state/ that takes no temp refuses the attempt before any merge (exit
#     1, the meta lock's refusal)
if [ "$(id -u)" != 0 ]; then
  dmeta w9 "pr=$DU\npr_head=abc111\n"
  dro() { chmod 555 "$H/home/state"; }
  drw() { chmod 755 "$H/home/state"; }
  dro; dgo 1 w9 "$DU"; drw
  assert_eq "$(derr)" "WARN: cannot lock meta file HOME/home/state/w9.meta - nothing written" "10: a read-only state/ refuses on the meta lock"
  assert_eq "$(dmerge_call)" "" "10: ...before any merge"
fi

# 11. staged ids: fam-ship with data/fam/ship/brief.md lands under the family
#     fam (its ledger record, its timeline under data/fam/ship/); gam-ship with
#     no stage dir is its own family
dput home/data/fam/ship/brief.md 'b\n'
dmeta fam-ship "pr=$DU\npr_head=abc111\n"
D_ENV=('D_FILES=s.go\n'); dgo 0 fam-ship "$DU"; D_ENV=()
assert_eq "$(tail -n 1 "$DNH/home/state/.landings")" "$(printf '%s\tfam\ts.go' $DNOW)" "11: the family's record"
assert_eq "$(cat "$DNH/home/data/fam/ship/timeline.log")" "$DFIXED merged: $DU" "11: the timeline under the stage dir"
dmeta gam-ship "pr=$DU\npr_head=abc111\n"
D_ENV=('D_FILES=t.go\n'); dgo 0 gam-ship "$DU"; D_ENV=()
assert_eq "$(tail -n 1 "$DNH/home/state/.landings")" "$(printf '%s\tgam-ship\tt.go' $DNOW)" "11: no stage dir - its own family"

# 12. the ROOT seam: a lab bin/ whose root links src/ starts the module from
#     this checkout, and the remedy's ac-know.sh is the LAB's (STARTED_BIN,
#     never import.meta.dir). The gate is not the lab's: a
#     lab ac-qa-lib.sh override of ac_qa_required (a stray lib planted in
#     the lab bin/) is never read, the twin in src/lib-qa-gate.ts answers
DLAB="$TMP/plab"; mkdir -p "$DLAB/bin"; cp "$BIN"/*.sh "$DLAB/bin/"; ln -s "$ROOT/src" "$DLAB/src"
printf 'ac_qa_required() { printf '"'"'lab qa %%s\\n'"'"' "$1"; return 1; }\n' >"$DLAB/bin/ac-qa-lib.sh"
out="$(cd "$DNH" && env -u AC_HOME LC_ALL=C PATH="$DSTUBS:$PATH" D_LOG="$DNH/calls.log" AC_HOME="$DNH/home" "$DLAB/bin/ac-pr-merge.sh" k1 "$DU" 2>"$TMP/plab.err")" || fail "12: the lab merge"
assert_eq "$out" "merged $DU" "12: no lab qa line - the lab's ac-qa-lib.sh is not consulted"
assert_contains "$(cat "$TMP/plab.err")" "record what it learned ($DLAB/bin/ac-know.sh add" "12: the remedy names the lab's bin/"

pass
