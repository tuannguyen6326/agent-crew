#!/usr/bin/env bash
# ac-pr-check.test.sh - records pr= and pr_head= on the task meta from a
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


# --- differential: src/pr-check.ts against the frozen bash original ----------
# DISPUTED: the implementation (tests/fixtures/ac-pr-check.sh under bash vs src/pr-check.ts through bin/ac-pr-check.sh)
# HELD-CONSTANT: two fleet homes seeded alike ($OH for the oracle, $NH for the shim), argv, cwd, LC_ALL=C, one PATH `gh` stub (answers and exit status from env, argv logged) and one PATH `date` stub freezing ac_iso, on both sides; exit status, stdout and stderr (the home spelled HOME) compared whole, then every entry under the home - path, mode, bytes - and the gh argv log.
obin="$(make_oracle_bin ac-pr-check)"
OH="$TMP/oh"; NH="$TMP/nh"; STUBS="$TMP/dstubs"
mkdir -p "$STUBS" "$TMP/dateonly" "$TMP/bunonly"
ln -s "$(command -v bun)" "$TMP/bunonly/bun"
cat >"$STUBS/gh" <<'GH'
#!/bin/sh
{ printf '[%s]' "$@"; printf '\n'; } >>"$GH_LOG"
case "$5" in
  headRefOid) printf '%b' "$GH_HEAD"; [ -z "$GH_ERR_HEAD" ] || printf '%s\n' "$GH_ERR_HEAD" >&2; exit "$GH_RC_HEAD" ;;
  state) printf '%b' "$GH_STATE"; [ -z "$GH_ERR_STATE" ] || printf '%s\n' "$GH_ERR_STATE" >&2; exit "$GH_RC_STATE" ;;
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

run_side() {  # run_side <bin> <home> <out> <err> <args...> - one side, from $TMP, as a chief runs it
  local b="$1" h="$2" o="$3" e="$4"; shift 4
  local path="$STUBS:$PATH"
  [ "${NO_GH-}" != 1 ] || path="$TMP/dateonly:$TMP/bunonly:/usr/bin:/bin"
  # env's -u must precede its assignments, so the home goes first either way.
  local -a home
  if [ "${HOMELESS-}" = 1 ]; then home=(-u AC_HOME); else home=(AC_HOME="${AC_HOME_ROW:-$h}"); fi
  (cd "$TMP" && env "${home[@]}" LC_ALL=C PATH="$path" GH_LOG="$h.gh" \
    GH_HEAD="${GH_HEAD-deadbeefcafe\n}" GH_STATE="${GH_STATE-OPEN\n}" \
    GH_RC_HEAD="${GH_RC_HEAD-0}" GH_RC_STATE="${GH_RC_STATE-0}" GH_ERR_HEAD="${GH_ERR_HEAD-}" GH_ERR_STATE="${GH_ERR_STATE-}" \
    "$@") >"$o" 2>"$e"
}
oracle() { run_side "$obin" "$OH" "$TMP/o.raw" "$TMP/o.rawerr" "$obin/ac-pr-check.sh" "$@"; }
shim() { run_side "$BIN" "$NH" "$TMP/n.raw" "$TMP/n.rawerr" "$BIN/ac-pr-check.sh" "$@"; }
norm() {  # norm <file> <home> - the home spelled HOME
  LC_ALL=C sed -e "s#$2#HOME#g" "$1"
}
snap() {  # snap <home> <out> - every entry under <home>, byte order: a dir, a link and its target, or a file with its mode and bytes
  : >"$2"
  [ -d "$1" ] || return 0
  (cd "$1" && find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf '== %s -> %s\n' "$f" "$(readlink "$f")"
    elif [ -d "$f" ]; then printf '== %s/\n' "$f"
    else printf '== %s %s\n' "$f" "$(stat -f %Lp "$f")"; cat "$f" 2>/dev/null; printf '\n--\n'; fi
  done) >"$2"
}
LAST_RC=0
same() {  # same <args...> - oracle on $OH and shim on $NH answer and leave byte-identical homes
  local o_rc=0 n_rc=0
  rm -f "$OH.gh" "$NH.gh"
  oracle "$@" || o_rc=$?
  shim "$@" || n_rc=$?
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/o.rawerr" "$OH" >"$TMP/o.err"
  norm "$TMP/n.raw" "$NH" >"$TMP/n.out"; norm "$TMP/n.rawerr" "$NH" >"$TMP/n.err"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  LAST_RC=$n_rc
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  [ "${ERR-}" = own ] || cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err" "$TMP/n.err" | head -n 4)"
  snap "$OH" "$TMP/o.tree"; snap "$NH" "$TMP/n.tree"
  [ "${TREE-}" = own ] || cmp -s "$TMP/o.tree" "$TMP/n.tree" || fail "differential home tree differs for '$*': $(diff "$TMP/o.tree" "$TMP/n.tree" | head -n 8)"
  if [ -e "$OH.gh" ] || [ -e "$NH.gh" ]; then
    cmp -s "$OH.gh" "$NH.gh" || fail "differential gh argv differs for '$*': $(diff "$OH.gh" "$NH.gh" | head -n 4)"
  fi
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err"; }
oracle_err() { cat "$TMP/o.err"; }
shim_tree() { cat "$TMP/n.tree"; }
reset_homes() {  # reset_homes [bare] - two empty homes, state/ and data/ minted unless bare
  rm -rf "$OH" "$NH"; mkdir -p "$OH" "$NH"
  [ "${1-}" = bare ] || mkdir -p "$OH/state" "$OH/data" "$NH/state" "$NH/data"
}
seed() {  # seed <relpath> <printf-format> - the same file under both homes
  local h; for h in "$OH" "$NH"; do mkdir -p "$(dirname "$h/$1")"; printf -- "$2" >"$h/$1"; done
}
seed_dir() { local h; for h in "$OH" "$NH"; do mkdir -p "$h/$1"; done; }
meta_is() {  # meta_is <printf-format> - the shim's t1.meta holds exactly these bytes
  printf -- "$1" | cmp -s - "$NH/state/t1.meta" || fail "shim meta bytes: $(od -c "$NH/state/t1.meta" | head -n 4)"
}

# 1. a plain record: the receipt, the two lines appended, the status line, the flat timeline
reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
same t1 "$U"
assert_eq "$LAST_RC" 0 "a plain record exits 0"
assert_eq "$(shim_out)" "recorded pr=$U pr_head=deadbeefcafe state=OPEN" "the receipt"
assert_eq "$(shim_err)" "" "a plain record says nothing on stderr"
meta_is "backend=tmux\nkind=ship\npr=$U\npr_head=deadbeefcafe\n"
assert_eq "$(cat "$NH/state/t1.status")" "$ISO PR ready: $U (OPEN)" "the status line under the frozen clock"
assert_eq "$(cat "$NH/data/t1/timeline.log")" "$ISO PR ready: $U (OPEN)" "the timeline mirror"
assert_eq "$(cat "$NH.gh")" "[pr][view][$U][--json][headRefOid][--jq][.headRefOid]
[pr][view][$U][--json][state][--jq][.state]" "gh's two argv, in order"
assert_eq "$(ls "$NH/state")" "t1.meta
t1.status" "no temp sibling is left behind"
assert_eq "$(stat -f %Lp "$NH/state/t1.meta")" "644" "the meta's mode"

# 2. a re-record over old pr=/pr_head= lines, prx= kept, an unterminated tail
reset_homes; seed state/t1.meta 'pr=old\nbackend=tmux\npr_head=oldhead\nprx=keep\nzz=1'
seed state/t1.status '2025-12-31T00:00:00Z working: spawned\n'
GH_HEAD='newhead\n' same t1 "$U"
meta_is "backend=tmux\nprx=keep\nzz=1\npr=$U\npr_head=newhead\n"
assert_eq "$(cat "$NH/state/t1.status")" "2025-12-31T00:00:00Z working: spawned
$ISO PR ready: $U (OPEN)" "the status log appends"

# 3. CRLF lines keep their CR
reset_homes; seed state/t1.meta 'pr=a\r\nk=v\r\n'
same t1 "$U"
meta_is "k=v\r\npr=$U\npr_head=deadbeefcafe\n"

# 4. gh fails on the head call: its status and stderr pass through, nothing written
reset_homes; seed state/t1.meta 'backend=tmux\n'
GH_RC_HEAD=3 GH_ERR_HEAD='gh: boom' same t1 "$U"
assert_eq "$LAST_RC" 3 "gh's own exit status"
assert_eq "$(shim_err)" "gh: boom" "gh's own stderr passes through"
assert_eq "$(shim_out)" "" "no receipt"
meta_is "backend=tmux\n"
assert_no_file "$NH/state/t1.status" "no status minted"
assert_no_file "$NH/data/t1" "no timeline dir minted"
assert_eq "$(cat "$NH.gh")" "[pr][view][$U][--json][headRefOid][--jq][.headRefOid]" "the second call is never made"

# 5. gh fails on the state call: both rewrites come after both calls
GH_RC_STATE=2 same t1 "$U"
assert_eq "$LAST_RC" 2 "the state call's status"
meta_is "backend=tmux\n"
assert_no_file "$NH/state/t1.status" "nothing written"

# 6. empty answers record an empty pr_head= and an empty state (W2)
GH_HEAD= GH_STATE= same t1 "$U"
assert_eq "$(shim_out)" "recorded pr=$U pr_head= state=" "the receipt with empty fields"
meta_is "backend=tmux\npr=$U\npr_head=\n"
assert_eq "$(cat "$NH/state/t1.status")" "$ISO PR ready: $U ()" "the status line with an empty state"

# 7. a multi-line answer is recorded verbatim, trailing newlines stripped (W2)
reset_homes; seed state/t1.meta 'backend=tmux\n'
GH_HEAD='aaa\nbbb\n\n' same t1 "$U"
assert_eq "$(shim_out)" "recorded pr=$U pr_head=aaa
bbb state=OPEN" "a two-line receipt"
meta_is "backend=tmux\npr=$U\npr_head=aaa\nbbb\n"

# 8. URL shapes: `*` spans slashes, the digit is required, case and scheme are exact
for u in https://github.com/a/b/c/pull/7 https://github.com//b/pull/7 https://github.com/a/b/pull/7x https://github.com/a/b/pull/7/files "https://github.com/a/b/pull/7 "; do
  reset_homes; seed state/t1.meta 'backend=tmux\n'
  same t1 "$u"
  assert_eq "$LAST_RC" 0 "accepted url '$u'"
  assert_contains "$(cat "$NH/state/t1.meta")" "pr=$u" "recorded url '$u'"
done
for u in https://github.com/a/pull/7 https://github.com/a/b/pull/ http://github.com/a/b/pull/7 https://GitHub.com/a/b/pull/7 not-a-pr-url; do
  reset_homes; seed state/t1.meta 'backend=tmux\n'
  same t1 "$u"
  assert_eq "$LAST_RC" 1 "refused url '$u'"
  assert_eq "$(shim_err)" "ERROR: not a full GitHub PR URL: $u" "the refusal names the url"
  meta_is "backend=tmux\n"
  assert_no_file "$NH.gh" "gh is never called for a refused url"
done

# 9. refusals and their order
reset_homes
same
assert_eq "$(shim_err)" "ERROR: usage: ac-pr-check.sh <id> <pr-url>" "no args"
same t1
assert_eq "$(shim_err)" "ERROR: usage: ac-pr-check.sh <id> <pr-url>" "one arg"
same t1 ""
assert_eq "$LAST_RC" 1 "an empty url is missing"
same nosuch "$U"
assert_eq "$(shim_err)" "ERROR: no crewmate meta for nosuch" "no meta"
same nosuch not-a-url
assert_eq "$(shim_err)" "ERROR: no crewmate meta for nosuch" "the meta check precedes the url check"
NO_GH=1 same
assert_eq "$(shim_err)" "ERROR: required tool not found: gh" "gh is required before the arguments are read"
seed state/t1.meta 'backend=tmux\n'
NO_GH=1 same t1 "$U"
assert_eq "$(shim_err)" "ERROR: required tool not found: gh" "and before any record"
meta_is "backend=tmux\n"

# 10. homeless: the refusal AND the meta refusal, exit 1 (W1)
reset_homes
HOMELESS=1 same t1 "$U"
assert_eq "$LAST_RC" 1 "homeless exits 1"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one
ERROR: no crewmate meta for t1" "the two ERROR lines"
# Named divergence: an AC_HOME cd cannot enter is the shell's own `cd:` line in
# the original; the port names the variable. Same second line, same exit.
ERR=own AC_HOME_ROW="$TMP/missing-home" same t1 "$U"
assert_eq "$LAST_RC" 1 "an unenterable home exits 1"
assert_contains "$(oracle_err)" "cd: $TMP/missing-home: No such file or directory" "the original's cd noise"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not a readable directory: $TMP/missing-home
ERROR: no crewmate meta for t1" "the port's refusal, then the entry's own line"

# 11. a verify-* meta: receipt and status, no timeline
reset_homes; seed state/vf.meta 'kind=verify-codereview\n'
same vf "$U"
assert_eq "$LAST_RC" 0 "a verify meta records"
assert_eq "$(cat "$NH/state/vf.status")" "$ISO PR ready: $U (OPEN)" "the status line"
assert_eq "$(find "$NH/data" -name timeline.log)" "" "no timeline for a verify pane"

# 12. staged ids over every nested shape of the bin/ac-brief.sh layout, then
#     each with the flat brief ALSO present: ambiguous, no timeline, still exit 0
while read -r id brief tl; do
  reset_homes; seed "state/$id.meta" 'kind=ship\n'
  [ "$brief" = - ] || seed "$brief" 'brief\n'
  [ "$id" != fam-chief ] || seed_dir data/fam
  same "$id" "$U"
  assert_eq "$LAST_RC" 0 "staged id '$id' records"
  assert_eq "$(cat "$NH/$tl")" "$ISO PR ready: $U (OPEN)" "timeline at $tl for '$id'"
  seed "data/$id/brief.md" 'flat\n'
  same "$id" "$U"
  assert_eq "$LAST_RC" 0 "ambiguous '$id' still records"
  assert_eq "$(find "$NH/data" -name timeline.log | LC_ALL=C sort | tr '\n' ' ')" "$NH/$tl " "ambiguous '$id' adds no timeline line anywhere"
  assert_eq "$(wc -l <"$NH/$tl" | tr -d ' ')" "1" "the first record's line is the only one"
done <<'ROWS'
fam-spec data/fam/spec/brief.md data/fam/spec/timeline.log
fam-spec-r2 data/fam/spec-r2/brief.md data/fam/spec-r2/timeline.log
fam-r3 data/fam/implement-r3/brief.md data/fam/implement-r3/timeline.log
fam-chief - data/fam/chief/timeline.log
t9 data/t9/implement/brief.md data/t9/implement/timeline.log
fam-slug data/fam/tasks/slug/brief.md data/fam/tasks/slug/timeline.log
ROWS

# 13. an id that traverses: refused without the file, recorded through it with
#     (the bash never validated the id - a defect candidate, reproduced)
reset_homes
same ../t1 "$U"
assert_eq "$(shim_err)" "ERROR: no crewmate meta for ../t1" "a traversing id with no file"
seed t1.meta 'backend=tmux\n'
same ../t1 "$U"
assert_eq "$LAST_RC" 0 "a traversing id records"
assert_eq "$(cat "$NH/t1.meta")" "backend=tmux
pr=$U
pr_head=deadbeefcafe" "recorded at <home>/t1.meta"
assert_eq "$(cat "$NH/t1/timeline.log")" "$ISO PR ready: $U (OPEN)" "and its timeline under <home>/t1"

# 14. the meta path is a directory
reset_homes; seed_dir state/t1.meta
same t1 "$U"
assert_eq "$(shim_err)" "ERROR: no crewmate meta for t1" "a directory is no meta"

# 15. a meta grep cannot read (W4) - named divergence: the original truncated it
#     to the two new lines (grep's noise on stderr, exit 0, status written); the
#     port refuses, exit 1, the meta untouched, nothing written.
if [ "$(id -u)" != 0 ]; then
  reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
  chmod 000 "$OH/state/t1.meta" "$NH/state/t1.meta"
  o_rc=0; n_rc=0
  oracle t1 "$U" || o_rc=$?
  shim t1 "$U" || n_rc=$?
  assert_eq "$o_rc" 0 "W4: the original exits 0"
  assert_eq "$(cat "$OH/state/t1.meta")" "pr=$U
pr_head=deadbeefcafe" "W4: the original truncated the meta"
  assert_contains "$(cat "$TMP/o.rawerr")" "grep: $OH/state/t1.meta: Permission denied" "W4: grep's noise on the original"
  assert_eq "$n_rc" 1 "W4: the port refuses"
  assert_eq "$(cat "$TMP/n.rawerr")" "ERROR: cannot rewrite $NH/state/t1.meta: EACCES" "W4: the port's refusal"
  assert_eq "$(cat "$TMP/n.raw")" "" "W4: no receipt from the port"
  assert_eq "$(stat -f %Lp "$NH/state/t1.meta")" "0" "W4: the port left the meta as it was"
  chmod 644 "$NH/state/t1.meta" "$OH/state/t1.meta"
  assert_eq "$(cat "$NH/state/t1.meta")" "backend=tmux
kind=ship" "W4: the port's meta keeps its bytes"
  assert_no_file "$NH/state/t1.status" "W4: the port wrote nothing else"
  assert_eq "$(ls "$NH/state")" "t1.meta" "W4: no temp left by the port"
fi

# 16. a meta holding a NUL byte (W3) - named divergence: BSD grep -v printed
#     `Binary file <path> matches` in place of the lines, so the original's meta
#     lost every other key; the port keeps the bytes. Receipt, status, exit equal.
reset_homes; seed state/t1.meta 'note=a\0b\nbackend=tmux\npr=old\n'
TREE=own same t1 "$U"
assert_eq "$LAST_RC" 0 "W3: both exit 0"
assert_eq "$(cat "$OH/state/t1.meta")" "Binary file $OH/state/t1.meta matches
pr=$U
pr_head=deadbeefcafe" "W3: the original destroyed the meta"
meta_is "note=a\0b\nbackend=tmux\npr=$U\npr_head=deadbeefcafe\n"
assert_eq "$(cat "$NH/state/t1.status")" "$(cat "$OH/state/t1.status")" "W3: the status lines agree"

# 17. a byte that is not UTF-8 in a kept line passes through on both sides
reset_homes; seed state/t1.meta 'note=d\351\nbackend=tmux\n'
same t1 "$U"
meta_is "note=d\351\nbackend=tmux\npr=$U\npr_head=deadbeefcafe\n"

# 18. state/ and data/ absent at the start are minted by the look and the mirror
reset_homes bare; seed state/t1.meta 'backend=tmux\n'
same t1 "$U"
assert_eq "$(cat "$NH/data/t1/timeline.log")" "$ISO PR ready: $U (OPEN)" "data/ minted for the mirror"
reset_homes bare
same nosuch "$U"
assert_contains "$(shim_tree)" "== ./state/" "state/ minted by the meta look"

# 19. a symlinked meta is replaced by a regular file, the target untouched; a
#     dangling one is no meta. (A planted sibling at the original's `.tmp.$$`
#     is unpredictable for the port; tests/ts/pr-check.test.ts pins it.)
reset_homes; seed state/real.meta 'backend=tmux\n'
ln -s real.meta "$OH/state/t1.meta"; ln -s real.meta "$NH/state/t1.meta"
same t1 "$U"
assert_eq "$LAST_RC" 0 "a symlinked meta records"
[ ! -L "$NH/state/t1.meta" ] || fail "the symlink was not replaced by a regular file"
assert_eq "$(cat "$NH/state/real.meta")" "backend=tmux" "the link target is untouched"
meta_is "backend=tmux\npr=$U\npr_head=deadbeefcafe\n"
reset_homes
ln -s gone.meta "$OH/state/t1.meta"; ln -s gone.meta "$NH/state/t1.meta"
same t1 "$U"
assert_eq "$(shim_err)" "ERROR: no crewmate meta for t1" "a dangling link is no meta"

# 20. a url carrying a byte that is not UTF-8 - named divergence: the original
#     passes the byte to gh and records it; bun decodes argv, so the port passes
#     and records U+FFFD (EF BF BD). Exit equal.
reset_homes; seed state/t1.meta 'backend=tmux\n'
bad="$(printf 'https://github.com/a/b/pull/7\351')"
o_rc=0; n_rc=0
oracle t1 "$bad" || o_rc=$?
shim t1 "$bad" || n_rc=$?
assert_eq "$n_rc" "$o_rc" "a non-UTF-8 url: exit equal"
assert_eq "$n_rc" 0 "a non-UTF-8 url records on both sides"
printf 'backend=tmux\npr=https://github.com/a/b/pull/7\351\npr_head=deadbeefcafe\n' | cmp -s - "$OH/state/t1.meta" || fail "the original records the byte"
printf 'backend=tmux\npr=https://github.com/a/b/pull/7\357\277\275\npr_head=deadbeefcafe\n' | cmp -s - "$NH/state/t1.meta" || fail "the port records U+FFFD"
assert_contains "$(cat "$NH.gh")" "$(printf 'pull/7\357\277\275]')" "the port passed U+FFFD to gh"

# 21. date(1) failing when the status is stamped: the meta is already rewritten
#     (both gh calls and both rewrites precede it), the run ends with date's
#     status, no status line, no timeline - the bash's errexit on `ts="$(ac_iso)"`
reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
mkdir -p "$TMP/baddate"; printf '#!/bin/sh\ncase "$*" in "-u +%%Y-%%m-%%dT%%H:%%M:%%SZ") exit 3 ;; *) exec /bin/date "$@" ;; esac\n' >"$TMP/baddate/date"; chmod +x "$TMP/baddate/date"
o_rc=0; n_rc=0
(cd "$TMP" && env AC_HOME="$OH" LC_ALL=C PATH="$TMP/baddate:$STUBS:$PATH" GH_LOG="$OH.gh" GH_HEAD='deadbeefcafe\n' GH_STATE='OPEN\n' GH_RC_HEAD=0 GH_RC_STATE=0 GH_ERR_HEAD= GH_ERR_STATE= "$obin/ac-pr-check.sh" t1 "$U") >"$TMP/o.raw" 2>"$TMP/o.rawerr" || o_rc=$?
(cd "$TMP" && env AC_HOME="$NH" LC_ALL=C PATH="$TMP/baddate:$STUBS:$PATH" GH_LOG="$NH.gh" GH_HEAD='deadbeefcafe\n' GH_STATE='OPEN\n' GH_RC_HEAD=0 GH_RC_STATE=0 GH_ERR_HEAD= GH_ERR_STATE= "$BIN/ac-pr-check.sh" t1 "$U") >"$TMP/n.raw" 2>"$TMP/n.rawerr" || n_rc=$?
assert_eq "$n_rc $o_rc" "3 3" "date failing: both end with date's status"
assert_eq "$(cat "$TMP/o.raw" "$TMP/n.raw" "$TMP/o.rawerr" "$TMP/n.rawerr")" "" "date failing: nothing printed on either side"
snap "$OH" "$TMP/o.tree"; snap "$NH" "$TMP/n.tree"
cmp -s "$TMP/o.tree" "$TMP/n.tree" || fail "date failing: the homes differ: $(diff "$TMP/o.tree" "$TMP/n.tree" | head -n 6)"
meta_is "backend=tmux\nkind=ship\npr=$U\npr_head=deadbeefcafe\n"
assert_no_file "$NH/state/t1.status" "date failing: no status line"
assert_no_file "$NH/data/t1/timeline.log" "date failing: no timeline"
# a date ended by a signal is 128+signal on both sides (the shell's reading)
mkdir -p "$TMP/killdate"; printf '#!/bin/sh\ncase "$*" in "-u +%%Y-%%m-%%dT%%H:%%M:%%SZ") kill -TERM $$ ;; *) exec /bin/date "$@" ;; esac\n' >"$TMP/killdate/date"; chmod +x "$TMP/killdate/date"
reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
o_rc=0; n_rc=0
(cd "$TMP" && env AC_HOME="$OH" LC_ALL=C PATH="$TMP/killdate:$STUBS:$PATH" GH_LOG="$OH.gh" GH_HEAD='deadbeefcafe\n' GH_STATE='OPEN\n' GH_RC_HEAD=0 GH_RC_STATE=0 GH_ERR_HEAD= GH_ERR_STATE= "$obin/ac-pr-check.sh" t1 "$U") >"$TMP/o.raw" 2>"$TMP/o.rawerr" || o_rc=$?
(cd "$TMP" && env AC_HOME="$NH" LC_ALL=C PATH="$TMP/killdate:$STUBS:$PATH" GH_LOG="$NH.gh" GH_HEAD='deadbeefcafe\n' GH_STATE='OPEN\n' GH_RC_HEAD=0 GH_RC_STATE=0 GH_ERR_HEAD= GH_ERR_STATE= "$BIN/ac-pr-check.sh" t1 "$U") >"$TMP/n.raw" 2>"$TMP/n.rawerr" || n_rc=$?
assert_eq "$n_rc $o_rc" "143 143" "date killed: both end with 128+SIGTERM"
assert_no_file "$NH/state/t1.status" "date killed: no status line"
# a date whose stamp carries a NUL: `$(...)` dropped it, both logs agree
mkdir -p "$TMP/nuldate"; printf '#!/bin/sh\ncase "$*" in "-u +%%Y-%%m-%%dT%%H:%%M:%%SZ") printf "2026-01-01T00:00:00Z\\000\\n" ;; *) exec /bin/date "$@" ;; esac\n' >"$TMP/nuldate/date"; chmod +x "$TMP/nuldate/date"
reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'
o_rc=0; n_rc=0
(cd "$TMP" && env AC_HOME="$OH" LC_ALL=C PATH="$TMP/nuldate:$STUBS:$PATH" GH_LOG="$OH.gh" GH_HEAD='deadbeefcafe\n' GH_STATE='OPEN\n' GH_RC_HEAD=0 GH_RC_STATE=0 GH_ERR_HEAD= GH_ERR_STATE= "$obin/ac-pr-check.sh" t1 "$U") >"$TMP/o.raw" 2>"$TMP/o.rawerr" || o_rc=$?
(cd "$TMP" && env AC_HOME="$NH" LC_ALL=C PATH="$TMP/nuldate:$STUBS:$PATH" GH_LOG="$NH.gh" GH_HEAD='deadbeefcafe\n' GH_STATE='OPEN\n' GH_RC_HEAD=0 GH_RC_STATE=0 GH_ERR_HEAD= GH_ERR_STATE= "$BIN/ac-pr-check.sh" t1 "$U") >"$TMP/n.raw" 2>"$TMP/n.rawerr" || n_rc=$?
assert_eq "$n_rc $o_rc" "0 0" "NUL stamp: both record"
cmp -s "$OH/state/t1.status" "$NH/state/t1.status" || fail "NUL stamp: the status bytes differ: $(od -c "$NH/state/t1.status" | head -n 2)"
cmp -s "$OH/data/t1/timeline.log" "$NH/data/t1/timeline.log" || fail "NUL stamp: the timeline bytes differ"
assert_eq "$(cat "$NH/state/t1.status")" "$ISO PR ready: $U (OPEN)" "NUL stamp: the NUL is gone from the line"

# 22. the status file cannot be appended (mode 000): the bash's errexit on the
#     `>>` ended the run with exit 1 and bash's own redirection line, before any
#     mirror; the port refuses with its line (shell-own stderr not reproduced) -
#     the meta rewritten on both sides, no timeline (root writes it: unprivileged only)
if [ "$(id -u)" != 0 ]; then
  reset_homes; seed state/t1.meta 'backend=tmux\nkind=ship\n'; seed state/t1.status ''
  chmod 000 "$OH/state/t1.status" "$NH/state/t1.status"
  o_rc=0; n_rc=0
  oracle t1 "$U" || o_rc=$?
  shim t1 "$U" || n_rc=$?
  chmod 644 "$OH/state/t1.status" "$NH/state/t1.status"
  assert_eq "$n_rc $o_rc" "1 1" "unwritable status: both exit 1"
  assert_eq "$(cat "$TMP/o.raw" "$TMP/n.raw")" "" "unwritable status: no receipt on either side"
  assert_contains "$(cat "$TMP/o.rawerr")" "Permission denied" "unwritable status: bash's redirection line on the original"
  assert_eq "$(cat "$TMP/n.rawerr")" "ERROR: cannot append $NH/state/t1.status" "unwritable status: the port's refusal"
  meta_is "backend=tmux\nkind=ship\npr=$U\npr_head=deadbeefcafe\n"
  printf 'backend=tmux\nkind=ship\npr=%s\npr_head=deadbeefcafe\n' "$U" | cmp -s - "$OH/state/t1.meta" || fail "unwritable status: the original rewrote the meta before the status"
  assert_eq "$(cat "$OH/state/t1.status" "$NH/state/t1.status")" "" "unwritable status: no status line on either side"
  assert_no_file "$NH/data/t1/timeline.log" "unwritable status: no mirror after the failed primary (port)"
  assert_no_file "$OH/data/t1/timeline.log" "unwritable status: no mirror after the failed primary (original)"
fi

# 23. an id ending in LF: the meta and the status keep the LF in their names,
#     the timeline lands under the LF-less dir `$(ac_task_dir)` captured
#     (the leg's snap reads names line by line, so this row compares by hand)
reset_homes; seed "state/t1
.meta" 'backend=tmux\nkind=ship\n'
o_rc=0; n_rc=0
oracle "t1
" "$U" || o_rc=$?
shim "t1
" "$U" || n_rc=$?
assert_eq "$n_rc $o_rc" "0 0" "LF id: both record"
assert_eq "$(norm "$TMP/n.raw" "$NH")" "$(norm "$TMP/o.raw" "$OH")" "LF id: the same receipt"
for h in "$OH" "$NH"; do
  [ -f "$h/data/t1/timeline.log" ] || fail "LF id: the timeline must sit under the LF-less dir ($h)"
  [ -f "$h/state/t1
.status" ] || fail "LF id: the status keeps the LF in its name ($h)"
  [ -f "$h/state/t1
.meta" ] || fail "LF id: the meta keeps the LF in its name ($h)"
done
assert_eq "$(cat "$NH/data/t1/timeline.log")" "$(cat "$OH/data/t1/timeline.log")" "LF id: the same timeline line"
assert_eq "$(cat "$NH/data/t1/timeline.log")" "$ISO PR ready: $U (OPEN)" "LF id: the timeline line"

pass
