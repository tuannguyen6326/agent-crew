#!/usr/bin/env bash
# ac-herdr-tab-open.test.sh - ac_herdr_tab_open (bin/ac-backend.sh, moved from
# ac-lib.sh by audit-f3), the workspace-fallback "tab create + pane-id sed"
# idiom shared by ac-ship.sh,
# ac-qa.sh, ac-gate.sh (watch-dashboard openers) and ac-pane-agent.sh
# (verifier pane opener) - F26. One helper, so a caller can no longer drift
# out of sync with a fix landed in a sibling copy (ac-qa.sh's copy had
# missed the ac-ship.sh copy's errexit guard on the very next two lines).
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home
. "$BIN/ac-lib.sh"
. "$BIN/ac-backend.sh"

repo="$(make_repo)"

# --- no workspace: plain tab create, pane_id + tab_id parsed back -------------
out="$(ac_herdr_tab_open sess mylabel "$repo")"
p="${out%% *}"; tab="${out#* }"
assert_contains "$p" "p" "a pane id is returned"
assert_contains "$tab" "t" "a tab id is returned"
assert_contains "$(tail -1 "$FAKE_HERDR/log")" "tab create" "the CLI was called"
case "$(tail -1 "$FAKE_HERDR/log")" in
  *--workspace*) fail "no workspace given must not pass --workspace" ;;
esac
assert_file "$FAKE_HERDR/panes/$p.buf" "the created pane exists"

# --- with a workspace: --workspace rides the call, same parse shape ----------
ws="$(herdr workspace create --label mygroup | sed -n 's/.*"workspace_id":"\([^"]*\)".*/\1/p')"
out="$(ac_herdr_tab_open sess wslabel "$repo" "$ws")"
p2="${out%% *}"
assert_contains "$(tail -1 "$FAKE_HERDR/log")" "--workspace $ws" "the workspace id rides the call"
assert_file "$FAKE_HERDR/panes/$p2.buf" "the workspace-scoped pane exists"

# --- an unreachable backend fails closed: no output, non-zero return ---------
touch "$FAKE_HERDR/.unreachable"
rc=0
out="$(ac_herdr_tab_open sess deadlabel "$repo" 2>/dev/null)" || rc=$?
rm -f "$FAKE_HERDR/.unreachable"
[ "$rc" -ne 0 ] || fail "an unreachable backend must not report success"
assert_eq "$out" "" "an unreachable backend prints nothing to parse"

pass
