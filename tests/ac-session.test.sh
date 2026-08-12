#!/usr/bin/env bash
# ac-session.test.sh - view/talk resume commands: fork-session on view,
# un-forked on talk, archive lookup, missing-session refusals.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# Live claude task with a recorded session id.
mkdir -p "$AC_HOME/state/archive/old1"
cat >"$AC_HOME/state/t1.meta" <<'EOF'
worktree=/tmp/wt1
harness=claude
backend=tmux
session_id=aaaabbbb-cccc-dddd-eeee-ffff00001111
EOF

out="$("$BIN/ac-session.sh" t1 2>/dev/null)"
assert_contains "$out" "resume aaaabbbb" "view resumes the session"
assert_contains "$out" "fork-session" "view is forked (safe)"

# Talk on a parked task (window gone -> state 'gone') is allowed, un-forked.
out="$("$BIN/ac-session.sh" t1 --talk 2>/dev/null)"
assert_contains "$out" "TALK: un-forked" "talk mode"
case "$out" in *--fork-session*) fail "talk must not fork" ;; esac

# Talk is REFUSED when the BACKEND itself is unobservable (F12): the state
# we don't know is exactly what could be mid-turn, and --talk's own hazard
# (two writers corrupt one session) is destructive the same way a REAP acting
# on an unknown pane is (contract: records/repo-knowledge/agent-crew.md:86,
# reap_orphan_window - REFUSE must not proceed on unknown), so unobservable is
# treated like busy, not like a silently-permitted unknown.
make_fake_herdr
printf 'worktree=/tmp/wt-t4\nharness=claude\nbackend=herdr\nsession_id=aaaabbbb-cccc-dddd-eeee-ffff00004444\n' \
  >"$AC_HOME/state/t4.meta"
printf 'pT4 tT4\n' >"$AC_HOME/state/.pane-t4"
printf 'pT4\n' >"$FAKE_HERDR/tabs/tT4"
: >"$FAKE_HERDR/panes/pT4.buf"
touch "$FAKE_HERDR/.unreachable"
err="$("$BIN/ac-session.sh" t4 --talk 2>&1)" && fail "talk must refuse an unobservable backend"
assert_contains "$err" "backend" "the talk refusal blames the BACKEND, not the pane"
assert_contains "$err" "UNKNOWN" "the talk refusal names liveness as unknown, not mid-turn"
rm -f "$FAKE_HERDR/.unreachable"

# Archived task still resolves.
cat >"$AC_HOME/state/archive/old1/meta" <<'EOF'
worktree=/tmp/wt-old
harness=claude
session_id=99998888-7777-6666-5555-444433332222
EOF
assert_contains "$("$BIN/ac-session.sh" old1 2>/dev/null)" "resume 99998888" "archive lookup"

# Refusals: no session id, non-claude harness.
printf 'worktree=/tmp/x\nharness=claude\n' >"$AC_HOME/state/t2.meta"
assert_fails "$BIN/ac-session.sh" t2
printf 'worktree=/tmp/x\nharness=fake\nsession_id=x\n' >"$AC_HOME/state/t3.meta"
assert_fails "$BIN/ac-session.sh" t3

pass
