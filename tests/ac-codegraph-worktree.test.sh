#!/usr/bin/env bash
# ac-codegraph-worktree.test.sh - ac_codegraph_worktree (ac-lib.sh): a leased
# worktree gets its OWN CodeGraph index of the crew branch AUTOMATICALLY -
# full init on the slot's first lease, incremental sync after - with
# config/codegraph=off as the fleet valve, always fire-and-forget.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

. "$BIN/ac-lib.sh"
make_home

repo="$(make_repo)"; wt="$repo/.crew/worktrees/1"
mkdir -p "$wt"
log="$TMP/cg.log"

# stub codegraph on PATH: records verb + cwd, and init materializes the cache
# dir the way the real tool does (so the second lease takes the sync arm)
mkdir -p "$TMP/stubbin"
cat >"$TMP/stubbin/codegraph" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "\$1" "\$(pwd)" >>"$log"
[ "\$1" = init ] && { mkdir -p .codegraph; : >.codegraph/codegraph.db; }
exit 0
EOF
chmod +x "$TMP/stubbin/codegraph"
PATH="$TMP/stubbin:$PATH"

# node-CLI children take ~1s to start under load - poll, never sleep-guess
wait_grep() { # wait_grep <pattern> <file> <label>
  local i=0
  while [ "$i" -lt 100 ]; do
    grep -q "$1" "$2" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "$3: '$1' never appeared in $2"
}

# 1) fleet valve off -> no action
printf 'off\n' >"$AC_HOME/config/codegraph"
ac_codegraph_worktree "$repo" "$wt"; sleep 1
assert_no_file "$log" "config/codegraph=off means no action"
rm -f "$AC_HOME/config/codegraph"

# 2) default: slot's first lease -> full init IN the worktree, no root index needed
ac_codegraph_worktree "$repo" "$wt"
wait_grep "init $wt" "$log" "first lease inits inside the worktree automatically"

# 2b) the cache dir is excluded for the WHOLE repo (root + every worktree)
# through the shared info/exclude - an unignored .codegraph/ would read as
# dirty and starve the pool of the slot forever
grep -qxF '.codegraph/' "$repo/.git/info/exclude" || fail "info/exclude carries .codegraph/"

# 3) slot already carries a cache -> incremental sync, never a re-init
ac_codegraph_worktree "$repo" "$wt"
wait_grep "sync $wt" "$log" "later leases sync incrementally"
assert_eq "$(grep -c '^init ' "$log")" "1" "init happens once per slot"

# 4) codegraph missing from PATH -> silent no-op (accelerator, not dependency)
rm -f "$log"
PATH="$(printf '%s' "$PATH" | sed "s|$TMP/stubbin:||")"
ac_codegraph_worktree "$repo" "$wt"; sleep 0.5
assert_no_file "$log" "no tool means no action and no error"

pass
