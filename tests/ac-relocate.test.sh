#!/usr/bin/env bash
# ac-relocate.test.sh - family-workspace relocation: idle-only guard,
# herdr-only, adopt-by-label target resolution (FAMILY WORKSPACE GROUPING),
# session resume in the new tab, handle/meta updates, no-op when already
# in the target workspace.
# shellcheck disable=SC2016  # script bodies are deliberately unexpanded here

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null || { printf 'SKIP: jq not available\n'; exit 0; }

make_home
stub="$TMP/stubbin"
mkdir -p "$stub"
export HDLOG="$TMP/hd.log" HDSTATE="$TMP/hd.state"
printf 'idle\n' >"$HDSTATE"
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab get") printf '{"result":{"tab":{"tab_id":"%s","agent_status":"%s"}}}\n' "$3" "$(cat "$HDSTATE")" ;;
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wC","label":"%s · famR","tab_count":2}]}}\n' "$AC_TEST_FLEET" ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"wC:tN"},"root_pane":{"pane_id":"pNEW"}}}' ;;
  # verified sends probe by capture-change: the render must react per call
  # (the log grows on every CLI hit) or every submit would read as stranded.
  "pane read") printf 'r%s\n' "$(wc -l <"$HDLOG")" ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"

relocate() { PATH="$stub:$PATH" AC_TEST_FLEET="$fleet" AC_SPAWN_SETTLE=0 "$BIN/ac-relocate.sh" "$@"; }

fleet="$(basename "$AC_HOME")"
mkdir -p "$AC_HOME/data/famR/chief"   # ac_family_of_id trusts -chief only with the nested dir
cat >"$AC_HOME/state/famR-chief.meta" <<EOF
backend=herdr
kind=roomchief
project=famR
worktree=/tmp
session_id=sid-123
EOF
printf 'p1 wA:t1\n' >"$AC_HOME/state/.pane-famR-chief"

# Refusals: unknown task, busy agent.
assert_fails relocate nosuchtask
printf 'working\n' >"$HDSTATE"
assert_fails relocate famR-chief
printf 'idle\n' >"$HDSTATE"

# Happy path: default target for famR-chief is famR's OWN family workspace,
# adopted by label; old tab closed, new tab there, handles/meta updated,
# session resumed with scope, watcher re-arm notice delivered.
out="$(relocate famR-chief)"
assert_contains "$out" "relocated famR-chief group=famR" "relocation reported"
log="$(cat "$HDLOG")"
assert_contains "$log" "tab close wA:t1" "old tab closed"
assert_contains "$log" "tab create --workspace wC" "created in the adopted family workspace"
assert_contains "$log" "AC_SCOPE=famR claude --resume sid-123" "session resumed with scope"
assert_contains "$log" 'AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set famR)' "watcher re-arm notice computes the story set"
assert_eq "$(cat "$AC_HOME/state/.pane-famR-chief")" "pNEW wC:tN" "handle updated"
assert_contains "$(cat "$AC_HOME/state/famR-chief.meta")" "window=herdr:pane-pNEW" "meta updated"

# Already in the target workspace: no-op success.
out="$(relocate famR-chief)"
assert_contains "$out" "already in group famR" "no-op when already there"

# No session_id -> refuse; non-herdr backend -> refuse.
cat >"$AC_HOME/state/nosid.meta" <<EOF
backend=herdr
kind=ship
worktree=/tmp
EOF
printf 'p2 wA:t2\n' >"$AC_HOME/state/.pane-nosid"
assert_fails relocate nosid
printf 'backend=tmux\nkind=ship\nworktree=/tmp\nsession_id=s\n' >"$AC_HOME/state/tm1.meta"
assert_fails relocate tm1

# --- the two steers are DIAGNOSED, never a bare errexit abort ------------------
# Contract: ac-relocate.sh header. Both backend_send_line calls run under
# `set -e`, so an unacknowledged one used to abort with no diagnosis at all and
# skip the status append below it. They now split on what the failure costs.

# The RESUME line is fatal: nothing was resumed, so there is no relocation to
# record. Reads are frozen, so every submit reads as a strand.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab get") printf '{"result":{"tab":{"tab_id":"%s","agent_status":"%s"}}}\n' "$3" "$(cat "$HDSTATE")" ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wC"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"wC:tX"},"root_pane":{"pane_id":"pX"}}}' ;;
  "pane read") printf 'frozen\n' ;;
esac
exit 0
EOF
mkdir -p "$AC_HOME/data/famX/chief"
cat >"$AC_HOME/state/famX-chief.meta" <<EOF
backend=herdr
kind=roomchief
project=famX
worktree=/tmp
session_id=sid-x
EOF
printf 'p1 wA:t1\n' >"$AC_HOME/state/.pane-famX-chief"
err="$(relocate famX-chief 2>&1)" && fail "an undelivered resume line must be fatal"
assert_contains "$err" "resume line NOT delivered" "the fatal names what was not delivered"
assert_no_file "$AC_HOME/state/famX-chief.status" "a relocation that never resumed records nothing"

# The NOTICE is a loud warning: it fails AFTER the tab was recreated and the
# session resumed, so dying there would leave the durable status line unwritten
# for a relocation that really happened. The stub freezes the render only once
# the notice has been TYPED, so the resume line before it still acks.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab get") printf '{"result":{"tab":{"tab_id":"%s","agent_status":"%s"}}}\n' "$3" "$(cat "$HDSTATE")" ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wC"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"wC:tY"},"root_pane":{"pane_id":"pY"}}}' ;;
  "pane read")
    if grep -q 'Notice: your window was relocated' "$HDLOG"; then printf 'frozen\n'
    else printf 'r%s\n' "$(wc -l <"$HDLOG")"; fi ;;
esac
exit 0
EOF
mkdir -p "$AC_HOME/data/famY/chief"
cat >"$AC_HOME/state/famY-chief.meta" <<EOF
backend=herdr
kind=roomchief
project=famY
worktree=/tmp
session_id=sid-y
EOF
printf 'p1 wA:t1\n' >"$AC_HOME/state/.pane-famY-chief"
: >"$HDLOG"   # the freeze trigger reads this log; earlier cases already logged a notice
errf="$TMP/relocate.err"
out="$(relocate famY-chief 2>"$errf")" \
  || fail "an undelivered notice must stay non-fatal - the session is already resumed"
assert_contains "$out" "relocated famY-chief" "the relocation is still reported"
assert_contains "$(cat "$errf")" "relocation notice NOT delivered" "the lost notice is diagnosed loudly"
assert_contains "$(cat "$AC_HOME/state/famY-chief.status")" "relocated to famY" \
  "the durable status line is still appended after a lost notice"

pass
