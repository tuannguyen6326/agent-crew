#!/usr/bin/env bash
# ac-pr-check.test.sh - records pr=, pr_head= and ci= on the task meta from a
# stubbed `gh pr view`, and refuses a malformed usage / non-PR URL.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
stub="$TMP/stubbin"
mkdir -p "$stub"
export GHVIEW_HEAD=deadbeefcafe
export GHVIEW_STATE=OPEN

cat >"$stub/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1 $2" = "pr view" ]; then
  case "$5" in
    headRefOid) printf '%s\n' "$GHVIEW_HEAD" ;;
    state) printf '%s\n' "$GHVIEW_STATE" ;;
    statusCheckRollup) printf '%s\n' "${GHVIEW_ROLLUP:-[]}" ;;
  esac
  exit 0
fi
exit 1
EOF
chmod +x "$stub/gh"

check() { PATH="$stub:$PATH" "$BIN/ac-pr-check.sh" "$@"; }

url=https://github.com/acme/widget/pull/7
printf 'backend=tmux\n' >"$AC_HOME/state/t1.meta"

out="$(check t1 "$url")"
assert_contains "$out" "pr=$url" "prints the recorded pr"
assert_contains "$out" "pr_head=$GHVIEW_HEAD" "prints the recorded pr_head"
meta="$(cat "$AC_HOME/state/t1.meta")"
assert_contains "$meta" "pr=$url" "meta records pr="
assert_contains "$meta" "pr_head=$GHVIEW_HEAD" "meta records pr_head="

# Usage and URL-shape refusals.
assert_fails check t1
assert_fails check t1 "not-a-pr-url"
assert_fails check nosuchtask "$url"


# --- the record, row by row ---------------------------------------------------
# One fleet home ($H); each run starts at $TMP with LC_ALL=C, stdin /dev/null,
# one PATH `gh` stub (answers and exit status from env, argv logged to $H.gh)
# and one PATH `date` stub freezing the stamp.
H="$TMP/nh"; STUBS="$TMP/dstubs"
mkdir -p "$STUBS" "$TMP/dateonly" "$TMP/bunonly"
ln -s "$(command -v bun)" "$TMP/bunonly/bun"
cat >"$STUBS/gh" <<'GH'
#!/bin/sh
{ printf '[%s]' "$@"; printf '\n'; } >>"$GH_LOG"
case "$5" in
  headRefOid) printf '%b' "$GH_HEAD"; [ -z "$GH_ERR_HEAD" ] || printf '%s\n' "$GH_ERR_HEAD" >&2; exit "$GH_RC_HEAD" ;;
  state) printf '%b' "$GH_STATE"; [ -z "$GH_ERR_STATE" ] || printf '%s\n' "$GH_ERR_STATE" >&2; exit "$GH_RC_STATE" ;;
  statusCheckRollup)
    # A literal `}` from the default JSON inside `${GH_ROLLUP:-...}` would
    # close the expansion early (sh does not nest braces there) - defaulted
    # as a plain assignment instead.
    r="$GH_ROLLUP"; [ -n "$r" ] || r='[{"status":"COMPLETED","conclusion":"SUCCESS"}]\n'
    printf '%b' "$r"; [ -z "${GH_ERR_ROLLUP-}" ] || printf '%s\n' "$GH_ERR_ROLLUP" >&2; exit "${GH_RC_ROLLUP:-0}" ;;
esac
exit 1
GH
cat >"$STUBS/date" <<'DATE'
#!/bin/sh
case "$*" in "-u +%Y-%m-%dT%H:%M:%SZ") echo 2026-01-01T00:00:00Z ;; *) exec /bin/date "$@" ;; esac
DATE
chmod +x "$STUBS/gh" "$STUBS/date"
cp "$STUBS/date" "$TMP/dateonly/date"
U=https://github.com/acme/widget/pull/7
ISO=2026-01-01T00:00:00Z

LAST_RC=0
run() {  # run <args...> - one record from $TMP, as a chief runs it; sets LAST_RC, stdout and stderr in $TMP/n.out and n.err
  local path="$STUBS:$PATH"
  [ "${NO_GH-}" != 1 ] || path="$TMP/dateonly:$TMP/bunonly:/usr/bin:/bin"
  [ -z "${DATE_STUB-}" ] || path="$DATE_STUB:$path"
  # A literal `}` inside a `${...-default}` would close the expansion early.
  local rollup="${GH_ROLLUP-}"
  [ -n "$rollup" ] || rollup='[{"status":"COMPLETED","conclusion":"SUCCESS"}]\n'
  rm -f "$H.gh"
  LAST_RC=0
  (cd "$TMP" && env AC_HOME="${AC_HOME_ROW:-$H}" LC_ALL=C PATH="$path" GH_LOG="$H.gh" \
    GH_HEAD="${GH_HEAD-deadbeefcafe\n}" GH_STATE="${GH_STATE-OPEN\n}" \
    GH_RC_HEAD="${GH_RC_HEAD-0}" GH_RC_STATE="${GH_RC_STATE-0}" GH_ERR_HEAD="${GH_ERR_HEAD-}" GH_ERR_STATE="${GH_ERR_STATE-}" \
    GH_ROLLUP="$rollup" GH_RC_ROLLUP="${GH_RC_ROLLUP-0}" GH_ERR_ROLLUP="${GH_ERR_ROLLUP-}" \
    "$BIN/ac-pr-check.sh" "$@" </dev/null) >"$TMP/n.out" 2>"$TMP/n.err" || LAST_RC=$?
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err"; }
reset_homes() {  # reset_homes [bare] - an empty home, state/ and data/ minted unless bare
  rm -rf "$H"; mkdir -p "$H"
  [ "${1-}" = bare ] || mkdir -p "$H/state" "$H/data"
}
seed() { mkdir -p "$(dirname "$H/$1")"; printf -- "$2" >"$H/$1"; }  # seed <relpath> <printf-format>
meta_is() {  # meta_is <printf-format> - t1.meta holds exactly these bytes
  printf -- "$1" | cmp -s - "$H/state/t1.meta" || fail "meta bytes: $(od -c "$H/state/t1.meta" | head -n 4)"
}

# 1. a plain record: the receipt, the three lines appended, the status line, the flat timeline
reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
run t1 "$U"
assert_eq "$LAST_RC" 0 "a plain record exits 0"
assert_eq "$(shim_out)" "recorded pr=$U pr_head=deadbeefcafe state=OPEN ci=green" "the receipt"
assert_eq "$(shim_err)" "" "a plain record says nothing on stderr"
meta_is "backend=tmux\nkind=ship\npr=$U\npr_head=deadbeefcafe\nci=green\n"
assert_eq "$(cat "$H/state/t1.status")" "$ISO PR ready: $U (OPEN, ci=green)" "the status line under the frozen clock"
assert_eq "$(cat "$H/data/t1/timeline.log")" "$ISO PR ready: $U (OPEN, ci=green)" "the timeline mirror"
assert_eq "$(cat "$H.gh")" "[pr][view][$U][--json][headRefOid][--jq][.headRefOid]
[pr][view][$U][--json][state][--jq][.state]
[pr][view][$U][--json][statusCheckRollup][--jq][.statusCheckRollup]" "gh's three argv, in order"
assert_eq "$(ls "$H/state")" "t1.meta
t1.status" "no temp sibling is left behind"
assert_eq "$(stat -f %Lp "$H/state/t1.meta")" "644" "the meta's mode"

# 2. a re-record over old pr=/pr_head= lines, prx= kept, an unterminated tail
reset_homes; seed state/t1.meta 'pr=old\nbackend=tmux\npr_head=oldhead\nprx=keep\nzz=1'
seed state/t1.status '2025-12-31T00:00:00Z working: spawned\n'
GH_HEAD='newhead\n' run t1 "$U"
meta_is "backend=tmux\nprx=keep\nzz=1\npr=$U\npr_head=newhead\nci=green\n"
assert_eq "$(cat "$H/state/t1.status")" "2025-12-31T00:00:00Z working: spawned
$ISO PR ready: $U (OPEN, ci=green)" "the status log appends"

# 3. CRLF lines keep their CR
reset_homes; seed state/t1.meta 'pr=a\r\nk=v\r\n'
run t1 "$U"
meta_is "k=v\r\npr=$U\npr_head=deadbeefcafe\nci=green\n"

# 4. gh fails on the head call: its status and stderr pass through, nothing written
reset_homes; seed state/t1.meta 'backend=tmux\n'
GH_RC_HEAD=3 GH_ERR_HEAD='gh: boom' run t1 "$U"
assert_eq "$LAST_RC" 3 "gh's own exit status"
assert_eq "$(shim_err)" "gh: boom" "gh's own stderr passes through"
assert_eq "$(shim_out)" "" "no receipt"
meta_is "backend=tmux\n"
assert_no_file "$H/state/t1.status" "no status minted"
assert_no_file "$H/data/t1" "no timeline dir minted"
assert_eq "$(cat "$H.gh")" "[pr][view][$U][--json][headRefOid][--jq][.headRefOid]" "the second call is never made"

# 5. gh fails on the state call: both rewrites come after both calls
GH_RC_STATE=2 run t1 "$U"
assert_eq "$LAST_RC" 2 "the state call's status"
meta_is "backend=tmux\n"
assert_no_file "$H/state/t1.status" "nothing written"

# 8. URL shapes: `*` spans slashes, the digit is required, case and scheme are exact
for u in https://github.com/a/b/c/pull/7 https://github.com//b/pull/7 https://github.com/a/b/pull/7x https://github.com/a/b/pull/7/files "https://github.com/a/b/pull/7 "; do
  reset_homes; seed state/t1.meta 'backend=tmux\n'
  run t1 "$u"
  assert_eq "$LAST_RC" 0 "accepted url '$u'"
  assert_contains "$(cat "$H/state/t1.meta")" "pr=$u" "recorded url '$u'"
done
for u in https://github.com/a/pull/7 https://github.com/a/b/pull/ http://github.com/a/b/pull/7 https://GitHub.com/a/b/pull/7 not-a-pr-url; do
  reset_homes; seed state/t1.meta 'backend=tmux\n'
  run t1 "$u"
  assert_eq "$LAST_RC" 1 "refused url '$u'"
  assert_eq "$(shim_err)" "ERROR: not a full GitHub PR URL: $u" "the refusal names the url"
  meta_is "backend=tmux\n"
  assert_no_file "$H.gh" "gh is never called for a refused url"
done

# 9. refusals and their order
reset_homes
run
assert_eq "$(shim_err)" "ERROR: usage: ac-pr-check.sh <id> <pr-url>" "no args"
run t1
assert_eq "$(shim_err)" "ERROR: usage: ac-pr-check.sh <id> <pr-url>" "one arg"
run t1 ""
assert_eq "$LAST_RC" 1 "an empty url is missing"
run nosuch "$U"
assert_eq "$(shim_err)" "ERROR: no crewmate meta for nosuch" "no meta"
run nosuch not-a-url
assert_eq "$(shim_err)" "ERROR: no crewmate meta for nosuch" "the meta check precedes the url check"
NO_GH=1 run
assert_eq "$(shim_err)" "ERROR: required tool not found: gh" "gh is required before the arguments are read"
seed state/t1.meta 'backend=tmux\n'
NO_GH=1 run t1 "$U"
assert_eq "$(shim_err)" "ERROR: required tool not found: gh" "and before any record"
meta_is "backend=tmux\n"

# 10. an AC_HOME that cannot be entered is named, exit 1
reset_homes
AC_HOME_ROW="$TMP/missing-home" run t1 "$U"
assert_eq "$LAST_RC" 1 "an unenterable home exits 1"
assert_contains "$(shim_err)" "ERROR: AC_HOME is not a readable directory: $TMP/missing-home" "the unenterable home is named"
assert_eq "$(shim_out)" "" "an unenterable home prints no receipt"

# 11. a verify-* meta: receipt and status, no timeline
reset_homes; seed state/vf.meta 'kind=verify-codereview\n'
run vf "$U"
assert_eq "$LAST_RC" 0 "a verify meta records"
assert_eq "$(cat "$H/state/vf.status")" "$ISO PR ready: $U (OPEN, ci=green)" "the status line"
assert_eq "$(find "$H/data" -name timeline.log)" "" "no timeline for a verify pane"

# 12. staged ids over every nested shape of the bin/ac-brief.sh layout, then
#     each with the flat brief ALSO present: ambiguous, no timeline, still exit 0
while read -r id brief tl; do
  reset_homes; seed "state/$id.meta" 'kind=ship\n'
  [ "$brief" = - ] || seed "$brief" 'brief\n'
  [ "$id" != fam-chief ] || mkdir -p "$H/data/fam"
  run "$id" "$U"
  assert_eq "$LAST_RC" 0 "staged id '$id' records"
  assert_eq "$(cat "$H/$tl")" "$ISO PR ready: $U (OPEN, ci=green)" "timeline at $tl for '$id'"
  seed "data/$id/brief.md" 'flat\n'
  run "$id" "$U"
  assert_eq "$LAST_RC" 0 "ambiguous '$id' still records"
  assert_eq "$(find "$H/data" -name timeline.log | LC_ALL=C sort | tr '\n' ' ')" "$H/$tl " "ambiguous '$id' adds no timeline line anywhere"
  assert_eq "$(wc -l <"$H/$tl" | tr -d ' ')" "1" "the first record's line is the only one"
done <<'ROWS'
fam-spec data/fam/spec/brief.md data/fam/spec/timeline.log
fam-spec-r2 data/fam/spec-r2/brief.md data/fam/spec-r2/timeline.log
fam-r3 data/fam/implement-r3/brief.md data/fam/implement-r3/timeline.log
fam-chief - data/fam/chief/timeline.log
t9 data/t9/implement/brief.md data/t9/implement/timeline.log
fam-slug data/fam/tasks/slug/brief.md data/fam/tasks/slug/timeline.log
ROWS

# 14. the meta path is a directory
reset_homes; mkdir -p "$H/state/t1.meta"
run t1 "$U"
assert_eq "$(shim_err)" "ERROR: no crewmate meta for t1" "a directory is no meta"

# 15. a meta this process cannot read is refused, exit 1, the meta untouched,
#     nothing written
if [ "$(id -u)" != 0 ]; then
  reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
  chmod 000 "$H/state/t1.meta"
  run t1 "$U"
  assert_eq "$LAST_RC" 1 "an unreadable meta is refused"
  assert_eq "$(shim_err)" "ERROR: cannot rewrite $H/state/t1.meta: EACCES" "the refusal names the meta"
  assert_eq "$(shim_out)" "" "no receipt"
  assert_eq "$(stat -f %Lp "$H/state/t1.meta")" "0" "the meta's mode is left as it was"
  chmod 644 "$H/state/t1.meta"
  meta_is 'backend=tmux\nkind=ship\n'
  assert_no_file "$H/state/t1.status" "nothing else written"
  assert_eq "$(ls "$H/state")" "t1.meta" "no temp left"
fi

# 16. a meta holding a NUL byte keeps its bytes
reset_homes; seed state/t1.meta 'note=a\0b\nbackend=tmux\npr=old\n'
run t1 "$U"
assert_eq "$LAST_RC" 0 "a NUL in the meta still records"
meta_is "note=a\0b\nbackend=tmux\npr=$U\npr_head=deadbeefcafe\nci=green\n"

# 17. a byte that is not UTF-8 in a kept line passes through
reset_homes; seed state/t1.meta 'note=d\351\nbackend=tmux\n'
run t1 "$U"
meta_is "note=d\351\nbackend=tmux\npr=$U\npr_head=deadbeefcafe\nci=green\n"

# 18. state/ and data/ absent at the start are minted by the look and the mirror
reset_homes bare; seed state/t1.meta 'backend=tmux\n'
run t1 "$U"
assert_eq "$(cat "$H/data/t1/timeline.log")" "$ISO PR ready: $U (OPEN, ci=green)" "data/ minted for the mirror"
reset_homes bare
run nosuch "$U"
[ -d "$H/state" ] || fail "state/ minted by the meta look"

# 19. a symlinked meta is replaced by a regular file, the target untouched; a
#     dangling one is no meta.
reset_homes; seed state/real.meta 'backend=tmux\n'
ln -s real.meta "$H/state/t1.meta"
run t1 "$U"
assert_eq "$LAST_RC" 0 "a symlinked meta records"
[ ! -L "$H/state/t1.meta" ] || fail "the symlink was not replaced by a regular file"
assert_eq "$(cat "$H/state/real.meta")" "backend=tmux" "the link target is untouched"
meta_is "backend=tmux\npr=$U\npr_head=deadbeefcafe\nci=green\n"
reset_homes
ln -s gone.meta "$H/state/t1.meta"
run t1 "$U"
assert_eq "$(shim_err)" "ERROR: no crewmate meta for t1" "a dangling link is no meta"

# 20. bun decodes argv, so a url byte that is not UTF-8 is passed to gh and
#     recorded as U+FFFD (EF BF BD)
reset_homes; seed state/t1.meta 'backend=tmux\n'
run t1 "$(printf 'https://github.com/a/b/pull/7\351')"
assert_eq "$LAST_RC" 0 "a non-UTF-8 url records"
meta_is 'backend=tmux\npr=https://github.com/a/b/pull/7\357\277\275\npr_head=deadbeefcafe\nci=green\n'
assert_contains "$(cat "$H.gh")" "$(printf 'pull/7\357\277\275]')" "U+FFFD is what gh was passed"

# 21. date(1) failing when the status is stamped: the meta is already rewritten
#     (every gh call and every rewrite precedes it), the run ends with date's
#     status, no status line, no timeline; a signalled date is 128+signal; a
#     NUL in the stamp is dropped
datestub() {  # datestub <name> <sh command for the stamp call> - a PATH dir whose date runs it
  mkdir -p "$TMP/$1"
  printf '#!/bin/sh\ncase "$*" in "-u +%%Y-%%m-%%dT%%H:%%M:%%SZ") %s ;; *) exec /bin/date "$@" ;; esac\n' "$2" >"$TMP/$1/date"
  chmod +x "$TMP/$1/date"
}
datestub baddate 'exit 3'
datestub killdate 'kill -TERM $$'
datestub nuldate 'printf "2026-01-01T00:00:00Z\\000\\n"'
reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
DATE_STUB="$TMP/baddate" run t1 "$U"
assert_eq "$LAST_RC" 3 "date failing: the run ends with date's status"
assert_eq "$(shim_out)$(shim_err)" "" "date failing: nothing printed"
meta_is "backend=tmux\nkind=ship\npr=$U\npr_head=deadbeefcafe\nci=green\n"
assert_no_file "$H/state/t1.status" "date failing: no status line"
assert_no_file "$H/data/t1/timeline.log" "date failing: no timeline"
reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
DATE_STUB="$TMP/killdate" run t1 "$U"
assert_eq "$LAST_RC" 143 "date killed: the run ends with 128+SIGTERM"
assert_no_file "$H/state/t1.status" "date killed: no status line"
reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
DATE_STUB="$TMP/nuldate" run t1 "$U"
assert_eq "$LAST_RC" 0 "NUL stamp: the run records"
assert_eq "$(cat "$H/state/t1.status")" "$ISO PR ready: $U (OPEN, ci=green)" "NUL stamp: the NUL is gone from the line"
assert_eq "$(cat "$H/data/t1/timeline.log")" "$(cat "$H/state/t1.status")" "NUL stamp: the timeline mirrors the status"

# 22. the status file cannot be appended (mode 000): refused, exit 1, before
#     any mirror - the meta already rewritten (root writes it: unprivileged only)
if [ "$(id -u)" != 0 ]; then
  reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'; seed state/t1.status ''
  chmod 000 "$H/state/t1.status"
  run t1 "$U"
  chmod 644 "$H/state/t1.status"
  assert_eq "$LAST_RC" 1 "unwritable status: exit 1"
  assert_eq "$(shim_out)" "" "unwritable status: no receipt"
  assert_eq "$(shim_err)" "ERROR: cannot append $H/state/t1.status" "unwritable status: the refusal"
  meta_is "backend=tmux\nkind=ship\npr=$U\npr_head=deadbeefcafe\nci=green\n"
  assert_eq "$(cat "$H/state/t1.status")" "" "unwritable status: no status line"
  assert_no_file "$H/data/t1/timeline.log" "unwritable status: no mirror after the failed primary"
fi

# 23. an id ending in LF: the meta and the status keep the LF in their names,
#     the timeline lands under the LF-less dir
reset_homes; seed "state/t1
.meta" 'backend=tmux\nkind=ship\n'
run "t1
" "$U"
assert_eq "$LAST_RC" 0 "LF id: the run records"
assert_eq "$(shim_out)" "recorded pr=$U pr_head=deadbeefcafe state=OPEN ci=green" "LF id: the receipt"
[ -f "$H/state/t1
.status" ] || fail "LF id: the status keeps the LF in its name"
assert_contains "$(cat "$H/state/t1
.meta")" "pr_head=deadbeefcafe" "LF id: the meta keeps the LF in its name"
assert_eq "$(cat "$H/data/t1/timeline.log")" "$ISO PR ready: $U (OPEN, ci=green)" "LF id: the timeline under the LF-less dir"

# 24. the four ci= classifications
reset_homes; seed state/t1.meta 'backend=tmux\n'
GH_ROLLUP='[]\n' run t1 "$U"
assert_eq "$LAST_RC" 0 "ci=none still records"
assert_eq "$(shim_out)" "recorded pr=$U pr_head=deadbeefcafe state=OPEN ci=none" "ci=none: the receipt"
meta_is "backend=tmux\npr=$U\npr_head=deadbeefcafe\nci=none\n"
assert_eq "$(cat "$H/state/t1.status")" "$ISO PR ready: $U (OPEN, no CI checks reported: unverified)" "ci=none: the exact none wording"

reset_homes; seed state/t1.meta 'backend=tmux\n'
GH_ROLLUP='[{"status":"IN_PROGRESS","conclusion":null}]\n' run t1 "$U"
assert_eq "$(shim_out)" "recorded pr=$U pr_head=deadbeefcafe state=OPEN ci=pending" "ci=pending: the receipt"
meta_is "backend=tmux\npr=$U\npr_head=deadbeefcafe\nci=pending\n"
assert_eq "$(cat "$H/state/t1.status")" "$ISO PR ready: $U (OPEN, ci=pending)" "ci=pending: the status line"

reset_homes; seed state/t1.meta 'backend=tmux\n'
GH_ROLLUP='[{"status":"COMPLETED","conclusion":"FAILURE"}]\n' run t1 "$U"
assert_eq "$(shim_out)" "recorded pr=$U pr_head=deadbeefcafe state=OPEN ci=failing" "ci=failing: the receipt"
meta_is "backend=tmux\npr=$U\npr_head=deadbeefcafe\nci=failing\n"
assert_eq "$(cat "$H/state/t1.status")" "$ISO PR ready: $U (OPEN, ci=failing)" "ci=failing: the status line"

reset_homes; seed state/t1.meta 'backend=tmux\n'
GH_ROLLUP='[{"status":"COMPLETED","conclusion":"SUCCESS"},{"state":"SUCCESS"}]\n' run t1 "$U"
assert_eq "$(shim_out)" "recorded pr=$U pr_head=deadbeefcafe state=OPEN ci=green" "ci=green: a CheckRun and a StatusContext, both ok"
meta_is "backend=tmux\npr=$U\npr_head=deadbeefcafe\nci=green\n"

pass
