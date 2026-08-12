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

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
stub="$TMP/stubbin"
mkdir -p "$stub"
export GHLOG="$TMP/gh.log"
export GHPRFILES="$TMP/gh.prfiles"   # `gh pr diff --name-only` answer, if set
export GHVIEW=""                     # `gh pr view --json headRefOid` behavior

# Logging gh fake: one bracketed line per argv element, so an empty-string
# argument would show up as a bare `[]` line and break the exact match.
# (Each call truncates the log, so GHLOG always holds the LAST call's argv -
# the `pr merge` one the argv asserts care about.)
# `pr view` is driven by GHVIEW to inject the fail-closed cases: "fail" exits
# nonzero (gh API error), "empty" prints nothing (empty head sha), any other
# value is printed as the resolved head sha.
cat >"$stub/gh" <<'EOF'
#!/usr/bin/env bash
: >"$GHLOG"
for a in "$@"; do printf '[%s]\n' "$a" >>"$GHLOG"; done
if [ "$1 $2" = "pr view" ]; then
  case "${GHVIEW:-}" in
    fail)  exit 1 ;;
    empty) exit 0 ;;
    *)     printf '%s\n' "$GHVIEW"; exit 0 ;;
  esac
fi
[ "$1 $2" = "pr diff" ] && cat "$GHPRFILES" 2>/dev/null
exit 0
EOF
chmod +x "$stub/gh"

url=https://github.com/acme/widget/pull/7
printf 'backend=tmux\n' >"$AC_HOME/state/t1.meta"

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
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n' "$url")" "no-tail argv"
assert_contains "$(cat "$AC_HOME/state/t1.meta")" "pr_merged=1" "meta records merge"

# Tail passes through verbatim; a method flag in the tail is not doubled.
merge t1 "$url" -- --squash --admin >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--admin]\n' "$url")" "tail verbatim, --squash not doubled"

# The `-- --squash` workaround alone still yields a single --squash.
merge t1 "$url" -- --squash >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n' "$url")" "-- --squash workaround"

# `-- --merge` replaces the default method.
merge t1 "$url" -- --merge >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--merge]\n' "$url")" "-- --merge overrides method"

# A flag value containing a space survives quoting as one argv element.
merge t1 "$url" -- --subject "release: two words" >/dev/null
assert_eq "$(argv)" "$(printf '[pr]\n[merge]\n[%s]\n[--squash]\n[--subject]\n[release: two words]\n' "$url")" "spaced flag stays one arg"

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
printf 'backend=tmux\nproject_dir=%s\n' "$qarepo" >"$AC_HOME/state/q1.meta"

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

# (e) a project that does NOT require qa still merges with an unresolved head.
noqarepo="$(make_repo noqarepo)"                          # no fleet-home config -> qa not enforced
printf 'backend=tmux\nproject_dir=%s\n' "$noqarepo" >"$AC_HOME/state/q2.meta"
GHVIEW=fail
out="$(merge q2 "$url" 2>&1)"
assert_contains "$out" "merged $url" "qa not required -> unresolved head is no false refusal"

# --- the SCOPED merge gate, driven through the HELPER ------------------------
# The LAYERING proof, and its location is load-bearing: ac_qa_gate_ok lives in
# ac-qa-lib.sh but reads the project yaml through ac_yaml_has, which lives in
# ac-pipeline-lib.sh. A unit test on the function passes even with this
# helper's source line missing - which is exactly the bug. Only driving the
# SCRIPT catches it.
mkdir -p "$AC_HOME/records/repo-knowledge"
grepo2="$(make_repo scopedqarepo)"
ghead="$(git -C "$grepo2" rev-parse HEAD)"
printf 'backend=tmux\nproject_dir=%s\n' "$grepo2" >"$AC_HOME/state/g1.meta"
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
printf 'backend=tmux\nproject_dir=%s\n' "$mrepo" >"$AC_HOME/state/m1.meta"
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
printf 'backend=tmux\nproject_dir=%s\n' "$krepo" >"$AC_HOME/state/k1.meta"
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

pass
